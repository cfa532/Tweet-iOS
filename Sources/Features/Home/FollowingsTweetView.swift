import SwiftUI

@available(iOS 16.0, *)
struct FollowingsTweetView: View {
    @Binding var isLoading: Bool
    let onAvatarTap: (User) -> Void
    @Binding var resetTrigger: Bool
    @Binding var scrollToTopTrigger: Bool
    @EnvironmentObject private var hproseInstance: HproseInstance

    var body: some View {
        ScrollViewReader { proxy in
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
                notifications: [
                    TweetListNotification(
                        name: .newTweetCreated,
                        key: "tweet",
                        shouldAccept: { _ in true },
                        action: { tweets, tweet in tweets.insert(tweet, at: 0) }
                    ),
                    TweetListNotification(
                        name: .tweetDeleted,
                        key: "tweetId",
                        shouldAccept: { _ in true },
                        action: { tweets, tweet in tweets.removeAll { $0?.mid == tweet.mid } }
                    )
                ],
                rowView: { tweet in
                    TweetItemView(
                        tweet: tweet,
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
                    withAnimation {
                        proxy.scrollTo("top", anchor: .top)
                    }
                    scrollToTopTrigger = false
                }
            }
        }
    }
}
