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
                )
            ],
            onScroll: { offset in
                handleScroll(offset: offset)
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
    
    // MARK: - Scroll Handling (same algorithm as ProfileView)
    @State private var scrollEndTimer: Timer?
    @State private var consecutiveSmallMovements: Int = 0
    @State private var isInertiaScrolling: Bool = false
    
    private func handleScroll(offset: CGFloat) {
        // Cancel any existing timer
        scrollEndTimer?.invalidate()
        
        // Calculate scroll direction and threshold
        let scrollDelta = offset - previousScrollOffset
        let scrollThreshold: CGFloat = 30
        
        // Track consecutive small movements to detect inertia scrolling
        if abs(scrollDelta) > scrollThreshold {
            consecutiveSmallMovements = 0
            isInertiaScrolling = false
        } else {
            consecutiveSmallMovements += 1
            // If we have many consecutive small movements, we're likely in inertia scrolling
            if consecutiveSmallMovements > 3 {
                isInertiaScrolling = true
            }
        }
        
        // Only change navigation state if we're not in inertia scrolling
        if !isInertiaScrolling {
            // Determine scroll direction
            let isScrollingDown = scrollDelta < -scrollThreshold
            let isScrollingUp = scrollDelta > scrollThreshold
            
            // Determine if we should show navigation
            let shouldShowNavigation: Bool
            
            if offset >= 0 {
                // Always show when at the top
                shouldShowNavigation = true
            } else if isScrollingDown && isNavigationVisible {
                // Scrolling down and navigation is visible - hide it
                shouldShowNavigation = false
            } else if isScrollingUp && !isNavigationVisible {
                // Scrolling up and navigation is hidden - show it
                shouldShowNavigation = true
            } else {
                // Keep current state
                shouldShowNavigation = isNavigationVisible
            }
            
            // Only update if the state actually changed
            if shouldShowNavigation != isNavigationVisible {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isNavigationVisible = shouldShowNavigation
                }
                NotificationCenter.default.post(
                    name: .navigationVisibilityChanged,
                    object: nil,
                    userInfo: ["isVisible": shouldShowNavigation]
                )
                print("[FollowingsTweetView] Navigation visibility changed to: \(shouldShowNavigation)")
            }
        }
        
        previousScrollOffset = offset
        
        // Reset inertia scrolling state after 0.3 seconds of no scroll activity
        scrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            Task { @MainActor in
                consecutiveSmallMovements = 0
                isInertiaScrolling = false
            }
        }
    }
}
