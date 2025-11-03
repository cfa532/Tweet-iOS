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
            // Note: Upload dialog is already shown by the caller (ComposeTweetView)
            // before prepareItemData, so we don't call startUpload here
            await self.uploadTweetWithPersistenceAndRetry(tweet: tweet, itemData: itemData)
        }
    }
    
    /// Schedule a chat message upload
    func scheduleChatMessageUpload(message: ChatMessage, itemData: [PendingTweetUpload.ItemData]) {
        Task.detached(priority: .background) {
            // Start progress tracking on main thread
            await MainActor.run {
                UploadProgressManager.shared.startUpload(type: "chat")
            }
            await self.uploadChatMessageWithPersistenceAndRetry(message: message, itemData: itemData)
        }
    }
    
    /// Schedule a comment upload
    func scheduleCommentUpload(
        comment: Tweet,
        to tweet: Tweet,
        itemData: [PendingTweetUpload.ItemData],
        isQuoting: Bool = false
    ) {
        Task.detached(priority: .background) {
            // Start progress tracking on main thread
            await MainActor.run {
                UploadProgressManager.shared.startUpload(type: "comment")
            }
            
            do {                
                // Update progress: uploading attachments
                await MainActor.run {
                    UploadProgressManager.shared.updateProgress(
                        stage: .uploadingAttachments,
                        message: NSLocalizedString("Uploading attachments...", comment: "Upload stage"),
                        progress: 0.2
                    )
                }
                
                // Upload attachments (same as tweet upload)
                let (uploadedAttachments, jobIdMap) = try await self.uploadAttachments(itemData: itemData)
                
                // If we got any video job IDs, handle the same way as tweet uploads
                if !jobIdMap.isEmpty {
                    print("✅ [Comment Upload] Got \(jobIdMap.count) video job ID(s). Closing dialog and polling in background...")
                    
                    // Update itemData with job IDs for polling
                    var updatedItemData = itemData
                    for (index, item) in updatedItemData.enumerated() {
                        if index < uploadedAttachments.count {
                            let attachment = uploadedAttachments[index]
                            let jobId = jobIdMap[item.identifier]
                            
                            updatedItemData[index] = PendingTweetUpload.ItemData(
                                identifier: item.identifier,
                                typeIdentifier: item.typeIdentifier,
                                data: item.data,
                                fileName: item.fileName,
                                noResample: item.noResample,
                                videoJobId: jobId,
                                cid: attachment.mid,
                                aspectRatio: attachment.aspectRatio,
                                fileSize: attachment.size,
                                mediaType: attachment.type.rawValue
                            )
                        }
                    }
                    
                    // Close the dialog with message about server processing
                    await MainActor.run {
                        UploadProgressManager.shared.updateProgress(
                            stage: .completed,
                            message: NSLocalizedString("Processing on server...", comment: "Upload stage"),
                            progress: 1.0,
                            detail: NSLocalizedString("Your comment will be posted when ready", comment: "Background processing")
                        )
                    }
                    
                    // Small delay to show message
                    try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
                    
                    await MainActor.run {
                        UploadProgressManager.shared.completeUpload()
                    }
                    
                    // Start background polling for video jobs (same as tweets)
                    Task.detached(priority: .background) {
                        await self.pollVideoJobsAndSubmitComment(
                            comment: comment,
                            to: tweet,
                            itemData: updatedItemData,
                            uploadedAttachments: uploadedAttachments,
                            isQuoting: isQuoting
                        )
                    }
                    
                    return
                }
                
                // No video jobs - images only, close dialog and submit comment in background
                print("✅ [Comment Upload] All image attachments uploaded. Closing dialog and submitting comment in background...")
                
                comment.attachments = uploadedAttachments
                
                // Show completion message
                await MainActor.run {
                    UploadProgressManager.shared.updateProgress(
                        stage: .completed,
                        message: NSLocalizedString("Submitting comment...", comment: "Upload stage"),
                        progress: 1.0,
                        detail: ""
                    )
                }
                
                // Small delay to show message
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                
                // Close dialog
                await MainActor.run {
                    UploadProgressManager.shared.completeUpload()
                }
                
                // Submit comment in background (non-blocking)
                Task.detached(priority: .background) {
                    guard let hproseInstance = self.hproseInstance else { return }
                    
                    print("📝 [Background Submit] Submitting comment with image attachments...")
                    
                    do {
                        if let newComment = try await hproseInstance.addComment(comment, to: tweet) {
                            print("✅ [Background Submit] Comment posted successfully!")
                            print("[TweetUploadManager] New comment mid: \(newComment.mid)")
                            print("[TweetUploadManager] Parent tweet mid: \(tweet.mid)")
                            
                            // If quoting, also upload as a new tweet
                            if isQuoting {
                                print("📝 [Quote Tweet] Uploading comment as quote tweet...")
                                newComment.originalTweetId = tweet.mid
                                newComment.originalAuthorId = tweet.authorId
                                if let quoteTweet = try await hproseInstance.uploadTweet(newComment) {
                                    print("✅ [Quote Tweet] Quote tweet posted successfully! ID: \(quoteTweet.mid)")
                                    // Update retweet count on the original tweet
                                    do {
                                        try await hproseInstance.updateRetweetCount(tweet: tweet, retweetId: quoteTweet.mid, direction: true)
                                        print("✅ [Quote Tweet] Updated retweet count for original tweet")
                                    } catch {
                                        print("⚠️ [Quote Tweet] Failed to update retweet count: \(error)")
                                    }
                                } else {
                                    print("❌ [Quote Tweet] Failed to post quote tweet")
                                }
                            }
                            // Success notification is posted by addComment()
                        } else {
                            let error = NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to post comment", comment: "Comment error")])
                            await MainActor.run {
                                if !hproseInstance.isAppInitializing {
                                    NotificationCenter.default.post(
                                        name: .backgroundUploadFailed,
                                        object: nil,
                                        userInfo: ["error": error]
                                    )
                                }
                            }
                        }
                    } catch {
                        print("❌ [Background Submit] Failed to post comment: \(error)")
                        await MainActor.run {
                            if !hproseInstance.isAppInitializing {
                                NotificationCenter.default.post(
                                    name: .backgroundUploadFailed,
                                    object: nil,
                                    userInfo: ["error": error]
                                )
                            }
                        }
                    }
                }
            } catch {
                print("❌ [Comment Upload] Failed to upload attachments: \(error)")
                await MainActor.run {
                    UploadProgressManager.shared.failUpload(message: ErrorMessageHelper.userFriendlyMessage(from: error))
                    
                    guard let hproseInstance = self.hproseInstance else { return }
                    if !hproseInstance.isAppInitializing {
                        NotificationCenter.default.post(
                            name: .backgroundUploadFailed,
                            object: nil,
                            userInfo: ["error": error]
                        )
                    }
                }
            }
        }
    }
    
    // REMOVED: recoverPendingUploads() and cleanupProblematicPendingUploads()
    // Pending upload recovery is now handled by ContentView's dialog system
    // which gives users control over retry/discard instead of automatic retry
}

