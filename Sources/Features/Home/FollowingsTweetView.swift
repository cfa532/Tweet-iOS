import SwiftUI

@available(iOS 16.0, *)
struct FollowingsTweetView: View {
    @Binding var isLoading: Bool
    let onAvatarTap: (User) -> Void
    @Binding var resetTrigger: Bool
    @Binding var scrollToTopTrigger: Bool
    @EnvironmentObject private var hproseInstance: HproseInstance
    @StateObject private var viewModel: FollowingsTweetViewModel

    init(isLoading: Binding<Bool>, onAvatarTap: @escaping (User) -> Void, resetTrigger: Binding<Bool>, scrollToTopTrigger: Binding<Bool>) {
        self._isLoading = isLoading
        self.onAvatarTap = onAvatarTap
        self._resetTrigger = resetTrigger
        self._scrollToTopTrigger = scrollToTopTrigger
        self._viewModel = StateObject(wrappedValue: FollowingsTweetViewModel(hproseInstance: HproseInstance.shared))
    }

    var body: some View {
        ScrollViewReader { proxy in
            TweetListView<TweetItemView>(
                title: "Timeline",
                tweets: $viewModel.tweets,
                tweetFetcher: { page, size, isFromCache in
                    if isFromCache {
                        // Fetch from cache
                        let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
                            for: hproseInstance.appUser.mid, page: page, pageSize: size)
                        await MainActor.run {
                            viewModel.tweets.mergeTweets(cachedTweets.compactMap { $0 })
                        }
                        return cachedTweets
                    } else {
                        // Fetch from server
                        let newTweets = await viewModel.fetchTweets(page: page, pageSize: size)
                        return newTweets
                    }
                },
                showTitle: false,
                notifications: [
                    TweetListNotification(
                        name: .newTweetCreated,
                        key: "tweet",
                        shouldAccept: { _ in true },
                        action: { tweet in viewModel.handleNewTweet(tweet) }
                    ),
                    TweetListNotification(
                        name: .tweetDeleted,
                        key: "tweetId",
                        shouldAccept: { _ in true },
                        action: { tweet in viewModel.handleDeletedTweet(tweet.mid) }
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
                    Task {
                        await MainActor.run {
                            viewModel.tweets.removeAll()
                        }
                    }
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
