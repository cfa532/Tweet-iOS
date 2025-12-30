import Foundation
import SwiftUI

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
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
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var selectedTab = 0
    @State private var isScrolling = false
    @State private var scrollOffset: CGFloat = 0
    @State private var isNavigationVisible = true
    @State private var previousScrollOffset: CGFloat = 0
    @State private var selectedUser: User? = nil
    
    @EnvironmentObject private var hproseInstance: HproseInstance
    
    init(
        navigationPath: Binding<NavigationPath>,
        onNavigationVisibilityChanged: ((Bool) -> Void)? = nil,
        onNavigateToProfile: (() -> Void)? = nil,
        onReturnToHome: (() -> Void)? = nil
    ) {
        self._navigationPath = navigationPath
        self.onNavigationVisibilityChanged = onNavigationVisibilityChanged
        self.onNavigateToProfile = onNavigateToProfile
        self.onReturnToHome = onReturnToHome
    }

    var body: some View {
        VStack(spacing: 0) {
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
            .frame(height: isNavigationVisible ? nil : 0)
            .opacity(isNavigationVisible ? 1 : 0)
            .clipped()

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
                    }
                )
                .tag(0)

                RecommendedTweetView(onScroll: { offset, delta in
                    handleScroll(offset: offset, delta: delta)
                })
                .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .padding(.leading, -4)
        }
        .padding(.top, 8) // Small top padding
        .toolbar(.hidden, for: .navigationBar) // Hide the navigation bar (iOS 17+)
        .toolbarBackground(.hidden, for: .navigationBar) // Hide navigation bar background
        .navigationBarTitleDisplayMode(.inline) // Inline mode to minimize height
        .navigationDestination(for: User.self) { user in
            ProfileView(user: user, onLogout: {
                navigationPath.removeLast(navigationPath.count)
                onReturnToHome?()
            }, navigationPath: $navigationPath)
        }
        .navigationDestination(for: UserListDestination.self) { destination in
            UserListDestinationView(destination: destination, navigationPath: $navigationPath)
        }
        .navigationDestination(for: TweetListDestination.self) { destination in
            TweetListDestinationView(destination: destination, navigationPath: $navigationPath)
        }
        .navigationDestination(for: CommentNavigation.self) { commentNav in
            CommentDetailView(comment: commentNav.comment, parentTweet: commentNav.parentTweet)
        }
        .navigationDestination(for: Tweet.self) { tweet in
            // Check if this is a comment (has originalTweetId but no content) vs quote tweet (has originalTweetId AND content)
            if tweet.originalTweetId != nil && (tweet.content?.isEmpty ?? true) && (tweet.attachments?.isEmpty ?? true) {
                // This is a comment (retweet with no content), show CommentDetailView with a parent fetcher
                CommentDetailViewWithParent(comment: tweet)

            } else {
                // This is a regular tweet or quote tweet, show TweetDetailView
                TweetDetailView(tweet: tweet)

            }
        }
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
            Task {
                // Don't clear cache on logout - cache persists per user and is cleared periodically or manually
                await MainActor.run {
                    print("DEBUG: Cache persists across logout - cleared periodically or manually by user")
                }
                try await HproseInstance.shared.initialize()
            }
        }
        .onDisappear {
            withAnimation(.easeInOut(duration: 0.3)) {
                isNavigationVisible = true
            }
            onNavigationVisibilityChanged?(true)
            
            // Clean up complete
            
            print("DEBUG: [HomeView] View disappeared")
        }
        .onAppear {
            // Ensure navigation is visible when view appears
            isNavigationVisible = true
            onNavigationVisibilityChanged?(true)
            print("DEBUG: [HomeView] View appeared, navigation set to visible")
        }
    }
    
    // MARK: - Scroll Handling
    @State private var lastSignificantDelta: CGFloat = 0
    
    private func handleScroll(offset: CGFloat, delta: CGFloat) {
        // Threshold for detecting intentional scroll
        let scrollThreshold: CGFloat = 15
        
        // Always show when at or near the top
        if offset <= 10 {
            if !isNavigationVisible {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isNavigationVisible = true
                }
                onNavigationVisibilityChanged?(true)
            }
            return
        }
        
        // Ignore very small deltas (noise from rendering/layout)
        guard abs(delta) > 2 else { return }
        
        // Detect significant scroll direction changes
        // Positive delta = scrolling down (content moves up)
        // Negative delta = scrolling up (content moves down)
        let isScrollingDown = delta > scrollThreshold
        let isScrollingUp = delta < -scrollThreshold
        
        // Update navigation visibility based on scroll direction
        if isScrollingDown && isNavigationVisible {
            // Scrolling down significantly - hide header and bottom bar
            withAnimation(.easeInOut(duration: 0.25)) {
                isNavigationVisible = false
            }
            onNavigationVisibilityChanged?(false)
            lastSignificantDelta = delta
        } else if isScrollingUp && !isNavigationVisible {
            // Scrolling up significantly - show header and bottom bar
            withAnimation(.easeInOut(duration: 0.25)) {
                isNavigationVisible = true
            }
            onNavigationVisibilityChanged?(true)
            lastSignificantDelta = delta
        }
    }
}

