@preconcurrency import Foundation
import SwiftUI

struct TweetListNotification {
    let name: Notification.Name
    let key: String
    let shouldAccept: (Tweet) -> Bool
    let action: (Tweet) -> Void
}

// Preference key to track content height
private struct TweetContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private final class ObserverHolder: @unchecked Sendable {
    var observer: NSObjectProtocol?
    init(_ observer: NSObjectProtocol?) { self.observer = observer }
}

@available(iOS 16.0, *)
struct TweetListView: View {
    // MARK: - Properties
    let title: String
    let tweetFetcher: @Sendable (UInt, UInt, Bool) async throws -> [Tweet?]
    let showTitle: Bool
    let header: (() -> AnyView)?
    let notifications: [TweetListNotification]
    let onScroll: ((CGFloat, CGFloat) -> Void)?  // (offset, delta)
    let leadingPadding: CGFloat  // Leading padding for cells
    let trailingPadding: CGFloat  // Trailing padding for cells
    let pinnedTweets: [Tweet]  // Pinned tweets for video coordination
    let feedIdentifier: String  // Unique identifier for persistent scroll position
    let preserveOrder: Bool  // If true, preserve server order instead of sorting by timestamp (for bookmarks/favorites)
    let allowDeleteAll: Bool  // If true, appUser can delete any tweet (main feed); otherwise only own tweets
    private let pageSize: UInt = 10  // Manual load-more only

    // Navigation callbacks (passed through to UIKit cells)
    let onAvatarTap: ((User) -> Void)?
    let onTweetTap: ((Tweet) -> Void)?
    let onShowLogin: (() -> Void)?
    let onShowToast: ((String, Bool) -> Void)?

    @EnvironmentObject private var hproseInstance: HproseInstance
    @Binding var tweets: [Tweet]
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var hasMoreTweets: Bool = true
    @State private var currentPage: UInt = 0
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info
    @State private var initialLoadComplete = false
    @StateObject private var videoLoadingManager = VideoLoadingManager.shared
    @State private var loadingStartTime: Date? = nil
    @State private var lastScrollOffset: CGFloat = 0
    @State private var didPrewarmSingletonFirstItem: Bool = false
    @State private var lastVisibleTweetIdBeforeLoad: String? = nil
    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var contentHeight: CGFloat = 0
    @State private var screenHeight: CGFloat = 0
    @State private var needsMoreContent: Bool = true
    @State private var startupTime: Date = Date()
    @State private var foregroundObserver: NSObjectProtocol?
    @State private var notificationObservers: [NSObjectProtocol] = []
    @State private var videoManagerUpdateTask: Task<Void, Never>? = nil
    @State private var hasAppearedOnce: Bool = false  // Track if view has appeared before (to detect navigation return)
    @State private var lastCleanupTime: Date = Date()
    private let cleanupInterval: TimeInterval = 10.0  // Cleanup every 10 seconds max

    /// Per-feed video coordinator — main feed uses .shared, other feeds get independent instances
    /// to prevent cross-feed interference (separate allVideos, visibleTweetIds, tableView, etc.)
    private let videoCoordinator: VideoPlaybackCoordinator
    
    // Memory management - limit total tweets in memory
    private let maxTweetsInMemory: Int = 200  // Keep max 200 tweets to prevent unbounded growth
    private let tweetsToKeepOnTrim: Int = 150  // When trimming, keep 150 most recent
    
    // Minimum duration to show the loading spinner (in seconds)
    private let minimumLoadingDuration: TimeInterval = 0.5
    
    // MARK: - Helper Methods
    
    /// Update VideoLoadingManager with current tweet list
    /// Centralized method to avoid code duplication
    /// Debounced to prevent excessive updates during rapid scrolling
    private func updateVideoLoadingManager(delay: TimeInterval = 0) {
        // Cancel any pending update task
        videoManagerUpdateTask?.cancel()
        
        // Create new debounced task
        videoManagerUpdateTask = Task.detached(priority: .background) {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            
            // Check if task was cancelled
            guard !Task.isCancelled else { return }
            
            let tweetIds = await MainActor.run { self.tweets.map { $0.mid } }
            await self.videoLoadingManager.updateTweetList(tweetIds)

            // Throttle cleanup to prevent excessive calls
            let shouldCleanup = await MainActor.run {
                let timeSinceLastCleanup = Date().timeIntervalSince(self.lastCleanupTime)
                if timeSinceLastCleanup > self.cleanupInterval {
                    self.lastCleanupTime = Date()
                    return true
                }
                return false
            }
            
            if shouldCleanup {
                // Trim tweets array if it's too large
                await self.trimTweetsIfNeeded()
                
                // Also cleanup old tweet instances to prevent memory growth
                let activeTweetIds = Set(tweetIds)
                Tweet.cleanupOldInstances(activeTweetIds: activeTweetIds)
            }
        }
    }
    
