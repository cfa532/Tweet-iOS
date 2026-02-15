import SwiftUI

struct FollowingsTweetView: View {
    @StateObject private var viewModel = FollowingsTweetViewModel.shared
    let onAvatarTap: (User) -> Void
    let onTweetTap: (Tweet) -> Void
    let onScroll: ((CGFloat, CGFloat) -> Void)?  // (offset, delta)
    let onShowLogin: (() -> Void)?
    let onShowToast: ((String, Bool) -> Void)?
    
    
    var body: some View {
        TweetListView(
            title: "",
            tweets: $viewModel.tweets,
            tweetFetcher: { page, size, isFromCache in
                let startTime = Date()
                if isFromCache {
                    print("📋 [CACHE LOAD] Fetching page \(page) from cache")
                    let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
                        for: viewModel.hproseInstance.appUser.mid, page: page, pageSize: size, currentUserId: viewModel.hproseInstance.appUser.mid, isProfileView: false)

                    let elapsed = Date().timeIntervalSince(startTime) * 1000
                    let validCount = cachedTweets.compactMap{$0}.count
                    print("✅ [CACHE LOAD] Returned \(validCount) tweets in \(String(format: "%.1f", elapsed))ms - rendering immediately!")
                    return cachedTweets
                } else {
                    print("🌐 [SERVER LOAD] Fetching page \(page) from server")
                    let serverTweets = await viewModel.fetchTweets(page: page, pageSize: size)
                    let elapsed = Date().timeIntervalSince(startTime) * 1000
                    let validCount = serverTweets.compactMap{$0}.count
                    print("✅ [SERVER LOAD] Returned \(validCount) tweets in \(String(format: "%.1f", elapsed))ms")
                    return serverTweets
                }
            },
            showTitle: false,
            notifications: [
                TweetListNotification(
                    name: .newTweetCreated,
                    key: "tweet",
                    shouldAccept: { tweet in
                        print("DEBUG: [FollowingsTweetView] newTweetCreated notification received - tweetId: \(tweet.mid), isPrivate: \(tweet.isPrivate ?? false)")
                        return !(tweet.isPrivate ?? false)
                    },
                    action: { tweet in
                        print("DEBUG: [FollowingsTweetView] Calling handleNewTweet for: \(tweet.mid)")
                        viewModel.handleNewTweet(tweet)
                    }
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
                onScroll?(offset, delta)
            },
            allowDeleteAll: true,
            onAvatarTap: { user in onAvatarTap(user) },
            onTweetTap: { tweet in onTweetTap(tweet) },
            onShowLogin: onShowLogin,
            onShowToast: onShowToast
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
            // TweetListView already handles initial loading with correct pageSize
            // No need to manually trigger here
        }
        .onAppear {
            onScroll?(0, 0)
        }
    }
}
