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
    private let hproseInstance: HproseInstance
    
    init(hproseInstance: HproseInstance) {
        self.hproseInstance = hproseInstance
    }
    
    func fetchTweets(page: UInt, pageSize: UInt) async -> [Tweet?] {
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
            await MainActor.run {
                tweets.mergeTweets(serverTweets.compactMap{ $0 })
            }
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
            return serverTweets     // including nil
        } catch {
            print("[FollowingsTweetViewModel] Error fetching tweets: \(error)")
            return []
        }
    }
    
    // optimistic UI update
    func handleNewTweet(_ tweet: Tweet?) {
        if let tweet = tweet {
            tweets.insert(tweet, at: 0)
        }
    }
    
    func handleDeletedTweet(_ tweetId: String) {
        tweets.removeAll { $0.mid == tweetId }
        TweetCacheManager.shared.deleteTweet(mid: tweetId)
    }
    
    func showTweetDetail(_ tweet: Tweet) {
        selectedTweet = tweet
        showTweetDetail = true
    }
}
