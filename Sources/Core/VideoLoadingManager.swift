//
//  VideoLoadingManager.swift
//  Tweet
//
//  Manages video loading and preloading based on tweet visibility with performance optimizations
//

import Foundation
import SwiftUI
import UIKit

@MainActor
class VideoLoadingManager: ObservableObject {
    static let shared = VideoLoadingManager()
    
    private init() {
        setupBasicMonitoring()
        startBackgroundCancellationTimer()
    }
    
    // MARK: - State
    @Published private(set) var visibleTweetIds: Set<String> = []
    @Published private(set) var currentVisibleTweetIndex: Int = 0
    private var allTweetIds: [String] = []
    private var tweetsWithVideos: Set<String> = [] // Track which tweets contain media (video, audio, etc.)
    private var retweetToOriginalMap: [String: String] = [:] // Map retweet ID to original tweet ID
    
    // MARK: - Performance Management
    private var activeLoadingCount: Int = 0
    private let maxConcurrentLoads: Int = 8 // Increased from 5 to 8 for better network utilization
    private var loadingQueue: [String] = [] // Queue for pending video loads
    private var isProcessingQueue = false
    
    // MARK: - Background Cancellation
    private var backgroundCancellationTimer: Timer?
    private var tweetsToCancel: Set<String> = [] // Tweets queued for background cancellation
    private var isProcessingCancellations = false
    
    // MARK: - Configuration
    private let preloadCount = 3 // Increased from 2 to 3 to allow more preloading
    private let bufferDistance = 1 // Keep 1 tweet behind as buffer
    private let cancellationBatchSize = 10 // Process cancellations in batches
    
    // MARK: - Performance Monitoring
    private var lastLoadTime: Date = Date()
    private var loadCountInLastMinute: Int = 0
    
    // MARK: - Public Methods
    
    /// Update the list of all tweet IDs (called when tweet list changes)
    func updateTweetList(_ tweetIds: [String]) {
        allTweetIds = tweetIds
    }
    
    /// Register a tweet as containing videos or audio (or other loadable media)
    /// Note: Despite the method name, this tracks all media types that need loading priority (video, audio, etc.)
    func registerTweetWithVideos(_ tweetId: String) {
        tweetsWithVideos.insert(tweetId)
        print("DEBUG: [VideoLoadingManager] Registered tweet \(tweetId) as containing media (video/audio)")
    }
    
    /// Register a retweet-to-original relationship
    func registerRetweetRelationship(retweetId: String, originalTweetId: String) {
        retweetToOriginalMap[retweetId] = originalTweetId
        print("DEBUG: [VideoLoadingManager] Registered retweet relationship: \(retweetId) -> \(originalTweetId)")
    }
    
    /// Update the currently visible tweet index
    func updateVisibleTweetIndex(_ index: Int) {
        guard index >= 0 && index < allTweetIds.count else { return }
        
        currentVisibleTweetIndex = index
        
        
        // Update visible tweet IDs
        updateVisibleTweetIds()
        
        // Queue tweets for background cancellation instead of immediate cancellation
        queueTweetsForCancellation()
        
        // Manage video loading with performance considerations
        manageVideoLoadingWithPerformance()
    }
    
