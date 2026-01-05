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
    private let pageSize: UInt = 5  // Reduced for better server load distribution

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
    
    // Minimum duration to show the loading spinner (in seconds)
    private let minimumLoadingDuration: TimeInterval = 0.5
    
    // MARK: - Video Navigation for Fullscreen
    
    /// Find next video in tweet list starting from given SOURCE tweet (visible in feed) and video index
    /// sourceTweetId: The visible tweet in feed (could be retweet)
    /// currentVideoIndex: The current video index in the tweet's attachments
    func findNextVideoInList(sourceTweetId: String, currentVideoIndex: Int) async -> (tweet: Tweet, videoIndex: Int, sourceTweetId: String)? {
        print("DEBUG: [TweetListView] Finding next video - sourceTweetId: \(sourceTweetId), currentVideoIndex: \(currentVideoIndex)")
        
        // Find source tweet (the visible tweet in feed)
        guard let sourceTweetIdx = await MainActor.run(body: { tweets.firstIndex(where: { $0.mid == sourceTweetId }) }) else {
            print("DEBUG: [TweetListView] Source tweet not found in feed")
            return nil
        }
        
        let sourceTweet = await MainActor.run { tweets[sourceTweetIdx] }
        
        // Get media tweet (handle retweets)
        let mediaTweet: Tweet
        if let originalTweetId = sourceTweet.originalTweetId,
           let originalAuthorId = sourceTweet.originalAuthorId {
            // This is a retweet - fetch original tweet
            print("DEBUG: [TweetListView] Source tweet is retweet, fetching original tweet")
            if let original = try? await hproseInstance.getTweet(tweetId: originalTweetId, authorId: originalAuthorId) {
                mediaTweet = original
            } else {
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
            
            print("DEBUG: [TweetListView] Media tweet has \(videoIndices.count) videos at indices: \(videoIndices)")
            
            // Check if there are more videos in current media tweet
            if let currentPosInVideoList = videoIndices.firstIndex(of: currentVideoIndex),
               currentPosInVideoList + 1 < videoIndices.count {
                let nextVideoIdx = videoIndices[currentPosInVideoList + 1]
                print("DEBUG: [TweetListView] ✅ Found next video in same tweet at index \(nextVideoIdx)")
                return (mediaTweet, nextVideoIdx, sourceTweetId) // Same source tweet
            }
        }
        
        // No more videos in current tweet, search next VISIBLE tweets in feed
        print("DEBUG: [TweetListView] Searching next visible tweets for videos... (from index \(sourceTweetIdx + 1) to \(await MainActor.run { tweets.count - 1}))")
        let tweetCount = await MainActor.run { tweets.count }
        for idx in (sourceTweetIdx + 1)..<tweetCount {
            let nextTweet = await MainActor.run { tweets[idx] }
            print("DEBUG: [TweetListView] Checking visible tweet \(idx): \(nextTweet.mid), isRetweet: \(nextTweet.originalTweetId != nil)")
            
            // Get media tweet (handle retweets)
            let nextMediaTweet: Tweet
            if let originalTweetId = nextTweet.originalTweetId,
               let originalAuthorId = nextTweet.originalAuthorId {
                print("DEBUG: [TweetListView] Tweet \(idx) is retweet, fetching original")
                if let original = try? await hproseInstance.getTweet(tweetId: originalTweetId, authorId: originalAuthorId) {
                    nextMediaTweet = original
                } else {
                    nextMediaTweet = nextTweet
                }
            } else {
                nextMediaTweet = nextTweet
            }
            
            if let attachments = nextMediaTweet.attachments {
                let videoTypes = attachments.map { $0.type }
                print("DEBUG: [TweetListView] Tweet \(idx) attachment types: \(videoTypes)")
                
                if let firstVideoIdx = attachments.firstIndex(where: { $0.type == .video || $0.type == .hls_video }) {
                    print("DEBUG: [TweetListView] ✅ Found next video at visible tweet index \(idx), video index \(firstVideoIdx)")
                    return (nextMediaTweet, firstVideoIdx, nextTweet.mid) // Return source tweet ID
                }
            }
        }
        
        print("DEBUG: [TweetListView] ❌ No more videos found")
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
                    isLoading: isLoading,
                    loadMoreTweets: { loadMoreTweets() },
                    onRefresh: {
                        await refreshTweets()
                        await onRefreshExtra?()
                    },
                    onScroll: onScroll,
                    leadingPadding: leadingPadding,
                    trailingPadding: trailingPadding
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
                            if notification.name == .tweetDeleted {
                                // For tweet deletion, handle directly in TweetListView
                                let countBefore = tweets.count
                                tweets.removeAll { $0.mid == tweetId }
                                let countAfter = tweets.count
                                TweetCacheManager.shared.deleteTweet(mid: tweetId)
                                print("DEBUG: [TweetListView] Removed deleted tweet \(tweetId) from list (title: \(title), count: \(countBefore) -> \(countAfter))")
                            } else if notification.name == .tweetPrivacyChanged {
                                // For privacy changes, handle removal directly here
                                // Find the tweet first before removing it
                                let tweetToRemove = tweets.first(where: { $0.mid == tweetId })
                                let countBefore = tweets.count
                                tweets.removeAll { $0.mid == tweetId }
                                let countAfter = tweets.count
                                
                                if countBefore != countAfter {
                                    print("DEBUG: [TweetListView] Removed privacy-changed tweet \(tweetId) from list (title: \(title), count: \(countBefore) -> \(countAfter))")
                                    // Also call custom handler with the tweet that was removed
                                    if let tweet = tweetToRemove {
                                        notification.action(tweet)
                                    }
                                } else {
                                    print("DEBUG: [TweetListView] Privacy-changed tweet \(tweetId) not found in list (title: \(title))")
                                }
                            } else {
                                // For other notifications, call the custom handler
                                // Find the actual tweet in the list and pass it to the handler
                                if let actualTweet = tweets.first(where: { $0.mid == tweetId }) {
                                    notification.action(actualTweet)
                                }
                            }
                        }
                        // Special case: tweetPrivacyChanged sends tweetId and privacy info
                        // This is handled by custom handlers in each view (FollowingsTweetView, ProfileTweetsSection)
                        // No built-in handling here to avoid conflicts
                        // Special case: blockUser may send blockedUserId to remove all tweets from that user
                        if let blockedUserId = notif.userInfo?["blockedUserId"] as? String {
                            let originalCount = tweets.count
                            tweets.removeAll { $0.authorId == blockedUserId }
                            let removedCount = originalCount - tweets.count
                            print("[TweetListView] Removed \(removedCount) tweets from blocked user: \(blockedUserId)")
                        }
                    }
            }
            }  // Close ZStack
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
        }  // Close GeometryReader
        .onReceive(NotificationCenter.default.publisher(for: .userDidLogin)) { _ in
            Task {
                await refreshTweets()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Set up fullscreen video search function for auto-advance
            // Each TweetListView overwrites the previous one's function
            print("DEBUG: [TweetListView] Registering video search function - title: \(title), tweets count: \(tweets.count)")
            FullScreenVideoManager.shared.setVideoSearchFunction(
                findNextVideoInList,
                onNavigate: { tweet, videoIndex, sourceTweetId in
                    print("DEBUG: [TweetListView] Fullscreen navigation callback - tweet: \(tweet.mid), videoIndex: \(videoIndex), sourceTweetId: \(sourceTweetId)")
                    // MediaBrowserView will handle the actual navigation
                }
            )
        }
    }

    // MARK: - Methods
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
                    print("[TweetListView] Initial cache load: got \(tweetsFromCache.count) tweets, hasMoreTweets=\(hasMoreTweets)")

                    // Update VideoLoadingManager with new tweet list (background task to avoid blocking)
                    // Defer during initial startup to prevent hangs
                    Task.detached(priority: .background) {
                        // Wait 1 second after cache load before updating video manager
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        let tweetIds = await MainActor.run { self.tweets.map { $0.mid } }
                        await self.videoLoadingManager.updateTweetList(tweetIds)
                    }

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
            
            // Step 2: Load from server to get the most up-to-date data
            await loadFromServer(page: page, pageSize: pageSize) { _ in }
            
            // Trigger preloading after initial load completes
            if hasMoreTweets {
                await MainActor.run {
                    loadNextTwoPages(startingFrom: 1)
                }
            }
            
        } catch {
            print("[TweetListView] Error during initial load: \(error)")
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
            let freshTweets = try await tweetFetcher(0, pageSize, false)
            let validTweets = freshTweets.compactMap { $0 }
            let hasValidTweet = !validTweets.isEmpty
            
            await MainActor.run {
                // Update tweets with server data while preserving cached tweets for failed IDs
                if hasValidTweet {
                    // Use mergeTweets to preserve cached tweets that weren't in server response
                    tweets.mergeTweets(validTweets)
                    currentPage = 0
                    hasMoreTweets = freshTweets.count >= pageSize
                    
                    // Update VideoLoadingManager with new tweet list (background task to avoid blocking)
                    Task.detached(priority: .background) {
                        let tweetIds = await MainActor.run { self.tweets.map { $0.mid } }
                        await self.videoLoadingManager.updateTweetList(tweetIds)
                    }
                    } else {
                        // Only clear if server returned no valid tweets AND we have no cached tweets
                        if tweets.isEmpty {
                            tweets = []
                            hasMoreTweets = false

                            // Update VideoLoadingManager with empty tweet list (background task to avoid blocking)
                            Task.detached(priority: .background) {
                                await self.videoLoadingManager.updateTweetList([])
                            }
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
        print("[TweetListView] loadMoreTweets called: hasMoreTweets=\(hasMoreTweets), isLoadingMore=\(isLoadingMore), initialLoadComplete=\(initialLoadComplete), currentPage=\(currentPage)")
        guard hasMoreTweets, !isLoadingMore, initialLoadComplete else {
            print("[TweetListView] loadMoreTweets guard failed - returning early")
            return 
        }
        
        let nextPage = page ?? (currentPage + 1)
        print("[TweetListView] loadMoreTweets proceeding with page \(nextPage)")
        
        // Load next two pages in advance, separated by 3 seconds
        loadNextTwoPages(startingFrom: nextPage)
    }
    
    // MARK: - Batch Loading for Prefetching
    private func loadNextTwoPages(startingFrom startPage: UInt) {
        // Load first page immediately
        loadSinglePage(page: startPage) { success in
            if success && self.hasMoreTweets {
                // Load second page after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if self.hasMoreTweets && !self.isLoadingMore {
                        self.loadSinglePage(page: startPage + 1) { _ in }
                    }
                }
            }
        }
    }
    
    private func loadSinglePage(page: UInt, completion: @escaping (Bool) -> Void) {
        let pageSize = self.pageSize
        
        Task {
            // Record loading start time
            let startTime = Date()
            
            await MainActor.run {
                // Capture the last visible tweet before loading
                if let lastTweet = tweets.last {
                    lastVisibleTweetIdBeforeLoad = lastTweet.mid
                    print("[TweetListView] Captured last visible tweet: \(lastTweet.mid)")
                }
                
                isLoadingMore = true
                loadingStartTime = startTime
            }
            
            do {
                // Step 1: Load from cache first for instant UX
                let tweetsFromCache = try await tweetFetcher(page, pageSize, true)
                
                // Calculate elapsed time
                let elapsedTime = Date().timeIntervalSince(startTime)
                let remainingTime = max(0, minimumLoadingDuration - elapsedTime)
                
                // Wait for minimum duration if needed
                if remainingTime > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingTime * 1_000_000_000))
                }
                
                await MainActor.run {
                    tweets.mergeTweets(tweetsFromCache.compactMap { $0 })
                    
                    // Set hasMoreTweets based on cache - if we got a full page, there might be more
                    // This is optimistic - server update will correct it if needed
                    if tweetsFromCache.count >= pageSize {
                        hasMoreTweets = true
                        print("[TweetListView] LoadMore cache: got full page (\(tweetsFromCache.count) >= \(pageSize)), setting hasMoreTweets=true")
                    }
                    
                    // Update VideoLoadingManager with new tweet list (background task to avoid blocking)
                    Task.detached(priority: .background) {
                        let tweetIds = await MainActor.run { self.tweets.map { $0.mid } }
                        await self.videoLoadingManager.updateTweetList(tweetIds)
                    }

                    // Clear loading state after minimum duration
                    isLoadingMore = false
                    loadingStartTime = nil
                    
                    // Restore scroll position to keep the last visible tweet above bottom bar
                    // Only restore scroll position after startup phase to avoid unwanted scrolling during app launch
                    if let lastTweetId = lastVisibleTweetIdBeforeLoad, !videoLoadingManager.isInStartupPhase {
                        print("[TweetListView] Restoring scroll position to tweet: \(lastTweetId)")
                        // Use a slight delay to ensure layout is complete
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeOut(duration: 0.25)) {
                                scrollProxy?.scrollTo("tweet_\(lastTweetId)", anchor: .bottom)
                            }
                        }
                        lastVisibleTweetIdBeforeLoad = nil
                    } else if let lastTweetId = lastVisibleTweetIdBeforeLoad, videoLoadingManager.isInStartupPhase {
                        // During startup phase, just clear the captured tweet without scrolling
                        print("[TweetListView] Skipping scroll restoration during startup phase for tweet: \(lastTweetId)")
                        lastVisibleTweetIdBeforeLoad = nil
                    }
                }
                
                // Step 2: Load from server to update with fresh data (non-blocking, no retry)
                Task {
                    await loadFromServer(page: page, pageSize: pageSize, completion: completion)
                }
            } catch {
                print("[TweetListView] Error loading page \(page): \(error)")
                
                // Calculate elapsed time for error case
                let elapsedTime = Date().timeIntervalSince(startTime)
                let remainingTime = max(0, minimumLoadingDuration - elapsedTime)
                
                // Wait for minimum duration even on error
                if remainingTime > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingTime * 1_000_000_000))
                }
                
                await MainActor.run { 
                    hasMoreTweets = false; 
                    isLoadingMore = false
                    loadingStartTime = nil
                    
                    // Restore scroll position even on error
                    // Only restore scroll position after startup phase to avoid unwanted scrolling during app launch
                    if let lastTweetId = lastVisibleTweetIdBeforeLoad, !videoLoadingManager.isInStartupPhase {
                        print("[TweetListView] Restoring scroll position after error to tweet: \(lastTweetId)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeOut(duration: 0.25)) {
                                scrollProxy?.scrollTo("tweet_\(lastTweetId)", anchor: .bottom)
                            }
                        }
                        lastVisibleTweetIdBeforeLoad = nil
                    } else if let lastTweetId = lastVisibleTweetIdBeforeLoad, videoLoadingManager.isInStartupPhase {
                        // During startup phase, just clear the captured tweet without scrolling
                        print("[TweetListView] Skipping scroll restoration during startup phase after error for tweet: \(lastTweetId)")
                        lastVisibleTweetIdBeforeLoad = nil
                    }
                }
                completion(false)
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
            print("[TweetListView] Server load failed: \(error)")
            
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
            
            // Update VideoLoadingManager with new tweet list (background task to avoid blocking)
            Task.detached(priority: .background) {
                let tweetIds = await MainActor.run { self.tweets.map { $0.mid } }
                await self.videoLoadingManager.updateTweetList(tweetIds)
            }

            currentPage = page

            // Set hasMoreTweets based on whether we got a full page
            // If we got a full page, there might be more tweets
            if tweetsFromServer.count >= pageSize {
                hasMoreTweets = true
                print("[TweetListView] Got full page (\(tweetsFromServer.count) >= \(pageSize)), setting hasMoreTweets=true")
            } else {
                hasMoreTweets = false
                print("[TweetListView] Got partial page (\(tweetsFromServer.count) < \(pageSize)), setting hasMoreTweets=false")
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
            print("[TweetListView] No valid tweets and partial page (\(tweetsFromServer.count) < \(pageSize)), setting hasMoreTweets=false")
            // Server returned fewer than pageSize tweets (or empty), so no more pages
            if page == 0 {
                if tweets.isEmpty {
                    // Update VideoLoadingManager with empty tweet list (background task to avoid blocking)
                    Task.detached(priority: .background) {
                        await self.videoLoadingManager.updateTweetList([])
                    }
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
            print("[TweetListView] Full page with all nil tweets, setting hasMoreTweets=true to continue searching")
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
        
        print("DEBUG: [TweetListView] Auto-loading more to fill screen (content: \(contentHeight), screen: \(screenHeight))")
        
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
