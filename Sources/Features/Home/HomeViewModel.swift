import Foundation
import SwiftUI

struct HomeView: View {
    @State private var tweets: [Tweet] = []
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var selectedTab = 0
    @State private var isScrolling = false
    @State private var scrollOffset: CGFloat = 0

    private let hproseInstance = HproseInstance.shared

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Custom Tab Bar
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
                        refresh: refresh,
                        likeTweet: likeTweet,
                        retweet: retweet,
                        bookmarkTweet: bookmarkTweet,
                        deleteTweet: deleteTweet
                    )
                    .tag(0)

                    RecommendedTweetView()
                        .tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await loadInitialTweets()
        }
    }

    func loadInitialTweets() async {
        isLoading = true
        do {
            tweets = try await hproseInstance.fetchTweets(
                user: hproseInstance.appUser, startRank: 0, endRank: 20
            )
        } catch {
            print("Error loading tweets: \(error)")
        }
        isLoading = false
    }

    func refresh() async {
        isRefreshing = true
        do {
            tweets = try await hproseInstance.fetchTweets(
                user: hproseInstance.appUser, startRank: 0, endRank: 20
            )
        } catch {
            print("Error refreshing tweets: \(error)")
        }
        isRefreshing = false
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

struct FollowingsTweetView: View {
    @Binding var tweets: [Tweet]
    @Binding var isLoading: Bool
    @Binding var isRefreshing: Bool
    let loadInitialTweets: () async -> Void
    let refresh: () async -> Void
    let likeTweet: (Tweet) async -> Void
    let retweet: (Tweet) async -> Void
    let bookmarkTweet: (Tweet) async -> Void
    let deleteTweet: (Tweet) async -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(tweets) { tweet in
                    TweetItemView(
                        tweet: tweet,
                        likeTweet: likeTweet,
                        retweet: retweet,
                        bookmarkTweet: bookmarkTweet,
                        deleteTweet: deleteTweet
                    )
                    .id(tweet.id)
                }
                if isLoading {
                    ProgressView()
                        .padding()
                }
            }
        }
        .refreshable {
            await refresh()
        }
        .onAppear {
            if tweets.isEmpty {
                Task {
                    await loadInitialTweets()
                }
            }
        }
    }
}

struct RecommendedTweetView: View {
    var body: some View {
        Text("Recommended tweets coming soon")
            .foregroundColor(.secondary)
    }
}

struct TweetItemView: View {
    let tweet: Tweet
    let likeTweet: (Tweet) async -> Void
    let retweet: (Tweet) async -> Void
    let bookmarkTweet: (Tweet) async -> Void
    let deleteTweet: (Tweet) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Author info
            HStack {
                AsyncImage(url: URL(string: tweet.author?.avatar ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.gray
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                VStack(alignment: .leading) {
                    Text(tweet.author?.name ?? "No one")
                        .font(.headline)
                    Text("@\(tweet.author?.username ?? "")")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Menu {
                    Button(role: .destructive) {
                        Task {
                            await deleteTweet(tweet)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.secondary)
                }
            }
            // Tweet content
            Text(tweet.content ?? "")
                .font(.body)
            // Media attachments
            if let attachments = tweet.attachments {
                let mimeiAttachments = attachments.map { media in
                    MimeiFileType(
                        mid: media.mid,
                        type: media.type,
                        size: media.size,
                        fileName: media.fileName,
                        timestamp: media.timestamp,
                        aspectRatio: media.aspectRatio,
                        url: media.url
                    )
                }
                MediaGridView(attachments: mimeiAttachments)
            }
            // Tweet actions
            HStack(spacing: 16) {
                TweetActionButton(
                    icon: "message",
                    count: tweet.retweetCount,
                    isSelected: false
                ) {
                    // Handle reply
                }
                TweetActionButton(
                    icon: "arrow.2.squarepath",
                    count: tweet.retweetCount,
                    isSelected: tweet.isRetweeted
                ) {
                    Task {
                        await retweet(tweet)
                    }
                }
                TweetActionButton(
                    icon: "heart",
                    count: tweet.favoriteCount,
                    isSelected: tweet.isLiked
                ) {
                    Task {
                        await likeTweet(tweet)
                    }
                }
                TweetActionButton(
                    icon: "bookmark",
                    count: 0,
                    isSelected: tweet.isBookmarked
                ) {
                    Task {
                        await bookmarkTweet(tweet)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
    }
}

struct TweetActionButton: View {
    let icon: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundColor(isSelected ? .blue : .secondary)
                if count > 0 {
                    Text("\(count)")
                        .font(.subheadline)
                        .foregroundColor(isSelected ? .blue : .secondary)
                }
            }
        }
    }
}

struct MediaGridView: View {
    let attachments: [MimeiFileType]
    var body: some View {
        let columns = [
            GridItem(.flexible()),
            GridItem(.flexible())
        ]
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(attachments) { attachment in
                AsyncImage(url: URL(string: attachment.url ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.gray
                }
                .frame(height: 200)
                .clipped()
            }
        }
    }
}

// MARK: - Preview
struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
    }
} 
