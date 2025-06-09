import SwiftUI

struct TweetListNotification {
    let name: Notification.Name
    let key: String
    let shouldAccept: (Tweet) -> Bool
    let action: (Tweet) -> Void
}

@available(iOS 16.0, *)
struct TweetListView<RowView: View>: View {
    // MARK: - Properties
    @StateObject private var appUserStore = AppUserStore.shared
    @State private var tweets: [Tweet] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var hasMoreTweets = true
    @State private var initialLoadComplete = false
    @State private var currentPage: UInt = 0
    
    private let pageSize: UInt
    private let rowView: (Tweet) -> RowView
    private let tweetFetcher: (UInt, UInt, Bool) async throws -> [Tweet?]
    private let notifications: [TweetListNotification]
    
    // MARK: - Initialization
    init(
        pageSize: UInt = 20,
        rowView: @escaping (Tweet) -> RowView,
        tweetFetcher: @escaping (UInt, UInt, Bool) async throws -> [Tweet?],
        notifications: [TweetListNotification] = []
    ) {
        self.pageSize = pageSize
        self.rowView = rowView
        self.tweetFetcher = tweetFetcher
        self.notifications = notifications
    }
    
    // MARK: - Methods
    private func performInitialLoad() async {
        print("[TweetListView] Starting initial load")
        isLoading = true
        
        do {
            // Step 1: Fetch from cache
            let tweetsInCache = try await tweetFetcher(0, pageSize, true)
            let appUser = await appUserStore.appUser
            
            await MainActor.run {
                tweets.mergeTweets(tweetsInCache.compactMap { $0 })
                print("[TweetListView] After cache: \(tweets.count) tweets for user: \(appUser.mid)")
            }
            
            // Step 2: Fetch from backend
            let tweetsInBackend = try await tweetFetcher(0, pageSize, false)
            let hasValidTweet = tweetsInBackend.contains { $0 != nil }
            if hasValidTweet {
                await MainActor.run {
                    tweets.mergeTweets(tweetsInBackend.compactMap { $0 })
                    print("[TweetListView] After backend: \(tweets.count) tweets for user: \(appUser.mid)")
                }
            } else if tweetsInBackend.count < pageSize {
                await MainActor.run {
                    hasMoreTweets = false
                }
                print("[TweetListView] No more tweets available")
            } else {
                // All tweets are nil, auto-increment and try again
                print("[TweetListView] All tweets nil for page 0, auto-incrementing page")
                await MainActor.run { isLoading = false }
                loadMoreTweets(page: 1)
                return
            }
        } catch {
            print("[TweetListView] Error during initial load: \(error)")
            await MainActor.run {
                hasMoreTweets = false
            }
        }
        
        await MainActor.run {
            isLoading = false
            initialLoadComplete = true
        }
    }
    
    func refreshTweets() async {
        guard !isLoading else { return }
        await MainActor.run {
            initialLoadComplete = false
            tweets = []
            currentPage = 0
            hasMoreTweets = true
        }
        await performInitialLoad()
    }
    
