import SwiftUI

@available(iOS 16.0, *)
struct FollowingsTweetView: View {
    @Binding var isLoading: Bool
    let onAvatarTap: (User) -> Void
    @Binding var resetTrigger: Bool
    @Binding var scrollToTopTrigger: Bool
    @EnvironmentObject private var hproseInstance: HproseInstance

    var body: some View {
        TweetListView(
            title: "Timeline",
            tweetFetcher: { page, size in
                try await hproseInstance.fetchTweetFeed(
                    user: hproseInstance.appUser,
                    pageNumber: page,
                    pageSize: size
                )
            },
            onRetweet: nil,
            onDeleteTweet: nil,
            onAvatarTap: onAvatarTap,
            showTitle: false
        )
    }
}