    /// Check if a tweet should load videos/audio (with performance throttling and cache awareness)
    /// Note: Despite the method name, this handles all media types (video, audio, etc.)
    func shouldLoadVideos(for tweetId: String) -> Bool {
        
        // HIGHEST PRIORITY: Original tweets of visible retweets should load immediately
        let currentVisibleTweetId = allTweetIds.indices.contains(currentVisibleTweetIndex) ? allTweetIds[currentVisibleTweetIndex] : nil
        if let visibleId = currentVisibleTweetId, retweetToOriginalMap[visibleId] == tweetId {
            print("DEBUG: [VideoLoadingManager] Tweet \(tweetId) is the ORIGINAL of visible retweet \(visibleId), HIGHEST PRIORITY - allowing loading")
            return true
        }
        
        guard let index = allTweetIds.firstIndex(of: tweetId) else { 
            print("DEBUG: [VideoLoadingManager] Tweet \(tweetId) not found in allTweetIds - denying loading")
            return false 
        }
                
        // HIGHEST PRIORITY: Current visible tweet should always load regardless of any constraints
        if index == currentVisibleTweetIndex {
            print("DEBUG: [VideoLoadingManager] Tweet \(tweetId) is current visible tweet, highest priority - allowing loading")
            return true
        }
        
        // Calculate distance first to prevent loading tweets above current position
        let distance = index - currentVisibleTweetIndex
        
        // CRITICAL: Never load videos for tweets above current position (scrolling up stability)
        // This prevents layout instability when scrolling up past previously viewed tweets
        if distance < 0 {
            print("DEBUG: [VideoLoadingManager] Tweet \(tweetId) is above current position (distance: \(distance)), denying loading for scroll stability")
            return false
        }
        
        // SECOND PRIORITY: Check if tweet has cached content - but only for tweets at or near current position
        // This allows fast loading of nearby cached content without causing layout shifts from distant tweets
        let hasCachedContent = SharedAssetCache.shared.hasCachedContent(for: tweetId)
        if hasCachedContent && distance <= preloadCount {
            print("DEBUG: [VideoLoadingManager] Tweet \(tweetId) has cached content and is within preload range, allowing loading")
            return true
        }
        
        // Check if we're already loading too many videos
        if activeLoadingCount >= maxConcurrentLoads {
            print("DEBUG: [VideoLoadingManager] Throttling video load for \(tweetId) - too many active loads (\(activeLoadingCount))")
            return false
        }
        
        // Check if we're loading too frequently
        if isLoadingTooFrequently() {
            print("DEBUG: [VideoLoadingManager] Throttling video load for \(tweetId) - loading too frequently")
            return false
        }
        
        // Only load videos for current visible tweet and next few tweets (NOT past tweets)
        return distance >= 0 && distance <= preloadCount
    }
    
    /// Check if a tweet should preload videos/audio
    /// Note: Despite the method name, this handles all media types (video, audio, etc.)
    func shouldPreloadVideos(for tweetId: String) -> Bool {
        // HIGHEST PRIORITY: Original tweets of visible retweets should preload
        let currentVisibleTweetId = allTweetIds.indices.contains(currentVisibleTweetIndex) ? allTweetIds[currentVisibleTweetIndex] : nil
        if let visibleId = currentVisibleTweetId, retweetToOriginalMap[visibleId] == tweetId {
            print("DEBUG: [VideoLoadingManager] Tweet \(tweetId) is the ORIGINAL of visible retweet \(visibleId), HIGHEST PRIORITY - allowing preloading")
            return true
        }
        
        guard let index = allTweetIds.firstIndex(of: tweetId) else { return false }
        
        // Only preload if the tweet actually contains videos
        guard tweetsWithVideos.contains(tweetId) else { return false }
        
        // HIGHEST PRIORITY: Current visible tweet should always preload regardless of any constraints
        if index == currentVisibleTweetIndex {
            print("DEBUG: [VideoLoadingManager] Tweet \(tweetId) is current visible tweet, highest priority - allowing preloading")
            return true
        }
        
        // Calculate distance first to prevent preloading tweets above current position
        let distance = index - currentVisibleTweetIndex
        
        // CRITICAL: Never preload videos for tweets above current position (scrolling up stability)
        // This prevents layout instability when scrolling up past previously viewed tweets
        if distance <= 0 {
            return false
        }
        
        // SECOND PRIORITY: Check if tweet has cached content - but only for tweets ahead of current position
        // This allows fast preloading of nearby cached content without causing layout shifts
        let hasCachedContent = SharedAssetCache.shared.hasCachedContent(for: tweetId)
        if hasCachedContent && distance <= preloadCount {
            print("DEBUG: [VideoLoadingManager] Tweet \(tweetId) has cached content and is within preload range, allowing preloading")
            return true
        }
        
        // Check performance constraints
        if activeLoadingCount >= maxConcurrentLoads {
            return false
        }
        
        // Preload if tweet is within the next few tweets (ahead of current position only)
        return distance > 0 && distance <= preloadCount
    }
    
