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
import ffmpegkit

// MARK: - Video Conversion Status
struct VideoConversionStatus {
    let status: String
    let progress: Int
    let message: String?
    let cid: String?
}

/// Manager class for handling all tweet and media uploads
class TweetUploadManager {
    // Reference to parent HproseInstance for accessing shared properties
    weak var hproseInstance: HproseInstance?
    
    init(hproseInstance: HproseInstance) {
        self.hproseInstance = hproseInstance
    }
    
    // MARK: - Public Upload Methods
    
    /// Upload data to IPFS with appropriate media processing
    func uploadToIPFS(
        data: Data,
        typeIdentifier: String,
        fileName: String? = nil,
        referenceId: String? = nil,
        noResample: Bool = false,
        progressCallback: ((String, Int) -> Void)? = nil
    ) async throws -> (MimeiFileType?, String?) {
        guard let hproseInstance = hproseInstance else {
            throw NSError(domain: "TweetUploadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "HproseInstance not available"])
        }
        
        _ = try await hproseInstance.appUser.resolveWritableUrl()
        print("Starting upload to IPFS: typeIdentifier=\(typeIdentifier), fileName=\(fileName ?? "nil"), noResample=\(noResample)")
        
        // Use MediaProcessor to determine media type and handle upload
        let mediaProcessor = HproseInstance.MediaProcessor()
        return try await mediaProcessor.processAndUpload(
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
    
    /// Schedule a tweet upload with persistence and retry
    func scheduleTweetUpload(tweet: Tweet, itemData: [PendingTweetUpload.ItemData]) {
        Task.detached(priority: .background) {
            await self.uploadTweetWithPersistenceAndRetry(tweet: tweet, itemData: itemData)
        }
    }
    
    /// Schedule a chat message upload
    func scheduleChatMessageUpload(message: ChatMessage, itemData: [PendingTweetUpload.ItemData]) {
        Task.detached(priority: .background) {
            var mutableMessage = message
            await self.uploadChatMessageWithPersistenceAndRetry(message: &mutableMessage, itemData: itemData)
        }
    }
    
    /// Schedule a comment upload
    func scheduleCommentUpload(
        comment: Tweet,
        to tweet: Tweet,
        itemData: [PendingTweetUpload.ItemData]
    ) {
        Task.detached(priority: .background) {
            do {
                guard let hproseInstance = self.hproseInstance else { return }
                
                let comment = comment
                var uploadedAttachments: [MimeiFileType] = []
                
                let itemPairs = itemData.chunked(into: 2)
                for (pairIndex, pair) in itemPairs.enumerated() {
                    do {
                        let pairAttachments = try await self.uploadItemPair(pair)
                        uploadedAttachments.append(contentsOf: pairAttachments)
                    } catch {
                        print("Error uploading pair \(pairIndex + 1): \(error)")
                        await MainActor.run {
                            if !hproseInstance.isAppInitializing {
                                NotificationCenter.default.post(
                                    name: .backgroundUploadFailed,
                                    object: nil,
                                    userInfo: ["error": error]
                                )
                            } else {
                                print("DEBUG: Skipping background upload error dialog during app initialization: \(error)")
                            }
                        }
                        return
                    }
                }
                
                if itemData.count != uploadedAttachments.count {
                    let error = NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to upload attachment", comment: "Attachment upload error")])
                    await MainActor.run {
                        if !hproseInstance.isAppInitializing {
                            NotificationCenter.default.post(
                                name: .backgroundUploadFailed,
                                object: nil,
                                userInfo: ["error": error]
                            )
                        } else {
                            print("DEBUG: Skipping background upload error dialog during app initialization: \(error)")
                        }
                    }
                    return
                }
                
                comment.attachments = uploadedAttachments
                
                if let newComment = try await hproseInstance.addComment(comment, to: tweet) {
                    await MainActor.run {
                        print("[TweetUploadManager] Comment upload completed successfully")
                        print("[TweetUploadManager] New comment mid: \(newComment.mid)")
                        print("[TweetUploadManager] Parent tweet mid: \(tweet.mid)")
                    }
                } else {
                    let error = NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to post comment", comment: "Comment error")])
                    await MainActor.run {
                        if !hproseInstance.isAppInitializing {
                            NotificationCenter.default.post(
                                name: .backgroundUploadFailed,
                                object: nil,
                                userInfo: ["error": error]
                            )
                        } else {
                            print("DEBUG: Skipping background upload error dialog during app initialization: \(error)")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    guard let hproseInstance = self.hproseInstance else { return }
                    if !hproseInstance.isAppInitializing {
                        NotificationCenter.default.post(
                            name: .backgroundUploadFailed,
                            object: nil,
                            userInfo: ["error": error.localizedDescription]
                        )
                    } else {
                        print("DEBUG: Skipping background upload error dialog during app initialization: \(error)")
                    }
                }
            }
        }
    }
    
    /// Recover any pending uploads from disk
    func recoverPendingUploads() async {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("pendingTweetUpload.json")
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("DEBUG: No pending upload file found")
            return
        }
        
        guard let hproseInstance = hproseInstance else { return }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let pendingUpload = try JSONDecoder().decode(PendingTweetUpload.self, from: data)
            
            // Check if the pending upload is not too old (e.g., within 24 hours)
            let maxAge: TimeInterval = 24 * 60 * 60 // 24 hours
            if Date().timeIntervalSince(pendingUpload.timestamp) < maxAge {
                print("DEBUG: Found valid pending upload from \(pendingUpload.timestamp), attempting recovery...")
                print("Recovering pending upload from \(pendingUpload.timestamp)")
                
                // Check if we have video job IDs to check first
                if let videoJobId = pendingUpload.videoJobId {
                    print("DEBUG: Found video job ID: \(videoJobId), checking status...")
                    
                    // Get base URL for status checking
                    _ = try? await hproseInstance.appUser.resolveWritableUrl()
                    let originalBaseURL = hproseInstance.appUser.writableUrl?.deletingLastPathComponent()
                    
                    // Get host - must succeed
                    guard let host = originalBaseURL?.host else {
                        print("ERROR: No host available for video job status check")
                        try? FileManager.default.removeItem(at: fileURL)
                        return
                    }
                    
                    // Get cloud drive port - must be configured
                    guard let cloudPort = hproseInstance.appUser.cloudDrivePort, cloudPort > 0 else {
                        print("ERROR: Cloud drive port not configured for video job status check")
                        try? FileManager.default.removeItem(at: fileURL)
                        return
                    }
                    
                    guard let baseURL = URL(string: "http://\(host):\(cloudPort)") else {
                        print("ERROR: Failed to construct cloud drive URL")
                        try? FileManager.default.removeItem(at: fileURL)
                        return
                    }
                    
                    if let status = await checkVideoJobStatus(jobId: videoJobId, baseURL: baseURL) {
                        switch status.status {
                        case "completed":
                            print("DEBUG: Video job completed while app was backgrounded, CID: \(status.cid ?? "unknown")")
                            await handleCompletedVideoJob(pendingUpload: pendingUpload, cid: status.cid)
                            return
                            
                        case "failed":
                            print("DEBUG: Video job failed: \(status.message ?? "Unknown error")")
                            
                        case "uploading", "processing":
                            print("DEBUG: Video job still in progress, resuming polling...")
                            await resumeVideoJobPolling(pendingUpload: pendingUpload, jobId: videoJobId)
                            return
                            
                        default:
                            print("DEBUG: Unknown video job status: \(status.status)")
                        }
                    } else {
                        print("DEBUG: Could not check video job status, job may have expired")
                    }
                }
                
                // Increment retry count for the next attempt
                let newRetryCount = pendingUpload.retryCount + 1
                let maxBackgroundRetries = 2
                
                print("DEBUG: Background retry attempt \(newRetryCount)/\(maxBackgroundRetries)")
                
                if newRetryCount > maxBackgroundRetries {
                    print("DEBUG: Max retries exceeded, removing pending upload without retrying")
                    try? FileManager.default.removeItem(at: fileURL)
                    return
                }
                
                // Show toast message for retry attempt
                await MainActor.run {
                    let retryMessage = String(format: NSLocalizedString("Upload failed, retrying... (attempt %d of %d)", comment: "Background upload retry message"), newRetryCount, maxBackgroundRetries)
                    NotificationCenter.default.post(
                        name: .backgroundUploadRetrying,
                        object: nil,
                        userInfo: ["message": retryMessage]
                    )
                }
                
                // Add delay before background retry
                let delay = UInt64(newRetryCount) * 2_000_000_000
                print("DEBUG: Background retry delay: \(delay / 1_000_000_000) seconds")
                try? await Task.sleep(nanoseconds: delay)
                
                await uploadTweetWithPersistenceAndRetry(
                    tweet: pendingUpload.tweet,
                    itemData: pendingUpload.itemData,
                    retryCount: newRetryCount,
                    videoJobId: pendingUpload.videoJobId
                )
            } else {
                // Remove old pending upload
                try? FileManager.default.removeItem(at: fileURL)
                print("Removed old pending upload from \(pendingUpload.timestamp)")
            }
        } catch {
            print("DEBUG: Failed to recover pending upload: \(error)")
            // Remove corrupted file
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
    
    /// Clean up problematic pending uploads during initialization
    func cleanupProblematicPendingUploads() async {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("pendingTweetUpload.json")
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let pendingUpload = try JSONDecoder().decode(PendingTweetUpload.self, from: data)
            
            let maxAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days
            let isTooOld = Date().timeIntervalSince(pendingUpload.timestamp) > maxAge
            let hasTooManyRetries = pendingUpload.retryCount >= 2
            
            if isTooOld || hasTooManyRetries {
                print("DEBUG: Cleaning up problematic pending upload (age: \(Date().timeIntervalSince(pendingUpload.timestamp))s, retries: \(pendingUpload.retryCount))")
                try FileManager.default.removeItem(at: fileURL)
                print("DEBUG: Removed problematic pending upload file")
            }
        } catch {
            print("DEBUG: Failed to check/cleanup pending upload: \(error)")
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

// MARK: - Private Upload Implementation
extension TweetUploadManager {
    
    private func uploadTweetWithPersistenceAndRetry(
        tweet: Tweet,
        itemData: [PendingTweetUpload.ItemData],
        retryCount: Int = 0,
        videoJobId: String? = nil
    ) async {
        print("DEBUG: [uploadTweetWithPersistenceAndRetry] Starting upload with retry count: \(retryCount)")
        
        guard let hproseInstance = hproseInstance else { return }
        
        // Save pending upload to disk
        let pendingUpload = PendingTweetUpload(tweet: tweet, itemData: itemData, retryCount: retryCount, videoJobId: videoJobId)
        await savePendingUpload(pendingUpload)
        
        do {
            // Upload attachments first
            let (uploadedAttachments, _) = try await uploadAttachments(itemData: itemData)
            
            // Update tweet with uploaded attachments
            tweet.attachments = uploadedAttachments
            
            // Upload the tweet
            if let uploadedTweet = try await hproseInstance.uploadTweet(tweet) {
                // Success - remove pending upload and notify
                await removePendingUpload()
                
                await MainActor.run {
                    hproseInstance.appUser.tweetCount = (hproseInstance.appUser.tweetCount ?? 0) + 1
                    NotificationCenter.default.post(
                        name: .newTweetCreated,
                        object: nil,
                        userInfo: ["tweet": uploadedTweet]
                    )
                }
            } else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to upload tweet", comment: "Tweet upload error")])
            }
        } catch {
            print("Error uploading tweet: \(error)")
            
            let maxRetries = 2
            print("DEBUG: [Error handling] retryCount=\(retryCount), maxRetries=\(maxRetries)")
            
            if retryCount >= maxRetries {
                print("DEBUG: [Error handling] MAX RETRIES REACHED - Showing error and removing pending upload")
                let userFriendlyMessage = NSLocalizedString("Failed to upload tweet. Please try again.", comment: "Tweet upload failed error")
                
                await MainActor.run {
                    if !hproseInstance.isAppInitializing {
                        NotificationCenter.default.post(
                            name: .backgroundUploadFailed,
                            object: nil,
                            userInfo: ["error": userFriendlyMessage]
                        )
                    }
                }
                
                await removePendingUpload()
            } else {
                print("DEBUG: [Error handling] Scheduling background retry \(retryCount + 1)")
                
                let delay = UInt64(retryCount + 1) * 2_000_000_000
                Task.detached(priority: .background) {
                    try? await Task.sleep(nanoseconds: delay)
                    await self.uploadTweetWithPersistenceAndRetry(tweet: tweet, itemData: itemData, retryCount: retryCount + 1)
                }
            }
        }
    }
    
    private func uploadChatMessageWithPersistenceAndRetry(
        message: inout ChatMessage,
        itemData: [PendingTweetUpload.ItemData],
        retryCount: Int = 0
    ) async {
        guard let hproseInstance = hproseInstance else { return }
        
        do {
            let (uploadedAttachments, _) = try await uploadAttachments(itemData: itemData)
            message.attachments = uploadedAttachments
            
            let resultMessage = try await hproseInstance.sendMessage(receiptId: message.receiptId, message: message)
            
            if resultMessage.success == true {
                print("Chat message sent successfully: \(resultMessage.id)")
            } else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: resultMessage.errorMsg ?? "Failed to send chat message"])
            }
        } catch {
            print("Error uploading chat message: \(error)")
            print(NSLocalizedString("Chat message upload failed", comment: "Chat upload error"))
        }
    }
    
    private func uploadAttachments(itemData: [PendingTweetUpload.ItemData]) async throws -> ([MimeiFileType], String?) {
        var uploadedAttachments: [MimeiFileType] = []
        var videoJobId: String? = nil
        
        let hasVideoItems = itemData.contains { item in
            item.typeIdentifier.contains("video") || item.typeIdentifier.contains("movie")
        }
        
        if hasVideoItems {
            for item in itemData {
                do {
                    let (result, jobId) = try await uploadToIPFS(
                        data: item.data,
                        typeIdentifier: item.typeIdentifier,
                        fileName: item.fileName,
                        noResample: item.noResample,
                        progressCallback: { message, progress in
                            print("DEBUG: Upload progress for \(item.fileName): \(message) (\(progress)%)")
                        }
                    )
                    
                    if let fileType = result {
                        uploadedAttachments.append(fileType)
                    }
                    
                    if let jobId = jobId {
                        videoJobId = jobId
                        print("DEBUG: Stored video job ID: \(jobId)")
                    }
                } catch {
                    print("Error uploading item \(item.fileName): \(error)")
                    throw error
                }
            }
        } else {
            let itemPairs = itemData.chunked(into: 2)
            
            for (pairIndex, pair) in itemPairs.enumerated() {
                do {
                    let pairAttachments = try await self.uploadItemPair(pair)
                    uploadedAttachments.append(contentsOf: pairAttachments)
                } catch {
                    print("Error uploading pair \(pairIndex + 1): \(error)")
                    throw error
                }
            }
        }
        
        if itemData.count != uploadedAttachments.count {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to upload attachment", comment: "Attachment upload error")])
        }
        
        return (uploadedAttachments, videoJobId)
    }
    
    private func uploadItemPair(_ pair: [PendingTweetUpload.ItemData]) async throws -> [MimeiFileType] {
        let uploadTasks = pair.map { itemData in
            Task {
                let (result, _) = try await uploadToIPFS(
                    data: itemData.data,
                    typeIdentifier: itemData.typeIdentifier,
                    fileName: itemData.fileName,
                    noResample: itemData.noResample,
                    progressCallback: { message, progress in
                        print("DEBUG: Upload progress for \(itemData.fileName): \(message) (\(progress)%)")
                    }
                )
                return result
            }
        }
        
        return try await withThrowingTaskGroup(of: MimeiFileType?.self) { group in
            for task in uploadTasks {
                group.addTask {
                    return try await task.value
                }
            }
            
            var uploadResults: [MimeiFileType?] = []
            for try await result in group {
                uploadResults.append(result)
            }
            
            if uploadResults.contains(where: { $0 == nil }) {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to upload attachment", comment: "Attachment upload error")])
            }
            
            return uploadResults.compactMap { $0 }
        }
    }
    
    private func savePendingUpload(_ pendingUpload: PendingTweetUpload) async {
        do {
            let data = try JSONEncoder().encode(pendingUpload)
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("pendingTweetUpload.json")
            try data.write(to: fileURL)
            print("Saved pending upload to disk")
        } catch {
            print("Failed to save pending upload: \(error)")
        }
    }
    
    private func removePendingUpload() async {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("pendingTweetUpload.json")
        try? FileManager.default.removeItem(at: fileURL)
        print("Removed pending upload from disk")
    }
}

// MARK: - Video Job Status Management
extension TweetUploadManager {
    
    private func checkVideoJobStatus(jobId: String, baseURL: URL?) async -> VideoConversionStatus? {
        guard let baseURL = baseURL else { return nil }
        
        let statusURL = baseURL.appendingPathComponent("convert-video/status/\(jobId)")
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
    
    private func handleCompletedVideoJob(pendingUpload: PendingTweetUpload, cid: String?) async {
        guard let cid = cid, !cid.isEmpty else {
            print("DEBUG: No CID available for completed video job")
            await uploadTweetWithPersistenceAndRetry(
                tweet: pendingUpload.tweet,
                itemData: pendingUpload.itemData,
                retryCount: pendingUpload.retryCount,
                videoJobId: pendingUpload.videoJobId
            )
            return
        }
        
        guard let hproseInstance = hproseInstance else { return }
        
        var uploadedAttachments: [MimeiFileType] = []
        var hasVideoItem = false
        
        for item in pendingUpload.itemData {
            if item.typeIdentifier.contains("video") || item.typeIdentifier.contains("movie") {
                hasVideoItem = true
                
                var aspectRatio: Float?
                do {
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
                    try item.data.write(to: tempURL)
                    aspectRatio = try await HLSVideoProcessor.shared.getVideoAspectRatio(filePath: tempURL.path)
                    try? FileManager.default.removeItem(at: tempURL)
                } catch {
                    print("DEBUG: Could not determine video aspect ratio: \(error), using default 16:9")
                    aspectRatio = 16.0 / 9.0
                }
                
                let currentDate = Date()
                let videoFile = MimeiFileType(
                    mid: cid,
                    mediaType: .hls_video,
                    size: Int64(item.data.count),
                    fileName: item.fileName,
                    timestamp: currentDate,
                    aspectRatio: aspectRatio,
                    url: nil
                )
                uploadedAttachments.append(videoFile)
            } else {
                do {
                    let (result, _) = try await uploadToIPFS(
                        data: item.data,
                        typeIdentifier: item.typeIdentifier,
                        fileName: item.fileName,
                        noResample: item.noResample,
                        progressCallback: { message, progress in
                            print("DEBUG: Upload progress for \(item.fileName): \(message) (\(progress)%)")
                        }
                    )
                    if let fileType = result {
                        uploadedAttachments.append(fileType)
                    }
                } catch {
                    print("Error uploading non-video item \(item.fileName): \(error)")
                    await uploadTweetWithPersistenceAndRetry(
                        tweet: pendingUpload.tweet,
                        itemData: pendingUpload.itemData,
                        retryCount: pendingUpload.retryCount,
                        videoJobId: pendingUpload.videoJobId
                    )
                    return
                }
            }
        }
        
        if hasVideoItem && uploadedAttachments.count == pendingUpload.itemData.count {
            pendingUpload.tweet.attachments = uploadedAttachments
            
            do {
                if let uploadedTweet = try await hproseInstance.uploadTweet(pendingUpload.tweet) {
                    await removePendingUpload()
                    
                    await MainActor.run {
                        hproseInstance.appUser.tweetCount = (hproseInstance.appUser.tweetCount ?? 0) + 1
                        NotificationCenter.default.post(
                            name: .newTweetCreated,
                            object: nil,
                            userInfo: ["tweet": uploadedTweet]
                        )
                    }
                } else {
                    throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to upload tweet", comment: "Tweet upload error")])
                }
            } catch {
                print("Error uploading tweet: \(error)")
                
                await MainActor.run {
                    if !hproseInstance.isAppInitializing {
                        NotificationCenter.default.post(
                            name: .backgroundUploadFailed,
                            object: nil,
                            userInfo: ["error": error.localizedDescription]
                        )
                    }
                }
            }
        } else {
            print("DEBUG: No video item found or attachment count mismatch")
            await uploadTweetWithPersistenceAndRetry(
                tweet: pendingUpload.tweet,
                itemData: pendingUpload.itemData,
                retryCount: pendingUpload.retryCount,
                videoJobId: pendingUpload.videoJobId
            )
        }
    }
    
    private func resumeVideoJobPolling(pendingUpload: PendingTweetUpload, jobId: String) async {
        print("DEBUG: Resuming video job polling for job ID: \(jobId)")
        
        guard let hproseInstance = hproseInstance else { return }
        
        _ = try? await hproseInstance.appUser.resolveWritableUrl()
        let originalBaseURL = hproseInstance.appUser.writableUrl?.deletingLastPathComponent()
        
        // Get host - must succeed
        guard let host = originalBaseURL?.host else {
            print("ERROR: No host available for video job polling")
            return
        }
        
        // Get cloud drive port - must be configured
        guard let cloudPort = hproseInstance.appUser.cloudDrivePort, cloudPort > 0 else {
            print("ERROR: Cloud drive port not configured for video job polling")
            return
        }
        
        guard let baseURL = URL(string: "http://\(host):\(cloudPort)") else {
            print("ERROR: Failed to construct cloud drive URL")
            return
        }
        
        guard let videoItem = pendingUpload.itemData.first(where: {
            $0.typeIdentifier.contains("video") || $0.typeIdentifier.contains("movie")
        }) else {
            print("DEBUG: No video item found for polling resume")
            return
        }
        
        do {
            let mediaProcessor = HproseInstance.MediaProcessor()
            let result = try await mediaProcessor.pollVideoConversionStatus(
                jobId: jobId,
                baseURL: baseURL,
                data: videoItem.data,
                fileName: videoItem.fileName,
                aspectRatio: nil as Float?,
                progressCallback: { message, progress in
                    print("DEBUG: Resume polling progress: \(message) (\(progress)%)")
                }
            )
            
            if let completedVideo = result {
                print("DEBUG: Video job completed during resume polling, CID: \(completedVideo.mid)")
                
                var updatedItemData = pendingUpload.itemData
                for (index, item) in updatedItemData.enumerated() {
                    if item.identifier == videoItem.identifier {
                        updatedItemData[index] = PendingTweetUpload.ItemData(
                            identifier: item.identifier,
                            typeIdentifier: item.typeIdentifier,
                            data: item.data,
                            fileName: item.fileName,
                            noResample: item.noResample,
                            videoJobId: nil
                        )
                        break
                    }
                }
                
                await uploadTweetWithPersistenceAndRetry(
                    tweet: pendingUpload.tweet,
                    itemData: updatedItemData,
                    retryCount: pendingUpload.retryCount,
                    videoJobId: nil
                )
            }
        } catch {
            print("DEBUG: Resume polling failed: \(error)")
            await uploadTweetWithPersistenceAndRetry(
                tweet: pendingUpload.tweet,
                itemData: pendingUpload.itemData,
                retryCount: pendingUpload.retryCount,
                videoJobId: pendingUpload.videoJobId
            )
        }
    }
}

// MARK: - Pending Tweet Upload Structure
extension TweetUploadManager {
    struct PendingTweetUpload: Codable {
        let tweet: Tweet
        let itemData: [ItemData]
        let timestamp: Date
        let retryCount: Int
        let videoJobId: String?
        
        struct ItemData: Codable {
        let identifier: String
        let typeIdentifier: String
        let data: Data
        let fileName: String
        let noResample: Bool
        let videoJobId: String?
        
        init(identifier: String, typeIdentifier: String, data: Data, fileName: String, noResample: Bool = false, videoJobId: String? = nil) {
            self.identifier = identifier
            self.typeIdentifier = typeIdentifier
            self.data = data
            self.fileName = fileName
            self.noResample = noResample
            self.videoJobId = videoJobId
        }
    }
    
        init(tweet: Tweet, itemData: [ItemData], retryCount: Int = 0, videoJobId: String? = nil) {
            self.tweet = tweet
            self.itemData = itemData
            self.timestamp = Date(timeIntervalSince1970: Date().timeIntervalSince1970)
            self.retryCount = retryCount
            self.videoJobId = videoJobId
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
