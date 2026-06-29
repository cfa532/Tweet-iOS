import SwiftUI

// MARK: - ProfileTweetsViewModel
@available(iOS 16.0, *)
class ProfileTweetsViewModel: ObservableObject {
    @Published var tweets: [Tweet] = []
    @Published var isLoading: Bool = false
    private let hproseInstance: HproseInstance
    private let user: User
    @Published var pinnedTweetIds: Set<String>
    
    init(hproseInstance: HproseInstance, user: User, pinnedTweetIds: Set<String>) {
        self.hproseInstance = hproseInstance
        self.user = user
        self.pinnedTweetIds = pinnedTweetIds
    }
    
    func updatePinnedTweetIds(_ newPinnedTweetIds: Set<String>) {
        
        // Remove any tweets that are now pinned from the current list
        let newlyPinnedIds = newPinnedTweetIds.subtracting(pinnedTweetIds)
        if !newlyPinnedIds.isEmpty {
            tweets.removeAll { tweet in
                newlyPinnedIds.contains(tweet.mid)
            }
        }
        
        // Add back any tweets that are no longer pinned
        let newlyUnpinnedIds = pinnedTweetIds.subtracting(newPinnedTweetIds)
        if !newlyUnpinnedIds.isEmpty {
        }
        
        pinnedTweetIds = newPinnedTweetIds
    }
    
    func fetchTweets(page: UInt, pageSize: UInt) async throws -> [Tweet?] {
        do {
            let hproseInstance = hproseInstance
            let user = user
            let serverTweets = try await Task.detached(priority: .utility) {
                try await hproseInstance.fetchUserTweets(
                    user: user,
                    pageNumber: page,
                    pageSize: pageSize
                )
            }.value
            
            // Preserve backend page length for pagination; nil entries are non-renderable.
            let filteredTweets: [Tweet?] = serverTweets.map { (tweet: Tweet?) -> Tweet? in
                if let tweet = tweet {
                    guard !TweetDeletionRegistry.shared.isDeleted(tweet.mid) else {
                        return nil
                    }
                    let isPinned = pinnedTweetIds.contains(tweet.mid)
                    if isPinned {
                    }
                    return isPinned ? nil : tweet
                }
                return nil
            }
            
            return filteredTweets
        } catch {
            throw error
        }
    }

    func handleNewTweet(_ tweet: Tweet) {
        guard !TweetDeletionRegistry.shared.isDeleted(tweet.mid) else { return }

        // Only show private tweets if the current user is the author
        if !(tweet.isPrivate ?? false) || tweet.authorId == hproseInstance.appUser.mid {
            // Don't add the tweet if it's pinned
            if !pinnedTweetIds.contains(tweet.mid) {
                // Use mergeTweets to maintain proper chronological ordering
                tweets.mergeTweets([tweet])
                
                // Cache new tweets in profile under their authorId
                TweetCacheManager.shared.saveTweet(tweet, userId: tweet.authorId)
            } else {
            }
        }
    }

    func handleDeletedTweet(_ tweetId: String) {
        TweetDeletionRegistry.shared.markDeleted(tweetId)
        tweets.removeAll { $0.mid == tweetId }
        TweetCacheManager.shared.deleteTweet(mid: tweetId)
    }
    
