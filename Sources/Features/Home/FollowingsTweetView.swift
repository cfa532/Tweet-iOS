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
                // Logic handled in TweetListView for immediate UI update and toast
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
                    retweet: { _ in },
                    deleteTweet: { _ in },
                    isInProfile: false,
                    onAvatarTap: onAvatarTap
                )
            }
        )
    }
}
