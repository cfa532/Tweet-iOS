//
//  TweetUploadManager.swift
//  Tweet
//
//  Created on 2025/10/13.
//  Refactored from HproseInstance.swift to separate upload concerns
//

import Foundation
import AVFoundation
import UIKit

// MARK: - Video Conversion Status
struct VideoConversionStatus {
    let status: String
    let progress: Int
    let message: String?
    let cid: String?
}

/// Main-actor upload coordinator for UI-owned tweet/user models and upload progress state.
@MainActor
final class TweetUploadManager {
    // Reference to parent HproseInstance for accessing shared properties
    weak var hproseInstance: HproseInstance?
    
    init(hproseInstance: HproseInstance) {
        self.hproseInstance = hproseInstance
    }

    // MARK: - Public Upload Methods
    
    /// Upload data to IPFS with appropriate media processing
    /// IPFS doesn't care about file types - they're all data blobs
    /// resolveWritableUrl() is called where needed (uploadRegularFile, video HLS operations)
    func uploadToIPFS(
        data: Data,
        typeIdentifier: String,
        fileName: String? = nil,
        referenceId: String? = nil,
        noResample: Bool = false,
        progressCallback: (@Sendable (String, Int) -> Void)? = nil
    ) async throws -> (MimeiFileType?, String?) {
        guard let hproseInstance = hproseInstance else {
            throw NSError(domain: "TweetUploadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "HproseInstance not available"])
        }
        
        print("Starting upload to IPFS: typeIdentifier=\(typeIdentifier), fileName=\(fileName ?? "nil"), noResample=\(noResample)")
        
        // Detect media type
        let mediaType = await HproseInstance.MediaProcessor.detectMediaType(
            from: typeIdentifier,
            fileName: fileName,
            data: data
        )
        print("📎 [Upload] Detected media type: \(mediaType.rawValue) for typeIdentifier=\(typeIdentifier), fileName=\(fileName ?? "nil")")
        
        // Video needs special processing (normalization, HLS conversion)
        if mediaType == .video {
            return try await HproseInstance.MediaProcessor.processVideo(
                data: data,
                typeIdentifier: typeIdentifier,
                fileName: fileName,
                referenceId: referenceId,
                noResample: noResample,
                appUser: hproseInstance.appUser,
                appId: hproseInstance.appId,
                progressCallback: progressCallback
            )
        }
        
        // All non-video files: just upload as-is (images, audio, documents)
        let result = try await HproseInstance.MediaProcessor.uploadRegularFile(
            data: data,
            typeIdentifier: typeIdentifier,
            fileName: fileName,
            referenceId: referenceId,
            mediaType: mediaType,
            appUser: hproseInstance.appUser,
            appId: hproseInstance.appId,
            progressCallback: progressCallback
        )
        return (result, nil)
    }
    
    /// Persist each user-started operation before the queue begins its work.
    func scheduleTweetUpload(tweet: Tweet, itemData: [PendingTweetUpload.ItemData]) {
        enqueue(PendingTweetUpload(tweet: tweet, itemData: itemData))
    }

    func scheduleCommentUpload(comment: Tweet, to tweet: Tweet,
                               itemData: [PendingTweetUpload.ItemData], isQuoting: Bool = false) {
        enqueue(PendingTweetUpload(tweet: comment, itemData: itemData,
                                   parent: TweetRecord(tweet: tweet), isQuoting: isQuoting))
    }

    func scheduleChatMessageUpload(message: ChatMessage, itemData: [PendingTweetUpload.ItemData]) {
        let record = TweetRecord(mid: message.id, authorId: message.authorId,
                                 content: message.content, timestamp: Date(timeIntervalSince1970: message.timestamp))
        var pending = PendingTweetUpload(record: record, itemData: itemData)
        pending.recipientId = message.receiptId
        pending.chatSessionId = message.chatSessionId
        enqueue(pending)
    }

    func enqueue(_ pending: PendingTweetUpload) {
        UploadProgressManager.shared.enqueueUpload(pending: pending)
    }

    // The queue awaits this entire operation: attachment preparation, server
    // processing and publication all share one cancellation and background grant.
    func executeUpload(_ saved: PendingTweetUpload) async throws {
        guard let hproseInstance else { throw uploadError("System error") }
        guard saved.record.authorId == hproseInstance.appUser.mid else {
            throw uploadError("Sign in to the account that started this upload.")
        }
        var pending = saved
        try Task.checkCancellation()
        try await savePendingUpload(pending)
        for index in pending.itemData.indices {
            try Task.checkCancellation()
            let item = pending.itemData[index]
            if item.cid != nil || item.videoJobId != nil { continue }
            var attachment: MimeiFileType?
            var jobId: String?
            // Only media transfers are safe to retry. Publication below is never
            // automatically repeated after a lost response.
            for attempt in 0...2 {
                try Task.checkCancellation()
                do {
                    let count = pending.itemData.count
                    let operationID = pending.id
                    (attachment, jobId) = try await uploadToIPFS(
                        data: item.data, typeIdentifier: item.typeIdentifier,
                        fileName: item.fileName, noResample: item.noResample,
                        progressCallback: { message, percent in
                            Task { @MainActor in
                                UploadProgressManager.shared.updateProgress(
                                    stage: .uploadingAttachments, message: message,
                                    progress: 0.05 + 0.7 * (Double(index) + Double(percent) / 100) / Double(count),
                                    operationID: operationID)
                            }
                        })
                    guard attachment != nil else { throw uploadError("Failed to upload attachment") }
                    break
                } catch {
                    try Task.checkCancellation()
                    print("[Upload] Attachment attempt \(attempt + 1) failed: \(error)")
                    if attempt == 2 { throw error }
                    try await Task.sleep(for: .seconds(2 * (attempt + 1)))
                }
            }
            guard let attachment else { throw uploadError("Failed to upload attachment") }
            pending.itemData[index] = PendingTweetUpload.ItemData(
                identifier: item.identifier, typeIdentifier: item.typeIdentifier, data: item.data,
                fileName: item.fileName, noResample: item.noResample, videoJobId: jobId,
                cid: attachment.mid, aspectRatio: attachment.aspectRatio,
                fileSize: attachment.size, mediaType: attachment.type.rawValue)
            if attachment.type == .image {
                let cacheKey = attachment.mid
                Task.detached(priority: .utility) {
                    ImageCacheManager.shared.cacheImageData(item.data, forKey: cacheKey)
                }
            }
            // Keep the server receipt even if cancellation arrived during the transfer.
            try await savePendingUpload(pending)
            try Task.checkCancellation()
            UploadProgressManager.shared.updateProgress(
                stage: .uploadingAttachments,
                message: NSLocalizedString("Uploading attachments...", comment: "Upload stage"),
                progress: 0.05 + 0.7 * Double(index + 1) / Double(pending.itemData.count))
        }

        if pending.itemData.contains(where: { $0.videoJobId != nil }) {
            try await waitForVideoJobs(&pending)
        }
        try Task.checkCancellation()
        let attachments = pending.itemData.compactMap { item -> MediaRecord? in
            guard let cid = item.cid else { return nil }
            return MediaRecord(mid: cid, type: MediaType.fromString(item.mediaType ?? "Image"),
                               size: item.fileSize, fileName: item.fileName, aspectRatio: item.aspectRatio)
        }
        guard attachments.count == pending.itemData.count else { throw uploadError("Failed to upload attachment") }
        pending.record.attachments = attachments
        // A persisted marker prevents an interrupted non-idempotent publication
        // from being silently resubmitted on the next launch.
        pending.publicationAttempted = true
        try await savePendingUpload(pending)
        try Task.checkCancellation()
        UploadProgressManager.shared.updateProgress(stage: .submittingTweet,
            message: NSLocalizedString("Publishing...", comment: "Upload stage"), progress: 0.95)

        if let recipient = pending.recipientId {
            let message = ChatMessage(id: pending.record.mid, authorId: pending.record.authorId,
                receiptId: recipient, chatSessionId: pending.chatSessionId ?? "",
                content: pending.record.content, timestamp: pending.record.timestamp.timeIntervalSince1970,
                attachments: attachments.map { $0.makeMedia() })
            let sent = try await hproseInstance.sendMessage(receiptId: recipient, message: message)
            guard sent.success == true else { throw uploadError(sent.errorMsg ?? "Failed to send message") }
            NotificationCenter.default.post(name: .chatMessageSent, object: nil, userInfo: ["message": sent])
        } else if let parentRecord = pending.parent {
            let comment = pending.record.makeTweet()
            let parent = parentRecord.makeTweet()
            // Keep the independent quote request concurrent with add_comment, but
            // structured so expiration cancels both and completion awaits both.
            let quote = pending.isQuoting ? TweetRecord(
                mid: "TEMP_QUOTE_\(UUID().uuidString)", authorId: comment.authorId,
                content: comment.content, timestamp: comment.timestamp,
                originalTweetId: parent.mid, originalAuthorId: parent.authorId,
                parentTweetId: comment.parentTweetId, attachments: attachments) : nil
            async let quoteResult: Void = publishQuoteIfNeeded(quote, original: parent)
            var commentError: Error?
            do {
                guard try await hproseInstance.addComment(comment, to: parent) != nil else {
                    throw uploadError("Failed to post comment")
                }
            } catch { commentError = error }
            // A failed comment must not cancel the independently requested quote.
            try await quoteResult
            if let commentError { throw commentError }
        } else {
            guard let posted = try await hproseInstance.uploadTweet(pending.record.makeTweet()) else {
                throw uploadError("Failed to upload tweet")
            }
            NotificationCenter.default.post(name: .newTweetCreated, object: nil, userInfo: ["tweet": posted])
        }
        // A confirmed publication wins even when cancellation raced the response.
        try await removePendingUpload(pending)
    }

    private func publishQuoteIfNeeded(_ record: TweetRecord?, original: Tweet) async throws {
        guard let record, let hproseInstance else { return }
        try Task.checkCancellation()
        guard let posted = try await hproseInstance.uploadTweet(record.makeTweet()) else {
            throw uploadError("Failed to post tweet. Please refresh before retrying.")
        }
        // Preserve the existing quote count update; this is a separate write.
        if let updated = await hproseInstance.updateRetweetCount(tweet: original, retweetId: posted.mid, direction: true) {
            TweetCacheManager.shared.saveTweet(updated, userId: updated.authorId)
        }
    }

    private func waitForVideoJobs(_ pending: inout PendingTweetUpload) async throws {
        guard let hproseInstance else { throw uploadError("System error") }
        try Task.checkCancellation()
        let rootURL = try await hproseInstance.appUser.resolveWritableUrl()
        guard let host = rootURL.host, hproseInstance.appUser.cloudDrivePort > 0,
              let pollURL = URL(string: "http://\(host):\(hproseInstance.appUser.cloudDrivePort)") else {
            throw uploadError("Failed to check video status")
        }
        let jobIndices = pending.itemData.indices.filter { pending.itemData[$0].videoJobId != nil }
        var fractions = Dictionary(uniqueKeysWithValues: jobIndices.map { ($0, 0.0) })
        for _ in 0..<120 {
            try Task.checkCancellation()
            for index in jobIndices {
                guard let jobId = pending.itemData[index].videoJobId else { continue }
                let status = await checkVideoJobStatus(jobId: jobId, baseURL: pollURL)
                try Task.checkCancellation()
                // A missed response is not a failed conversion. Leave its receipt
                // intact and try the next scheduled poll without an alert.
                guard let status else { continue }
                if status.status == "failed" { throw uploadError("Video processing failed") }
                fractions[index] = max(fractions[index] ?? 0, Double(min(max(status.progress, 0), 100)) / 100)
                if status.status == "completed" {
                    guard let cid = status.cid, !cid.isEmpty else {
                        throw uploadError("Video processing completed but no ID returned")
                    }
                    let item = pending.itemData[index]
                    pending.itemData[index] = PendingTweetUpload.ItemData(
                        identifier: item.identifier, typeIdentifier: item.typeIdentifier, data: item.data,
                        fileName: item.fileName, noResample: item.noResample, cid: cid,
                        aspectRatio: item.aspectRatio, fileSize: item.fileSize, mediaType: item.mediaType)
                    fractions[index] = 1
                    try await savePendingUpload(pending)
                }
            }
            UploadProgressManager.shared.updateProgress(stage: .uploadingAttachments,
                message: NSLocalizedString("Processing on server...", comment: "Upload stage"),
                progress: 0.75 + 0.19 * fractions.values.reduce(0, +) / Double(jobIndices.count))
            if !pending.itemData.contains(where: { $0.videoJobId != nil }) { return }
            try await Task.sleep(for: .seconds(5))
        }
        throw uploadError("Video processing timed out")
    }

    private func uploadError(_ message: String) -> NSError {
        NSError(domain: "TweetUpload", code: -1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(message, comment: "Upload error")])
    }

