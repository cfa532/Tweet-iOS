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

// MARK: - Preview
@available(iOS 17.0, *)
struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView(navigationPath: .constant(NavigationPath()))
    }
} 