    /// Trim oldest tweets from memory if array exceeds maximum size
    /// Keeps most recent tweets to prevent unbounded memory growth
    private func trimTweetsIfNeeded() async {
        await MainActor.run {
            guard tweets.count > maxTweetsInMemory else { return }
            
            print("⚠️ [MEMORY] Trimming tweets array from \(tweets.count) to \(tweetsToKeepOnTrim)")
            
            // Keep only the most recent tweets (sorted by timestamp descending)
            // Already sorted in descending order, so just take first N
            let tweetsToRemove = tweets.dropFirst(tweetsToKeepOnTrim)
            
            // Clear Tweet singleton instances for removed tweets
            for tweet in tweetsToRemove {
                Tweet.clearInstance(mid: tweet.mid)
            }
            
            // Trim array
            tweets = Array(tweets.prefix(tweetsToKeepOnTrim))
            
            print("✅ [MEMORY] Trimmed to \(tweets.count) tweets")
        }
    }
    
    // MARK: - Initialization
    let onRefreshExtra: (() async -> Void)?  // Optional extra refresh callback
    
    init(
        title: String,
        tweets: Binding<[Tweet]>,
        tweetFetcher: @escaping @Sendable (UInt, UInt, Bool) async throws -> [Tweet?],
        showTitle: Bool = true,
        notifications: [TweetListNotification]? = nil,
        onScroll: ((CGFloat, CGFloat) -> Void)? = nil,
        leadingPadding: CGFloat = 8,
        trailingPadding: CGFloat = 8,
        pinnedTweets: [Tweet] = [],
        feedIdentifier: String = "mainFeed",
        preserveOrder: Bool = false,
        allowDeleteAll: Bool = false,
        header: (() -> AnyView)? = nil,
        onRefreshExtra: (() async -> Void)? = nil,
        onAvatarTap: ((User) -> Void)? = nil,
        onTweetTap: ((Tweet) -> Void)? = nil,
        onShowLogin: (() -> Void)? = nil,
        onShowToast: ((String, Bool) -> Void)? = nil
    ) {
        self.title = title
        self._tweets = tweets
        self.tweetFetcher = tweetFetcher
        self.showTitle = showTitle
        self.onScroll = onScroll
        self.leadingPadding = leadingPadding
        self.trailingPadding = trailingPadding
        self.pinnedTweets = pinnedTweets
        self.feedIdentifier = feedIdentifier
        self.preserveOrder = preserveOrder
        self.allowDeleteAll = allowDeleteAll
        self.header = header
        self.onRefreshExtra = onRefreshExtra
        self.onAvatarTap = onAvatarTap
        self.onTweetTap = onTweetTap
        self.onShowLogin = onShowLogin
        self.onShowToast = onShowToast
        // Main feed uses shared coordinator; other feeds get independent instances
        // to prevent cross-feed interference (separate allVideos, visibleTweetIds, tableView, etc.)
        self.videoCoordinator = (feedIdentifier == "mainFeed")
            ? VideoPlaybackCoordinator.shared
            : VideoPlaybackCoordinator()
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
    }

