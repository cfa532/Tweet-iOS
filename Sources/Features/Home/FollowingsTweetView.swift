import SwiftUI

@available(iOS 16.0, *)
struct FollowingsTweetView: View {
    @Binding var isLoading: Bool
    let onAvatarTap: (User) -> Void
    @Binding var resetTrigger: Bool
    @Binding var scrollToTopTrigger: Bool
    @EnvironmentObject private var hproseInstance: HproseInstance

    var body: some View {
        TweetListView<TweetItemView>(
            title: "Timeline",
            tweetFetcher: { page, size in
                try await hproseInstance.fetchTweetFeed(
                    user: hproseInstance.appUser,
                    pageNumber: page,
                    pageSize: size
                )
            },
            onRetweet: { tweet in
                Task {
                    if let retweet = try? await hproseInstance.retweet(tweet) {
                        // Update retweet count of the original tweet
                        if let updatedOriginalTweet = try? await hproseInstance.updateRetweetCount(
                            tweet: tweet,
                            retweetId: retweet.mid
                        ) {
                            // The TweetListView will handle updating its own state
                        }
                    }
                }
            },
            onDeleteTweet: { tweet in
                // Only allow delete if current user is the author
                if tweet.authorId == hproseInstance.appUser.mid {
                    _ = try? await hproseInstance.deleteTweet(tweet.mid)
                }
            },
            onAvatarTap: onAvatarTap,
            showTitle: false,
            rowView: { tweet in
                TweetItemView(
                    tweet: tweet,
                    retweet: { tweet in
                        Task {
                            if let retweet = try? await hproseInstance.retweet(tweet) {
                                // Update retweet count of the original tweet
                                if let updatedOriginalTweet = try? await hproseInstance.updateRetweetCount(
                                    tweet: tweet,
                                    retweetId: retweet.mid
                                ) {
                                    // The TweetListView will handle updating its own state
                                }
                            }
                        }
                    },
                    deleteTweet: { tweet in
                        Task {
                            if tweet.authorId == hproseInstance.appUser.mid {
                                if let tweetId = try? await hproseInstance.deleteTweet(tweet.mid) {
                                    print("Successfully deleted tweet: \(tweetId)")
                                }
                            }
                        }
                    },
                    isInProfile: false,
                    onAvatarTap: onAvatarTap
                )
            }
        )
        .environmentObject(hproseInstance)
    }
}
