//
//  TweetTableViewController.swift
//  Tweet
//
//  UIKit-based tweet list to replace SwiftUI LazyVStack
//  Eliminates 2.5s GraphHost.flushTransactions() hang
//
import UIKit
import SwiftUI
import Combine
import Darwin

/// EXPERIMENT (not shipped): let Auto Layout size every row instead of computing the
/// height deterministically — the closest UIKit analogue to Compose's `LazyColumn`, which
/// the Android client uses and which needs no height calculation at all.
///
/// Enable with TWEET_SELF_SIZING=1. The point is to find out whether the deterministic
/// height calculator is earning its keep, or whether UIKit can be trusted to measure.
enum FeedLayoutMode {
    nonisolated(unsafe) static let selfSizing =
        ProcessInfo.processInfo.environment["TWEET_SELF_SIZING"] != nil
}

struct BackgroundFeedResumeSnapshot: Codable {
    let feedIdentifier: String
    let appUserId: String
    let contentOffsetY: CGFloat
    let topTweetId: String?
    let topTweetOffsetY: CGFloat
    let anchorTweetId: String?
    let anchorTweetOffsetY: CGFloat?
    let anchorViewportY: CGFloat?
    let createdAt: Date
}

final class BackgroundResumeStateStore: @unchecked Sendable {
    static let shared = BackgroundResumeStateStore()

    private let snapshotKey = "backgroundFeedResumeSnapshot"
    private let maxSnapshotAge: TimeInterval = 24 * 60 * 60

    private init() {}

    func save(_ snapshot: BackgroundFeedResumeSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: snapshotKey)
        print("[BackgroundResume] Saved snapshot for feed=\(snapshot.feedIdentifier), topTweet=\(snapshot.topTweetId ?? "none")")
    }

    func snapshot(feedIdentifier: String, appUserId: String) -> BackgroundFeedResumeSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(BackgroundFeedResumeSnapshot.self, from: data) else {
            return nil
        }

        guard Date().timeIntervalSince(snapshot.createdAt) <= maxSnapshotAge else {
            clear(reason: "expired snapshot")
            return nil
        }

        guard snapshot.feedIdentifier == feedIdentifier,
              snapshot.appUserId == appUserId else {
            return nil
        }

        return snapshot
    }

    func hasSnapshot(feedIdentifier: String, appUserId: String) -> Bool {
        snapshot(feedIdentifier: feedIdentifier, appUserId: appUserId) != nil
    }

    func clear(reason: String) {
        if UserDefaults.standard.object(forKey: snapshotKey) != nil {
            UserDefaults.standard.removeObject(forKey: snapshotKey)
            print("[BackgroundResume] Cleared snapshot: \(reason)")
        }
    }
}

/// In-memory scroll position storage across view controller deallocation within the same session.
/// Does NOT persist to disk — on app restart the feed starts from the top.
@MainActor
class ScrollPositionManager {
    static let shared = ScrollPositionManager()
    private var scrollPositions: [String: CGFloat] = [:]

    private init() {}

    func saveScrollPosition(_ position: CGFloat, for identifier: String) {
        scrollPositions[identifier] = position
    }

    func getScrollPosition(for identifier: String) -> CGFloat? {
        scrollPositions[identifier]
    }

    func clearScrollPosition(for identifier: String) {
        scrollPositions.removeValue(forKey: identifier)
    }
}

class TweetTableViewController: UITableViewController {
    
    // Data
    private var tweets: [Tweet] = []
    private var pinnedTweets: [Tweet] = []  // Pinned tweets rendered as first N rows
    private var hasMoreTweets: Bool = true
    private var canShowNoMoreTweetsMessage: Bool = false
    private var isLoadingMore: Bool = false
    
    // Bottom pull-to-load state (manual pull past bottom edge)
    private var isBottomPullActive: Bool = false
    private var bottomPullThreshold: CGFloat = 50
    // Trigger load-more when this many regular rows remain below the viewport (= 1 page).
    private let loadMoreTriggerRows = 10
    // Match Android's profile opening policy: page beyond page 0 only when fewer
    // than five regular tweets are available to render. User-driven scrolling
    // continues to use the normal one-page runway below.
    private let minimumProfileTweetsForInitialFill = 5
    private var autoLoadMoreCountDuringCurrentScrollGesture: Int = 0
    private let maxAutoLoadMorePerScrollGesture: Int = 2
    /// Row count when the last automatic page was requested. A page that comes back with
    /// nothing the feed did not already have must not chain straight into another one —
    /// see `triggerAutoLoadMoreIfNeeded`.
    private var rowCountAtLastAutoLoad: Int?
    
    // Spinner timing
    private var isLoading: Bool = false
    private var loadingSpinnerStartTime: Date? = nil
    private let minimumSpinnerDisplayTime: TimeInterval = 0.5  // 500ms minimum
    private var loadingTimeoutTimer: Timer?
    private let maximumLoadingTime: TimeInterval = 10.0  // 10 second timeout
    private var needsFooterUpdate = false
    
    // No more tweets message state
    private var isShowingNoMoreTweetsMessage: Bool = false
    private var noMoreTweetsMessageTimer: Timer?
    private var lastNoMoreTweetsShownTime: Date?
    private let noMoreTweetsMessageCooldown: TimeInterval = 2.0  // 2 second cooldown
    
    // Callbacks
    var loadMoreTweets: ((Bool) -> Void)?  // Parameter: forceLoad
    var onRefresh: (() async -> Void)?  // Pull-to-refresh callback
    var onLoadMoreRequested: (() -> Void)?  // Callback when load more is requested programmatically
    var headerViewBuilder: (() -> AnyView)?
    var onScroll: ((CGFloat, CGFloat) -> Void)?  // (offset, delta)
    var onScrollStateChange: ((CGFloat, Bool, Bool) -> Void)?  // (offset, isAtTop, isInteracting)
    /// Fired after a viewport-aware memory trim so the SwiftUI-side binding can be
    /// kept in sync with what the table view actually rendered.
    var onTweetsTrimmed: (([Tweet]) -> Void)?
    var leadingPadding: CGFloat = 8  // Configurable leading padding for cells
    var trailingPadding: CGFloat = 8  // Configurable trailing padding for cells

    // Pure UIKit cell configuration (replaces rowViewBuilder)
    var hproseInstance: HproseInstance?
    var onAvatarTap: ((User) -> Void)?
    var onTweetTap: ((Tweet) -> Void)?
    var onShowLogin: (() -> Void)?
    var onShowToast: ((String, Bool) -> Void)?
    var onRetweetUnavailable: ((String) -> Void)?
    var allowDeleteAll: Bool = false
    /// True on the main feed: prepended tweets must not move the scroll position.
    /// False elsewhere (profile/list/bookmarks): prepended tweets scroll to the top.
    var preservesScrollPositionOnPrepend: Bool = false
    
    // Header hosting controller
    private var headerHostingController: UIHostingController<AnyView>?
    // Monotonic counter — incremented every time a deferred header-update Task is posted;
    // the Task checks its captured value against the current counter and bails if stale.
    private var headerUpdateGeneration = 0
    
    // Refresh control
    private var customRefreshControl: UIRefreshControl?
    private var interfaceStyleTraitRegistration: UITraitChangeRegistration?
    
    // Video playback coordinator (per-feed instance, injected from TweetTableView)
    let videoCoordinator: VideoPlaybackCoordinator
    
    // Scroll tracking for toolbar hiding
    private var lastScrollOffset: CGFloat = 0
    private var hasCompletedInitialLayout: Bool = false
    private var hasAdjustedInitialPosition: Bool = false
    private var lastScrollCallbackTime: CFTimeInterval = 0
    private let scrollCallbackThrottleInterval: CFTimeInterval = 0.1 // 100ms throttle for scroll callbacks

    // Height cache for layout stability (prevents jumps when cells with videos load)
    // Throttling for video visibility updates (avoid expensive checks on every scroll frame)
    private var lastVideoVisibilityUpdate: CFTimeInterval = 0
    private let videoVisibilityThrottleInterval = FeedPlaybackTuning.videoVisibilityThrottleInterval
    private var isVideoVisibilityUpdateScheduled = false
    private var lastScrollVelocitySampleTime: CFTimeInterval = 0
    private var estimatedScrollVelocityY: CGFloat = 0
    private var lastVisibleTweetIds: Set<String> = [] // Cache last visible tweet IDs
    private var lastLoadVisibleVideoIds: Set<String> = [] // Cache media that is physically on screen and should load
    private var lastContinuePlaybackVideoIds: Set<String> = [] // Cache media visible enough to keep current playback
    private var lastOnScreenVideoIds: Set<String> = [] // Cache per-cell on-screen video identifiers
    
    // Cached main content rect to avoid recalculating on every visibility check
    private var cachedMainContentRect: CGRect?
    private var lastContentOffset: CGFloat = 0
    // Jump-detector state: timestamp of the previous scroll callback (hitch detection).
    private var lastScrollEventTimestamp: CFTimeInterval = 0
    private var lastCallbackOffset: CGFloat = 0  // Only updated when onScroll fires — gives accumulated delta
    private var isCompensatingForBarAppearance: Bool = false  // Compensate contentOffset when header expands
    /// Row anchored while the bars animate in, plus where it sat in window coordinates
    /// at the moment the bars were requested. viewDidLayoutSubviews drives the row back
    /// to that screen position so the content appears stationary.
    private var barCompensationAnchorTweetId: String?
    private var barCompensationAnchorScreenY: CGFloat?
    /// Top of the table's content area in window space at the last layout pass. Corrections
    /// run only when THIS changes, so a coasting scroll is never mistaken for drift.
    private var barCompensationChromeTopWindowY: CGFloat?
    private var lastBarAppearanceRequestTime: CFTimeInterval = 0
    private var lastHeaderHeight: CGFloat = 0
    private var lastHeaderLayoutWidth: CGFloat = 0
    private var lastFooterHeight: CGFloat = 0
    
    // Notification observer for scroll to top
    private var scrollToTopObserver: NSObjectProtocol?

    // Foreground/background observer to prevent white space issue
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var prepareVisibleVideosForBackgroundObserver: NSObjectProtocol?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var reloadVisibleVideosObserver: NSObjectProtocol?
    private var needsVideoLayerRefresh = false
    private var foregroundVideoLayerRefreshRetryCount = 0
    private var pendingBackgroundResumeRestoreWorks: [DispatchWorkItem] = []
    private var backgroundResumeRestoreGeneration: Int = 0

    // Observer for feed view appearance (to restart video playback after navigation)
    private var feedViewDidAppearObserver: NSObjectProtocol?
    private var overlayCoverageObserver: NSObjectProtocol?
    private var feedPlaybackResumeGeneration: Int = 0
    private var pendingFeedPlaybackResumeReason: String?
    private var videoVisibilityRefreshGeneration: Int = 0

    // Scroll position preservation
    private var savedScrollPosition: CGFloat?
    private var didAttemptInitialSavedScrollPositionRestore = false
    private var isScrollingToTop: Bool = false
    /// Set while a scroll-to-top is in flight, so the layout pass that runs when the nav
    /// bars finish expanding can re-pin the offset to the final inset.
    /// See `scrollToTop()`.
    private var isSettlingScrollToTop: Bool = false
    private enum PendingScrollRequest {
        case top
        case firstRegularTweet
        case tweet(String)
    }
    private var pendingScrollRequest: PendingScrollRequest?

    // Feed identifier for persistent scroll position storage
    var feedIdentifier: String = "mainFeed"  // Default to main feed

    private var presentsSavedCommentContext: Bool {
        feedIdentifier.hasPrefix("bookmarks_") || feedIdentifier.hasPrefix("favorites_")
    }

    private func effectiveEmbeddedTweetId(for tweet: Tweet) -> String? {
        if let originalTweetId = tweet.originalTweetId {
            return originalTweetId
        }
        return presentsSavedCommentContext ? tweet.parentTweetId : nil
    }
    var isDarkModeEnabled: Bool = false
    
    // Track scroll direction for height caching strategy
    private var isScrollingBackward: Bool = false
    private let directionalPreloadRowCount = FeedPlaybackTuning.directionalImagePreloadRowCount
    private let oppositeStopPreloadRowCount = FeedPlaybackTuning.oppositeStopImagePreloadRowCount
    private let maxDirectionalImagePreloadsInFlight = FeedPlaybackTuning.maxDirectionalImagePreloadsInFlight
    private var activeDirectionalImagePreloadTasks: [String: Task<Void, Never>] = [:]
    private var lastDirectionalImagePreloadDuringScrollTime: CFTimeInterval = 0
    private var didScheduleInitialVisibilityRefresh = false

    // Scroll state tracking to prevent direction detection jitter during deceleration
    private var isUserDragging: Bool = false
    private var isDecelerating: Bool = false
    private var isTableViewUpdating: Bool = false
    private var deferredPinnedTweets: [Tweet]?
    private var deferredTweets: [Tweet]?
    private var pendingTrimRequest: (maxCount: Int, targetCount: Int)?
    /// True when updateLoadingState(isLoadingMore:false) was called while deferredTweets
    /// were pending. The spinner stays visible until the deferred rows are actually inserted.
    private var hasPendingSpinnerHide = false
    private var pendingSpinnerShouldShowMessage = false
    private var needsFullReloadAfterAttach: Bool = false
    private var pendingHeightRelayoutTweetIds = Set<String>()
    /// Visible rows whose recomputed height SHRANK: applying the shrink while the row is
    /// on screen slides everything below it up (visible shake at scroll stop) for zero
    /// visual benefit — the content already fits. The reconcile is deferred until the
    /// row leaves the screen (didEndDisplaying re-queues it into pendingHeightRelayoutTweetIds).
    private var deferredShrinkTweetIds = Set<String>()
    /// Tweet IDs whose content is currently expanded by the user ("More..." tapped).
    /// `heightForRowAt` returns `automaticDimension` for these so the table re-measures
    /// the cell at full expanded height instead of using the cached truncated height.
    private var expandedTweetIds = Set<String>()
    /// Tweet the user expanded while a scroll gesture was still active; its row is
    /// anchored when the deferred relayout finally runs.
    private var pendingExpansionAnchorTweetId: String?
    private var embeddedTweetPrefetchInFlight = Set<String>()

    // (Text height pre-warming is handled globally by TweetHeightPrewarmer.shared)

    private var isReadyForFeedVideoResume: Bool {
        isViewLoaded && view.window != nil && tableView.window != nil
    }

    private var isTableAttachedForLayout: Bool {
        isViewLoaded && view.window != nil && tableView.window != nil && tableView.superview != nil
    }

    private var isTableVisibleForMutation: Bool {
        isTableAttachedForLayout && videoCoordinator.isFeedVisible
    }

    private var isTableAttachedForDataMutation: Bool {
        isTableAttachedForLayout
    }

    private var currentRowLayoutWidth: CGFloat {
        tableView.bounds.width > 0 ? tableView.bounds.width : UIScreen.main.bounds.width
    }

    /// Keeps TweetHeightPrewarmer's background-measurement width in sync with this table's
    /// ACTUAL row layout width (tableView.bounds.width), instead of the app-launch-time guess
    /// derived from UIScreen.main.bounds.width. If the two ever diverge (safe area, Slide Over,
    /// iPad, or simply a table that isn't edge-to-edge with the screen), the prewarmer's cached
    /// text height/attributed string would be keyed on a width that never matches what
    /// calculateTweetHeight/renderTextContent actually compute — silently defeating prewarming
    /// entirely and forcing full CoreText typesetting on first render regardless.
    private func syncPrewarmerContentWidthIfNeeded() {
        let padding = leadingPadding + trailingPadding
        let contentWidth = currentRowLayoutWidth - padding - 3 - 46 - 4
        guard contentWidth > 1 else { return }
        if abs(TweetHeightPrewarmer.shared.standardContentWidth - contentWidth) > 0.5 {
            TweetHeightPrewarmer.shared.standardContentWidth = contentWidth
        }
    }

    private func cachedHeight(for tweet: Tweet, width: CGFloat) -> CGFloat? {
        guard let cachedHeight = tweet.cachedHeight,
              abs(tweet.cachedHeightWidth - width) <= 1 else {
            return nil
        }
        return cachedHeight
    }

    private func setCachedHeight(_ height: CGFloat, for tweet: Tweet, width: CGFloat) {
        let cacheWidth = width > 0 ? width : currentRowLayoutWidth
        tweet.cachedHeight = height
        tweet.cachedHeightWidth = cacheWidth
        TweetHeightCache.shared.setHeight(height, for: tweet.mid, width: cacheWidth)
    }

    private func clearCachedHeight(for tweet: Tweet) {
        tweet.cachedHeight = nil
        tweet.cachedHeightWidth = 0
        TweetHeightCache.shared.removeHeight(for: tweet.mid)
    }

