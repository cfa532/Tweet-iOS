@preconcurrency import Foundation
import SwiftUI
import UIKit

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

@available(iOS 16.0, *)
private struct ProfileNewTweetsBanner: View {
    let tweets: [Tweet]
    let onTap: () -> Void

    var body: some View {
        VStack {
            Button(action: onTap) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))

                    avatarCluster

                    Text(title)
                        .font(.system(size: 15, weight: .regular))
                }
                .foregroundColor(.white)
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .frame(height: 44)
                .background(Capsule().fill(Color.accentColor))
                .clipShape(Capsule())
                .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))

            Spacer()
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(!tweets.isEmpty)
        .animation(.easeOut(duration: 0.22), value: tweets.map(\.mid))
    }

    private var title: String {
        let count = tweets.count
        let format = count == 1
            ? NSLocalizedString("new_tweets_banner_one", comment: "New tweet floating pill title")
            : NSLocalizedString("new_tweets_banner_many", comment: "New tweets floating pill title")
        return String(format: format, count > 9 ? "9+" : "\(count)")
    }

    private var avatarCluster: some View {
        HStack(spacing: -9) {
            ForEach(Array(distinctAuthors.prefix(3).enumerated()), id: \.element.mid) { index, user in
                Avatar(user: user, size: 26)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
                    .zIndex(Double(3 - index))
            }
        }
        .padding(.horizontal, distinctAuthors.isEmpty ? 0 : 4)
    }

    private var distinctAuthors: [User] {
        var seen = Set<String>()
        return tweets.compactMap(\.author).filter { user in
            seen.insert(user.mid).inserted
        }
    }
}

@available(iOS 16.0, *)
struct TweetListView: View {
    // MARK: - Properties
    let title: String
    let tweetFetcher: @Sendable (UInt, UInt, Bool) async throws -> [Tweet?]
    let onForegroundRefresh: (() async -> Void)?
    let showTitle: Bool
    let header: (() -> AnyView)?
    let headerRefreshToken: Int
    let notifications: [TweetListNotification]
    let onScroll: ((CGFloat, CGFloat) -> Void)?  // (offset, delta)
    let onScrollStateChange: ((CGFloat, Bool, Bool) -> Void)?
    let leadingPadding: CGFloat  // Leading padding for cells
    let trailingPadding: CGFloat  // Trailing padding for cells
    let pinnedTweets: [Tweet]  // Pinned tweets for video coordination
    let feedIdentifier: String  // Unique identifier for persistent scroll position
    let preserveOrder: Bool  // If true, preserve server order instead of sorting by timestamp (for bookmarks/favorites)
    let allowDeleteAll: Bool  // If true, appUser can delete any tweet (main feed); otherwise only own tweets
    /// True on the main feed: prepended tweets must not move scroll position. False on
    /// bounded feeds (profile/list/bookmarks) where new tweets should scroll to the top.
    let preservesScrollPositionOnPrepend: Bool
    /// External signal used by profile route recovery to reload page 0 while preserving currently visible tweets.
    let externalRefreshToken: Int
    let profileResyncedTweets: [Tweet]
    let profileResyncedTweetsToken: Int
    let emptyStateText: LocalizedStringKey?
    private let pageSize: UInt = 5  // Smaller pages keep per-insert table work light

    // Navigation callbacks (passed through to UIKit cells)
    let onAvatarTap: ((User) -> Void)?
    let onTweetTap: ((Tweet) -> Void)?
    let onShowLogin: (() -> Void)?
    let onShowToast: ((String, Bool) -> Void)?

    @EnvironmentObject private var hproseInstance: HproseInstance
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
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
    @State private var hasReceivedScrollState = false
    @State private var isFeedAtTop: Bool = true
    @State private var isFeedScrollInteractionActive: Bool = false
    @State private var contentHeight: CGFloat = 0
    @State private var screenHeight: CGFloat = 0
    @State private var needsMoreContent: Bool = true
    @State private var startupTime: Date = Date()
    @State private var foregroundObserver: NSObjectProtocol?
    @State private var notificationObservers: [NSObjectProtocol] = []
    @State private var videoManagerUpdateTask: Task<Void, Never>? = nil
    @State private var hasAppearedOnce: Bool = false  // Track if view has appeared before (to detect navigation return)
    @State private var lastCleanupTime: Date = Date()
    @State private var didConfirmEmptyFromServer: Bool = false
    @State private var pendingProfileNewTweets: [Tweet] = []
    @State private var showProfileNewTweetsBanner = false
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
    
