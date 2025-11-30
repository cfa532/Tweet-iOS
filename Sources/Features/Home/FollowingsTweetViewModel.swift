//
//  FollowingsTweetViewModel.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/6/4.
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
    
    func fetchTweets(page: UInt, pageSize: UInt) async -> [Tweet?] {
        let startTime = Date()
        print("🌐 [SERVER FETCH] fetchTweets START - page: \(page), pageSize: \(pageSize)")
        
        // fetch tweets from server
        // Load tweets of alphaId if appUser is a guest user
        if hproseInstance.appUser.isGuest {
            do {
                print("[HproseInstance] Loading tweets for guest user from alphaId")
                if let adminUser = try await hproseInstance.fetchUser(Gadget.getAlphaIds().first ?? "") {
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
            
            // Check for any private tweets that might have slipped through
            for tweet in filteredTweets {
                if tweet.isPrivate == true {
                    print("WARNING: [FollowingsTweetViewModel] Private tweet found in feed: \(tweet.mid) by user: \(tweet.authorId)")
                }
            }
            
            await MainActor.run {
                // Use mergeTweetsSmoothly to prevent layout shifts
                tweets.mergeTweetsSmoothly(filteredTweets)
            }
            
            // Cache main feed tweets under appUser.mid for efficient loading
            let cacheKey = hproseInstance.appUser.mid
            for tweet in serverTweets.compactMap({ $0 }) {
                TweetCacheManager.shared.saveTweet(tweet, userId: cacheKey)
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
                        // Use mergeTweetsSmoothly to prevent layout shifts from background updates
                        tweets.mergeTweetsSmoothly(newTweets.compactMap{ $0 })
                    }
                }
            }
            
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            print("✅ [SERVER FETCH] fetchTweets COMPLETE - loaded \(serverTweets.compactMap{$0}.count) tweets in \(String(format: "%.1f", elapsed))ms")
            return serverTweets     // including nil
        } catch {
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            print("❌ [SERVER FETCH] fetchTweets FAILED in \(String(format: "%.1f", elapsed))ms: \(error)")
            return []
        }
    }
    
    // optimistic UI update
    func handleNewTweet(_ tweet: Tweet?) {
        if let tweet = tweet {
            // Don't show private tweets in the home feed
            if !(tweet.isPrivate ?? false) {
                // For new tweets, use mergeTweets (with sorting) since they should appear at the top
                tweets.mergeTweets([tweet])
                
                // Cache new tweets in main feed under appUser.mid
                TweetCacheManager.shared.saveTweet(tweet, userId: hproseInstance.appUser.mid)
            }
        }
    }
    
    func handleDeletedTweet(_ tweetId: String) {
        tweets.removeAll { $0.mid == tweetId }
        TweetCacheManager.shared.deleteTweet(mid: tweetId)
        // Also remove from main feed cache if it exists there
        // Note: deleteTweet removes by tweet ID, so it will remove from all caches
    }
    
    // Remove all tweets from a specific user (e.g., when unfollowing)
    func removeTweetsFromUser(_ userId: MimeiId) {
        let removedCount = tweets.filter { $0.authorId == userId }.count
        print("[FollowingsTweetViewModel] Removing \(removedCount) tweets from user \(userId)")
        
        // Remove from displayed tweets array
        tweets.removeAll { $0.authorId == userId }
        
        // Remove from local cache
        TweetCacheManager.shared.deleteTweetsFromUser(userId: userId, cacheKey: hproseInstance.appUser.mid)
    }
    
    // Fetch and add recent tweets from a newly followed user
    func addTweetsFromNewlyFollowedUser(_ user: User) async {
        do {
            print("[FollowingsTweetViewModel] Fetching recent tweets from newly followed user: \(user.mid)")
            
            // Fetch first page of user's tweets (10 tweets should be enough for initial display)
            let userTweets = try await hproseInstance.fetchUserTweets(
                user: user,
                pageNumber: 0,
                pageSize: 10
            )
            
            // Filter out nils and private tweets
            let validTweets = userTweets.compactMap { $0 }.filter { !($0.isPrivate ?? false) }
            
            print("[FollowingsTweetViewModel] Got \(validTweets.count) valid tweets from newly followed user \(user.mid)")
            
            if !validTweets.isEmpty {
                await MainActor.run {
                    // Add tweets to the feed (mergeTweets will sort them by timestamp)
                    tweets.mergeTweets(validTweets)
                }
                
                // Cache newly followed user's tweets under appUser.mid for main feed
                let cacheKey = hproseInstance.appUser.mid
                for tweet in validTweets {
                    TweetCacheManager.shared.saveTweet(tweet, userId: cacheKey)
                }
                
                print("[FollowingsTweetViewModel] Added and cached \(validTweets.count) tweets from newly followed user")
            }
        } catch {
            print("[FollowingsTweetViewModel] Error fetching tweets from newly followed user \(user.mid): \(error)")
        }
    }
    
    func showTweetDetail(_ tweet: Tweet) {
        selectedTweet = tweet
        showTweetDetail = true
    }
    
    // Method to clear tweets when user logs in/out
    func clearTweets() {
        tweets.removeAll()
        // Don't clear cache on logout - cache persists per user and is cleared periodically or manually
    }
    
    // Method to load page 0 tweets when app user is ready
    func loadPage0Tweets() async {
        print("[FollowingsTweetViewModel] Loading page 0 tweets for user: \(hproseInstance.appUser.mid)")
        let serverTweets = await fetchTweets(page: 0, pageSize: 20)
        print("[FollowingsTweetViewModel] Loaded \(serverTweets.compactMap { $0 }.count) tweets")
    }
}