    func loadMoreTweets(page: UInt? = nil) {
        print("[TweetListView] loadMoreTweets called - hasMoreTweets: \(hasMoreTweets), isLoadingMore: \(isLoadingMore), initialLoadComplete: \(initialLoadComplete), currentPage: \(currentPage)")
        guard hasMoreTweets, !isLoadingMore, initialLoadComplete else {
            print("[TweetListView] loadMoreTweets guard failed - hasMoreTweets: \(hasMoreTweets), isLoadingMore: \(isLoadingMore), initialLoadComplete: \(initialLoadComplete)")
            return
        }
        
        let nextPage = page ?? (currentPage + 1)
        let pageSize = self.pageSize
        
        if initialLoadComplete { isLoadingMore = true }
        
        Task {
            do {
                print("[TweetListView] Starting to load more tweets - page: \(nextPage)")
                // Step 1: Fetch from cache for the given page
                let tweetsInCache = try await tweetFetcher(nextPage, pageSize, true)
                
                print("[TweetListView] Got \(tweetsInCache.count) tweets from cache")
                await MainActor.run {
                    tweets.mergeTweets(tweetsInCache.compactMap { $0 })
                }
                
                // Step 2: Fetch from backend
                let tweetsInBackend = try await tweetFetcher(nextPage, pageSize, false)
                let hasValidTweet = tweetsInBackend.contains { $0 != nil }
                if hasValidTweet {
                    print("[TweetListView] Got \(tweetsInBackend.count) tweets from backend")
                    await MainActor.run {
                        tweets.mergeTweets(tweetsInBackend.compactMap { $0 })
                        currentPage = nextPage
                    }
                    print("[TweetListView] Updated currentPage to \(currentPage)")
                } else if tweetsInBackend.count < pageSize {
                    await MainActor.run {
                        hasMoreTweets = false
                    }
                    print("[TweetListView] No more tweets available")
                } else {
                    // All tweets are nil, auto-increment and try again
                    print("[TweetListView] All tweets nil for page \(nextPage), auto-incrementing page")
                    await MainActor.run { isLoadingMore = false }
                    loadMoreTweets(page: nextPage + 1)
                    return
                }
            } catch {
                print("[TweetListView] Error loading more tweets: \(error)")
                await MainActor.run {
                    hasMoreTweets = false
                }
            }
            
            await MainActor.run { isLoadingMore = false }
        }
    }
    
    var body: some View {
        ScrollView {
            TweetListContentView(
                tweets: tweets,
                rowView: rowView,
                hasMoreTweets: hasMoreTweets,
                isLoadingMore: isLoadingMore,
                isLoading: isLoading,
                initialLoadComplete: initialLoadComplete,
                loadMoreTweets: { loadMoreTweets() }
            )
        }
        .refreshable {
            await refreshTweets()
        }
        .task {
            if tweets.isEmpty {
                await refreshTweets()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .userDidLogin)) { _ in
            Task {
                await refreshTweets()
            }
        }
        // Listen to all notifications
        ForEach(notifications, id: \.name) { notification in
            EmptyView()
                .onReceive(NotificationCenter.default.publisher(for: notification.name)) { notif in
                    if let tweet = notif.userInfo?[notification.key] as? Tweet, notification.shouldAccept(tweet) {
                        notification.action(tweet)
                    }
                    // Special case: tweetDeleted may send tweetId as String
                    if notification.key == "tweetId", let tweetId = notif.userInfo?[notification.key] as? String {
                        Task { @MainActor in
                            tweets.removeAll { $0.id == tweetId }
                            TweetCacheManager.shared.deleteTweet(mid: tweetId)
                        }
                    }
                }
        }
    }
}

@available(iOS 16.0, *)
struct TweetListContentView<RowView: View>: View {
    let tweets: [Tweet]
    let rowView: (Tweet) -> RowView
    let hasMoreTweets: Bool
    let isLoadingMore: Bool
    let isLoading: Bool
    let initialLoadComplete: Bool
    let loadMoreTweets: () -> Void
    
    var body: some View {
        LazyVStack(spacing: 0) {
            Color.clear.frame(height: 0)
            ForEach(tweets, id: \.mid) { tweet in
                rowView(tweet)
            }
            // Sentinel view for infinite scroll
            if hasMoreTweets {
                ProgressView()
                    .frame(height: 40)
                    .onAppear {
                        print("[TweetListContentView] ProgressView appeared - initialLoadComplete: \(initialLoadComplete), isLoadingMore: \(isLoadingMore)")
                        if initialLoadComplete && !isLoadingMore {
                            print("[TweetListContentView] Scheduling loadMoreTweets")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                if initialLoadComplete && !isLoadingMore {
                                    print("[TweetListContentView] Calling loadMoreTweets")
                                    loadMoreTweets()
                                }
                            }
                        }
                    }
            }
        }
    }
}

