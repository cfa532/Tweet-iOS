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
    @State private var previousScrollOffset: CGFloat = 0
    @State private var isNavigationVisible = true
    @State private var selectedUser: User? = nil
    @State private var selectedTweet: Tweet? = nil
    
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
        NavigationStack {
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
                        selectedTweet: $selectedTweet,
                        onScroll: { offset in
                            handleScroll(offset: offset)
                        }
                    )
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
                })
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedTweet != nil },
                set: { if !$0 { selectedTweet = nil } }
            )) {
                if let selectedTweet = selectedTweet {
                    TweetDetailView(tweet: selectedTweet)
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
                
                // Pause all videos when HomeView disappears
                print("DEBUG: [HomeView] View disappeared, pausing all videos")
                pauseAllVideos()
            }
        }
        
        // Start initial refresh timer (3 seconds)
    }
    
    // MARK: - Scroll Handling
    private func handleScroll(offset: CGFloat) {
        // Calculate scroll direction and threshold
        let scrollDelta = offset - previousScrollOffset
        let scrollThreshold: CGFloat = 20 // Increased threshold for less sensitivity
        
        // Show navigation if:
        // 1. At the top (offset >= 0)
        // 2. Scrolling down significantly (negative delta < -threshold) when navigation is currently hidden
        // Hide navigation if:
        // 3. Scrolling down significantly (negative delta < -threshold) when navigation is currently visible
        let shouldShowNavigation: Bool
        
        if offset >= 0 {
            // Always show when at the top
            shouldShowNavigation = true
        } else if scrollDelta < -scrollThreshold {
            // Scrolling down - hide navigation if it's currently visible
            shouldShowNavigation = false
        } else if scrollDelta > scrollThreshold && !isNavigationVisible {
            // Scrolling up AND navigation is currently hidden - show it
            shouldShowNavigation = true
        } else {
            // Keep current state for small movements or when scrolling up but navigation is already visible
            shouldShowNavigation = isNavigationVisible
        }
        
        if shouldShowNavigation != isNavigationVisible {
            withAnimation(.easeInOut(duration: 0.3)) {
                isNavigationVisible = shouldShowNavigation
            }
            // Notify parent about navigation visibility change
            onNavigationVisibilityChanged?(shouldShowNavigation)
        }
        
        previousScrollOffset = offset
    }
    
    /// Pause all videos when HomeView disappears
    private func pauseAllVideos() {
        print("DEBUG: [HomeView] Pausing all videos")
        
        // Note: The actual video cleanup should be handled by FollowingsTweetView and RecommendedTweetView
        // This function serves as a fallback and logs the event
    }
}

// MARK: - Preview
@available(iOS 17.0, *)
struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView(navigationPath: .constant(NavigationPath()))
    }
} 
