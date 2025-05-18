import SwiftUI

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

// MARK: - Preview
struct FollowingsTweetView_Previews: PreviewProvider {
    static var previews: some View {
        FollowingsTweetView(
            tweets: .constant([]),
            isLoading: .constant(false),
            isRefreshing: .constant(false),
            loadInitialTweets: {},
            refresh: {},
            likeTweet: { _ in },
            retweet: { _ in },
            bookmarkTweet: { _ in },
            deleteTweet: { _ in }
        )
    }
} 