    // Pending data contains only Sendable records. Encoding and disk I/O stay
    // off the main actor, and each operation has its own atomic checkpoint.
    func savePendingUpload(_ pending: PendingTweetUpload) async throws {
        try await Task.detached(priority: .utility) {
            let directory = Self.pendingDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var directoryURL = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directoryURL.setResourceValues(values)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            try encoder.encode(pending).write(to: Self.pendingURL(pending),
                                             options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }.value
    }

    func removePendingUpload(_ pending: PendingTweetUpload) async throws {
        try await Task.detached(priority: .utility) {
            let url = Self.pendingURL(pending)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }.value
    }

    func pendingUploads() async throws -> [PendingTweetUpload] {
        try await Task.detached(priority: .utility) {
            let directory = Self.pendingDirectory
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            var uploads: [PendingTweetUpload] = []
            if FileManager.default.fileExists(atPath: directory.path) {
                uploads = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }
                    .map { try decoder.decode(PendingTweetUpload.self, from: Data(contentsOf: $0)) }
            }
            // Keep the previous version's valid pending file available for an
            // explicit Retry/Discard. Merely opening the app never rewrites it.
            if FileManager.default.fileExists(atPath: Self.legacyPendingURL.path) {
                let data = try Data(contentsOf: Self.legacyPendingURL)
                let keys = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if keys?["record"] != nil {
                    uploads.append(try decoder.decode(PendingTweetUpload.self, from: data))
                } else {
                    let legacy = try decoder.decode(LegacyPendingUpload.self, from: data)
                    var pending = PendingTweetUpload(record: legacy.tweet, itemData: legacy.itemData,
                                                     retryCount: legacy.retryCount, videoJobId: legacy.videoJobId)
                    pending.usesLegacyFile = true
                    // Old checkpoints did not record whether publication began.
                    pending.publicationAttempted = true
                    uploads.append(pending)
                }
            }
            return uploads.sorted { $0.timestamp < $1.timestamp }
        }.value
    }

