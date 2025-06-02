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