    func handlePrivacyChange(tweetId: String) {
        // TweetListView's .tweetPrivacyChanged listener unconditionally removes
        // the tweet from the bound array before calling this action. For the
        // appUser's own profile we want to keep it visible (the cell renders the
        // updated public/private state). Re-insert from the singleton.
        if user.mid == hproseInstance.appUser.mid {
            guard let tweet = Tweet.getInstance(for: tweetId) else { return }
            // Don't add the tweet if it's pinned (pinned section renders separately)
            if !pinnedTweetIds.contains(tweet.mid) {
                tweets.mergeTweets([tweet])
            }
        } else {
            // For other users' profiles, removal already happened in TweetListView.
            // Calling removeAll again here is harmless but redundant — keep it as
            // a safety net in case TweetListView's contract changes.
            tweets.removeAll { $0.mid == tweetId }
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
struct ProfileTweetsSection<Header: View>: View {
    let pinnedTweets: [Tweet] // sorted, from state
    let pinnedTweetIds: Set<String> // from state
    let user: User
    let hproseInstance: HproseInstance
    let onUserSelect: (User) -> Void
    let onTweetTap: (Tweet) -> Void
    let onAvatarTapInProfile: ((User) -> Void)?
    let onPinnedTweetsRefresh: () async -> Void
    let onScroll: (CGFloat, CGFloat) -> Void  // (offset, delta)
    let onShowLogin: (() -> Void)?
    let onShowToast: ((String, Bool) -> Void)?
    let routeRefreshToken: Int
    let headerRefreshToken: Int
    let resyncedTweets: [Tweet]
    let resyncedTweetsToken: Int
    @StateObject private var viewModel: ProfileTweetsViewModel
    let header: () -> Header

    init(
        pinnedTweets: [Tweet],
        pinnedTweetIds: Set<String>,
        user: User,
        hproseInstance: HproseInstance,
        onUserSelect: @escaping (User) -> Void,
        onTweetTap: @escaping (Tweet) -> Void,
        onAvatarTapInProfile: ((User) -> Void)? = nil,
        onPinnedTweetsRefresh: @escaping () async -> Void,
        onScroll: @escaping (CGFloat, CGFloat) -> Void,  // (offset, delta)
        onShowLogin: (() -> Void)? = nil,
        onShowToast: ((String, Bool) -> Void)? = nil,
        routeRefreshToken: Int = 0,
        headerRefreshToken: Int = 0,
        resyncedTweets: [Tweet] = [],
        resyncedTweetsToken: Int = 0,
        @ViewBuilder header: @escaping () -> Header = { EmptyView() }
    ) {
        self.pinnedTweets = pinnedTweets
        self.pinnedTweetIds = pinnedTweetIds
        self.user = user
        self.hproseInstance = hproseInstance
        self.onUserSelect = onUserSelect
        self.onTweetTap = onTweetTap
        self.onAvatarTapInProfile = onAvatarTapInProfile
        self.onPinnedTweetsRefresh = onPinnedTweetsRefresh
        self.onScroll = onScroll
        self.onShowLogin = onShowLogin
        self.onShowToast = onShowToast
        self.routeRefreshToken = routeRefreshToken
        self.headerRefreshToken = headerRefreshToken
        self.resyncedTweets = resyncedTweets
        self.resyncedTweetsToken = resyncedTweetsToken
        self.header = header
        self._viewModel = StateObject(wrappedValue: ProfileTweetsViewModel(
            hproseInstance: hproseInstance,
            user: user,
            pinnedTweetIds: pinnedTweetIds
        ))
    }
    
    var body: some View {
        TweetListView(
            title: "",
            tweets: $viewModel.tweets,
            tweetFetcher: { page, size, isFromCache in
                let startTime = Date()
                if isFromCache {
                    print("📋 [PROFILE CACHE LOAD] Fetching page \(page) from cache for \(user.mid)")
                    let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
                        for: user.mid, page: page, pageSize: size, currentUserId: hproseInstance.appUser.mid, isProfileView: true)
                    let elapsed = Date().timeIntervalSince(startTime) * 1000
                    let validCount = cachedTweets.compactMap { $0 }.count
                    print("✅ [PROFILE CACHE LOAD] Returned \(validCount) tweets in \(String(format: "%.1f", elapsed))ms for \(user.mid)")
                    return cachedTweets
                } else {
                    print("🌐 [PROFILE SERVER LOAD] Fetching page \(page) from server for \(user.mid)")
                    let serverTweets = try await viewModel.fetchTweets(page: page, pageSize: size)
                    let elapsed = Date().timeIntervalSince(startTime) * 1000
                    let validCount = serverTweets.compactMap { $0 }.count
                    print("✅ [PROFILE SERVER LOAD] Returned \(validCount) tweets in \(String(format: "%.1f", elapsed))ms for \(user.mid)")
                    return serverTweets
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
                ),
                TweetListNotification(
                    name: .tweetPrivacyChanged,
                    key: "tweetId",
                    shouldAccept: { _ in true },
                    action: { tweet in viewModel.handlePrivacyChange(tweetId: tweet.mid) }
                )
            ],
            onScroll: onScroll,
            leadingPadding: 5,
            trailingPadding: 7,
            pinnedTweets: pinnedTweets,
            feedIdentifier: "profile_\(user.mid)",
            externalRefreshToken: routeRefreshToken,
            profileResyncedTweets: resyncedTweets,
            profileResyncedTweetsToken: resyncedTweetsToken,
            emptyStateText: LocalizedStringKey("No tweets yet"),
            header: {
                AnyView(
                    VStack(spacing: 0) {
                        header()
                            .id("top")
                        if !pinnedTweets.isEmpty {
                            Text(LocalizedStringKey("Pinned"))
                                .font(.subheadline)
                                .bold()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 5)
                                .padding(.trailing, 7)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                                .background(Color(UIColor.systemBackground))
                        }
                    }
                )
            },
            headerRefreshToken: headerRefreshToken,
            onRefreshExtra: onPinnedTweetsRefresh,
            onAvatarTap: { user in
                // If onAvatarTapInProfile is provided, use it (for scroll-to-top in profile)
                // Otherwise use onUserSelect for navigation
                if let onAvatarTapInProfile = onAvatarTapInProfile {
                    onAvatarTapInProfile(user)
                } else {
                    onUserSelect(user)
                }
            },
            onTweetTap: onTweetTap,
            onShowLogin: onShowLogin,
            onShowToast: onShowToast
        )
        .frame(maxHeight: .infinity)
        .onChange(of: user.mid) { _, _ in
            viewModel.tweets.removeAll()
        }
        .onChange(of: pinnedTweetIds) { _, newPinnedTweetIds in
            viewModel.updatePinnedTweetIds(newPinnedTweetIds)
        }
    }
    

} 
