import SwiftUI

@available(iOS 16.0, *)
struct FollowingsTweetView: View {
    let onAvatarTap: (User) -> Void
    let onTweetTap: (Tweet) -> Void
    let onScroll: ((CGFloat) -> Void)?
    @EnvironmentObject private var hproseInstance: HproseInstance
    // Use a shared view model instance to keep tweets in memory
    @StateObject private var viewModel: FollowingsTweetViewModel

    init(onAvatarTap: @escaping (User) -> Void, onTweetTap: @escaping (Tweet) -> Void, onScroll: ((CGFloat) -> Void)? = nil) {
        self.onAvatarTap = onAvatarTap
        self.onTweetTap = onTweetTap
        self.onScroll = onScroll
        // Use shared instance to keep tweets in memory across navigation
        self._viewModel = StateObject(wrappedValue: FollowingsTweetViewModel.shared)
    }

    var body: some View {
        ScrollViewReader { proxy in
            TweetListView<TweetItemView>(
                title: NSLocalizedString("Timeline", comment: "Timeline view title"),
                tweets: $viewModel.tweets,
                tweetFetcher: { page, size, isFromCache, shouldCache in
                    if isFromCache {
                        // Fetch from cache - don't merge here, let TweetListView handle it
                        let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
                            for: hproseInstance.appUser.mid, page: page, pageSize: size, currentUserId: hproseInstance.appUser.mid)
                        // Filter out private tweets from cache for following view
                        let filteredCachedTweets = cachedTweets.compactMap { $0 }.filter { !($0.isPrivate ?? false) }
                        return filteredCachedTweets.map { Optional($0) }
                    } else {
                        // Fetch from server
                        return await viewModel.fetchTweets(page: page, pageSize: size, shouldCache: shouldCache)
                    }
                },
                showTitle: false, shouldCacheServerTweets: true,
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
                        showDeleteButton: true,
                        onAvatarTap: { user in
                            onAvatarTap(user)
                        },
                        onTap: { tweet in
                            onTweetTap(tweet)
                        },
                        onRemove: { tweetId in
                            if let idx = viewModel.tweets.firstIndex(where: { $0.id == tweetId }) {
                                viewModel.tweets.remove(at: idx)
                            }
                        }
                    )
                }
            )
            .onReceive(NotificationCenter.default.publisher(for: .tweetDeleted)) { notification in
                // Handle blocked user tweets removal
                if let blockedUserId = notification.userInfo?["blockedUserId"] as? String {
                    let originalCount = viewModel.tweets.count
                    viewModel.tweets.removeAll { $0.authorId == blockedUserId }
                    let removedCount = originalCount - viewModel.tweets.count
                    print("[FollowingsTweetView] Removed \(removedCount) tweets from blocked user: \(blockedUserId)")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .userDidLogin)) { _ in
                // Clear tweets and refresh when user logs in
                Task {
                    await MainActor.run {
                        viewModel.clearTweets()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .userDidLogout)) { _ in
                // Clear tweets and refresh when user logs out
                Task {
                    await MainActor.run {
                        viewModel.clearTweets()
                    }
                }
            }
            .onDisappear {
                print("DEBUG: [FollowingsTweetView] View disappeared")
            }
        }
    }
    

}
