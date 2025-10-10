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
    @State private var accumulatedDelta: CGFloat = 0
    @State private var scrollUpAccumulated: CGFloat = 0
    
    private func handleScroll(offset: CGFloat, delta: CGFloat) {
        // Positive offset = scrolled down, negative offset = pull-to-refresh
        // Positive delta = scrolling down, negative delta = scrolling up
        
        // CRITICAL: Always show header when at or near the top (offset <= 10)
        // This prevents header from hiding during pull-to-refresh
        if offset <= 10 {
            if !isNavigationVisible {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isNavigationVisible = true
                }
                onNavigationVisibilityChanged?(true)
            }
            // Reset accumulated deltas when at top
            accumulatedDelta = 0
            scrollUpAccumulated = 0
            return
        }
        
        if delta > 5 {
            // Scrolling down - accumulate
            accumulatedDelta += delta
            scrollUpAccumulated = 0 // Reset scroll up counter
            
            if accumulatedDelta > 50 && isNavigationVisible {
                // Scrolled down enough - hide header
                withAnimation(.easeInOut(duration: 0.25)) {
                    isNavigationVisible = false
                }
                onNavigationVisibilityChanged?(false)
                accumulatedDelta = 0
            }
        } else if delta < -5 {
            // Scrolling up - accumulate a bit before showing
            scrollUpAccumulated += abs(delta)
            accumulatedDelta = 0 // Reset scroll down counter
            
            if scrollUpAccumulated > 20 && !isNavigationVisible {
                // Scrolled up a bit - show header
                withAnimation(.easeInOut(duration: 0.25)) {
                    isNavigationVisible = true
                }
                onNavigationVisibilityChanged?(true)
                scrollUpAccumulated = 0
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
