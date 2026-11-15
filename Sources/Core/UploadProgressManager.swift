// Owns each complete upload, including server processing and publication.
import BackgroundTasks
import Foundation
import SwiftUI

enum UploadStage {
    case preparing, convertingVideo, uploadingAttachments, submittingTweet, completed, failed
}

@MainActor
final class UploadProgressManager: ObservableObject {
    static let shared = UploadProgressManager()

    @Published var isUploading = false
    @Published var currentStage: UploadStage = .preparing
    @Published var stageMessage = ""
    @Published var progress = 0.0
    @Published var detailedProgress = ""
    @Published var uploadType = ""
    @Published private(set) var canContinueInBackground = false
    @Published private(set) var pendingChatUploads: [TweetUploadManager.PendingTweetUpload] = []
    var isProcessingVideo = false

    private struct QueuedUpload {
        let pending: TweetUploadManager.PendingTweetUpload
        let saved: Task<Void, Error>?
        let completion: CheckedContinuation<Void, Error>?
    }

    private var queue: [QueuedUpload] = []
    private var worker: Task<Void, Never>?
    private var activeID: UUID?
    private var discardActiveUpload = false
    private var dismissal: Task<Void, Never>?
    private let background = UploadBackgroundExecution()

    var hasActiveOrQueuedUploads: Bool { worker != nil || !queue.isEmpty }

    private init() {
        background.didStart = { [weak self] in
            self?.canContinueInBackground = true
            UIApplication.shared.isIdleTimerDisabled = false
        }
        background.didExpire = { [weak self] in
            guard let self else { return }
            self.canContinueInBackground = false
            self.worker?.cancel()
            VideoConversionService.shared.cancelCurrentConversion()
            self.stageMessage = NSLocalizedString("Upload paused. You can retry when you return.", comment: "Upload paused")
            self.currentStage = .failed
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func enqueueUploadAndWait(pending: TweetUploadManager.PendingTweetUpload) async throws {
        try await withCheckedThrowingContinuation { continuation in
            enqueueUpload(pending: pending, completion: continuation)
        }
    }

    func enqueueUpload(
        pending: TweetUploadManager.PendingTweetUpload,
        completion: CheckedContinuation<Void, Error>? = nil,
        alreadySaved: Bool = false
    ) {
        guard activeID != pending.id, !queue.contains(where: { $0.pending.id == pending.id }) else {
            completion?.resume(throwing: NSError(domain: "TweetUpload", code: -1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("This edit is already being saved.", comment: "Duplicate edit upload")
            ]))
            return
        }
        // Save queued items too, so a process exit cannot lose a second post.
        let saved = alreadySaved ? nil : Task {
            try await HproseInstance.shared.uploadManager.savePendingUpload(pending)
        }
        queue.append(QueuedUpload(pending: pending, saved: saved, completion: completion))
        if pending.recipientId != nil { pendingChatUploads.append(pending) }
        guard worker == nil else { return }
        worker = Task { await processQueue() }
    }

    private func processQueue() async {
        defer {
            worker = nil
            activeID = nil
            isProcessingVideo = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        while !queue.isEmpty && !Task.isCancelled {
            let entry = queue.removeFirst()
            let pending = entry.pending
            activeID = pending.id
            discardActiveUpload = false
            dismissal?.cancel()
            isUploading = true
            uploadType = pending.type
            currentStage = .preparing
            stageMessage = NSLocalizedString("Preparing upload...", comment: "Upload stage")
            detailedProgress = ""
            progress = 0
            isProcessingVideo = pending.hasVideos
            canContinueInBackground = false
            UIApplication.shared.isIdleTimerDisabled = true
            // Requests originate only from the user-started foreground queue.
            // Pending recovery waits for the user's Retry button.
            background.request(title: uploadTitle, message: stageMessage)
            do {
                try await entry.saved?.value
                try Task.checkCancellation()
                try await HproseInstance.shared.uploadManager.executeUpload(pending)
                completeUpload()
                entry.completion?.resume()
            } catch {
                background.finish(success: false)
                if discardActiveUpload {
                    do { try await HproseInstance.shared.uploadManager.removePendingUpload(pending) }
                    catch { print("[Upload] Could not discard pending upload: \(error)") }
                }
                if Task.isCancelled {
                    failUpload(message: NSLocalizedString(discardActiveUpload ? "Upload cancelled" :
                        "Upload paused. You can retry when you return.", comment: "Upload stopped"))
                } else {
                    print("[Upload] Operation remains pending: \(error)")
                    let message = pending.type == "edit"
                        ? ErrorMessageHelper.userFriendlyMessage(from: error)
                        : NSLocalizedString("Upload unfinished. You can retry when you return.", comment: "Upload pending")
                    failUpload(message: message)
                    if pending.type == "tweet" {
                        NotificationCenter.default.post(
                            name: .tweetPublishFailed, object: nil,
                            userInfo: ["error": ErrorMessageHelper.userFriendlyMessage(from: error)]
                        )
                    } else if pending.type == "edit", entry.completion == nil {
                        // The editor presents its own alert when it is waiting for the operation.
                        NotificationCenter.default.post(
                            name: .backgroundUploadFailed, object: nil,
                            userInfo: ["error": message]
                        )
                    }
                }
                entry.completion?.resume(throwing: error)
            }
            if pending.recipientId != nil {
                pendingChatUploads.removeAll { $0.id == pending.id }
            }
            background.finish(success: currentStage == .completed)
            canContinueInBackground = false
            isProcessingVideo = false
            // A new background job cannot be requested without a foreground
            // user action. Saved queued posts remain available for Retry.
            if Task.isCancelled || UIApplication.shared.applicationState == .background { break }
        }

        // A paused worker must also finish any editor that was waiting in the
        // queue, while preserving the queued uploads on disk for explicit retry.
        let pausedError = NSError(domain: "TweetUpload", code: -1, userInfo: [
            NSLocalizedDescriptionKey: NSLocalizedString("Upload paused. You can retry when you return.", comment: "Upload paused")
        ])
        while !queue.isEmpty {
            let queued = queue.removeFirst()
            do {
                try await queued.saved?.value
                queued.completion?.resume(throwing: pausedError)
            } catch {
                queued.completion?.resume(throwing: error)
            }
        }
        if !pendingChatUploads.isEmpty { pendingChatUploads.removeAll() }
    }

    var uploadTitle: String {
        switch uploadType {
        case "tweet": return NSLocalizedString("Posting Tweet", comment: "Upload title")
        case "comment": return NSLocalizedString("Posting Comment", comment: "Upload title")
        case "chat": return NSLocalizedString("Sending Message", comment: "Upload title")
        case "edit": return NSLocalizedString("Updating Tweet", comment: "Upload title")
        default: return NSLocalizedString("Uploading", comment: "Upload title")
        }
    }

    func updateProgress(stage: UploadStage, message: String, progress: Double = 0, detail: String = "", operationID: UUID? = nil) {
        // A callback from a cancelled media encoder belongs to its own operation.
        if let operationID, operationID != activeID { return }
        guard worker?.isCancelled != true else { return }
        currentStage = stage
        stageMessage = message
        self.progress = max(self.progress, min(max(progress, 0), 0.99))
        detailedProgress = detail
        background.update(fraction: self.progress, message: message)
    }

    func completeUpload() {
        currentStage = .completed
        stageMessage = NSLocalizedString("Upload completed", comment: "Upload stage")
        progress = 1
        background.finish(success: true)
        scheduleDismissal(after: 1)
    }

    func failUpload(message: String) {
        currentStage = .failed
        stageMessage = message
        background.finish(success: false)
        scheduleDismissal(after: 3)
    }

    private func scheduleDismissal(after seconds: Double) {
        UIApplication.shared.isIdleTimerDisabled = false
        dismissal?.cancel()
        dismissal = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            isUploading = false
            uploadType = ""
            detailedProgress = ""
        }
    }

    func cancelUpload() {
        guard worker != nil else { isUploading = false; return }
        discardActiveUpload = true
        worker?.cancel()
        VideoConversionService.shared.cancelCurrentConversion()
        background.finish(success: false)
        stageMessage = NSLocalizedString("Cancelling upload...", comment: "Upload cancellation")
        // Wait for the worker before deleting its checkpoint or starting another
        // operation. An in-flight publication may still return confirmed success.
        NotificationCenter.default.post(name: .uploadCancelled, object: nil)
    }
}

/// Runtime for one finite, user-started upload. Never pretends that interrupted
/// publication succeeded; the pending checkpoint records what remains uncertain.
@MainActor
private final class UploadBackgroundExecution {
    private final class Completion { var success = false }
    private var identifier: String?
    private var completion: Completion?
    private var task: BGTask?
    private var fraction = 0.0
    private var title = ""
    private var message = ""
    var didStart: (() -> Void)?
    var didExpire: (() -> Void)?

