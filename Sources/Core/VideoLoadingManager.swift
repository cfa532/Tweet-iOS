//
//  VideoLoadingManager.swift
//  Tweet
//
//  Manages video loading and preloading based on tweet visibility
//

import Foundation
import SwiftUI

@MainActor
class VideoLoadingManager: ObservableObject {
    static let shared = VideoLoadingManager()
    
    private init() {}
    
    // MARK: - State
    @Published private(set) var visibleTweetIds: Set<String> = []
    @Published private(set) var currentVisibleTweetIndex: Int = 0
    private var allTweetIds: [String] = []
    
    // MARK: - Configuration
    private let preloadCount = 3 // Number of tweets to preload ahead
    private let bufferDistance = 1 // Keep 1 tweet behind as buffer
    
    // MARK: - Public Methods
    
    /// Update the list of all tweet IDs (called when tweet list changes)
    func updateTweetList(_ tweetIds: [String]) {
        allTweetIds = tweetIds
        print("DEBUG: [VideoLoadingManager] Updated tweet list with \(tweetIds.count) tweets")
    }
    
    /// Update the currently visible tweet index
    func updateVisibleTweetIndex(_ index: Int) {
        guard index >= 0 && index < allTweetIds.count else { return }
        
        let previousIndex = currentVisibleTweetIndex
        currentVisibleTweetIndex = index
        
        print("DEBUG: [VideoLoadingManager] Visible tweet changed from index \(previousIndex) to \(index)")
        
        // Update visible tweet IDs
        updateVisibleTweetIds()
        
        // Manage video loading
        manageVideoLoading()
    }
    
    /// Check if a tweet should load videos
    func shouldLoadVideos(for tweetId: String) -> Bool {
        guard let index = allTweetIds.firstIndex(of: tweetId) else { return false }
        
        // Only load videos for current visible tweet and next few tweets
        let distance = index - currentVisibleTweetIndex
        return distance >= 0 && distance <= preloadCount
    }
    
    /// Check if a tweet should preload videos
    func shouldPreloadVideos(for tweetId: String) -> Bool {
        guard let index = allTweetIds.firstIndex(of: tweetId) else { return false }
        
        // Preload if tweet is within the next 3 tweets
        let distance = index - currentVisibleTweetIndex
        return distance > 0 && distance <= preloadCount
    }
    
    /// Check if a tweet should cancel video loading
    func shouldCancelVideoLoading(for tweetId: String) -> Bool {
        guard let index = allTweetIds.firstIndex(of: tweetId) else { return false }
        
        // Cancel if tweet is behind the current visible tweet (with small buffer)
        let distance = currentVisibleTweetIndex - index
        return distance > 1  // Only keep 1 tweet behind as buffer
    }
    
    // MARK: - Private Methods
    
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
    
    private func manageVideoLoading() {
        // Cancel loading for tweets that are too far behind
        for (index, tweetId) in allTweetIds.enumerated() {
            if shouldCancelVideoLoading(for: tweetId) {
                cancelVideoLoading(for: tweetId)
                print("DEBUG: [VideoLoadingManager] Cancelled video loading for tweet \(tweetId) at index \(index)")
            }
        }
        
        // Trigger preloading for upcoming tweets
        for i in 1...preloadCount {
            let index = currentVisibleTweetIndex + i
            if index < allTweetIds.count {
                let tweetId = allTweetIds[index]
                if shouldPreloadVideos(for: tweetId) {
                    triggerVideoPreloading(for: tweetId)
                    print("DEBUG: [VideoLoadingManager] Triggered video preloading for tweet \(tweetId) at index \(index)")
                }
            }
        }
    }
    
    private func cancelVideoLoading(for tweetId: String) {
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
        // Trigger video preloading for this tweet
        // This will be implemented by calling SharedAssetCache methods
        
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
