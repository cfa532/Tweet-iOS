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
            showTitle: false,
            rowView: { tweet in
                TweetItemView(
                    tweet: tweet,
                    retweet: { tweet in
                        Task {
                            if let retweet = try? await hproseInstance.retweet(tweet) {
                                // Update retweet count of the original tweet in backend.
                                // tweet, the original tweet now, is updated in the following function.
                               try? await hproseInstance.updateRetweetCount(tweet: tweet, retweetId: retweet.mid)
                            }
                        }
                    },
                    deleteTweet: { tweet in
                        // Only allow delete if current user is the author
                        if tweet.authorId == hproseInstance.appUser.mid {
                            Task {
                                // Post notification for optimistic UI update
                                NotificationCenter.default.post(
                                    name: .tweetDeleted,
                                    object: tweet.mid
                                )
                                
                                do {
                                    // Attempt actual deletion
                                    if let tweetId = try await hproseInstance.deleteTweet(tweet.mid) {
                                        print("Successfully deleted tweet: \(tweetId)")
                                        if let originalTweetId = tweet.originalTweetId,
                                           let originalAuthorId = tweet.originalAuthorId,
                                           let originalTweet = try? await hproseInstance.getTweet(tweetId: originalTweetId, authorId: originalAuthorId) {
                                            // originalTweet is loaded in cache, which is visible to user.
                                            try? await hproseInstance.updateRetweetCount(tweet: originalTweet, retweetId: tweet.mid, direction: false)
                                        }
                                    } else {
                                        // If deletion fails, post restoration notification
                                        NotificationCenter.default.post(
                                            name: .tweetRestored,
                                            object: tweet.mid
                                        )
                                    }
                                } catch {
                                    // If deletion fails, post restoration notification
                                    NotificationCenter.default.post(
                                        name: .tweetRestored,
                                        object: tweet.mid
                                    )
                                }
                            }
                        }
                    },
                    isInProfile: false,
                    onAvatarTap: onAvatarTap
                )
            }
        )
        .onChange(of: resetTrigger) { newValue in
            if newValue {
                resetTrigger = false
            }
        }
        .onChange(of: scrollToTopTrigger) { newValue in
            if newValue {
                scrollToTopTrigger = false
            }
        }
    }
}
