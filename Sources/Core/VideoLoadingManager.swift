//
//  VideoLoadingManager.swift
//  Tweet
//
//  Manages video loading and preloading based on tweet visibility with performance optimizations
//

import Foundation
import SwiftUI

@MainActor
class VideoLoadingManager: ObservableObject {
    static let shared = VideoLoadingManager()
    
    private init() {
        setupPerformanceMonitoring()
    }
    
    // MARK: - State
    @Published private(set) var visibleTweetIds: Set<String> = []
    @Published private(set) var currentVisibleTweetIndex: Int = 0
    private var allTweetIds: [String] = []
    private var tweetsWithVideos: Set<String> = [] // Track which tweets contain videos
    
    // MARK: - Performance Management
    private var activeLoadingCount: Int = 0
    private let maxConcurrentLoads: Int = 2 // Limit concurrent video loads to prevent UI freezes
    private var loadingQueue: [String] = [] // Queue for pending video loads
    private var isProcessingQueue = false
    
    // MARK: - Configuration
    private let preloadCount = 2 // Reduced from 3 to 2 to prevent excessive loading
    private let bufferDistance = 1 // Keep 1 tweet behind as buffer
    
    // MARK: - Performance Monitoring
    private var lastLoadTime: Date = Date()
    private var loadCountInLastMinute: Int = 0
    
    // MARK: - Public Methods
    
    /// Update the list of all tweet IDs (called when tweet list changes)
    func updateTweetList(_ tweetIds: [String]) {
        allTweetIds = tweetIds
        print("DEBUG: [VideoLoadingManager] Updated tweet list with \(tweetIds.count) tweets")
    }
    
    /// Register a tweet as containing videos
    func registerTweetWithVideos(_ tweetId: String) {
        tweetsWithVideos.insert(tweetId)
        print("DEBUG: [VideoLoadingManager] Registered tweet \(tweetId) as containing videos")
    }
    
    /// Update the currently visible tweet index
    func updateVisibleTweetIndex(_ index: Int) {
        guard index >= 0 && index < allTweetIds.count else { return }
        
        let previousIndex = currentVisibleTweetIndex
        currentVisibleTweetIndex = index
        
        print("DEBUG: [VideoLoadingManager] Visible tweet changed from index \(previousIndex) to \(index)")
        
        // Update visible tweet IDs
        updateVisibleTweetIds()
        
        // Manage video loading with performance considerations
        manageVideoLoadingWithPerformance()
    }
    
    /// Check if a tweet should load videos (with performance throttling)
    func shouldLoadVideos(for tweetId: String) -> Bool {
        guard let index = allTweetIds.firstIndex(of: tweetId) else { return false }
        
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
        
        // Check performance monitor
        if !PerformanceMonitor.shared.canLoadMoreVideos() {
            print("DEBUG: [VideoLoadingManager] Throttling video load for \(tweetId) - performance monitor blocked")
            return false
        }
        
        // Only load videos for current visible tweet and next few tweets (NOT past tweets)
        let distance = index - currentVisibleTweetIndex
        return distance >= 0 && distance <= preloadCount
    }
    
    /// Check if a tweet should preload videos
    func shouldPreloadVideos(for tweetId: String) -> Bool {
        guard let index = allTweetIds.firstIndex(of: tweetId) else { return false }
        
        // Only preload if the tweet actually contains videos
        guard tweetsWithVideos.contains(tweetId) else { return false }
        
        // Check performance constraints
        if activeLoadingCount >= maxConcurrentLoads {
            return false
        }
        
        // Preload if tweet is within the next 2 tweets (reduced from 3)
        let distance = index - currentVisibleTweetIndex
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
        
        // Notify performance monitor
        PerformanceMonitor.shared.videoLoadStarted()
    }
    
    /// Notify that a video load has completed
    func videoLoadCompleted() {
        activeLoadingCount = max(0, activeLoadingCount - 1)
        print("DEBUG: [VideoLoadingManager] Video load completed. Active loads: \(activeLoadingCount)")
        
        // Notify performance monitor
        PerformanceMonitor.shared.videoLoadCompleted()
        
        // Process queue if there are pending loads
        if !loadingQueue.isEmpty && !isProcessingQueue {
            processLoadingQueue()
        }
    }
    
    // MARK: - Private Methods
    
    private func setupPerformanceMonitoring() {
        // Reset load count every minute
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
            Task { @MainActor in
                self.loadCountInLastMinute = 0
            }
        }
    }
    
    private func isLoadingTooFrequently() -> Bool {
        let timeSinceLastLoad = Date().timeIntervalSince(lastLoadTime)
        return timeSinceLastLoad < 0.5 && loadCountInLastMinute > 10 // Throttle if loading too frequently
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
        print("DEBUG: [VideoLoadingManager] Updated visible tweet IDs: \(visibleTweetIds)")
    }
    
    private func manageVideoLoadingWithPerformance() {
        print("DEBUG: [VideoLoadingManager] Managing video loading for visible tweet index: \(currentVisibleTweetIndex)")
        
        // Cancel loading for tweets that are too far behind
        for (index, tweetId) in allTweetIds.enumerated() {
            if shouldCancelVideoLoading(for: tweetId) {
                cancelVideoLoading(for: tweetId)
                print("DEBUG: [VideoLoadingManager] Cancelled video loading for tweet \(tweetId) at index \(index)")
            }
        }
        
        // Trigger preloading for upcoming tweets with performance limits
        for i in 1...preloadCount {
            let index = currentVisibleTweetIndex + i
            if index < allTweetIds.count {
                let tweetId = allTweetIds[index]
                if shouldPreloadVideos(for: tweetId) {
                    if activeLoadingCount < maxConcurrentLoads {
                        triggerVideoPreloading(for: tweetId)
                        print("DEBUG: [VideoLoadingManager] Triggered video preloading for tweet \(tweetId)")
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
                
                // Small delay to prevent overwhelming the system
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }
            
            isProcessingQueue = false
        }
    }
    
    private func cancelVideoLoading(for tweetId: String) {
        // Remove from queue if present
        loadingQueue.removeAll { $0 == tweetId }
        
        // Cancel any ongoing video loading tasks for this tweet
        Task { @MainActor in
            SharedAssetCache.shared.cancelLoadingForTweet(tweetId)
        }
        
        // Post notification for MediaGridView to handle
        NotificationCenter.default.post(
            name: .cancelVideoLoading,
            object: nil,
            userInfo: ["tweetId": tweetId]
        )
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
}

// MARK: - Notification Names
extension Notification.Name {
    static let cancelVideoLoading = Notification.Name("cancelVideoLoading")
    static let triggerVideoPreloading = Notification.Name("triggerVideoPreloading")
}