    private struct LegacyPendingUpload: Decodable {
        let tweet: TweetRecord
        let itemData: [PendingTweetUpload.ItemData]
        let retryCount: Int
        let videoJobId: String?
    }

    nonisolated private static var legacyPendingURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pendingTweetUpload.json")
    }

    nonisolated private static func pendingURL(_ pending: PendingTweetUpload) -> URL {
        pending.usesLegacyFile == true ? legacyPendingURL :
            pendingDirectory.appendingPathComponent(pending.id.uuidString + ".json")
    }

    nonisolated private static var pendingDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingUploads", isDirectory: true)
    }
}

// MARK: - Video Job Status Management
extension TweetUploadManager {
    
    private func checkVideoJobStatus(jobId: String, baseURL: URL?) async -> VideoConversionStatus? {
        guard let baseURL = baseURL else { return nil }
        
        let statusURL = baseURL.appendingPathComponent("process-zip/status/\(jobId)")
        print("DEBUG: Checking video job status at: \(statusURL)")
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        
        do {
            let (responseData, response) = try await session.data(from: statusURL)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    return try parseVideoStatusResponse(responseData: responseData)
                } else if httpResponse.statusCode == 404 {
                    print("DEBUG: Video job not found: \(jobId)")
                    return nil
                } else {
                    print("DEBUG: Video job status check failed with HTTP \(httpResponse.statusCode)")
                    return nil
                }
            }
        } catch {
            print("DEBUG: Video job status check error: \(error)")
        }
        
        return nil
    }
    
    private func parseVideoStatusResponse(responseData: Data) throws -> VideoConversionStatus {
        guard let responseString = String(data: responseData, encoding: .utf8) else {
            throw NSError(domain: "TweetUploadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response encoding"])
        }
        
        guard let jsonData = responseString.data(using: .utf8) else {
            throw NSError(domain: "TweetUploadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert response to data"])
        }
        
        let json = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any]
        
        let status = json?["status"] as? String ?? "unknown"
        let progress = json?["progress"] as? Int ?? 0
        let message = json?["message"] as? String
        let cid = json?["cid"] as? String
        
        return VideoConversionStatus(
            status: status,
            progress: progress,
            message: message,
            cid: cid
        )
    }
    
}

