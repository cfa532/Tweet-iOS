import SwiftUI

struct TweetDetailView: View {
    @StateObject private var viewModel = TweetDetailViewModel()
    @State private var isShowingReplySheet = false

    var body: some View {
        VStack {
            // Existing code
            TweetListView<TweetItemView>(
                title: "Replies",
                tweets: $viewModel.tweets,
                tweetFetcher: { page, size, isFromCache in
                    if isFromCache {
                        // Fetch from cache
                        let cachedTweets = TweetCacheManager.shared.fetchCachedTweets(for: tweet.mid, page: page, pageSize: size)
                        return cachedTweets
                    } else {
                        // Fetch from server
                        await viewModel.fetchTweets(page: page, pageSize: size)
                        return viewModel.tweets.map { Optional($0) }
                    }
                },
                showTitle: false,
                notifications: [
                    TweetListNotification(
                        name: .newTweetCreated,
                        key: "tweet",
                        shouldAccept: { _ in true },
                        action: { tweet in viewModel.handleNewTweet(tweet) }
                    ),
                    TweetListNotification(
                        name: .tweetDeleted,
                        key: "tweetId",
                        shouldAccept: { _ in true },
                        action: { tweet in viewModel.handleDeletedTweet(tweet.mid) }
                    )
                ],
                rowView: { tweet in
                    TweetItemView(
                        tweet: tweet,
                        isInProfile: false,
                        onAvatarTap: onAvatarTap
                    )
                }
            )
            // Existing code
        }
    }

    private func onAvatarTap(tweet: Tweet) {
        // Implementation of onAvatarTap
    }
}

struct TweetDetailView_Previews: PreviewProvider {
    static var previews: some View {
        TweetDetailView()
    }
} 