    /// Debounced memory maintenance for large feeds.
    private func scheduleMemoryMaintenance(delay: TimeInterval = 0) {
        // Cancel any pending update task
        videoManagerUpdateTask?.cancel()
        
        // Create new debounced task
        videoManagerUpdateTask = Task.detached(priority: .background) {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            
            // Check if task was cancelled
            guard !Task.isCancelled else { return }
            
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
                let activeTweetIds = await MainActor.run { Set(self.tweets.map { $0.mid }) }
                Tweet.cleanupOldInstances(activeTweetIds: activeTweetIds)
            }
        }
    }

    private func visibleTweetsExcludingDeleted(_ candidateTweets: [Tweet]) -> [Tweet] {
        candidateTweets.filter { !TweetDeletionRegistry.shared.isDeleted($0.mid) }
    }

    private func mergePaginatedTweets(_ paginatedTweets: [Tweet]) {
        if preserveOrder {
            tweets.appendTweetsPreservingOrder(paginatedTweets)
        } else {
            tweets.mergeTweets(paginatedTweets)
        }
        scheduleMemoryMaintenance(delay: 0.2)
    }

    private func applyCachedPaginationTweets(
        _ cachedTweets: [Tweet],
        responseCount: Int,
        page: UInt,
        pageSize: UInt
    ) {
        mergePaginatedTweets(cachedTweets)
        if responseCount >= pageSize {
            hasMoreTweets = true
        }
    }

    private func applyServerPaginationTweets(
        _ serverTweets: [Tweet],
        responseCount: Int,
        page: UInt,
        pageSize: UInt
    ) {
        mergePaginatedTweets(serverTweets)
        currentPage = page
        hasMoreTweets = responseCount >= pageSize
    }

    private var shouldUseProfileNewTweetsBanner: Bool {
        feedIdentifier.hasPrefix("profile_")
    }

    private var shouldRenderProfileNewTweetsImmediately: Bool {
        guard shouldUseProfileNewTweetsBanner else { return true }
        guard !isFeedScrollInteractionActive else { return false }
        if hasReceivedScrollState {
            return isFeedAtTop
        }
        return ScrollPositionManager.shared.getScrollPosition(for: feedIdentifier) == nil
    }

    private var visiblePendingProfileNewTweets: [Tweet] {
        let visibleTweetIds = Set(tweets.map(\.mid))
        return pendingProfileNewTweets.filter { tweet in
            isPendingProfileNewTweet(tweet, visibleTweetIds: visibleTweetIds)
        }
    }

    private func isNewerThanCurrentTop(_ tweet: Tweet) -> Bool {
        guard let topTweet = tweets.first else { return false }
        if tweet.timestamp == topTweet.timestamp {
            return tweet.mid > topTweet.mid
        }
        return tweet.timestamp > topTweet.timestamp
    }

    private func isPendingProfileNewTweet(_ tweet: Tweet, visibleTweetIds: Set<String>) -> Bool {
        !TweetDeletionRegistry.shared.isDeleted(tweet.mid)
            && !visibleTweetIds.contains(tweet.mid)
            && isNewerThanCurrentTop(tweet)
    }

    private func visibleProfileResyncedTweets(_ resyncedTweets: [Tweet]) -> [Tweet] {
        guard shouldUseProfileNewTweetsBanner else { return [] }

        let profileUserId = String(feedIdentifier.dropFirst("profile_".count))
        let pinnedTweetIds = Set(pinnedTweets.map(\.mid))
        return resyncedTweets.filter { tweet in
            tweet.authorId == profileUserId
                && !TweetDeletionRegistry.shared.isDeleted(tweet.mid)
                && (!(tweet.isPrivate ?? false) || tweet.authorId == hproseInstance.appUser.mid)
                && !pinnedTweetIds.contains(tweet.mid)
        }
    }

    private func applyProfileResyncedTweets(_ resyncedTweets: [Tweet]) {
        let visibleResyncedTweets = visibleProfileResyncedTweets(resyncedTweets)
        guard !visibleResyncedTweets.isEmpty else { return }

        let visibleTweetIds = Set(tweets.map(\.mid))
        let existingTweets = visibleResyncedTweets.filter { visibleTweetIds.contains($0.mid) }
        let newTopTweets = visibleResyncedTweets.filter { tweet in
            !visibleTweetIds.contains(tweet.mid) && (tweets.isEmpty || isNewerThanCurrentTop(tweet))
        }

        let renderableNewTweets = newTopTweets.isEmpty
            ? []
            : stageProfileNewTweetsBehindBannerIfNeeded(
                newTopTweets,
                reason: "profile resync"
            ).tweetsToRender
        let renderableTweets = existingTweets + renderableNewTweets

        guard !renderableTweets.isEmpty else { return }
        tweets.mergeTweets(renderableTweets)
        scheduleMemoryMaintenance(delay: 0.2)
    }

    @discardableResult
    private func stageProfileNewTweetsBehindBannerIfNeeded(
        _ incomingTweets: [Tweet],
        reason: String
    ) -> (tweetsToRender: [Tweet], deferredTweetIds: Set<String>) {
        guard shouldUseProfileNewTweetsBanner,
              !tweets.isEmpty,
              !shouldRenderProfileNewTweetsImmediately else {
            return (incomingTweets, [])
        }

        var seenTweetIds = Set<String>()
        let uniqueIncomingTweets = incomingTweets.filter { tweet in
            seenTweetIds.insert(tweet.mid).inserted
        }

        let visibleTweetIds = Set(tweets.map(\.mid))
        let newTweets = uniqueIncomingTweets.filter { tweet in
            isPendingProfileNewTweet(tweet, visibleTweetIds: visibleTweetIds)
        }
        let snapshot = newTweets.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.mid > rhs.mid
            }
            return lhs.timestamp > rhs.timestamp
        }

        let combinedPendingTweets = pendingProfileNewTweets + snapshot
        var seenPendingTweetIds = Set<String>()
        pendingProfileNewTweets = combinedPendingTweets
            .filter { tweet in seenPendingTweetIds.insert(tweet.mid).inserted }
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.mid > rhs.mid
                }
                return lhs.timestamp > rhs.timestamp
            }
        showProfileNewTweetsBanner = !pendingProfileNewTweets.isEmpty

        let deferredTweetIds = Set(snapshot.map(\.mid))
        guard !deferredTweetIds.isEmpty else {
            print("DEBUG: [TweetListView] No profile new tweets for banner during \(reason), feed=\(feedIdentifier)")
            return (incomingTweets, [])
        }

        print("DEBUG: [TweetListView] Deferred \(deferredTweetIds.count) profile tweet(s) behind banner during \(reason), feed=\(feedIdentifier)")
        return (
            incomingTweets.filter { !deferredTweetIds.contains($0.mid) },
            deferredTweetIds
        )
    }

    private func applyPendingProfileNewTweets() {
        let pendingTweets = visiblePendingProfileNewTweets
        guard !pendingTweets.isEmpty else {
            pendingProfileNewTweets.removeAll()
            showProfileNewTweetsBanner = false
            return
        }

        let firstNewTweetId = pendingTweets.first?.mid
        tweets.mergeTweets(pendingTweets)
        pendingProfileNewTweets.removeAll()
        showProfileNewTweetsBanner = false
        currentPage = 0
        hasMoreTweets = true
        scheduleMemoryMaintenance(delay: 0.2)
        DispatchQueue.main.async {
            var userInfo: [String: Any] = [
                "feedIdentifier": feedIdentifier,
                "scrollTarget": "tweetId"
            ]
            if let firstNewTweetId {
                userInfo["targetTweetId"] = firstNewTweetId
            }
            NotificationCenter.default.post(
                name: .scrollToTop,
                object: nil,
                userInfo: userInfo
            )
        }
        print("DEBUG: [TweetListView] Applied \(pendingTweets.count) pending profile tweet(s), feed=\(feedIdentifier)")
    }

    private func pendingBackgroundResumeSnapshotForInitialLoad() -> BackgroundFeedResumeSnapshot? {
        guard feedIdentifier == "mainFeed",
              !hproseInstance.appUser.isGuest else {
            return nil
        }

        return BackgroundResumeStateStore.shared.snapshot(
            feedIdentifier: feedIdentifier,
            appUserId: hproseInstance.appUser.mid
        )
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
        onForegroundRefresh: (() async -> Void)? = nil,
        showTitle: Bool = true,
        notifications: [TweetListNotification]? = nil,
        onScroll: ((CGFloat, CGFloat) -> Void)? = nil,
        onScrollStateChange: ((CGFloat, Bool, Bool) -> Void)? = nil,
        leadingPadding: CGFloat = 8,
        trailingPadding: CGFloat = 8,
        pinnedTweets: [Tweet] = [],
        feedIdentifier: String = "mainFeed",
        preserveOrder: Bool = false,
        allowDeleteAll: Bool = false,
        preservesScrollPositionOnPrepend: Bool = false,
        externalRefreshToken: Int = 0,
        profileResyncedTweets: [Tweet] = [],
        profileResyncedTweetsToken: Int = 0,
        emptyStateText: LocalizedStringKey? = nil,
        header: (() -> AnyView)? = nil,
        headerRefreshToken: Int = 0,
        onRefreshExtra: (() async -> Void)? = nil,
        onAvatarTap: ((User) -> Void)? = nil,
        onTweetTap: ((Tweet) -> Void)? = nil,
        onShowLogin: (() -> Void)? = nil,
        onShowToast: ((String, Bool) -> Void)? = nil
    ) {
        self.title = title
        self._tweets = tweets
        self.tweetFetcher = tweetFetcher
        self.onForegroundRefresh = onForegroundRefresh
        self.showTitle = showTitle
        self.onScroll = onScroll
        self.onScrollStateChange = onScrollStateChange
        self.leadingPadding = leadingPadding
        self.trailingPadding = trailingPadding
        self.pinnedTweets = pinnedTweets
        self.feedIdentifier = feedIdentifier
        self.preserveOrder = preserveOrder
        self.allowDeleteAll = allowDeleteAll
        self.preservesScrollPositionOnPrepend = preservesScrollPositionOnPrepend
        self.externalRefreshToken = externalRefreshToken
        self.profileResyncedTweets = profileResyncedTweets
        self.profileResyncedTweetsToken = profileResyncedTweetsToken
        self.emptyStateText = emptyStateText
        self.header = header
        self.headerRefreshToken = headerRefreshToken
        self.onRefreshExtra = onRefreshExtra
        self.onAvatarTap = onAvatarTap
        self.onTweetTap = onTweetTap
        self.onShowLogin = onShowLogin
        self.onShowToast = onShowToast
        // Main feed uses shared coordinator; other feeds get independent instances
        // to prevent cross-feed interference (separate allVideos, visibleTweetIds, tableView, etc.)
        let coordinator = (feedIdentifier == "mainFeed")
            ? VideoPlaybackCoordinator.shared
            : VideoPlaybackCoordinator()
        coordinator.directionalPlayerPreloadCount = FeedPlaybackTuning.directionalVideoPreloadCount
        self.videoCoordinator = coordinator
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

    /// Extracted so the body stays simple enough for the SwiftUI type-checker
    /// (the TweetTableView initializer has many parameters).
    private var feedTableView: TweetTableView {
        TweetTableView(
            tweets: $tweets,
            colorScheme: colorScheme,
            isDarkMode: themeManager.isDarkMode,
            header: header,
            headerRefreshToken: headerRefreshToken,
            hproseInstance: hproseInstance,
            hasMoreTweets: $hasMoreTweets,
            isLoading: isLoading,
            isLoadingMore: isLoadingMore,
            preservesScrollPositionOnPrepend: preservesScrollPositionOnPrepend,
            loadMoreTweets: { forceLoad in loadMoreTweets(forceLoad: forceLoad) },
            onRefresh: {
                await refreshTweetsFromUserPull()
                await onRefreshExtra?()
            },
            onScroll: onScroll,
            onScrollStateChange: { offset, isAtTop, isInteracting in
                DispatchQueue.main.async {
                    if !hasReceivedScrollState {
                        hasReceivedScrollState = true
                    }
                    if isFeedAtTop != isAtTop {
                        isFeedAtTop = isAtTop
                    }
                    if isFeedScrollInteractionActive != isInteracting {
                        isFeedScrollInteractionActive = isInteracting
                    }
                    onScrollStateChange?(offset, isAtTop, isInteracting)
                }
            },
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
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // UIKit TABLE VIEW — pure UIKit cells, no UIHostingController per cell
                feedTableView
                .onAppear {
                    screenHeight = geometry.size.height
                }
                .background(XTheme.backgroundColor)

            if isLoading && tweets.isEmpty {
                ProgressView()
                    .scaleEffect(2.0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(header == nil ? XTheme.backgroundColor : Color.clear)
                    .allowsHitTesting(false)
            }

            if let emptyStateText,
               didConfirmEmptyFromServer,
               tweets.isEmpty,
               pinnedTweets.isEmpty,
               !isLoading,
               !isLoadingMore {
                VStack {
                    Spacer()
                    Text(emptyStateText)
                        .font(.subheadline)
                        .foregroundColor(XTheme.secondaryTextColor)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }

            if showToast {
                VStack {
                    Spacer()
                    ToastView(message: toastMessage, type: toastType)
                        .padding(.bottom, 40)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: showToast)
                .allowsHitTesting(false)
            }

            if showProfileNewTweetsBanner && !visiblePendingProfileNewTweets.isEmpty {
                ProfileNewTweetsBanner(
                    tweets: visiblePendingProfileNewTweets,
                    onTap: applyPendingProfileNewTweets
                )
                .zIndex(1000)
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
                    didConfirmEmptyFromServer = false
                }
            }
        }  // Close GeometryReader
        .onReceive(NotificationCenter.default.publisher(for: .userDidLogin)) { _ in
            Task {
                await refreshTweets()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appUserReady)) { _ in
            // Cold start guard: if initial page loaded before initialization finished
            // (or before any cache existed), force a retry once appUser/baseUrl is ready.
            Task {
                print("🚀 [INIT RETRY] .appUserReady received for feed=\(feedIdentifier), tweets=\(tweets.count), isLoading=\(isLoading), isLoadingMore=\(isLoadingMore)")
                var waitCount = 0
                while waitCount < 20 && (isLoading || isLoadingMore) {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    waitCount += 1
                }
                if waitCount > 0 {
                    print("⏳ [INIT RETRY] Waited \(waitCount * 100)ms for loading to settle, feed=\(feedIdentifier)")
                }
                guard UIApplication.shared.applicationState == .active else {
                    print("🚀 [INIT RETRY] Deferred retry because app is not active, feed=\(feedIdentifier)")
                    return
                }
                guard tweets.isEmpty else {
                    print("✅ [INIT RETRY] Skipped retry because feed already has \(tweets.count) tweet(s), feed=\(feedIdentifier)")
                    return
                }
                print("🔄 [INIT RETRY] Triggering refreshTweets() after init completion, feed=\(feedIdentifier)")
                await refreshTweets()
            }
        }
        .onChange(of: externalRefreshToken) { _, _ in
            Task {
                await reloadFromServerAfterRouteChange()
            }
        }
        .onChange(of: profileResyncedTweetsToken) { _, _ in
            applyProfileResyncedTweets(profileResyncedTweets)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            videoCoordinator.directionalPlayerPreloadCount = FeedPlaybackTuning.directionalVideoPreloadCount

            // Set up foreground observer to fetch new tweets when app returns
            setupForegroundObserver()
            // Set up notification observers
            setupNotificationObservers()

            // Only notify feedViewDidAppear when RETURNING from navigation, not on initial load
            // This prevents unnecessary video stop/restart cycles that cause flickering
            if hasAppearedOnce {
                // Returning from navigation - notify to restart video playback
                // Notify promptly so the UIKit viewWillAppear fallback can stand down.
                // TweetTableViewController applies the actual settle delay before resuming.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NotificationCenter.default.post(name: .feedViewDidAppear, object: nil,
                                                    userInfo: ["feedIdentifier": feedIdentifier])
                }
                // If returning from navigation and feed is empty (e.g. guest user's
                // initial load completed before server was ready), reload now.
                if tweets.isEmpty && initialLoadComplete {
                    Task {
                        await refreshTweets()
                    }
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
                        if name == .newTweetCreated, shouldUseProfileNewTweetsBanner {
                            let stagingResult = stageProfileNewTweetsBehindBannerIfNeeded([tweet], reason: "newTweetCreated notification")
                            if !stagingResult.deferredTweetIds.contains(tweet.mid) {
                                notification.action(tweet)
                            }
                            continue
                        }
                        notification.action(tweet)
                    }
                    // Special case: tweetId notifications send String instead of Tweet
                    if notification.key == "tweetId", let tweetId = notif.userInfo?[notification.key] as? String {
                        // Find tweet once for efficiency (avoid multiple O(n) searches)
                        let tweetIndex = tweetsBinding.wrappedValue.firstIndex(where: { $0.mid == tweetId })
                        
                        if notification.name == .tweetDeleted {
                            TweetDeletionRegistry.shared.markDeleted(tweetId)
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
            TweetDeletionRegistry.shared.unmarkDeleted(tweetId)
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
        // Main feed foreground checks are handled centrally by AppDelegate so they
        // can queue the shared new-tweets banner instead of merging directly.
        guard feedIdentifier != "mainFeed" else { return }
        guard foregroundObserver == nil else { return }
        
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
    }
    
    /// Fetch new tweets when app comes to foreground
    /// This refreshes the first page and routes prepended tweets through the tap-to-load banner.
    private func fetchNewTweetsOnForeground() async {
        // Don't fetch if already loading or refreshing
        guard !isLoading && !isLoadingMore else {
            print("📱 [FOREGROUND] Skipping - already loading")
            return
        }

        // After a long background the video proxy needs to restart before this fetch triggers
        // rebuildVideoListAndRefreshVisibility. Racing the two paths causes the coordinator to
        // rebuild allVideos mid-recovery, which can leave the primary video stuck unplayed.
        // Wait up to 2s for video infrastructure to be ready before issuing the network call.
        if !AppDelegate.isVideoInfrastructureReady {
            var waited = 0
            while !AppDelegate.isVideoInfrastructureReady && waited < 20 {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                waited += 1
            }
            print("📱 [FOREGROUND] Infrastructure wait: \(waited * 100)ms (\(AppDelegate.isVideoInfrastructureReady ? "ready" : "timed out"))")
        }

        print("📱 [FOREGROUND] Fetching fresh tweets from server...")

        if let onForegroundRefresh {
            await onForegroundRefresh()
            return
        }
        
        do {
            // Fetch fresh tweets from server (page 0, no cache)
            let freshTweets = try await tweetFetcher(0, pageSize, false)
            let validTweets = visibleTweetsExcludingDeleted(freshTweets.compactMap { $0 })
            
            await MainActor.run {
                if !validTweets.isEmpty {
                    let renderableTweets: [Tweet]
                    if shouldUseProfileNewTweetsBanner {
                        renderableTweets = stageProfileNewTweetsBehindBannerIfNeeded(
                            validTweets,
                            reason: "foreground refresh"
                        ).tweetsToRender
                    } else {
                        renderableTweets = validTweets
                    }

                    // For preserveOrder lists (bookmarks/favorites), append in server order
                    // For other lists, merge with timestamp sorting
                    if !renderableTweets.isEmpty {
                        if preserveOrder {
                            tweets.appendTweetsPreservingOrder(renderableTweets)
                        } else {
                            tweets.mergeTweets(renderableTweets)
                        }
                    }
                    currentPage = 0
                    hasMoreTweets = freshTweets.count >= pageSize

                    // Update video manager with debouncing
                    scheduleMemoryMaintenance(delay: 0.2)

                    print("📱 [FOREGROUND] ✅ Processed \(validTweets.count) fresh tweets")
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
        didConfirmEmptyFromServer = false
        // First paint is cache-first. Do not show the blank loading spinner until
        // the first cache probe misses; otherwise a valid cached profile briefly
        // looks blocked by network even though cached rows are about to render.
        if tweets.isEmpty {
            isLoading = false
        }
        let page: UInt = 0
        var didLoadCachedContent = false

        do {
            // Step 1: Load the first cached page for the first paint. This mirrors
            // Android: if the requested cached page has anything renderable, show it
            // immediately and let server refresh / scroll pagination handle the rest.
            let tweetsFromCache = try await tweetFetcher(page, pageSize, true)
            let validPage = visibleTweetsExcludingDeleted(tweetsFromCache.compactMap { $0 })
            let resumeSnapshot = pendingBackgroundResumeSnapshotForInitialLoad()

            if let resumeSnapshot,
               let targetTweetId = resumeSnapshot.anchorTweetId ?? resumeSnapshot.topTweetId,
               !validPage.contains(where: { $0.mid == targetTweetId }) {
                BackgroundResumeStateStore.shared.clear(reason: "saved tweet not in first cached page")
                print("[BackgroundResume] Skipped deep cached resume search for saved tweet \(targetTweetId)")
            }

            let hasCachedContent = !validPage.isEmpty
            didLoadCachedContent = hasCachedContent

            if hasCachedContent {
                await MainActor.run {
                    // Use direct assignment for page 0 so cached order is not disturbed.
                    tweets = validPage
                    currentPage = page

                    hasMoreTweets = true  // Server may have more

                    // Schedule memory maintenance for the first visible cache page.
                    scheduleMemoryMaintenance(delay: 0.2)

                    // Don't mark as loaded yet - wait for server fetch to complete
                    // This prevents "No tweet yet" from showing prematurely if cached tweets
                    // are filtered out (e.g., pinned tweets) before server fetch completes
                    isLoading = false
                    initialLoadComplete = false  // Keep false until server fetch completes
                    didConfirmEmptyFromServer = false
                }

                await Task.yield()
            } else {
                // No cached content - keep showing loading spinner and wait for server
                await MainActor.run {
                    isLoading = true
                    initialLoadComplete = false
                }
            }

            // End startup phase after 3 seconds
            Task.detached(priority: .background) {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                await videoLoadingManager.endStartupPhase()
            }
        } catch {
            await MainActor.run {
                if tweets.isEmpty {
                    isLoading = true
                    initialLoadComplete = false
                }
                didConfirmEmptyFromServer = false
            }
        }
        
        if feedIdentifier == "mainFeed",
           didLoadCachedContent,
           UIApplication.shared.applicationState != .active {
            await MainActor.run {
                isLoading = false
                initialLoadComplete = true
            }
            print("📋 [CACHE LOAD] Deferred main feed server refresh while app is not active; foreground refresh will queue banner")
            return
        }

        // CRITICAL: Let UI render cached tweets BEFORE fetching from server
        // If we await server fetch in same function, SwiftUI batches updates and only renders once
        // By launching server fetch in a detached task, cached tweets render immediately
        // and the blocking backend path cannot inherit SwiftUI's main actor.
        Task.detached(priority: .utility) {
            // Step 2: Load from server to get the most up-to-date data (in background)
            // Additional pages are loaded automatically when user scrolls near the bottom
            await loadFromServer(page: page, pageSize: pageSize) { _ in }
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
        didConfirmEmptyFromServer = false
        currentPage = 0

        // DON'T clear existing tweets - keep them while refreshing for better UX
        // await MainActor.run {
        //     tweets.removeAll()
        // }

        await loadFromServer(page: 0, pageSize: pageSize) { _ in }
    }

    private func refreshTweetsFromUserPull() async {
        guard initialLoadComplete, !isLoading, !isLoadingMore else {
            print("🔄 [PULL REFRESH] Skipped while feed is still loading, feed=\(feedIdentifier)")
            return
        }

        isLoading = true
        initialLoadComplete = false
        didConfirmEmptyFromServer = false
        currentPage = 0

        do {
            let cachedTweets = try await tweetFetcher(0, pageSize, true)
            let visibleCachedTweets = visibleTweetsExcludingDeleted(cachedTweets.compactMap { $0 })

            if !visibleCachedTweets.isEmpty {
                if preserveOrder {
                    tweets = visibleCachedTweets
                } else {
                    tweets.mergeTweets(visibleCachedTweets)
                }
                hasMoreTweets = cachedTweets.count >= pageSize
                scheduleMemoryMaintenance(delay: 0.2)
                print("🔄 [PULL REFRESH] Rendered \(visibleCachedTweets.count) cached tweet(s) before server refresh, feed=\(feedIdentifier)")
            }
        } catch {
            print("🔄 [PULL REFRESH] Cache refresh failed before server refresh, feed=\(feedIdentifier): \(error)")
        }

        await loadFromServer(page: 0, pageSize: pageSize) { _ in }
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
                        let visibleCachedTweets = visibleTweetsExcludingDeleted(tweetsFromCache.compactMap { $0 })
                        applyCachedPaginationTweets(
                            visibleCachedTweets,
                            responseCount: tweetsFromCache.count,
                            page: page,
                            pageSize: pageSize
                        )
                    }
                    print("✅ [PAGINATION] Loaded \(tweetsFromCache.count) tweets from cache for page \(page)")
                }
            } catch {
                // Cache fetch failed - not critical, we'll try server next
                print("⚠️ [PAGINATION] Cache fetch failed for page \(page): \(error), will try server")
            }

            // CRITICAL: Let UI render cached tweets BEFORE continuing with server fetch
            // By spawning the rest in a detached task, cached tweets render immediately
            // without resuming backend work on SwiftUI's main actor.
            Task.detached(priority: .utility) {
                // Step 2: Load from server to get fresh data (always try, even if cache failed)
                // Keep isLoadingMore = true until server responds so spinner stays visible
                await loadFromServer(page: page, pageSize: pageSize, completion: completion)

                // Now that server has responded, clear loading state
                await MainActor.run {
                    isLoadingMore = false
                    loadingStartTime = nil
                }
            }
        }
    }
    
    // MARK: - Server Loading (No Retry)
    private func loadFromServer(page: UInt, pageSize: UInt, completion: @escaping (Bool) -> Void) async {
        var pageToLoad = page
        var skippedEmptyFullPages = 0
        let maxEmptyFullPagesToSkip = 200
        var foundValidTweets = false
        var lastResponseSize: Int?

        while true {
            do {
                let tweetsFromServer = try await tweetFetcher(pageToLoad, pageSize, false)
                let validServerTweets = visibleTweetsExcludingDeleted(tweetsFromServer.compactMap { $0 })
                let shouldLoadNextPage = validServerTweets.isEmpty && tweetsFromServer.count >= pageSize
                foundValidTweets = foundValidTweets || !validServerTweets.isEmpty
                lastResponseSize = tweetsFromServer.count

                await MainActor.run {
                    updateTweetsWithServerData(
                        validServerTweets: validServerTweets,
                        tweetsFromServer: tweetsFromServer,
                        page: pageToLoad,
                        pageSize: pageSize
                    )
                }

                guard shouldLoadNextPage else {
                    break
                }

                skippedEmptyFullPages += 1
                if skippedEmptyFullPages >= maxEmptyFullPagesToSkip {
                    print("⚠️ [PAGINATION] Stopped auto-skipping after \(skippedEmptyFullPages) full empty pages from page \(page)")
                    await MainActor.run {
                        if page == 0 {
                            isLoading = false
                            initialLoadComplete = true
                            didConfirmEmptyFromServer = false
                        }
                    }
                    break
                }

                pageToLoad += 1
                print("📊 [PAGINATION] Auto-loading next page \(pageToLoad) after full empty page")
            } catch {
                await MainActor.run {
                    // Mark initial load as complete even on error for page 0
                    if page == 0 {
                        isLoading = false
                        initialLoadComplete = true
                        didConfirmEmptyFromServer = false
                    }
                    // Don't modify tweets array - keep cached data intact
                }
                break
            }
        }

        await MainActor.run {
            if page == 0 {
                isLoading = false
                initialLoadComplete = true

                if foundValidTweets {
                    didConfirmEmptyFromServer = false
                } else if let lastResponseSize, lastResponseSize < pageSize {
                    if tweets.isEmpty || emptyStateText != nil {
                        tweets = []
                        scheduleMemoryMaintenance()
                        didConfirmEmptyFromServer = true
                    } else {
                        didConfirmEmptyFromServer = false
                    }
                }
            }
        }
        completion(true)
    }

    private func reloadFromServerAfterRouteChange() async {
        await MainActor.run {
            if tweets.isEmpty {
                isLoading = true
                initialLoadComplete = false
                didConfirmEmptyFromServer = false
            }
        }
        await loadFromServer(page: 0, pageSize: pageSize) { _ in }
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
        let renderableServerTweets: [Tweet]
        if page == 0 {
            renderableServerTweets = stageProfileNewTweetsBehindBannerIfNeeded(
                validServerTweets,
                reason: "server page 0 refresh"
            ).tweetsToRender
        } else {
            renderableServerTweets = validServerTweets
        }
        let hasValidTweet = !renderableServerTweets.isEmpty

        // BRANCH 1: Got valid tweets - check response size
        if hasValidTweet {
            didConfirmEmptyFromServer = false
            // For preserveOrder lists (bookmarks/favorites), page 0 should always REPLACE
            // to ensure correct server order (sorted by bookmark/favorite time)
            if page == 0 && preserveOrder {
                tweets = renderableServerTweets
                currentPage = page
                hasMoreTweets = tweetsFromServer.count >= pageSize
                scheduleMemoryMaintenance(delay: 0.2)
            } else if page == 0 && tweets.isEmpty {
                tweets = renderableServerTweets
                currentPage = page
                hasMoreTweets = tweetsFromServer.count >= pageSize
                scheduleMemoryMaintenance(delay: 0.2)
            } else {
                // For preserveOrder lists (bookmarks/favorites), append in server order
                // For other lists, merge with timestamp sorting
                applyServerPaginationTweets(
                    renderableServerTweets,
                    responseCount: tweetsFromServer.count,
                    page: page,
                    pageSize: pageSize
                )
            }

            print("📊 [PAGINATION] Page \(page): got \(tweetsFromServer.count) entries (\(validServerTweets.count) valid), hasMoreTweets = \(hasMoreTweets)")

            // Mark initial load as complete for page 0 only if we got valid tweets
            if page == 0 {
                isLoading = false
                initialLoadComplete = true
            }

        // BRANCH 1b: Valid profile page contained only new top tweets deferred behind the banner.
        } else if !validServerTweets.isEmpty {
            didConfirmEmptyFromServer = false
            currentPage = page
            hasMoreTweets = tweetsFromServer.count >= pageSize
            if page == 0 {
                isLoading = false
                initialLoadComplete = true
            }
            print("📊 [PAGINATION] Page \(page): deferred \(validServerTweets.count) profile entries behind banner, hasMoreTweets = \(hasMoreTweets)")

        // BRANCH 2: No valid tweets AND partial page - server depleted
        } else if tweetsFromServer.count < pageSize {
            // Partial page means server ran out of bookmark/favorite entries
            hasMoreTweets = false
            print("📊 [PAGINATION] Page \(page): got \(tweetsFromServer.count) entries (0 valid), PARTIAL PAGE - no more tweets")
            if page == 0 && (tweets.isEmpty || emptyStateText != nil) {
                // Server confirmed an empty first page. Profile lists opt into
                // clearing stale cached rows so the empty state can be shown.
                tweets = []
                scheduleMemoryMaintenance()
                isLoading = false
                initialLoadComplete = true
                didConfirmEmptyFromServer = true
            } else if page == 0 {
                // Have cached tweets but server returned empty — keep cached content visible.
                // Either network failed (fetcher should have thrown) or server is temporarily empty.
                isLoading = false
                initialLoadComplete = true
                didConfirmEmptyFromServer = false
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
