//
//  UploadProgressManager.swift
//  Tweet
//
//  Manages upload progress tracking and app backgrounding detection
//

import Foundation
import SwiftUI
import Combine

enum UploadStage {
    case preparing
    case convertingVideo
    case uploadingAttachments
    case submittingTweet
    case completed
    case failed
}

@MainActor
class UploadProgressManager: ObservableObject {
    static let shared = UploadProgressManager()
    
    @Published var isUploading: Bool = false
    @Published var currentStage: UploadStage = .preparing
    @Published var stageMessage: String = ""
    @Published var progress: Double = 0.0 // 0.0 to 1.0
    @Published var detailedProgress: String = ""
    @Published var uploadType: String = "" // "tweet", "comment", "chat"

    private var uploadStartTime: Date?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var wasBackgrounded: Bool = false
    private var userInteractionDisabled: Bool = false
    
    // CRITICAL: Track if upload involves video conversion (FFmpeg)
    // This prevents video player cache clearing during intensive processing
    var isProcessingVideo: Bool = false
    
    // CRITICAL: Upload queue to prevent concurrent uploads from interfering
    private var uploadQueue: [QueuedUpload] = []
    private var isProcessingQueue: Bool = false
    
    struct QueuedUpload {
        let id: UUID = UUID()
        let type: String
        let hasVideos: Bool
        let execute: () async throws -> Void
    }
    
    private init() {
        setupBackgroundObserver()
    }
    
