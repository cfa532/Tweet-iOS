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
        print("DEBUG: [ProfileTweetsViewModel] Updating pinned tweet IDs from \(pinnedTweetIds.count) to \(newPinnedTweetIds.count)")
        
        // Remove any tweets that are now pinned from the current list
        let newlyPinnedIds = newPinnedTweetIds.subtracting(pinnedTweetIds)
        if !newlyPinnedIds.isEmpty {
            print("DEBUG: [ProfileTweetsViewModel] Removing \(newlyPinnedIds.count) newly pinned tweets from list")
            tweets.removeAll { tweet in
                newlyPinnedIds.contains(tweet.mid)
            }
        }
        
        // Add back any tweets that are no longer pinned
        let newlyUnpinnedIds = pinnedTweetIds.subtracting(newPinnedTweetIds)
        if !newlyUnpinnedIds.isEmpty {
            print("DEBUG: [ProfileTweetsViewModel] \(newlyUnpinnedIds.count) tweets are no longer pinned")
        }
        
        pinnedTweetIds = newPinnedTweetIds
    }
    
    func fetchTweets(page: UInt, pageSize: UInt, shouldCache: Bool = false) async throws -> [Tweet?] {
        do {
            let serverTweets = try await hproseInstance.fetchUserTweets(
                user: user,
                pageNumber: page,
                pageSize: pageSize
            )
            print("DEBUG: [ProfileTweetsViewModel] Got \(serverTweets.count) tweets from server, filtering out \(pinnedTweetIds.count) pinned tweets")
            
            // Filter out pinned tweets from server response
            let filteredTweets = serverTweets.filter { tweet in
                if let tweet = tweet {
                    let isPinned = pinnedTweetIds.contains(tweet.mid)
                    if isPinned {
                        print("DEBUG: [ProfileTweetsViewModel] Filtering out pinned tweet: \(tweet.mid)")
                    }
                    return !isPinned
                }
                return true // Keep nil tweets
            }
            
            print("DEBUG: [ProfileTweetsViewModel] After filtering: \(filteredTweets.count) tweets")
            
            await MainActor.run {
                tweets.mergeTweets(filteredTweets.compactMap{ $0 })
            }
            
            // Cache tweets only if it's the appUser's profile
            if shouldCache && user.mid == hproseInstance.appUser.mid {
                for tweet in filteredTweets.compactMap({ $0 }) {
                    TweetCacheManager.shared.saveTweet(tweet, userId: user.mid)
                }
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
            // Don't add the tweet if it's pinned
            if !pinnedTweetIds.contains(tweet.mid) {
                print("DEBUG: [ProfileTweetsViewModel] Adding new tweet to list: \(tweet.mid)")
                // Use mergeTweets to maintain proper chronological ordering
                tweets.mergeTweets([tweet])
                
                // Cache the new tweet if it's the appUser's profile
                if user.mid == hproseInstance.appUser.mid {
                    TweetCacheManager.shared.saveTweet(tweet, userId: user.mid)
                    print("DEBUG: [ProfileTweetsViewModel] Cached new tweet: \(tweet.mid)")
                }
            } else {
                print("DEBUG: [ProfileTweetsViewModel] Skipping pinned tweet: \(tweet.mid)")
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
            print("[ProfileTweetsViewModel] Privacy changed for appUser's tweet: \(tweetId)")
        } else {
            // For other users' profiles, remove the tweet since it became private
            tweets.removeAll { $0.mid == tweetId }
            print("[ProfileTweetsViewModel] Removed private tweet from other user's profile: \(tweetId)")
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
        onAvatarTapInProfile: ((User) -> Void)? = nil,
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
        self.onAvatarTapInProfile = onAvatarTapInProfile
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
        ScrollViewReader { proxy in
            TweetListView<TweetItemView>(
            title: "",
            tweets: $viewModel.tweets,
            tweetFetcher: { page, size, isFromCache, shouldCache in
                if isFromCache {
                    // Fetch from cache for profile tweets (only if it's the appUser's profile)
                    if user.mid == hproseInstance.appUser.mid {
                        let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
                            for: user.mid, page: page, pageSize: size, currentUserId: hproseInstance.appUser.mid)
                        return cachedTweets
                    } else {
                        // Don't cache other users' tweets
                        return []
                    }
                } else {
                    return try await viewModel.fetchTweets(page: page, pageSize: size, shouldCache: shouldCache)
                }
            },
            showTitle: false, shouldCacheServerTweets: false,
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
            ], onScroll: onScroll,
            header: {
                AnyView(
                    VStack(spacing: 0) {
                        header()
                            .id("top")
                        if !pinnedTweets.isEmpty {
                            VStack(spacing: 0) {
                                Text(LocalizedStringKey("Pinned"))
                                    .font(.subheadline)
                                    .bold()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal)
                                    .padding(.top, 8)
                                    .padding(.bottom, 4)
                                    .background(Color(UIColor.systemBackground))
                                
                                // Display pinned tweets
                                ForEach(pinnedTweets, id: \.mid) { pinnedTweet in
                                                                    TweetItemView(
                                    tweet: pinnedTweet,
                                    isPinned: true,
                                    isInProfile: true,
                                    showDeleteButton: user.mid == hproseInstance.appUser.mid,
                                    onAvatarTap: { user in
                                        onUserSelect(user)
                                    },
                                    onTap: nil, // Will use NavigationLink instead
                                    onAvatarTapInProfile: onAvatarTapInProfile,
                                    currentProfileUser: user,
                                    onRemove: { tweetId in
                                        // Handle pinned tweet removal if needed
                                        print("DEBUG: [ProfileTweetsSection] Pinned tweet removal requested for: \(tweetId)")
                                        // Post notification to trigger deletion handling in ProfileView
                                        NotificationCenter.default.post(
                                            name: .tweetDeleted,
                                            object: nil,
                                            userInfo: ["tweetId": tweetId]
                                        )
                                    }
                                )
                                    .background(Color(UIColor.systemBackground))
                                }
                            }
                            .onAppear {
                                print("DEBUG: [ProfileTweetsSection] Pinned tweets section appeared with \(pinnedTweets.count) tweets")
                            }
                        } else {
                            // No pinned tweets to display
                        }
                    }
                )
            },
            rowView: { tweet in
                TweetItemView(
                    tweet: tweet,
                    isPinned: pinnedTweets.contains { $0.mid == tweet.mid },
                    isInProfile: true,
                    showDeleteButton: user.mid == hproseInstance.appUser.mid,
                    onAvatarTap: { user in
                        onUserSelect(user)
                    },
                    onTap: nil, // Will use NavigationLink instead
                    onAvatarTapInProfile: onAvatarTapInProfile,
                    currentProfileUser: user,
                    onRemove: { tweetId in
                        if let idx = viewModel.tweets.firstIndex(where: { $0.mid == tweetId }) {
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
        .onChange(of: user.mid) { _, _ in
            viewModel.tweets.removeAll()
        }
        .onChange(of: pinnedTweetIds) { _, newPinnedTweetIds in
            print("DEBUG: [ProfileTweetsSection] Pinned tweet IDs changed to: \(newPinnedTweetIds)")
            viewModel.updatePinnedTweetIds(newPinnedTweetIds)
        }
        .onDisappear {
            print("DEBUG: [ProfileTweetsSection] Section disappeared")
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrollToTop)) { _ in
            withAnimation(.easeInOut(duration: 0.5)) {
                proxy.scrollTo("top", anchor: .top)
            }
        }
        }
    }
    

} 
