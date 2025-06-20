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
    
    func fetchTweets(page: UInt, pageSize: UInt) async throws -> [Tweet?] {
        do {
            let serverTweets = try await hproseInstance.fetchUserTweet(
                user: user,
                pageNumber: page,
                pageSize: pageSize
            )
            // Filter out pinned tweets from server response
            let filteredTweets = serverTweets.filter { tweet in
                if let tweet = tweet {
                    return !pinnedTweetIds.contains(tweet.mid)
                }
                return true // Keep nil tweets
            }
            await MainActor.run {
                tweets.mergeTweets(filteredTweets.compactMap{ $0 })
            }
            return filteredTweets
        } catch {
            print("[ProfileTweetsViewModel] Error fetching tweets: \(error)")
            return []
        }
    }
    
    func handleNewTweet(_ tweet: Tweet) {
        tweets.insert(tweet, at: 0)
    }
    
    func handleDeletedTweet(_ tweetId: String) {
        tweets.removeAll { $0.mid == tweetId }
        TweetCacheManager.shared.deleteTweet(mid: tweetId)
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
                    tweets: $viewModel.tweets,
                    tweetFetcher: { page, size, isFromCache in
                        if isFromCache {
                            // Fetch from cache
//                            let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(for: user.mid, page: page, pageSize: size)
//                            print("[DEBUG] Fetching cached tweets for user: \(user.mid)")
//                            for tweet in cachedTweets {
//                                if let t = tweet {
//                                    print("[DEBUG] Cached tweet authorId: \(t.authorId), mid: \(t.mid)")
//                                }
//                            }
//                            await MainActor.run {
//                                viewModel.tweets.mergeTweets(cachedTweets.compactMap { tweet in
//                                    if let t = tweet, t.authorId == user.mid {
//                                        print("[DEBUG] Merging tweet mid: \(t.mid) for user: \(t.authorId)")
//                                        return t
//                                    } else {
//                                        return nil
//                                    }
//                                })
//                            }
//                            return cachedTweets
                            return []
                        } else {
                            // Fetch from server
                            return try await viewModel.fetchTweets(page: page, pageSize: size)
                        }
                    },
                    showTitle: false,
                    notifications: [
                        TweetListNotification(
                            name: .newTweetCreated,
                            key: "tweet",
                            shouldAccept: { tweet in tweet.authorId == user.mid },
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
                            isPinned: pinnedTweets.contains { $0.mid == tweet.mid },
                            isInProfile: true,
                            onAvatarTap: { user in
                                // Handle avatar tap - navigate to profile
                            },
                            onRemove: { tweetId in
                                if let idx = viewModel.tweets.firstIndex(where: { $0.id == tweetId }) {
                                    viewModel.tweets.remove(at: idx)
                                }
                            }
                        )
                    }
                )
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            .refreshable {
                await onPinnedTweetsRefresh()
            }
            .onChange(of: user.mid) { _ in
                viewModel.tweets.removeAll()
            }
        }
    }
} 
