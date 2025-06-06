import Foundation
import SwiftUI

@available(iOS 17.0, *)
struct HomeView: View {
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var selectedTab = 0
    @State private var isScrolling = false
    @State private var scrollOffset: CGFloat = 0
    @State private var selectedUser: User? = nil
    @State private var resetFollowingsFeed = false
    @State private var scrollToTopTrigger = false

    @EnvironmentObject private var hproseInstance: HproseInstance

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppHeaderView(onAppIconTap: { scrollToTopTrigger.toggle() })
                    .padding(.vertical, 8)
                // Tab bar (no avatars/settings here)
                HStack(spacing: 0) {
                    TabButton(title: "Followings", isSelected: selectedTab == 0) {
                        withAnimation { selectedTab = 0 }
                    }
                    TabButton(title: "Recommendation", isSelected: selectedTab == 1) {
                        withAnimation { selectedTab = 1 }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)

                // Tab Content
                TabView(selection: $selectedTab) {
                    FollowingsTweetView(
                        isLoading: $isLoading,
                        onAvatarTap: { user in
                            selectedUser = user
                        },
                        resetTrigger: $resetFollowingsFeed,
                        scrollToTopTrigger: $scrollToTopTrigger
                    )
                    .tag(0)

                    RecommendedTweetView()
                        .tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationDestination(item: $selectedUser) { user in
                ProfileView(user: user, onLogout: {
                    selectedTab = 0
                    resetFollowingsFeed.toggle()
                })
            }
            .onReceive(NotificationCenter.default.publisher(for: .userDidLogin)) { _ in
                Task {
                    await MainActor.run {
                        TweetCacheManager.shared.clearAllTweets()
                        // Reset all loaded tweets in all view models by toggling reset triggers
                        resetFollowingsFeed.toggle()
                        // Add similar triggers for other feeds/view models if needed
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .userDidLogout)) { _ in
                Task {
                    await MainActor.run {
                        TweetCacheManager.shared.clearAllTweets()
                        resetFollowingsFeed.toggle()
                        // Add similar triggers for other feeds/view models if needed
                    }
                }
            }
        }
    }
}

struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isSelected ? .primary : .secondary)
                Rectangle()
                    .fill(isSelected ? Color.blue : Color.clear)
                    .frame(height: 2)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview
@available(iOS 17.0, *)
struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
    }
} 
