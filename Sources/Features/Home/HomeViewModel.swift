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
            
            // Clean up timer
            scrollEndTimer?.invalidate()
            scrollEndTimer = nil
            
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
    @State private var scrollEndTimer: Timer?
    @State private var consecutiveSmallMovements: Int = 0
    @State private var isInertiaScrolling: Bool = false
    
    private func handleScroll(offset: CGFloat) {
        print("[HomeView] handleScroll called with offset: \(offset)")
        
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
        
        print("[HomeView] Scroll delta: \(scrollDelta), consecutiveSmallMovements: \(consecutiveSmallMovements), isInertiaScrolling: \(isInertiaScrolling)")
        
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
                onNavigationVisibilityChanged?(shouldShowNavigation)
                print("[HomeView] Navigation visibility changed to: \(shouldShowNavigation)")
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

// MARK: - Preview
@available(iOS 17.0, *)
struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView(navigationPath: .constant(NavigationPath()))
    }
} 
