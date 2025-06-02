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
                        do {
                            let currentCount = tweet.retweetCount ?? 0
                            tweet.retweetCount = currentCount + 1

                            if let retweet = try await hproseInstance.retweet(tweet) {
                                NotificationCenter.default.post(name: .newTweetCreated,
                                                                object: nil,
                                                                userInfo: ["tweet": retweet])
                                // Update retweet count of the original tweet in backend.
                                // tweet, the original tweet now, is updated in the following function.
                                try? await hproseInstance.updateRetweetCount(tweet: tweet, retweetId: retweet.mid)
                            }
                        } catch {
                            print("Retweet failed in FollowingsTweetView")
                        }
                    },
                    deleteTweet: { tweet in
                        // Post notification for optimistic UI update
                        NotificationCenter.default.post(
                            name: .tweetDeleted,
                            object: tweet.mid
                        )
                        
                        // Attempt actual deletion
                        if let tweetId = try? await hproseInstance.deleteTweet(tweet.mid) {
                            print("Successfully deleted tweet: \(tweetId)")
                            if let originalTweetId = tweet.originalTweetId,
                               let originalAuthorId = tweet.originalAuthorId,
                               let originalTweet = try? await hproseInstance.getTweet(
                                tweetId: originalTweetId,
                                authorId: originalAuthorId)
                            {
                                // originalTweet is loaded in cache, which is visible to user.
                                let currentCount = originalTweet.retweetCount ?? 0
                                originalTweet.retweetCount = max(0, currentCount - 1)
                                try? await hproseInstance.updateRetweetCount(tweet: originalTweet, retweetId: tweet.mid, direction: false)
                            }
                        } else {
                            // If deletion fails, post restoration notification
                            NotificationCenter.default.post(
                                name: .tweetRestored,
                                object: tweet.mid
                            )
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