    private func setupBackgroundObserver() {
        // Observe app going to background
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if self.isUploading {
                    self.wasBackgrounded = true
                    print("⚠️ [UploadProgress] App backgrounded during upload")
                    
                    // CRITICAL: Clear video processing flag immediately to allow video player cleanup
                    // Video players need to release resources when backgrounding
                    if self.isProcessingVideo {
                        print("⚠️ [UploadProgress] Clearing video processing flag on background")
                        self.isProcessingVideo = false
                    }
                }
            }
        }
        
        // Observe app returning to foreground
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if self.wasBackgrounded {
                    print("⚠️ [UploadProgress] App foregrounded after upload interruption")
                    // Check if upload is still active
                    if self.isUploading {
                        // Upload may have failed, notify user
                        self.handleBackgroundInterruption()
                    }
                    self.wasBackgrounded = false
                }
            }
        }
    }
    
    /// Enqueue an upload to be processed (prevents concurrent upload conflicts)
    func enqueueUpload(type: String, hasVideos: Bool = false, execute: @escaping () async throws -> Void) {
        let upload = QueuedUpload(type: type, hasVideos: hasVideos, execute: execute)
        
        uploadQueue.append(upload)
        print("📥 [UploadQueue] Enqueued \(type) upload (queue size: \(uploadQueue.count))")
        
        // Start processing queue if not already processing
        if !isProcessingQueue {
            Task {
                await processUploadQueue()
            }
        }
    }
    
    /// Process uploads one at a time from the queue
    private func processUploadQueue() async {
        guard !isProcessingQueue else {
            print("⚠️ [UploadQueue] Already processing queue")
            return
        }
        
        isProcessingQueue = true
        
        while !uploadQueue.isEmpty {
            let upload = uploadQueue.removeFirst()
            print("📤 [UploadQueue] Processing \(upload.type) upload (remaining: \(uploadQueue.count))")
            
            // Start this upload
            startUpload(type: upload.type, hasVideos: upload.hasVideos)
            
            do {
                try await upload.execute()
                print("✅ [UploadQueue] \(upload.type) upload completed")
            } catch {
                print("❌ [UploadQueue] \(upload.type) upload failed: \(error)")
                // Error handling is done by the upload execute function
            }
        }
        
        isProcessingQueue = false
        print("✅ [UploadQueue] Queue processing completed")
    }
    
    /// Cancel all queued uploads (but not the current one)
    func cancelQueuedUploads() {
        let cancelledCount = uploadQueue.count
        uploadQueue.removeAll()
        if cancelledCount > 0 {
            print("🛑 [UploadQueue] Cancelled \(cancelledCount) queued upload(s)")
        }
    }
    
    func startUpload(type: String, hasVideos: Bool = false) {
        isUploading = true
        uploadType = type
        currentStage = .preparing
        
        // Show stronger warning for video uploads
        if hasVideos {
            stageMessage = NSLocalizedString("Preparing video upload... Please keep the app in foreground", comment: "Video upload warning")
        } else {
            stageMessage = NSLocalizedString("Preparing upload... Please stay on this screen", comment: "Upload stage")
        }

        progress = 0.0
        detailedProgress = ""
        uploadStartTime = Date()
        wasBackgrounded = false
        
        // CRITICAL: Mark video processing state to prevent cache clearing
        isProcessingVideo = hasVideos

        // Prevent screen from auto-locking during upload
        UIApplication.shared.isIdleTimerDisabled = true

        // Note: User interaction blocking is handled by the overlay's background
        // The dialog itself remains interactive for the close button

        print("📤 [UploadProgress] Started \(type) upload (idle timer disabled, videos: \(hasVideos), processing video: \(hasVideos))")
    }
    
    func updateProgress(stage: UploadStage, message: String, progress: Double = 0.0, detail: String = "") {
        self.currentStage = stage
        self.stageMessage = message
        self.progress = min(max(progress, 0.0), 1.0)
        self.detailedProgress = detail
        
        print("📊 [UploadProgress] \(message) - \(Int(progress * 100))%")
    }
    
    func completeUpload() {
        currentStage = .completed
        stageMessage = NSLocalizedString("Upload completed", comment: "Upload stage")
        progress = 1.0

        // Re-enable auto-lock
        UIApplication.shared.isIdleTimerDisabled = false

        // Restore user interaction
        unblockUserInteraction()
        
        // CRITICAL: Clear video processing flag
        isProcessingVideo = false

        if let startTime = uploadStartTime {
            let duration = Date().timeIntervalSince(startTime)
            print("✅ [UploadProgress] Upload completed in \(String(format: "%.1f", duration))s (idle timer re-enabled, user interaction restored)")
        }

        // Reset after a short delay
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            self.isUploading = false
            self.uploadType = ""
            self.progress = 0.0
            self.detailedProgress = ""
        }
    }
    
    func failUpload(message: String) {
        currentStage = .failed
        stageMessage = message
        progress = 0.0

        // Re-enable auto-lock
        UIApplication.shared.isIdleTimerDisabled = false

        // Restore user interaction
        unblockUserInteraction()
        
        // CRITICAL: Clear video processing flag
        isProcessingVideo = false

        print("❌ [UploadProgress] Upload failed: \(message) (idle timer re-enabled, user interaction restored)")

        // Keep failed state visible longer
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            self.isUploading = false
            self.uploadType = ""
            self.progress = 0.0
            self.detailedProgress = ""
        }
    }
    
    func cancelUpload() {
        print("🛑 [UploadProgress] User cancelled upload")
        
        // Cancel video conversion if in progress
        VideoConversionService.shared.cancelCurrentConversion()
        
        // Cancel upload task in TweetUploadManager
        HproseInstance.shared.uploadManager.cancelCurrentUpload()
        
        // Remove pending upload file
        Task {
            await HproseInstance.shared.uploadManager.removePendingUpload()
        }
        
        // Re-enable auto-lock
        UIApplication.shared.isIdleTimerDisabled = false
        
        // Restore user interaction
        unblockUserInteraction()
        
        // CRITICAL: Clear video processing flag
        isProcessingVideo = false
        
        // Reset upload state
        currentStage = .failed
        stageMessage = NSLocalizedString("Upload cancelled", comment: "Upload cancelled message")
        progress = 0.0
        isUploading = false
        uploadType = ""
        detailedProgress = ""
        
        // Post notification for upload cancellation
        NotificationCenter.default.post(
            name: .uploadCancelled,
            object: nil
        )
    }
    
    private func handleBackgroundInterruption() {
        // If still uploading after backgrounding, it likely failed
        // Clean up state to prevent video player issues
        print("⚠️ [UploadProgress] Detected upload interruption - cleaning up state")
        
        // Re-enable auto-lock
        UIApplication.shared.isIdleTimerDisabled = false
        
        // Restore user interaction
        unblockUserInteraction()
        
        // CRITICAL: Clear video processing flag to allow video player recovery
        isProcessingVideo = false
        
        // Reset upload state
        currentStage = .failed
        stageMessage = NSLocalizedString("Upload interrupted", comment: "Upload interrupted")
        progress = 0.0
        isUploading = false
        uploadType = ""
        detailedProgress = ""
        
        print("✅ [UploadProgress] State cleaned up after interruption")
    }

    private func blockUserInteraction() {
        guard !userInteractionDisabled else { return }

        Task { @MainActor in
            userInteractionDisabled = true
            // Block user interaction on all windows to prevent other tasks during upload
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                for window in windowScene.windows {
                    window.isUserInteractionEnabled = false
                }
                print("🚫 [UploadProgress] User interaction blocked during upload")
            }
        }
    }

    private func unblockUserInteraction() {
        guard userInteractionDisabled else { return }

        Task { @MainActor in
            userInteractionDisabled = false
            // Restore user interaction on all windows
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                for window in windowScene.windows {
                    window.isUserInteractionEnabled = true
                }
                print("✅ [UploadProgress] User interaction restored after upload")
            }
        }
    }
    
    deinit {
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

