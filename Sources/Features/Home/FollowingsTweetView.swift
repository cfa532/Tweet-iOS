import SwiftUI

@available(iOS 16.0, *)
struct FollowingsTweetView: View {
    let onAvatarTap: (User) -> Void
    @Binding var selectedTweet: Tweet?
    let onScroll: ((CGFloat) -> Void)?
    @EnvironmentObject private var hproseInstance: HproseInstance
    @StateObject private var viewModel: FollowingsTweetViewModel

    init(onAvatarTap: @escaping (User) -> Void, selectedTweet: Binding<Tweet?>, onScroll: ((CGFloat) -> Void)? = nil) {
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
                        let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
                            for: hproseInstance.appUser.mid, page: page, pageSize: size, currentUserId: hproseInstance.appUser.mid)
                        // Filter out private tweets from cache for following view
                        let filteredCachedTweets = cachedTweets.compactMap { $0 }.filter { !($0.isPrivate ?? false) }
                        return filteredCachedTweets.map { Optional($0) }
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
                        shouldAccept: { tweet in
                            // Don't show private tweets in the home feed
                            !(tweet.isPrivate ?? false)
                        },
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
            .onDisappear {
                print("DEBUG: [FollowingsTweetView] View disappeared")
            }
        }
    }
    

}