// Values only: safe to encode and save away from the main actor.
extension TweetUploadManager {
    struct PendingTweetUpload: Codable, Sendable {
        let id: UUID
        var record: TweetRecord
        var itemData: [ItemData]
        let timestamp: Date
        let retryCount: Int
        let videoJobId: String?
        var parent: TweetRecord?
        var isQuoting: Bool
        var recipientId: String?
        var chatSessionId: String?
        var publicationAttempted: Bool
        var usesLegacyFile: Bool?

        @MainActor var tweet: Tweet { record.makeTweet() }
        var type: String { recipientId != nil ? "chat" : (parent != nil ? "comment" : "tweet") }
        var hasVideos: Bool { itemData.contains { Self.isVideo($0.typeIdentifier) } }
        private static func isVideo(_ type: String) -> Bool {
            let value = type.lowercased()
            return ["video", "movie", "quicktime", "mpeg", "mp4", "m4v", "mov", "avi", "mkv", "webm"].contains { value.contains($0) }
        }

        @MainActor
        init(tweet: Tweet, itemData: [ItemData], retryCount: Int = 0, videoJobId: String? = nil,
             parent: TweetRecord? = nil, isQuoting: Bool = false) {
            self.init(record: TweetRecord(tweet: tweet), itemData: itemData, retryCount: retryCount,
                      videoJobId: videoJobId, parent: parent, isQuoting: isQuoting)
        }

