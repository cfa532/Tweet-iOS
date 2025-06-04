import SwiftUI

// MARK: - ProfileTweetsViewModel
@available(iOS 16.0, *)
class ProfileTweetsViewModel: ObservableObject {
    @Published var tweets: [Tweet] = []
    @Published var isLoading: Bool = false
    private let hproseInstance: HproseInstance
    private let user: User
    private let pinnedTweetIds: Set<String>
    
    init(hproseInstance: HproseInstance, user: User, pinnedTweetIds: Set<String>) {
        self.hproseInstance = hproseInstance
        self.user = user
        self.pinnedTweetIds = pinnedTweetIds
    }
    
    func fetchTweets(page: Int, pageSize: Int) async {
        // Step 1: Fetch from cache immediately
        let cachedTweets = TweetCacheManager.shared.fetchCachedTweets(
            for: user.mid,
            page: page,
            pageSize: pageSize
        )
        
        // Filter out pinned tweets from cache
        let filteredCached = cachedTweets.filter { !pinnedTweetIds.contains($0.mid) }
        
        await MainActor.run {
            self.tweets = filteredCached
        }
        
        // Step 2: Fetch from server
        if let serverTweets = try? await hproseInstance.fetchUserTweet(
            user: user,
            startRank: UInt(page * pageSize),
            endRank: UInt((page + 1) * pageSize - 1)
        ) {
            // Filter out pinned tweets from server response
            let filteredServer = serverTweets.filter { !pinnedTweetIds.contains($0.mid) }
            
            await MainActor.run {
                self.tweets = filteredServer
            }
        }
    }
}

private struct TweetListScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

@available(iOS 16.0, *)
struct ProfileTweetsSection: View {
    let isLoading: Bool
    let pinnedTweets: [Tweet] // sorted, from state
    let pinnedTweetIds: Set<String> // from state
    let user: User
    let hproseInstance: HproseInstance
    let onUserSelect: (User) -> Void
    let onPinnedTweetsRefresh: () async -> Void
    let onScroll: (CGFloat) -> Void
    @StateObject private var viewModel: ProfileTweetsViewModel
    
    init(
        isLoading: Bool,
        pinnedTweets: [Tweet],
        pinnedTweetIds: Set<String>,
        user: User,
        hproseInstance: HproseInstance,
        onUserSelect: @escaping (User) -> Void,
        onPinnedTweetsRefresh: @escaping () async -> Void,
        onScroll: @escaping (CGFloat) -> Void
    ) {
        self.isLoading = isLoading
        self.pinnedTweets = pinnedTweets
        self.pinnedTweetIds = pinnedTweetIds
        self.user = user
        self.hproseInstance = hproseInstance
        self.onUserSelect = onUserSelect
        self.onPinnedTweetsRefresh = onPinnedTweetsRefresh
        self.onScroll = onScroll
        self._viewModel = StateObject(wrappedValue: ProfileTweetsViewModel(
            hproseInstance: hproseInstance,
            user: user,
            pinnedTweetIds: pinnedTweetIds
        ))
    }
    
    var body: some View {
        if isLoading {
            ProgressView("Loading tweets...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if !pinnedTweets.isEmpty {
                    Text("Pinned")
                        .font(.subheadline)
                        .bold()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(UIColor.systemBackground))
                }
                TweetListView<TweetItemView>(
                    title: "",
                    tweetFetcher: { page, size in
                        print("[ProfileTweetsSection] tweetFetcher called: page=\(page), size=\(size)")
                        if page == 0 {
                            await viewModel.fetchTweets(page: page, pageSize: size)
                            let combined = pinnedTweets + viewModel.tweets
                            let result = Array(combined.prefix(size))
                            print("[ProfileTweetsSection] Returning page 0: pinned=\(pinnedTweets.count), regular=\(viewModel.tweets.count), total=\(result.count)")
                            return result
                        } else {
                            await viewModel.fetchTweets(page: page, pageSize: size)
                            print("[ProfileTweetsSection] Returning page \(page): tweets=\(viewModel.tweets.count)")
                            return viewModel.tweets
                        }
                    },
                    showTitle: false,
                    notifications: [
                        TweetListNotification(
                            name: .newTweetCreated,
                            key: "tweet",
                            shouldAccept: { tweet in tweet.authorId == user.mid },
                            action: { tweets, tweet in tweets.insert(tweet, at: 0) }
                        ),
                        TweetListNotification(
                            name: .tweetDeleted,
                            key: "tweetId",
                            shouldAccept: { _ in true },
                            action: { tweets, tweet in tweets.removeAll { $0?.mid == tweet.mid } }
                        )
                    ],
                    rowView: { tweet in
                        TweetItemView(
                            tweet: tweet,
                            isPinned: pinnedTweetIds.contains(tweet.mid),
                            isInProfile: true,
                            onAvatarTap: { user in onUserSelect(user) }
                        )
                    }
                )
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            .refreshable {
                await onPinnedTweetsRefresh()
            }
        }
    }
} 
