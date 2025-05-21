import SwiftUI

struct FollowingsTweetView: View {
    @State private var tweets: [Tweet] = []
    @Binding var isLoading: Bool

    let onAvatarTap: (User) -> Void

    private let hproseInstance = HproseInstance.shared

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(tweets) { tweet in
                    TweetItemView(
                        tweet: tweet,
                        retweet: retweet,
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
        }
        .onAppear {
            if tweets.isEmpty {
                Task {
                    await loadInitialTweets()
                }
            }
        }
        .task {
            await loadInitialTweets()
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
        do {
            if let tweetId = try await hproseInstance.deleteTweet(tweet.id) {
                tweets.removeAll { $0.id == tweetId }
            } else {
                print("Error deleting tweet: \(tweet)")
            }
        } catch {
            print("Error deleting tweet: \(error)")
        }
    }
}
