//
//  FollowingsTweetViewModel.swift
//  Tweet
//
//  Created by 超方 on 2025/6/4.
//

@available(iOS 16.0, *)
@MainActor
class FollowingsTweetViewModel: ObservableObject {
    @Published var tweets: [Tweet] = []     // tweet list to be displayed on screen.
    @Published var isLoading: Bool = false
    var hproseInstance: HproseInstance
    var appUserStore: AppUserStore
    
    init(hproseInstance: HproseInstance, appUserStore: AppUserStore) {
        self.hproseInstance = hproseInstance
        self.appUserStore = appUserStore
    }
    
    func fetchTweets(page: UInt, pageSize: UInt) async -> [Tweet?] {
        // fetch tweets from server
        do {
            let serverTweets = try await hproseInstance.fetchTweetFeed(
                user: appUserStore.appUser,
                pageNumber: page,
                pageSize: pageSize
            )
            tweets.mergeTweets(serverTweets.compactMap{ $0 })
            return serverTweets     // including nil
        } catch {
            print("[FollowingsTweetViewModel] Error fetching tweets: \(error)")
            return Array(repeating: nil, count: Int(pageSize))
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
}
