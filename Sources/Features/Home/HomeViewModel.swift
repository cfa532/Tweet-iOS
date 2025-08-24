import Foundation
import SwiftUI

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
                // Tab bar
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
            .opacity(isNavigationVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.3), value: isNavigationVisible)
            .offset(y: isNavigationVisible ? 0 : -100)
            .frame(height: isNavigationVisible ? nil : 0)
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
                    onScroll: nil // FollowingsTweetView now handles its own scroll detection
                )
                // Remove the .id(refreshKey) that forces recreation
                .tag(0)

                RecommendedTweetView(onScroll: { offset in
                    handleScroll(offset: offset)
                })
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .padding(.leading, -4)
        }
        .navigationBarHidden(true) // Hide the system navigation bar
        .navigationDestination(for: User.self) { user in
            ProfileView(user: user, onLogout: {
                navigationPath.removeLast(navigationPath.count)
                onReturnToHome?()
            }, navigationPath: $navigationPath)
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
                await MainActor.run {
                    TweetCacheManager.shared.clearAllCache()
                    print("DEBUG: Cleared all cache on user login")
                }
                try await HproseInstance.shared.initialize()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .userDidLogout)) { _ in
            Task {
                await MainActor.run {
                    TweetCacheManager.shared.clearAllCache()
                    print("DEBUG: Cleared all cache on user logout")
                }
                try await HproseInstance.shared.initialize()
            }
        }
        .onDisappear {
            withAnimation(.easeInOut(duration: 0.3)) {
                isNavigationVisible = true
            }
            onNavigationVisibilityChanged?(true)
            
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
    private func handleScroll(offset: CGFloat) {
        print("[HomeView] handleScroll called with offset: \(offset)")
        
        // Calculate scroll direction and threshold
        let scrollDelta = offset - previousScrollOffset
        let scrollThreshold: CGFloat = 30 // Single threshold for both scroll directions
        
        print("[HomeView] Scroll delta: \(scrollDelta), previous offset: \(previousScrollOffset)")
        
        // Determine scroll direction with threshold
        let isScrollingDown = scrollDelta < -scrollThreshold
        let isScrollingUp = scrollDelta > scrollThreshold
        
        print("[HomeView] isScrollingDown: \(isScrollingDown), isScrollingUp: \(isScrollingUp)")
        
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
        
        print("[HomeView] Current isNavigationVisible: \(isNavigationVisible), shouldShowNavigation: \(shouldShowNavigation)")
        
        // Only update if the state actually changed
        if shouldShowNavigation != isNavigationVisible {
            withAnimation(.easeInOut(duration: 0.3)) {
                isNavigationVisible = shouldShowNavigation
            }
            // Notify parent about navigation visibility change
            onNavigationVisibilityChanged?(shouldShowNavigation)
            
            print("[HomeView] Navigation visibility changed to: \(shouldShowNavigation) - Scroll delta: \(scrollDelta), offset: \(offset)")
        }
        
        previousScrollOffset = offset
    }
}

// MARK: - Preview
@available(iOS 17.0, *)
struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView(navigationPath: .constant(NavigationPath()))
    }
} 
