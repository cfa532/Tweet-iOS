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
    let title: String
    let tweetFetcher: @Sendable (UInt, UInt, Bool) async throws -> [Tweet?]
    let showTitle: Bool
    let rowView: (Tweet) -> RowView
    let notifications: [TweetListNotification]
    private let pageSize: UInt = 10

    @EnvironmentObject private var hproseInstance: HproseInstance
    @Binding var tweets: [Tweet]
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var hasMoreTweets: Bool = true
    @State private var currentPage: UInt = 0
    @State private var errorMessage: String? = nil
    @State private var showDeleteResult = false
    @State private var deleteResultMessage = ""
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info
    @State private var initialLoadComplete = false
    @State private var deletedTweetIds = Set<String>()

    // MARK: - Initialization
    init(
        title: String,
        tweets: Binding<[Tweet]>,
        tweetFetcher: @escaping @Sendable (UInt, UInt, Bool) async throws -> [Tweet?],
        showTitle: Bool = true,
        notifications: [TweetListNotification]? = nil,
        rowView: @escaping (Tweet) -> RowView
    ) {
        self.title = title
        self._tweets = tweets
        self.tweetFetcher = tweetFetcher
        self.showTitle = showTitle
        // Default: listen for newTweetCreated and insert at top
        self.notifications = notifications ?? [
            TweetListNotification(
                name: .newTweetCreated,
                key: "tweet",
                shouldAccept: { _ in true },
                action: { _ in }
            ),
            TweetListNotification(
                name: .tweetDeleted,
                key: "tweetId",
                shouldAccept: { _ in true },
                action: { _ in }
            )
        ]
        self.rowView = rowView
    }

    // MARK: - Body
    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                ScrollView {
                    TweetListContentView(
                        tweets: Binding(
                            get: { tweets.map { Optional($0) } },
                            set: { newValue in
                                tweets = newValue.compactMap { $0 }
                            }
                        ),
                        rowView: { tweet in
                            rowView(tweet)
                        },
                        hasMoreTweets: hasMoreTweets,
                        isLoadingMore: isLoadingMore,
                        isLoading: isLoading,
                        initialLoadComplete: initialLoadComplete,
                        loadMoreTweets: { loadMoreTweets() }
                    )
                }
                if showToast {
                    VStack {
                        Spacer()
                        ToastView(message: toastMessage, type: toastType)
                            .padding(.bottom, 40)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut, value: showToast)
                }
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
            ForEach(Array(notifications.enumerated()), id: \ .element.name) { idx, notification in
                EmptyView()
                    .onReceive(NotificationCenter.default.publisher(for: notification.name)) { notif in
                        if let tweet = notif.userInfo?[notification.key] as? Tweet, notification.shouldAccept(tweet) {
                            notification.action(tweet)
                        }
                        // Special case: tweetDeleted may send tweetId as String
                        if notification.key == "tweetId", let tweetId = notif.userInfo?[notification.key] as? String {
                            tweets.removeAll { $0.id == tweetId }
                            TweetCacheManager.shared.deleteTweet(mid: tweetId)
                        }
                    }
            }
        }
    }

    // MARK: - Methods
    func performInitialLoad() async {
        print("[TweetListView] Starting initial load for user: \(hproseInstance.appUser.mid)")
        isLoading = true
        initialLoadComplete = false
        hasMoreTweets = true
        currentPage = 0
        tweets = []
        var page: UInt = 0
        var totalValidTweets = 0
        var keepLoading = true
        while keepLoading {
            do {
                print("[TweetListView] Loading page \(page) for user: \(hproseInstance.appUser.mid)")
                // Step 1: Fetch from cache
                let tweetsInCache = try await tweetFetcher(page, pageSize, true)
                await MainActor.run {
                    tweets.mergeTweets(tweetsInCache.compactMap { $0 })
                    totalValidTweets = tweets.count
                    print("[TweetListView] After cache: \(totalValidTweets) tweets for user: \(hproseInstance.appUser.mid)")
                }

                // Step 2: Fetch from server
                let tweetsInBackend = try await tweetFetcher(page, pageSize, false)
                await MainActor.run {
                    totalValidTweets = tweets.count
                    print("[TweetListView] After backend: \(totalValidTweets) tweets for user: \(hproseInstance.appUser.mid)")
                }

                // Update cache with server-fetched tweets
                for tweet in tweetsInBackend.compactMap({ $0 }) {
                    TweetCacheManager.shared.saveTweet(tweet, mid: tweet.mid, userId: hproseInstance.appUser.mid)
                }

                currentPage = page
                if totalValidTweets > 4 {
                    // Only set hasMoreTweets to false if we get no tweets from the server
                    hasMoreTweets = !tweetsInBackend.isEmpty
                    keepLoading = false
                    print("[TweetListView] Stopping initial load - enough tweets for user: \(hproseInstance.appUser.mid), hasMoreTweets: \(hasMoreTweets)")
                } else if tweets.count < pageSize {
                    // Only set hasMoreTweets to false if we get no tweets from the server
                    hasMoreTweets = !tweetsInBackend.isEmpty
                    keepLoading = false
                    print("[TweetListView] Stopping initial load - not enough tweets for user: \(hproseInstance.appUser.mid), hasMoreTweets: \(hasMoreTweets)")
                } else {
                    page += 1
                }
            } catch {
                print("[TweetListView] Error during initial load for user \(hproseInstance.appUser.mid): \(error)")
                errorMessage = error.localizedDescription
                break
            }
        }
        isLoading = false
        initialLoadComplete = true
        print("[TweetListView] Initial load complete - total tweets: \(tweets.count), hasMoreTweets: \(hasMoreTweets) for user: \(hproseInstance.appUser.mid)")
    }

    func refreshTweets() async {
        guard !isLoading else { return }
        initialLoadComplete = false
        await performInitialLoad()
    }

    func loadMoreTweets(page: UInt? = nil) {
        print("[TweetListView] loadMoreTweets called for user: \(hproseInstance.appUser.mid) - hasMoreTweets: \(hasMoreTweets), isLoadingMore: \(isLoadingMore), initialLoadComplete: \(initialLoadComplete), currentPage: \(currentPage)")
        guard hasMoreTweets, !isLoadingMore, initialLoadComplete else { 
            print("[TweetListView] loadMoreTweets guard failed for user: \(hproseInstance.appUser.mid) - hasMoreTweets: \(hasMoreTweets), isLoadingMore: \(isLoadingMore), initialLoadComplete: \(initialLoadComplete)")
            return 
        }
        isLoadingMore = true
        let nextPage = page ?? (currentPage + 1)
        let pageSize = self.pageSize

        Task {
            print("[TweetListView] Starting to load more tweets - page: \(nextPage) for user: \(hproseInstance.appUser.mid)")
            // Step 1: Fetch from cache for the given page
            let tweetsInCache = try? await tweetFetcher(nextPage, pageSize, true)
            await MainActor.run {
                if let cachedTweets = tweetsInCache {
                    print("[TweetListView] Got \(cachedTweets.count) tweets from cache for user: \(hproseInstance.appUser.mid)")
                    tweets.mergeTweets(cachedTweets.compactMap { $0 })
                }
            }

            // Step 2: Fetch from backend
            let tweetsInBackend = try? await tweetFetcher(nextPage, pageSize, false)
            await MainActor.run {
                if let backendTweets = tweetsInBackend {
                    print("[TweetListView] Got \(backendTweets.count) tweets from backend for user: \(hproseInstance.appUser.mid)")
                    tweets.mergeTweets(backendTweets.compactMap { $0 })
                    // Only set hasMoreTweets to false if we get no tweets from the server
                    hasMoreTweets = !backendTweets.isEmpty
                    if !hasMoreTweets {
                        print("[TweetListView] No more tweets available for user: \(hproseInstance.appUser.mid)")
                    }
                }
                isLoadingMore = false
                currentPage = nextPage
                print("[TweetListView] Updated currentPage to \(currentPage) for user: \(hproseInstance.appUser.mid)")
            }

            // Update cache with server-fetched tweets
            if let backendTweets = tweetsInBackend {
                for tweet in backendTweets.compactMap({ $0 }) {
                    TweetCacheManager.shared.saveTweet(tweet, mid: tweet.mid, userId: hproseInstance.appUser.mid)
                }
            }
        }
    }

    private func showToastWith(message: String, type: ToastView.ToastType) {
        toastMessage = message
        toastType = type
        showToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { showToast = false }
        }
    }

    // MARK: - Optimistic UI Methods
    func insertTweet(_ tweet: Tweet) {
        tweets.insert(tweet, at: 0)
    }
    
    func removeTweet(_ tweet: Tweet) async -> Void {
    }
}

@available(iOS 16.0, *)
struct TweetListContentView<RowView: View>: View {
    @Binding var tweets: [Tweet?]
    let rowView: (Tweet) -> RowView
    let hasMoreTweets: Bool
    let isLoadingMore: Bool
    let isLoading: Bool
    let initialLoadComplete: Bool
    let loadMoreTweets: () -> Void
    
    var body: some View {
        LazyVStack(spacing: 0) {
            Color.clear.frame(height: 0)
            ForEach(tweets.indices, id: \ .self) { index in
                if let tweet = tweets[index] {
                    rowView(tweet)
                        .id(index == tweets.firstIndex(where: { $0 != nil }) ? "top" : tweet.id)
                }
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

