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
            let serverTweets = try await hproseInstance.fetchUserTweets(
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
        // Only show private tweets if the current user is the author
        if !(tweet.isPrivate ?? false) || tweet.authorId == hproseInstance.appUser.mid {
            tweets.insert(tweet, at: 0)
        }
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
struct ProfileTweetsSection<Header: View>: View {
    let pinnedTweets: [Tweet] // sorted, from state
    let pinnedTweetIds: Set<String> // from state
    let user: User
    let hproseInstance: HproseInstance
    let onUserSelect: (User) -> Void
    let onTweetTap: (Tweet) -> Void
    let onPinnedTweetsRefresh: () async -> Void
    let onScroll: (CGFloat) -> Void
    @StateObject private var viewModel: ProfileTweetsViewModel
    let header: () -> Header
    
    init(
        pinnedTweets: [Tweet],
        pinnedTweetIds: Set<String>,
        user: User,
        hproseInstance: HproseInstance,
        onUserSelect: @escaping (User) -> Void,
        onTweetTap: @escaping (Tweet) -> Void,
        onPinnedTweetsRefresh: @escaping () async -> Void,
        onScroll: @escaping (CGFloat) -> Void,
        @ViewBuilder header: @escaping () -> Header = { EmptyView() }
    ) {
        self.pinnedTweets = pinnedTweets
        self.pinnedTweetIds = pinnedTweetIds
        self.user = user
        self.hproseInstance = hproseInstance
        self.onUserSelect = onUserSelect
        self.onTweetTap = onTweetTap
        self.onPinnedTweetsRefresh = onPinnedTweetsRefresh
        self.onScroll = onScroll
        self.header = header
        self._viewModel = StateObject(wrappedValue: ProfileTweetsViewModel(
            hproseInstance: hproseInstance,
            user: user,
            pinnedTweetIds: pinnedTweetIds
        ))
    }
    
    var body: some View {
        TweetListView<TweetItemView>(
            title: "",
            tweets: $viewModel.tweets,
            tweetFetcher: { page, size, isFromCache in
                if isFromCache {
                    return []
                } else {
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
            header: {
                AnyView(
                    VStack(spacing: 0) {
                        header()
                        if !pinnedTweets.isEmpty {
                            Text(LocalizedStringKey("Pinned"))
                                .font(.subheadline)
                                .bold()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color(UIColor.systemBackground))
                        }
                    }
                )
            },
            rowView: { tweet in
                TweetItemView(
                    tweet: tweet,
                    isPinned: pinnedTweets.contains { $0.mid == tweet.mid },
                    isInProfile: true,
                    onAvatarTap: { user in
                        onUserSelect(user)
                    },
                    onTap: { tweet in
                        onTweetTap(tweet)
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
        .refreshable {
            await onPinnedTweetsRefresh()
        }
        .onChange(of: user.mid) { _ in
            viewModel.tweets.removeAll()
        }
        .onDisappear {
            print("DEBUG: [ProfileTweetsSection] Section disappeared")
        }
    }
    

} 
