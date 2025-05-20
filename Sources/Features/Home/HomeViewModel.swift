import Foundation
import SwiftUI

@available(iOS 17.0, *)
struct HomeView: View {
    @State private var tweets: [Tweet] = []
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var selectedTab = 0
    @State private var isScrolling = false
    @State private var scrollOffset: CGFloat = 0
    @State private var selectedUser: User? = nil

    private let hproseInstance = HproseInstance.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppHeaderView()
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
                        tweets: $tweets,
                        isLoading: $isLoading,
                        isRefreshing: $isRefreshing,
                        loadInitialTweets: loadInitialTweets,
                        likeTweet: likeTweet,
                        retweet: retweet,
                        bookmarkTweet: bookmarkTweet,
                        deleteTweet: deleteTweet,
                        onAvatarTap: { user in
                            selectedUser = user
                        }
                    )
                    .tag(0)

                    RecommendedTweetView()
                        .tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationDestination(item: $selectedUser) { user in
                ProfileView(user: user)
            }
        }
        .task {
            await loadInitialTweets()
        }
    }

    func loadInitialTweets() async {
        isLoading = true
        do {
            tweets = try await hproseInstance.fetchTweetFeed(
                user: hproseInstance.appUser, startRank: 0, endRank: 20
            )
        } catch {
            print("Error loading tweets: \(error)")
        }
        isLoading = false
    }

    func likeTweet(_ tweet: Tweet) async {
        do {
            try await hproseInstance.likeTweet(tweet.id)
            if let index = tweets.firstIndex(where: { $0.id == tweet.id }) {
                tweets[index].isLiked.toggle()
                tweets[index].favoriteCount += tweets[index].isLiked ? 1 : -1
            }
        } catch {
            print("Error liking tweet: \(error)")
        }
    }

    func retweet(_ tweet: Tweet) async {
        do {
            try await hproseInstance.retweet(tweet.id)
            if let index = tweets.firstIndex(where: { $0.id == tweet.id }) {
                tweets[index].isRetweeted.toggle()
                tweets[index].retweetCount += tweets[index].isRetweeted ? 1 : -1
            }
        } catch {
            print("Error retweeting: \(error)")
        }
    }

    func bookmarkTweet(_ tweet: Tweet) async {
        do {
            try await hproseInstance.bookmarkTweet(tweet.id)
            if let index = tweets.firstIndex(where: { $0.id == tweet.id }) {
                tweets[index].isBookmarked.toggle()
            }
        } catch {
            print("Error bookmarking tweet: \(error)")
        }
    }

    func deleteTweet(_ tweet: Tweet) async {
        do {
            try await hproseInstance.deleteTweet(tweet.id)
            tweets.removeAll { $0.id == tweet.id }
        } catch {
            print("Error deleting tweet: \(error)")
        }
    }
}

// MARK: - Preview
@available(iOS 17.0, *)
struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
    }
} 