    /// Check if a tweet should cancel video loading
    func shouldCancelVideoLoading(for tweetId: String) -> Bool {
        guard let index = allTweetIds.firstIndex(of: tweetId) else { return false }
        
        // Only cancel if the tweet actually contains videos
        guard tweetsWithVideos.contains(tweetId) else { return false }
        
        // Cancel if tweet is behind the current visible tweet (with small buffer)
        let distance = currentVisibleTweetIndex - index
        return distance > 1  // Only keep 1 tweet behind as buffer
    }
    
    /// Notify that a video load has started
    func videoLoadStarted() {
        activeLoadingCount += 1
        loadCountInLastMinute += 1
        lastLoadTime = Date()
        print("DEBUG: [VideoLoadingManager] Video load started. Active loads: \(activeLoadingCount)")
    }
    
    /// Notify that a video load has completed
    func videoLoadCompleted() {
        activeLoadingCount = max(0, activeLoadingCount - 1)
        print("DEBUG: [VideoLoadingManager] Video load completed. Active loads: \(activeLoadingCount)")
        
        // Process queue if there are pending loads
        if !loadingQueue.isEmpty && !isProcessingQueue {
            processLoadingQueue()
        }
    }
    
    // MARK: - Private Methods
    
    private func setupBasicMonitoring() {
        // Reset load count every minute
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
            Task { @MainActor in
                self.loadCountInLastMinute = 0
            }
        }
        
    }
    
    /// Start background cancellation timer to process cancellations without blocking main actor
    private func startBackgroundCancellationTimer() {
        backgroundCancellationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                self.processBackgroundCancellations()
            }
        }
    }
    
    /// Queue tweets for background cancellation instead of immediate cancellation
    private func queueTweetsForCancellation() {
        for tweetId in allTweetIds {
            if shouldCancelVideoLoading(for: tweetId) {
                tweetsToCancel.insert(tweetId)
            }
        }
    }
    
    /// Process cancellations in background without blocking main actor
    private func processBackgroundCancellations() {
        guard !isProcessingCancellations && !tweetsToCancel.isEmpty else { return }
        
        isProcessingCancellations = true
        
        // Process cancellations in batches to avoid blocking
        let batchSize = min(cancellationBatchSize, tweetsToCancel.count)
        let batch = Array(tweetsToCancel.prefix(batchSize))
        
        // Remove processed tweets from the set
        for tweetId in batch {
            tweetsToCancel.remove(tweetId)
        }
        
        // Process cancellations in background
        Task.detached(priority: .background) {
            await self.processCancellationBatch(batch)
        }
        
        isProcessingCancellations = false
    }
    
    /// Process a batch of cancellations in background
    private func processCancellationBatch(_ tweetIds: [String]) async {
        // If an overlay (fullscreen, login sheet, etc.) is presented, skip cancellations.
        // Cancelling during overlays can stop videos that should resume after dismissal.
        let isCovered = await MainActor.run { self.isContentCoveredByOverlay() }
        if isCovered {
            print("DEBUG: [VideoLoadingManager] Content covered by overlay, skipping cancellation batch (\(tweetIds.count) tweets)")
            return
        }

        for tweetId in tweetIds {
            // CRITICAL FIX: Cancel loading tasks for out-of-sight videos even if cached content exists
            // This stops active buffering/downloading that continues even after videos scroll out of view
            // The cached content will remain, but active loading tasks will be cancelled
            await MainActor.run {
                SharedAssetCache.shared.cancelLoadingForOutOfSightTweet(tweetId)
            }
            
            // Post notification for MediaGridView to handle (on main actor)
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .cancelVideoLoading,
                    object: nil,
                    userInfo: ["tweetId": tweetId]
                )
            }
            
            // No artificial delay - process videos as fast as the system allows
        }
    }

    /// Returns true when a modal/sheet/fullscreen cover is presented over the app content.
    @MainActor
    private func isContentCoveredByOverlay() -> Bool {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            return false
        }
        return window.rootViewController?.presentedViewController != nil
    }
    
    private func isLoadingTooFrequently() -> Bool {
        let timeSinceLastLoad = Date().timeIntervalSince(lastLoadTime)
        return timeSinceLastLoad < 0.3 && loadCountInLastMinute > 20 // Increased frequency limit from 15 to 20
    }
    
    private func updateVisibleTweetIds() {
        var newVisibleIds = Set<String>()
        
        // Add current visible tweet
        if currentVisibleTweetIndex < allTweetIds.count {
            newVisibleIds.insert(allTweetIds[currentVisibleTweetIndex])
        }
        
        // Add tweets within preload range
        for i in 1...preloadCount {
            let index = currentVisibleTweetIndex + i
            if index < allTweetIds.count {
                newVisibleIds.insert(allTweetIds[index])
            }
        }
        
        visibleTweetIds = newVisibleIds
    }
    
    private func manageVideoLoadingWithPerformance() {
        
        // Note: Cancellations are now handled by background timer, not here
        
        // Trigger preloading for upcoming tweets with performance limits
        for i in 1...preloadCount {
            let index = currentVisibleTweetIndex + i
            if index < allTweetIds.count {
                let tweetId = allTweetIds[index]
                if shouldPreloadVideos(for: tweetId) {
                    if activeLoadingCount < maxConcurrentLoads {
                        triggerVideoPreloading(for: tweetId)
                    } else {
                        // Add to queue if we're at capacity
                        if !loadingQueue.contains(tweetId) {
                            loadingQueue.append(tweetId)
                            print("DEBUG: [VideoLoadingManager] Queued video preloading for tweet \(tweetId)")
                        }
                    }
                }
            }
        }
    }
    
    private func processLoadingQueue() {
        guard !isProcessingQueue && !loadingQueue.isEmpty else { return }
        
        isProcessingQueue = true
        
        Task { @MainActor in
            while !loadingQueue.isEmpty && activeLoadingCount < maxConcurrentLoads {
                let tweetId = loadingQueue.removeFirst()
                if shouldPreloadVideos(for: tweetId) {
                    triggerVideoPreloading(for: tweetId)
                    print("DEBUG: [VideoLoadingManager] Processed queued video preloading for tweet \(tweetId)")
                }
                
                // No artificial delay - process queue as fast as possible
            }
            
            isProcessingQueue = false
        }
    }

    
    /// Legacy method - now handled by background cancellation
    private func cancelVideoLoading(for tweetId: String) {
        // This method is kept for backward compatibility but is no longer used
        // Cancellations are now handled by the background timer
        print("DEBUG: [VideoLoadingManager] Legacy cancelVideoLoading called for \(tweetId) - using background cancellation instead")
    }
    
    private func triggerVideoPreloading(for tweetId: String) {
        // Trigger video preloading for this tweet using SharedAssetCache
        Task { @MainActor in
            SharedAssetCache.shared.triggerVideoPreloadingForTweet(tweetId)
        }
        
        // Post notification for MediaGridView to handle
        NotificationCenter.default.post(
            name: .triggerVideoPreloading,
            object: nil,
            userInfo: ["tweetId": tweetId]
        )
    }
    
    deinit {
        // Clean up timers
        backgroundCancellationTimer?.invalidate()
        backgroundCancellationTimer = nil
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let cancelVideoLoading = Notification.Name("cancelVideoLoading")
    static let triggerVideoPreloading = Notification.Name("triggerVideoPreloading")
}