// MARK: - Navigation Destination Views
// These wrapper views handle navigation destinations at the root level to avoid conflicts
// when multiple ProfileViews are nested in the navigation stack

struct UserListDestinationView: View {
    let destination: UserListDestination
    @Binding var navigationPath: NavigationPath
    @EnvironmentObject private var hproseInstance: HproseInstance
    
    var body: some View {
        UserListView(
            title: userListTitle(for: destination),
            userFetcher: { page, size in
                // Only fetch all IDs once when page is 0
                if page == 0 {
                    let entry: UserContentType = destination.listType == .FOLLOWER ? .FOLLOWER : .FOLLOWING
                    let targetUser = User.getInstance(mid: destination.userId)
                    let ids = try await hproseInstance.getListByType(user: targetUser, entry: entry)
                    // Update user properties on main thread
                    await MainActor.run {
                        if destination.listType == .FOLLOWER {
                            targetUser.fansList = ids
                        } else {
                            targetUser.followingList = ids
                        }
                    }
                    return ids
                } else {
                    let targetUser = User.getInstance(mid: destination.userId)
                    return if destination.listType == .FOLLOWER {
                        targetUser.fansList ?? []
                    } else {
                        targetUser.followingList ?? []
                    }
                }
            },
            navigationPath: $navigationPath,
            onFollowToggle: { user in
                Task {
                    await handleToggleFollowing(for: user)
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
    @EnvironmentObject private var hproseInstance: HproseInstance
    @State private var tweets: [Tweet] = []
    
    var body: some View {
        let targetUser = User.getInstance(mid: destination.userId)
        let isTargetAppUser = destination.userId == hproseInstance.appUser.mid
        
        TweetListView(
            title: listTitle(isAppUser: isTargetAppUser),
            tweets: $tweets,
            tweetFetcher: { page, size, isFromCache in
                print("DEBUG: [TweetListDestinationView] Fetching \(destination.listType) - page: \(page), size: \(size), isFromCache: \(isFromCache)")
                if isFromCache {
                    // For bookmarks/favorites, we don't cache, so return empty array
                    return []
                } else {
                    let tweetType: UserContentType = destination.listType == .BOOKMARKS ? .BOOKMARKS : .FAVORITES
                    let fetchedTweets = try await hproseInstance.getUserTweetsByType(user: targetUser, type: tweetType, pageNumber: page, pageSize: size)
                    print("DEBUG: [TweetListDestinationView] Got \(fetchedTweets.count) \(destination.listType) tweets")
                    return fetchedTweets
                }
            },
            rowView: { tweet in
                TweetItemView(
                    tweet: tweet,
                    showDeleteButton: isTargetAppUser,
                    onAvatarTap: { tappedUser in
                        print("🔴 [TweetListDestinationView] Avatar tapped - user: \(tappedUser.username ?? "nil")")
                        navigationPath.append(tappedUser)
                    },
                    onTap: { tappedTweet in
                        navigationPath.append(tappedTweet)
                    }
                )
            }
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