    private func scheduleFeedPlaybackResume(after delay: TimeInterval, reason: String) {
        guard !OverlayVisibilityCoordinator.shared.isCovered else {
            print("📺 [VIDEO RESTART] Feed '\(feedIdentifier)' resume after \(reason) deferred to overlay dismiss")
            return
        }

        feedPlaybackResumeGeneration += 1
        let generation = feedPlaybackResumeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.feedPlaybackResumeGeneration == generation,
                  !self.videoCoordinator.isOverlayDismissPending,
                  !OverlayVisibilityCoordinator.shared.isCovered else { return }

            guard !NavigationStateManager.shared.isDetailViewActive else {
                self.pendingFeedPlaybackResumeReason = reason
                return
            }

            guard self.isReadyForFeedVideoResume else {
                self.pendingFeedPlaybackResumeReason = reason
                return
            }

            self.performFeedPlaybackResume(reason: reason)
        }
    }

    private func performFeedPlaybackResume(reason: String) {
        guard !NavigationStateManager.shared.isDetailViewActive else {
            pendingFeedPlaybackResumeReason = reason
            return
        }

        guard isReadyForFeedVideoResume else {
            pendingFeedPlaybackResumeReason = reason
            return
        }

        print("📺 [VIDEO RESTART] Feed '\(feedIdentifier)' resume after \(reason)")
        if videoCoordinator.primaryVideoId == nil {
            lastVisibleTweetIds = []
            lastLoadVisibleVideoIds = []
            lastContinuePlaybackVideoIds = []
            lastOnScreenVideoIds = []
            updateVisibleTweetsForVideoPlayback()
        }
        videoCoordinator.requestResumePrimaryPlaybackIfVisible()
    }

    init(videoCoordinator: VideoPlaybackCoordinator) {
        self.videoCoordinator = videoCoordinator
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        MainThreadStallSampler.shared.startIfNeeded()
        // Unambiguous record of which row-height model this run used — a perf log is
        // useless if you cannot tell from it whether the experiment was switched on.
        print("📐 [FEED LAYOUT] mode=\(FeedLayoutMode.selfSizing ? "SELF-SIZING (no height calculator)" : "deterministic heights")")

        interfaceStyleTraitRegistration = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: TweetTableViewController, _) in
            controller.applyTheme()
        }

        setupTableView()
        setupRefreshControl()
        setupScrollToTopObserver()
        setupMemoryWarningObserver()
        setupForegroundBackgroundObservers()
        setupFeedViewDidAppearObserver()
        setupOverlayCoverageObserver()

        // Pass table view reference to video coordinator for viewport calculations
        videoCoordinator.setTableView(tableView)
    }
    
    // isolated deinit (SE-0371): the runtime hops to the main actor if the last
    // reference is dropped off-main, instead of MainActor.assumeIsolated trapping
    // (the build-117 crash class).
    isolated deinit {
        // End any active background task
        endBackgroundTask()

        // Remove notification observers
        if let observer = scrollToTopObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        if let observer = prepareVisibleVideosForBackgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        if let observer = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        if let observer = reloadVisibleVideosObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        if let observer = feedViewDidAppearObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        if let observer = overlayCoverageObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        // Clean up timers
        noMoreTweetsMessageTimer?.invalidate()
        loadingTimeoutTimer?.invalidate()
        embeddedTweetPrefetchInFlight.removeAll()
        cancelDirectionalImagePreloads()
        cancelPendingBackgroundResumeRestores()

        // NOTE: Removed .shouldStopAllVideos notification from deinit
        // This was causing issues when navigating back from profile - it would stop
        // the main feed's videos. The video coordinator already handles stopping
        // videos when they become invisible via updateVisibleTweets.
    }
    
    private func setupScrollToTopObserver() {
        scrollToTopObserver = NotificationCenter.default.addObserver(
            forName: .scrollToTop,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let targetFeedId = notification.userInfo?["feedIdentifier"] as? String
            let scrollTarget = notification.userInfo?["scrollTarget"] as? String
            let targetTweetId = notification.userInfo?["targetTweetId"] as? String
            guard let self = self else { return }

            MainActor.assumeIsolated {
                // Check if this notification is for this specific feed
                if let targetFeedId {
                    // Only scroll if the notification targets this feed
                    if targetFeedId == self.feedIdentifier {
                        self.handleScrollToTopNotification(scrollTarget: scrollTarget, targetTweetId: targetTweetId)
                    }
                } else {
                    // No target specified - scroll if this is the main feed
                    if self.feedIdentifier == "mainFeed" {
                        self.handleScrollToTopNotification(scrollTarget: scrollTarget, targetTweetId: targetTweetId)
                    }
                }
            }
        }
    }

    private func handleScrollToTopNotification(scrollTarget: String?, targetTweetId: String?) {
        if scrollTarget == "tweetId",
           let targetTweetId {
            scrollToTweet(targetTweetId)
        } else if scrollTarget == "firstRegularTweet" {
            scrollToFirstRegularTweet()
        } else {
            scrollToTop()
        }
    }

    private func setupOverlayCoverageObserver() {
        overlayCoverageObserver = NotificationCenter.default.addObserver(
            forName: .overlayCoverageChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let isCovered = notification.userInfo?["isCovered"] as? Bool
            let source = notification.userInfo?["source"] as? String
            MainActor.assumeIsolated {
                guard let self,
                      let isCovered,
                      !isCovered,
                      let source,
                      source.contains("MediaBrowser") else { return }

                self.remeasureVisibleRowsAfterOverlayDismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.remeasureVisibleRowsAfterOverlayDismiss()
                    }
                }
            }
        }
    }

    private func remeasureVisibleRowsAfterOverlayDismiss() {
        guard tableView.window != nil,
              let visibleIndexPaths = tableView.indexPathsForVisibleRows,
              !visibleIndexPaths.isEmpty else { return }

        for indexPath in visibleIndexPaths {
            guard let tweet = tweetForRow(indexPath.row) else { continue }
            clearCachedHeight(for: tweet)
        }

        UIView.performWithoutAnimation {
            isTableViewUpdating = true
            tableView.beginUpdates()
            tableView.endUpdates()
            isTableViewUpdating = false
        }
    }

    /// Setup observer for feed view appearance to resume video playback after navigation
    private func setupFeedViewDidAppearObserver() {
        feedViewDidAppearObserver = NotificationCenter.default.addObserver(
            forName: .feedViewDidAppear,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let feedId = notification.userInfo?["feedIdentifier"] as? String

            // When the same video was playing on the profile we left, main feed and profile share
            // one AVPlayer (SharedAssetCache). The profile's SimpleVideoPlayer.onDisappear runs
            // during teardown and calls player.pause() on that shared instance. If we send our
            // resume-play command before the profile has torn down, the profile's onDisappear
            // can run afterward and pause the player again. Delay so teardown completes first.
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only process if this notification targets our feed
                if let feedId, feedId != self.feedIdentifier {
                    return
                }
                let hasLiveHandoff = VideoSurfaceHandoffRegistry.shared.hasActiveTransfer()
                self.scheduleFeedPlaybackResume(
                    after: hasLiveHandoff ? 0.05 : 0.4,
                    reason: "feedViewDidAppear"
                )
            }
        }
    }

    // MEMORY FIX: Respond to memory warnings by aggressively clearing caches
    private var memoryWarningObserver: NSObjectProtocol?
    
    private func setupMemoryWarningObserver() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Only perform aggressive cleanup when memory is genuinely high.
            // iOS sends memory warnings even at ~200MB; reloading visible cells
            // tears down playing video players and causes black flicker.
            var vmInfo = task_vm_info_data_t()
            var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / mach_msg_type_number_t(MemoryLayout<natural_t>.size)
            let memoryMB: UInt64
            if withUnsafeMutablePointer(to: &vmInfo, {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
                }
            }) == KERN_SUCCESS {
                memoryMB = UInt64(vmInfo.phys_footprint) / (1024 * 1024)
            } else {
                memoryMB = 0
            }
            guard memoryMB > 1200 else { return }

            // Stop all videos and clear coordinator caches via notification
            NotificationCenter.default.post(name: .shouldStopAllVideos, object: nil)

            // Force reload visible cells to reclaim memory
            MainActor.assumeIsolated {
                if let self, self.tableView.window != nil, let visibleIndexPaths = self.tableView.indexPathsForVisibleRows {
                    self.isTableViewUpdating = true
                    self.tableView.reloadRows(at: visibleIndexPaths, with: .none)
                    self.isTableViewUpdating = false
                }
            }
        }
    }

    // Background task identifier for memory cleanup
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // MARK: - Foreground/Background Observers
    /// Setup observers to save scroll position before backgrounding and restore after foreground
    /// This prevents the white space issue caused by safe area inset recalculation
    /// Also handles video player memory management (release on background, restore on foreground)
    private func setupForegroundBackgroundObservers() {
        // Save scroll position and release video players when app goes to background
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,  // Changed from willResignActive
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppDidEnterBackground()
            }
        }

        prepareVisibleVideosForBackgroundObserver = NotificationCenter.default.addObserver(
            forName: .prepareVisibleVideosForBackground,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let aggressive = notification.userInfo?["aggressive"] as? Bool ?? false
            guard aggressive else { return }
            // AppDelegate posts this custom notification synchronously from its
            // @MainActor cleanup path. Finish local teardown before global caches
            // are released and the background task is ended.
            MainActor.assumeIsolated { [weak self] in
                self?.prepareVisibleVideosForBackground(
                    reason: "preGlobalMemoryRelease",
                    aggressive: true
                )
            }
        }

        // Restore scroll position and video players when app returns to foreground
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppWillEnterForeground()
            }
        }

        // After app is fully active (GPU ready), force all displayed video cells
        // to re-render. This covers partially visible cells that have no per-cell
        // foreground observer (isVisible=false removes it).
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppDidBecomeActive()
            }
        }

        reloadVisibleVideosObserver = NotificationCenter.default.addObserver(
            forName: .reloadVisibleVideosOnly,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleReloadVisibleVideosOnly()
            }
        }
    }

    @MainActor
    private func handleAppDidEnterBackground() {
        guard videoCoordinator.isFeedVisible else { return }

        // Request background time from iOS to complete cleanup
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            // Cleanup callback - iOS is about to force-terminate background task
            print("⚠️ [BACKGROUND] Background task time expired - iOS forcing cleanup")
            Task { @MainActor [weak self] in
                self?.endBackgroundTask()
            }
        }

        print("🌙 [BACKGROUND] App entering background - deferring media cleanup to grace window")

        // Save the current scroll position before backgrounding
        saveScrollPositionIfNeeded()

        // End background task after a short delay to allow cleanup to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            print("✅ [BACKGROUND] Cleanup complete")

            // End background task when done
            self.endBackgroundTask()
        }
    }

    private func prepareVisibleVideosForBackground(reason: String, aggressive: Bool = false) {
        guard videoCoordinator.isFeedVisible else { return }
        guard isTableAttachedForLayout else { return }

        cancelDirectionalImagePreloads()

        // Save/pause visible videos before global memory release. Keep a captured
        // cover frame on screen so foreground recovery can rebuild underneath it.
        guard !isTableViewUpdating else { return }

        var preparedCount = 0
        for cell in tableView.visibleCells {
            guard let tweetCell = cell as? TweetTableViewCell else { continue }
            tweetCell.tweetContentView.prepareMediaForBackground(aggressive: aggressive)
            preparedCount += 1
        }

        if preparedCount > 0 {
            let mode = aggressive ? "aggressive" : "short"
            print("🌙 [BACKGROUND] Prepared \(preparedCount) visible tweet cell(s) for \(mode) background (\(reason))")
        }
    }

    @MainActor
    private func handleAppWillEnterForeground() {
        guard videoCoordinator.isFeedVisible else { return }

        isUserDragging = false
        isDecelerating = false

        print("☀️ [FOREGROUND] App returning to foreground")

        // Cancel background task if still active
        endBackgroundTask()
        needsVideoLayerRefresh = true
        foregroundVideoLayerRefreshRetryCount = 0

        let currentPosition = tableView.contentOffset.y
        lastContentOffset = currentPosition
        lastCallbackOffset = currentPosition
    }

    @MainActor
    private func handleAppDidBecomeActive() {
        guard needsVideoLayerRefresh else { return }
        guard videoCoordinator.isFeedVisible else {
            scheduleForegroundVideoLayerRefreshRetryIfNeeded()
            return
        }
        guard AppDelegate.isVideoInfrastructureReady,
              isReadyForFeedVideoResume,
              !isTableViewUpdating else {
            scheduleForegroundVideoLayerRefreshRetryIfNeeded()
            return
        }
        needsVideoLayerRefresh = false
        foregroundVideoLayerRefreshRetryCount = 0
        refreshVisibleVideoLayersAfterForeground()
        videoCoordinator.requestResumePrimaryPlaybackIfVisible()
    }

    @MainActor
    private func scheduleForegroundVideoLayerRefreshRetryIfNeeded() {
        guard needsVideoLayerRefresh else { return }
        guard foregroundVideoLayerRefreshRetryCount < 8 else { return }

        foregroundVideoLayerRefreshRetryCount += 1
        let delay = min(0.25 * Double(foregroundVideoLayerRefreshRetryCount), 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleAppDidBecomeActive()
            }
        }
    }

    @MainActor
    private func handleReloadVisibleVideosOnly() {
        guard videoCoordinator.isFeedVisible else { return }
        recoverVideoCoordinatorAfterForeground(reason: "reloadVisibleVideosOnly")
    }

    /// End the background task and invalidate the identifier
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    /// Get current memory usage in MB
    private func getMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        if kerr == KERN_SUCCESS {
            return Double(info.resident_size) / (1024 * 1024) // Convert to MB
        }
        return 0
    }

    @MainActor
    private func recoverVideoCoordinatorAfterForeground(reason: String) {
        guard AppDelegate.isVideoInfrastructureReady else { return }
        guard isReadyForFeedVideoResume, !isTableViewUpdating else {
            pendingFeedPlaybackResumeReason = reason
            schedulePendingFeedPlaybackResumeRetry(reason: reason)
            return
        }

        needsVideoLayerRefresh = false
        videoCoordinator.validatePlayersAfterBackground()
        videoCoordinator.resetForForegroundInfrastructureRecovery(reason: reason)
        lastVisibleTweetIds = []
        lastLoadVisibleVideoIds = []
        lastContinuePlaybackVideoIds = []
        lastOnScreenVideoIds = []
        updateVisibleTweetsForVideoPlayback()
        // Refresh layers AFTER the coordinator is reset and allVideos is rebuilt so that
        // any onReadyForDisplay callbacks cells set up see consistent coordinator state,
        // and so that coordinatorWantsToPlay is authoritative (set by requestResume below).
        refreshVisibleVideoLayersAfterForeground()
        videoCoordinator.requestResumePrimaryPlaybackIfVisible()
    }

    @MainActor
    private func schedulePendingFeedPlaybackResumeRetry(reason: String) {
        feedPlaybackResumeGeneration += 1
        let generation = feedPlaybackResumeGeneration
        let delays: [TimeInterval] = [0.1, 0.35, 0.8, 1.5]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.feedPlaybackResumeGeneration == generation,
                          self.pendingFeedPlaybackResumeReason == reason,
                          AppDelegate.isVideoInfrastructureReady,
                          self.isReadyForFeedVideoResume,
                          !self.isTableViewUpdating else { return }

                    self.pendingFeedPlaybackResumeReason = nil
                    if reason == "reloadVisibleVideosOnly" || reason.hasPrefix("backgroundResumeRestore") {
                        self.recoverVideoCoordinatorAfterForeground(reason: "\(reason)-deferredReady")
                    } else {
                        self.scheduleFeedPlaybackResume(after: 0, reason: "\(reason)-deferredReady")
                    }
                }
            }
        }
    }

    private func refreshVisibleVideoLayersAfterForeground() {
        guard isTableVisibleForMutation else { return }

        for cell in tableView.visibleCells {
            guard let tweetCell = cell as? TweetTableViewCell else { continue }
            tweetCell.tweetContentView.refreshVideoLayersAfterForeground()
        }
    }

    func scrollToTop() {
        guard isTableVisibleForMutation else {
            pendingScrollRequest = .top
            return
        }

        // Clear saved scroll position when scrolling to top
        savedScrollPosition = nil
        ScrollPositionManager.shared.clearScrollPosition(for: feedIdentifier)
        if feedIdentifier == "mainFeed" {
            BackgroundResumeStateStore.shared.clear(reason: "manual scroll to top")
        }
        isScrollingToTop = true

        // Reveal the app header BEFORE starting the scroll animation.
        //
        // The header is not a content inset — it is a SwiftUI sibling above this table
        // whose height collapses to 0 when the user scrolls down (HomeViewModel's
        // isNavigationVisible). Left alone, the sequence was: animate towards the top →
        // HomeViewModel.handleScroll sees `offset <= 10` and expands the header → the
        // table's frame changes mid-animation → UIScrollView CANCELS the in-flight
        // setContentOffset animation. The scroll stops wherever it had got to, roughly a
        // header height short — the reported "stops in the middle of the first tweet".
        // A second tap works because the header is already expanded by then, so no layout
        // change interrupts the animation.
        //
        // Posting .showBarsAfterScrollEnd up front expands the header instantly (that
        // observer deliberately does not animate) and stamps lastVisibilityChangeTime,
        // whose 0.35s cooldown also suppresses the late handleScroll expansion. The
        // layout change therefore happens before the animation rather than during it.
        //
        // Requesting it here rather than via showBarsWithoutAnimation deliberately skips
        // the bar-appearance anchor: that machinery holds a row still while the bars
        // expand mid-coast, which is the opposite of what a scroll-to-top wants.
        endBarAppearanceCompensation()
        NotificationCenter.default.post(
            name: .showBarsAfterScrollEnd,
            object: nil,
            userInfo: ["animated": false]
        )

        // Belt and braces: the header expansion above still resizes this table, so let the
        // next layout passes re-pin the offset in case the animation is disturbed anyway.
        isSettlingScrollToTop = true
        tableView.setContentOffset(
            CGPoint(x: 0, y: -tableView.adjustedContentInset.top),
            animated: true
        )

        // Reset flags once the animation and any header relayout have settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.isScrollingToTop = false
            self?.isSettlingScrollToTop = false
        }
    }

    func scrollToFirstRegularTweet() {
        guard isTableVisibleForMutation else {
            pendingScrollRequest = .firstRegularTweet
            return
        }

        savedScrollPosition = nil
        ScrollPositionManager.shared.clearScrollPosition(for: feedIdentifier)
        if feedIdentifier == "mainFeed" {
            BackgroundResumeStateStore.shared.clear(reason: "manual scroll to first new tweet")
        }

        isScrollingToTop = true
        tableView.layoutIfNeeded()

        let indexPath = regularTweetIndexPath(0)
        if indexPath.row < tableView.numberOfRows(inSection: 0) {
            tableView.scrollToRow(at: indexPath, at: .top, animated: true)
        } else {
            scrollToTop()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isScrollingToTop = false
        }
    }

    func scrollToTweet(_ tweetId: String) {
        guard isTableVisibleForMutation else {
            pendingScrollRequest = .tweet(tweetId)
            return
        }

        savedScrollPosition = nil
        ScrollPositionManager.shared.clearScrollPosition(for: feedIdentifier)
        if feedIdentifier == "mainFeed" {
            BackgroundResumeStateStore.shared.clear(reason: "manual scroll to tweet")
        }

        isScrollingToTop = true
        tableView.layoutIfNeeded()

        if let row = rowForTweetId(tweetId), row < tableView.numberOfRows(inSection: 0) {
            tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .top, animated: true)
        } else {
            scrollToFirstRegularTweet()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isScrollingToTop = false
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyTheme()

        if needsHeaderUpdate {
            updateHeader()
        }

        videoCoordinator.isFeedVisible = true

        // Resume video playback when returning from a UIKit full-screen modal (e.g. the
        // MediaBrowserView fullscreen player).  TweetListView.onAppear does NOT fire for
        // UIKit .fullScreen modal dismissal because the SwiftUI view stays in the hierarchy
        // while the modal is presented, so the .feedViewDidAppear notification is never
        // posted through that path.  Re-evaluate visibility here to fill the gap.
        // The delay lets the dismiss/pop animation and destination teardown complete
        // before we resume the shared player. Detail teardown pauses the same AVPlayer;
        // resuming too early creates a visible play/pause flicker on the feed cell.
        if isMovingToParent == false {
            let isLiveDetailHandoff = NavigationStateManager.shared.isDetailViewActive
                || NavigationStateManager.shared.shouldPreserveFeedForDetailTransition
                || VideoSurfaceHandoffRegistry.shared.hasActiveTransfer()
            let resumeDelay: TimeInterval = isLiveDetailHandoff ? 0.05 : 0.25
            scheduleFeedPlaybackResume(after: resumeDelay, reason: "viewWillAppear")
        }

        // Restore the in-memory offset only for the main feed. Profile/detail feeds are
        // created frequently during navigation; applying a saved offset before their
        // first layout can stack with media setup and make the first gesture feel frozen.
        if feedIdentifier == "mainFeed", !isScrollingToTop && !hasAdjustedInitialPosition {
            if savedScrollPosition != nil || ScrollPositionManager.shared.getScrollPosition(for: feedIdentifier) != nil {
                DispatchQueue.main.async { [weak self] in
                    self?.applyMainFeedSavedScrollPositionIfReady()
                }
            }
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Initial position adjustment - only run once on first appearance
        if !hasAdjustedInitialPosition {
            hasAdjustedInitialPosition = true

            let topInset = tableView.adjustedContentInset.top
            let currentOffset = tableView.contentOffset.y

            // Only adjust if offset is close to 0 (the bad initial position)
            // and topInset is set (nav bar is present)
            // Ignore if already properly positioned or if user has scrolled
            // Also ignore if we just restored a saved position
            let hasSavedPosition = (feedIdentifier == "mainFeed" && (
                savedScrollPosition != nil
                    || ScrollPositionManager.shared.getScrollPosition(for: feedIdentifier) != nil
            ))
                || hasPendingBackgroundResumeSnapshot()
            if topInset > 0 && currentOffset >= -5 && currentOffset <= 5 && !hasSavedPosition {
                tableView.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false)
                lastScrollOffset = -topInset
            }
        }

        applyMainFeedSavedScrollPositionIfReady()
        // NOTE: Video playback restart is handled by .feedViewDidAppear notification
        // (see setupFeedViewDidAppearObserver) which re-evaluates visibility to resume playback

        if needsFooterUpdate {
            needsFooterUpdate = false
            updateLoadingState(
                isLoading: isLoading,
                isLoadingMore: isLoadingMore,
                hasMoreTweets: hasMoreTweets,
                canShowNoMoreTweetsMessage: canShowNoMoreTweetsMessage
            )
        }

        applyPendingDetachedTableReloadIfNeeded(reason: "viewDidAppear")
        applyDeferredTableChromeUpdatesAfterScroll()
        applyPendingScrollRequestIfNeeded()
        schedulePendingBackgroundResumeRestore(reason: "viewDidAppear")
        scheduleVideoVisibilityRefresh(reason: "viewDidAppear")
        if let pendingReason = pendingFeedPlaybackResumeReason {
            guard AppDelegate.isVideoInfrastructureReady else {
                schedulePendingFeedPlaybackResumeRetry(reason: pendingReason)
                return
            }
            pendingFeedPlaybackResumeReason = nil
            if pendingReason == "reloadVisibleVideosOnly" || pendingReason.hasPrefix("backgroundResumeRestore") {
                recoverVideoCoordinatorAfterForeground(reason: "\(pendingReason)-windowReady")
            } else {
                scheduleFeedPlaybackResume(after: 0, reason: "\(pendingReason)-windowReady")
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelPendingBackgroundResumeRestores()

        videoCoordinator.isFeedVisible = false
        feedPlaybackResumeGeneration += 1

        if NavigationStateManager.shared.shouldPreserveFeedForDetailTransition,
           let videoMid = NavigationStateManager.shared.videoMidToPreserveForDetailTransition {
            videoCoordinator.suspendForDetailHandoff(preservingVideoMid: videoMid)
        } else {
            // Stop all feed videos when navigating away to non-detail destinations.
            // Detail borrows the shared feed AVPlayer, so stopping here creates a
            // pause/reattach cycle and a visible freeze when returning.
            videoCoordinator.stopAllVideos()
        }
        cancelDirectionalImagePreloads()

        // Save current scroll position when view disappears (backup to scroll delegate methods)
        saveScrollPositionIfNeeded()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        syncPrewarmerContentWidthIfNeeded()

        guard isTableVisibleForMutation else { return }

        // Keep visible content pinned while the bars appear without animation.
        //
        // This used to compensate by how far this VIEW's frame moved in window space,
        // then apply that as a contentOffset delta. That double-counts: showing the bars
        // also grows adjustedContentInset.top, and UIKit shifts contentOffset for the
        // inset change on its own — so adding the frame delta on top produced a visible
        // ~91pt jump at scroll stop (caught as `idle-offset-change` from
        // viewDidLayoutSubviews). Anchoring a real row instead is self-correcting: it
        // measures where the content ACTUALLY landed after UIKit finished, whatever
        // combination of frame/inset/offset changes got it there, and cancels the
        // residual drift only. That measurement is gated on the chrome geometry actually
        // changing, so it corrects the bar-driven shift without fighting a coasting scroll.
        applyBarAppearanceAnchorCorrectionIfNeeded()

        // Initialize lastScrollOffset to current offset to prevent incorrect delta on first scroll
        // This prevents toolbar from hiding incorrectly when view loads with negative content offset
        if !hasCompletedInitialLayout {
            lastScrollOffset = tableView.contentOffset.y
            hasCompletedInitialLayout = true
            if !didScheduleInitialVisibilityRefresh {
                didScheduleInitialVisibilityRefresh = true
                scheduleVideoVisibilityRefresh(reason: "initialLayout")
            }

            // Ensure table view is scrolled to proper top position (respecting safe area)
            // This prevents header from being covered by navigation bar
            let topInset = tableView.adjustedContentInset.top
            let currentOffset = tableView.contentOffset.y

            // If offset is too negative (header would be under nav bar), correct it
            // But only if we don't have a saved position to restore
            let hasSavedPosition = feedIdentifier == "mainFeed"
                && (savedScrollPosition != nil || ScrollPositionManager.shared.getScrollPosition(for: feedIdentifier) != nil)
            if currentOffset < -topInset && !hasSavedPosition {
                tableView.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false)
                lastScrollOffset = -topInset
            }
        }

        // A scroll-to-top is in flight and the app header's expansion resizes this table.
        // Re-pin so the feed lands on the true top rather than wherever a cancelled
        // animation left it. Abandoned as soon as the user touches the list.
        if isSettlingScrollToTop, !isUserDragging, !tableView.isTracking {
            let settledTop = -tableView.adjustedContentInset.top
            if abs(tableView.contentOffset.y - settledTop) > 0.5 {
                tableView.setContentOffset(CGPoint(x: 0, y: settledTop), animated: false)
                lastScrollOffset = settledTop
                lastContentOffset = settledTop
            }
        }

        if headerViewBuilder != nil,
           isTableVisibleForMutation,
           abs(tableView.bounds.width - lastHeaderLayoutWidth) > 1 {
            updateHeader()
        }
    }
    
    private func setupTableView() {
        tableView.register(TweetTableViewCell.self, forCellReuseIdentifier: TweetTableViewCell.reuseIdentifier)
        tableView.separatorStyle = .none
        applyTheme()
        
        // Use smarter estimated height based on cached values
        tableView.estimatedRowHeight = 250 // Base estimate, will be refined per cell
        tableView.rowHeight = UITableView.automaticDimension
        
        // CRITICAL: Explicitly set delegate to self
        tableView.delegate = self
        tableView.dataSource = self
        
        // Twitter-like scroll deceleration for smooth, controlled scrolling
        tableView.decelerationRate = .normal

        // PERFORMANCE FIX: Keep system prefetching disabled to avoid expensive cell creation
        // System prefetching creates entire cells (UIHostingController + SwiftUI layout) just to measure height
        // This blocks main thread for 180ms+ during scroll idle periods, causing stuttering
        // Instead, we use custom background data prefetching (see extension below)
        tableView.prefetchDataSource = self  // Our lightweight data prefetching only
        if #available(iOS 15.0, *) {
            tableView.isPrefetchingEnabled = false  // Disable system's cell prefetching
        }
        
        // CRITICAL: Disable section header pinning so headers scroll naturally
        if #available(iOS 15.0, *) {
            tableView.sectionHeaderTopPadding = 0
        }
        
        // Self-sizing optimization flags for better scroll performance
        if #available(iOS 15.0, *) {
            tableView.fillerRowHeight = 0  // Don't calculate filler rows
            tableView.sectionHeaderHeight = 0  // No section headers
            tableView.sectionFooterHeight = 0  // No section footers
        }
        
        // Use automatic adjustment to respect safe area (navigation bar)
        // The scroll jump is prevented by not reassigning tableHeaderView in updateHeader()
        tableView.contentInsetAdjustmentBehavior = .automatic
        
        // Add bottom content inset to prevent last tweet from being hidden by tab bar
        // This ensures the last tweet is fully visible and scrollable above the bottom navigation
        // Tab bar height ~49pt + safe area bottom (~34pt on devices with home indicator)
        let bottomInset: CGFloat = 70 // Extra padding to account for tab bar + safe area + footer message
        tableView.contentInset.bottom = bottomInset
        tableView.verticalScrollIndicatorInsets.bottom = bottomInset
    }

    func applyTheme() {
        let interfaceStyle: UIUserInterfaceStyle = isDarkModeEnabled ? .dark : .light
        overrideUserInterfaceStyle = interfaceStyle
        view.overrideUserInterfaceStyle = interfaceStyle
        tableView.overrideUserInterfaceStyle = interfaceStyle
        tableView.backgroundColor = XTheme.background
        view.backgroundColor = XTheme.background
        customRefreshControl?.tintColor = XTheme.accent
        if tableView.window != nil {
            tableView.visibleCells.forEach { cell in
                if let tweetCell = cell as? TweetTableViewCell {
                    tweetCell.applyTheme()
                } else {
                    cell.backgroundColor = XTheme.background
                    cell.contentView.backgroundColor = XTheme.background
                }
            }
        }
    }

    private func regularTweetIndexPath(_ regularIndex: Int) -> IndexPath {
        IndexPath(row: pinnedTweets.count + regularIndex, section: 0)
    }

    private func setupRefreshControl() {
        customRefreshControl = UIRefreshControl()
        customRefreshControl?.tintColor = XTheme.accent
        customRefreshControl?.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        tableView.refreshControl = customRefreshControl
    }

    private func tweetForRow(_ row: Int) -> Tweet? {
        let totalRows = pinnedTweets.count + tweets.count
        guard row >= 0, row < totalRows else { return nil }
        if row < pinnedTweets.count {
            return pinnedTweets[row]
        }
        let regularIndex = row - pinnedTweets.count
        guard regularIndex < tweets.count else { return nil }
        return tweets[regularIndex]
    }

    private func rowForTweetId(_ tweetId: String) -> Int? {
        if let pinnedIndex = pinnedTweets.firstIndex(where: { $0.mid == tweetId }) {
            return pinnedIndex
        }
        if let regularIndex = tweets.firstIndex(where: { $0.mid == tweetId }) {
            return pinnedTweets.count + regularIndex
        }
        return nil
    }

    private func dominantVisibleTweetAnchor() -> (tweetId: String, tweetOffsetY: CGFloat, viewportY: CGFloat)? {
        guard let visibleRows = tableView.indexPathsForVisibleRows?.sorted(),
              !visibleRows.isEmpty else {
            return nil
        }

        let visibleTopY = tableView.contentOffset.y + tableView.adjustedContentInset.top
        let visibleBottomY = tableView.contentOffset.y + tableView.bounds.height - tableView.adjustedContentInset.bottom
        guard visibleBottomY > visibleTopY else { return nil }

        var bestAnchor: (tweetId: String, tweetOffsetY: CGFloat, viewportY: CGFloat, visibleHeight: CGFloat)?
        for indexPath in visibleRows {
            guard let tweet = tweetForRow(indexPath.row) else { continue }
            let rowRect = tableView.rectForRow(at: indexPath)
            let intersectionTop = max(rowRect.minY, visibleTopY)
            let intersectionBottom = min(rowRect.maxY, visibleBottomY)
            let visibleHeight = intersectionBottom - intersectionTop
            guard visibleHeight > 1 else { continue }

            let anchorContentY = (intersectionTop + intersectionBottom) / 2
            let anchor = (
                tweetId: tweet.mid,
                tweetOffsetY: anchorContentY - rowRect.minY,
                viewportY: anchorContentY - tableView.contentOffset.y,
                visibleHeight: visibleHeight
            )

            if bestAnchor == nil || anchor.visibleHeight > bestAnchor!.visibleHeight {
                bestAnchor = anchor
            }
        }

        guard let bestAnchor else { return nil }
        return (bestAnchor.tweetId, bestAnchor.tweetOffsetY, bestAnchor.viewportY)
    }

    private func currentBackgroundResumeSnapshot() -> BackgroundFeedResumeSnapshot? {
        guard feedIdentifier == "mainFeed",
              let appUser = hproseInstance?.appUser,
              !appUser.isGuest else {
            return nil
        }

        let anchor = dominantVisibleTweetAnchor()
        return BackgroundFeedResumeSnapshot(
            feedIdentifier: feedIdentifier,
            appUserId: appUser.mid,
            contentOffsetY: tableView.contentOffset.y,
            topTweetId: anchor?.tweetId,
            topTweetOffsetY: anchor?.tweetOffsetY ?? 0,
            anchorTweetId: anchor?.tweetId,
            anchorTweetOffsetY: anchor?.tweetOffsetY,
            anchorViewportY: anchor?.viewportY,
            createdAt: Date()
        )
    }

    private func pendingBackgroundResumeSnapshot() -> BackgroundFeedResumeSnapshot? {
        guard feedIdentifier == "mainFeed",
              let appUser = hproseInstance?.appUser,
              !appUser.isGuest else {
            return nil
        }

        return BackgroundResumeStateStore.shared.snapshot(
            feedIdentifier: feedIdentifier,
            appUserId: appUser.mid
        )
    }

    private func hasPendingBackgroundResumeSnapshot() -> Bool {
        pendingBackgroundResumeSnapshot() != nil
    }

    private func cancelPendingBackgroundResumeRestores() {
        backgroundResumeRestoreGeneration += 1
        pendingBackgroundResumeRestoreWorks.forEach { $0.cancel() }
        pendingBackgroundResumeRestoreWorks.removeAll()
    }

    private func cancelBackgroundResumeForUserScroll() {
        let hadPendingRestore = !pendingBackgroundResumeRestoreWorks.isEmpty || hasPendingBackgroundResumeSnapshot()
        cancelPendingBackgroundResumeRestores()
        guard hadPendingRestore else { return }
        BackgroundResumeStateStore.shared.clear(reason: "user scroll took control")
    }

    private func scheduleInitialSavedScrollPositionRestoreIfNeeded(reason: String) {
        guard feedIdentifier != "mainFeed" else { return }
        guard !didAttemptInitialSavedScrollPositionRestore else { return }
        guard savedScrollPosition != nil || ScrollPositionManager.shared.getScrollPosition(for: feedIdentifier) != nil else { return }
        guard isTableVisibleForMutation else { return }

        didAttemptInitialSavedScrollPositionRestore = true
        DispatchQueue.main.async { [weak self] in
            self?.restoreInitialSavedScrollPositionIfValid(reason: reason, allowDeferral: true)
        }
    }

    private func applyMainFeedSavedScrollPositionIfReady() {
        guard feedIdentifier == "mainFeed",
              !isScrollingToTop,
              isTableVisibleForMutation else { return }
        guard let position = savedScrollPosition ?? ScrollPositionManager.shared.getScrollPosition(for: feedIdentifier) else { return }

        lastContentOffset = position
        lastCallbackOffset = position
        tableView.setContentOffset(CGPoint(x: 0, y: position), animated: false)
        lastScrollOffset = position
        savedScrollPosition = nil
    }

    private func restoreInitialSavedScrollPositionIfValid(reason: String, allowDeferral: Bool) {
        guard isTableVisibleForMutation, !tweets.isEmpty else { return }
        guard let position = savedScrollPosition ?? ScrollPositionManager.shared.getScrollPosition(for: feedIdentifier) else { return }
        guard !tableView.isTracking, !tableView.isDragging, !tableView.isDecelerating else { return }

        let minimumOffsetY = -tableView.adjustedContentInset.top
        let maximumOffsetY = max(
            minimumOffsetY,
            tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
        )

        if allowDeferral,
           position > minimumOffsetY + 1,
           maximumOffsetY <= minimumOffsetY + 1,
           tableView.numberOfRows(inSection: 0) > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.restoreInitialSavedScrollPositionIfValid(reason: reason, allowDeferral: false)
            }
            return
        }

        guard position >= minimumOffsetY, position <= maximumOffsetY else {
            savedScrollPosition = nil
            ScrollPositionManager.shared.clearScrollPosition(for: feedIdentifier)
            tableView.setContentOffset(CGPoint(x: 0, y: minimumOffsetY), animated: false)
            lastScrollOffset = minimumOffsetY
            print("[ScrollRestore] Cleared invalid saved position for \(feedIdentifier) during \(reason)")
            return
        }

        tableView.setContentOffset(CGPoint(x: 0, y: position), animated: false)
        lastContentOffset = position
        lastCallbackOffset = position
        lastScrollOffset = position
        savedScrollPosition = nil
        print("[ScrollRestore] Restored saved position for \(feedIdentifier) during \(reason), offset=\(Int(position))")
    }

    private func schedulePendingBackgroundResumeRestore(reason: String) {
        guard let snapshot = pendingBackgroundResumeSnapshot() else { return }

        cancelPendingBackgroundResumeRestores()
        let generation = backgroundResumeRestoreGeneration

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.backgroundResumeRestoreGeneration == generation else { return }
            if self.applyBackgroundResumeSnapshot(
                snapshot,
                reason: "\(reason)-settled",
                clearOnSuccess: true
            ) {
                self.scheduleVideoVisibilityRefresh(reason: "backgroundResumeRestore")
            }
            self.pendingBackgroundResumeRestoreWorks.removeAll()
        }
        pendingBackgroundResumeRestoreWorks.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    @discardableResult
    private func applyBackgroundResumeSnapshot(
        _ snapshot: BackgroundFeedResumeSnapshot,
        reason: String,
        clearOnSuccess: Bool
    ) -> Bool {
        guard isTableVisibleForMutation, !tweets.isEmpty else { return false }
        guard !tableView.isTracking,
              !tableView.isDragging,
              !tableView.isDecelerating,
              !isUserDragging,
              !isDecelerating else {
            print("[BackgroundResume] Restore skipped during user scroll for \(reason)")
            return false
        }

        let targetOffsetY: CGFloat?
        let anchorTweetId = snapshot.anchorTweetId ?? snapshot.topTweetId
        let anchorTweetOffsetY = snapshot.anchorTweetOffsetY ?? snapshot.topTweetOffsetY
        let anchorViewportY = snapshot.anchorViewportY ?? tableView.adjustedContentInset.top

        if let tweetId = anchorTweetId,
           let row = rowForTweetId(tweetId) {
            let indexPath = IndexPath(row: row, section: 0)
            let rowRect = tableView.rectForRow(at: indexPath)
            targetOffsetY = rowRect.minY + anchorTweetOffsetY - anchorViewportY
        } else if tableView.contentSize.height > snapshot.contentOffsetY {
            targetOffsetY = snapshot.contentOffsetY
        } else {
            targetOffsetY = nil
        }

        guard let targetOffsetY else {
            print("[BackgroundResume] Restore skipped; anchor not loaded for \(reason)")
            return false
        }

        let minimumOffsetY = -tableView.adjustedContentInset.top
        let maximumOffsetY = max(
            minimumOffsetY,
            tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
        )
        let boundedOffsetY = min(max(targetOffsetY, minimumOffsetY), maximumOffsetY)

        tableView.setContentOffset(CGPoint(x: 0, y: boundedOffsetY), animated: false)
        lastContentOffset = boundedOffsetY
        lastCallbackOffset = boundedOffsetY
        lastScrollOffset = boundedOffsetY

        if clearOnSuccess {
            BackgroundResumeStateStore.shared.clear(reason: "applied \(reason)")
        }

        print("[BackgroundResume] Restored feed snapshot via \(reason), anchor=\(anchorTweetId ?? "none"), offset=\(Int(boundedOffsetY))")
        return true
    }

    private func prefetchEmbeddedTweetIdsIfNeeded(_ tweetIds: Set<String>) {
        for tweetId in tweetIds {
            prefetchEmbeddedTweetIfNeeded(originalTweetId: tweetId)
        }
    }

    private func prefetchEmbeddedTweetIfNeeded(originalTweetId: String) {
        guard Tweet.getInstance(for: originalTweetId)?.author == nil else { return }
        guard !embeddedTweetPrefetchInFlight.contains(originalTweetId) else { return }

        embeddedTweetPrefetchInFlight.insert(originalTweetId)
        Task(priority: .utility) { [weak self] in
            let loadedTweet = await TweetCacheManager.shared.fetchTweet(mid: originalTweetId)
            guard let self else { return }
            self.embeddedTweetPrefetchInFlight.remove(originalTweetId)

            // The original may have arrived after the outer rows were first prewarmed. Warm
            // every quote that uses it now, before those rows approach the viewport.
            if loadedTweet != nil {
                let relatedQuotes = (self.pinnedTweets + self.tweets).filter {
                    $0.originalTweetId == originalTweetId
                }
                self.scheduleHeightPrewarm(for: relatedQuotes)

                // The deterministic height of every quote row flips from the placeholder
                // to the full embedded height the moment the original enters the singleton
                // cache — including rows far off screen. Reconcile them through the
                // anchor-preserving relayout (deferred to scroll-stop if the user is
                // mid-gesture); otherwise UIKit discovers each new height at realization
                // while scrolling up — one visible jump per quote row. Coalesced: a burst
                // of prefetch completions must produce ONE table pass, not one each.
                for quote in relatedQuotes {
                    self.pendingHeightRelayoutTweetIds.insert(quote.mid)
                }
                self.scheduleCoalescedHeightRelayout()
            }
        }
    }
    
    @objc private func handleRefresh() {
        Task {
            await onRefresh?()
            await MainActor.run {
                self.customRefreshControl?.endRefreshing()
            }
        }
    }
    
    // MARK: - Public API
    
    func updatePinnedTweets(_ tweets: [Tweet]) {
        if isTableAttachedForDataMutation, isScrollInteractionActive {
            deferredPinnedTweets = tweets
            return
        }

        let oldCount = pinnedTweets.count
        let oldPinnedTweets = pinnedTweets
        let oldOriginalTweetIds = Set(oldPinnedTweets.compactMap(\.originalTweetId))
        self.pinnedTweets = tweets

        guard isTableAttachedForDataMutation else {
            needsFullReloadAfterAttach = true
            return
        }

        let newOriginalTweetIds = Set(tweets.compactMap(\.originalTweetId))
        prefetchEmbeddedTweetIdsIfNeeded(newOriginalTweetIds.subtracting(oldOriginalTweetIds))

        // Check if same tweets in same order - only counts may have changed
        if oldCount == tweets.count && oldCount > 0 {
            var sameOrder = true
            for i in 0..<oldCount {
                if oldPinnedTweets[i].mid != tweets[i].mid {
                    sameOrder = false
                    break
                }
            }

            if sameOrder {
                // OPTIMIZATION: Same pinned tweets in same order - only hit counts changed
                // SwiftUI will automatically re-render action buttons via @Published properties

                // Still update visibility for video coordinator
                rebuildVideoListAndRefreshVisibility(reason: "pinnedTweetsSameOrder")
                scheduleVideoVisibilityRefresh(reason: "pinnedTweetsSameOrder")
                return
            }
        }

        // Reload table to reflect new pinned tweets
        isTableViewUpdating = true
        if oldCount != tweets.count {
            // Pinned row count changed (e.g. pinned tweets loaded after a restored
            // scroll position on re-open). reloadData preserves contentOffset in points,
            // but the added/removed pinned rows shift the regular content, so a restored
            // offset lands ~one row off. When scrolled down, restore the offset by the
            // height delta so the same content stays visible; at the very top, keep the
            // top so a fresh open still shows pinned + first regular.
            let topPosition = -tableView.adjustedContentInset.top
            let wasAtTop = tableView.contentOffset.y <= topPosition + 10
            let contentHeightBefore = tableView.contentSize.height
            let offsetBefore = tableView.contentOffset.y
            tableView.reloadData()
            tableView.layoutIfNeeded()
            if wasAtTop {
                tableView.setContentOffset(CGPoint(x: 0, y: topPosition), animated: false)
                lastContentOffset = topPosition
                lastCallbackOffset = topPosition
                lastScrollOffset = topPosition
            } else {
                let heightDelta = tableView.contentSize.height - contentHeightBefore
                if abs(heightDelta) > 0.5 {
                    let restoredOffset = offsetBefore + heightDelta
                    tableView.setContentOffset(CGPoint(x: 0, y: restoredOffset), animated: false)
                    lastContentOffset = restoredOffset
                    lastCallbackOffset = restoredOffset
                    lastScrollOffset = restoredOffset
                }
            }
        } else if oldCount > 0 {
            // Different tweets in same positions, update the content
            let indexPaths = (0..<oldCount).map { IndexPath(row: $0, section: 0) }
            tableView.reloadRows(at: indexPaths, with: .none)
        }
        isTableViewUpdating = false

        // CRITICAL: Update visibility after reload so coordinator knows pinned videos are visible
        rebuildVideoListAndRefreshVisibility(reason: "pinnedTweetsReload")
        scheduleVideoVisibilityRefresh(reason: "pinnedTweetsReload")
    }
    
    func updateTweets(_ newTweets: [Tweet], reloadSameOrderRows: Bool = false) {
        // A held pagination array is only valid against the state it was diffed from. Any
        // other update (prepend, delete, reorder) supersedes it — re-applying it later
        // could resurrect a deleted row. The append branch below re-arms it.
        pendingScrollDeferredTweets = nil
        let oldCount = tweets.count
        let oldTweets = tweets

        // Defer ALL structural table mutations while the user is scrolling.
        //
        // The old exception for "pagination append during scroll" (isPaginationAppendDuringScroll)
        // allowed insertRows to fire while the finger was still moving. On profile feeds embedded
        // in a SwiftUI UIViewControllerRepresentable, the UIKit/SwiftUI bridge can have a brief
        // window where view.window != nil (passing isTableVisibleForMutation) yet UIKit internally
        // marks the table outside its layout hierarchy. insertRows during that window triggers
        // "UITableView was told to layout outside view hierarchy" — UIKit then forces a full
        // re-layout of the entire table (expensive on large feeds) causing a ~1s freeze.
        //
        // Deferring until scroll stops is safe: applyDeferredTableChromeUpdatesAfterScroll is
        // called from scrollViewDidEndDragging / scrollViewDidEndDecelerating.
        if isTableAttachedForDataMutation, isScrollInteractionActive {
            deferredTweets = newTweets
            // Pre-warm text heights while the user is still scrolling so that by the time
            // scroll stops and insertRowsAtIndexPaths fires, estimatedHeightForRowAt is fast.
            scheduleHeightPrewarm(for: newTweets)
            return
        }

        // Skip all UIKit table operations if the view is not in the window hierarchy.
        // This can happen when a pending SwiftUI update fires after navigation has already
        // popped this view (e.g. immediately after logout). Updating a detached table view
        // causes UITableView row-count assertion failures.
        guard isTableAttachedForDataMutation else {
            tweets = newTweets
            needsFullReloadAfterAttach = true
            return
        }

        // Note: stale Tweet instance cleanup is handled by TweetListView's throttled
        // scheduleMemoryMaintenance (runs at most once per cleanupInterval), not here —
        // this function fires on every structural update and doing an unthrottled
        // Set(activeTweetIds) + cleanup sweep per update was pure duplicate work.

        let newOriginalTweetIds = Set(newTweets.compactMap(\.originalTweetId))

        tweets = newTweets
        
        
        // Handle initial load
        if oldCount == 0 && newTweets.count > 0 {
            prefetchEmbeddedTweetIdsIfNeeded(newOriginalTweetIds)
            scheduleHeightPrewarm(for: newTweets)
            isTableViewUpdating = true
            tableView.reloadData()
            isTableViewUpdating = false
            scheduleInitialSavedScrollPositionRestoreIfNeeded(reason: "initialTweets")
            rebuildVideoListAndRefreshVisibility(reason: "initialTweetsVideoList")
            schedulePendingBackgroundResumeRestore(reason: "initialTweets")
            scheduleAutoLoadMoreCheck(reason: "initialTweets")
            
            // Trigger video detection after initial load. Multiple passes are intentional:
            // cached startup rows can self-size/layout over several run-loop turns, and a
            // single early pass may only see the first visible media cell.
            scheduleVideoVisibilityRefresh(reason: "initialTweets")
            return
        }
        
        // Check if same tweets in same order - only counts may have changed
        if oldCount == newTweets.count {
            var sameOrder = true
            for i in 0..<oldCount {
                if oldTweets[i].mid != newTweets[i].mid {
                    sameOrder = false
                    break
                }
            }

            if sameOrder {
                if reloadSameOrderRows {
                    isTableViewUpdating = true
                    let indexPaths = (0..<oldCount).map { regularTweetIndexPath($0) }
                    tableView.reloadRows(at: indexPaths, with: .none)
                    isTableViewUpdating = false
                }
                scheduleVideoVisibilityRefresh(reason: "tweetsSameOrder")
                return
            }
        }

        let oldOriginalTweetIds = Set(oldTweets.compactMap(\.originalTweetId))
        prefetchEmbeddedTweetIdsIfNeeded(newOriginalTweetIds.subtracting(oldOriginalTweetIds))
        
        // Smart update: Check for common patterns
        // Lazy evaluation - only create ID arrays when needed
        var oldIds: [String]?
        var newIds: [String]?
        
        func getOldIds() -> [String] {
            if oldIds == nil { oldIds = oldTweets.map { $0.mid } }
            return oldIds!
        }
        
        func getNewIds() -> [String] {
            if newIds == nil { newIds = newTweets.map { $0.mid } }
            return newIds!
        }
        
        // Case 1: Tweets prepended (new tweets at top) - most common for new posts
        if newTweets.count > oldCount {
            let potentialPrependCount = newTweets.count - oldCount
            let afterNewOnes = Array(getNewIds().dropFirst(potentialPrependCount))

            if afterNewOnes == getOldIds() {
                scheduleHeightPrewarm(for: Array(newTweets.prefix(potentialPrependCount)))
                isTableViewUpdating = true
                let indexPaths = (0..<potentialPrependCount).map { regularTweetIndexPath($0) }
                if preservesScrollPositionOnPrepend {
                    // Main feed. At idle top (e.g. app open), let fresh top tweets surface.
                    // Once the user has started interacting, keep the same rows under them.
                    // insertRows above the viewport shifts content down without UIKit adjusting
                    // the offset, so restore by the inserted height.
                    let topPosition = -tableView.adjustedContentInset.top
                    let scrolledDown = tableView.contentOffset.y > topPosition + 10
                    if scrolledDown || isScrollInteractionActive {
                        let contentHeightBefore = tableView.contentSize.height
                        let contentOffsetBefore = tableView.contentOffset.y
                        tableView.insertRows(at: indexPaths, with: .none)
                        let heightDelta = tableView.contentSize.height - contentHeightBefore
                        if heightDelta > 0.5 {
                            tableView.setContentOffset(
                                CGPoint(x: 0, y: contentOffsetBefore + heightDelta),
                                animated: false
                            )
                        }
                    } else {
                        tableView.insertRows(at: indexPaths, with: .none)
                    }
                } else {
                    // Bounded feed (profile/list/bookmarks): never auto-scroll on prepend.
                    // If the feed is already at the top, render new tweets in place and keep
                    // the profile header visible. If the user is away from the top, preserve
                    // the visible content and let the banner tap perform the explicit scroll.
                    let topPosition = -tableView.adjustedContentInset.top
                    let wasAtTop = !isScrollInteractionActive
                        && tableView.contentOffset.y <= topPosition + 10

                    if wasAtTop {
                        tableView.insertRows(at: indexPaths, with: .none)
                        tableView.setContentOffset(CGPoint(x: 0, y: topPosition), animated: false)
                        lastContentOffset = topPosition
                        lastCallbackOffset = topPosition
                        lastScrollOffset = topPosition
                    } else {
                        let contentHeightBefore = tableView.contentSize.height
                        let contentOffsetBefore = tableView.contentOffset.y
                        tableView.insertRows(at: indexPaths, with: .none)
                        let heightDelta = tableView.contentSize.height - contentHeightBefore
                        if heightDelta > 0.5 {
                            let restoredOffset = contentOffsetBefore + heightDelta
                            tableView.setContentOffset(
                                CGPoint(x: 0, y: restoredOffset),
                                animated: false
                            )
                            lastContentOffset = restoredOffset
                            lastCallbackOffset = restoredOffset
                            lastScrollOffset = restoredOffset
                        }
                    }
                }
                isTableViewUpdating = false

                rebuildVideoListAndRefreshVisibility(reason: "tweetsPrependedVideoList")
                scheduleVideoVisibilityRefresh(reason: "tweetsPrepended")
                return
            }
        }
        
        // Case 2: Tweets appended (pagination) - common for load more
        if newTweets.count > oldCount {
            let newIdsPrefix = Array(getNewIds().prefix(oldCount))

            if newIdsPrefix == getOldIds() {
                guard tableView.window != nil else {
                    needsFullReloadAfterAttach = true
                    return
                }
                // Hold the append until the scroll stops — unless the user is close enough
                // to the end that they would actually run out of rows, in which case the
                // content matters more than the frame.
                if isScrollInteractionActive, !isRunningLowOnRowsBelowViewport() {
                    pendingScrollDeferredTweets = newTweets
                    return
                }
                scheduleHeightPrewarm(for: Array(newTweets.dropFirst(oldCount)))
                isTableViewUpdating = true
                let indexPaths = (oldCount..<newTweets.count).map { regularTweetIndexPath($0) }
                tableView.insertRows(at: indexPaths, with: .none)
                isTableViewUpdating = false
                rebuildVideoListAndRefreshVisibility(reason: "tweetsAppendedVideoList")
                scheduleVideoVisibilityRefresh(reason: "tweetsAppended")
                scheduleAutoLoadMoreCheck(reason: "tweetsAppended")
                return
            }
        }

        // Case 3: Single tweet removed - common for delete
        // OPTIMIZED: Use Set for O(1) lookup instead of O(n)
        if newTweets.count == oldCount - 1 {
            let newIdsSet = Set(getNewIds())
            if let removedIndex = getOldIds().firstIndex(where: { !newIdsSet.contains($0) }) {
                isTableViewUpdating = true
                tableView.deleteRows(at: [regularTweetIndexPath(removedIndex)], with: .automatic)
                isTableViewUpdating = false
                rebuildVideoListAndRefreshVisibility(reason: "tweetDeletedVideoList")
                scheduleVideoVisibilityRefresh(reason: "tweetDeleted")
                return
            }
        }

        // Complex change: compute minimal diff instead of full reload.
        // reloadData() tears down ALL visible cells (including video players),
        // causing flicker when only a few rows were inserted/removed.
        let diff = getNewIds().difference(from: getOldIds())

        if diff.isEmpty {
            // No structural changes - content-only updates handled by ObservableObject
            rebuildVideoListAndRefreshVisibility(reason: "emptyDiffVideoList")
            scheduleVideoVisibilityRefresh(reason: "emptyDiff")
            return
        }

        // Preserve the viewport across arbitrary diffs. Inserts/removals above the
        // visible rows shift content, and unlike the prepend/trim paths this one had no
        // offset compensation — a deferred server merge applied at scroll stop produced
        // a visible jump. Anchor by tweet ID (row indices change across the diff);
        // `tweets` already holds the new array here, so read ids from the visible cells.
        var anchorTweetId: String?
        var anchorOffset: CGFloat = 0
        for cell in tableView.visibleCells.sorted(by: { $0.frame.origin.y < $1.frame.origin.y }) {
            guard let tweetCell = cell as? TweetTableViewCell,
                  let tid = tweetCell.tweetId,
                  rowForTweetId(tid) != nil else { continue }
            anchorTweetId = tid
            anchorOffset = tableView.contentOffset.y - cell.frame.origin.y
            break
        }

        isTableViewUpdating = true
        tableView.performBatchUpdates {
            for change in diff {
                switch change {
                case .remove(let offset, _, _):
                    tableView.deleteRows(at: [regularTweetIndexPath(offset)], with: .none)
                case .insert(let offset, _, _):
                    tableView.insertRows(at: [regularTweetIndexPath(offset)], with: .none)
                }
            }
        }

        if let anchorTweetId, let row = rowForTweetId(anchorTweetId) {
            let newTop = tableView.rectForRow(at: IndexPath(row: row, section: 0)).origin.y
            let targetOffset = newTop + anchorOffset
            if abs(targetOffset - tableView.contentOffset.y) > 0.5 {
                tableView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
            }
        }
        isTableViewUpdating = false
        rebuildVideoListAndRefreshVisibility(reason: "diffUpdateVideoList")
        scheduleVideoVisibilityRefresh(reason: "diffUpdate")
        scheduleAutoLoadMoreCheck(reason: "diffUpdate")
    }

    /// Trims `tweets` back down to `targetCount` when it exceeds `maxCount`, keeping a
    /// window around whatever rows are currently on screen instead of always keeping the
    /// newest ones. A user scrolled deep into a long feed is looking at rows far from the
    /// top; blindly keeping `prefix(targetCount)` (as this used to do) would delete exactly
    /// the rows under their finger. Off-screen rows below the viewport are cheap to drop
    /// (nothing shifts). Off-screen rows above the viewport require a contentOffset
    /// compensation, mirrored from the prepend-insert logic in updateTweets, so removing
    /// them doesn't yank the visible content upward.
    func trimTweetsIfOverCapacity(maxCount: Int, targetCount: Int) {
        guard tweets.count > maxCount else { return }

        guard isTableAttachedForDataMutation else {
            // Not laid out — no viewport to protect, safe to keep the newest window.
            let trimmed = Array(tweets.prefix(targetCount))
            let removed = tweets.dropFirst(targetCount)
            for tweet in removed { Tweet.clearInstance(mid: tweet.mid) }
            tweets = trimmed
            onTweetsTrimmed?(trimmed)
            return
        }

        guard !isScrollInteractionActive else {
            pendingTrimRequest = (maxCount, targetCount)
            return
        }

        let oldCount = tweets.count
        let visibleRegularIndices = (tableView.indexPathsForVisibleRows ?? [])
            .map { $0.row - pinnedTweets.count }
            .filter { $0 >= 0 && $0 < oldCount }
        let firstVisible = visibleRegularIndices.min() ?? 0
        let lastVisible = visibleRegularIndices.max() ?? firstVisible

        let halfWindow = targetCount / 2
        var lowerBound = max(0, firstVisible - halfWindow)
        var upperBound = min(oldCount, lowerBound + targetCount)
        if upperBound - lowerBound < targetCount {
            lowerBound = max(0, upperBound - targetCount)
        }
        // Never trim rows that are actually on screen right now.
        lowerBound = min(lowerBound, firstVisible)
        upperBound = max(upperBound, lastVisible + 1)

        guard lowerBound > 0 || upperBound < oldCount else { return }

        let headTweets = lowerBound > 0 ? Array(tweets[0..<lowerBound]) : []
        let tailTweets = upperBound < oldCount ? Array(tweets[upperBound...]) : []
        let trimmedTweets = Array(tweets[lowerBound..<upperBound])

        // Index paths must be captured against the OLD (pre-trim) row layout —
        // deleteRows interprets them relative to the table's current rows.
        let headIndexPaths = (0..<lowerBound).map { regularTweetIndexPath($0) }
        let tailIndexPaths = (upperBound..<oldCount).map { regularTweetIndexPath($0) }

        let contentOffsetBefore = tableView.contentOffset.y
        let contentSizeBefore = tableView.contentSize.height

        // The data source must already reflect the final row count by the time
        // deleteRows is called — mutating `tweets` after issuing the delete (as an
        // earlier version of this code did) leaves numberOfRowsInSection returning
        // the stale count mid-update and trips UITableView's row-count assertion.
        isTableViewUpdating = true
        tweets = trimmedTweets
        tableView.deleteRows(at: headIndexPaths + tailIndexPaths, with: .none)
        isTableViewUpdating = false

        // Removing rows above the viewport shifts content up; compensate so the
        // rows the user is currently looking at don't jump.
        if !headTweets.isEmpty {
            let removedHeight = contentSizeBefore - tableView.contentSize.height
            if removedHeight > 0.5 {
                let minOffset = -tableView.adjustedContentInset.top
                let newOffset = max(minOffset, contentOffsetBefore - removedHeight)
                tableView.setContentOffset(CGPoint(x: 0, y: newOffset), animated: false)
            }
        }

        for tweet in headTweets + tailTweets {
            clearCachedHeight(for: tweet)
            Tweet.clearInstance(mid: tweet.mid)
        }

        print("⚠️ [MEMORY] Trimmed feed '\(feedIdentifier)' from \(oldCount) to \(trimmedTweets.count) (removed \(headTweets.count) head, \(tailTweets.count) tail)")

        // The video coordinator's allVideos list was built from the pre-trim tweets/row
        // layout. Without rebuilding it here, its index-to-row mapping goes stale after
        // the delete above — primary-video selection and on/off-screen detection then
        // compute against the wrong rows, which shows up as jumpy video during scroll.
        rebuildVideoListAndRefreshVisibility(reason: "tweetsTrimmedVideoList")
        scheduleVideoVisibilityRefresh(reason: "tweetsTrimmed")

        onTweetsTrimmed?(trimmedTweets)
    }

    private func scheduleAutoLoadMoreCheck(reason: String) {
        DispatchQueue.main.async { [weak self] in
            self?.triggerAutoLoadMoreIfNeeded(reason: reason, countsTowardScrollGestureLimit: false)
        }
    }

    private func triggerAutoLoadMoreIfNeeded(reason: String, countsTowardScrollGestureLimit: Bool) {
        guard hasMoreTweets, !isLoadingMore else { return }
        guard tableView.window != nil, tableView.numberOfRows(inSection: 0) > 0 else { return }
        guard let lastVisibleRow = tableView.indexPathsForVisibleRows?.last?.row else { return }

        // Loading-state and row-update callbacks are layout-driven, not evidence
        // that the user approached the bottom. A full first profile page already
        // has enough content; do not turn initial layout into page-1 prefetching.
        if feedIdentifier.hasPrefix("profile_"),
           !countsTowardScrollGestureLimit,
           tweets.count >= minimumProfileTweetsForInitialFill {
            return
        }

        let totalRows = pinnedTweets.count + tweets.count
        let remainingRows = max(0, totalRows - 1 - lastVisibleRow)
        guard remainingRows < dynamicLoadMoreTriggerRows() else { return }

        if countsTowardScrollGestureLimit {
            guard autoLoadMoreCountDuringCurrentScrollGesture < maxAutoLoadMorePerScrollGesture else { return }
            autoLoadMoreCountDuringCurrentScrollGesture += 1
        } else if let rowCountAtLastAutoLoad, totalRows <= rowCountAtLastAutoLoad {
            // The chained (non-gesture) path is driven by the isLoadingMore transition, not
            // by content arriving. When a page merges entirely into rows the feed already
            // has — the server's ranked feed hands back the same tweets under a new page
            // number, and appendTweetsPreservingOrder dedupes them — the row count does not
            // move, `remainingRows` stays under the threshold, and this fires again the
            // instant the page lands. That is an unbounded request loop: it only ends when
            // the server finally returns a partial page. Observed on device: 63 pages and
            // ~230 "valid" tweets fetched while the user had scrolled past 22 rows, each
            // one a round trip plus a table mutation landing mid-scroll.
            //
            // So: a page that added nothing does not earn another automatic page. The user
            // scrolling again goes through the branch above, which is capped per gesture.
            return
        }

        rowCountAtLastAutoLoad = totalRows
        triggerAutoLoadMore()
    }

    /// True when so few rows remain below the viewport that withholding freshly paginated
    /// rows would leave the user scrolling into the end of the list.
    private func isRunningLowOnRowsBelowViewport() -> Bool {
        guard let lastVisibleRow = tableView.indexPathsForVisibleRows?.last?.row else { return true }
        let totalRows = pinnedTweets.count + tweets.count
        return max(0, totalRows - 1 - lastVisibleRow) < loadMoreTriggerRows
    }

    /// Widens the load-more trigger distance during fast flings. A user flinging quickly
    /// through a long feed can cover a page's worth of rows before the network round-trip
    /// for the next page completes, hitting the bottom spinner mid-gesture. Scaling the
    /// trigger distance with scroll velocity buys enough runway for the fetch to land first.
    private func dynamicLoadMoreTriggerRows() -> Int {
        let velocity = abs(estimatedScrollVelocityY)
        guard velocity > 300 else { return loadMoreTriggerRows }

        let avgRowHeight: CGFloat = 250
        let leadTimeSeconds: CGFloat = 1.2
        let velocityRows = Int(ceil(velocity / avgRowHeight * leadTimeSeconds))
        return max(loadMoreTriggerRows, min(velocityRows, 40))
    }

    private var needsHeaderUpdate = false

    /// Rows that arrived from pagination while the feed was moving. Appending is not a
    /// jump risk — new rows go below the viewport — but the table pass plus the estimate
    /// query for every new row is main-actor work landing on a frame that is already
    /// building cells. Held here and applied at scroll stop, like
    /// `pendingHeightRelayoutTweetIds`.
    private var pendingScrollDeferredTweets: [Tweet]?

    /// Applies pagination rows that were held back during the scroll.
    private func flushScrollDeferredTweets() {
        guard let pending = pendingScrollDeferredTweets else { return }
        pendingScrollDeferredTweets = nil
        updateTweets(pending)
    }

    private var isScrollInteractionActive: Bool {
        tableView.isTracking
            || tableView.isDragging
            || tableView.isDecelerating
            || isUserDragging
            || isDecelerating
    }

    private func notifyScrollStateChanged(_ scrollView: UIScrollView) {
        let topPosition = -scrollView.adjustedContentInset.top
        let isAtTop = scrollView.contentOffset.y <= topPosition + 10
        onScrollStateChange?(scrollView.contentOffset.y, isAtTop, isScrollInteractionActive)
    }

    private func applyDeferredTableChromeUpdatesAfterScroll() {
        // Flush height reconciliations queued while the feed was hidden or mid-gesture
        // (async embedded loads, prefetch completions) before structural updates run.
        performPendingHeightRelayout()

        let hadDeferredTweets = deferredTweets != nil
        if let deferredTweets {
            self.deferredTweets = nil
            updateTweets(deferredTweets)
        }

        if needsHeaderUpdate {
            updateHeader()
        }

        if let deferredPinnedTweets {
            self.deferredPinnedTweets = nil
            updatePinnedTweets(deferredPinnedTweets)
        }

        if let pendingTrimRequest {
            self.pendingTrimRequest = nil
            trimTweetsIfOverCapacity(maxCount: pendingTrimRequest.maxCount, targetCount: pendingTrimRequest.targetCount)
        }

        // Hide the spinner now that deferred rows are in the table.
        // We only do this when there actually were deferred tweets so that a
        // spurious scroll-end event doesn't race with a legitimate pending hide.
        if hasPendingSpinnerHide && hadDeferredTweets {
            hasPendingSpinnerHide = false
            let shouldShow = pendingSpinnerShouldShowMessage
            pendingSpinnerShouldShowMessage = false
            // Respect the minimum display time even on the deferred path.
            if let startTime = loadingSpinnerStartTime {
                let remaining = max(0, minimumSpinnerDisplayTime - Date().timeIntervalSince(startTime))
                if remaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                        self?.hideSpinner(shouldShowMessage: shouldShow)
                    }
                } else {
                    hideSpinner(shouldShowMessage: shouldShow)
                }
            } else {
                hideSpinner(shouldShowMessage: shouldShow)
            }
        }

        applyPendingScrollRequestIfNeeded()
    }

    private func applyPendingDetachedTableReloadIfNeeded(reason: String) {
        guard needsFullReloadAfterAttach, isTableAttachedForDataMutation else { return }
        guard !isScrollInteractionActive else { return }

        needsFullReloadAfterAttach = false
        isTableViewUpdating = true
        tableView.reloadData()
        isTableViewUpdating = false
        if videoCoordinator.isFeedVisible {
            rebuildVideoListAndRefreshVisibility(reason: "\(reason)DetachedReload")
        }
        scheduleInitialSavedScrollPositionRestoreIfNeeded(reason: reason)
        if videoCoordinator.isFeedVisible {
            scheduleVideoVisibilityRefresh(reason: "\(reason)DetachedReload")
        }
    }

    private func applyPendingScrollRequestIfNeeded() {
        guard isTableVisibleForMutation, !isScrollInteractionActive, let request = pendingScrollRequest else { return }

        pendingScrollRequest = nil
        switch request {
        case .top:
            scrollToTop()
        case .firstRegularTweet:
            scrollToFirstRegularTweet()
        case .tweet(let tweetId):
            scrollToTweet(tweetId)
        }
    }

    func updateHeader() {
        // Defer header layout until the view is in the hierarchy to avoid
        // "UITableView layout outside view hierarchy" warnings.
        guard isTableVisibleForMutation else {
            needsHeaderUpdate = true
            return
        }
        guard !isScrollInteractionActive else {
            needsHeaderUpdate = true
            return
        }
        needsHeaderUpdate = false

        guard let headerBuilder = headerViewBuilder else {
            if tableView.tableHeaderView != nil {
                tableView.tableHeaderView = nil
            }
            lastHeaderLayoutWidth = 0
            return
        }
        
        // Create or update header hosting controller
        if headerHostingController == nil {
            // FIRST TIME: Create and set up header
            let headerView = headerBuilder()
            let hostingController = UIHostingController(rootView: headerView)
            hostingController.view.backgroundColor = .clear
            
            // CRITICAL: Disable safe area insets to prevent layout shifts
            hostingController.view.insetsLayoutMarginsFromSafeArea = false
            
            self.headerHostingController = hostingController
            addChild(hostingController)
            hostingController.didMove(toParent: self)
            
            guard let headerView = hostingController.view else { return }
            
            // Use frame-based layout (no constraints) to avoid width=0 conflicts
            // Calculate content width accounting for padding
            let tableWidth = max(tableView.bounds.width, 100) // Ensure minimum width
            lastHeaderLayoutWidth = tableWidth
            let contentWidth = tableWidth - (leadingPadding + trailingPadding)
            
            // Size the SwiftUI view properly
            headerView.translatesAutoresizingMaskIntoConstraints = true
            
            // Set a fixed width for the hosting controller to ensure proper layout
            hostingController.view.frame.size.width = contentWidth
            
            // Calculate the fitting height with the fixed width.
            // Use layoutFittingExpandedSize so SwiftUI text views return their ideal
            // (multi-line) height rather than the minimum (1-line) height.
            let targetSize = CGSize(width: contentWidth, height: UIView.layoutFittingExpandedSize.height)
            let fittingSize = hostingController.sizeThatFits(in: targetSize)
            
            // Set final frame with padding
            headerView.frame = CGRect(
                x: leadingPadding,
                y: 0,
                width: contentWidth,
                height: fittingSize.height
            )
            
            // Force layout to ensure SwiftUI calculates correctly
            headerView.setNeedsLayout()
            headerView.layoutIfNeeded()
            
            // Create container view and add header
            let containerView = UIView()
            containerView.backgroundColor = .clear
            containerView.frame = CGRect(x: 0, y: 0, width: tableWidth, height: fittingSize.height)
            containerView.addSubview(headerView)
            
            // Assign as table header view (ONLY ONCE)
            tableView.tableHeaderView = containerView
        } else {
            // SUBSEQUENT UPDATES: Only update content, don't reassign tableHeaderView unless necessary
            // This prevents scroll position jumps
            headerHostingController?.rootView = headerBuilder()

            // Defer the expensive SwiftUI measurement off the current run-loop turn.
            // layoutIfNeeded() + sizeThatFits() on the hosting controller are synchronous
            // SwiftUI layout passes that can block the main thread 200–500 ms on complex
            // profile headers, causing "System gesture gate timed out" during scroll.
            headerUpdateGeneration += 1
            let generation = headerUpdateGeneration
            Task { @MainActor [weak self] in
                guard let self,
                      self.headerUpdateGeneration == generation,
                      self.isTableVisibleForMutation,
                      let headerView = self.headerHostingController?.view,
                      let containerView = self.tableView.tableHeaderView else { return }

                let tableWidth = max(self.tableView.bounds.width, 100)
                self.lastHeaderLayoutWidth = tableWidth
                let contentWidth = tableWidth - (self.leadingPadding + self.trailingPadding)

                headerView.frame.size.width = contentWidth
                headerView.setNeedsLayout()
                headerView.layoutIfNeeded()

                let targetSize = CGSize(width: contentWidth, height: UIView.layoutFittingExpandedSize.height)
                let fittingSize = self.headerHostingController?.sizeThatFits(in: targetSize)
                    ?? CGSize(width: contentWidth, height: containerView.frame.height)

                let oldHeight = containerView.frame.height
                guard abs(oldHeight - fittingSize.height) > 1 else { return }

                let currentOffset = self.tableView.contentOffset
                let topInset = self.tableView.adjustedContentInset.top

                headerView.frame = CGRect(x: self.leadingPadding, y: 0, width: contentWidth, height: fittingSize.height)
                containerView.frame = CGRect(x: 0, y: 0, width: tableWidth, height: fittingSize.height)

                self.tableView.tableHeaderView = containerView

                let heightDiff = fittingSize.height - oldHeight
                let isAtTop = abs(currentOffset.y) < 10 || (topInset > 0 && abs(currentOffset.y + topInset) < 10)

                if isAtTop {
                    let properTopOffset = topInset > 0 ? -topInset : 0
                    UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
                        self.tableView.setContentOffset(CGPoint(x: 0, y: properTopOffset), animated: false)
                    }
                } else {
                    let newOffset = CGPoint(x: currentOffset.x, y: currentOffset.y + heightDiff)
                    self.tableView.setContentOffset(newOffset, animated: false)
                }
            }
        }
    }
    
    func updateLoadingState(
        isLoading: Bool,
        isLoadingMore: Bool,
        hasMoreTweets: Bool,
        canShowNoMoreTweetsMessage: Bool
    ) {
        // Track previous states
        let previousLoading = self.isLoading
        let previousLoadingMore = self.isLoadingMore
        let previousHasMoreTweets = self.hasMoreTweets
        let previousCanShowNoMoreTweetsMessage = self.canShowNoMoreTweetsMessage
        let stateChanged = previousLoading != isLoading
            || previousLoadingMore != isLoadingMore
            || previousHasMoreTweets != hasMoreTweets
            || previousCanShowNoMoreTweetsMessage != canShowNoMoreTweetsMessage
        
        self.isLoading = isLoading
        self.isLoadingMore = isLoadingMore
        self.hasMoreTweets = hasMoreTweets
        self.canShowNoMoreTweetsMessage = canShowNoMoreTweetsMessage

        if !canShowNoMoreTweetsMessage {
            clearNoMoreTweetsMessageIfNeeded()
        }

        guard stateChanged || needsFooterUpdate else { return }

        if hasMoreTweets && !isLoadingMore {
            scheduleAutoLoadMoreCheck(reason: "loadingState")
        }
        
        // ✅ FIX: Only log state changes, and avoid logging Date() or complex objects
        // Excessive logging can cause Xcode console to stop showing logs (FontServicesDaemonManager error)
        if stateChanged {
        }

        guard isTableVisibleForMutation else {
            // SwiftUI can deliver loading state before the UIKit table is attached.
            // Mutating tableFooterView while detached forces UIKit to lay out
            // visible rows outside the view hierarchy and emits a noisy warning.
            needsFooterUpdate = true
            loadingTimeoutTimer?.invalidate()
            loadingTimeoutTimer = nil
            return
        }
        needsFooterUpdate = false

        // Show/hide loading spinner with animations
        if isLoadingMore {
            // Don't show spinner if we just showed/have no-more-tweets message
            if isShowingNoMoreTweetsMessage || (!hasMoreTweets && lastNoMoreTweetsShownTime != nil) {
                let timeSinceMessage = lastNoMoreTweetsShownTime.map { Date().timeIntervalSince($0) } ?? 0
                if timeSinceMessage < 3.0 { return }
            }

            // Record when spinner was shown
            loadingSpinnerStartTime = Date()

            // Start timeout timer as safety measure
            loadingTimeoutTimer?.invalidate()
            loadingTimeoutTimer = Timer.scheduledTimer(withTimeInterval: maximumLoadingTime, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    if self.isLoadingMore {
                        self.updateLoadingState(
                            isLoading: self.isLoading,
                            isLoadingMore: false,
                            hasMoreTweets: self.hasMoreTweets,
                            canShowNoMoreTweetsMessage: self.canShowNoMoreTweetsMessage
                        )
                    }
                }
            }

            // Use taller footer to position spinner just above bottom nav bar
            let footerView = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 80))
            footerView.backgroundColor = .clear
            footerView.isUserInteractionEnabled = false

            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.center = CGPoint(x: footerView.bounds.width / 2, y: 30)
            spinner.isUserInteractionEnabled = false
            spinner.startAnimating()
            footerView.addSubview(spinner)

            // Fade in and slide up animation
            footerView.alpha = 0
            footerView.transform = CGAffineTransform(translationX: 0, y: 20)
            tableView.tableFooterView = footerView

            UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
                footerView.alpha = 1.0
                footerView.transform = .identity
            }
        } else {
            // Hide spinner, but ensure minimum display time
            if let startTime = loadingSpinnerStartTime {
                let elapsedTime = Date().timeIntervalSince(startTime)
                let remainingTime = max(0, minimumSpinnerDisplayTime - elapsedTime)

                // Check if we should show "no more tweets" message
                let shouldShowMessage = previousLoadingMore
                    && canShowNoMoreTweetsMessage
                    && tweets.count > 0

                // Add cooldown check
                let canShowMessage: Bool
                if let lastShown = lastNoMoreTweetsShownTime {
                    canShowMessage = Date().timeIntervalSince(lastShown) > noMoreTweetsMessageCooldown
                } else {
                    canShowMessage = true
                }

                // If new rows are deferred behind an active scroll gesture, keep the spinner
                // visible until applyDeferredTableChromeUpdatesAfterScroll commits them.
                // Hiding now creates a gap: spinner gone but rows still pending finger lift.
                if deferredTweets != nil {
                    if !hasPendingSpinnerHide {
                        hasPendingSpinnerHide = true
                        pendingSpinnerShouldShowMessage = shouldShowMessage && canShowMessage
                        loadingTimeoutTimer?.invalidate()
                        loadingTimeoutTimer = nil
                    }
                    return
                }

                if remainingTime > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + remainingTime) { [weak self] in
                        guard let self = self else { return }
                        self.hideSpinner(shouldShowMessage: shouldShowMessage && canShowMessage)
                    }
                } else {
                    hideSpinner(shouldShowMessage: shouldShowMessage && canShowMessage)
                }
            } else {
                // No start time recorded, hide immediately
                // Don't clear footer if we're showing the "no more tweets" message
                if isShowingNoMoreTweetsMessage { return }
                tableView.tableFooterView = nil
            }
        }
    }

    private func hideSpinner(shouldShowMessage: Bool) {
        // Cancel timeout timer since loading completed normally
        loadingTimeoutTimer?.invalidate()
        loadingTimeoutTimer = nil

        guard isTableVisibleForMutation else {
            needsFooterUpdate = true
            loadingSpinnerStartTime = nil
            return
        }

        // Don't hide spinner if we're showing the "no more tweets" message
        if isShowingNoMoreTweetsMessage {
            loadingSpinnerStartTime = nil
            return
        }

        guard let footerView = tableView.tableFooterView else {
            loadingSpinnerStartTime = nil
            if shouldShowMessage {
                showNoMoreTweetsMessage()
            }
            return
        }
        
        // Fade out and slide down animation
        UIView.animate(withDuration: 0.2, animations: {
            footerView.alpha = 0
            footerView.transform = CGAffineTransform(translationX: 0, y: 10)
        }) { [weak self] _ in
            guard let self = self else { return }
            if self.tableView.tableFooterView === footerView {
                self.tableView.tableFooterView = nil
            }
            self.loadingSpinnerStartTime = nil

            if shouldShowMessage {
                self.showNoMoreTweetsMessage()
            }
        }
    }
    
    // MARK: - UITableViewDataSource
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return pinnedTweets.count + tweets.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let __stallStart = CACurrentMediaTime()
        defer {
            let elapsedMs = (CACurrentMediaTime() - __stallStart) * 1000
            if elapsedMs >= StallLog.thresholdMs {
                print("⏱️ [STALL] cellForRowAt row=\(indexPath.row) took \(String(format: "%.1f", elapsedMs))ms scrolling=\(isUserDragging || isDecelerating)")
            }
        }
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: TweetTableViewCell.reuseIdentifier,
            for: indexPath
        ) as? TweetTableViewCell else {
            return UITableViewCell()
        }

        // First N rows are pinned tweets, rest are regular tweets
        let tweet: Tweet
        if indexPath.row < pinnedTweets.count {
            tweet = pinnedTweets[indexPath.row]
        } else {
            tweet = tweets[indexPath.row - pinnedTweets.count]
        }

        let effectiveEmbeddedTweetId = effectiveEmbeddedTweetId(for: tweet)
        if let effectiveEmbeddedTweetId {
            prefetchEmbeddedTweetIfNeeded(originalTweetId: effectiveEmbeddedTweetId)
        }

        let totalRows = pinnedTweets.count + tweets.count
        let isLastItem = indexPath.row == totalRows - 1
        let isLastPinnedTweet = !pinnedTweets.isEmpty && indexPath.row == pinnedTweets.count - 1

        if let hprose = hproseInstance {
            cell.configure(
                with: tweet,
                hproseInstance: hprose,
                isPinned: indexPath.row < pinnedTweets.count,
                isLastPinnedTweet: isLastPinnedTweet,
                isLastItem: isLastItem || isLastPinnedTweet,
                parentViewController: self,
                leadingPadding: leadingPadding,
                trailingPadding: trailingPadding,
                rowWidth: currentRowLayoutWidth,
                videoCoordinator: videoCoordinator,
                onAvatarTap: { [weak self] user in
                    guard user.hasValidUsername else { return }
                    self?.onAvatarTap?(user)
                },
                onTweetTap: onTweetTap,
                onShowLogin: onShowLogin,
                onShowToast: onShowToast,
                allowDeleteAll: allowDeleteAll,
                savedParentTweetId: tweet.originalTweetId == nil ? effectiveEmbeddedTweetId : nil
            )
        }

        cell.onRetweetUnavailable = { [weak self, weak cell] tweetId in
            guard let self, let cell, cell.tweetId == tweetId else { return }
            cell.isHidden = true
            self.onRetweetUnavailable?(tweetId)
        }

        // Content expansion callback — fires when user taps "More..." to expand truncated text.
        // expandedTweetIds makes heightForRowAt return automaticDimension so the table
        // re-measures the cell at expanded height instead of using the cached truncated value.
        cell.onContentExpanded = { [weak self, weak cell] in
            guard let self, let cell,
                  let indexPath = self.tableView.indexPath(for: cell),
                  let tweet = self.tweetForRow(indexPath.row) else { return }

            self.expandedTweetIds.insert(tweet.mid)
            self.clearCachedHeight(for: tweet)

            if self.isScrollInteractionActive {
                self.pendingHeightRelayoutTweetIds.insert(tweet.mid)
                self.pendingExpansionAnchorTweetId = tweet.mid
            } else {
                self.performPendingHeightRelayout(include: tweet.mid, anchorTweetId: tweet.mid)
            }
        }

        // Live content/title/attachment updates are not user expansion. Queue the row for
        // the anchor-preserving relayout, which recomputes the deterministic height and
        // mutates the table only once momentum stops. Do NOT clear the cached height here:
        // heightForRowAt serves cache-first, so the intact cache keeps reporting the OLD
        // height until the relayout applies the new one under an anchor. Clearing it (as
        // this used to) let calculateTweetHeight's answer flip mid-scroll (embedded tweet
        // placeholder → loaded) and destroyed the persisted height on every async embedded
        // configure — quote rows never kept a stable height, so each scroll-up pass
        // rediscovered their heights at realization time as a visible jump.
        cell.onContentDidChangeHeightAsync = { [weak self, weak cell] in
            guard let self, let cell,
                  let indexPath = self.tableView.indexPath(for: cell),
                  let tweet = self.tweetForRow(indexPath.row) else { return }

            self.expandedTweetIds.remove(tweet.mid)
            if self.isScrollInteractionActive {
                self.pendingHeightRelayoutTweetIds.insert(tweet.mid)
            } else {
                self.performPendingHeightRelayout(include: tweet.mid)
            }
        }

        return cell
    }
    
    // MARK: - UITableViewDelegate

    private func pinnedTweetsDividerHeight(forRow row: Int) -> CGFloat {
        !pinnedTweets.isEmpty && row == pinnedTweets.count - 1
            ? TweetTableViewCell.pinnedTweetsDividerHeight
            : 0
    }

    override func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        let totalRows = pinnedTweets.count + tweets.count
        guard indexPath.row < totalRows else { return 200 }

        let tweet: Tweet
        if indexPath.row < pinnedTweets.count {
            tweet = pinnedTweets[indexPath.row]
        } else {
            let regularIndex = indexPath.row - pinnedTweets.count
            guard regularIndex < tweets.count else { return 200 }
            tweet = tweets[regularIndex]
        }

        let layoutWidth = currentRowLayoutWidth
        let dividerHeight = pinnedTweetsDividerHeight(forRow: indexPath.row)

        // Use in-memory cached height if available — set by willDisplay from actual Auto Layout
        if let cachedHeight = cachedHeight(for: tweet, width: layoutWidth) {
            return cachedHeight + dividerHeight
        }

        if FeedLayoutMode.selfSizing {
            // The real "delete the calculator" configuration: never compute a height, and
            // for a row never yet displayed give UIKit a flat guess, exactly what a
            // LazyColumn would have (nothing). Everything below this line is the machinery
            // under test.
            return TweetHeightCache.shared.getHeight(for: tweet.mid, width: layoutWidth)
                .map { $0 + dividerHeight } ?? 400
        }

        // Use persisted height cache (survives app restarts) as second-best estimate.
        // This prevents scroll jumps for previously-viewed tweets on cold start.
        // NOTE: Do NOT set tweet.cachedHeight here — persisted heights may be stale
        // (e.g., from a session where the cell didn't fully render). Only willDisplay
        // should set cachedHeight after Auto Layout verifies the actual height.
        if let persistedHeight = TweetHeightCache.shared.getHeight(for: tweet.mid, width: layoutWidth) {
            return persistedHeight + dividerHeight
        }

        // Check if the per-tweet text-height cache (set by a prior calculateTweetHeight call) is
        // warm for the display tweet. If it is, calculateTweetHeight skips both
        // makeContentAttributedString and UILabel.sizeThatFits and runs in <0.1 ms.
        //
        // estimatedHeightForRowAt is called for EVERY row during insertRowsAtIndexPaths
        // (UITableView needs the total section height for scroll indicators). For brand-new
        // tweets whose text hasn't been typeset yet, the full calculateTweetHeight path takes
        // ~15 ms/tweet — 50 new tweets = ~750 ms main-thread freeze. To avoid this, fall back
        // to a cheap character-count estimate for cold tweets. heightForRowAt (called only for
        // the ~7 visible rows) still runs the accurate calculateTweetHeight and populates the
        // cache, so the estimate is only used once per tweet.
        let padding = leadingPadding + trailingPadding
        let contentWidth = layoutWidth - padding - 3 - 46 - 4

        let isRetweet = tweet.originalTweetId != nil && tweet.originalAuthorId != nil
        let hasOwnContent = (tweet.content != nil && !(tweet.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
            || (tweet.attachments != nil && !(tweet.attachments?.isEmpty ?? true))
        let isPureRetweet = isRetweet && !hasOwnContent
        let displayTweet: Tweet
        if isPureRetweet, let originalId = tweet.originalTweetId,
           let original = Tweet.getInstance(for: originalId), original.author != nil {
            displayTweet = original
        } else {
            displayTweet = tweet
        }

        // Fast path: text height already computed this session — calculateTweetHeight is cheap.
        // For quote-tweets, calculateTweetHeight ALSO measures the embedded/original tweet's text
        // (a separate cache keyed on the embedded Tweet instance). If the embedded tweet's instance
        // was recreated (e.g. evicted by memory trimming/cleanup and re-fetched), its cache is cold
        // even though the quoting tweet's own cache is warm — so this must gate on BOTH caches or
        // the "fast path" silently pays full CoreText typesetting cost for the embedded content.
        var textCacheWarm = displayTweet.cachedMeasuredTextHeight >= 0
            && displayTweet.cachedMeasuredTextWidth == contentWidth
        if textCacheWarm, isRetweet, hasOwnContent,
           let originalId = tweet.originalTweetId,
           let embeddedTweet = Tweet.getInstance(for: originalId),
           embeddedTweet.author != nil,
           let embeddedContent = embeddedTweet.content,
           !embeddedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let embeddedWidth = contentWidth - 12
            textCacheWarm = embeddedTweet.cachedMeasuredTextHeight >= 0
                && embeddedTweet.cachedMeasuredTextWidth == embeddedWidth
        }
        if textCacheWarm {
            return Self.calculateTweetHeight(for: tweet, rowWidth: layoutWidth, cellHorizontalPadding: padding)
                + dividerHeight
        }

        // A prewarm normally publishes the same numeric height to the Tweet first. This lookup
        // covers the brief fallback where the background estimate exists without a live instance.
        let prewarmTextH = TweetHeightPrewarmer.shared.get(tweetId: displayTweet.mid, width: contentWidth)

        // Cold path: use a sub-millisecond character-count heuristic to avoid CoreText layout.
        return Self.roughHeightEstimate(for: tweet, displayTweet: displayTweet,
                                        isPureRetweet: isPureRetweet,
                                        isRetweet: isRetweet, hasOwnContent: hasOwnContent,
                                        rowWidth: layoutWidth, contentWidth: contentWidth,
                                        cellHorizontalPadding: padding,
                                        prewarmTextHeight: prewarmTextH) + dividerHeight
    }

    /// Adds every fixed attachment component using the same metrics that TweetBodyUIView
    /// applies to its arranged subviews. Text height is supplied separately because that is
    /// the only expensive measurement and is prewarmed off the main thread.
    @discardableResult
    private static func addAttachmentHeights(
        for tweet: Tweet,
        contentWidth: CGFloat,
        hasTextContent: Bool,
        to bodyHeight: inout CGFloat
    ) -> Bool {
        let attachments = tweet.attachments ?? []
        let audioAttachments = attachments.filter { $0.type == .audio }
        let mediaAttachments = attachments.filter { TweetBodyUIView.isMediaType($0.type) }
        let documentAttachments = attachments.filter { TweetBodyUIView.isDocumentType($0.type) }

        var hasCaptionLabel = false
        if mediaAttachments.count == 1 {
            let attachment = mediaAttachments[0]
            if attachment.type == .video || attachment.type == .hls_video {
                let hasTitle = tweet.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                let hasFileName = attachment.fileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                hasCaptionLabel = hasTitle || (hasFileName && !hasTextContent)
            }
        }

        // TweetBodyUIView.contentStack is a UIStackView over
        // [contentLabel, audioContainer, mediaContainer, captionLabel, documentContainer].
        // A hidden arranged subview contributes NEITHER its height NOR the custom spacing
        // that follows it, so the gaps have to be counted between consecutive VISIBLE
        // items — not once per attachment kind. Every gap configure() installs is 8pt
        // except media → caption, which is 2pt.
        enum Item { case text, audio, media, caption, docs }
        var visible: [(Item, CGFloat)] = []
        if hasTextContent {
            // Height already added by the caller; only its position in the stack matters.
            visible.append((.text, 0))
        }
        if !audioAttachments.isEmpty {
            visible.append((.audio, TweetBodyUIView.audioPlaylistHeight))
        }
        if !mediaAttachments.isEmpty {
            // MediaGridUIView reports ceil() of this as its intrinsic height, so the row
            // calculator has to round the same way or every media row is a fraction short.
            visible.append((.media, ceil(MediaGridViewModel.calculateHeight(
                for: mediaAttachments,
                gridWidth: max(10, contentWidth - 2)
            ))))
        }
        if hasCaptionLabel {
            // Single line, so the label's fitting height is the font's line height.
            visible.append((.caption, UIFont.systemFont(ofSize: 14).lineHeight))
        }
        if !documentAttachments.isEmpty {
            visible.append((.docs, TweetBodyUIView.documentAttachmentsHeight(for: documentAttachments)))
        }

        var previous: Item?
        for (item, height) in visible {
            if let previous {
                bodyHeight += (previous == .media && item == .caption) ? 2 : 8
            }
            bodyHeight += height
            previous = item
        }

        return hasCaptionLabel
    }

    /// Height estimate for tweets whose UILabel-accurate text height is not yet in cache.
    ///
    /// When prewarmTextHeight is provided (background boundingRect measurement), it replaces
    /// the char-count heuristic for the text portion — accuracy within ~1 pt of UILabel.
    /// When nil, falls back to a sub-millisecond character-count approximation.
    /// Called only from estimatedHeightForRowAt; heightForRowAt uses calculateTweetHeight.
    private static func roughHeightEstimate(
        for tweet: Tweet,
        displayTweet: Tweet,
        isPureRetweet: Bool,
        isRetweet: Bool,
        hasOwnContent: Bool,
        rowWidth: CGFloat,
        contentWidth: CGFloat,
        cellHorizontalPadding: CGFloat,
        prewarmTextHeight: CGFloat? = nil
    ) -> CGFloat {
        var height: CGFloat = isPureRetweet ? 26 : 16
        // Must stay a constant: this runs for every row of an inserted page. See the
        // note in calculateTweetHeight.
        height += ceil(UIFont.preferredFont(forTextStyle: .headline).lineHeight)
        height += 2 // contentColumn spacing after header

        var bodyHeight: CGFloat = 2
        var hasTextContent = false

        if let content = displayTweet.content,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hasTextContent = true
            if let prewarmH = prewarmTextHeight {
                // Background TextKit1 layout — within ~1pt of UILabel. Used as-is: rounding
                // it here would make this estimate disagree with the calculateTweetHeight
                // that heightForRowAt runs for the same tweet a moment later.
                bodyHeight += prewarmH
            } else {
                bodyHeight += TweetBodyUIView.estimatedTextHeight(
                    for: content, availableWidth: contentWidth
                )
            }
        }

        let hasCaptionLabel = addAttachmentHeights(
            for: displayTweet,
            contentWidth: contentWidth,
            hasTextContent: hasTextContent,
            to: &bodyHeight
        )

        height += bodyHeight
        height += isRetweet && hasOwnContent ? 12 : (hasCaptionLabel ? 4 : 10)

        if isRetweet && hasOwnContent {
            if let originalId = tweet.originalTweetId,
               let embeddedTweet = Tweet.getInstance(for: originalId),
               embeddedTweet.author != nil {
                // Rough embedded estimate: fixed header + approximate text + media.
                let embeddedContentWidth = contentWidth - 12
                let hasEmbeddedText = embeddedTweet.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                var embeddedBodyH: CGFloat = 2
                if hasEmbeddedText {
                    let embeddedWidth = embeddedContentWidth
                    if embeddedTweet.cachedMeasuredTextWidth == embeddedWidth,
                       embeddedTweet.cachedMeasuredTextHeight >= 0 {
                        embeddedBodyH += embeddedTweet.cachedMeasuredTextHeight
                    } else if let prewarmHeight = TweetHeightPrewarmer.shared.get(
                        tweetId: embeddedTweet.mid,
                        width: embeddedWidth
                    ) {
                        embeddedBodyH += prewarmHeight
                    } else {
                        embeddedBodyH += TweetBodyUIView.estimatedTextHeight(
                            for: embeddedTweet.content ?? "", availableWidth: embeddedWidth
                        )
                    }
                }
                _ = addAttachmentHeights(
                    for: embeddedTweet,
                    contentWidth: embeddedContentWidth,
                    hasTextContent: hasEmbeddedText,
                    to: &embeddedBodyH
                )
                let embeddedHeaderHeight = max(
                    CGFloat(32),
                    TweetHeaderUIView.measuredHeaderHeight(
                        for: embeddedTweet,
                        availableWidth: embeddedContentWidth - 32 - 6
                    )
                )
                let embeddedHeight: CGFloat = 8 + embeddedHeaderHeight + 4 + embeddedBodyH + EmbeddedTweetUIView.contentBottomPadding
                height += embeddedHeight
            } else {
                height += EmbeddedTweetUIView.placeholderHeight
            }
            height += 10
        }

        height += 30 + 8 + 1
        return height
    }

    /// Shared UILabel for text height measurement — matches UILabel's exact rendering.
    /// Using boundingRect() with .byWordWrapping/.byTruncatingTail can disagree with
    /// UILabel's TextKit2 layout by ~1pt (constant) or ~20pt (line-break differences).
    private static let measurementLabel: UILabel = {
        let label = UILabel()
        label.font = TweetBodyUIView.contentFont
        label.numberOfLines = TweetBodyUIView.maxContentLines
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    /// Deterministic height calculation matching TweetCellContentView's Auto Layout.
    static func calculateTweetHeight(
        for tweet: Tweet,
        rowWidth: CGFloat? = nil,
        cellHorizontalPadding: CGFloat = 16
    ) -> CGFloat {
        // Determine if this is a pure retweet (show original content) or regular/quoted
        let isRetweet = tweet.originalTweetId != nil && tweet.originalAuthorId != nil
        let hasOwnContent = (tweet.content != nil && !(tweet.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
            || (tweet.attachments != nil && !(tweet.attachments?.isEmpty ?? true))
        let isPureRetweet = isRetweet && !hasOwnContent

        let displayTweet: Tweet
        if isPureRetweet, let originalId = tweet.originalTweetId,
           let original = Tweet.getInstance(for: originalId), original.author != nil {
            displayTweet = original
        } else {
            displayTweet = tweet
        }

        var height: CGFloat = 0

        // Top padding
        if isPureRetweet {
            // Banner at topAnchor+6, height 18, mainStack 2pt below banner
            height += 6 + 18 + 2
        } else {
            // mainStackTopDefault: topAnchor + 16
            height += 16
        }

        // Body: text + media
        // TweetBodyUIView layout: contentStack.top = bodyView.top + 2 (always)
        // contentLabel → media: customSpacing = 8 when text visible
        let effectiveRowWidth = (rowWidth ?? UIScreen.main.bounds.width)
        let contentWidth = (
            effectiveRowWidth
            - cellHorizontalPadding
            - 3 /* leading */
            - 46 /* avatar */
            - 4 /* stack spacing */
        )

        // Header: single-line height of .headline.
        //
        // The label is `numberOfLines = 2`, so this under-reports a header whose
        // name + @username + timestamp wraps. Measuring it properly was tried and
        // REVERTED: `measuredHeaderHeight` runs a UILabel/CoreText pass, and
        // `estimatedHeightForRowAt` is called for EVERY row when a paginated page is
        // inserted — 10-20 cold tweets at once, on the main thread, inside
        // `updateTweets`. Measured on device: an 837ms stall and a 395ms
        // `cellForRowAt`. A per-tweet cache does not help, because the rows being
        // inserted are precisely the ones whose cache is cold.
        //
        // Safe to approximate here: both this and `roughHeightEstimate` use the same
        // constant, so it is a uniform offset, never an estimate-vs-actual MISMATCH —
        // and mismatch is what moves the list. Fixing it properly means measuring the
        // header off the main thread in TweetHeightPrewarmer, not inline.
        let headerHeight = ceil(UIFont.preferredFont(forTextStyle: .headline).lineHeight)
        height += headerHeight
        height += 2 // contentColumn spacing after header

        // bodyHeight mirrors TweetBodyUIView's contentStack Auto Layout
        var bodyHeight: CGFloat = 2 // contentStack.top offset (always present)
        var hasTextContent = false

        if let content = displayTweet.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hasTextContent = true
            // The attributed string is ONLY an input to the sizeThatFits pass below, so
            // build it only when that pass actually has to run. TweetHeightPrewarmer
            // publishes cachedMeasuredTextHeight from a background thread but
            // deliberately does not publish the attributed string (it avoids sending it
            // across the actor boundary), so building it up front meant every prewarmed
            // tweet re-ran CoreText typesetting on the main thread and then threw the
            // result away — expensive enough with CJK content to stall the scroll when
            // a paginated page was inserted.
            let measuredTextHeight: CGFloat
            if displayTweet.cachedMeasuredTextWidth == contentWidth && displayTweet.cachedMeasuredTextHeight >= 0 {
                measuredTextHeight = displayTweet.cachedMeasuredTextHeight
            } else {
                // Build (or retrieve cached) attributed string — single typesetting pass
                let attrString: NSAttributedString
                if let cached = displayTweet.cachedContentAttributedString,
                   displayTweet.cachedContentWidth == contentWidth {
                    attrString = cached
                } else {
                    attrString = TweetBodyUIView.makeContentAttributedString(
                        content: content, availableWidth: contentWidth
                    )
                    displayTweet.cachedContentAttributedString = attrString
                    displayTweet.cachedContentWidth = contentWidth
                }
                // Use shared UILabel for exact height matching (avoids boundingRect vs UILabel diffs).
                // Cache the sizeThatFits result so repeated willDisplay / heightForRowAt calls skip
                // the TextKit layout pass for already-measured tweets.
                Self.measurementLabel.attributedText = attrString
                measuredTextHeight = Self.measurementLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height
                displayTweet.cachedMeasuredTextHeight = measuredTextHeight
                displayTweet.cachedMeasuredTextWidth = contentWidth
                // Republish into the prewarmer so estimatedHeightForRowAt can never keep
                // serving a background measurement that this UILabel pass has superseded:
                // the two caches are read by different code paths for the same row, and a
                // disagreement between them shows up as contentSize moving mid-scroll.
                TweetHeightPrewarmer.shared.set(measuredTextHeight,
                                                tweetId: displayTweet.mid, width: contentWidth)
            }
            bodyHeight += measuredTextHeight
        }

        let hasCaptionLabel = addAttachmentHeights(
            for: displayTweet,
            contentWidth: contentWidth,
            hasTextContent: hasTextContent,
            to: &bodyHeight
        )

        height += bodyHeight

        // Spacing after body (matches updateBodyToActionSpacing)
        // Quoted tweets: 12pt body→embedded; Regular: caption ? 4 : 10 body→action
        if isRetweet && hasOwnContent {
            height += 12
        } else {
            height += hasCaptionLabel ? 4 : 10
        }

        // Embedded/quoted tweet (only for quoted tweets, not pure retweets)
        if isRetweet && hasOwnContent {
            if let originalId = tweet.originalTweetId,
               let embeddedTweet = Tweet.getInstance(for: originalId),
               embeddedTweet.author != nil {
                // EmbeddedTweetUIView layout:
                //   8pt top padding
                //   contentStack = max(40, textStack)
                //     textStack = headerView(24) + bodyView
                //   bottomPadding = EmbeddedTweetUIView.contentBottomPadding
                //
                // TweetBodyUIView (embedded) layout:
                //   2pt contentStack top
                //   contentLabel (if text) + 8pt spacing (to mediaContainer)
                //   mediaContainer (mediaH) + 2pt spacing (if caption visible) + caption(17)

                let hasEmbeddedText = embeddedTweet.content != nil &&
                    !(embeddedTweet.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

                // Calculate embedded bodyView height (matches TweetBodyUIView auto layout)
                var embeddedBodyH: CGFloat = 2 // contentStack top padding

                if hasEmbeddedText {
                    // bodyView spans full EmbeddedTweetUIView contentStack width (NOT beside avatar).
                    // Embedded wrapper extends 4pt left, then embedded content adds 8pt side insets.
                    let embeddedWidth = contentWidth - 12
                    // Same as above: only typeset when the measured height isn't already known.
                    let embeddedTextHeight: CGFloat
                    if embeddedTweet.cachedMeasuredTextWidth == embeddedWidth && embeddedTweet.cachedMeasuredTextHeight >= 0 {
                        embeddedTextHeight = embeddedTweet.cachedMeasuredTextHeight
                    } else {
                        // Build (or retrieve cached) attributed string for embedded tweet
                        let attrString: NSAttributedString
                        if let cached = embeddedTweet.cachedContentAttributedString,
                           embeddedTweet.cachedContentWidth == embeddedWidth {
                            attrString = cached
                        } else {
                            attrString = TweetBodyUIView.makeContentAttributedString(
                                content: embeddedTweet.content!, availableWidth: embeddedWidth
                            )
                            embeddedTweet.cachedContentAttributedString = attrString
                            embeddedTweet.cachedContentWidth = embeddedWidth
                        }
                        Self.measurementLabel.attributedText = attrString
                        embeddedTextHeight = Self.measurementLabel.sizeThatFits(CGSize(width: embeddedWidth, height: .greatestFiniteMagnitude)).height
                        embeddedTweet.cachedMeasuredTextHeight = embeddedTextHeight
                        embeddedTweet.cachedMeasuredTextWidth = embeddedWidth
                        TweetHeightPrewarmer.shared.set(embeddedTextHeight,
                                                        tweetId: embeddedTweet.mid, width: embeddedWidth)
                    }
                    embeddedBodyH += embeddedTextHeight
                }

                _ = addAttachmentHeights(
                    for: embeddedTweet,
                    contentWidth: contentWidth - 12,
                    hasTextContent: hasEmbeddedText,
                    to: &embeddedBodyH
                )

                // EmbeddedTweetUIView.contentStack (spacing=4):
                //   headerRow height = max(32pt avatar, measured two-line header)
                //   bodyView height = embeddedBodyH
                let embeddedContentWidth = contentWidth - 12
                let embeddedHeaderWidth = embeddedContentWidth - 32 - 6
                let embeddedHeaderHeight = max(
                    CGFloat(32),
                    TweetHeaderUIView.measuredHeaderHeight(
                        for: embeddedTweet,
                        availableWidth: embeddedHeaderWidth
                    )
                )
                let embeddedHeight: CGFloat = 8 + embeddedHeaderHeight + 4 + embeddedBodyH + EmbeddedTweetUIView.contentBottomPadding
                height += embeddedHeight
            } else {
                // Not loaded: "Loading quoted tweet..." placeholder
                height += EmbeddedTweetUIView.placeholderHeight
            }

            height += 10 // contentColumn.setCustomSpacing(10, after: embeddedTweetWrapper)
        }

        // Action bar (fixed 30pt)
        height += 30

        // Bottom padding (matches mainStack.bottomAnchor = separatorView.topAnchor - 8)
        height += 8

        // Separator
        height += 1

        return height
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let totalRows = pinnedTweets.count + tweets.count
        guard indexPath.row < totalRows else {
            return UITableView.automaticDimension
        }

        let tweet: Tweet
        if indexPath.row < pinnedTweets.count {
            tweet = pinnedTweets[indexPath.row]
        } else {
            let regularIndex = indexPath.row - pinnedTweets.count
            guard regularIndex < tweets.count else {
                return UITableView.automaticDimension
            }
            tweet = tweets[regularIndex]
        }

        // Expanded tweets need full Auto Layout measurement — skip all caches.
        if expandedTweetIds.contains(tweet.mid) {
            return UITableView.automaticDimension
        }

        // Saved comments gain an embedded parent only in bookmark/favorite lists.
        // Let Auto Layout measure this presentation-specific card rather than polluting
        // the shared Tweet height cache used by ordinary comment screens.
        if tweet.originalTweetId == nil, effectiveEmbeddedTweetId(for: tweet) != nil {
            return UITableView.automaticDimension
        }

        if FeedLayoutMode.selfSizing {
            return UITableView.automaticDimension
        }

        let layoutWidth = currentRowLayoutWidth
        let dividerHeight = pinnedTweetsDividerHeight(forRow: indexPath.row)

        // Use cached height if available (set by willDisplay from actual Auto Layout).
        if let cachedHeight = cachedHeight(for: tweet, width: layoutWidth) {
            return cachedHeight + dividerHeight
        }

        // Use persisted measured height before falling back to deterministic calculation.
        // estimatedHeightForRowAt uses the same value; keeping both paths aligned avoids
        // a visible grow-after-render pass for previously measured tweets.
        if let persistedHeight = TweetHeightCache.shared.getHeight(for: tweet.mid, width: layoutWidth) {
            return persistedHeight + dividerHeight
        }

        // Use deterministic calculation instead of Auto Layout.
        // This matches estimatedHeightForRowAt's fallback, so estimate == actual → no scroll jumps.
        // The cell still uses Auto Layout internally for content positioning;
        // only the cell height is pre-determined.
        return Self.calculateTweetHeight(
            for: tweet,
            rowWidth: layoutWidth,
            cellHorizontalPadding: leadingPadding + trailingPadding
        ) + dividerHeight
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let totalRows = pinnedTweets.count + tweets.count
        guard indexPath.row < totalRows else { return }

        let tweet: Tweet
        if indexPath.row < pinnedTweets.count {
            tweet = pinnedTweets[indexPath.row]
        } else {
            let regularIndex = indexPath.row - pinnedTweets.count
            guard regularIndex < tweets.count else { return }
            tweet = tweets[regularIndex]
        }

        if tweet.originalTweetId == nil, effectiveEmbeddedTweetId(for: tweet) != nil {
            return
        }

        // Cache the actual Auto Layout height from the cell frame.
        // heightForRowAt returns automaticDimension on first display, so cell.frame.height
        // reflects the true Auto Layout result. Cache it for future use so that
        // estimatedHeightForRowAt == heightForRowAt → no scroll jumps on subsequent displays.
        //
        // Guards against caching incomplete heights:
        // 1. embeddedTweetLoaded: don't cache if retweet/quote's original tweet isn't loaded
        // 2. Height sanity check: don't cache if significantly smaller than calculated estimate
        //    (indicates cell hasn't fully rendered — e.g., media grid not yet laid out)
        if cell.frame.height > 0 {
            let cellWidth = cell.bounds.width > 0 ? cell.bounds.width : currentRowLayoutWidth
            let dividerHeight = pinnedTweetsDividerHeight(forRow: indexPath.row)
            let tweetHeight = cell.frame.height - dividerHeight
            // Fast path: height already cached and matches the rendered cell — nothing to update.
            // Skips the expensive calculateTweetHeight (sizeThatFits + maybe TextKit layout)
            // on every willDisplay call for stable cells.
            if let existing = cachedHeight(for: tweet, width: cellWidth),
               abs(existing - tweetHeight) <= 1 {
                return
            }

            let effectiveEmbeddedTweetId = effectiveEmbeddedTweetId(for: tweet)
            let needsEmbeddedTweet = effectiveEmbeddedTweetId != nil
            let embeddedTweetLoaded = !needsEmbeddedTweet ||
                                     (Tweet.getInstance(for: effectiveEmbeddedTweetId!)?.author != nil)
            if embeddedTweetLoaded {
                // Sanity check: if the actual height is much smaller than expected,
                // the cell likely hasn't finished rendering (async content pending).
                // Don't cache — let Auto Layout re-determine on next display.
                let expectedHeight = Self.calculateTweetHeight(
                    for: tweet,
                    rowWidth: cellWidth,
                    cellHorizontalPadding: self.leadingPadding + self.trailingPadding
                )
                let isReasonable = tweetHeight >= expectedHeight - 20

                if isReasonable {
                    setCachedHeight(tweetHeight, for: tweet, width: cell.bounds.width)
                } else {
                    clearCachedHeight(for: tweet)
                }
            }
        }
    }

    override func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Forward media invisibility to the cell
        if let tweetCell = cell as? TweetTableViewCell {
            tweetCell.tweetContentView.setMediaVisible(false)
        }

        // A shrink deferred while this row was on screen can now be reconciled — re-queue
        // it; the next relayout flush finds the row off screen and applies the shrink via
        // the reloadRows path with the viewport anchored (no visible movement).
        if let tweetCell = cell as? TweetTableViewCell, let tweetId = tweetCell.tweetId,
           deferredShrinkTweetIds.remove(tweetId) != nil {
            pendingHeightRelayoutTweetIds.insert(tweetId)
        }

        // If this cell was showing expanded content, clear the expansion tracking and nil
        // cachedHeight so that when the tweet scrolls back into view, heightForRowAt falls
        // back to calculateTweetHeight (truncated height) and the cell remeasures correctly.
        if let tweetCell = cell as? TweetTableViewCell, let tweetId = tweetCell.tweetId,
           expandedTweetIds.remove(tweetId) != nil {
            let totalRows = pinnedTweets.count + tweets.count
            guard indexPath.row < totalRows else { return }
            let tweet: Tweet
            if indexPath.row < pinnedTweets.count {
                tweet = pinnedTweets[indexPath.row]
            } else {
                let idx = indexPath.row - pinnedTweets.count
                guard idx < tweets.count else { return }
                tweet = tweets[idx]
            }
            clearCachedHeight(for: tweet)
        }
    }

    // MARK: - UIScrollViewDelegate

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let currentOffset = scrollView.contentOffset.y
        let frameDelta = currentOffset - lastContentOffset
        lastContentOffset = currentOffset  // always update for frame-level tracking

        guard isTableVisibleForMutation else { return }

        // Jump/hitch detector — NOT #if DEBUG: the app's Run configuration is Release,
        // so DEBUG-gated code never reaches the device. Two signatures:
        //   (a) idle-offset-change: the offset moved while the table was fully stopped
        //       (a layout-induced twitch) — prints the responsible call stack.
        //   (b) scroll-hitch: the gap between scroll callbacks during physical scrolling
        //       exceeded ~3 frames — the main thread was blocked (the "hang"); the
        //       culprit is whatever logged during the gap, so no stack is taken.
        let detectorNow = CACurrentMediaTime()
        let isPhysicallyScrolling = isUserDragging || isDecelerating
            || scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        if !isPhysicallyScrolling, !isScrollingToTop, !isTableViewUpdating, abs(frameDelta) > 2 {
            let stack = Thread.callStackSymbols.dropFirst(2).prefix(10).joined(separator: "\n")
            print("🧭 [SCROLL JUMP TRACE] idle-offset-change feed=\(feedIdentifier) " +
                  "delta=\(String(format: "%.1f", frameDelta)) offset=\(String(format: "%.1f", currentOffset))\n\(stack)")
        } else if isPhysicallyScrolling, lastScrollEventTimestamp > 0 {
            let gapMs = (detectorNow - lastScrollEventTimestamp) * 1000
            if gapMs > 50 {
                print("🧭 [SCROLL JUMP TRACE] scroll-hitch feed=\(feedIdentifier) " +
                      "gapMs=\(Int(gapMs)) delta=\(String(format: "%.1f", frameDelta)) " +
                      "offset=\(String(format: "%.1f", currentOffset)) decelerating=\(isDecelerating)")
            }
        }
        lastScrollEventTimestamp = detectorNow

        notifyScrollStateChanged(scrollView)

        // Update scroll direction only during active user dragging
        if isUserDragging && abs(frameDelta) >= 2.0 {
            isScrollingBackward = frameDelta < 0
        }

        let now = CACurrentMediaTime()
        updateEstimatedScrollVelocity(frameDelta: frameDelta, now: now)
        // Cells consult this to defer AVPlayer creation/attach during fast flings.
        videoCoordinator.currentScrollVelocityY = estimatedScrollVelocityY

        // Update video visibility during all scroll phases (drag + deceleration).
        // Throttle limits frequency to avoid excessive work.
        if now - lastVideoVisibilityUpdate >= videoVisibilityThrottleInterval {
            lastVideoVisibilityUpdate = now
            scheduleVideoVisibilityUpdateNextRunLoop()
        }

        let isUserDrivenScroll = isUserDragging || isDecelerating || scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        if isUserDrivenScroll {
            triggerDirectionalImagePreloadDuringScroll(now: now)
        }

        // Auto-load next page when 1 page worth of rows remains below the viewport.
        // Row-count threshold adapts to tweet height: tall media tweets give more pixel
        // runway; short text tweets still guarantee one full page of buffer.
        let contentHeight = scrollView.contentSize.height
        let scrollViewHeight = scrollView.frame.size.height
        let contentInsetBottom = scrollView.contentInset.bottom
        let bottomOffset = scrollView.contentOffset.y + scrollViewHeight - contentHeight + contentInsetBottom

        if isUserDrivenScroll {
            triggerAutoLoadMoreIfNeeded(
                reason: "scroll",
                countsTowardScrollGestureLimit: true
            )
        }


        // Manual pull-to-load: user pulled past the bottom edge (works even when hasMoreTweets is false)
        if isUserDragging,
           tweets.count >= 4,
           bottomOffset > bottomPullThreshold,
           !isLoadingMore,
           !isBottomPullActive {
            isBottomPullActive = true
            triggerBottomPullLoadMore()
        } else if bottomOffset <= 0 {
            isBottomPullActive = false
        }

        // Don't trigger toolbar hiding until initial layout is complete
        guard hasCompletedInitialLayout else { return }

        // Only fire toolbar callbacks during active user dragging.
        // During deceleration and layout-induced scrolls, lock toolbar state.
        guard isUserDragging else { return }

        // Use pan gesture VELOCITY for direction — immune to layout-induced offset jumps.
        // contentOffset delta is contaminated when toolbar show/hide changes the table view
        // frame, but velocity purely reflects the user's finger movement.
        let velocity = scrollView.panGestureRecognizer.velocity(in: scrollView).y
        // velocity > 0 = finger moving down = content down = "scrolling up" (show toolbar)
        // velocity < 0 = finger moving up = content up = "scrolling down" (hide toolbar)
        guard abs(velocity) > 100 else { return }  // ignore ambiguous / near-zero velocity

        // Time-based throttling
        let shouldThrottleByTime = (now - lastScrollCallbackTime) < scrollCallbackThrottleInterval

        // Distance throttle — enough scroll distance since last callback
        let distanceSinceLastCallback = abs(currentOffset - lastCallbackOffset)
        let headerThreshold: CGFloat = 30
        guard !shouldThrottleByTime && distanceSinceLastCallback >= headerThreshold else { return }

        // Convert velocity to delta convention: positive = scrolling down, negative = scrolling up
        let delta: CGFloat = velocity > 0 ? -headerThreshold : headerThreshold

        if delta > 0 {
            // Scrolling down → hide bars immediately (no layout shift — content area expands)
            pendingBarsShowAfterScroll = false
            onScroll?(currentOffset, delta)
        } else {
            // Scrolling up → latch the request and reveal the bars on finger lift, so
            // they are up for the whole coast. Showing them from here would re-toggle
            // isNavigationVisible repeatedly across a single gesture, each toggle
            // re-running the header layout and restarting the offset compensation.
            pendingBarsShowAfterScroll = true
        }

        lastCallbackOffset = currentOffset
        lastScrollCallbackTime = now
    }

    private func updateEstimatedScrollVelocity(frameDelta: CGFloat, now: CFTimeInterval) {
        guard lastScrollVelocitySampleTime > 0 else {
            lastScrollVelocitySampleTime = now
            estimatedScrollVelocityY = 0
            return
        }

        let elapsed = now - lastScrollVelocitySampleTime
        if elapsed > 0 {
            estimatedScrollVelocityY = frameDelta / CGFloat(elapsed)
        }
        lastScrollVelocitySampleTime = now
    }

    override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // User started dragging - reset callback baseline to current position
        // so accumulated delta starts fresh from the new drag gesture
        cancelBackgroundResumeForUserScroll()
        isUserDragging = true
        isDecelerating = false
        lastScrollVelocitySampleTime = 0
        estimatedScrollVelocityY = 0
        lastScrollEventTimestamp = 0
        autoLoadMoreCountDuringCurrentScrollGesture = 0
        rowCountAtLastAutoLoad = nil
        lastCallbackOffset = scrollView.contentOffset.y
        videoCoordinator.onScrollStarted()
        updateVisibleTweetsForVideoPlayback()
        notifyScrollStateChanged(scrollView)
    }

    override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // User lifted finger
        isUserDragging = false
        isDecelerating = decelerate

        // Reveal the bars as soon as the finger lifts, so they are already on screen
        // while the list coasts. Waiting for the scroll to fully stop left them hidden
        // for the whole inertial phase.
        showPendingBarsAfterScrollIfNeeded()

        // CRITICAL: Save scroll position immediately when user stops dragging
        // (if not decelerating, scroll has stopped - save now to survive app termination)
        if !decelerate {
            videoCoordinator.currentScrollVelocityY = 0
            flushScrollDeferredTweets()
            performPendingHeightRelayout()
            saveScrollPositionIfNeeded()
            runScrollStopPreloadWhenIdle()
        }
        notifyScrollStateChanged(scrollView)
    }

    /// Set while an upward drag is in progress; consumed when the finger lifts.
    ///
    /// Finger lift is a single, well-defined moment: the bars come in as inertia starts
    /// and stay up for the coast, and the anchored compensation in viewDidLayoutSubviews
    /// keeps the content pinned while they do. Firing this repeatedly from
    /// scrollViewDidScroll instead would re-toggle isNavigationVisible several times per
    /// gesture, restarting that compensation each time.
    private var pendingBarsShowAfterScroll = false

    private func showPendingBarsAfterScrollIfNeeded() {
        guard pendingBarsShowAfterScroll else { return }
        pendingBarsShowAfterScroll = false
        showBarsWithoutAnimation()
    }

    override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        isDecelerating = false
        videoCoordinator.currentScrollVelocityY = 0

        // Deceleration skipped video visibility updates — do one final update now
        updateVisibleTweetsForVideoPlayback()
        flushScrollDeferredTweets()
        performPendingHeightRelayout()
        showPendingBarsAfterScrollIfNeeded()

        triggerPreloadOnScrollStop()

        // CRITICAL: Save scroll position immediately when scroll momentum stops
        // This ensures position is persisted even if app is killed before viewWillDisappear
        saveScrollPositionIfNeeded()

        // If decelerated to near the top, show bars
        let topInset = scrollView.adjustedContentInset.top
        if scrollView.contentOffset.y <= -topInset + 10 {
            showBarsWithoutAnimation()
        }

        applyDeferredTableChromeUpdatesAfterScroll()
        notifyScrollStateChanged(scrollView)
    }

    private func runScrollStopPreloadWhenIdle(attempt: Int = 0) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let tableIsIdle = !self.isUserDragging &&
                !self.isDecelerating &&
                !self.tableView.isTracking &&
                !self.tableView.isDragging &&
                !self.tableView.isDecelerating

            guard tableIsIdle else {
                guard attempt < 3 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.runScrollStopPreloadWhenIdle(attempt: attempt + 1)
                }
                return
            }

            self.updateVisibleTweetsForVideoPlayback()
            self.triggerPreloadOnScrollStop()
            self.applyDeferredTableChromeUpdatesAfterScroll()
        }
    }

    override func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        refreshVisiblePlaybackAfterProgrammaticListChange(reason: "pendingTweetsScrollAnimationEnded")
    }

    /// Coalesces multiple same-turn relayout requests (e.g. a burst of embedded-tweet
    /// prefetch completions) into a single table pass on the next run-loop turn.
    /// While the user is scrolling, does nothing — the pending set is flushed by the
    /// scroll-stop handlers.
    private var isCoalescedHeightRelayoutScheduled = false
    private func scheduleCoalescedHeightRelayout() {
        guard !isScrollInteractionActive else { return }
        guard !isCoalescedHeightRelayoutScheduled else { return }
        isCoalescedHeightRelayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isCoalescedHeightRelayoutScheduled = false
            guard !self.isScrollInteractionActive else { return }
            self.performPendingHeightRelayout()
        }
    }

    /// `anchorTweetId` pins that row's own top across the reflow. Pass it for a
    /// user-initiated expansion so the text grows downward from where it was tapped.
    private func performPendingHeightRelayout(include tweetId: String? = nil, anchorTweetId: String? = nil) {
        if let tweetId {
            pendingHeightRelayoutTweetIds.insert(tweetId)
        }
        let requestedAnchorTweetId = anchorTweetId ?? pendingExpansionAnchorTweetId
        pendingExpansionAnchorTweetId = nil
        guard !pendingHeightRelayoutTweetIds.isEmpty else { return }
        guard isTableVisibleForMutation else { return }

        let expectedCount = pinnedTweets.count + tweets.count
        let currentCount = tableView.numberOfRows(inSection: 0)
        guard expectedCount == currentCount else { return }

        // Recompute the deterministic height for every pending tweet and keep only the
        // rows whose height actually changed. heightForRowAt serves cache-first, so the
        // cache must be updated here — before the reflow — for begin/endUpdates to see
        // the new value; and rows whose recomputed height matches the cache are dropped
        // so an async configure that didn't change the height costs no table pass at all.
        let layoutWidth = currentRowLayoutWidth
        let visibleIndexPaths = tableView.indexPathsForVisibleRows ?? []
        let visibleRowSet = Set(visibleIndexPaths.map(\.row))
        var changedTweetIds = Set<String>()
        var changedRows: [Int] = []
        for mid in pendingHeightRelayoutTweetIds {
            guard let row = rowForTweetId(mid), let tweet = tweetForRow(row) else { continue }

            // Rows measured by Auto Layout (expanded content, saved-comment context)
            // bypass the height caches entirely — always reflow, never cache.
            if expandedTweetIds.contains(mid)
                || (tweet.originalTweetId == nil && effectiveEmbeddedTweetId(for: tweet) != nil) {
                changedTweetIds.insert(mid)
                changedRows.append(row)
                continue
            }

            let newHeight = Self.calculateTweetHeight(
                for: tweet,
                rowWidth: layoutWidth,
                cellHorizontalPadding: leadingPadding + trailingPadding
            )
            // Compare against the height UIKit is actually being served: in-memory first,
            // then the persisted cache — a recreated Tweet instance has no in-memory height
            // even though heightForRowAt has been serving the persisted value the whole
            // time. Without this fallback every instance recreation registered as a height
            // change and triggered a 1–2pt begin/endUpdates wiggle at each scroll stop.
            let servedHeight = cachedHeight(for: tweet, width: layoutWidth)
                ?? TweetHeightCache.shared.getHeight(for: tweet.mid, width: layoutWidth)
            if let servedHeight, abs(servedHeight - newHeight) <= 1.5 {
                // Republish the SERVED value (not the fresh calculation) so heightForRowAt
                // keeps returning the exact number UIKit already banked — zero movement.
                if tweet.cachedHeight == nil {
                    setCachedHeight(servedHeight, for: tweet, width: layoutWidth)
                }
                continue
            }

            // Defer moderate shrinks of on-screen rows until the row scrolls away;
            // large shrinks still apply now (a big blank band looks broken).
            if let servedHeight,
               visibleRowSet.contains(row),
               newHeight < servedHeight,
               servedHeight - newHeight <= 60 {
                if tweet.cachedHeight == nil {
                    setCachedHeight(servedHeight, for: tweet, width: layoutWidth)
                }
                deferredShrinkTweetIds.insert(mid)
                continue
            }

            setCachedHeight(newHeight, for: tweet, width: layoutWidth)
            changedTweetIds.insert(mid)
            changedRows.append(row)
        }
        pendingHeightRelayoutTweetIds.removeAll()
        guard !changedTweetIds.isEmpty else { return }

        // Anchor to the first visible cell whose height isn't itself among the pending
        // changes, so the anchor's own rectForRow (measured before AND after the reflow)
        // isn't thrown off by its own row growing/shrinking. If the changing row sits
        // above a "first visible row" anchor that's also changing, using rectForRow
        // before/after can disagree with how UIKit distributes the height delta,
        // producing a visible over/undershoot (jump-then-settle) instead of a clean
        // absorb. Falls back to the first visible row if every visible row is changing.
        var anchorIndexPath: IndexPath?
        var anchorOffset: CGFloat = 0
        // A user-initiated expansion overrides that choice and anchors the tapped row's
        // OWN top, so the text grows downward from where it sits. The "stable" rule picks
        // the first visible row that isn't changing — which, for the topmost row, is the
        // row BELOW it. Pinning that one keeps it in place and forces the expanding row
        // to grow upward, pushing its top off under the header. Anchoring the expanding
        // row is equally correct for rows further down: everything above it is unaffected
        // either way, so its top staying put is exactly the desired result.
        let expansionAnchor: IndexPath? = requestedAnchorTweetId
            .flatMap { rowForTweetId($0) }
            .flatMap { $0 < tableView.numberOfRows(inSection: 0) ? IndexPath(row: $0, section: 0) : nil }
        let stableAnchor = visibleIndexPaths.first { indexPath in
            guard let tweet = tweetForRow(indexPath.row) else { return false }
            return !changedTweetIds.contains(tweet.mid)
        }
        if let chosen = expansionAnchor ?? stableAnchor ?? visibleIndexPaths.first {
            let cellTop = tableView.rectForRow(at: chosen).origin.y
            anchorOffset = tableView.contentOffset.y - cellTop
            anchorIndexPath = chosen
        }

        // Off-screen changed rows must be reloaded: begin/endUpdates only re-queries
        // heights for VISIBLE rows, so a realized-then-scrolled-away row would keep its
        // stale banked height and UIKit would discover the new one mid-scroll at
        // realization — the exact top-entering jump this reflow exists to prevent.
        // Reloading an off-screen row is cheap (no cell exists) and flicker-free.
        let offscreenReloadPaths = changedRows
            .filter { !visibleRowSet.contains($0) }
            .map { IndexPath(row: $0, section: 0) }

        let tracePendingTweetIds = changedTweetIds.sorted()
        let traceAnchorTweetId = anchorIndexPath.flatMap { tweetForRow($0.row)?.mid } ?? "none"
        let traceAnchorRow = anchorIndexPath?.row ?? -1
        let traceOffsetBefore = tableView.contentOffset.y
        let traceContentHeightBefore = tableView.contentSize.height
        print("🧭 [SCROLL JUMP TRACE] relayout-before " +
              "feed=\(feedIdentifier) changed=\(tracePendingTweetIds) " +
              "offscreenReloads=\(offscreenReloadPaths.map(\.row)) " +
              "anchorTweet=\(traceAnchorTweetId) anchorRow=\(traceAnchorRow) " +
              "anchorOffset=\(anchorOffset) offset=\(traceOffsetBefore) " +
              "contentHeight=\(traceContentHeightBefore) " +
              "dragging=\(isUserDragging) decelerating=\(isDecelerating)")

        UIView.performWithoutAnimation {
            isTableViewUpdating = true
            tableView.beginUpdates()
            if !offscreenReloadPaths.isEmpty {
                tableView.reloadRows(at: offscreenReloadPaths, with: .none)
            }
            tableView.endUpdates()
            isTableViewUpdating = false
        }

        let traceRawOffsetAfter = tableView.contentOffset.y
        let traceContentHeightAfter = tableView.contentSize.height
        print("🧭 [SCROLL JUMP TRACE] relayout-raw-after " +
              "feed=\(feedIdentifier) pending=\(tracePendingTweetIds) " +
              "anchorTweet=\(traceAnchorTweetId) anchorRow=\(traceAnchorRow) " +
              "offset=\(traceRawOffsetAfter) offsetDelta=\(traceRawOffsetAfter - traceOffsetBefore) " +
              "contentHeight=\(traceContentHeightAfter) " +
              "contentHeightDelta=\(traceContentHeightAfter - traceContentHeightBefore)")

        // Restore position relative to the anchor cell to absorb any content-offset drift.
        if let anchor = anchorIndexPath {
            let newCellTop = tableView.rectForRow(at: anchor).origin.y
            let newOffset = newCellTop + anchorOffset
            if abs(newOffset - tableView.contentOffset.y) > 0.5 {
                let correctionDelta = newOffset - tableView.contentOffset.y
                print("🧭 [SCROLL JUMP TRACE] anchor-correction " +
                      "feed=\(feedIdentifier) anchorTweet=\(traceAnchorTweetId) " +
                      "anchorRow=\(anchor.row) newCellTop=\(newCellTop) " +
                      "targetOffset=\(newOffset) correctionDelta=\(correctionDelta)")
                tableView.setContentOffset(CGPoint(x: 0, y: newOffset), animated: false)
            }
        } else {
            print("🧭 [SCROLL JUMP TRACE] anchor-missing " +
                  "feed=\(feedIdentifier) pending=\(tracePendingTweetIds) " +
                  "offset=\(tableView.contentOffset.y)")
        }
    }

    /// Show bars immediately without animation.
    ///
    /// Posts `.showBarsAfterScrollEnd` so the parent view sets isNavigationVisible
    /// **without animation**.  The instant frame change is then compensated in
    /// `viewDidLayoutSubviews` so visible content stays at the same screen position.
    private func showBarsWithoutAnimation() {
        let now = CACurrentMediaTime()
        guard now - lastBarAppearanceRequestTime > FeedPlaybackTuning.barAppearanceCompensationTimeout else {
            return
        }
        lastBarAppearanceRequestTime = now

        // Anchor a real row before the bars expand, in window coordinates, so the
        // correction below can measure the true visual drift rather than inferring it.
        captureBarAppearanceAnchor()

        NotificationCenter.default.post(
            name: .showBarsAfterScrollEnd,
            object: nil,
            userInfo: ["animated": false]
        )

        // Safety timeout — stop compensating even if layout never fires
        DispatchQueue.main.asyncAfter(deadline: .now() + FeedPlaybackTuning.barAppearanceCompensationTimeout) { [weak self] in
            self?.endBarAppearanceCompensation()
        }
    }

    private func captureBarAppearanceAnchor() {
        guard let visibleIndexPaths = tableView.indexPathsForVisibleRows?.sorted(),
              let anchorPath = visibleIndexPaths.first,
              let tweet = tweetForRow(anchorPath.row) else {
            endBarAppearanceCompensation()
            return
        }
        let rowOrigin = tableView.rectForRow(at: anchorPath).origin
        barCompensationAnchorTweetId = tweet.mid
        barCompensationAnchorScreenY = tableView.convert(rowOrigin, to: nil).y
        barCompensationChromeTopWindowY = currentChromeTopWindowY()
        isCompensatingForBarAppearance = true
    }

    /// Where the chrome puts the top of the list, in window space.
    ///
    /// Purely geometric: it is read from the table's FRAME (via its superview) plus the
    /// adjusted inset, never from `bounds`/`contentOffset`. So it moves when the bars
    /// resize the table and stays put while the list scrolls — which is exactly the
    /// distinction the correction below needs.
    private func currentChromeTopWindowY() -> CGFloat? {
        guard let superview = tableView.superview else { return nil }
        return superview.convert(tableView.frame.origin, to: nil).y + tableView.adjustedContentInset.top
    }

    /// Drives the anchored row back to the screen position it occupied before the bars
    /// appeared, cancelling the shift their arrival caused.
    ///
    /// Runs on every layout pass in the compensation window but only ACTS on the pass where
    /// the chrome resized; the rest just re-baseline the anchor. That distinction matters
    /// because the bars come in at finger lift while the list is still coasting, so most
    /// passes see legitimate scroll movement that must not be cancelled.
    private func applyBarAppearanceAnchorCorrectionIfNeeded() {
        guard isCompensatingForBarAppearance,
              let anchorTweetId = barCompensationAnchorTweetId,
              let targetScreenY = barCompensationAnchorScreenY,
              let row = rowForTweetId(anchorTweetId),
              row < tableView.numberOfRows(inSection: 0) else { return }

        // Never fight the user's finger — if a new gesture started, abandon the anchor.
        guard !isUserDragging, !tableView.isTracking else {
            endBarAppearanceCompensation()
            return
        }

        // Correct only on the layout pass where the chrome actually resized the table.
        //
        // The bars are revealed at finger lift and the list keeps coasting underneath them,
        // so most passes in the compensation window see a moving list and a stationary
        // chrome. Re-pinning the anchor on those passes treats the coast itself as drift:
        // it dragged contentOffset back to a fixed value every other frame, freezing and
        // juddering the feed for ~150ms before it lurched free. Scroll-up only, because the
        // bars never appear on scroll-down — which is exactly the asymmetry users report.
        guard let chromeTop = currentChromeTopWindowY() else { return }
        let anchorPath = IndexPath(row: row, section: 0)
        guard abs(chromeTop - (barCompensationChromeTopWindowY ?? chromeTop)) > 0.5 else {
            // Chrome is stable — the list is merely coasting. Re-baseline to where the
            // scroll has legitimately carried the anchor, so if the chrome resizes again
            // that pass measures only the NEW shift instead of re-cancelling this coast.
            barCompensationChromeTopWindowY = chromeTop
            barCompensationAnchorScreenY = tableView.convert(
                tableView.rectForRow(at: anchorPath).origin, to: nil
            ).y
            return
        }
        barCompensationChromeTopWindowY = chromeTop

        let rowOrigin = tableView.rectForRow(at: anchorPath).origin
        let currentScreenY = tableView.convert(rowOrigin, to: nil).y
        let drift = currentScreenY - targetScreenY
        guard abs(drift) > 0.5 else { return }

        tableView.contentOffset.y += drift
        barCompensationAnchorScreenY = tableView.convert(
            tableView.rectForRow(at: anchorPath).origin, to: nil
        ).y
    }

    private func endBarAppearanceCompensation() {
        // Silence on success. The anchored row is expected to have MOVED by now — the list
        // coasts under the bars — so its displacement is not an error signal. What must be
        // zero is leftover chrome resizing that no pass got to cancel.
        if isCompensatingForBarAppearance,
           let recorded = barCompensationChromeTopWindowY,
           let chromeTop = currentChromeTopWindowY(),
           abs(chromeTop - recorded) > 0.5 {
            print("🧭 [SCROLL JUMP TRACE] bar-appearance uncompensatedChromeShift=" +
                  "\(String(format: "%.1f", chromeTop - recorded))")
        }
        isCompensatingForBarAppearance = false
        barCompensationAnchorTweetId = nil
        barCompensationAnchorScreenY = nil
        barCompensationChromeTopWindowY = nil
    }

    /// Warm images in the scroll direction, plus the existing reverse row once scrolling settles.
    /// Videos stay directional and are handled by the coordinator's video index.
    private func triggerPreloadOnScrollStop() {
        guard let visibleIndexPaths = tableView.indexPathsForVisibleRows,
              let firstVisible = visibleIndexPaths.first,
              let lastVisible = visibleIndexPaths.last else {
            videoCoordinator.performPreloadOnScrollStop()
            return
        }

        let preloadRows = directionalPreloadRows(
            firstVisibleRow: firstVisible.row,
            lastVisibleRow: lastVisible.row
        )
        let oppositeRows = oppositeStopPreloadRows(
            firstVisibleRow: firstVisible.row,
            lastVisibleRow: lastVisible.row
        )
        if videoCoordinator.canRunDirectionalPreloads() {
            preloadImagesForRows(preloadRows + oppositeRows, allowNetwork: true)
        } else {
            cancelDirectionalImagePreloads()
        }

        videoCoordinator.performPreloadOnScrollStop()
    }

    /// Lightweight image warmup while the list is moving. This only promotes cached
    /// image files in the current scroll direction; network preloads wait for scroll stop.
    private func triggerDirectionalImagePreloadDuringScroll(now: CFTimeInterval) {
        guard now - lastDirectionalImagePreloadDuringScrollTime >= FeedPlaybackTuning.directionalVideoPreloadRefreshInterval else { return }
        lastDirectionalImagePreloadDuringScrollTime = now

        guard let visibleIndexPaths = tableView.indexPathsForVisibleRows,
              let firstVisible = visibleIndexPaths.first,
              let lastVisible = visibleIndexPaths.last else { return }

        let preloadRows = directionalPreloadRows(
            firstVisibleRow: firstVisible.row,
            lastVisibleRow: lastVisible.row
        )
        guard !preloadRows.isEmpty else { return }

        // Warm the text of rows about to appear. heightForRowAt is cache-first, and a miss
        // runs the full calculateTweetHeight synchronously INSIDE dequeueReusableCell — 4-8ms
        // on the single frame the row enters, which on its own overruns the frame budget and
        // costs a vsync. The feed then advances two frames' worth of pixels in one frame,
        // which is the residual scroll shake. Measuring ahead turns that into a cache hit.
        prewarmUpcomingRowHeights()

        if videoCoordinator.canRunDirectionalImagePreloads() {
            preloadImagesForRows(preloadRows, allowNetwork: false)
        }
    }

    /// Text prewarm reaches further ahead than the image preload window: the cost being avoided
    /// lands on one frame, so the measurement has to finish well before the row is dequeued.
    /// TweetHeightPrewarmer skips anything already measured, so repeat calls across scroll
    /// frames are cheap.
    private func prewarmUpcomingRowHeights() {
        guard let visibleIndexPaths = tableView.indexPathsForVisibleRows,
              let firstVisible = visibleIndexPaths.first?.row,
              let lastVisible = visibleIndexPaths.last?.row else { return }

        let totalRows = pinnedTweets.count + tweets.count
        guard totalRows > 0 else { return }

        let rows: [Int]
        if isScrollingBackward {
            let nearest = firstVisible - 1
            guard nearest >= 0 else { return }
            rows = Array(stride(from: nearest, through: max(0, nearest - heightPrewarmRowCount + 1), by: -1))
        } else {
            let nearest = lastVisible + 1
            guard nearest < totalRows else { return }
            rows = Array(nearest...min(totalRows - 1, nearest + heightPrewarmRowCount - 1))
        }

        let upcoming = rows.compactMap { tweetForRow($0) }
        guard !upcoming.isEmpty else { return }
        scheduleHeightPrewarm(for: upcoming)
    }

    /// Rows ahead of the viewport to typeset text for. Deliberately deeper than the image
    /// preload window — a text-measurement miss costs a dropped frame, an image miss does not.
    private let heightPrewarmRowCount = 8

    private func directionalPreloadRows(firstVisibleRow: Int, lastVisibleRow: Int) -> [Int] {
        let totalRows = pinnedTweets.count + tweets.count
        guard totalRows > 0 else { return [] }

        if isScrollingBackward {
            let nearestRowAbove = firstVisibleRow - 1
            guard nearestRowAbove >= 0 else { return [] }
            let farthestRowAbove = max(0, nearestRowAbove - directionalPreloadRowCount + 1)
            return Array(stride(from: nearestRowAbove, through: farthestRowAbove, by: -1))
        } else {
            let nearestRowBelow = lastVisibleRow + 1
            guard nearestRowBelow < totalRows else { return [] }
            let farthestRowBelow = min(totalRows - 1, nearestRowBelow + directionalPreloadRowCount - 1)
            return Array(nearestRowBelow...farthestRowBelow)
        }
    }

    private func oppositeStopPreloadRows(firstVisibleRow: Int, lastVisibleRow: Int) -> [Int] {
        let totalRows = pinnedTweets.count + tweets.count
        guard totalRows > 0 else { return [] }

        if isScrollingBackward {
            let nearestRowBelow = lastVisibleRow + 1
            guard nearestRowBelow < totalRows else { return [] }
            let farthestRowBelow = min(totalRows - 1, nearestRowBelow + oppositeStopPreloadRowCount - 1)
            return Array(nearestRowBelow...farthestRowBelow)
        } else {
            let nearestRowAbove = firstVisibleRow - 1
            guard nearestRowAbove >= 0 else { return [] }
            let farthestRowAbove = max(0, nearestRowAbove - oppositeStopPreloadRowCount + 1)
            return Array(stride(from: nearestRowAbove, through: farthestRowAbove, by: -1))
        }
    }

    private func preloadImagesForRows(_ rows: [Int], allowNetwork: Bool = true) {
        var targetImageIds = Set<String>()
        var cachedTargetImageIds = Set<String>()
        var candidates: [(attachment: MimeiFileType, url: URL)] = []
        var cachedCandidates: [MimeiFileType] = []
        var candidateIds = Set<String>()
        let visibleImageIds = visibleImageAttachmentIds()

        for row in rows {
            guard let tweet = tweetForRow(row) else { continue }
            for source in mediaPreloadSources(for: tweet) {
                let mediaAttachments = source.attachments?
                    .filter { TweetBodyUIView.isMediaType($0.type) }
                    .prefix(4) ?? []

                for attachment in mediaAttachments where attachment.type == .image {
                    targetImageIds.insert(attachment.mid)

                    if ImageCacheManager.shared.getCompressedImageFromMemory(for: attachment) != nil {
                        cachedTargetImageIds.insert(attachment.mid)
                        continue
                    }

                    guard !candidateIds.contains(attachment.mid),
                          !visibleImageIds.contains(attachment.mid),
                          !GlobalImageLoadManager.shared.hasLoad(id: attachment.mid),
                          !BlackList.shared.isBlacklisted(MimeiId(attachment.mid)) else {
                        continue
                    }

                    if !allowNetwork {
                        candidateIds.insert(attachment.mid)
                        cachedCandidates.append(attachment)
                        continue
                    }

                    guard !candidateIds.contains(attachment.mid),
                          let baseUrl = resolvedMediaBaseUrl(for: source),
                          let url = attachment.getUrl(baseUrl) else {
                        continue
                    }

                    candidateIds.insert(attachment.mid)
                    candidates.append((attachment, url))
                }
            }
        }

        if allowNetwork {
            let activeImageIds = Set(activeDirectionalImagePreloadTasks.keys)
            let staleImageIds = activeImageIds
                .subtracting(targetImageIds)
                .union(activeImageIds.intersection(visibleImageIds))
                .union(activeImageIds.intersection(cachedTargetImageIds))
            for imageId in staleImageIds {
                activeDirectionalImagePreloadTasks[imageId]?.cancel()
                activeDirectionalImagePreloadTasks.removeValue(forKey: imageId)
            }
        }

        var availableSlots = max(0, maxDirectionalImagePreloadsInFlight - activeDirectionalImagePreloadTasks.count)
        guard availableSlots > 0 else { return }

        if !allowNetwork {
            for attachment in cachedCandidates {
                guard availableSlots > 0 else { break }
                guard activeDirectionalImagePreloadTasks[attachment.mid] == nil else { continue }

                availableSlots -= 1
                startCachedDirectionalImagePromotion(attachment: attachment)
            }
            return
        }

        for candidate in candidates {
            guard availableSlots > 0 else { break }
            guard activeDirectionalImagePreloadTasks[candidate.attachment.mid] == nil,
                  !GlobalImageLoadManager.shared.hasLoad(id: candidate.attachment.mid),
                  !MemoryCapManager.shared.isAboveDuplicateBlockThreshold else {
                continue
            }

            availableSlots -= 1
            startDirectionalImagePreload(attachment: candidate.attachment, url: candidate.url)
        }
    }

    private func startCachedDirectionalImagePromotion(attachment: MimeiFileType) {
        let attachmentCopy = attachment
        let imageId = attachment.mid

        activeDirectionalImagePreloadTasks[imageId] = Task.detached(priority: .utility) { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.activeDirectionalImagePreloadTasks.removeValue(forKey: imageId)
                }
            }

            guard !Task.isCancelled else { return }
            _ = ImageCacheManager.shared.getCompressedImage(for: attachmentCopy)
        }
    }

    private func startDirectionalImagePreload(attachment: MimeiFileType, url: URL) {
        let attachmentCopy = attachment
        let imageId = attachment.mid

        activeDirectionalImagePreloadTasks[imageId] = Task.detached(priority: .utility) { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.activeDirectionalImagePreloadTasks.removeValue(forKey: imageId)
                }
            }

            guard !Task.isCancelled else { return }

            do {
                try Task.checkCancellation()
                var request = URLRequest(url: url)
                request.timeoutInterval = Constants.IMAGE_LOAD_TIMEOUT
                request.cachePolicy = .returnCacheDataElseLoad

                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()

                guard !data.isEmpty,
                      let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    return
                }

                _ = ImageCacheManager.shared.cacheImageData(data, for: attachmentCopy)
            } catch {
                // Directional preload is opportunistic; visible cells perform their own retry.
            }
        }
    }

    private func cancelDirectionalImagePreloads() {
        for task in activeDirectionalImagePreloadTasks.values {
            task.cancel()
        }
        activeDirectionalImagePreloadTasks.removeAll()
    }

    private func visibleImageAttachmentIds() -> Set<String> {
        guard let visibleIndexPaths = tableView.indexPathsForVisibleRows else { return [] }

        var ids = Set<String>()
        for indexPath in visibleIndexPaths {
            guard let tweet = tweetForRow(indexPath.row) else { continue }
            for source in mediaPreloadSources(for: tweet) {
                let mediaAttachments = source.attachments?
                    .filter { TweetBodyUIView.isMediaType($0.type) }
                    .prefix(4) ?? []
                for attachment in mediaAttachments where attachment.type == .image {
                    ids.insert(attachment.mid)
                }
            }
        }
        return ids
    }

    private func mediaPreloadSources(for tweet: Tweet) -> [Tweet] {
        let hasContentText = tweet.content != nil && !(tweet.content?.isEmpty ?? true)
        let hasAttachments = tweet.attachments != nil && !(tweet.attachments?.isEmpty ?? true)
        let hasOwnContent = hasContentText || hasAttachments

        if let originalTweetId = tweet.originalTweetId {
            prefetchEmbeddedTweetIfNeeded(originalTweetId: originalTweetId)

            if !hasOwnContent {
                return Tweet.getInstance(for: originalTweetId).map { [$0] } ?? []
            }

            if let embeddedTweet = Tweet.getInstance(for: originalTweetId) {
                return [tweet, embeddedTweet]
            }
        }

        return [tweet]
    }

    private func resolvedMediaBaseUrl(for tweet: Tweet) -> URL? {
        tweet.author?.baseUrl
            ?? HproseInstance.shared.appUser.baseUrl
            ?? HproseInstance.baseUrl
    }

    // MARK: - Scroll Position Persistence

    /// Save scroll position immediately if scrolled away from top
    /// Save scroll position in memory for same-session navigation (push/pop, VC recreation)
    private func saveScrollPositionIfNeeded() {
        let topInset = tableView.adjustedContentInset.top
        let currentOffset = tableView.contentOffset.y
        let topPosition = -topInset

        // Save position if we're scrolled down from the top (more than 10 points)
        if currentOffset > topPosition + 10 {
            // Save to both instance variable (for same-session) and persistent storage
            savedScrollPosition = currentOffset
            ScrollPositionManager.shared.saveScrollPosition(currentOffset, for: feedIdentifier)
            if UIApplication.shared.applicationState == .background,
               let snapshot = currentBackgroundResumeSnapshot() {
                BackgroundResumeStateStore.shared.save(snapshot)
            }
        } else {
            // Clear position if at/near top
            savedScrollPosition = nil
            ScrollPositionManager.shared.clearScrollPosition(for: feedIdentifier)
            if feedIdentifier == "mainFeed" {
                BackgroundResumeStateStore.shared.clear(reason: "main feed near top")
            }
        }
    }
    
    // MARK: - Height Estimation

    /// Falls back to per-feed content width in case it differs from the global standardContentWidth
    /// (e.g., custom padding on iPad). All skipping/caching logic is in TweetHeightPrewarmer.
    private func scheduleHeightPrewarm(for tweets: [Tweet]) {
        let contentWidth = currentRowLayoutWidth - (leadingPadding + trailingPadding) - 3 - 46 - 4
        guard contentWidth > 1 else { return }
        TweetHeightPrewarmer.shared.prewarmFeedTweets(tweets, contentWidth: contentWidth)
    }

    // MARK: - Video Playback Coordination

    private func rebuildVideoListAndRefreshVisibility(reason: String) {
        let currentTweets = tweets
        let currentPinnedTweets = pinnedTweets
        videoCoordinator.buildVideoList(from: currentTweets, pinnedTweets: currentPinnedTweets) { [weak self] in
            let delay: TimeInterval = self?.feedIdentifier == "mainFeed" ? 0.18 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isTableVisibleForMutation else { return }
                guard !self.isScrollInteractionActive else { return }
                self.lastVisibleTweetIds = []
                self.lastLoadVisibleVideoIds = []
                self.lastContinuePlaybackVideoIds = []
                self.lastOnScreenVideoIds = []
                self.updateVisibleTweetsForVideoPlayback()
            }
        }
    }

    private func scheduleVideoVisibilityRefresh(reason: String) {
        videoVisibilityRefreshGeneration += 1
        let generation = videoVisibilityRefreshGeneration
        let isFeedReturn = reason == "viewDidAppear"
        let isLightweightUpdate = reason == "tweetsSameOrder"
            || reason == "emptyDiff"
            || reason == "tweetsAppended"
        let delays: [TimeInterval]
        if isFeedReturn {
            delays = [0.18]
        } else if isLightweightUpdate {
            delays = [0.1]
        } else {
            delays = [0, 0.2, 0.5]
        }
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.videoVisibilityRefreshGeneration == generation,
                      self.isTableVisibleForMutation else { return }
                guard !self.isScrollInteractionActive else { return }
                if delay > 0, !isFeedReturn && !isLightweightUpdate {
                    self.forceLayoutVisibleCellsForVisibilityPass()
                }
                self.updateVisibleTweetsForVideoPlayback()
                if !isFeedReturn {
                    self.runScrollStopPreloadWhenIdle()
                }
            }
        }
    }

    private func forceLayoutVisibleCellsForVisibilityPass() {
        guard isTableVisibleForMutation else { return }
        guard !isUserDragging && !isDecelerating else { return }
        tableView.layoutIfNeeded()
        for cell in tableView.visibleCells {
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
            cell.contentView.setNeedsLayout()
            cell.contentView.layoutIfNeeded()
        }
    }

    private func refreshVisiblePlaybackAfterProgrammaticListChange(reason: String) {
        guard isTableVisibleForMutation else { return }
        guard isReadyForFeedVideoResume else { return }
        lastVisibleTweetIds = []
        lastLoadVisibleVideoIds = []
        lastContinuePlaybackVideoIds = []
        lastOnScreenVideoIds = []
        forceLayoutVisibleCellsForVisibilityPass()
        updateVisibleTweetsForVideoPlayback()
        runScrollStopPreloadWhenIdle()
        videoCoordinator.recoverVisiblePlaybackAfterInterruption(
            reason: reason,
            isForegroundRecovery: false
        )
    }
    
    /// Defers updateVisibleTweetsForVideoPlayback() to the next run-loop turn instead of
    /// running it synchronously inside scrollViewDidScroll. scrollViewDidScroll fires as part
    /// of the CURRENT CATransaction, before UIKit's own layoutSubviews has created cells for
    /// rows that just scrolled into view — querying visibleCells/cellForRow(at:) at that point
    /// forces UIKit to synchronously build+configure those cells (full CoreText text layout)
    /// right there on the scroll display-link's critical path. Deferring to the next turn lets
    /// the current transaction's layout pass finish normally first, so by the time this runs,
    /// the cells already exist and querying them is a cheap, side-effect-free read.
    private func scheduleVideoVisibilityUpdateNextRunLoop() {
        guard !isVideoVisibilityUpdateScheduled else { return }
        isVideoVisibilityUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isVideoVisibilityUpdateScheduled = false
            self.updateVisibleTweetsForVideoPlayback()
        }
    }

    private func updateVisibleTweetsForVideoPlayback() {
        guard isTableVisibleForMutation else { return }
        guard !isTableViewUpdating else { return }
        guard !tweets.isEmpty || !pinnedTweets.isEmpty else { return }

        // Calculate the actual user-visible rect, excluding areas behind translucent bars.
        // adjustedContentInset accounts for navigation bar, status bar, and toolbar.
        let insets = tableView.adjustedContentInset
        let visibleTop = tableView.contentOffset.y + insets.top
        let visibleBottom = tableView.contentOffset.y + tableView.bounds.height - insets.bottom
        let visibleRect = CGRect(x: 0, y: visibleTop, width: tableView.bounds.width, height: max(0, visibleBottom - visibleTop))

        // Single pass over visible cells: compute tweet visibility, toggle media visibility,
        // and gather load-visible/playable video IDs together so scrolling does less repeated work.
        // NOTE: iterate tableView.visibleCells (already-created cells only), NOT
        // indexPathsForVisibleRows + cellForRow(at:) — the latter forces UIKit to synchronously
        // create+configure a cell (full CoreText text layout) for any row that just scrolled into
        // view but hasn't been prepared yet, right here on the scroll display-link's critical path.
        var visibleTweetIds = Set<String>()
        var loadVisibleVideoIds = Set<String>()
        var continuePlaybackVideoIds = Set<String>()
        var onScreenVideoIds = Set<String>()
        for cell in tableView.visibleCells {
            guard let tweetCell = cell as? TweetTableViewCell,
                  let indexPath = tableView.indexPath(for: tweetCell) else { continue }

            let cellRect = tableView.rectForRow(at: indexPath)
            let intersection = cellRect.intersection(visibleRect)
            let ratio = cellRect.height > 0 ? intersection.height / cellRect.height : 0
            let isRowOnScreen = intersection.height > 0
            let isTweetVisible = ratio >= FeedPlaybackTuning.tweetVisibleRatio

            // Loading uses any positive visibility; autoplay still uses the stricter
            // media-cell threshold returned as `playable`.
            tweetCell.tweetContentView.setMediaVisible(isRowOnScreen)
            let mediaVisibility = tweetCell.tweetContentView.mediaVisibilityIdentifiers(
                visibleRect: visibleRect,
                coordinateSpace: tableView
            )
            loadVisibleVideoIds.formUnion(mediaVisibility.loadVisible)
            continuePlaybackVideoIds.formUnion(mediaVisibility.continuePlayback)
            onScreenVideoIds.formUnion(mediaVisibility.playable)

            guard isTweetVisible, let tweet = tweetForRow(indexPath.row) else { continue }
            visibleTweetIds.insert(tweet.mid)
        }
        guard loadVisibleVideoIds != lastLoadVisibleVideoIds ||
              continuePlaybackVideoIds != lastContinuePlaybackVideoIds ||
              onScreenVideoIds != lastOnScreenVideoIds ||
              visibleTweetIds != lastVisibleTweetIds else {
            return
        }

        lastLoadVisibleVideoIds = loadVisibleVideoIds
        lastContinuePlaybackVideoIds = continuePlaybackVideoIds
        lastOnScreenVideoIds = onScreenVideoIds
        lastVisibleTweetIds = visibleTweetIds
        videoCoordinator.updateViewportVisibility(
            loadVisibleIdentifiers: loadVisibleVideoIds,
            continuePlaybackIdentifiers: continuePlaybackVideoIds,
            playableIdentifiers: onScreenVideoIds,
            visibleTweetIds: visibleTweetIds
        )

        // Identify a primary candidate as soon as it crosses the visibility threshold,
        // whether the user's finger is still down or the table is decelerating after a
        // fling — rather than waiting for the scroll to fully stop. A typical fling is a
        // short drag followed by a long momentum deceleration, so most of the scrolling
        // (and most threshold crossings) happens during isDecelerating, not isUserDragging;
        // gating this on isUserDragging alone meant videos that scrolled into view during
        // the coast phase never got identified until the scroll fully stopped. This only
        // marks a tentative candidate — actually starting playback/preloading and demoting
        // other videos to non-primary stays withheld behind a confirmation window inside
        // the coordinator, so a fast fling that keeps crossing new thresholds doesn't
        // thrash between candidates.
        if isUserDragging || isDecelerating {
            videoCoordinator.identifyPrimaryVideoDuringActiveScroll()
        }

        // Directional image preload is handled separately so video coordination stays light during scroll.
    }
    
    /// Calculate the visible main content area (excluding header and footer)
    /// Cached to avoid expensive recalculation on every visibility check
    private func calculateMainContentRect() -> CGRect {
        let currentOffset = tableView.contentOffset.y
        let currentHeaderHeight = tableView.tableHeaderView?.frame.height ?? 0
        let currentFooterHeight = tableView.tableFooterView?.frame.height ?? 0
        
        // Return cached rect if conditions haven't changed significantly (within 10pt)
        if let cached = cachedMainContentRect,
           abs(currentOffset - lastContentOffset) < 10,
           abs(currentHeaderHeight - lastHeaderHeight) < 1,
           abs(currentFooterHeight - lastFooterHeight) < 1 {
            return cached
        }
        
        // Recalculate if cache is invalid
        let visibleBounds = tableView.bounds
        var mainContentY = currentOffset
        var mainContentHeight = visibleBounds.height
        
        // Exclude table header view from top
        if let headerView = tableView.tableHeaderView {
            let headerHeight = headerView.frame.height
            let headerBottom = headerHeight // Header is at position 0
            
            // If we're scrolled such that header is still visible, adjust top boundary
            if mainContentY < headerBottom {
                let headerVisibleHeight = headerBottom - mainContentY
                mainContentY += headerVisibleHeight
                mainContentHeight -= headerVisibleHeight
            }
        }
        
        // Exclude table footer view from bottom
        if let footerView = tableView.tableFooterView {
            let footerHeight = footerView.frame.height
            let contentHeight = tableView.contentSize.height
            let footerTop = contentHeight - footerHeight
            let visibleBottom = currentOffset + visibleBounds.height
            
            // If footer is visible at bottom, adjust bottom boundary
            if visibleBottom > footerTop {
                let footerVisibleHeight = visibleBottom - footerTop
                mainContentHeight -= footerVisibleHeight
            }
        }
        
        let rect = CGRect(
            x: 0,
            y: mainContentY,
            width: visibleBounds.width,
            height: max(0, mainContentHeight) // Ensure non-negative height
        )
        
        // Cache the result
        cachedMainContentRect = rect
        lastContentOffset = currentOffset
        lastHeaderHeight = currentHeaderHeight
        lastFooterHeight = currentFooterHeight
        
        return rect
    }
    
    // MARK: - Bottom Pull-to-Load
    //
    // Flow when user pulls at bottom:
    // - WITH server call: Spinner shows minimum 500ms, waits for server response
    //   - If server responds: Spinner hides after response (minimum 500ms enforced)
    //   - If timeout (10s): Spinner force-hides with warning log
    // - WITHOUT server call (no more tweets):
    //   1. Show spinner for exactly 500ms
    //   2. Hide spinner with animation
    //   3. Show "no more tweets" message for exactly 2s
    //   4. Hide message with animation
    //   5. Apply 2s cooldown before showing message again
    
    /// Programmatically trigger load more (e.g., from external button or gesture)
    func triggerLoadMore() {
        triggerBottomPullLoadMore()
    }
    
    /// Show "no more tweets" message (can be called externally)
    func showNoMoreTweetsMessageIfNeeded() {
        if canShowNoMoreTweetsMessage && tweets.count > 0 {
            showNoMoreTweetsMessage()
        }
    }
    
    private func triggerBottomPullLoadMore() {
        guard !isLoadingMore else { return }

        // Check if there are no more tweets to load
        if !hasMoreTweets {
            showNoMoreTweetsMessageIfNeeded()
            isBottomPullActive = false
            return
        }

        updateLoadingState(
            isLoading: isLoading,
            isLoadingMore: true,
            hasMoreTweets: hasMoreTweets,
            canShowNoMoreTweetsMessage: canShowNoMoreTweetsMessage
        )

        // Call the load more callback with forceLoad=true to bypass hasMoreTweets check
        loadMoreTweets?(true)

        // Notify callback if registered
        onLoadMoreRequested?()
    }

    private func triggerAutoLoadMore() {
        guard hasMoreTweets, !isLoadingMore else { return }

        updateLoadingState(
            isLoading: isLoading,
            isLoadingMore: true,
            hasMoreTweets: hasMoreTweets,
            canShowNoMoreTweetsMessage: canShowNoMoreTweetsMessage
        )

        // Automatic pagination should obey hasMoreTweets; threshold crossing decides when it fires.
        loadMoreTweets?(false)

        // Notify callback if registered
        onLoadMoreRequested?()
    }
    
    private func showNoMoreTweetsMessage() {
        guard canShowNoMoreTweetsMessage, tweets.count > 0 else { return }
        guard !isShowingNoMoreTweetsMessage else { return }
        guard tableView.window != nil else {
            needsFooterUpdate = true
            return
        }

        isShowingNoMoreTweetsMessage = true
        lastNoMoreTweetsShownTime = Date()
        noMoreTweetsMessageTimer?.invalidate()

        let footerView = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 120))
        footerView.backgroundColor = .clear
        footerView.isUserInteractionEnabled = false

        let messageLabel = UILabel()
        messageLabel.text = NSLocalizedString("No more tweets", comment: "Message shown when there are no more tweets to load")
        messageLabel.textAlignment = .center
        messageLabel.font = .systemFont(ofSize: 15, weight: .medium)
        messageLabel.textColor = XTheme.secondaryText
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.isUserInteractionEnabled = false

        footerView.addSubview(messageLabel)

        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: footerView.centerXAnchor),
            messageLabel.topAnchor.constraint(equalTo: footerView.topAnchor, constant: 40)
        ])

        footerView.alpha = 0
        footerView.transform = CGAffineTransform(translationX: 0, y: 20)
        tableView.tableFooterView = footerView

        UIView.animate(withDuration: 0.4, delay: 0, options: .curveEaseOut) {
            footerView.alpha = 1.0
            footerView.transform = .identity
        }

        // Auto-hide after 2 seconds
        noMoreTweetsMessageTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }

                UIView.animate(withDuration: 0.3, animations: {
                    footerView.alpha = 0
                    footerView.transform = CGAffineTransform(translationX: 0, y: -10)
                }) { _ in
                    if self.tableView.tableFooterView === footerView {
                        self.tableView.tableFooterView = nil
                    }
                    self.isShowingNoMoreTweetsMessage = false

                    // Small delay to prevent immediate spinner flash after message removal
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        MainActor.assumeIsolated {
                            if self.isLoadingMore && self.hasMoreTweets {
                                self.updateLoadingState(
                                    isLoading: self.isLoading,
                                    isLoadingMore: self.isLoadingMore,
                                    hasMoreTweets: self.hasMoreTweets,
                                    canShowNoMoreTweetsMessage: self.canShowNoMoreTweetsMessage
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func clearNoMoreTweetsMessageIfNeeded() {
        guard isShowingNoMoreTweetsMessage else { return }

        noMoreTweetsMessageTimer?.invalidate()
        noMoreTweetsMessageTimer = nil
        isShowingNoMoreTweetsMessage = false

        if tableView.tableFooterView != nil {
            tableView.tableFooterView = nil
        }
    }
}

// MARK: - Prefetching (Performance Optimization)
extension TweetTableViewController: UITableViewDataSourcePrefetching {
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        // PERFORMANCE: Prefetch limited quoted/retweet payloads ahead (max 3) without blocking UI.
        let limitedPrefetch = Array(indexPaths.prefix(3))
        for indexPath in limitedPrefetch {
            guard let tweet = tweetForRow(indexPath.row),
                  let originalTweetId = tweet.originalTweetId else { continue }
            prefetchEmbeddedTweetIfNeeded(originalTweetId: originalTweetId)
        }
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        // No action needed - prefetch is async cache warming only.
    }
}
