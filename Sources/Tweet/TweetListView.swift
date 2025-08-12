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
    let header: (() -> AnyView)?
    let notifications: [TweetListNotification]
    let onScroll: ((CGFloat) -> Void)?
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
        onScroll: ((CGFloat) -> Void)? = nil,
        header: (() -> AnyView)? = nil,
        rowView: @escaping (Tweet) -> RowView
    ) {
        self.title = title
        self._tweets = tweets
        self.tweetFetcher = tweetFetcher
        self.showTitle = showTitle
        self.onScroll = onScroll
        self.header = header
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
                    VStack(spacing: 0) {
                        TweetListContentView(
                            tweets: Binding(
                                get: { tweets.map { Optional($0) } },
                                set: { newValue in
                                    tweets = newValue.compactMap { $0 }
                                }
                            ),
                            header: header,
                            rowView: { tweet in
                                rowView(tweet)
                            },
                            hasMoreTweets: $hasMoreTweets,
                            isLoadingMore: isLoadingMore,
                            isLoading: isLoading,
                            initialLoadComplete: initialLoadComplete,
                            loadMoreTweets: { loadMoreTweets() }
                        )
                    }
                }
                .coordinateSpace(name: "scroll")
                
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
        currentPage = 0
        tweets = []
        let page: UInt = 0

        do {
            print("[TweetListView] Loading page \(page) for user: \(hproseInstance.appUser.mid)")
            
            // Step 1: Load from cache first for instant UX (always try cache)
            let tweetsFromCache = try await tweetFetcher(page, pageSize, true)
            await MainActor.run {
                tweets.mergeTweets(tweetsFromCache.compactMap { $0 })
                isLoading = false
                initialLoadComplete = true
                print("[TweetListView] Loaded \(tweetsFromCache.compactMap { $0 }.count) tweets from cache")
            }
            
            // Step 2: Load from server to update with fresh data (non-blocking, no retry)
            Task {
                await loadFromServer(page: page, pageSize: pageSize)
            }
            
        } catch {
            print("[TweetListView] Error during initial load for user \(hproseInstance.appUser.mid): \(error)")
            errorMessage = error.localizedDescription
            await MainActor.run {
                isLoading = false
                initialLoadComplete = true
            }
        }
        
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
        
        let nextPage = page ?? (currentPage + 1)
        let pageSize = self.pageSize
        
        Task {
            isLoadingMore = true
            
            do {
                print("[TweetListView] Starting to load more tweets - page: \(nextPage) for user: \(hproseInstance.appUser.mid)")
                
                // Step 1: Load from cache first for instant UX
                let tweetsFromCache = try await tweetFetcher(nextPage, pageSize, true)
                await MainActor.run {
                    print("[TweetListView] Got \(tweetsFromCache.count) tweets from cache for user: \(hproseInstance.appUser.mid)")
                    tweets.mergeTweets(tweetsFromCache.compactMap { $0 })
                }
                
                // Step 2: Load from server to update with fresh data (non-blocking, no retry)
                Task {
                    await loadFromServer(page: nextPage, pageSize: pageSize)
                }
            } catch {
                print("[TweetListView] Error loading more tweets: \(error)")
                await MainActor.run { hasMoreTweets = false; isLoadingMore = false }
            }
        }
    }
    
    // MARK: - Server Loading (No Retry)
    private func loadFromServer(page: UInt, pageSize: UInt) async {
        let networkMonitor = NetworkMonitor.shared
        
        // Skip server loading if no network connection
        guard networkMonitor.hasAnyConnection else {
            print("[TweetListView] No network connection available, skipping server load")
            await MainActor.run { isLoadingMore = false }
            return
        }
        
        do {
            let tweetsFromServer = try await tweetFetcher(page, pageSize, false)
            let hasValidTweet = tweetsFromServer.contains { $0 != nil }
            
            await MainActor.run {
                print("[TweetListView] Got \(tweetsFromServer.count) tweets from server for user: \(hproseInstance.appUser.mid)")
                tweets.mergeTweets(tweetsFromServer.compactMap { $0 })
                
                if hasValidTweet {
                    currentPage = page
                    print("[TweetListView] Updated currentPage to \(currentPage) for user: \(hproseInstance.appUser.mid)")
                } else if tweetsFromServer.count < pageSize {
                    hasMoreTweets = false
                    print("[TweetListView] No more tweets available for user: \(hproseInstance.appUser.mid)")
                } else {
                    // All tweets are nil, auto-increment and try again
                    print("[TweetListView] All tweets nil for page \(page), auto-incrementing page")
                    isLoadingMore = false
                    loadMoreTweets(page: page + 1)
                    return
                }
            }
            
        } catch {
            print("[TweetListView] Server load failed: \(error)")
            print("[TweetListView] Continuing with cached data only")
            
            // Show user-friendly error message for network issues
            if !networkMonitor.hasAnyConnection {
                await MainActor.run {
                    errorMessage = "No internet connection. Showing cached content."
                }
            } else {
                await MainActor.run {
                    errorMessage = "Unable to load fresh content. Showing cached data."
                }
            }
        }
        
        await MainActor.run { isLoadingMore = false }
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
    let header: (() -> AnyView)?
    let rowView: (Tweet) -> RowView
    @Binding var hasMoreTweets: Bool
    let isLoadingMore: Bool
    let isLoading: Bool
    let initialLoadComplete: Bool
    let loadMoreTweets: () -> Void
    
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @State private var showOfflineIndicator = false
    
    var body: some View {
        LazyVStack(spacing: 0) {
            Color.clear.frame(height: 0)
            
            // Header content
            if let header = header {
                header()
            }
            
            // Offline indicator
            if showOfflineIndicator && !networkMonitor.hasAnyConnection {
                HStack {
                    Image(systemName: "wifi.slash")
                        .foregroundColor(.orange)
                    Text("Offline - Showing cached content")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
            }
            
            // Show loading state
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading tweets...")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else if initialLoadComplete && tweets.compactMap({ $0 }).isEmpty {
                // Show empty state when loading is complete but no tweets
                VStack(spacing: 16) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No tweet yet")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                // Show tweets
                ForEach(Array(tweets.compactMap { $0 }.enumerated()), id: \.element.mid) { index, tweet in
                    VStack(spacing: 0) {
                        if index > 0 {
                            Rectangle()
                                .frame(height: 0.5)
                                .foregroundColor(Color(.systemGray))
                        }
                        rowView(tweet)
                    }
                }
                
                // Always present view to detect bottom scrolling
                Color.clear
                    .frame(height: 40)
                    .onAppear {
                        print("[TweetListContentView] Bottom view appeared - initialLoadComplete: \(initialLoadComplete), isLoadingMore: \(isLoadingMore)")
                        if initialLoadComplete && !isLoadingMore {
                            print("[TweetListContentView] Setting hasMoreTweets to true")
                            hasMoreTweets = true
                            print("[TweetListContentView] Scheduling loadMoreTweets")
                            // Use shorter delay like ProfileView
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                if initialLoadComplete && !isLoadingMore {
                                    print("[TweetListContentView] Calling loadMoreTweets")
                                    loadMoreTweets()
                                }
                            }
                        }
                    }
                
                // Loading indicator for more tweets
                if hasMoreTweets {
                    ProgressView()
                        .frame(height: 40)
                }
            }
        }
        .onAppear {
            // Check network status when view appears
            showOfflineIndicator = !networkMonitor.hasAnyConnection
        }
        .onChange(of: networkMonitor.isConnected) { isConnected in
            // Update offline indicator when network status changes
            showOfflineIndicator = !isConnected
        }
    }
}

