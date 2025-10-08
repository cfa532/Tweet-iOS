import SwiftUI

struct FollowingsTweetView: View {
    @StateObject private var viewModel = FollowingsTweetViewModel.shared
    let onAvatarTap: (User) -> Void
    let onTweetTap: (Tweet) -> Void
    let onScroll: ((CGFloat) -> Void)?
    
    // Scroll detection state (same as ProfileView)
    @State private var isNavigationVisible = true
    @State private var previousScrollOffset: CGFloat = 0
    
    var body: some View {
        TweetListView<TweetItemView>(
            title: "",
            tweets: $viewModel.tweets,
            tweetFetcher: { page, size, isFromCache, shouldCache in
                if isFromCache {
                    // Use "main_feed" as special user ID for main feed cache to separate from profile browsing
                    let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
                        for: "main_feed", page: page, pageSize: size, currentUserId: viewModel.hproseInstance.appUser.mid)
                    return cachedTweets
                } else {
                    return await viewModel.fetchTweets(page: page, pageSize: size, shouldCache: shouldCache)
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
            onScroll: { delta in
                onScroll?(delta) // Pass delta directly to parent
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
            // Set initial navigation state
            isNavigationVisible = true
            onScroll?(0)
        }
        .onDisappear {
            // Clean up timer
            scrollEndTimer?.invalidate()
            scrollEndTimer = nil
            print("DEBUG: [FollowingsTweetView] View disappeared")
        }
    }
    
    // MARK: - Scroll Handling
    @State private var scrollEndTimer: Timer?
    @State private var lastScrollOffset: CGFloat = 0
    
    private func handleScroll(offset: CGFloat) {
        // Calculate scroll delta
        let delta = offset - lastScrollOffset
        lastScrollOffset = offset
        
        // Pass the delta to parent (positive = scrolling up, negative = scrolling down)
        onScroll?(delta)
        
        print("DEBUG: [FollowingsTweetView] Scroll offset: \(offset), delta: \(delta)")
    }
}
