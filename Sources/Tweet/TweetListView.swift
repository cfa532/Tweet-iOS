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
struct TweetListView<RowView: View>: View {
    // MARK: - Properties
    let title: String
    let tweetFetcher: @Sendable (UInt, UInt, Bool) async throws -> [Tweet?]
    let showTitle: Bool
    let rowView: (Tweet) -> RowView
    let header: (() -> AnyView)?
    let notifications: [TweetListNotification]
    let onScroll: ((CGFloat, CGFloat) -> Void)?  // (offset, delta)
    let leadingPadding: CGFloat  // Leading padding for cells
    let trailingPadding: CGFloat  // Trailing padding for cells
    let pinnedTweets: [Tweet]  // Pinned tweets for video coordination
    private let pageSize: UInt = 10  // Manual load-more only

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
    @State private var videoUpdateTask: Task<Void, Never>? // Track update task for debouncing
    
    // Minimum duration to show the loading spinner (in seconds)
    private let minimumLoadingDuration: TimeInterval = 0.5
    
    // MARK: - Helper Methods
    
    /// Update VideoLoadingManager with current tweet list (DEBOUNCED)
    /// Centralized method to avoid code duplication and prevent task pile-up
    private func updateVideoLoadingManager(delay: TimeInterval = 0) {
        // Cancel any pending update task to prevent pile-up
        videoUpdateTask?.cancel()
        
        // Create new update task
        videoUpdateTask = Task.detached(priority: .background) {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            
            // Check if cancelled during delay
            guard !Task.isCancelled else { return }
            
            let tweetIds = await MainActor.run { self.tweets.map { $0.mid } }
            
            // Check again after MainActor.run
            guard !Task.isCancelled else { return }
            
            await self.videoLoadingManager.updateTweetList(tweetIds)

            // Also cleanup old tweet instances to prevent memory growth
            let activeTweetIds = Set(tweetIds)
            Tweet.cleanupOldInstances(activeTweetIds: activeTweetIds)
            
            // Clear task reference on completion
            await MainActor.run {
                self.videoUpdateTask = nil
            }
        }
    }
    
    // MARK: - Video Navigation for Fullscreen
    
