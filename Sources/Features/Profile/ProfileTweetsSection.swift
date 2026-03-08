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
        // Wait for app initialization with timeout — don't block forever when server is unreachable
        if !hproseInstance.isAppInitialized {
            print("⏳ [PROFILE FETCH] Waiting for app initialization (max 10s)...")
            var waitCount = 0
            while !hproseInstance.isAppInitialized && waitCount < 100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waitCount += 1
            }
            if hproseInstance.isAppInitialized {
                print("✅ [PROFILE FETCH] App initialization complete")
            } else {
                print("⚠️ [PROFILE FETCH] Timed out waiting for app initialization")
            }
        }
        
        do {
            let serverTweets = try await hproseInstance.fetchUserTweets(
                user: user,
                pageNumber: page,
                pageSize: pageSize
            )
            
            // Filter out pinned tweets from server response
            let filteredTweets = serverTweets.filter { tweet in
                if let tweet = tweet {
                    let isPinned = pinnedTweetIds.contains(tweet.mid)
                    if isPinned {
                    }
                    return !isPinned
                }
                return true // Keep nil tweets
            }
            
            
            await MainActor.run {
                tweets.mergeTweets(filteredTweets.compactMap{ $0 })
            }
            
            // Cache profile tweets under their authorId (which is user.mid for profile view)
            for tweet in filteredTweets.compactMap({ $0 }) {
                TweetCacheManager.shared.saveTweet(tweet, userId: tweet.authorId)
            }
            
            return filteredTweets
        } catch {
            throw error
        }
    }

    func handleNewTweet(_ tweet: Tweet) {
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
        tweets.removeAll { $0.mid == tweetId }
        TweetCacheManager.shared.deleteTweet(mid: tweetId)
    }
    
    func handlePrivacyChange(tweetId: String) {
        // For profile view, handle privacy changes based on user type
        if user.mid == hproseInstance.appUser.mid {
            // For appUser's profile, keep all tweets (public and private)
            // Privacy change will be reflected in UI, no need to remove/add
        } else {
            // For other users' profiles, remove the tweet since it became private
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
                if isFromCache {
                    let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
                        for: user.mid, page: page, pageSize: size, currentUserId: hproseInstance.appUser.mid, isProfileView: true)
                    return cachedTweets
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
        .onDisappear {
        }
    }
    

} 