// MARK: - Private Upload Implementation
extension TweetUploadManager {
    
    func uploadTweetWithPersistenceAndRetry(
        tweet: Tweet,
        itemData: [PendingTweetUpload.ItemData],
        retryCount: Int = 0,
        videoJobId: String? = nil
    ) async {
        print("DEBUG: [uploadTweetWithPersistenceAndRetry] Starting upload with retry count: \(retryCount)")
        
        guard let hproseInstance = hproseInstance else {
            await MainActor.run {
                UploadProgressManager.shared.failUpload(message: "System error")
            }
            return
        }
        
        // Save pending upload to disk
        let pendingUpload = PendingTweetUpload(tweet: tweet, itemData: itemData, retryCount: retryCount, videoJobId: videoJobId)
        await savePendingUpload(pendingUpload)
        
        // RETRY LOGIC: Check if any items have job IDs (from previous upload attempt)
        let itemsWithJobIds = itemData.filter { $0.videoJobId != nil }
        
        if !itemsWithJobIds.isEmpty {
            print("📋 [Retry] Found \(itemsWithJobIds.count) item(s) with existing job IDs. Checking server status...")
            
            // Get base URL for polling
            guard let baseURL = try? await hproseInstance.appUser.resolveWritableUrl(),
                  let host = baseURL.host,
                  hproseInstance.appUser.cloudDrivePort > 0,
                  let pollURL = URL(string: "http://\(host):\(hproseInstance.appUser.cloudDrivePort)") else {
                print("❌ [Retry] Cannot construct polling URL")
                await MainActor.run {
                    UploadProgressManager.shared.failUpload(message: "Configuration error")
                }
                await removePendingUpload()
                return
            }
            
            // Update progress: checking job statuses
            await MainActor.run {
                UploadProgressManager.shared.updateProgress(
                    stage: .uploadingAttachments,
                    message: NSLocalizedString("Checking video status...", comment: "Upload stage"),
                    progress: 0.5
                )
            }
            
            // Check status of ALL jobs
            var allCompleted = true
            var anyFailed = false
            var completedCIDs: [String: String] = [:]
            
            for item in itemsWithJobIds {
                guard let jobId = item.videoJobId else { continue }
                
                if let status = await checkVideoJobStatus(jobId: jobId, baseURL: pollURL) {
                    switch status.status {
                    case "completed":
                        if let cid = status.cid, !cid.isEmpty {
                            completedCIDs[jobId] = cid
                            print("✅ [Retry] Job \(jobId) complete, CID: \(cid)")
                        } else {
                            print("❌ [Retry] Job completed but no CID")
                            anyFailed = true
                            break
                        }
                        
                    case "uploading", "processing":
                        allCompleted = false
                        print("⏳ [Retry] Job \(jobId) still processing")
                        
                    case "failed":
                        anyFailed = true
                        print("❌ [Retry] Job \(jobId) failed: \(status.message ?? "Unknown error")")
                        break
                        
                    default:
                        anyFailed = true
                        print("❌ [Retry] Unknown status for job \(jobId): \(status.status)")
                        break
                    }
                } else {
                    anyFailed = true
                    print("❌ [Retry] Cannot check status for job \(jobId)")
                    break
                }
            }
            
            // Handle results
            if anyFailed {
                await MainActor.run {
                    UploadProgressManager.shared.failUpload(message: NSLocalizedString("Video processing failed", comment: "Error"))
                }
                await removePendingUpload()
                return
            } else if allCompleted {
                print("✅ [Retry] ALL jobs completed! Submitting tweet...")
                await submitTweetWithCompletedJobs(
                    tweet: tweet,
                    itemData: itemData,
                    completedCIDs: completedCIDs,
                    uploadedAttachments: [] // Will be built from itemData
                )
                return
            } else {
                print("⏳ [Retry] \(completedCIDs.count)/\(itemsWithJobIds.count) jobs complete. Continuing in background...")
                await MainActor.run {
                    UploadProgressManager.shared.updateProgress(
                        stage: .completed,
                        message: NSLocalizedString("Processing on server...", comment: "Upload stage"),
                        progress: 1.0,
                        detail: NSLocalizedString("Your tweet will be posted when ready", comment: "Background processing")
                    )
                }
                
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                
                await MainActor.run {
                    UploadProgressManager.shared.completeUpload()
                }
                
                // Remove pending upload file - background polling will handle completion
                // This prevents dialog from appearing when user returns from background
                await removePendingUpload()
                
                // Continue polling in background
                Task.detached(priority: .background) {
                    await self.pollAllJobsAndSubmitTweet(
                        tweet: tweet,
                        itemData: itemData,
                        uploadedAttachments: [] // Will be built from itemData
                    )
                }
                return
            }
        }
        
        // NEW UPLOAD: No existing job ID, upload attachments in foreground
        do {
            // Update progress: uploading attachments
            await MainActor.run {
                UploadProgressManager.shared.updateProgress(
                    stage: .uploadingAttachments,
                    message: NSLocalizedString("Uploading attachments...", comment: "Upload stage"),
                    progress: 0.2
                )
            }
            
            // Upload attachments (FOREGROUND ONLY - dialog stays open)
            let (uploadedAttachments, jobIdMap) = try await uploadAttachments(itemData: itemData)
            
            // If we got any video job IDs, update itemData and close dialog
            if !jobIdMap.isEmpty {
                print("✅ [Upload] All attachments uploaded. Got \(jobIdMap.count) job ID(s). Closing dialog and polling in background...")
                
                // Update itemData with job IDs, CIDs, and metadata
                var updatedItemData = itemData
                for (index, item) in updatedItemData.enumerated() {
                    if index < uploadedAttachments.count {
                        let attachment = uploadedAttachments[index]
                        let jobId = jobIdMap[item.identifier]
                        
                        print("📋 [Upload] Storing item \(index + 1): identifier=\(item.identifier), jobId=\(jobId ?? "nil"), cid=\(attachment.mid), aspectRatio=\(attachment.aspectRatio ?? 0), size=\(attachment.size ?? 0)")
                        
                        updatedItemData[index] = PendingTweetUpload.ItemData(
                            identifier: item.identifier,
                            typeIdentifier: item.typeIdentifier,
                            data: item.data,
                            fileName: item.fileName,
                            noResample: item.noResample,
                            videoJobId: jobId,  // Job ID if video, nil if image
                            cid: attachment.mid,  // Actual CID for all items (jobId for videos, real CID for images)
                            aspectRatio: attachment.aspectRatio,  // Preserve aspect ratio
                            fileSize: attachment.size,  // Preserve file size
                            mediaType: attachment.type.rawValue  // Preserve media type
                        )
                    }
                }
                
                print("📊 [Upload] Updated itemData: \(updatedItemData.count) items")
                for (idx, item) in updatedItemData.enumerated() {
                    print("  Item \(idx + 1): videoJobId=\(item.videoJobId ?? "nil"), cid=\(item.cid ?? "nil"), fileName=\(item.fileName)")
                }
                
                // Close the dialog with message about server processing
                await MainActor.run {
                    UploadProgressManager.shared.updateProgress(
                        stage: .completed,
                        message: NSLocalizedString("Processing on server...", comment: "Upload stage"),
                        progress: 1.0,
                        detail: NSLocalizedString("Your tweet will be posted when ready", comment: "Background processing")
                    )
                }
                
                // Small delay to show message
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
                
                await MainActor.run {
                    UploadProgressManager.shared.completeUpload()
                }
                
                // IMPORTANT: Remove pending upload file since we're starting background polling
                // This prevents the dialog from appearing when user returns from background
                await removePendingUpload()
                
                // Start background polling for ALL jobs (non-blocking)
                // If polling fails, it will show toast and won't save pending upload again
                Task.detached(priority: .background) {
                    await self.pollAllJobsAndSubmitTweet(
                        tweet: tweet,
                        itemData: updatedItemData,
                        uploadedAttachments: uploadedAttachments
                    )
                }
                
                return
            }
            
            // No video jobs - images only, close dialog and submit tweet in background
            print("✅ [Upload] All image attachments uploaded. Closing dialog and submitting tweet in background...")
            
            tweet.attachments = uploadedAttachments
            
            // Show completion message briefly
            await MainActor.run {
                UploadProgressManager.shared.updateProgress(
                    stage: .completed,
                    message: NSLocalizedString("Submitting tweet...", comment: "Upload stage"),
                    progress: 1.0,
                    detail: ""
                )
            }
            
            // Small delay to show message
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            // Close dialog
            await MainActor.run {
                UploadProgressManager.shared.completeUpload()
            }
            
            // Remove pending upload file - background submission will handle completion
            await removePendingUpload()
            
            // Submit tweet in background (non-blocking)
            Task.detached(priority: .background) {
                guard let hproseInstance = self.hproseInstance else { return }
                
                print("📝 [Background Submit] Submitting tweet with image attachments...")
                
                // Submit with retry
                var submitRetryCount = 0
                let maxRetries = 2
                
                while submitRetryCount <= maxRetries {
                    do {
                        if let uploadedTweet = try await hproseInstance.uploadTweet(tweet) {
                            // Success! (tweetCount is updated by refreshAppUserFromServer() inside uploadTweet())
                            await MainActor.run {
                                NotificationCenter.default.post(
                                    name: .newTweetCreated,
                                    object: nil,
                                    userInfo: ["tweet": uploadedTweet]
                                )
                            }
                            print("✅ [Background Submit] Tweet posted successfully!")
                            return
                        }
                    } catch {
                        submitRetryCount += 1
                        if submitRetryCount <= maxRetries {
                            print("🔄 [Background Submit] Retry \(submitRetryCount)/\(maxRetries)...")
                            try? await Task.sleep(nanoseconds: UInt64(submitRetryCount) * 2_000_000_000)
                        } else {
                            print("❌ [Background Submit] Max retries reached")
                            await self.showFailureToast(message: NSLocalizedString("Failed to post tweet", comment: "Error"))
                            return
                        }
                    }
                }
            }
            
            return
        } catch {
            print("Error uploading tweet: \(error)")
            
            let maxRetries = 2
            print("DEBUG: [Error handling] retryCount=\(retryCount), maxRetries=\(maxRetries)")
            
            if retryCount >= maxRetries {
                print("DEBUG: [Error handling] MAX RETRIES REACHED - Showing error and removing pending upload")
                let userFriendlyMessage = NSLocalizedString("Failed to upload tweet. Please try again.", comment: "Tweet upload failed error")
                
                await MainActor.run {
                    UploadProgressManager.shared.failUpload(message: userFriendlyMessage)
                    
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
                
                // Don't fail the progress UI on retry
                await MainActor.run {
                    UploadProgressManager.shared.updateProgress(
                        stage: .uploadingAttachments,
                        message: NSLocalizedString("Retrying upload...", comment: "Upload stage"),
                        progress: 0.1
                    )
                }
                
                let delay = UInt64(retryCount + 1) * 2_000_000_000
                Task.detached(priority: .background) {
                    try? await Task.sleep(nanoseconds: delay)
                    await self.uploadTweetWithPersistenceAndRetry(tweet: tweet, itemData: itemData, retryCount: retryCount + 1)
                }
            }
        }
    }
    
    /// Poll for ALL video jobs and auto-submit tweet when ALL are ready
    private func pollAllJobsAndSubmitTweet(
        tweet: Tweet,
        itemData: [PendingTweetUpload.ItemData],
        uploadedAttachments: [MimeiFileType]
    ) async {
        // Extract all job IDs from itemData
        let jobItems = itemData.filter { $0.videoJobId != nil }
        guard !jobItems.isEmpty else {
            print("⚠️ [Background Poll] No job IDs to poll")
            return
        }
        
        print("🔄 [Background Poll] Starting background polling for \(jobItems.count) job(s)")
        
        guard let hproseInstance = hproseInstance else {
            print("❌ [Background Poll] HproseInstance not available")
            return
        }
        
        // Get base URL for polling
        guard let baseURL = try? await hproseInstance.appUser.resolveWritableUrl(),
              let host = baseURL.host,
              hproseInstance.appUser.cloudDrivePort > 0,
              let pollURL = URL(string: "http://\(host):\(hproseInstance.appUser.cloudDrivePort)") else {
            print("❌ [Background Poll] Cannot construct polling URL")
            await showFailureToast(message: NSLocalizedString("Failed to check video status", comment: "Error"))
            await removePendingUpload()
            return
        }
        
        // Track completed job CIDs
        var completedCIDs: [String: String] = [:] // jobId -> CID
        var completedCount = 0
        let totalJobs = jobItems.count
        
        // Poll until all complete or failed
        var pollAttempts = 0
        let maxPollAttempts = 120 // 10 minutes (5 second intervals)
        
        while pollAttempts < maxPollAttempts && completedCount < totalJobs {
            pollAttempts += 1
            
            // Check status of all pending jobs
            for jobItem in jobItems {
                guard let jobId = jobItem.videoJobId else { continue }
                
                // Skip already completed jobs
                if completedCIDs[jobId] != nil {
                    continue
                }
                
                if let status = await checkVideoJobStatus(jobId: jobId, baseURL: pollURL) {
                    switch status.status {
                    case "completed":
                        if let cid = status.cid, !cid.isEmpty {
                            completedCIDs[jobId] = cid
                            completedCount += 1
                            print("✅ [Background Poll] Job \(completedCount)/\(totalJobs) complete! Job: \(jobId), CID: \(cid)")
                        } else {
                            print("❌ [Background Poll] Job completed but no CID returned")
                            await showFailureToast(message: NSLocalizedString("Video processing completed but no ID returned", comment: "Error"))
                            await removePendingUpload()
                            return
                        }
                        
                    case "failed":
                        print("❌ [Background Poll] Job failed: \(status.message ?? "Unknown error")")
                        await showFailureToast(message: NSLocalizedString("Video processing failed", comment: "Error"))
                        await removePendingUpload()
                        return
                        
                    case "uploading", "processing":
                        // Still processing, continue polling
                        continue
                        
                    default:
                        print("⚠️ [Background Poll] Unknown status for job \(jobId): \(status.status)")
                        continue
                    }
                }
            }
            
            // Check if all jobs completed
            if completedCount == totalJobs {
                print("✅ [Background Poll] ALL \(totalJobs) jobs completed!")
                // Submit tweet with all completed videos
                await submitTweetWithCompletedJobs(
                    tweet: tweet,
                    itemData: itemData,
                    completedCIDs: completedCIDs,
                    uploadedAttachments: uploadedAttachments
                )
                return
            }
            
            // Wait before next poll
            print("⏳ [Background Poll] \(completedCount)/\(totalJobs) jobs complete, polling... (\(pollAttempts)/\(maxPollAttempts))")
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
        }
        
        // Timeout
        print("❌ [Background Poll] Polling timeout after \(maxPollAttempts) attempts (\(completedCount)/\(totalJobs) completed)")
        await showFailureToast(message: NSLocalizedString("Video processing timed out", comment: "Error"))
        await removePendingUpload()
    }
    
    /// Submit tweet once ALL video jobs are complete (with retry)
    private func submitTweetWithCompletedJobs(
        tweet: Tweet,
        itemData: [PendingTweetUpload.ItemData],
        completedCIDs: [String: String], // jobId -> CID mapping
        uploadedAttachments: [MimeiFileType],
        retryCount: Int = 0
    ) async {
        guard let hproseInstance = hproseInstance else { return }
        
        print("📝 [Submit] Submitting tweet with \(completedCIDs.count) completed job(s), retry: \(retryCount)")
        print("📝 [Submit] ItemData count: \(itemData.count)")
        
        // Build final attachments using stored CIDs, completed job CIDs, and metadata
        var finalAttachments: [MimeiFileType] = []
        
        for (index, item) in itemData.enumerated() {
            print("📋 [Submit] Processing item \(index + 1): videoJobId=\(item.videoJobId ?? "nil"), cid=\(item.cid ?? "nil"), fileName=\(item.fileName)")
            
            if let jobId = item.videoJobId {
                // This is a video - use the completed CID from server
                if let completedCID = completedCIDs[jobId] {
                    let attachment = MimeiFileType(
                        mid: completedCID,
                        mediaType: .hls_video,
                        size: item.fileSize ?? Int64(item.data.count),
                        fileName: item.fileName,
                        timestamp: Date(timeIntervalSince1970: Date().timeIntervalSince1970),
                        aspectRatio: item.aspectRatio,
                        url: nil
                    )
                    finalAttachments.append(attachment)
                    print("✅ [Submit] Added video attachment \(index + 1): CID: \(completedCID), size: \(item.fileSize ?? 0), aspectRatio: \(item.aspectRatio ?? 0), fileName: \(item.fileName)")
                } else {
                    print("❌ [Submit] WARNING: Missing completed CID for job: \(jobId)")
                }
            } else if let storedCID = item.cid {
                // This is an image or non-video - use the stored CID and metadata
                let mediaType = MediaType.fromString(item.mediaType ?? "Image")
                let attachment = MimeiFileType(
                    mid: storedCID,
                    mediaType: mediaType,
                    size: item.fileSize ?? Int64(item.data.count),
                    fileName: item.fileName,
                    timestamp: Date(timeIntervalSince1970: Date().timeIntervalSince1970),
                    aspectRatio: item.aspectRatio,
                    url: nil
                )
                finalAttachments.append(attachment)
                print("✅ [Submit] Added \(mediaType.rawValue) attachment \(index + 1): CID: \(storedCID), size: \(item.fileSize ?? 0), aspectRatio: \(item.aspectRatio ?? 0), fileName: \(item.fileName)")
            } else {
                print("❌ [Submit] ERROR: Missing CID for attachment \(index + 1) - This should never happen!")
            }
        }
        
        print("📊 [Submit] Final attachments count: \(finalAttachments.count) (expected: \(itemData.count))")
        tweet.attachments = finalAttachments
        
        // Submit the tweet
        do {
            if let uploadedTweet = try await hproseInstance.uploadTweet(tweet) {
                // Success! (tweetCount is updated by refreshAppUserFromServer() inside uploadTweet())
                await removePendingUpload()
                
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .newTweetCreated,
                        object: nil,
                        userInfo: ["tweet": uploadedTweet]
                    )
                }
                
                print("✅ [Submit] Tweet posted successfully with \(finalAttachments.count) attachments!")
            } else {
                throw NSError(domain: "TweetUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to upload tweet"])
            }
        } catch {
            print("❌ [Submit] Failed to post tweet (attempt \(retryCount + 1)): \(error)")
            
            // Retry up to 2 times
            let maxRetries = 2
            if retryCount < maxRetries {
                print("🔄 [Submit] Retrying tweet submission (\(retryCount + 1)/\(maxRetries))...")
                let delay = UInt64(retryCount + 1) * 2_000_000_000 // 2s, 4s
                try? await Task.sleep(nanoseconds: delay)
                await submitTweetWithCompletedJobs(
                    tweet: tweet,
                    itemData: itemData,
                    completedCIDs: completedCIDs,
                    uploadedAttachments: uploadedAttachments,
                    retryCount: retryCount + 1
                )
            } else {
                print("❌ [Submit] Max retries reached, giving up")
                await showFailureToast(message: NSLocalizedString("Failed to post tweet", comment: "Error"))
                await removePendingUpload()
            }
        }
    }
    
    /// Poll video jobs and submit comment (reuses tweet polling logic)
    private func pollVideoJobsAndSubmitComment(
        comment: Tweet,
        to parentTweet: Tweet,
        itemData: [PendingTweetUpload.ItemData],
        uploadedAttachments: [MimeiFileType],
        isQuoting: Bool = false
    ) async {
        // Extract all job IDs from itemData
        let jobItems = itemData.filter { $0.videoJobId != nil }
        guard !jobItems.isEmpty else {
            print("⚠️ [Comment Poll] No job IDs to poll")
            return
        }
        
        print("🔄 [Comment Poll] Starting background polling for \(jobItems.count) video job(s)")
        
        guard let hproseInstance = hproseInstance else {
            print("❌ [Comment Poll] HproseInstance not available")
            return
        }
        
        // Get base URL for polling
        guard let baseURL = try? await hproseInstance.appUser.resolveWritableUrl(),
              let host = baseURL.host,
              hproseInstance.appUser.cloudDrivePort > 0,
              let pollURL = URL(string: "http://\(host):\(hproseInstance.appUser.cloudDrivePort)") else {
            print("❌ [Comment Poll] Cannot construct polling URL")
            await showFailureToast(message: NSLocalizedString("Failed to check video status", comment: "Error"))
            return
        }
        
        // Track completed job CIDs
        var completedCIDs: [String: String] = [:] // jobId -> CID
        var completedCount = 0
        let totalJobs = jobItems.count
        
        // Poll until all complete or failed
        var pollAttempts = 0
        let maxPollAttempts = 120 // 10 minutes (5 second intervals)
        
        while pollAttempts < maxPollAttempts && completedCount < totalJobs {
            pollAttempts += 1
            
            // Check status of all pending jobs
            for jobItem in jobItems {
                guard let jobId = jobItem.videoJobId else { continue }
                
                // Skip already completed jobs
                if completedCIDs[jobId] != nil {
                    continue
                }
                
                if let status = await checkVideoJobStatus(jobId: jobId, baseURL: pollURL) {
                    switch status.status {
                    case "completed":
                        if let cid = status.cid, !cid.isEmpty {
                            completedCIDs[jobId] = cid
                            completedCount += 1
                            print("✅ [Comment Poll] Job \(completedCount)/\(totalJobs) complete! Job: \(jobId), CID: \(cid)")
                        } else {
                            print("❌ [Comment Poll] Job completed but no CID returned")
                            await showFailureToast(message: NSLocalizedString("Video processing completed but no ID returned", comment: "Error"))
                            return
                        }
                        
                    case "failed":
                        print("❌ [Comment Poll] Job failed: \(status.message ?? "Unknown error")")
                        await showFailureToast(message: NSLocalizedString("Video processing failed", comment: "Error"))
                        return
                        
                    case "uploading", "processing":
                        // Still processing, continue polling
                        continue
                        
                    default:
                        print("⚠️ [Comment Poll] Unknown status for job \(jobId): \(status.status)")
                        continue
                    }
                }
            }
            
            // Check if all jobs completed
            if completedCount == totalJobs {
                print("✅ [Comment Poll] ALL \(totalJobs) video jobs completed!")
                // Submit comment with all completed videos
                await submitCommentWithCompletedJobs(
                    comment: comment,
                    to: parentTweet,
                    itemData: itemData,
                    completedCIDs: completedCIDs,
                    isQuoting: isQuoting
                )
                return
            }
            
            // Wait before next poll
            print("⏳ [Comment Poll] \(completedCount)/\(totalJobs) jobs complete, polling... (\(pollAttempts)/\(maxPollAttempts))")
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
        }
        
        // Timeout
        print("❌ [Comment Poll] Polling timeout after \(maxPollAttempts) attempts (\(completedCount)/\(totalJobs) completed)")
        await showFailureToast(message: NSLocalizedString("Video processing timed out", comment: "Error"))
    }
    
    /// Submit comment once ALL video jobs are complete (with retry)
    private func submitCommentWithCompletedJobs(
        comment: Tweet,
        to parentTweet: Tweet,
        itemData: [PendingTweetUpload.ItemData],
        completedCIDs: [String: String],
        retryCount: Int = 0,
        isQuoting: Bool = false
    ) async {
        guard let hproseInstance = hproseInstance else { return }
        
        print("📝 [Comment Submit] Submitting comment with \(completedCIDs.count) completed video job(s), retry: \(retryCount)")
        
        // Build final attachments using completed job CIDs
        var finalAttachments: [MimeiFileType] = []
        
        for (index, item) in itemData.enumerated() {
            if let jobId = item.videoJobId {
                // This is a video - use the completed CID from server
                if let completedCID = completedCIDs[jobId] {
                    let attachment = MimeiFileType(
                        mid: completedCID,
                        mediaType: .hls_video,
                        size: item.fileSize ?? Int64(item.data.count),
                        fileName: item.fileName,
                        timestamp: Date(timeIntervalSince1970: Date().timeIntervalSince1970),
                        aspectRatio: item.aspectRatio,
                        url: nil
                    )
                    finalAttachments.append(attachment)
                    print("✅ [Comment Submit] Added video attachment \(index + 1): CID: \(completedCID)")
                }
            } else if let storedCID = item.cid {
                // This is an image - use the stored CID
                let mediaType = MediaType.fromString(item.mediaType ?? "Image")
                let attachment = MimeiFileType(
                    mid: storedCID,
                    mediaType: mediaType,
                    size: item.fileSize ?? Int64(item.data.count),
                    fileName: item.fileName,
                    timestamp: Date(timeIntervalSince1970: Date().timeIntervalSince1970),
                    aspectRatio: item.aspectRatio,
                    url: nil
                )
                finalAttachments.append(attachment)
                print("✅ [Comment Submit] Added image attachment \(index + 1): CID: \(storedCID)")
            }
        }
        
        comment.attachments = finalAttachments
        
        // Submit the comment
        do {
            if let newComment = try await hproseInstance.addComment(comment, to: parentTweet) {
                print("✅ [Comment Submit] Comment posted successfully with \(finalAttachments.count) attachments!")
                print("[TweetUploadManager] New comment mid: \(newComment.mid)")
                print("[TweetUploadManager] Parent tweet mid: \(parentTweet.mid)")
                
                // If quoting, also upload as a new tweet
                if isQuoting {
                    print("📝 [Quote Tweet] Uploading comment as quote tweet...")
                    newComment.originalTweetId = parentTweet.mid
                    newComment.originalAuthorId = parentTweet.authorId
                    if let quoteTweet = try await hproseInstance.uploadTweet(newComment) {
                        print("✅ [Quote Tweet] Quote tweet posted successfully! ID: \(quoteTweet.mid)")
                        // Update retweet count on the original tweet
                        do {
                            try await hproseInstance.updateRetweetCount(tweet: parentTweet, retweetId: quoteTweet.mid, direction: true)
                            print("✅ [Quote Tweet] Updated retweet count for original tweet")
                        } catch {
                            print("⚠️ [Quote Tweet] Failed to update retweet count: \(error)")
                        }
                    } else {
                        print("❌ [Quote Tweet] Failed to post quote tweet")
                    }
                }
                // Success notification is posted by addComment()
            } else {
                throw NSError(domain: "CommentUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to post comment"])
            }
        } catch {
            print("❌ [Comment Submit] Failed to post comment (attempt \(retryCount + 1)): \(error)")
            
            let maxRetries = 2
            if retryCount < maxRetries {
                print("🔄 [Comment Submit] Retrying... (\(retryCount + 1)/\(maxRetries))")
                try? await Task.sleep(nanoseconds: UInt64(retryCount + 1) * 2_000_000_000) // Exponential backoff
                await submitCommentWithCompletedJobs(
                    comment: comment,
                    to: parentTweet,
                    itemData: itemData,
                    completedCIDs: completedCIDs,
                    retryCount: retryCount + 1,
                    isQuoting: isQuoting
                )
            } else {
                print("❌ [Comment Submit] Max retries reached")
                await showFailureToast(message: NSLocalizedString("Failed to post comment after retries", comment: "Error"))
            }
        }
    }
    
    /// Poll video jobs and send chat message once complete
    private func pollVideoJobsAndSendChatMessage(
        message: ChatMessage,
        itemData: [PendingTweetUpload.ItemData],
        uploadedAttachments: [MimeiFileType]
    ) async {
        // Extract all job IDs from itemData
        let jobItems = itemData.filter { $0.videoJobId != nil }
        guard !jobItems.isEmpty else {
            print("⚠️ [Chat Poll] No job IDs to poll")
            return
        }
        
        print("🔄 [Chat Poll] Starting background polling for \(jobItems.count) video job(s)")
        print("🔄 [Chat Poll] Message content: '\(message.content ?? "nil")', receiptId: \(message.receiptId)")
        for (idx, jobItem) in jobItems.enumerated() {
            print("🔄 [Chat Poll] Job \(idx + 1): jobId=\(jobItem.videoJobId ?? "nil"), fileName=\(jobItem.fileName)")
        }
        
        guard let hproseInstance = hproseInstance else {
            print("❌ [Chat Poll] HproseInstance not available")
            return
        }
        
        // Get base URL for polling
        guard let baseURL = try? await hproseInstance.appUser.resolveWritableUrl(),
              let host = baseURL.host,
              hproseInstance.appUser.cloudDrivePort > 0,
              let pollURL = URL(string: "http://\(host):\(hproseInstance.appUser.cloudDrivePort)") else {
            print("❌ [Chat Poll] Cannot construct polling URL")
            await showFailureToast(message: NSLocalizedString("Failed to check video status", comment: "Error"))
            return
        }
        
        // Track completed job CIDs
        var completedCIDs: [String: String] = [:] // jobId -> CID
        var completedCount = 0
        let totalJobs = jobItems.count
        
        // Poll until all complete or failed
        var pollAttempts = 0
        let maxPollAttempts = 120 // 10 minutes (5 second intervals)
        
        while pollAttempts < maxPollAttempts && completedCount < totalJobs {
            pollAttempts += 1
            
            // Check status of all pending jobs
            for jobItem in jobItems {
                guard let jobId = jobItem.videoJobId else { continue }
                
                // Skip already completed jobs
                if completedCIDs[jobId] != nil {
                    continue
                }
                
                if let status = await checkVideoJobStatus(jobId: jobId, baseURL: pollURL) {
                    switch status.status {
                    case "completed":
                        if let cid = status.cid, !cid.isEmpty {
                            completedCIDs[jobId] = cid
                            completedCount += 1
                            print("✅ [Chat Poll] Job \(completedCount)/\(totalJobs) complete! Job: \(jobId), CID: \(cid)")
                        } else {
                            print("❌ [Chat Poll] Job completed but no CID returned")
                            await showFailureToast(message: NSLocalizedString("Video processing completed but no ID returned", comment: "Error"))
                            return
                        }
                        
                    case "failed":
                        print("❌ [Chat Poll] Job failed: \(status.message ?? "Unknown error")")
                        await MainActor.run {
                            NotificationCenter.default.post(
                                name: .chatMessageSendFailed,
                                object: nil,
                                userInfo: ["error": NSError(domain: "ChatUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: status.message ?? NSLocalizedString("Video processing failed", comment: "Error")])]
                            )
                        }
                        return
                        
                    case "uploading", "processing":
                        // Still processing, continue polling
                        continue
                        
                    default:
                        print("⚠️ [Chat Poll] Unknown status for job \(jobId): \(status.status)")
                        continue
                    }
                }
            }
            
            // Check if all jobs completed
            if completedCount == totalJobs {
                print("✅ [Chat Poll] ALL \(totalJobs) video jobs completed!")
                // Send chat message with all completed videos
                await sendChatMessageWithCompletedJobs(
                    message: message,
                    itemData: itemData,
                    completedCIDs: completedCIDs
                )
                return
            }
            
            // Wait before next poll
            print("⏳ [Chat Poll] \(completedCount)/\(totalJobs) jobs complete, polling... (\(pollAttempts)/\(maxPollAttempts))")
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
        }
        
        // Timeout
        print("❌ [Chat Poll] Polling timeout after \(maxPollAttempts) attempts (\(completedCount)/\(totalJobs) completed)")
        await MainActor.run {
            NotificationCenter.default.post(
                name: .chatMessageSendFailed,
                object: nil,
                userInfo: ["error": NSError(domain: "ChatUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Video processing timed out", comment: "Error")])]
            )
        }
    }
    
    /// Send chat message once ALL video jobs are complete
    private func sendChatMessageWithCompletedJobs(
        message: ChatMessage,
        itemData: [PendingTweetUpload.ItemData],
        completedCIDs: [String: String],
        retryCount: Int = 0
    ) async {
        guard let hproseInstance = hproseInstance else { return }
        
        print("📝 [Chat Submit] Sending message with \(completedCIDs.count) completed video job(s), retry: \(retryCount)")
        print("📝 [Chat Submit] ItemData count: \(itemData.count), completedCIDs: \(completedCIDs)")
        
        // Build final attachments using completed job CIDs
        var finalAttachments: [MimeiFileType] = []
        
        for (index, item) in itemData.enumerated() {
            print("📋 [Chat Submit] Processing item \(index + 1): videoJobId=\(item.videoJobId ?? "nil"), cid=\(item.cid ?? "nil"), fileName=\(item.fileName)")
            
            if let jobId = item.videoJobId {
                // This is a video - use the completed CID from server
                if let completedCID = completedCIDs[jobId] {
                    // Use the mediaType from itemData if available, otherwise default to hls_video
                    let mediaType = item.mediaType != nil ? MediaType.fromString(item.mediaType!) : .hls_video
                    let attachment = MimeiFileType(
                        mid: completedCID,
                        mediaType: mediaType,
                        size: item.fileSize ?? Int64(item.data.count),
                        fileName: item.fileName,
                        timestamp: Date(timeIntervalSince1970: Date().timeIntervalSince1970),
                        aspectRatio: item.aspectRatio,
                        url: nil
                    )
                    finalAttachments.append(attachment)
                    print("✅ [Chat Submit] Added video attachment \(index + 1): CID: \(completedCID), mediaType: \(mediaType.rawValue), size: \(item.fileSize ?? 0), aspectRatio: \(item.aspectRatio ?? 0)")
                } else {
                    print("❌ [Chat Submit] WARNING: Missing completed CID for job: \(jobId)")
                }
            } else if let storedCID = item.cid {
                // This is an image - use the stored CID
                let mediaType = MediaType.fromString(item.mediaType ?? "Image")
                let attachment = MimeiFileType(
                    mid: storedCID,
                    mediaType: mediaType,
                    size: item.fileSize ?? Int64(item.data.count),
                    fileName: item.fileName,
                    timestamp: Date(timeIntervalSince1970: Date().timeIntervalSince1970),
                    aspectRatio: item.aspectRatio,
                    url: nil
                )
                finalAttachments.append(attachment)
                print("✅ [Chat Submit] Added image attachment \(index + 1): CID: \(storedCID), mediaType: \(mediaType.rawValue)")
            } else {
                print("❌ [Chat Submit] ERROR: Missing CID for attachment \(index + 1) - This should never happen!")
            }
        }
        
        print("📊 [Chat Submit] Final attachments count: \(finalAttachments.count) (expected: \(itemData.count))")
        
        var finalMessage = message
        finalMessage.attachments = finalAttachments
        
        print("📤 [Chat Submit] About to send message: content='\(finalMessage.content ?? "nil")', attachments=\(finalMessage.attachments?.count ?? 0), receiptId=\(finalMessage.receiptId)")
        if let attachments = finalMessage.attachments {
            for (idx, att) in attachments.enumerated() {
                print("📤 [Chat Submit] Final attachment \(idx + 1):")
                print("  mid: \(att.mid)")
                print("  type: \(att.type.rawValue)")
                print("  size: \(att.size ?? -1)")
                print("  fileName: \(att.fileName ?? "nil")")
                print("  aspectRatio: \(att.aspectRatio ?? -1)")
                print("  timestamp: \(att.timestamp.timeIntervalSince1970 * 1000)")
            }
        }
        print("📤 [Chat Submit] Full message JSON: \(finalMessage.toJSONString())")
        
        // Send the message
        do {
            let resultMessage = try await hproseInstance.sendMessage(receiptId: finalMessage.receiptId, message: finalMessage)
            
            if resultMessage.success == true {
                print("✅ [Chat Submit] Message sent successfully with \(finalAttachments.count) attachments!")
                print("✅ [Chat Submit] Result message ID: \(resultMessage.id), content: \(resultMessage.content ?? "nil"), attachments: \(resultMessage.attachments?.count ?? 0)")
                
                await MainActor.run {
                    // Post notification for message sent
                    NotificationCenter.default.post(
                        name: .chatMessageSent,
                        object: nil,
                        userInfo: ["message": resultMessage]
                    )
                    print("✅ [Chat Submit] Posted chatMessageSent notification")
                }
            } else {
                let errorMsg = resultMessage.errorMsg ?? "Failed to send message"
                print("❌ [Chat Submit] Message send failed: \(errorMsg)")
                throw NSError(domain: "ChatUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            }
        } catch {
            print("❌ [Chat Submit] Failed to send message (attempt \(retryCount + 1)): \(error)")
            print("❌ [Chat Submit] Error details: \(error.localizedDescription)")
            
            let maxRetries = 2
            if retryCount < maxRetries {
                print("🔄 [Chat Submit] Retrying... (\(retryCount + 1)/\(maxRetries))")
                try? await Task.sleep(nanoseconds: UInt64(retryCount + 1) * 2_000_000_000) // Exponential backoff
                await sendChatMessageWithCompletedJobs(
                    message: message,
                    itemData: itemData,
                    completedCIDs: completedCIDs,
                    retryCount: retryCount + 1
                )
            } else {
                print("❌ [Chat Submit] Max retries reached, giving up")
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .chatMessageSendFailed,
                        object: nil,
                        userInfo: ["error": error]
                    )
                }
            }
        }
    }
    
    private func showFailureToast(message: String) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .backgroundUploadFailed,
                object: nil,
                userInfo: ["error": message]
            )
        }
    }
    
    private func uploadChatMessageWithPersistenceAndRetry(
        message: ChatMessage,
        itemData: [PendingTweetUpload.ItemData],
        retryCount: Int = 0
    ) async {
        guard let hproseInstance = hproseInstance else { return }
        
        do {
            // Update progress: uploading attachments
            await MainActor.run {
                UploadProgressManager.shared.updateProgress(
                    stage: .uploadingAttachments,
                    message: NSLocalizedString("Uploading attachments...", comment: "Upload stage"),
                    progress: 0.2
                )
            }
            
            let (uploadedAttachments, jobIdMap) = try await uploadAttachments(itemData: itemData)
            
            // Check if we have video jobs that need polling
            if !jobIdMap.isEmpty {
                print("✅ [Chat Upload] Got \(jobIdMap.count) video job ID(s). Closing dialog and polling in background...")
                
                // Update itemData with job IDs for polling
                var updatedItemData = itemData
                for (index, item) in updatedItemData.enumerated() {
                    if index < uploadedAttachments.count {
                        let attachment = uploadedAttachments[index]
                        let jobId = jobIdMap[item.identifier]
                        
                        print("📋 [Chat Upload] Storing metadata for item \(index + 1): mediaType=\(attachment.type.rawValue), jobId=\(jobId ?? "nil"), cid=\(attachment.mid)")
                        
                        updatedItemData[index] = PendingTweetUpload.ItemData(
                            identifier: item.identifier,
                            typeIdentifier: item.typeIdentifier,
                            data: item.data,
                            fileName: item.fileName,
                            noResample: item.noResample,
                            videoJobId: jobId,
                            cid: attachment.mid,
                            aspectRatio: attachment.aspectRatio,
                            fileSize: attachment.size,
                            mediaType: attachment.type.rawValue
                        )
                    }
                }
                
                // Close the dialog with message about server processing
                await MainActor.run {
                    UploadProgressManager.shared.updateProgress(
                        stage: .completed,
                        message: NSLocalizedString("Processing video on server...", comment: "Upload stage"),
                        progress: 1.0,
                        detail: NSLocalizedString("Your message will be sent when ready", comment: "Background processing")
                    )
                }
                
                // Small delay to show message
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
                
                await MainActor.run {
                    UploadProgressManager.shared.completeUpload()
                }
                
                // Start background polling for video jobs
                Task.detached(priority: .background) {
                    await self.pollVideoJobsAndSendChatMessage(
                        message: message,
                        itemData: updatedItemData,
                        uploadedAttachments: uploadedAttachments
                    )
                }
                
                return
            }
            
            // No video jobs - images only, send message immediately
            print("✅ [Chat Upload] All image attachments uploaded. Sending message...")
            
            var finalMessage = message
            finalMessage.attachments = uploadedAttachments
            
            // Update progress: sending message
            await MainActor.run {
                UploadProgressManager.shared.updateProgress(
                    stage: .submittingTweet,
                    message: NSLocalizedString("Sending message...", comment: "Upload stage"),
                    progress: 0.9
                )
            }
            
            let resultMessage = try await hproseInstance.sendMessage(receiptId: finalMessage.receiptId, message: finalMessage)
            
            if resultMessage.success == true {
                print("✅ [Chat Upload] Chat message sent successfully: \(resultMessage.id)")
                
                await MainActor.run {
                    UploadProgressManager.shared.completeUpload()
                    
                    // Post notification for message sent
                    NotificationCenter.default.post(
                        name: .chatMessageSent,
                        object: nil,
                        userInfo: ["message": resultMessage]
                    )
                }
            } else {
                throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: resultMessage.errorMsg ?? "Failed to send chat message"])
            }
        } catch {
            print("❌ [Chat Upload] Error uploading chat message: \(error)")
            await MainActor.run {
                UploadProgressManager.shared.failUpload(message: ErrorMessageHelper.userFriendlyMessage(from: error))
            }
        }
    }
    
    private func uploadAttachments(itemData: [PendingTweetUpload.ItemData]) async throws -> ([MimeiFileType], [String:String]) {
        var uploadedAttachments: [MimeiFileType] = []
        var jobIdMap: [String: String] = [:] // identifier -> jobId mapping
        
        let totalItems = itemData.count
        
        // Upload items one by one to show progress for each
        for (index, item) in itemData.enumerated() {
            let itemNumber = index + 1
            
            print("📋 [Upload] Starting item \(itemNumber)/\(totalItems): typeIdentifier=\(item.typeIdentifier), fileName=\(item.fileName)")
            
            // Determine if this is a video BEFORE calling uploadToIPFS so we can capture it in the closure
            let typeIdLower = item.typeIdentifier.lowercased()
            let isVideo = typeIdLower.contains("video") || 
                          typeIdLower.contains("movie") || 
                          typeIdLower.contains("mpeg") ||
                          typeIdLower.contains("mp4") ||
                          typeIdLower.contains("m4v") ||
                          typeIdLower.contains("quicktime") ||
                          typeIdLower.contains("avi") ||
                          typeIdLower.contains("mov")
            
            do {
                let (result, jobId) = try await uploadToIPFS(
                    data: item.data,
                    typeIdentifier: item.typeIdentifier,
                    fileName: item.fileName,
                    noResample: item.noResample,
                    progressCallback: { [itemNumber, totalItems, index, isVideo] message, progress in
                        Task { @MainActor in
                            let overallProgress = 0.2 + (Double(index) / Double(totalItems) * 0.6) + (Double(progress) / 100.0 * (0.6 / Double(totalItems)))
                            
                            // Use the captured isVideo value, not message content
                            let progressMessage: String
                            if isVideo {
                                progressMessage = String(format: NSLocalizedString("Processing video %d/%d", comment: "Upload progress"), itemNumber, totalItems)
                            } else {
                                progressMessage = String(format: NSLocalizedString("Uploading image %d/%d", comment: "Upload progress"), itemNumber, totalItems)
                            }
                            
                            UploadProgressManager.shared.updateProgress(
                                stage: .uploadingAttachments,
                                message: progressMessage,
                                progress: overallProgress,
                                detail: "\(progress)%"
                            )
                        }
                    }
                )
                
                if let fileType = result {
                    uploadedAttachments.append(fileType)
                    print("✅ [Upload] Item \(itemNumber)/\(totalItems) uploaded as \(fileType.type.rawValue), fileName=\(fileType.fileName ?? "nil")")
                }
                
                if let jobId = jobId {
                    jobIdMap[item.identifier] = jobId
                    print("📝 [Upload] Item \(itemNumber)/\(totalItems) uploaded, job ID: \(jobId)")
                } else {
                    print("✅ [Upload] Item \(itemNumber)/\(totalItems) uploaded (no job ID)")
                }
            } catch {
                print("❌ [Upload] Error uploading item \(itemNumber)/\(totalItems): \(error)")
                throw error
            }
        }
        
        if itemData.count != uploadedAttachments.count {
            throw NSError(domain: "HproseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to upload attachment", comment: "Attachment upload error")])
        }
        
        print("📊 [Upload] All \(totalItems) attachments uploaded. Job IDs: \(jobIdMap.count)")
        return (uploadedAttachments, jobIdMap)
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
                    
                    // Post notification (tweetCount is updated by refreshAppUserFromServer() inside uploadTweet())
                    await MainActor.run {
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
        guard hproseInstance.appUser.cloudDrivePort > 0 else {
            print("ERROR: Cloud drive port not configured for video job polling")
            return
        }
        
        guard let baseURL = URL(string: "http://\(host):\(hproseInstance.appUser.cloudDrivePort)") else {
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
        let videoJobId: String? // Legacy - kept for backward compatibility
        
        struct ItemData: Codable {
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
        
        init(tweet: Tweet, itemData: [ItemData], retryCount: Int = 0, videoJobId: String? = nil) {
            self.tweet = tweet
            self.itemData = itemData
            self.timestamp = Date(timeIntervalSince1970: Date().timeIntervalSince1970)
            self.retryCount = retryCount
            self.videoJobId = videoJobId // Legacy compatibility
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