    /// Find next video in tweet list starting from given SOURCE tweet (visible in feed) and video index
    /// sourceTweetId: The visible tweet in feed (could be retweet)
    /// currentVideoIndex: The current video index in the tweet's attachments
    func findNextVideoInList(sourceTweetId: String, currentVideoIndex: Int) async -> (tweet: Tweet, videoIndex: Int, sourceTweetId: String)? {
        
        // ✅ PERFORMANCE FIX: Capture tweet arrays synchronously (no MainActor wait)
        // This eliminates the async bottleneck that was blocking UI during video navigation
        let allTweets = pinnedTweets + tweets
        let pinnedCount = pinnedTweets.count
        let regularCount = tweets.count
        
        print("🔍 [FIND NEXT VIDEO] Searching for next video after sourceTweetId: \(sourceTweetId), videoIndex: \(currentVideoIndex)")
        print("🔍 [FIND NEXT VIDEO] Total tweets to search: \(allTweets.count) (pinned: \(pinnedCount), regular: \(regularCount))")
        
        // Find source tweet (the visible tweet in feed)
        guard let sourceTweetIdx = allTweets.firstIndex(where: { $0.mid == sourceTweetId }) else {
            print("❌ [FIND NEXT VIDEO] Source tweet not found in list")
            return nil
        }
        
        print("🔍 [FIND NEXT VIDEO] Found source tweet at index: \(sourceTweetIdx)")
        
        let sourceTweet = allTweets[sourceTweetIdx]
        
        // Get media tweet (handle retweets)
        // Optimization: Check cache first, skip if not available (don't block on network)
        let mediaTweet: Tweet
        if let originalTweetId = sourceTweet.originalTweetId,
           sourceTweet.attachments == nil {
            // This is a retweet without attachments - check cache (singleton + Core Data)
            let original = Tweet.getInstance(for: originalTweetId)
                ?? TweetCacheManager.shared.fetchTweetSync(mid: originalTweetId)
            
            if let original = original {
                mediaTweet = original
            } else {
                // Original not in cache - skip to next tweet instead of blocking on network
                mediaTweet = sourceTweet
            }
        } else {
            mediaTweet = sourceTweet
        }
        
        // Find all video attachments in media tweet
        if let attachments = mediaTweet.attachments {
            let videoIndices = attachments.enumerated().compactMap { index, attachment in
                (attachment.type == .video || attachment.type == .hls_video) ? index : nil
            }
            
            
            // Check if there are more videos in current media tweet
            if let currentPosInVideoList = videoIndices.firstIndex(of: currentVideoIndex),
               currentPosInVideoList + 1 < videoIndices.count {
                let nextVideoIdx = videoIndices[currentPosInVideoList + 1]
                return (mediaTweet, nextVideoIdx, sourceTweetId) // Same source tweet
            }
        }
        
        // No more videos in current tweet, search next VISIBLE tweets in feed (including both pinned and regular)
        print("🔍 [FIND NEXT VIDEO] No more videos in current tweet, searching from index \(sourceTweetIdx + 1) to \(allTweets.count - 1)")
        for idx in (sourceTweetIdx + 1)..<allTweets.count {
            let nextTweet = allTweets[idx]
            
            // Get media tweet (handle retweets)
            // Optimization: Check cache first, skip if not available (don't block on network)
            let nextMediaTweet: Tweet
            if let originalTweetId = nextTweet.originalTweetId,
               nextTweet.attachments == nil {
                // This is a retweet without attachments - check cache (singleton + Core Data)
                let original = Tweet.getInstance(for: originalTweetId)
                    ?? TweetCacheManager.shared.fetchTweetSync(mid: originalTweetId)
                
                if let original = original {
                    nextMediaTweet = original
                } else {
                    // Original not in cache - skip to next tweet instead of blocking on network
                    nextMediaTweet = nextTweet
                }
            } else {
                nextMediaTweet = nextTweet
            }
            
            if let attachments = nextMediaTweet.attachments {
                if let firstVideoIdx = attachments.firstIndex(where: { $0.type == .video || $0.type == .hls_video }) {
                    print("✅ [FIND NEXT VIDEO] Found next video at index \(idx): tweetId=\(nextTweet.mid), videoMid=\(attachments[firstVideoIdx].mid)")
                    return (nextMediaTweet, firstVideoIdx, nextTweet.mid) // Return source tweet ID
                }
            }
        }
        
        print("❌ [FIND NEXT VIDEO] No next video found in list")
        return nil
    }

    // MARK: - Initialization
    let onRefreshExtra: (() async -> Void)?  // Optional extra refresh callback
    
