import Foundation
import SwiftUI
import OSLog

private let homeViewLogger = Logger(subsystem: "com.zz", category: "HomeView")

struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

@available(iOS 17.0, *)
struct HomeView: View {
    @Binding var navigationPath: NavigationPath
    let onNavigationVisibilityChanged: ((Bool) -> Void)?
    let onNavigateToProfile: (() -> Void)?
    let onReturnToHome: (() -> Void)?
    let onShowLogin: (() -> Void)?
    let onShowToast: ((String, Bool) -> Void)?
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var selectedTab = 0
    @State private var isScrolling = false
    @State private var scrollOffset: CGFloat = 0
    @State private var isNavigationVisible = true
    /// Natural height of the header VStack below, captured via onGeometryChange.
    /// `.frame(height: isNavigationVisible ? nil : 0)` cannot animate — SwiftUI has
    /// no way to interpolate towards `nil` (unconstrained), so the height snapped to 0
    /// in a single frame even though the state change was wrapped in withAnimation.
    /// Only the opacity animated, producing a visible jump in whatever content sat
    /// below the header (most noticeable when a video row was mid-scroll at the time).
    /// Using a concrete measured height instead of nil gives animation two real
    /// endpoints to interpolate between.
    @State private var measuredHeaderHeight: CGFloat?
    @State private var previousScrollOffset: CGFloat = 0
    @State private var selectedUser: User? = nil
    @State private var foregroundObserver: NSObjectProtocol? = nil

    @EnvironmentObject private var hproseInstance: HproseInstance

    init(
        navigationPath: Binding<NavigationPath>,
        onNavigationVisibilityChanged: ((Bool) -> Void)? = nil,
        onNavigateToProfile: (() -> Void)? = nil,
        onReturnToHome: (() -> Void)? = nil,
        onShowLogin: (() -> Void)? = nil,
        onShowToast: ((String, Bool) -> Void)? = nil
    ) {
        self._navigationPath = navigationPath
        self.onNavigationVisibilityChanged = onNavigationVisibilityChanged
        self.onNavigateToProfile = onNavigateToProfile
        self.onReturnToHome = onReturnToHome
        self.onShowLogin = onShowLogin
        self.onShowToast = onShowToast
    }

