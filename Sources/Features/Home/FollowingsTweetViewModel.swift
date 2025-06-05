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
    private let hproseInstance: HproseInstance
    
    init(hproseInstance: HproseInstance) {
        self.hproseInstance = hproseInstance
    }
    
    func fetchTweets(page: UInt, pageSize: UInt) async -> [Tweet?] {
        // fetch tweets from server
        if let serverTweets = try? await hproseInstance.fetchTweetFeed(
            user: hproseInstance.appUser,
            pageNumber: page,
            pageSize: pageSize
        ) {
            await MainActor.run {
                tweets.mergeTweets(serverTweets.compactMap{ $0 })
            }
            return serverTweets     // including nil
        }
        return Array(repeating: nil, count: Int(pageSize))
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