    init(
        title: String,
        tweets: Binding<[Tweet]>,
        tweetFetcher: @escaping @Sendable (UInt, UInt, Bool) async throws -> [Tweet?],
        showTitle: Bool = true,
        notifications: [TweetListNotification]? = nil,
        onScroll: ((CGFloat, CGFloat) -> Void)? = nil,  // (offset, delta)
        leadingPadding: CGFloat = 8,  // Default 8pt leading padding
        trailingPadding: CGFloat = 8,  // Default 8pt trailing padding
        pinnedTweets: [Tweet] = [],  // Pinned tweets for video coordination
        header: (() -> AnyView)? = nil,
        onRefreshExtra: (() async -> Void)? = nil,  // Extra refresh callback
        rowView: @escaping (Tweet) -> RowView
    ) {
        self.title = title
        self._tweets = tweets
        self.tweetFetcher = tweetFetcher
        self.showTitle = showTitle
        self.onScroll = onScroll
        self.leadingPadding = leadingPadding
        self.trailingPadding = trailingPadding
        self.pinnedTweets = pinnedTweets
        self.header = header
        self.onRefreshExtra = onRefreshExtra
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
        GeometryReader { geometry in
            ZStack {
                // UIKit TABLE VIEW - Eliminates SwiftUI's GraphHost.flushTransactions() hang
                TweetTableView(
                    tweets: $tweets,
                    header: header,
                    rowView: { tweet in
                        rowView(tweet)
                    },
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
                    pinnedTweets: pinnedTweets
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
            
            // Listen to all notifications
            ForEach(Array(notifications.enumerated()), id: \.element.name) { idx, notification in
                EmptyView()
                    .onReceive(NotificationCenter.default.publisher(for: notification.name)) { notif in
                        if let tweet = notif.userInfo?[notification.key] as? Tweet, notification.shouldAccept(tweet) {
                            notification.action(tweet)
                        }
                        // Special case: tweetId notifications send String instead of Tweet
                        if notification.key == "tweetId", let tweetId = notif.userInfo?[notification.key] as? String {
                            // Find tweet once for efficiency (avoid multiple O(n) searches)
                            let tweetIndex = tweets.firstIndex(where: { $0.mid == tweetId })
                            
                            if notification.name == .tweetDeleted {
                                // For tweet deletion, handle directly in TweetListView
                                if let index = tweetIndex {
                                    tweets.remove(at: index)
                                }
                                TweetCacheManager.shared.deleteTweet(mid: tweetId)
                            } else if notification.name == .tweetPrivacyChanged {
                                // For privacy changes, handle removal directly here
                                if let index = tweetIndex {
                                    let tweetToRemove = tweets[index]
                                    tweets.remove(at: index)
                                    // Call custom handler with the tweet that was removed
                                    notification.action(tweetToRemove)
                                }
                            } else {
                                // For other notifications, call the custom handler
                                if let index = tweetIndex {
                                    notification.action(tweets[index])
                                }
                            }
                        }
                        // Special case: tweetPrivacyChanged sends tweetId and privacy info
                        // This is handled by custom handlers in each view (FollowingsTweetView, ProfileTweetsSection)
                        // No built-in handling here to avoid conflicts
                        // Special case: blockUser may send blockedUserId to remove all tweets from that user
                        if let blockedUserId = notif.userInfo?["blockedUserId"] as? String {
                            tweets.removeAll { $0.authorId == blockedUserId }
                        }
                    }
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
            // DON'T stop all videos here for MainFeed/TweetList!
            // The coordinator already tracks visible videos and will restart them naturally.
            // Calling stopAllVideos() would reset coordinator state and force player recreation.
            //
            // For views like ProfileView, stopAllVideos() makes sense because they're
            // new contexts. But TweetListView is the "home base" that coordinator manages.
            
            print("🧹 [TweetListView] View appeared - letting coordinator handle video state")
            
            // Set up fullscreen video search function for auto-advance
            setupVideoSearchFunction()
            
            // Set up foreground observer to fetch new tweets when app returns
            setupForegroundObserver()
        }
        .onChange(of: tweets) { _, _ in
            // Update search function when tweets change
            setupVideoSearchFunction()
        }
        .onChange(of: pinnedTweets) { _, _ in
            // Update search function when pinned tweets change
            setupVideoSearchFunction()
        }
        .onDisappear {
            // CRITICAL: Stop all video playback when navigating away
            VideoPlaybackCoordinator.shared.stopAllVideos()
            
            // DON'T clean up players here - they may be needed when navigating back
            // Memory management is handled by cache limits and periodic cleanup
            // Only aggressive cleanup happens on profile view transitions
            
            print("🧹 [TweetListView] View disappeared - stopped all videos (players kept for potential return)")
            
            // Clean up foreground observer
            if let observer = foregroundObserver {
                NotificationCenter.default.removeObserver(observer)
                foregroundObserver = nil
            }
        }
    }
    
    // MARK: - Helper Methods
    
    /// Set up the video search function with current tweet arrays
    private func setupVideoSearchFunction() {
        // Capture current tweet arrays - this runs whenever tweets/pinnedTweets change
        let currentTweets = tweets
        let currentPinnedTweets = pinnedTweets
        let hproseRef = hproseInstance
        
        FullScreenVideoManager.shared.setVideoSearchFunction(
            { [currentTweets, currentPinnedTweets, hproseRef] sourceTweetId, currentVideoIndex in
                    // Combined tweet list: pinned tweets first, then regular tweets
                    let allTweets = currentPinnedTweets + currentTweets
                    print("🔍 [FIND NEXT VIDEO] Searching for next video after sourceTweetId: \(sourceTweetId), videoIndex: \(currentVideoIndex)")
                    print("🔍 [FIND NEXT VIDEO] Total tweets to search: \(allTweets.count) (pinned: \(currentPinnedTweets.count), regular: \(currentTweets.count))")
                    
                    // Find source tweet
                    guard let sourceTweetIdx = allTweets.firstIndex(where: { $0.mid == sourceTweetId }) else {
                        print("❌ [FIND NEXT VIDEO] Source tweet not found in list")
                        return nil
                    }
                    
                    print("🔍 [FIND NEXT VIDEO] Found source tweet at index: \(sourceTweetIdx)")
                    let sourceTweet = allTweets[sourceTweetIdx]
                    
                    // Get media tweet (handle retweets)
                    // Optimization: Only fetch if retweet doesn't already have attachments
                    let mediaTweet: Tweet
                    if let originalTweetId = sourceTweet.originalTweetId,
                       let originalAuthorId = sourceTweet.originalAuthorId,
                       sourceTweet.attachments == nil {
                        if let original = try? await hproseRef.getTweet(tweetId: originalTweetId, authorId: originalAuthorId) {
                            mediaTweet = original
                        } else {
                            mediaTweet = sourceTweet
                        }
                    } else {
                        mediaTweet = sourceTweet
                    }
                    
                    // Check for more videos in current tweet
                    if let attachments = mediaTweet.attachments {
                        let videoIndices = attachments.enumerated().compactMap { index, attachment in
                            (attachment.type == .video || attachment.type == .hls_video) ? index : nil
                        }
                        
                        if let currentPosInVideoList = videoIndices.firstIndex(of: currentVideoIndex),
                           currentPosInVideoList + 1 < videoIndices.count {
                            let nextVideoIdx = videoIndices[currentPosInVideoList + 1]
                            return (mediaTweet, nextVideoIdx, sourceTweetId)
                        }
                    }
                    
                    // Search next tweets
                    print("🔍 [FIND NEXT VIDEO] No more videos in current tweet, searching from index \(sourceTweetIdx + 1) to \(allTweets.count - 1)")
                    for idx in (sourceTweetIdx + 1)..<allTweets.count {
                        let nextTweet = allTweets[idx]
                        
                        // Optimization: Only fetch if retweet doesn't already have attachments
                        let nextMediaTweet: Tweet
                        if let originalTweetId = nextTweet.originalTweetId,
                           let originalAuthorId = nextTweet.originalAuthorId,
                           nextTweet.attachments == nil {
                            if let original = try? await hproseRef.getTweet(tweetId: originalTweetId, authorId: originalAuthorId) {
                                nextMediaTweet = original
                            } else {
                                nextMediaTweet = nextTweet
                            }
                        } else {
                            nextMediaTweet = nextTweet
                        }
                        
                        if let attachments = nextMediaTweet.attachments {
                            if let firstVideoIdx = attachments.firstIndex(where: { $0.type == .video || $0.type == .hls_video }) {
                                print("✅ [FIND NEXT VIDEO] Found next video at index \(idx): tweetId=\(nextTweet.mid), videoMid=\(attachments[firstVideoIdx].mid)")
                                return (nextMediaTweet, firstVideoIdx, nextTweet.mid)
                            }
                        }
                    }
                    
                    print("❌ [FIND NEXT VIDEO] No next video found in list")
                    return nil
                },
                onNavigate: { tweet, videoIndex, sourceTweetId in
                    // MediaBrowserView will handle the actual navigation
                }
            )
    }

    // MARK: - Methods
    
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
                    // Merge new tweets into existing list (will sort by timestamp)
                    tweets.mergeTweets(validTweets)
                    currentPage = 0
                    hasMoreTweets = freshTweets.count >= pageSize
                    
                    // Update video manager in background
                    updateVideoLoadingManager()
                    
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
                        // Merge new tweets into existing list
                        self.tweets.mergeTweets(validTweets)
                        self.currentPage = nextPage
                        
                        // Update hasMoreTweets based on whether we got a full page
                        self.hasMoreTweets = tweets.count >= self.pageSize
                        
                        // Update video manager in background
                        self.updateVideoLoadingManager()
                    } else {
                        // No valid tweets - stop loading
                        self.hasMoreTweets = false
                        print("📥 [AUTO-LOAD] No valid tweets in page \(nextPage) - stopping")
                    }
                }
                
                // Check if we got a partial page (indicates end of new tweets)
                if tweets.count < pageSize {
                    print("📥 [AUTO-LOAD] Received partial page (\(tweets.count) tweets) - completed")
                    break
                }
                
                pagesLoaded += 1
                
                // Small delay between requests to avoid overwhelming server
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                
            } catch {
                print("📥 [AUTO-LOAD] Error loading page \(nextPage): \(error)")
                await MainActor.run {
                    self.hasMoreTweets = false
                }
                break
            }
        }
        
        if pagesLoaded >= maxAutoLoadPages {
            print("📥 [AUTO-LOAD] Reached max auto-load limit (\(maxAutoLoadPages) pages)")
        }
    }

    func refreshTweets() async {
        guard !isLoading else {
            return
        }
        
        isLoading = true
        initialLoadComplete = false
        currentPage = 0
        
        do {
            // Always load fresh data from server for refresh
            let freshTweets = try await tweetFetcher(0, pageSize, false)
            let validTweets = freshTweets.compactMap { $0 }
            let hasValidTweet = !validTweets.isEmpty
            
            if validTweets.isEmpty {
            }
            
            await MainActor.run {
                // Update tweets with server data - REPLACE on refresh, don't merge
                if hasValidTweet {
                    // On refresh, replace existing tweets with fresh server data
                    tweets = validTweets
                    currentPage = 0
                    hasMoreTweets = freshTweets.count >= pageSize
                    
                    // Update VideoLoadingManager
                    updateVideoLoadingManager()
                    } else {
                        // Only clear if server returned no valid tweets AND we have no cached tweets
                        if tweets.isEmpty {
                            tweets = []
                            hasMoreTweets = false

                            // Update VideoLoadingManager with empty list
                            updateVideoLoadingManager()
                        } else {
                        // Keep cached tweets if server returned no valid tweets
                        hasMoreTweets = false
                    }
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
                        tweets.mergeTweets(tweetsFromCache.compactMap { $0 })
                        
                        // Set hasMoreTweets based on cache - if we got a full page, there might be more
                        // This is optimistic - server update will correct it if needed
                        if tweetsFromCache.count >= pageSize {
                            hasMoreTweets = true
                        }
                        
                        // Update VideoLoadingManager
                        updateVideoLoadingManager()
                    }
                    print("✅ [PAGINATION] Loaded \(tweetsFromCache.count) tweets from cache for page \(page)")
                }
            } catch {
                // Cache fetch failed - not critical, we'll try server next
                print("⚠️ [PAGINATION] Cache fetch failed for page \(page): \(error), will try server")
            }
            
            // Calculate elapsed time
            let elapsedTime = Date().timeIntervalSince(startTime)
            let remainingTime = max(0, minimumLoadingDuration - elapsedTime)
            
            // Wait for minimum duration if needed
            if remainingTime > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remainingTime * 1_000_000_000))
            }
            
            await MainActor.run {
                // Clear loading state after minimum duration
                isLoadingMore = false
                loadingStartTime = nil
                
                // Restore scroll position to keep the last visible tweet above bottom bar
                // Only restore scroll position after startup phase to avoid unwanted scrolling during app launch
                if let lastTweetId = lastVisibleTweetIdBeforeLoad, !videoLoadingManager.isInStartupPhase {
                    // Use a slight delay to ensure layout is complete
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            scrollProxy?.scrollTo("tweet_\(lastTweetId)", anchor: .bottom)
                        }
                    }
                    lastVisibleTweetIdBeforeLoad = nil
                } else if let _ = lastVisibleTweetIdBeforeLoad, videoLoadingManager.isInStartupPhase {
                    // During startup phase, just clear the captured tweet without scrolling
                    lastVisibleTweetIdBeforeLoad = nil
                }
            }
            
            // Step 2: Load from server to get fresh data (always try, even if cache failed)
            Task {
                await loadFromServer(page: page, pageSize: pageSize, completion: completion)
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
    private func updateTweetsWithServerData(
        validServerTweets: [Tweet],
        tweetsFromServer: [Tweet?],
        page: UInt,
        pageSize: UInt
    ) {
        let hasValidTweet = !validServerTweets.isEmpty
        
        // Update tweets with server data
        if hasValidTweet {
            if page == 0 && tweets.isEmpty {
                tweets = validServerTweets
            } else {
                tweets.mergeTweets(validServerTweets)
            }
            
            // Update VideoLoadingManager
            updateVideoLoadingManager()

            currentPage = page

            // Set hasMoreTweets based on whether we got a full page
            // If we got a full page, there might be more tweets
            if tweetsFromServer.count >= pageSize {
                hasMoreTweets = true
            } else {
                hasMoreTweets = false
            }

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
        } else if tweetsFromServer.count < pageSize {
            hasMoreTweets = false
            // Server returned fewer than pageSize tweets (or empty), so no more pages
            if page == 0 {
                if tweets.isEmpty {
                    // Update VideoLoadingManager with empty list
                    updateVideoLoadingManager()
                    isLoading = false
                    initialLoadComplete = true
                } else {
                    isLoading = false
                    initialLoadComplete = true
                }
            }
        } else {
            // All tweets are nil but we got a full page, continue to next page
            currentPage = page
            hasMoreTweets = true
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
            // Header content
            if let header = header {
                header()
            }
            
            // Show loading state if we don't have tweets and haven't completed loading
            // This covers both: actively loading (isLoading=true) OR waiting for initial load to start (!initialLoadComplete)
            if tweets.compactMap({ $0 }).isEmpty && (isLoading || !initialLoadComplete) {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text(NSLocalizedString("Loading tweets...", comment: "Loading tweets message"))
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            } else if initialLoadComplete && tweets.compactMap({ $0 }).isEmpty {
                // Show empty state ONLY when loading is actually complete AND there are no tweets
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
                // Show tweets with LazyVStack for smooth scrolling
                // Small spacer
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 1)
                
                LazyVStack(spacing: 0, pinnedViews: []) {
                    ForEach(Array(tweets.compactMap { $0 }.enumerated()), id: \.element.mid) { index, tweet in
                        VStack(spacing: 0) {
                            if index > 0 {
                                Rectangle()
                                    .padding(.horizontal, 2)
                                    .frame(height: 0.5)
                                    .foregroundColor(Color(.systemGray).opacity(0.4))
                            }
                            rowView(tweet)
                                // Add identity for view reuse
                                .id("tweet_\(tweet.mid)")
                                .onAppear {
                                    // Update VideoLoadingManager when tweet becomes visible
                                    videoLoadingManager.updateVisibleTweetIndex(index)
                                }
                        }
                    }
                }
                
                // Load-more trigger and spinner - matches working commit 9667bda5cbcbfe18a2932c6d4c31280556dba55c
                // Always present view to detect bottom scrolling
                Color.clear
                    .frame(height: 40)
                    .onAppear {
                        if initialLoadComplete && !isLoadingMore {
                            hasMoreTweets = true
                            loadMoreTweets()
                        }
                    }
                
                // Loading indicator for more tweets - shown as list item for smooth scrolling
                if hasMoreTweets {
                    // Use consistent height to prevent layout jumps
                    ZStack {
                        if isLoadingMore {
                            // Show spinner when loading
                            ProgressView()
                                .scaleEffect(1.0)
                        }
                    }
                    .frame(height: 80)
                    .frame(maxWidth: .infinity)
                } else {
                    // Small spacer at bottom when no more tweets
                    Color.clear
                        .frame(height: 80)
                }
            }
        }
    }
}
