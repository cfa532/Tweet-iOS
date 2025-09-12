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
    let tweetFetcher: @Sendable (UInt, UInt, Bool, Bool) async throws -> [Tweet?]
    let showTitle: Bool
    let rowView: (Tweet) -> RowView
    let header: (() -> AnyView)?
    let notifications: [TweetListNotification]
    let onScroll: ((CGFloat) -> Void)?
    let shouldCacheServerTweets: Bool
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
    @StateObject private var videoLoadingManager = VideoLoadingManager.shared

    // MARK: - Initialization
    init(
        title: String,
        tweets: Binding<[Tweet]>,
        tweetFetcher: @escaping @Sendable (UInt, UInt, Bool, Bool) async throws -> [Tweet?],
        showTitle: Bool = true,
        shouldCacheServerTweets: Bool = false,
        notifications: [TweetListNotification]? = nil,
        onScroll: ((CGFloat) -> Void)? = nil,
        header: (() -> AnyView)? = nil,
        rowView: @escaping (Tweet) -> RowView
    ) {
        self.title = title
        self._tweets = tweets
        self.tweetFetcher = tweetFetcher
        self.showTitle = showTitle
        self.shouldCacheServerTweets = shouldCacheServerTweets
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
                .modifier(ScrollDetectionModifier(onScroll: onScroll))
                .onAppear {
                    onScroll?(0)
                }
                
                if showToast {
                    VStack {
                        Spacer()
                        ToastView(message: toastMessage, type: toastType)
                            .padding(.bottom, 40)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: showToast)
                }
            }
            .refreshable {
                await refreshTweets()
            }
            .task {
                // Only load if tweets are empty and we haven't completed initial load
                if tweets.isEmpty && !initialLoadComplete {
                    await performInitialLoad()
                } else if !tweets.isEmpty {
                    // If we already have tweets, mark as loaded
                    initialLoadComplete = true
                    isLoading = false
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
                        // Special case: blockUser may send blockedUserId to remove all tweets from that user
                        if let blockedUserId = notif.userInfo?["blockedUserId"] as? String {
                            let originalCount = tweets.count
                            tweets.removeAll { $0.authorId == blockedUserId }
                            let removedCount = originalCount - tweets.count
                            print("[TweetListView] Removed \(removedCount) tweets from blocked user: \(blockedUserId)")
                        }
                    }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Methods
    func performInitialLoad() async {
        isLoading = true
        initialLoadComplete = false
        currentPage = 0
        let page: UInt = 0

        do {
            // Step 1: Load from cache first for instant UX (always try cache)
            let tweetsFromCache = try await tweetFetcher(page, pageSize, true, false)
            let validCachedTweets = tweetsFromCache.compactMap { $0 }
            
            await MainActor.run {
                tweets.mergeTweets(validCachedTweets)
                
                // Update VideoLoadingManager with new tweet list
                let tweetIds = tweets.map { $0.mid }
                videoLoadingManager.updateTweetList(tweetIds)
                
                // Mark as loaded immediately after cache load for instant UX
                isLoading = false
                initialLoadComplete = true
            }
            
            // Step 2: Load from server in background to get the most up-to-date data
            // This happens asynchronously and won't block the UI
            Task.detached(priority: .background) {
                await self.loadFromServer(page: page, pageSize: self.pageSize) { _ in
                    // Server load completion handled separately
                }
            }
            
            // Trigger preloading after initial load completes
            if hasMoreTweets {
                await MainActor.run {
                    loadNextTwoPages(startingFrom: 1)
                }
            }
            
        } catch {
            print("[TweetListView] Error during initial load: \(error)")
            errorMessage = error.localizedDescription
            await MainActor.run {
                isLoading = false
                initialLoadComplete = true
            }
        }
    }

    func refreshTweets() async {
        guard !isLoading else { return }
        
        isLoading = true
        initialLoadComplete = false
        currentPage = 0
        
        do {
            // Always load fresh data from server for refresh
            let freshTweets = try await tweetFetcher(0, pageSize, false, shouldCacheServerTweets)
            let validTweets = freshTweets.compactMap { $0 }
            let hasValidTweet = !validTweets.isEmpty
            
            await MainActor.run {
                // Update tweets with server data while preserving cached tweets for failed IDs
                if hasValidTweet {
                    // Use mergeTweets to preserve cached tweets that weren't in server response
                    tweets.mergeTweets(validTweets)
                    currentPage = 0
                    hasMoreTweets = freshTweets.count >= pageSize
                    
                    // Update VideoLoadingManager with new tweet list
                    let tweetIds = tweets.map { $0.mid }
                    videoLoadingManager.updateTweetList(tweetIds)
                } else {
                    // Only clear if server returned no valid tweets AND we have no cached tweets
                    if tweets.isEmpty {
                        tweets = []
                        hasMoreTweets = false
                        
                        // Update VideoLoadingManager with empty tweet list
                        videoLoadingManager.updateTweetList([])
                    } else {
                        // Keep cached tweets if server returned no valid tweets
                        hasMoreTweets = false
                    }
                }
                
                isLoading = false
                initialLoadComplete = true
            }
            
        } catch {
            print("[TweetListView] Refresh failed: \(error)")
            await MainActor.run {
                isLoading = false
                initialLoadComplete = true
                // Keep existing tweets on refresh failure
            }
        }
    }

    func loadMoreTweets(page: UInt? = nil) {
        guard hasMoreTweets, !isLoadingMore, initialLoadComplete else { 
            return 
        }
        
        let nextPage = page ?? (currentPage + 1)
        
        // Load next two pages in advance, separated by 3 seconds
        loadNextTwoPages(startingFrom: nextPage)
    }
    
    // MARK: - Batch Loading for Prefetching
    private func loadNextTwoPages(startingFrom startPage: UInt) {
        // Load first page immediately
        loadSinglePage(page: startPage) { success in
            if success && self.hasMoreTweets {
                // Load second page after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.hasMoreTweets && !self.isLoadingMore {
                        self.loadSinglePage(page: startPage + 1) { _ in
                            // Second page load complete
                        }
                    }
                }
            }
        }
    }
    
    private func loadSinglePage(page: UInt, completion: @escaping (Bool) -> Void) {
        let pageSize = self.pageSize
        
        Task {
            isLoadingMore = true
            
            do {
                // Step 1: Load from cache first for instant UX
                let tweetsFromCache = try await tweetFetcher(page, pageSize, true, false)
                await MainActor.run {
                    tweets.mergeTweets(tweetsFromCache.compactMap { $0 })
                    
                    // Update VideoLoadingManager with new tweet list
                    let tweetIds = tweets.map { $0.mid }
                    videoLoadingManager.updateTweetList(tweetIds)
                    
                    // Clear loading state immediately after showing cached content
                    isLoadingMore = false
                }
                
                // Step 2: Load from server to update with fresh data (non-blocking, no retry)
                Task {
                    await loadFromServer(page: page, pageSize: pageSize, completion: completion)
                }
            } catch {
                print("[TweetListView] Error loading page \(page): \(error)")
                await MainActor.run { 
                    hasMoreTweets = false; 
                    isLoadingMore = false 
                }
                completion(false)
            }
        }
    }
    
    // MARK: - Server Loading (No Retry)
    private func loadFromServer(page: UInt, pageSize: UInt, completion: @escaping (Bool) -> Void) async {
        do {
            let tweetsFromServer = try await tweetFetcher(page, pageSize, false, shouldCacheServerTweets)
            let validServerTweets = tweetsFromServer.compactMap { $0 }
            let hasValidTweet = !validServerTweets.isEmpty
            
            await MainActor.run {
                // Update tweets with server data (existing mergeTweets already preserves cached tweets for failed IDs)
                if hasValidTweet {
                    if page == 0 {
                        // For first page, replace all tweets with server data
                        tweets = validServerTweets
                    } else {
                        // For subsequent pages, merge server data
                        tweets.mergeTweets(validServerTweets)
                    }
                    
                    // Update VideoLoadingManager with new tweet list
                    let tweetIds = tweets.map { $0.mid }
                    videoLoadingManager.updateTweetList(tweetIds)
                    
                    currentPage = page
                } else if tweetsFromServer.count < pageSize {
                    hasMoreTweets = false
                } else {
                    // All tweets are nil but we got a full page, continue to next page
                    currentPage = page
                    // Don't call loadMoreTweets recursively here, let the normal flow continue
                }
            }
            
        } catch {
            print("[TweetListView] Server load failed: \(error)")
            
            await MainActor.run {
                errorMessage = "Unable to load fresh content. Showing cached data."
                // Don't modify tweets array - keep cached data intact
            }
        }
        completion(true)
    }

    // MARK: - Optimistic UI Methods
    func insertTweet(_ tweet: Tweet) {
        tweets.insert(tweet, at: 0)
    }
    
    func removeTweet(_ tweet: Tweet) async -> Void {
    }
}