    // MARK: - Body
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // UIKit TABLE VIEW — pure UIKit cells, no UIHostingController per cell
                TweetTableView(
                    tweets: $tweets,
                    header: header,
                    hproseInstance: hproseInstance,
                    hasMoreTweets: $hasMoreTweets,
                    isLoadingMore: isLoadingMore,
                    loadMoreTweets: { forceLoad in loadMoreTweets(forceLoad: forceLoad) },
                    onRefresh: {
                        await refreshTweets()
                        await onRefreshExtra?()
                    },
                    onScroll: onScroll,
                    leadingPadding: leadingPadding,
                    trailingPadding: trailingPadding,
                    pinnedTweets: pinnedTweets,
                    feedIdentifier: feedIdentifier,
                    videoCoordinator: videoCoordinator,
                    onAvatarTap: onAvatarTap,
                    onTweetTap: onTweetTap,
                    onShowLogin: onShowLogin,
                    onShowToast: onShowToast,
                    allowDeleteAll: allowDeleteAll
                )
                .onAppear {
                    screenHeight = geometry.size.height
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
            }  // Close ZStack
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
        }  // Close GeometryReader
        .onReceive(NotificationCenter.default.publisher(for: .userDidLogin)) { _ in
            Task {
                await refreshTweets()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Set up foreground observer to fetch new tweets when app returns
            setupForegroundObserver()
            // Set up notification observers
            setupNotificationObservers()

            // Only notify feedViewDidAppear when RETURNING from navigation, not on initial load
            // This prevents unnecessary video stop/restart cycles that cause flickering
            if hasAppearedOnce {
                // Returning from navigation - notify to restart video playback
                // Delay slightly to ensure layout is complete
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: .feedViewDidAppear, object: nil,
                                                    userInfo: ["feedIdentifier": feedIdentifier])
                }
            } else {
                // First appearance - just mark as appeared, video will start via normal flow
                hasAppearedOnce = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CacheCleared"))) { _ in
            // Refresh tweets when cache is cleared
            print("DEBUG: [TweetListView] Received CacheCleared notification, refreshing tweets")
            Task {
                await refreshTweets()
            }
        }
        .onDisappear {
            // Clean up foreground observer
            if let observer = foregroundObserver {
                NotificationCenter.default.removeObserver(observer)
                foregroundObserver = nil
            }
            // NOTE: Do NOT clean up notification observers here.
            // onDisappear fires when navigating to detail view, but we still need
            // to handle .tweetDeleted (and other notifications) while the detail view
            // is shown. setupNotificationObservers() already cleans up before re-creating
            // when onAppear fires again, so there's no risk of duplicate observers.
        }
    }
    
    // MARK: - Helper Methods
    
    // MARK: - Methods
    
    /// Setup notification observers for tweet updates
    private func setupNotificationObservers() {
        // Remove existing observers if any
        cleanupNotificationObservers()
        
        // Get unique notification names
        let uniqueNames = Set(notifications.map { $0.name })
        
        // Capture binding and notification handlers by value to avoid capturing entire self
        // This is safe because:
        // 1. Binding is a lightweight value type (just a reference wrapper)
        // 2. We properly clean up observers in onDisappear
        // 3. No retain cycle since structs don't have reference semantics
        let tweetsBinding = _tweets
        let notificationHandlers = notifications
        
        // Set up one observer per unique notification name
        for name in uniqueNames {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { notif in
                // Find matching notification handlers for this notification name
                for notification in notificationHandlers where notification.name == name {
                    if let tweet = notif.userInfo?[notification.key] as? Tweet, notification.shouldAccept(tweet) {
                        notification.action(tweet)
                    }
                    // Special case: tweetId notifications send String instead of Tweet
                    if notification.key == "tweetId", let tweetId = notif.userInfo?[notification.key] as? String {
                        // Find tweet once for efficiency (avoid multiple O(n) searches)
                        let tweetIndex = tweetsBinding.wrappedValue.firstIndex(where: { $0.mid == tweetId })
                        
                        if notification.name == .tweetDeleted {
                            // For tweet deletion, handle directly in TweetListView
                            if let index = tweetIndex {
                                tweetsBinding.wrappedValue.remove(at: index)
                            }
                            TweetCacheManager.shared.deleteTweet(mid: tweetId)
                        } else if notification.name == .tweetPrivacyChanged {
                            // For privacy changes, handle removal directly here
                            if let index = tweetIndex {
                                let tweetToRemove = tweetsBinding.wrappedValue[index]
                                tweetsBinding.wrappedValue.remove(at: index)
                                // Call custom handler with the tweet that was removed
                                notification.action(tweetToRemove)
                            }
                        } else {
                            // For other notifications, call the custom handler
                            if let index = tweetIndex {
                                notification.action(tweetsBinding.wrappedValue[index])
                            }
                        }
                    }
                }
                // Special case: blockUser may send blockedUserId to remove all tweets from that user
                if let blockedUserId = notif.userInfo?["blockedUserId"] as? String {
                    tweetsBinding.wrappedValue.removeAll { $0.authorId == blockedUserId }
                }
            }
            
            notificationObservers.append(observer)
        }

        // Always observe .tweetRestored to re-insert optimistically deleted tweets on failure
        let restoredObserver = NotificationCenter.default.addObserver(
            forName: .tweetRestored,
            object: nil,
            queue: .main
        ) { notif in
            guard let tweetId = notif.userInfo?["tweetId"] as? String else { return }
            // Only restore if not already in the list
            guard !tweetsBinding.wrappedValue.contains(where: { $0.mid == tweetId }) else { return }
            if let tweet = Tweet.getInstance(for: tweetId) {
                tweetsBinding.wrappedValue.mergeTweets([tweet])
            }
        }
        notificationObservers.append(restoredObserver)
    }

    /// Clean up notification observers
    private func cleanupNotificationObservers() {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }
    
    /// Setup observer to fetch new tweets when app comes to foreground
    private func setupForegroundObserver() {
        // Remove existing observer if any
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        // Listen for app becoming active (returning from background or screen lock)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Only fetch if initial load has completed (avoid interfering with app startup)
            guard self.initialLoadComplete else {
                print("📱 [FOREGROUND] Skipping fetch - initial load not complete")
                return
            }
            
            // Fetch new tweets when app comes to foreground
            print("📱 [FOREGROUND] App became active - fetching new tweets...")
            Task {
                await self.fetchNewTweetsOnForeground()
            }
        }
        
        print("📱 [FOREGROUND] Observer set up - will fetch tweets on app foreground")
    }
    
    /// Fetch new tweets when app comes to foreground
    /// This refreshes the first page to show any new tweets that arrived while app was in background
    private func fetchNewTweetsOnForeground() async {
        // Don't fetch if already loading or refreshing
        guard !isLoading && !isLoadingMore else {
            print("📱 [FOREGROUND] Skipping - already loading")
            return
        }
        
        print("📱 [FOREGROUND] Fetching fresh tweets from server...")
        
        do {
            // Fetch fresh tweets from server (page 0, no cache)
            let freshTweets = try await tweetFetcher(0, pageSize, false)
            let validTweets = freshTweets.compactMap { $0 }
            
            await MainActor.run {
                if !validTweets.isEmpty {
                    // For preserveOrder lists (bookmarks/favorites), append in server order
                    // For other lists, merge with timestamp sorting
                    if preserveOrder {
                        tweets.appendTweetsPreservingOrder(validTweets)
                    } else {
                        tweets.mergeTweets(validTweets)
                    }
                    currentPage = 0
                    hasMoreTweets = freshTweets.count >= pageSize

                    // Update video manager with debouncing
                    updateVideoLoadingManager(delay: 0.2)

                    print("📱 [FOREGROUND] ✅ Merged \(validTweets.count) fresh tweets")
                } else {
                    print("📱 [FOREGROUND] No new tweets found")
                }
            }
        } catch {
            print("📱 [FOREGROUND] ❌ Error fetching tweets: \(error)")
        }
    }
    
    func performInitialLoad() async {
        currentPage = 0
        let page: UInt = 0

        do {
            // Step 1: Load from cache first for instant UX (always try cache)
            let tweetsFromCache = try await tweetFetcher(page, pageSize, true)
            let validCachedTweets = tweetsFromCache.compactMap { $0 }
            
            let hasCachedContent = !validCachedTweets.isEmpty
            
            await MainActor.run {
                if hasCachedContent {
                    // If we have cached content, show it immediately without loading spinner
                    // Use direct assignment (not merge) to avoid re-sorting cached content
                    tweets = validCachedTweets
                    
                    // Set hasMoreTweets based on cache - if we got a full page, there might be more
                    hasMoreTweets = tweetsFromCache.count >= pageSize

                    // Update VideoLoadingManager with delay for startup
                    updateVideoLoadingManager(delay: 1.0)

                    // Don't mark as loaded yet - wait for server fetch to complete
                    // This prevents "No tweet yet" from showing prematurely if cached tweets
                    // are filtered out (e.g., pinned tweets) before server fetch completes
                    isLoading = false
                    initialLoadComplete = false  // Keep false until server fetch completes
                } else {
                    // No cached content - show loading spinner and wait for server
                    isLoading = true
                    initialLoadComplete = false
                }
            }

            // Yield so SwiftUI/UIKit can render cached tweets before we start the server fetch.
            // Without this, the server Task can run immediately and the list may not show cache first.
            if hasCachedContent {
                await Task.yield()
            }

            // Prewarm singleton players based on the first available cached video (best-effort).
            // Defer during initial startup to prevent hangs
            Task.detached(priority: .background) {
                // Wait for startup phase to end before prewarming videos
                if await MainActor.run(body: { videoLoadingManager.isInStartupPhase }) {
                    await withCheckedContinuation { continuation in
                        let holder = ObserverHolder(nil)
                        holder.observer = NotificationCenter.default.addObserver(
                            forName: .startupPhaseEnded,
                            object: nil,
                            queue: nil
                        ) { _ in
                            if let observer = holder.observer {
                                NotificationCenter.default.removeObserver(observer)
                            }
                            continuation.resume()
                        }
                    }
                }
                // Defer prewarming to avoid overwhelming system when startup phase ends
                Task.detached(priority: .background) {
                    await MainActor.run {
                        self.prewarmSingletonPlayersFromFirstVideoIfNeeded()
                    }
                }
            }

            // End startup phase after 3 seconds
            Task.detached(priority: .background) {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                await videoLoadingManager.endStartupPhase()
            }
        } catch {
            await MainActor.run {
                isLoading = false
                initialLoadComplete = true
            }
        }
        
        // CRITICAL: Let UI render cached tweets BEFORE fetching from server
        // If we await server fetch in same function, SwiftUI batches updates and only renders once
        // By launching server fetch in separate Task, cached tweets render immediately
        Task {
            // Step 2: Load from server to get the most up-to-date data (in background)
            await loadFromServer(page: page, pageSize: pageSize) { _ in }
            
            // Step 3: Auto-load additional pages if there are more tweets on server
            // This ensures all new tweets are loaded when app opens, not just first page
            await autoLoadRemainingNewTweets()
        }
    }
    
    /// Automatically load remaining new tweets after initial load
    /// Continues loading pages until no more tweets or reasonable limit reached
    ///
    /// Uses the same pagination algorithm as updateTweetsWithServerData:
    /// - responseSize >= pageSize: keep loading (more entries might exist)
    /// - responseSize < pageSize: stop (server depleted)
    private func autoLoadRemainingNewTweets() async {
        let maxAutoLoadPages: UInt = 2  // Load up to 2 additional pages (20 tweets total with pageSize=10)
        var pagesLoaded: UInt = 0

        // Check if there are more tweets to load
        let shouldContinue = await MainActor.run { hasMoreTweets }
        guard shouldContinue else { return }


        while pagesLoaded < maxAutoLoadPages {
            let currentHasMore = await MainActor.run { hasMoreTweets }
            guard currentHasMore else {
                print("📥 [AUTO-LOAD] No more tweets to load (completed)")
                break
            }

            let nextPage = await MainActor.run { currentPage + 1 }

            do {
                let tweets = try await tweetFetcher(nextPage, pageSize, false)
                let validTweets = tweets.compactMap { $0 }

                await MainActor.run {
                    if !validTweets.isEmpty {
                        // For preserveOrder lists (bookmarks/favorites), append in server order
                        // For other lists, merge with timestamp sorting
                        if self.preserveOrder {
                            self.tweets.appendTweetsPreservingOrder(validTweets)
                        } else {
                            self.tweets.mergeTweets(validTweets)
                        }
                        self.currentPage = nextPage

                        // Check response size to determine if more items exist
                        self.hasMoreTweets = tweets.count >= self.pageSize

                        // Update video manager with debouncing (will batch multiple updates)
                        self.updateVideoLoadingManager(delay: 0.2)
                    } else {
                        // No valid tweets - check response size
                        self.currentPage = nextPage
                        self.hasMoreTweets = tweets.count >= self.pageSize
                        if !self.hasMoreTweets {
                            print("📥 [AUTO-LOAD] No valid tweets in page \(nextPage) and partial page - stopping")
                        } else {
                            print("📥 [AUTO-LOAD] No valid tweets in page \(nextPage) but got full page - continuing")
                        }
                    }
                }
                
                // Check if we got a partial page (indicates end of new tweets)
                if tweets.count < pageSize {
                    print("📥 [AUTO-LOAD] Received partial page (\(tweets.count) tweets) - completed")
                    break
                }
                
                pagesLoaded += 1
                
                // Small delay between requests to avoid overwhelming server
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms (increased from 100ms)
                
            } catch {
                print("❌ [AUTO-LOAD] Error loading page \(nextPage): \(error)")
                print("❌ [AUTO-LOAD] Error details: \(error.localizedDescription)")
                // Don't set hasMoreTweets = false on error!
                // This would prevent manual retry and show "no more tweets" incorrectly
                // The error could be temporary (network, timeout, etc.)
                // Just stop auto-loading and let the user retry manually via scroll
                break
            }
        }
        
        if pagesLoaded >= maxAutoLoadPages {
            print("📥 [AUTO-LOAD] Reached max auto-load limit (\(maxAutoLoadPages) pages)")
        }
    }

    /// Refresh tweets from server (pull-to-refresh)
    ///
    /// Uses the same pagination algorithm as updateTweetsWithServerData:
    /// - responseSize >= pageSize: keep loading (more entries might exist)
    /// - responseSize < pageSize: stop (server depleted)
    func refreshTweets() async {
        guard !isLoading else {
            return
        }

        isLoading = true
        initialLoadComplete = false
        currentPage = 0

        // DON'T clear existing tweets - keep them while refreshing for better UX
        // await MainActor.run {
        //     tweets.removeAll()
        // }

        do {
            // Always load fresh data from server for refresh
            let freshTweets = try await tweetFetcher(0, pageSize, false)
            let validTweets = freshTweets.compactMap { $0 }
            let hasValidTweet = !validTweets.isEmpty

            if validTweets.isEmpty {
            }

            await MainActor.run {
                // Update tweets with server data - MERGE on refresh to keep existing content
                if hasValidTweet {
                    // For preserveOrder lists (bookmarks/favorites), replace entirely on refresh to get fresh order
                    // For other lists, merge with timestamp sorting
                    if preserveOrder {
                        tweets = validTweets
                    } else {
                        tweets.mergeTweets(validTweets)
                    }
                    currentPage = 0

                    // Check response size to determine if more items exist
                    hasMoreTweets = freshTweets.count >= pageSize

                    // Update VideoLoadingManager with debouncing
                    updateVideoLoadingManager(delay: 0.2)
                } else {
                    // No valid tweets - check response size
                    hasMoreTweets = freshTweets.count >= pageSize

                    // Only clear if server returned no valid tweets AND we have no cached tweets
                    if tweets.isEmpty {
                        tweets = []
                        // Update VideoLoadingManager with empty list
                        updateVideoLoadingManager()
                    }
                    // Keep cached tweets if server returned no valid tweets
                }

                isLoading = false
                initialLoadComplete = true
            }
            
        } catch {
            await MainActor.run {
                isLoading = false
                initialLoadComplete = true
                // Keep existing tweets on refresh failure
            }
        }
    }

    func loadMoreTweets(page: UInt? = nil, forceLoad: Bool = false) {
        // Prevent loading if we've reached memory limit
        if tweets.count >= maxTweetsInMemory && !forceLoad {
            print("⚠️ [MEMORY] Reached maximum tweets limit (\(maxTweetsInMemory)), stopping pagination")
            hasMoreTweets = false
            return
        }
        
        // Allow bypassing hasMoreTweets check for manual pull-to-load
        guard (hasMoreTweets || forceLoad), !isLoadingMore, initialLoadComplete else {
            return 
        }
        
        // Set loading flag IMMEDIATELY to prevent duplicate calls
        isLoadingMore = true
        
        let nextPage = page ?? (currentPage + 1)
        
        // Load single page only (no batch prefetch)
        loadSinglePage(page: nextPage) { _ in }
    }
    
    // MARK: - Batch Loading (Removed - now using single page loads only)
    
    private func loadSinglePage(page: UInt, completion: @escaping (Bool) -> Void) {
        let pageSize = self.pageSize

        Task {
            // Record loading start time
            let startTime = Date()

            await MainActor.run {
                // Capture the last visible tweet before loading
                if let lastTweet = tweets.last {
                    lastVisibleTweetIdBeforeLoad = lastTweet.mid
                }

                isLoadingMore = true
                loadingStartTime = startTime
            }

            // Step 1: Try to load from cache first for instant UX (best-effort, don't fail on cache errors)
            var tweetsFromCache: [Tweet?] = []
            do {
                tweetsFromCache = try await tweetFetcher(page, pageSize, true)

                // If we got cached tweets, show them immediately
                if !tweetsFromCache.isEmpty {
                    await MainActor.run {
                        // For preserveOrder lists (bookmarks/favorites), append in server order
                        // For other lists, merge with timestamp sorting
                        if preserveOrder {
                            tweets.appendTweetsPreservingOrder(tweetsFromCache.compactMap { $0 })
                        } else {
                            tweets.mergeTweets(tweetsFromCache.compactMap { $0 })
                        }

                        // Set hasMoreTweets based on cache - if we got a full page, there might be more
                        // This is optimistic - server update will correct it if needed
                        if tweetsFromCache.count >= pageSize {
                            hasMoreTweets = true
                        }

                        // Update VideoLoadingManager with debouncing
                        updateVideoLoadingManager(delay: 0.2)
                    }
                    print("✅ [PAGINATION] Loaded \(tweetsFromCache.count) tweets from cache for page \(page)")
                }
            } catch {
                // Cache fetch failed - not critical, we'll try server next
                print("⚠️ [PAGINATION] Cache fetch failed for page \(page): \(error), will try server")
            }

            // CRITICAL: Let UI render cached tweets BEFORE continuing with server fetch
            // By spawning the rest in a separate Task, cached tweets render immediately
            // (Same pattern as performInitialLoad - SwiftUI batches updates within same Task)
            let capturedLastTweetId = lastVisibleTweetIdBeforeLoad
            let tweetCountBeforeServer = tweets.count

            Task {
                // Step 2: Load from server to get fresh data (always try, even if cache failed)
                // Keep isLoadingMore = true until server responds so spinner stays visible
                await loadFromServer(page: page, pageSize: pageSize, completion: completion)

                // Now that server has responded, clear loading state
                await MainActor.run {
                    isLoadingMore = false
                    loadingStartTime = nil

                    // Only restore scroll position if:
                    // 1. New tweets were actually loaded (count increased)
                    // 2. Not at end of list (hasMoreTweets is still true)
                    // 3. Not during startup phase
                    let newTweetsLoaded = tweets.count > tweetCountBeforeServer
                    if let lastTweetId = capturedLastTweetId,
                       newTweetsLoaded,
                       hasMoreTweets,
                       !videoLoadingManager.isInStartupPhase {
                        // Use a slight delay to ensure layout is complete
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeOut(duration: 0.25)) {
                                scrollProxy?.scrollTo("tweet_\(lastTweetId)", anchor: .bottom)
                            }
                        }
                    }
                    lastVisibleTweetIdBeforeLoad = nil
                }
            }
        }
    }
    
    // MARK: - Server Loading (No Retry)
    private func loadFromServer(page: UInt, pageSize: UInt, completion: @escaping (Bool) -> Void) async {
        do {
            let tweetsFromServer = try await tweetFetcher(page, pageSize, false)
            let validServerTweets = tweetsFromServer.compactMap { $0 }
            
            await MainActor.run {
                updateTweetsWithServerData(
                    validServerTweets: validServerTweets,
                    tweetsFromServer: tweetsFromServer,
                    page: page,
                    pageSize: pageSize
                )
            }
            
        } catch {
            
            await MainActor.run {
                // Mark initial load as complete even on error for page 0
                if page == 0 {
                    isLoading = false
                    initialLoadComplete = true
                }
                // Don't modify tweets array - keep cached data intact
            }
        }
        completion(true)
    }
    
    // Helper function to update tweets with server data
    //
    // PAGINATION ALGORITHM - How It Works:
    // ====================================
    // This function is used by ALL tweet lists: main feed, bookmarks, favorites, user profiles
    //
    // Server Behavior (see TweetBackendApp/get_user_meta.js):
    // -------------------------------------------------------
    // 1. Server gets ALL bookmark/favorite entries from user's list
    // 2. Sorts by timestamp (newest first)
    // 3. **Slices to requested page range FIRST** (e.g., entries 0-9 for page 0)
    // 4. Then calls get_tweet() for each entry in the slice
    // 5. Returns array where:
    //    - Array count = number of bookmark/favorite ENTRIES in the slice
    //    - Array items can be null if the tweet was deleted (get_tweet returns null)
    //
    // Key Insight:
    // -----------
    // The array count reflects the number of bookmark/favorite ENTRIES, NOT valid tweets!
    //
    // Example: User has 100 bookmarks, 20 are deleted tweets, pageSize=10
    // - Page 0: Server slices entries 0-9 → returns array of 10 items (some null)
    // - Page 9: Server slices entries 90-99 → returns array of 10 items (some null)
    // - Page 10: Server slices entries 100-109 → returns array of 0 items (no more entries)
    //
    // Pagination Rule (SIMPLE):
    // ------------------------
    // if responseSize >= pageSize → more entries might exist, hasMoreTweets = true
    // if responseSize < pageSize → no more entries, hasMoreTweets = false
    //
    // This works because:
    // - Full page (count >= pageSize) means server had enough entries to fill the page
    // - Partial page (count < pageSize) means server ran out of entries
    //
    // NOTE: This is DIFFERENT from validCount (number of non-null tweets)
    // We must check responseSize, not validCount!
    private func updateTweetsWithServerData(
        validServerTweets: [Tweet],
        tweetsFromServer: [Tweet?],
        page: UInt,
        pageSize: UInt
    ) {
        let hasValidTweet = !validServerTweets.isEmpty

        // BRANCH 1: Got valid tweets - check response size
        if hasValidTweet {
            // For preserveOrder lists (bookmarks/favorites), page 0 should always REPLACE
            // to ensure correct server order (sorted by bookmark/favorite time)
            if page == 0 && preserveOrder {
                tweets = validServerTweets
            } else if page == 0 && tweets.isEmpty {
                tweets = validServerTweets
            } else {
                // For preserveOrder lists (bookmarks/favorites), append in server order
                // For other lists, merge with timestamp sorting
                if preserveOrder {
                    tweets.appendTweetsPreservingOrder(validServerTweets)
                } else {
                    tweets.mergeTweets(validServerTweets)
                }
            }

            // Update VideoLoadingManager with debouncing
            updateVideoLoadingManager(delay: 0.2)

            currentPage = page

            // Check response size (including nils) to determine if more items exist
            // Server slices bookmark/favorite ENTRIES before calling get_tweet
            // So array count reflects number of entries, not valid tweets
            hasMoreTweets = tweetsFromServer.count >= pageSize
            print("📊 [PAGINATION] Page \(page): got \(tweetsFromServer.count) entries (\(validServerTweets.count) valid), hasMoreTweets = \(hasMoreTweets)")

            // Mark initial load as complete for page 0 only if we got valid tweets
            if page == 0 {
                isLoading = false
                initialLoadComplete = true
                // Prewarm video players in background to avoid blocking scroll gestures
                // Defer during initial startup to prevent hangs
                Task.detached(priority: .background) {
                    // Wait 2 seconds after initial load before prewarming videos
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run {
                        self.prewarmSingletonPlayersFromFirstVideoIfNeeded()
                    }
                }
            }

        // BRANCH 2: No valid tweets AND partial page - server depleted
        } else if tweetsFromServer.count < pageSize {
            // Partial page means server ran out of bookmark/favorite entries
            hasMoreTweets = false
            print("📊 [PAGINATION] Page \(page): got \(tweetsFromServer.count) entries (0 valid), PARTIAL PAGE - no more tweets")
            if page == 0 {
                if tweets.isEmpty {
                    // Update VideoLoadingManager with empty list (no debouncing needed for empty)
                    updateVideoLoadingManager()
                    isLoading = false
                    initialLoadComplete = true
                } else {
                    isLoading = false
                    initialLoadComplete = true
                }
            }

        // BRANCH 3: No valid tweets BUT full page - keep trying next page
        } else {
            // Full page (all nils) means server had enough entries, continue to next page
            // Example: Page has 10 deleted bookmarks (all nils) - more entries might exist
            currentPage = page
            hasMoreTweets = true
            print("📊 [PAGINATION] Page \(page): got \(tweetsFromServer.count) entries (0 valid), FULL PAGE - trying next page")
        }
    }

    @MainActor
    private func prewarmSingletonPlayersFromFirstVideoIfNeeded() {
        guard !didPrewarmSingletonFirstItem else { return }

        // Find the first video/HLS attachment we can resolve to a URL.
        for tweet in tweets {
            guard let attachments = tweet.attachments else { continue }
            let baseUrl = tweet.author?.baseUrl ?? hproseInstance.appUser.baseUrl ?? HproseInstance.baseUrl

            for attachment in attachments where (attachment.type == .video || attachment.type == .hls_video) {
                guard let url = attachment.getUrl(baseUrl) else { continue }

                didPrewarmSingletonFirstItem = true

                // Prewarm both singleton pipelines (no playback).
                FullScreenVideoManager.shared.prewarmFirstItemIfNeeded(
                    url: url,
                    mediaID: attachment.mid,
                    mediaType: attachment.type
                )
                DetailVideoManager.shared.prewarmFirstItemIfNeeded(
                    url: url,
                    mediaID: attachment.mid,
                    mediaType: attachment.type
                )
                return
            }
        }
    }

    // MARK: - Optimistic UI Methods
    func insertTweet(_ tweet: Tweet) {
        tweets.insert(tweet, at: 0)
    }
    
    // MARK: - Screen Filling
    /// Automatically loads more tweets until the screen is filled
    private func loadMoreToFillScreen() async {
        guard hasMoreTweets, !isLoadingMore, !isLoading, initialLoadComplete else { return }
        
        
        // Temporarily disable auto-fill to prevent infinite loop
        await MainActor.run {
            needsMoreContent = false
        }
        
        // Load next page
        loadMoreTweets()
        
        // Re-enable after a short delay to allow UI to update
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
            await MainActor.run {
                needsMoreContent = true
            }
        }
    }
}
