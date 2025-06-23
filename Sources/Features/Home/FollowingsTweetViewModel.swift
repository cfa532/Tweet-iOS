//
//  FollowingsTweetViewModel.swift
//  Tweet
//
//  Created by 超方 on 2025/6/4.
//

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
        do {
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
                    entry: "update_following_tweets"
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
