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
    let onScroll: ((CGFloat, CGFloat) -> Void)?  // (offset, delta)
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
    @State private var loadingStartTime: Date? = nil
    @State private var scrollAnchorId: String? = nil  // Track scroll position
    
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
    init(
        title: String,
        tweets: Binding<[Tweet]>,
        tweetFetcher: @escaping @Sendable (UInt, UInt, Bool, Bool) async throws -> [Tweet?],
        showTitle: Bool = true,
        shouldCacheServerTweets: Bool = false,
        notifications: [TweetListNotification]? = nil,
        onScroll: ((CGFloat, CGFloat) -> Void)? = nil,  // (offset, delta)
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
               .safeAreaInset(edge: .top) {
                   Color.clear.frame(height: 0)
               }
               .onScrollGeometryChange(for: CGFloat.self) { geometry in
                   geometry.contentOffset.y
               } action: { oldValue, newValue in
                   let delta = newValue - oldValue
                   onScroll?(newValue, delta)  // Pass both offset and delta
               }
               .onAppear {
                   onScroll?(0, 0)  // Pass both offset and delta
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
            let tweetsFromCache = try await tweetFetcher(page, pageSize, true, false)
            let validCachedTweets = tweetsFromCache.compactMap { $0 }
            
            let hasCachedContent = !validCachedTweets.isEmpty
            
            await MainActor.run {
                if hasCachedContent {
                    // If we have cached content, show it immediately without loading spinner
                    // Use direct assignment (not merge) to avoid re-sorting cached content
                    tweets = validCachedTweets
                    
                    // Update VideoLoadingManager with new tweet list
                    let tweetIds = tweets.map { $0.mid }
                    videoLoadingManager.updateTweetList(tweetIds)
                    
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
            
            // Step 2: Load from server to get the most up-to-date data
            if hasCachedContent {
                // If we have cache, load server data but wait for it to complete
                // before marking as loaded (to prevent premature empty state)
                await loadFromServer(page: page, pageSize: pageSize) { _ in
                    // Server load completed - initialLoadComplete will be set in loadFromServer
                }
            } else {
                // No cache - wait for server load to complete before marking as loaded
                await loadFromServer(page: page, pageSize: pageSize) { _ in
                    // Server load completed
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
            errorMessage = ErrorMessageHelper.userFriendlyMessage(from: error)
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
                // Load second page after 1.5 seconds to prevent scroll jumpiness
                // Reduced from 3s for better responsiveness while still allowing UI to settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
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
            // Record loading start time
            let startTime = Date()
            
            await MainActor.run {
                isLoadingMore = true
                loadingStartTime = startTime
            }
            
            do {
                // Step 1: Load from cache first for instant UX
                let tweetsFromCache = try await tweetFetcher(page, pageSize, true, false)
                
                // Calculate elapsed time
                let elapsedTime = Date().timeIntervalSince(startTime)
                let remainingTime = max(0, minimumLoadingDuration - elapsedTime)
                
                // Wait for minimum duration if needed
                if remainingTime > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingTime * 1_000_000_000))
                }
                
                await MainActor.run {
                    tweets.mergeTweets(tweetsFromCache.compactMap { $0 })
                    
                    // Update VideoLoadingManager with new tweet list
                    let tweetIds = tweets.map { $0.mid }
                    videoLoadingManager.updateTweetList(tweetIds)
                    
                    // Clear loading state after minimum duration
                    isLoadingMore = false
                    loadingStartTime = nil
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
                // Capture scroll position before updating content
                if !tweets.isEmpty {
                    // Save the first visible tweet to maintain scroll position
                    scrollAnchorId = tweets.first?.mid
                }
                
                // Update tweets with server data (existing mergeTweets already preserves cached tweets for failed IDs)
                if hasValidTweet {
                    if page == 0 {
                        // For first page, MERGE instead of replace to prevent scroll jumps
                        // Only replace if we have NO cached content
                        if tweets.isEmpty {
                            tweets = validServerTweets
                        } else {
                            // Use mergeTweetsSmoothly to prevent layout shifts when updating cached content
                            tweets.mergeTweetsSmoothly(validServerTweets)
                        }
                    } else {
                        // For subsequent pages, use smooth merge to avoid re-sorting
                        tweets.mergeTweetsSmoothly(validServerTweets)
                    }
                    
                    // Update VideoLoadingManager with new tweet list
                    let tweetIds = tweets.map { $0.mid }
                    videoLoadingManager.updateTweetList(tweetIds)
                    
                    currentPage = page
                    
                    // Mark initial load as complete for page 0 only if we got valid tweets
                    if page == 0 {
                        isLoading = false
                        initialLoadComplete = true
                    }
                } else if tweetsFromServer.count < pageSize {
                    hasMoreTweets = false
                    // Server returned fewer than pageSize tweets (or empty), so no more pages
                    // Update VideoLoadingManager even when no tweets
                    if page == 0 {
                        if tweets.isEmpty {
                            videoLoadingManager.updateTweetList([])
                            // Only mark as complete if we have no tweets at all (no cache, no server)
                            isLoading = false
                            initialLoadComplete = true
                        } else {
                            // We have cached tweets, so mark as complete (server confirmed no more pages)
                            isLoading = false
                            initialLoadComplete = true
                        }
                    }
                } else {
                    // All tweets are nil but we got a full page, continue to next page
                    currentPage = page
                    // Don't mark as complete yet - keep trying next pages
                    // Don't call loadMoreTweets recursively here, let the normal flow continue
                }
                
                // Clear scroll anchor after a brief delay to allow layout to settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    scrollAnchorId = nil
                }
            }
            
        } catch {
            print("[TweetListView] Server load failed: \(error)")
            
            await MainActor.run {
                errorMessage = "Unable to load fresh content. Showing cached data."
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
                // Show tweets
                // Small spacer to maintain layout stability
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 1)
                
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
