import SwiftUI

@available(iOS 16.0, *)
struct FollowingsTweetView: View {
    @Binding var isLoading: Bool
    let onAvatarTap: (User) -> Void
    @Binding var resetTrigger: Bool
    @Binding var scrollToTopTrigger: Bool
    @EnvironmentObject private var hproseInstance: HproseInstance
    @EnvironmentObject private var appUserStore: AppUserStore
    @StateObject private var viewModel: FollowingsTweetViewModel
    @State private var appUser: User = User(mid: Constants.GUEST_ID)

    init(isLoading: Binding<Bool>, onAvatarTap: @escaping (User) -> Void, resetTrigger: Binding<Bool>, scrollToTopTrigger: Binding<Bool>) {
        self._isLoading = isLoading
        self.onAvatarTap = onAvatarTap
        self._resetTrigger = resetTrigger
        self._scrollToTopTrigger = scrollToTopTrigger
        // Initialize with empty instances, will be updated in onAppear
        self._viewModel = StateObject(wrappedValue: FollowingsTweetViewModel(
            hproseInstance: HproseInstance.shared,
            appUserStore: AppUserStore.shared
        ))
    }

    var body: some View {
        ScrollViewReader { proxy in
            TweetListView<TweetItemView>(
                pageSize: 20,
                rowView: { tweet in
                    TweetItemView(
                        tweet: tweet,
                        isInProfile: false,
                        onAvatarTap: onAvatarTap,
                        onRemove: { tweetId in
                            if let idx = viewModel.tweets.firstIndex(where: { $0.id == tweetId }) {
                                viewModel.tweets.remove(at: idx)
                            }
                        }
                    )
                },
                tweetFetcher: { @Sendable page, size, isFromCache in
                    if isFromCache {
                        // Fetch from cache
                        let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
                            for: appUserStore.appUser.mid, page: page, pageSize: size)
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
                ]
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
            .task {
                appUser = await AppUserStore.shared.getAppUser()
            }
            .onAppear {
                // Update view model with the actual environment objects
                viewModel.hproseInstance = hproseInstance
                viewModel.appUserStore = appUserStore
            }
        }
    }
}