    var body: some View {
        // Tab Content
        TabView(selection: $selectedTab) {
            FollowingsTweetView(
                onAvatarTap: { user in
                    navigationPath.append(user)
                    onNavigateToProfile?()
                },
                onTweetTap: { tweet in
                    navigationPath.append(tweet)
                },
                onScroll: { offset, delta in
                    handleScroll(offset: offset, delta: delta)
                },
                onShowLogin: onShowLogin,
                onShowToast: onShowToast,
                topContentInset: measuredHeaderHeight ?? 0
            )
            .background(XTheme.backgroundColor)
            .tag(0)

            RecommendedTweetView(onScroll: { offset, delta in
                handleScroll(offset: offset, delta: delta)
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(XTheme.backgroundColor)
            .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .padding(.leading, -4)
        .background(XTheme.backgroundColor)
        .ignoresSafeArea(.container, edges: .top)
        // The header FLOATS over the feed; it is not a sibling above it in a stack.
        //
        // As a VStack sibling, collapsing it to height 0 moved the feed table's window
        // origin up by the header's full height (89pt measured). UIKit does not adjust
        // contentOffset for a frame move, so the whole 89pt landed on the content as
        // extra motion: mid-drag the list ran at up to 2x the finger for ~0.27s and then
        // snapped back to tracking it. The reveal direction was already being corrected
        // for exactly this (the bar-appearance compensation in TweetTableViewController);
        // the hide direction never was, which is why only scroll-down jumped.
        //
        // Now the table is full-bleed and keeps a CONSTANT contentInset.top equal to the
        // header height (`topContentInset` below), so the header showing or hiding changes
        // no geometry at all — the table's window origin measured 159 before and 70 after
        // as a sibling, and a flat 159 as an overlay. Content simply flows under the
        // collapsed header instead of being pushed by it.
        //
        // safeAreaInset was tried first and does NOT work here: SwiftUI lays a
        // UIViewControllerRepresentable out inside the reduced safe area, so the table's
        // frame moved exactly as it did in the VStack. The inset has to reach the table
        // as a real UIScrollView contentInset, which is what topContentInset does.
        .overlay(alignment: .top) {
            // Header section
            VStack(spacing: 0) {
                AppHeaderView()
                    .padding(.vertical, 8)
                HStack(spacing: 0) {
                    TabButton(title: LocalizedStringKey("Followings"), isSelected: selectedTab == 0) {
                        withAnimation { selectedTab = 0 }
                    }
                    TabButton(title: LocalizedStringKey("Recommendation"), isSelected: selectedTab == 1) {
                        withAnimation { selectedTab = 1 }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.leading, -4)
            }
            .background(XTheme.backgroundColor)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(XTheme.borderColor)
                    .frame(height: 0.5)
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                guard newHeight > 0 else { return }
                measuredHeaderHeight = newHeight
            }
            // Translated, not collapsed. Collapsing the height is what used to relayout
            // everything below it; sliding it up leaves the table's geometry untouched.
            .offset(y: isNavigationVisible ? 0 : -(measuredHeaderHeight ?? 0))
            .opacity(isNavigationVisible ? 1 : 0)
            .allowsHitTesting(isNavigationVisible)
        }
        .padding(.top, 8) // Small top padding
        .background(XTheme.backgroundColor)
        .toolbar(.hidden, for: .navigationBar) // Hide the navigation bar (iOS 17+)
        .toolbarBackground(.hidden, for: .navigationBar) // Hide navigation bar background
        .navigationBarTitleDisplayMode(.inline) // Inline mode to minimize height
        .appNavigationDestinations(
            path: $navigationPath,
            onShowLogin: onShowLogin,
            onShowToast: onShowToast,
            onProfileLogout: {
                navigationPath.removeLast(navigationPath.count)
                onReturnToHome?()
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: .userDidLogin)) { _ in
            Task {
                // After login, appUser and baseUrl are already populated by login() method
                // No need to call initialize() or clear cache - login() already handles everything
                // Just mark initialization as complete if not already done
                await MainActor.run {
                    if !HproseInstance.shared.isAppInitialized {
                        HproseInstance.shared.markInitializationComplete()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .userDidLogout)) { _ in
            // Pop all navigation immediately so profile/detail views are dismissed before
            // initialize() triggers state changes that would update their table views.
            if navigationPath.count > 0 {
                navigationPath.removeLast(navigationPath.count)
            }
            Task {
                // Don't clear cache on logout - cache persists per user and is cleared periodically or manually
                await MainActor.run {
                    print("DEBUG: Cache persists across logout - cleared periodically or manually by user")
                }
                try await HproseInstance.shared.initialize()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToCommentDetail"))) { notification in
            if let comment = notification.userInfo?["comment"] as? Tweet,
               let parentTweet = notification.userInfo?["parentTweet"] as? Tweet {
                let commentNav = CommentNavigation(comment: comment, parentTweet: parentTweet)
                navigationPath.append(commentNav)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showBarsAfterScrollEnd)) { notification in
            // Show bars WITHOUT animation so the frame change is instant.
            // TweetTableViewController compensates contentOffset in viewDidLayoutSubviews.
            guard !isNavigationVisible else { return }
            isNavigationVisible = true
            let animated = notification.userInfo?["animated"] as? Bool ?? false
            postNavigationVisibilityNotification(isVisible: true, animated: animated)
            lastVisibilityChangeTime = Date()
        }
        .onDisappear {
            withAnimation(.easeInOut(duration: 0.3)) {
                isNavigationVisible = true
            }
            // Post notification for bottom tab bar
            NotificationCenter.default.post(
                name: .navigationVisibilityChanged,
                object: nil,
                userInfo: ["isVisible": true]
            )

            // Clean up foreground observer
            if let observer = foregroundObserver {
                NotificationCenter.default.removeObserver(observer)
                foregroundObserver = nil
            }

        }
        .onAppear {
            // Ensure navigation is visible when view appears
            isNavigationVisible = true
            // Post notification for bottom tab bar
            NotificationCenter.default.post(
                name: .navigationVisibilityChanged,
                object: nil,
                userInfo: ["isVisible": true]
            )

            // Setup foreground observer to restore navigation state when app returns from background
            setupForegroundObserver()
        }
    }
    
    // MARK: - Scroll Handling
    @State private var lastSignificantDelta: CGFloat = 0
    @State private var lastNotificationTime: Date?
    private let notificationThrottleInterval: TimeInterval = 0.1 // 100ms - prevent rapid-fire notifications
    @State private var lastVisibilityChangeTime: Date?
    private let visibilityChangeCooldown: TimeInterval = 0.35 // Cooldown after show/hide to prevent feedback loop

    private func handleScroll(offset: CGFloat, delta: CGFloat) {
        // Cooldown after toolbar visibility change — the header resize animation
        // causes layout-induced contentOffset changes that would trigger the opposite
        // direction, creating a show/hide feedback loop.
        if let lastChange = lastVisibilityChangeTime,
           Date().timeIntervalSince(lastChange) < visibilityChangeCooldown {
            return
        }

        // Threshold for detecting intentional scroll
        let scrollThreshold: CGFloat = 15

        // Always show when at or near the top
        if offset <= 10 {
            if !isNavigationVisible {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isNavigationVisible = true
                }
                postNavigationVisibilityNotification(isVisible: true)
                lastVisibilityChangeTime = Date()
            }
            return
        }

        // Ignore very small deltas (noise from rendering/layout)
        guard abs(delta) > 2 else { return }

        // Positive delta = scrolling down (content moves up)
        // Negative delta = scrolling up (content moves down)
        let isScrollingDown = delta > scrollThreshold
        let isScrollingUp = delta < -scrollThreshold

        if isScrollingDown && isNavigationVisible {
            withAnimation(.easeInOut(duration: 0.25)) {
                isNavigationVisible = false
            }
            postNavigationVisibilityNotification(isVisible: false)
            lastSignificantDelta = delta
            lastVisibilityChangeTime = Date()
        } else if isScrollingUp && !isNavigationVisible {
            withAnimation(.easeInOut(duration: 0.25)) {
                isNavigationVisible = true
            }
            postNavigationVisibilityNotification(isVisible: true)
            lastSignificantDelta = delta
            lastVisibilityChangeTime = Date()
        }
    }
    
    // Helper to post navigation visibility notification with throttling
    private func postNavigationVisibilityNotification(isVisible: Bool, animated: Bool = true) {
        // Throttle notifications to prevent excessive posting during rapid scroll
        let now = Date()
        if animated, let lastTime = lastNotificationTime, now.timeIntervalSince(lastTime) < notificationThrottleInterval {
            return
        }

        lastNotificationTime = now
        NotificationCenter.default.post(
            name: .navigationVisibilityChanged,
            object: nil,
            userInfo: ["isVisible": isVisible, "animated": animated]
        )
    }

    // MARK: - Foreground Observer
    /// Setup observer to restore navigation state when app returns from background
    /// This prevents the white space issue when navigation was semi-hidden before backgrounding
    private func setupForegroundObserver() {
        // Avoid duplicate observers
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                // Always reset navigation to visible when returning from background
                isNavigationVisible = true
                NotificationCenter.default.post(
                    name: .navigationVisibilityChanged,
                    object: nil,
                    userInfo: ["isVisible": true]
                )
            }
        }
    }
}

// MARK: - Navigation Destination Views
// These wrapper views handle navigation destinations at the root level to avoid conflicts
// when multiple ProfileViews are nested in the navigation stack

struct UserListDestinationView: View {
    let destination: UserListDestination
    @Binding var navigationPath: NavigationPath
    let onShowLogin: (() -> Void)?
    @EnvironmentObject private var hproseInstance: HproseInstance
    
    var body: some View {
        UserListView(
            title: userListTitle(for: destination),
            userId: destination.userId,
            userFetcher: { page, size in
                let targetUser = User.getInstance(mid: destination.userId)
                var cachedIds = destination.listType == .FOLLOWER ? targetUser.fansList : targetUser.followingList

                // The in-memory singleton is empty on cold start, but the profile
                // owner's cached user record carries the lists too.
                if cachedIds == nil {
                    _ = await TweetCacheManager.shared.fetchUser(mid: destination.userId)
                    cachedIds = destination.listType == .FOLLOWER ? targetUser.fansList : targetUser.followingList
                }

                let ids = cachedIds ?? []
                let startIndex = page * size
                guard startIndex < ids.count else { return [] }
                let endIndex = min(startIndex + size, ids.count)
                return Array(ids[startIndex..<endIndex])
            },
            authoritativeUserFetcher: {
                let entry: UserContentType = destination.listType == .FOLLOWER ? .FOLLOWER : .FOLLOWING
                let targetUser = User.getInstance(mid: destination.userId)
                let ids = try await hproseInstance.getListByType(user: targetUser, entry: entry)

                if destination.listType == .FOLLOWER {
                    targetUser.fansList = ids
                } else {
                    targetUser.followingList = ids
                }
                // Persist the authoritative IDs for cache-first rendering next time.
                TweetCacheManager.shared.saveUser(targetUser)
                return ids
            },
            navigationPath: $navigationPath,
            onFollowToggle: { user in
                Task {
                    await handleToggleFollowing(for: user)
                }
            },
            onShowLogin: onShowLogin,
            onPermanentlyBlacklisted: { blacklistedUserId, failureStartedAt in
                let relationship: UserContentType =
                    destination.listType == .FOLLOWER ? .FOLLOWER : .FOLLOWING
                let targetUser = User.getInstance(mid: destination.userId)

                Task {
                    do {
                        let result = try await hproseInstance.removePermanentlyBlacklistedUser(
                            blacklistedUserId,
                            from: relationship,
                            owner: targetUser,
                            failureStartedAt: failureStartedAt
                        )

                        if result.reason == "relationship_is_newer" {
                            BlackList.shared.restoreAfterNewerRelationship(blacklistedUserId)
                            return
                        }
                        guard result.removed else { return }

                        await MainActor.run {
                            if destination.listType == .FOLLOWER {
                                targetUser.fansList?.removeAll { $0 == blacklistedUserId }
                            } else {
                                targetUser.followingList?.removeAll { $0 == blacklistedUserId }
                            }
                            TweetCacheManager.shared.saveUser(targetUser)
                        }
                    } catch {
                        homeViewLogger.error(
                            "Failed to remove permanently blacklisted relationship: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }
        )
    }
    
    private func userListTitle(for destination: UserListDestination) -> String {
        let targetUser = User.getInstance(mid: destination.userId)
        let displayName = targetUser.name ?? targetUser.username ?? NSLocalizedString("Noone", comment: "No one")
        let titleKey = destination.listType == .FOLLOWER ? "Fans@%@" : "Followings@%@"
        return String(format: NSLocalizedString(titleKey, comment: "User list title"), displayName)
    }
    
    private func handleToggleFollowing(for user: User) async {
        if let ret = try? await hproseInstance.toggleFollowing(followingId: user.mid) {
            // Update app user's followingList based on the result
            if ret {
                // User is now following - add to followingList
                if hproseInstance.appUser.followingList == nil {
                    hproseInstance.appUser.followingList = []
                }
                if !hproseInstance.appUser.followingList!.contains(user.mid) {
                    hproseInstance.appUser.followingList!.append(user.mid)
                }
            } else {
                // User is no longer following - remove from followingList
                hproseInstance.appUser.followingList?.removeAll { $0 == user.mid }
            }
        }
    }
}

struct TweetListDestinationView: View {
    let destination: TweetListDestination
    @Binding var navigationPath: NavigationPath
    let onShowLogin: (() -> Void)?
    let onShowToast: ((String, Bool) -> Void)?
    @EnvironmentObject private var hproseInstance: HproseInstance
    @State private var tweets: [Tweet] = []

    var body: some View {
        let targetUser = User.getInstance(mid: destination.userId)
        let isTargetAppUser = destination.userId == hproseInstance.appUser.mid

        // Create unique feedIdentifier for scroll position persistence
        let feedIdentifier = destination.listType == .BOOKMARKS
            ? "bookmarks_\(destination.userId)"
            : "favorites_\(destination.userId)"

        TweetListView(
            title: listTitle(isAppUser: isTargetAppUser),
            tweets: $tweets,
            tweetFetcher: { page, size, isFromCache in
                if isFromCache {
                    let tweetType: UserContentType = destination.listType == .BOOKMARKS ? .BOOKMARKS : .FAVORITES
                    let cacheKey = tweetType == .BOOKMARKS
                        ? TweetCacheManager.bookmarkCacheKey(userId: destination.userId)
                        : TweetCacheManager.favoriteCacheKey(userId: destination.userId)
                    let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
                        for: cacheKey,
                        page: page,
                        pageSize: size,
                        currentUserId: hproseInstance.appUser.mid,
                        isProfileView: false
                    )
                    return cachedTweets
                } else {
                    let tweetType: UserContentType = destination.listType == .BOOKMARKS ? .BOOKMARKS : .FAVORITES
                    let fetchedTweets = try await hproseInstance.getUserTweetsByType(user: targetUser, type: tweetType, pageNumber: page, pageSize: size)
                    return fetchedTweets
                }
            },
            feedIdentifier: feedIdentifier,
            preserveOrder: true,
            onAvatarTap: { tappedUser in
                navigationPath.append(tappedUser)
            },
            onTweetTap: { tappedTweet in
                navigationPath.append(tappedTweet)
            },
            onShowLogin: onShowLogin,
            onShowToast: onShowToast
        )
    }
    
    private func listTitle(isAppUser: Bool) -> String {
        if destination.listType == .BOOKMARKS {
            return isAppUser 
                ? NSLocalizedString("Your Bookmarks", comment: "Your bookmarks title")
                : NSLocalizedString("Bookmarks", comment: "Bookmarks title")
        } else {
            return isAppUser 
                ? NSLocalizedString("Your Favorites", comment: "Your favorites title")
                : NSLocalizedString("Favorites", comment: "Favorites title")
        }
    }
}

// MARK: - Preview
@available(iOS 17.0, *)
struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView(navigationPath: .constant(NavigationPath()))
    }
} 