        init(record: TweetRecord, itemData: [ItemData], retryCount: Int = 0, videoJobId: String? = nil,
             parent: TweetRecord? = nil, isQuoting: Bool = false) {
            id = UUID()
            self.record = record
            self.itemData = itemData
            timestamp = Date()
            self.retryCount = retryCount
            self.videoJobId = videoJobId
            self.parent = parent
            self.isQuoting = isQuoting
            publicationAttempted = false
        }

        struct ItemData: Codable, Sendable {
            let identifier: String
            let typeIdentifier: String
            let data: Data
            let fileName: String
            let noResample: Bool
            let videoJobId: String? // Per-item job ID for video processing
            let cid: String? // Actual CID after upload (for both videos and images)
            let aspectRatio: Float? // Aspect ratio
            let fileSize: Int64? // File size
            let mediaType: String? // MediaType (Image, Video, hls_video, etc.)
            
            init(identifier: String, typeIdentifier: String, data: Data, fileName: String, noResample: Bool = false, videoJobId: String? = nil, cid: String? = nil, aspectRatio: Float? = nil, fileSize: Int64? = nil, mediaType: String? = nil) {
                self.identifier = identifier
                self.typeIdentifier = typeIdentifier
                self.data = data
                self.fileName = fileName
                self.noResample = noResample
                self.videoJobId = videoJobId
                self.cid = cid
                self.aspectRatio = aspectRatio
                self.fileSize = fileSize
                self.mediaType = mediaType
            }
        }
        
    }
}

// MARK: - Array Extension
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
