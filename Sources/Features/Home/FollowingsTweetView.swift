import SwiftUI

@available(iOS 16.0, *)
struct FollowingsTweetView: View {
    @State private var tweets: [Tweet] = []
    @Binding var isLoading: Bool
    let onAvatarTap: (User) -> Void

    private let hproseInstance = HproseInstance.shared

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach($tweets) { $tweet in
                    TweetItemView(
                        tweet: $tweet,
                        retweet: { tweet in
                            await retweet(tweet)
                        },
                        deleteTweet: deleteTweet,
                        isInProfile: false,
                        onAvatarTap: onAvatarTap
                    )
                    .id(tweet.id)
                }
                if isLoading {
                    ProgressView()
                        .padding()
                }
            }
        }
        .refreshable {
            await loadInitialTweets()
        }
        .onAppear {
            if tweets.isEmpty {
                Task {
                    await loadInitialTweets()
                }
            }
        }
    }
    
    func loadInitialTweets() async {
        isLoading = true
        do {
            tweets = try await hproseInstance.fetchTweetFeed(
                user: hproseInstance.appUser, startRank: 0, endRank: 20
            )
        } catch {
            print("Error loading tweets: \(error)")
        }
        isLoading = false
    }
    
    
    func retweet(_ tweet: Tweet) async {
        do {
            if let retweet = try await hproseInstance.retweet(tweet) {
                // Insert retweet at the beginning of the array
                tweets.insert(retweet, at: 0)
                
                // update retweet count of the original tweet
                if let updatedOriginalTweet = try await hproseInstance.updateRetweetCount(tweet: tweet, retweetId: retweet.mid) {
                    if let index = tweets.firstIndex(where: { $0.id == updatedOriginalTweet.mid }) {
                        tweets[index] = updatedOriginalTweet
                    }
                } else {
                    print("Update of the original tweet failed. \(tweet) \(retweet)")
                }
            } else {
                print("Retweet failed. \(tweet)")
            }
        } catch {
            print("Error retweeting: \(error) \(tweet)")
        }
    }

    func deleteTweet(_ tweet: Tweet) async {
        // Remove from UI immediately
        tweets.removeAll { $0.id == tweet.mid }
        
        // Handle deletion in background
        Task.detached {
            do {
                if let tweetId = try await hproseInstance.deleteTweet(tweet.mid) {
                    print("Successfully deleted tweet: \(tweetId)")
                } else {
                    print("Error deleting tweet: \(tweet)")
                    // Optionally, you could add the tweet back to the UI here if deletion failed
                    await MainActor.run {
                        tweets.append(tweet)
                    }
                }
            } catch {
                print("Error deleting tweet: \(error)")
                // Optionally, you could add the tweet back to the UI here if deletion failed
                await MainActor.run {
                    tweets.append(tweet)
                }
            }
        }
    }
}
