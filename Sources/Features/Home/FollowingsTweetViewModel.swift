//
//  FollowingsTweetViewModel.swift
//  Tweet
//
//  Created by 超方 on 2025/6/4.
//

// MARK: - Tweet Array Extension
extension Array where Element == Tweet {
    /// Merge new tweets into the array, overwriting existing ones with the same mid and appending new ones.
    mutating func mergeTweets(_ newTweets: [Tweet]) {
        var tweetDict = Dictionary(uniqueKeysWithValues: self.map { ($0.mid, $0) })
        for tweet in newTweets {
            tweetDict[tweet.mid] = tweet // Overwrite if exists, insert if not
        }
        // Preserve order: existing tweets first, then new ones not already present
        let existingOrder = self.map { $0.mid }
        let newOrder = newTweets.map { $0.mid }.filter { !existingOrder.contains($0) }
        self = existingOrder.compactMap { tweetDict[$0] } + newOrder.compactMap { tweetDict[$0] }
    }
}

@available(iOS 16.0, *)
class FollowingsTweetViewModel: ObservableObject {
    @Published var tweets: [Tweet] = []
    @Published var isLoading: Bool = false
    private let hproseInstance: HproseInstance
    
    init(hproseInstance: HproseInstance) {
        self.hproseInstance = hproseInstance
    }
    
    func fetchTweets(page: Int, pageSize: Int) async {
        let cachedTweets = TweetCacheManager.shared.fetchCachedTweets(
            for: hproseInstance.appUser.mid,
            page: page,
            pageSize: pageSize
        )
        let validCached = cachedTweets.compactMap { $0 }
        await MainActor.run {
            tweets.mergeTweets(validCached)
        }

        if let serverTweets = try? await hproseInstance.fetchTweetFeed(
            user: hproseInstance.appUser,
            pageNumber: page,
            pageSize: pageSize
        ) {
            await MainActor.run {
                tweets.mergeTweets(serverTweets)
            }
            // Update cached tweets with server-fetched tweets
            for tweet in serverTweets {
                TweetCacheManager.shared.saveTweet(tweet, mid: tweet.mid, userId: hproseInstance.appUser.mid)
            }
        }
    }
    
    func handleNewTweet(_ tweet: Tweet) {
        tweets.insert(tweet, at: 0)
    }
    
    func handleDeletedTweet(_ tweetId: String) {
        tweets.removeAll { $0.mid == tweetId }
        TweetCacheManager.shared.deleteTweet(mid: tweetId)
    }
}