    func request(title: String, message: String) {
        guard #available(iOS 26.0, *), UIApplication.shared.applicationState != .background else { return }
        let id = (Bundle.main.bundleIdentifier ?? "com.example.Tweet") + ".upload." + UUID().uuidString
        let completion = Completion()
        self.identifier = id
        self.completion = completion
        self.title = title
        self.message = message
        fraction = 0
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            Task { @MainActor in
                guard let self, self.identifier == id else {
                    // The upload can finish before iOS delivers the grant.
                    task.setTaskCompleted(success: completion.success)
                    return
                }
                self.task = task
                guard let continued = task as? BGContinuedProcessingTask else {
                    self.finish(success: false)
                    return
                }
                continued.progress.totalUnitCount = 1_000_000
                continued.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.identifier == id else { return }
                        self.finish(success: false)
                        self.didExpire?()
                    }
                }
                self.update(fraction: self.fraction, message: self.message)
                self.didStart?()
            }
        }
        guard registered else { finish(success: false); return }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: message)
        // Upload immediately in the foreground if iOS cannot grant runtime.
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) }
        catch {
            print("[Upload] Background runtime unavailable; continuing in foreground: \(error)")
            finish(success: false)
        }
    }

    func update(fraction: Double, message: String) {
        self.fraction = max(self.fraction, min(fraction, 0.99))
        self.message = message
        if #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask {
            continued.progress.completedUnitCount = Int64(self.fraction * Double(continued.progress.totalUnitCount))
            continued.updateTitle(title, subtitle: message)
        }
    }

    func finish(success: Bool) {
        let finished = task
        let requested = identifier
        completion?.success = success
        completion = nil
        task = nil
        identifier = nil
        finished?.expirationHandler = nil
        if let finished {
            if #available(iOS 26.0, *), let continued = finished as? BGContinuedProcessingTask, success {
                continued.progress.completedUnitCount = continued.progress.totalUnitCount
            }
            finished.setTaskCompleted(success: success)
        } else if let requested {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requested)
        }
    }
}
