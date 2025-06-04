import SwiftUI

@available(iOS 16.0, *)
class FollowingsTweetViewModel: ObservableObject {
    @Published var tweets: [Tweet] = []
    @Published var isLoading: Bool = false
    private let hproseInstance: HproseInstance
    
    init(hproseInstance: HproseInstance) {
        self.hproseInstance = hproseInstance
    }
    
    func fetchTweets(page: Int, pageSize: Int) async {
        // Step 1: Fetch from cache immediately
        let cachedTweets = TweetCacheManager.shared.fetchCachedTweets(
            for: hproseInstance.appUser.mid,
            page: page,
            pageSize: pageSize
        )
        
        await MainActor.run {
            self.tweets = cachedTweets
        }
        
        // Step 2: Fetch from server and update cache
        if let serverTweets = try? await hproseInstance.fetchTweetFeed(
            user: hproseInstance.appUser,
            pageNumber: page,
            pageSize: pageSize
        ) {
            // Save new tweets to cache
            for tweet in serverTweets {
                TweetCacheManager.shared.saveTweet(tweet, hproseInstance.appUser.mid)
            }
            
            // Update the UI with new tweets
            await MainActor.run {
                self.tweets = serverTweets
            }
        }
    }
    
    func handleNewTweet(_ tweet: Tweet) {
        tweets.insert(tweet, at: 0)
    }
    
    func handleDeletedTweet(_ tweetId: String) {
        tweets.removeAll { $0.mid == tweetId }
    }
}

@available(iOS 16.0, *)
struct FollowingsTweetView: View {
    @Binding var isLoading: Bool
    let onAvatarTap: (User) -> Void
    @Binding var resetTrigger: Bool
    @Binding var scrollToTopTrigger: Bool
    @EnvironmentObject private var hproseInstance: HproseInstance
    @StateObject private var viewModel: FollowingsTweetViewModel

    init(isLoading: Binding<Bool>, onAvatarTap: @escaping (User) -> Void, resetTrigger: Binding<Bool>, scrollToTopTrigger: Binding<Bool>) {
        self._isLoading = isLoading
        self.onAvatarTap = onAvatarTap
        self._resetTrigger = resetTrigger
        self._scrollToTopTrigger = scrollToTopTrigger
        self._viewModel = StateObject(wrappedValue: FollowingsTweetViewModel(hproseInstance: HproseInstance.shared))
    }

    var body: some View {
        ScrollViewReader { proxy in
            TweetListView<TweetItemView>(
                title: "Timeline",
                tweetFetcher: { page, size in
                    await viewModel.fetchTweets(page: page, pageSize: size)
                    return viewModel.tweets
                },
                showTitle: false,
                notifications: [
                    TweetListNotification(
                        name: .newTweetCreated,
                        key: "tweet",
                        shouldAccept: { _ in true },
                        action: { _, tweet in viewModel.handleNewTweet(tweet) }
                    ),
                    TweetListNotification(
                        name: .tweetDeleted,
                        key: "tweetId",
                        shouldAccept: { _ in true },
                        action: { _, tweet in
                            viewModel.handleDeletedTweet(tweet.mid)
                        }
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
            .onChange(of: resetTrigger) { newValue in
                if newValue {
                    resetTrigger = false
                }
            }
            .onChange(of: scrollToTopTrigger) { newValue in
                if newValue {
                    withAnimation {
                        proxy.scrollTo("top", anchor: .top)
                    }
                    scrollToTopTrigger = false
                }
            }
        }
    }
}
