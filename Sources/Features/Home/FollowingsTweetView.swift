import SwiftUI

@available(iOS 16.0, *)
struct FollowingsTweetView: View {
    @Binding var isLoading: Bool
    let onAvatarTap: (User) -> Void
    @Binding var resetTrigger: Bool
    @Binding var scrollToTopTrigger: Bool
    @EnvironmentObject private var hproseInstance: HproseInstance
    @State private var tweetListView: TweetListView<TweetItemView>?

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
            onAvatarTap: onAvatarTap,
            showTitle: false,
            rowView: { tweet in
                TweetItemView(
                    tweet: tweet,
                    retweet: { tweet in
                        Task {
                            if let retweet = try? await hproseInstance.retweet(tweet),
                               // Update retweet count of the original tweet
                               let updatedOriginalTweet = try? await hproseInstance.updateRetweetCount(
                                tweet: tweet,
                                retweetId: retweet.mid
                               ) {
                                // The TweetListView will handle updating its own state
                                tweet.retweetCount = updatedOriginalTweet.retweetCount
                                tweet.favoriteCount = updatedOriginalTweet.favoriteCount
                                tweet.bookmarkCount = updatedOriginalTweet.bookmarkCount
                                tweet.commentCount = updatedOriginalTweet.commentCount
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
        .background(
            GeometryReader { geometry in
                Color.clear.onAppear {
                    tweetListView = TweetListView<TweetItemView>(
                        title: "Timeline",
                        tweetFetcher: { page, size in
                            try await hproseInstance.fetchTweetFeed(
                                user: hproseInstance.appUser,
                                pageNumber: page,
                                pageSize: size
                            )
                        },
                        onAvatarTap: onAvatarTap,
                        showTitle: false,
                        rowView: { tweet in
                            TweetItemView(
                                tweet: tweet,
                                retweet: { _ in },
                                deleteTweet: { _ in },
                                isInProfile: false,
                                onAvatarTap: onAvatarTap
                            )
                        }
                    )
                }
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
//        .environmentObject(hproseInstance)
    }
}
