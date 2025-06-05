//
//  FollowingsTweetViewModel.swift
//  Tweet
//
//  Created by 超方 on 2025/6/4.
//

@available(iOS 16.0, *)
class FollowingsTweetViewModel: ObservableObject {
    @Published var tweets: [Tweet] = []
    @Published var isLoading: Bool = false
    private let hproseInstance: HproseInstance
    
    init(hproseInstance: HproseInstance) {
        self.hproseInstance = hproseInstance
    }
    
    func fetchTweets(page: Int, pageSize: Int) async -> [Tweet?] {
        // fetch tweets from server
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
            // If we got fewer tweets than requested, pad with nil to indicate end of feed
            if serverTweets.count < pageSize {
                var result = serverTweets.map { Optional($0) }
                result.append(contentsOf: Array(repeating: nil, count: pageSize - serverTweets.count))
                return result
            }
            return serverTweets.map { Optional($0) }
        }
        return Array(repeating: nil, count: pageSize)
    }
    
    func handleNewTweet(_ tweet: Tweet) {
        tweets.insert(tweet, at: 0)
    }
    
    func handleDeletedTweet(_ tweetId: String) {
        tweets.removeAll { $0.mid == tweetId }
        TweetCacheManager.shared.deleteTweet(mid: tweetId)
    }
}

// MARK: - Tweet Array Extension
extension Array where Element == Tweet {
    /// Merge new tweets into the array, overwriting existing ones with the same mid and appending new ones.
    mutating func mergeTweets(_ newTweets: [Tweet]) {
        print("[TweetListView] Merging \(newTweets.count) tweets")
        // Create a set of existing mids for quick lookup
        let existingMids = Set(self.map { $0.mid })
        
        // Filter out tweets that already exist
        let uniqueNewTweets = newTweets.filter { !existingMids.contains($0.mid) }
        
        // Append new tweets to the end
        self.append(contentsOf: uniqueNewTweets)
        
        print("[TweetListView] After merge: \(self.count) tweets")
    }
}
