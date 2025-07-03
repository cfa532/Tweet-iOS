import SwiftUI

@available(iOS 16.0, *)
struct FollowingsTweetView: View {
    @Binding var isLoading: Bool
    let onAvatarTap: (User) -> Void
    @Binding var selectedTweet: Tweet?
    let onScroll: ((CGFloat) -> Void)?
    @EnvironmentObject private var hproseInstance: HproseInstance
    @StateObject private var viewModel: FollowingsTweetViewModel

    init(isLoading: Binding<Bool>, onAvatarTap: @escaping (User) -> Void, selectedTweet: Binding<Tweet?>, onScroll: ((CGFloat) -> Void)? = nil) {
        self._isLoading = isLoading
        self.onAvatarTap = onAvatarTap
        self._selectedTweet = selectedTweet
        self.onScroll = onScroll
        self._viewModel = StateObject(wrappedValue: FollowingsTweetViewModel(hproseInstance: HproseInstance.shared))
    }

    var body: some View {
        ScrollViewReader { proxy in
            TweetListView<TweetItemView>(
                title: "Timeline",
                tweets: $viewModel.tweets,
                tweetFetcher: { page, size, isFromCache in
                    if isFromCache {
                        // Fetch from cache - don't merge here, let TweetListView handle it
                        return await TweetCacheManager.shared.fetchCachedTweets(
                            for: hproseInstance.appUser.mid, page: page, pageSize: size)
                    } else {
                        // Fetch from server
                        return await viewModel.fetchTweets(page: page, pageSize: size)
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
                onScroll: onScroll,
                rowView: { tweet in
                    TweetItemView(
                        tweet: tweet,
                        isPinned: false,
                        isInProfile: false,
                        onAvatarTap: { user in
                            onAvatarTap(user)
                        },
                        onTap: { tweet in
                            selectedTweet = tweet
                        },
                        onRemove: { tweetId in
                            if let idx = viewModel.tweets.firstIndex(where: { $0.id == tweetId }) {
                                viewModel.tweets.remove(at: idx)
                            }
                        }
                    )
                }
            )
        }
    }
}
