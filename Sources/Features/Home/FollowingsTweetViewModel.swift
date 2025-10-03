//
//  FollowingsTweetViewModel.swift
//  Tweet
//
//  Created by 超方 on 2025/6/4.
//

import AVFoundation
import UIKit

@available(iOS 16.0, *)
class FollowingsTweetViewModel: ObservableObject {
    @Published var tweets: [Tweet] = []     // tweet list to be displayed on screen.
    @Published var isLoading: Bool = false
    @Published var showTweetDetail: Bool = false
    @Published var selectedTweet: Tweet?
    let hproseInstance: HproseInstance
    
    // Shared instance to keep tweets in memory across navigation
    static let shared = FollowingsTweetViewModel(hproseInstance: HproseInstance.shared)
    
    init(hproseInstance: HproseInstance) {
        self.hproseInstance = hproseInstance
    }
    
    func fetchTweets(page: UInt, pageSize: UInt, shouldCache: Bool = true) async -> [Tweet?] {
        // fetch tweets from server
        // Load tweets of alphaId if appUser is a guest user
        if hproseInstance.appUser.isGuest {
            do {
                print("[HproseInstance] Loading tweets for guest user from alphaId")
                if let adminUser = try await hproseInstance.fetchUser(AppConfig.alphaId) {
                    let serverTweets = try await hproseInstance.fetchUserTweets(user: adminUser, pageNumber: 0, pageSize: 20)
                    print("[HproseInstance] Loaded \(serverTweets.compactMap { $0 }.count) tweets for guest user")
                    await MainActor.run {
                        tweets.mergeTweets(serverTweets.compactMap{ $0 })
                    }
                    return serverTweets
                }
            } catch {
                print("[HproseInstance] Error loading tweets for guest user: \(error)")
                // Don't throw here, allow the app to continue even if tweet loading fails
            }
            return []
        }
        
        do {
            /// The backend may return an array containing nils. If the returned array size is less than pageSize, it means there are no more tweets on the backend.
            /// This function accumulates only non-nil tweets and stops fetching when the backend returns fewer than pageSize items.
            let serverTweets = try await hproseInstance.fetchTweetFeed(
                user: hproseInstance.appUser,
                pageNumber: page,
                pageSize: pageSize
            )
            let filteredTweets = serverTweets.compactMap{ $0 }
            
            // Debug: Log all tweets and their privacy status
            print("DEBUG: [FollowingsTweetViewModel] Processing \(filteredTweets.count) tweets from server")
            for tweet in filteredTweets {
                print("DEBUG: [FollowingsTweetViewModel] Tweet: \(tweet.mid), isPrivate: \(tweet.isPrivate ?? false), authorId: \(tweet.authorId)")
                if tweet.isPrivate == true {
                    print("DEBUG: [FollowingsTweetViewModel] WARNING: Private tweet found in feed: \(tweet.mid) by user: \(tweet.authorId)")
                }
            }
            
            await MainActor.run {
                tweets.mergeTweets(filteredTweets)
            }
            
            // Cache tweets if shouldCache is true - use "main_feed" as special user ID for main feed cache
            if shouldCache {
                for tweet in serverTweets.compactMap({ $0 }) {
                    TweetCacheManager.shared.saveTweet(tweet, userId: "main_feed")
                }
            }
            if page == 0 {
                // only check for new tweets from followings on initial load.
                Task {
                    let newTweets = try await hproseInstance.fetchTweetFeed(
                        user: hproseInstance.appUser,
                        pageNumber: page,
                        pageSize: pageSize,
                        entry: "update_following_tweets"    // check for new tweets have not been synced.
                    )
                    await MainActor.run {
                        tweets.mergeTweets(newTweets.compactMap{ $0 })
                    }
                }
            }
            return serverTweets     // including nil
        } catch {
            print("[FollowingsTweetViewModel] Error fetching tweets: \(error)")
            return []
        }
    }
    
    // optimistic UI update
    func handleNewTweet(_ tweet: Tweet?) {
        if let tweet = tweet {
            // Don't show private tweets in the home feed
            if !(tweet.isPrivate ?? false) {
                // Use mergeTweets to maintain proper chronological ordering
                tweets.mergeTweets([tweet])
                
                // Cache the new tweet so it persists across app restarts
                TweetCacheManager.shared.saveTweet(tweet, userId: "main_feed")
                print("DEBUG: [FollowingsTweetViewModel] Cached new tweet: \(tweet.mid)")
            }
        }
    }
    
    func handleDeletedTweet(_ tweetId: String) {
        tweets.removeAll { $0.mid == tweetId }
        TweetCacheManager.shared.deleteTweet(mid: tweetId)
        // Also remove from main feed cache if it exists there
        // Note: deleteTweet removes by tweet ID, so it will remove from all caches
    }
    
    func showTweetDetail(_ tweet: Tweet) {
        selectedTweet = tweet
        showTweetDetail = true
    }
    
    // Method to clear tweets when user logs in/out
    func clearTweets() {
        tweets.removeAll()
        // Clear main feed cache when user logs in/out
        TweetCacheManager.shared.clearCacheForUser(userId: "main_feed")
    }
    
    // Method to load page 0 tweets when app user is ready
    func loadPage0Tweets() async {
        print("[FollowingsTweetViewModel] Loading page 0 tweets for user: \(hproseInstance.appUser.mid)")
        let serverTweets = await fetchTweets(page: 0, pageSize: 20, shouldCache: true)
        print("[FollowingsTweetViewModel] Loaded \(serverTweets.compactMap { $0 }.count) tweets")
    }
}