// MARK: - Scroll Offset Preference Key
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Scroll Detection Modifier
private struct ScrollDetectionModifier: ViewModifier {
    let onScroll: ((CGFloat) -> Void)?
    
    func body(content: Content) -> some View {
        if let onScroll = onScroll {
            content.simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        let offset = value.translation.height
                        onScroll(offset)
                    }
                    .onEnded { _ in
                        // When gesture ends, maintain current state for a brief period
                        // to allow scroll inertia to settle naturally
                        // Don't immediately change navigation state
                        // Let the scroll view settle naturally
                    }
            )
        } else {
            content
        }
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
    @StateObject private var videoLoadingManager = VideoLoadingManager.shared
    
    var body: some View {
        LazyVStack(spacing: 0) {
            Color.clear.frame(height: 0)
            
            // Header content
            if let header = header {
                header()
            }
            
            // Show loading state only if we don't have any tweets yet
            if isLoading && tweets.compactMap({ $0 }).isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text(NSLocalizedString("Loading tweets...", comment: "Loading tweets message"))
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
                    Text(NSLocalizedString("No tweet yet", comment: "No tweets available message"))
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
                                .padding(.horizontal, 2)
                                .frame(height: 0.5)
                                .foregroundColor(Color(.systemGray).opacity(0.4))
                        }
                        rowView(tweet)
                            // Add stable identity to prevent unnecessary re-composition
                            .id("tweet_\(tweet.mid)")
                            .onAppear {
                                // Update VideoLoadingManager when tweet becomes visible
                                videoLoadingManager.updateVisibleTweetIndex(index)
                                print("DEBUG: [TweetListContentView] Tweet \(tweet.mid) at index \(index) became visible")
                            }
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
                            print("[TweetListContentView] Scheduling batch load of next two pages")
                            // Use shorter delay like ProfileView
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                if initialLoadComplete && !isLoadingMore {
                                    print("[TweetListContentView] Calling loadMoreTweets (batch mode)")
                                    loadMoreTweets()
                                }
                            }
                        }
                    }
                
                // Loading indicator for more tweets
                if hasMoreTweets {
                    ProgressView()
                        .frame(height: 40)
                        .padding(.top, -40) // Move spinner up by 40 dp
                }
            }
        }
    }
}

