import SwiftUI

struct FollowingsTweetView: View {
    @StateObject private var viewModel = FollowingsTweetViewModel.shared
    let onAvatarTap: (User) -> Void
    let onTweetTap: (Tweet) -> Void
    let onScroll: ((CGFloat, CGFloat) -> Void)?  // (offset, delta)
    
    
    var body: some View {
        TweetListView<TweetItemView>(
            title: "",
            tweets: $viewModel.tweets,
            tweetFetcher: { page, size, isFromCache, shouldCache in
                let startTime = Date()
                if isFromCache {
                    print("📋 [FEED LOAD] Fetching page \(page) from CACHE")
                    // Use "main_feed" as special user ID for main feed cache to separate from profile browsing
                    let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
                        for: "main_feed", page: page, pageSize: size, currentUserId: viewModel.hproseInstance.appUser.mid)
                    let elapsed = Date().timeIntervalSince(startTime) * 1000
                    print("✅ [FEED LOAD] Cache returned \(cachedTweets.compactMap{$0}.count) tweets in \(String(format: "%.1f", elapsed))ms")
                    return cachedTweets
                } else {
                    print("🌐 [FEED LOAD] Fetching page \(page) from SERVER")
                    let serverTweets = await viewModel.fetchTweets(page: page, pageSize: size, shouldCache: shouldCache)
                    let elapsed = Date().timeIntervalSince(startTime) * 1000
                    print("✅ [FEED LOAD] Server returned \(serverTweets.compactMap{$0}.count) tweets in \(String(format: "%.1f", elapsed))ms")
                    return serverTweets
                }
            },
            showTitle: false,
            shouldCacheServerTweets: true,
            notifications: [
                TweetListNotification(
                    name: .newTweetCreated,
                    key: "tweet",
                    shouldAccept: { tweet in !(tweet.isPrivate ?? false) },
                    action: { tweet in viewModel.handleNewTweet(tweet) }
                ),
                TweetListNotification(
                    name: .tweetDeleted,
                    key: "tweetId",
                    shouldAccept: { _ in true },
                    action: { tweet in viewModel.handleDeletedTweet(tweet.mid) }
                ),
                TweetListNotification(
                    name: .tweetPrivacyChanged,
                    key: "tweetId",
                    shouldAccept: { _ in true },
                    action: { tweet in viewModel.handleDeletedTweet(tweet.mid) }
                )
            ],
            onScroll: { offset, delta in
                onScroll?(offset, delta) // Pass both offset and delta to parent
            },
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
        .onReceive(NotificationCenter.default.publisher(for: .appUserReady)) { _ in
            // Load page 0 tweets when user is ready (guest or logged-in)
            Task {
                await viewModel.loadPage0Tweets()
            }
        }
        .onAppear {
            onScroll?(0, 0)
        }
    }
}
