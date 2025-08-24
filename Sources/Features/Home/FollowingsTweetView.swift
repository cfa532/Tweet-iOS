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
                    let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
                        for: viewModel.hproseInstance.appUser.mid, page: page, pageSize: size, currentUserId: viewModel.hproseInstance.appUser.mid)
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
    @State private var lastScrollTime: Date = Date()
    @State private var isActivelyScrolling: Bool = false
    @State private var consecutiveSmallMovements: Int = 0
    @State private var lastSignificantMovementTime: Date = Date()
    @State private var hasStartedInertiaScrolling: Bool = false
    
    private func handleScroll(offset: CGFloat) {
        print("[FollowingsTweetView] handleScroll called with offset: \(offset)")
        
        let currentTime = Date()
        let timeSinceLastScroll = currentTime.timeIntervalSince(lastScrollTime)
        let timeSinceLastSignificantMovement = currentTime.timeIntervalSince(lastSignificantMovementTime)
        lastScrollTime = currentTime
        
        // Cancel any existing timer
        scrollEndTimer?.invalidate()
        
        // Calculate scroll direction and threshold
        let scrollDelta = offset - previousScrollOffset
        let scrollThreshold: CGFloat = 30 // Single threshold for both scroll directions
        
        // Determine if we're actively scrolling (significant movement within short time)
        let isSignificantMovement = abs(scrollDelta) > scrollThreshold
        let isRecentMovement = timeSinceLastScroll < 0.1 // Within 100ms
        
        // Track consecutive small movements (potential inertia stop attempts)
        if isSignificantMovement {
            consecutiveSmallMovements = 0
            lastSignificantMovementTime = currentTime
            isActivelyScrolling = true
            hasStartedInertiaScrolling = false
        } else {
            consecutiveSmallMovements += 1
            // If we have significant movement followed by small movements, we might be in inertia scrolling
            if isActivelyScrolling && consecutiveSmallMovements > 2 {
                hasStartedInertiaScrolling = true
            }
        }
        
        // If we have many consecutive small movements or it's been a while since significant movement,
        // we might be in an inertia stop scenario - don't change navigation state
        let isInertiaStopScenario = consecutiveSmallMovements > 3 || timeSinceLastSignificantMovement > 0.5
        
        print("[FollowingsTweetView] Scroll delta: \(scrollDelta), previous offset: \(previousScrollOffset), timeSinceLastScroll: \(timeSinceLastScroll), consecutiveSmallMovements: \(consecutiveSmallMovements), isInertiaStopScenario: \(isInertiaStopScenario), hasStartedInertiaScrolling: \(hasStartedInertiaScrolling)")
        
        // Determine scroll direction with threshold
        let isScrollingDown = scrollDelta < -scrollThreshold
        let isScrollingUp = scrollDelta > scrollThreshold
        
        print("[FollowingsTweetView] isScrollingDown: \(isScrollingDown), isScrollingUp: \(isScrollingUp), isActivelyScrolling: \(isActivelyScrolling)")
        
        // Only change navigation state if we're actively scrolling AND not in an inertia stop scenario AND not in inertia scrolling
        if isActivelyScrolling && !isInertiaStopScenario && !hasStartedInertiaScrolling {
            // Determine if we should show navigation
            let shouldShowNavigation: Bool
            
            if offset >= 0 {
                // Always show when at the top (or initial state)
                shouldShowNavigation = true
            } else if isScrollingDown && isNavigationVisible {
                // Scrolling down and navigation is visible - hide it
                shouldShowNavigation = false
            } else if isScrollingUp && !isNavigationVisible {
                // Scrolling up and navigation is hidden - show it
                shouldShowNavigation = true
            } else {
                // Keep current state for small movements or when already in desired state
                shouldShowNavigation = isNavigationVisible
            }
            
            print("[FollowingsTweetView] Current isNavigationVisible: \(isNavigationVisible), shouldShowNavigation: \(shouldShowNavigation)")
            
            // Only update if the state actually changed
            if shouldShowNavigation != isNavigationVisible {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isNavigationVisible = shouldShowNavigation
                }
                // Notify parent about navigation visibility change
                NotificationCenter.default.post(
                    name: .navigationVisibilityChanged,
                    object: nil,
                    userInfo: ["isVisible": shouldShowNavigation]
                )
                
                print("[FollowingsTweetView] Navigation visibility changed to: \(shouldShowNavigation) - Scroll delta: \(scrollDelta), offset: \(offset)")
            }
        }
        
        previousScrollOffset = offset
        
        // Set a timer to handle scroll end - if no more scroll events come in for 0.3 seconds,
        // we can assume the scroll has ended and maintain the current state
        scrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            print("[FollowingsTweetView] Scroll end timer fired - maintaining current navigation state")
            isActivelyScrolling = false
            consecutiveSmallMovements = 0
            hasStartedInertiaScrolling = false
            // Don't change the navigation state when scroll ends
            // Let it remain in its current state
        }
    }
}
