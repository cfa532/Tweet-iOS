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
    private var isLoadingMore: Bool = false
    
    // Bottom pull-to-load state
    private var isBottomPullActive: Bool = false
    private var bottomPullThreshold: CGFloat = 50  // Pull down 50pt to trigger (reduced from 80)
    
    // Spinner timing
    private var loadingSpinnerStartTime: Date? = nil
    private let minimumSpinnerDisplayTime: TimeInterval = 0.5  // 500ms minimum
    private var loadingTimeoutTimer: Timer?
    private let maximumLoadingTime: TimeInterval = 10.0  // 10 second timeout
    
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
    var leadingPadding: CGFloat = 8  // Configurable leading padding for cells
    var trailingPadding: CGFloat = 8  // Configurable trailing padding for cells

    // Pure UIKit cell configuration (replaces rowViewBuilder)
    var hproseInstance: HproseInstance?
    var onAvatarTap: ((User) -> Void)?
    var onTweetTap: ((Tweet) -> Void)?
    var onShowLogin: (() -> Void)?
    var onShowToast: ((String, Bool) -> Void)?
    var allowDeleteAll: Bool = false
    
    // Header hosting controller
    private var headerHostingController: UIHostingController<AnyView>?
    
    // Refresh control
    private var customRefreshControl: UIRefreshControl?
    
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
    private let videoVisibilityThrottleInterval: TimeInterval = 0.15 // 150ms during active drag
    private var lastVisibleTweetIds: Set<String> = [] // Cache last visible tweet IDs
    private var lastPreloadTweetIds: Set<String> = [] // Cache last preload zone tweet IDs
    private var lastOnScreenVideoIds: Set<String> = [] // Cache per-cell on-screen video identifiers
    
    // Cached main content rect to avoid recalculating on every visibility check
    private var cachedMainContentRect: CGRect?
    private var lastContentOffset: CGFloat = 0
    private var lastCallbackOffset: CGFloat = 0  // Only updated when onScroll fires — gives accumulated delta
    private var isCompensatingForBarAppearance: Bool = false  // Compensate contentOffset when header expands
    private var compensationBaseOriginY: CGFloat?
    private var lastHeaderHeight: CGFloat = 0
    private var lastFooterHeight: CGFloat = 0
    
    // Notification observer for scroll to top
    private var scrollToTopObserver: NSObjectProtocol?

    // Foreground/background observer to prevent white space issue
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var needsVideoLayerRefresh = false
    private var scrollPositionBeforeBackground: CGFloat?

    // Observer for feed view appearance (to restart video playback after navigation)
    private var feedViewDidAppearObserver: NSObjectProtocol?

    // Scroll position preservation
    private var savedScrollPosition: CGFloat?
    private var isScrollingToTop: Bool = false

    // Feed identifier for persistent scroll position storage
    var feedIdentifier: String = "mainFeed"  // Default to main feed
    
    // Track scroll direction for height caching strategy
    private var isScrollingBackward: Bool = false

    // Scroll state tracking to prevent direction detection jitter during deceleration
    private var isUserDragging: Bool = false
    private var isDecelerating: Bool = false

    init(videoCoordinator: VideoPlaybackCoordinator) {
        self.videoCoordinator = videoCoordinator
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupTableView()
        setupRefreshControl()
        setupScrollToTopObserver()
        setupMemoryWarningObserver()
        setupForegroundBackgroundObservers()
        setupFeedViewDidAppearObserver()

        // Pass table view reference to video coordinator for viewport calculations
        videoCoordinator.setTableView(tableView)
    }
    
    deinit {
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

        if let observer = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        if let observer = feedViewDidAppearObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        // Clean up timers
        noMoreTweetsMessageTimer?.invalidate()
        loadingTimeoutTimer?.invalidate()

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
            guard let self = self else { return }

            // Check if this notification is for this specific feed
            if let targetFeedId = notification.userInfo?["feedIdentifier"] as? String {
                // Only scroll if the notification targets this feed
                if targetFeedId == self.feedIdentifier {
                    self.scrollToTop()
                }
            } else {
                // No target specified - scroll if this is the main feed
                if self.feedIdentifier == "mainFeed" {
                    self.scrollToTop()
                }
            }
        }
    }

    /// Setup observer for feed view appearance to resume video playback after navigation
    private func setupFeedViewDidAppearObserver() {
        feedViewDidAppearObserver = NotificationCenter.default.addObserver(
            forName: .feedViewDidAppear,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            // When the same video was playing on the profile we left, main feed and profile share
            // one AVPlayer (SharedAssetCache). The profile's SimpleVideoPlayer.onDisappear runs
            // during teardown and calls player.pause() on that shared instance. If we send our
            // resume-play command before the profile has torn down, the profile's onDisappear
            // can run afterward and pause the player again. Delay so teardown completes first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self else { return }
                Task { @MainActor in
                    print("📺 [VIDEO RESTART] Feed '\(self.feedIdentifier)' view appeared - resuming video playback")
                    // Do not call stopAllVideos() when returning from profile (or other navigation).
                    // That was stopping the current video; instead refresh visibility and resume
                    // the current primary if it is still visible so playback continues.
                    self.lastVisibleTweetIds = []
                    self.updateVisibleTweetsForVideoPlayback()
                    self.videoCoordinator.requestResumePrimaryPlaybackIfVisible()
                }
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

            // Stop all videos and clear coordinator caches via notification
            NotificationCenter.default.post(name: .shouldStopAllVideos, object: nil)

            // Force reload visible cells to reclaim memory
            if let visibleIndexPaths = self?.tableView.indexPathsForVisibleRows {
                self?.tableView.reloadRows(at: visibleIndexPaths, with: .none)
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
            guard let self = self else { return }

            // Request background time from iOS to complete cleanup
            self.backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
                // Cleanup callback - iOS is about to force-terminate background task
                print("⚠️ [BACKGROUND] Background task time expired - iOS forcing cleanup")
                self?.endBackgroundTask()
            }

            // Log memory before cleanup
            print("🌙 [BACKGROUND] App entering background - starting aggressive memory cleanup")

            // Save the current scroll position before backgrounding
            self.scrollPositionBeforeBackground = self.tableView.contentOffset.y

            // Show cached thumbnails on visible video cells before AppDelegate releases video memory.
            // This prevents black AVPlayerLayer in the app switcher snapshot.
            for cell in self.tableView.visibleCells {
                guard let tweetCell = cell as? TweetTableViewCell else { continue }
                tweetCell.tweetContentView.showVideoThumbnailsForBackground()
            }

            // End background task after a short delay to allow cleanup to complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                print("✅ [BACKGROUND] Cleanup complete")

                // End background task when done
                self.endBackgroundTask()
            }
        }

        // Restore scroll position and video players when app returns to foreground
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            print("☀️ [FOREGROUND] App returning to foreground")

            // Cancel background task if still active
            self.endBackgroundTask()
            self.needsVideoLayerRefresh = true

            guard let savedPosition = self.scrollPositionBeforeBackground else { return }

            // Restore the scroll position after a brief delay to let layout settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self else { return }
                // Set lastContentOffset before restoring so scrollViewDidScroll sees zero delta
                // This prevents the restoration from triggering toolbar hiding
                self.lastContentOffset = savedPosition
                self.lastCallbackOffset = savedPosition
                self.tableView.setContentOffset(CGPoint(x: 0, y: savedPosition), animated: false)
                self.scrollPositionBeforeBackground = nil

                // Restore visible video players and preload 2 more in scroll direction
                self.restoreVideoPlayersAfterForeground()
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
            guard let self = self, self.needsVideoLayerRefresh else { return }
            self.needsVideoLayerRefresh = false
            for cell in self.tableView.visibleCells {
                guard let tweetCell = cell as? TweetTableViewCell else { continue }
                tweetCell.tweetContentView.refreshVideoLayersAfterForeground()
            }
        }
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

    /// Restore visible video players after returning from background
    /// With health checks in place, we simply validate cached players and update visibility
    /// Broken players will be auto-detected and recreated on-demand
    private func restoreVideoPlayersAfterForeground() {
        print("☀️ [VIDEO RESTORE] Restoring video playback")

        // Step 1: Validate all cached players and remove any that are broken
        // This proactively cleans up players that were invalidated during backgrounding
        videoCoordinator.validatePlayersAfterBackground()

        // Step 2: Get currently visible tweet IDs
        let visibleIndexPaths = tableView.indexPathsForVisibleRows ?? []
        let visibleTweetIds = Set(visibleIndexPaths.compactMap { indexPath -> String? in
            let totalRows = pinnedTweets.count + tweets.count
            guard indexPath.row < totalRows else { return nil }

            if indexPath.row < pinnedTweets.count {
                return pinnedTweets[indexPath.row].mid
            } else {
                let regularIndex = indexPath.row - pinnedTweets.count
                guard regularIndex < tweets.count else { return nil }
                return tweets[regularIndex].mid
            }
        })

        print("☀️ [VIDEO RESTORE] Updating visibility for \(visibleTweetIds.count) visible tweets")

        // Step 3: Update visible tweets to trigger playback
        // Any players that were removed in step 1 will be automatically recreated when needed
        videoCoordinator.updateVisibleTweets(visibleTweetIds)

        print("✅ [VIDEO RESTORE] Video restoration complete - healthy players retained, broken ones will be recreated")
    }

    func scrollToTop() {
        // Clear saved scroll position when scrolling to top
        savedScrollPosition = nil
        ScrollPositionManager.shared.clearScrollPosition(for: feedIdentifier)
        isScrollingToTop = true

        // Scroll to the absolute top of the table view with animation
        // Use the top of the content including any table header view
        // Calculate the proper top position accounting for content inset
        let topInset = tableView.adjustedContentInset.top

        // If there's a table header, we want to show it, so scroll to -topInset
        // This positions the header at the top of the visible area (below nav bar)
        let targetOffset = CGPoint(x: 0, y: -topInset)
        tableView.setContentOffset(targetOffset, animated: true)

        // Also ensure we're at the exact top by forcing layout
        tableView.layoutIfNeeded()

        // Reset flag after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isScrollingToTop = false
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Resume video playback when returning from a UIKit full-screen modal (e.g. the
        // MediaBrowserView fullscreen player).  TweetListView.onAppear does NOT fire for
        // UIKit .fullScreen modal dismissal because the SwiftUI view stays in the hierarchy
        // while the modal is presented, so the .feedViewDidAppear notification is never
        // posted through that path.  Re-evaluate visibility here to fill the gap.
        // The 0.25s delay lets the dismiss cross-dissolve animation complete before we
        // start playing, which prevents audio starting while the transition is still visible.
        if isMovingToParent == false {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.lastVisibleTweetIds = []
                self.updateVisibleTweetsForVideoPlayback()
                self.videoCoordinator.requestResumePrimaryPlaybackIfVisible()
            }
        }

        // Restore scroll position for same-session navigation (push/pop or VC recreation)
        if !isScrollingToTop {
            // Check instance variable first, then in-memory ScrollPositionManager
            let position = savedScrollPosition ?? ScrollPositionManager.shared.getScrollPosition(for: feedIdentifier)
            if let position {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, !self.isScrollingToTop else { return }
                    self.lastContentOffset = position
                    self.lastCallbackOffset = position
                    self.tableView.setContentOffset(CGPoint(x: 0, y: position), animated: false)
                    self.lastScrollOffset = position
                    self.savedScrollPosition = nil
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
            let hasSavedPosition = savedScrollPosition != nil || ScrollPositionManager.shared.getScrollPosition(for: feedIdentifier) != nil
            if topInset > 0 && currentOffset >= -5 && currentOffset <= 5 && !hasSavedPosition {
                tableView.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false)
                lastScrollOffset = -topInset
            }
        }

        // NOTE: Video playback restart is handled by .feedViewDidAppear notification
        // (see setupFeedViewDidAppearObserver) which re-evaluates visibility to resume playback
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // Stop all feed videos when navigating away (detail view push, profile tap, etc.).
        // Without this the feed keeps active AVPlayer XPC sessions alive while the destination
        // view tries to open its own, hitting the system's concurrent-player limit and causing
        // PlayerRemoteXPC -12860 errors that prevent the destination video from playing.
        // Playback is restored by the .feedViewDidAppear handler when the feed becomes visible again.
        videoCoordinator.stopAllVideos()

        // Save current scroll position when view disappears (backup to scroll delegate methods)
        saveScrollPositionIfNeeded()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Compensate contentOffset when the header expands without animation.
        // The frame jumps instantly; we adjust offset by the same amount so
        // visible content stays at the same screen position.
        if isCompensatingForBarAppearance, let baseY = compensationBaseOriginY {
            let currentY = view.convert(CGPoint.zero, to: nil).y
            let shift = currentY - baseY
            if abs(shift) > 1 {
                tableView.contentOffset.y += shift
                compensationBaseOriginY = currentY
                isCompensatingForBarAppearance = false
            }
        }

        // Initialize lastScrollOffset to current offset to prevent incorrect delta on first scroll
        // This prevents toolbar from hiding incorrectly when view loads with negative content offset
        if !hasCompletedInitialLayout {
            lastScrollOffset = tableView.contentOffset.y
            hasCompletedInitialLayout = true

            // Ensure table view is scrolled to proper top position (respecting safe area)
            // This prevents header from being covered by navigation bar
            let topInset = tableView.adjustedContentInset.top
            let currentOffset = tableView.contentOffset.y

            // If offset is too negative (header would be under nav bar), correct it
            // But only if we don't have a saved position to restore
            let hasSavedPosition = savedScrollPosition != nil || ScrollPositionManager.shared.getScrollPosition(for: feedIdentifier) != nil
            if currentOffset < -topInset && !hasSavedPosition {
                tableView.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false)
                lastScrollOffset = -topInset
            }
        }
    }
    
    private func setupTableView() {
        tableView.register(TweetTableViewCell.self, forCellReuseIdentifier: TweetTableViewCell.reuseIdentifier)
        tableView.separatorStyle = .none
        tableView.backgroundColor = .systemBackground
        
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
    
    private func setupRefreshControl() {
        customRefreshControl = UIRefreshControl()
        customRefreshControl?.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        tableView.refreshControl = customRefreshControl
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
        let oldCount = pinnedTweets.count
        let oldPinnedTweets = pinnedTweets
        self.pinnedTweets = tweets

        // Rebuild video list when pinned tweets change
        // This ensures pinned tweet videos are registered with the coordinator
        videoCoordinator.buildVideoList(from: self.tweets, pinnedTweets: pinnedTweets)

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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.updateVisibleTweetsForVideoPlayback()
                }
                return
            }
        }

        // Reload table to reflect new pinned tweets
        if oldCount != tweets.count {
            // Number of rows changed, do a full reload
            tableView.reloadData()
        } else if oldCount > 0 {
            // Different tweets in same positions, update the content
            let indexPaths = (0..<oldCount).map { IndexPath(row: $0, section: 0) }
            tableView.reloadRows(at: indexPaths, with: .none)
        }

        // CRITICAL: Update visibility after reload so coordinator knows pinned videos are visible
        // Use longer delay (300ms) to ensure cells are fully rendered
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.updateVisibleTweetsForVideoPlayback()
        }
    }
    
    func updateTweets(_ newTweets: [Tweet]) {
        let oldCount = tweets.count
        let oldTweets = tweets
        tweets = newTweets

        // Pre-fetch embedded tweets for accurate height calculation (pure UIKit optimization)
        // Load embedded tweets in background so they're available when cells are displayed
        Task.detached(priority: .userInitiated) {
            for tweet in newTweets {
                if let originalTweetId = tweet.originalTweetId {
                    // Check if already loaded
                    if Tweet.getInstance(for: originalTweetId)?.author == nil {
                        // Try to fetch from cache (fast, async)
                        _ = await TweetCacheManager.shared.fetchTweet(mid: originalTweetId)
                    }
                }
            }
        }

        // Cleanup old tweet instances to prevent memory growth
        Task.detached(priority: .background) {
            let activeTweetIds = Set(newTweets.map { $0.mid })
            Tweet.cleanupOldInstances(activeTweetIds: activeTweetIds)
        }
        
        
        // Handle initial load
        if oldCount == 0 && newTweets.count > 0 {
            tableView.reloadData()
            videoCoordinator.buildVideoList(from: newTweets, pinnedTweets: pinnedTweets)
            
            // Trigger video detection after initial load
            // CRITICAL: Use longer delay (300ms) to ensure all cells are fully rendered
            // 100ms was too short, causing only first video to be detected on app launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.updateVisibleTweetsForVideoPlayback()
            }
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
                // OPTIMIZATION: Same tweets in same order - only hit counts changed
                // Tweet.getInstance() already updated the @Published count properties
                // SwiftUI will automatically re-render action buttons, no need to reload cells
                videoCoordinator.buildVideoList(from: newTweets, pinnedTweets: pinnedTweets)
                return
            }
        }
        
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
                let indexPaths = (0..<potentialPrependCount).map { IndexPath(row: $0, section: 0) }
                tableView.insertRows(at: indexPaths, with: .automatic)
                videoCoordinator.buildVideoList(from: newTweets, pinnedTweets: pinnedTweets)
                return
            }
        }
        
        // Case 2: Tweets appended (pagination) - common for load more
        if newTweets.count > oldCount {
            let newIdsPrefix = Array(getNewIds().prefix(oldCount))
            
            if newIdsPrefix == getOldIds() {
                let indexPaths = (oldCount..<newTweets.count).map { IndexPath(row: $0, section: 0) }
                tableView.insertRows(at: indexPaths, with: .none)
                videoCoordinator.buildVideoList(from: newTweets, pinnedTweets: pinnedTweets)
                return
            }
        }
        
        // Case 3: Single tweet removed - common for delete
        // OPTIMIZED: Use Set for O(1) lookup instead of O(n)
        if newTweets.count == oldCount - 1 {
            let newIdsSet = Set(getNewIds())
            if let removedIndex = getOldIds().firstIndex(where: { !newIdsSet.contains($0) }) {
                tableView.deleteRows(at: [IndexPath(row: removedIndex, section: 0)], with: .automatic)
                videoCoordinator.buildVideoList(from: newTweets, pinnedTweets: pinnedTweets)
                return
            }
        }
        
        // Complex change: fallback to full reload
        tableView.reloadData()
        videoCoordinator.buildVideoList(from: newTweets, pinnedTweets: pinnedTweets)
    }
    
    func updateHeader() {
        guard let headerBuilder = headerViewBuilder else {
            if tableView.tableHeaderView != nil {
                tableView.tableHeaderView = nil
            }
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
            let contentWidth = tableWidth - (leadingPadding + trailingPadding)
            
            // Size the SwiftUI view properly
            headerView.translatesAutoresizingMaskIntoConstraints = true
            
            // Set a fixed width for the hosting controller to ensure proper layout
            hostingController.view.frame.size.width = contentWidth
            
            // Calculate the fitting height with the fixed width
            let targetSize = CGSize(width: contentWidth, height: UIView.layoutFittingCompressedSize.height)
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
            
            // Recalculate size with frame-based layout
            if let headerView = headerHostingController?.view, let containerView = tableView.tableHeaderView {
                let tableWidth = max(tableView.bounds.width, 100)
                let contentWidth = tableWidth - (leadingPadding + trailingPadding)
                
                // Set fixed width before calculating height
                headerView.frame.size.width = contentWidth
                headerView.setNeedsLayout()
                headerView.layoutIfNeeded()
                
                let targetSize = CGSize(width: contentWidth, height: UIView.layoutFittingCompressedSize.height)
                let fittingSize = headerHostingController?.sizeThatFits(in: targetSize) ?? targetSize
                
                // Update frames if size changed
                let oldHeight = containerView.frame.height
                if abs(oldHeight - fittingSize.height) > 1 {
                    
                    // CRITICAL: Preserve scroll position when updating header
                    let currentOffset = tableView.contentOffset
                    let topInset = tableView.adjustedContentInset.top
                    
                    headerView.frame = CGRect(x: leadingPadding, y: 0, width: contentWidth, height: fittingSize.height)
                    containerView.frame = CGRect(x: 0, y: 0, width: tableWidth, height: fittingSize.height)
                    
                    // Trigger table view layout update
                    tableView.tableHeaderView = containerView
                    
                    // Only adjust scroll position if user has scrolled away from the top
                    // If at the top (offset near 0 or -topInset), stay at the top
                    let heightDiff = fittingSize.height - oldHeight
                    let isAtTop = abs(currentOffset.y) < 10 || (topInset > 0 && abs(currentOffset.y + topInset) < 10)
                    
                    if isAtTop {
                        // At the top: keep position at proper top (below nav bar) with smooth animation
                        let properTopOffset = topInset > 0 ? -topInset : 0
                        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut, animations: {
                            self.tableView.setContentOffset(CGPoint(x: 0, y: properTopOffset), animated: false)
                        }, completion: nil)
                    } else {
                        // Scrolled down: preserve visible content by adjusting for height change (instant)
                        let newOffset = CGPoint(x: currentOffset.x, y: currentOffset.y + heightDiff)
                        tableView.setContentOffset(newOffset, animated: false)
                    }
                }
            }
        }
    }
    
    func updateLoadingState(isLoadingMore: Bool, hasMoreTweets: Bool) {
        // Track previous states
        let previousLoadingMore = self.isLoadingMore
        let previousHasMoreTweets = self.hasMoreTweets
        let stateChanged = previousLoadingMore != isLoadingMore || previousHasMoreTweets != hasMoreTweets
        
        self.isLoadingMore = isLoadingMore
        self.hasMoreTweets = hasMoreTweets
        
        // ✅ FIX: Only log state changes, and avoid logging Date() or complex objects
        // Excessive logging can cause Xcode console to stop showing logs (FontServicesDaemonManager error)
        if stateChanged {
        }

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
                guard let self = self else { return }
                if self.isLoadingMore {
                    self.updateLoadingState(isLoadingMore: false, hasMoreTweets: self.hasMoreTweets)
                }
            }

            // Use taller footer to position spinner just above bottom nav bar
            let footerView = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 80))
            footerView.backgroundColor = .clear

            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.center = CGPoint(x: footerView.bounds.width / 2, y: 30)
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
                let shouldShowMessage = previousLoadingMore && !hasMoreTweets && tweets.count > 0

                // Add cooldown check
                let canShowMessage: Bool
                if let lastShown = lastNoMoreTweetsShownTime {
                    canShowMessage = Date().timeIntervalSince(lastShown) > noMoreTweetsMessageCooldown
                } else {
                    canShowMessage = true
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

        // CRITICAL: Load embedded/quoted tweet BEFORE configuring cell
        // This prevents layout shifts and overlapping when the embedded tweet loads
        // Prefetching will have already warmed the cache, making this fast
        if let originalTweetId = tweet.originalTweetId {
            // Try to get from cache synchronously and ensure it's in the singleton store
            if let cachedEmbeddedTweet = TweetCacheManager.shared.fetchTweetSync(mid: originalTweetId) {
                // Get or create the singleton instance with full data from cache
                _ = Tweet.getInstance(
                    mid: cachedEmbeddedTweet.mid,
                    authorId: cachedEmbeddedTweet.authorId,
                    content: cachedEmbeddedTweet.content,
                    timestamp: cachedEmbeddedTweet.timestamp,
                    title: cachedEmbeddedTweet.title,
                    originalTweetId: cachedEmbeddedTweet.originalTweetId,
                    originalAuthorId: cachedEmbeddedTweet.originalAuthorId,
                    author: cachedEmbeddedTweet.author,
                    favorites: cachedEmbeddedTweet.favorites,
                    favoriteCount: cachedEmbeddedTweet.favoriteCount ?? 0,
                    bookmarkCount: cachedEmbeddedTweet.bookmarkCount ?? 0,
                    retweetCount: cachedEmbeddedTweet.retweetCount ?? 0,
                    commentCount: cachedEmbeddedTweet.commentCount ?? 0,
                    attachments: cachedEmbeddedTweet.attachments,
                    isPrivate: cachedEmbeddedTweet.isPrivate,
                    downloadable: cachedEmbeddedTweet.downloadable
                )
            }
        }

        let totalRows = pinnedTweets.count + tweets.count
        let isLastItem = indexPath.row == totalRows - 1

        if let hprose = hproseInstance {
            cell.configure(
                with: tweet,
                hproseInstance: hprose,
                isPinned: indexPath.row < pinnedTweets.count,
                isLastItem: isLastItem,
                parentViewController: self,
                leadingPadding: leadingPadding,
                trailingPadding: trailingPadding,
                videoCoordinator: videoCoordinator,
                onAvatarTap: onAvatarTap,
                onTweetTap: onTweetTap,
                onShowLogin: onShowLogin,
                onShowToast: onShowToast,
                allowDeleteAll: allowDeleteAll
            )
        }

        // Height change callback for embedded tweets that load asynchronously
        // When the embedded tweet loads, the cell expands and the table must re-layout
        cell.onHeightChanged = { [weak self, weak cell] in
            guard let self, let cell,
                  let indexPath = self.tableView.indexPath(for: cell) else { return }
            // Invalidate cached height so Auto Layout remeasures
            let tweet: Tweet
            if indexPath.row < self.pinnedTweets.count {
                tweet = self.pinnedTweets[indexPath.row]
            } else {
                let idx = indexPath.row - self.pinnedTweets.count
                guard idx < self.tweets.count else { return }
                tweet = self.tweets[idx]
            }
            tweet.cachedHeight = nil

            // Guard: only trigger height recalc if data source is still consistent
            // If pinnedTweets/tweets changed since last reload, a reloadData is pending
            let expectedCount = self.pinnedTweets.count + self.tweets.count
            let currentCount = self.tableView.numberOfRows(inSection: 0)
            if expectedCount == currentCount {
                UIView.performWithoutAnimation {
                    self.tableView.beginUpdates()
                    self.tableView.endUpdates()
                }

                // CRITICAL: Cache the new height immediately after re-layout
                // willDisplay is NOT called for already-visible cells, so we must cache here
                // to prevent scroll jumps when the cell scrolls away and back
                if cell.frame.height > 0 {
                    // Verify embedded tweet is still loaded (in case of rapid changes)
                    let needsEmbeddedTweet = tweet.originalTweetId != nil
                    let embeddedTweetLoaded = !needsEmbeddedTweet ||
                                             (Tweet.getInstance(for: tweet.originalTweetId!)?.author != nil)
                    if embeddedTweetLoaded {
                        // Sanity check: don't cache if significantly smaller than expected
                        // (indicates cell hasn't fully rendered — e.g., media grid pending)
                        let expectedHeight = Self.calculateTweetHeight(for: tweet)
                        let isReasonable = cell.frame.height >= expectedHeight - 20
                        if isReasonable {
                            tweet.cachedHeight = cell.frame.height
                            TweetHeightCache.shared.setHeight(cell.frame.height, for: tweet.mid)
                        }
                    }
                }
            }
        }

        return cell
    }
    
    // MARK: - UITableViewDelegate

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

        // Use in-memory cached height if available — set by willDisplay from actual Auto Layout
        if let cachedHeight = tweet.cachedHeight {
            return cachedHeight
        }

        // Use persisted height cache (survives app restarts) as second-best estimate.
        // This prevents scroll jumps for previously-viewed tweets on cold start.
        // NOTE: Do NOT set tweet.cachedHeight here — persisted heights may be stale
        // (e.g., from a session where the cell didn't fully render). Only willDisplay
        // should set cachedHeight after Auto Layout verifies the actual height.
        if let persistedHeight = TweetHeightCache.shared.getHeight(for: tweet.mid) {
            return persistedHeight
        }

        // Use deterministic calculation as estimate.
        // willDisplay caches the actual Auto Layout height for future use,
        // so subsequent calls will hit the cachedHeight path above.
        return Self.calculateTweetHeight(for: tweet)
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
    static func calculateTweetHeight(for tweet: Tweet) -> CGFloat {
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

        // Header: stackView height = tallest label's single-line height.
        // Uses .preferredFont(.headline) which varies with Dynamic Type.
        let headerHeight = ceil(UIFont.preferredFont(forTextStyle: .headline).lineHeight)
        height += headerHeight

        // spacing after header: 0
        // Body: text + media
        // TweetBodyUIView layout: contentStack.top = bodyView.top + 2 (always)
        // contentLabel → media: customSpacing = 4 when text visible, 0 when hidden
        // Account for cell-level padding (leadingPadding + trailingPadding, default 8+8)
        let cellPadding: CGFloat = 16 // leadingPadding(8) + trailingPadding(8) default
        let contentWidth = (UIScreen.main.bounds.width - cellPadding - 3 /* leading */ - 42 /* avatar */ - 4 /* stack spacing */)

        // bodyHeight mirrors TweetBodyUIView's contentStack Auto Layout
        var bodyHeight: CGFloat = 2 // contentStack.top offset (always present)
        var hasTextContent = false

        if let content = displayTweet.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hasTextContent = true
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
            // Use shared UILabel for exact height matching (avoids boundingRect vs UILabel diffs)
            Self.measurementLabel.attributedText = attrString
            let textSize = Self.measurementLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
            bodyHeight += ceil(textSize.height)
        }

        // Media attachments (filter to media-only, matching TweetBodyUIView)
        let mediaAttachments = displayTweet.attachments?.filter { TweetBodyUIView.isMediaType($0.type) } ?? []
        var hasCaptionLabel = false
        if !mediaAttachments.isEmpty {
            let mediaHeight = MediaGridViewModel.calculateHeight(for: mediaAttachments, isEmbedded: false)
            if hasTextContent {
                bodyHeight += 4 // customSpacing(after: contentLabel) when text visible
            }
            bodyHeight += mediaHeight

            // Video caption for single-video tweets
            if mediaAttachments.count == 1 {
                let att = mediaAttachments[0]
                if att.type == .video || att.type == .hls_video {
                    let hasTitle = displayTweet.title != nil &&
                        !(displayTweet.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    let hasFileName = att.fileName != nil &&
                        !(att.fileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    if hasTitle || hasFileName {
                        bodyHeight += 2 // customSpacing(after: mediaContainerView)
                        bodyHeight += 17 // caption label height (14pt font, single line)
                        hasCaptionLabel = true
                    }
                }
            }
        }

        // Document attachments (PDFs, etc.) — hosted via SwiftUI DocumentAttachmentsView
        let documentAttachments = displayTweet.attachments?.filter { TweetBodyUIView.isDocumentType($0.type) } ?? []
        if !documentAttachments.isEmpty {
            let docCount = min(documentAttachments.count, 2) // maxDocuments: 2 in feed cells
            // Each DocumentRowView: ~32pt (14pt font + caption2 + vertical padding + background)
            // Outer VStack: 4pt padding top/bottom, 2pt spacing between rows
            let rowsHeight = CGFloat(docCount) * 32 + (docCount > 1 ? CGFloat(docCount - 1) * 2 : 0)
            let ellipsisHeight: CGFloat = documentAttachments.count > 2 ? 24 : 0
            let docHeight = rowsHeight + 8 + ellipsisHeight // 8pt = outer VStack padding (4+4)
            if hasTextContent || !mediaAttachments.isEmpty {
                bodyHeight += 8 // spacing before document container
            }
            bodyHeight += docHeight
        }

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
                //   bottomPadding = (hasMedia && !hasCaptionInBody) ? 0 : 8
                //
                // TweetBodyUIView (embedded) layout:
                //   2pt contentStack top
                //   contentLabel (if text) + 4pt spacing (to mediaContainer)
                //   mediaContainer (mediaH) + 2pt spacing (if caption visible) + caption(17)

                let embeddedMedia = embeddedTweet.attachments?.filter { TweetBodyUIView.isMediaType($0.type) } ?? []

                // Check for video caption in embedded tweet
                var hasEmbeddedCaption = false
                if embeddedMedia.count == 1 {
                    let att = embeddedMedia[0]
                    if att.type == .video || att.type == .hls_video {
                        let hasTitle = embeddedTweet.title != nil &&
                            !(embeddedTweet.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                        let hasFileName = att.fileName != nil &&
                            !(att.fileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                        hasEmbeddedCaption = hasTitle || hasFileName
                    }
                }

                // Calculate embedded bodyView height (matches TweetBodyUIView auto layout)
                var embeddedBodyH: CGFloat = 2 // contentStack top padding
                let hasEmbeddedText = embeddedTweet.content != nil &&
                    !(embeddedTweet.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

                if hasEmbeddedText {
                    let embeddedWidth = contentWidth - 16 - 40 - 8 // embedded padding + avatar + spacing
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
                    let textSize = Self.measurementLabel.sizeThatFits(CGSize(width: embeddedWidth, height: .greatestFiniteMagnitude))
                    embeddedBodyH += ceil(textSize.height)
                    embeddedBodyH += 4 // spacing after contentLabel to mediaContainer
                }

                if !embeddedMedia.isEmpty {
                    embeddedBodyH += MediaGridViewModel.calculateHeight(for: embeddedMedia, isEmbedded: true)
                    if hasEmbeddedCaption {
                        embeddedBodyH += 2 + 17 // spacing + caption label
                    }
                }

                // textStack = header + bodyView (same font as main header)
                let textStackH = headerHeight + embeddedBodyH
                let contentStackH = max(40, textStackH)

                // Bottom padding: 0 when media present without caption, 8 otherwise
                let hasMedia = !embeddedMedia.isEmpty
                let reduceBottom = hasMedia && !hasEmbeddedCaption
                let bottomPadding: CGFloat = reduceBottom ? 0 : 8

                let embeddedHeight: CGFloat = 8 + contentStackH + bottomPadding
                height += embeddedHeight
            } else {
                // Not loaded: show placeholder (60pt)
                height += 60
            }

            height += 10 // contentColumn.setCustomSpacing(10, after: embeddedTweetWrapper)
        }

        // Action bar (fixed 30pt)
        height += 30

        // Bottom padding (matches mainStack.bottomAnchor = separatorView.topAnchor - 16)
        height += 16

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

        // Use cached height if available (set by willDisplay from actual Auto Layout).
        if let cachedHeight = tweet.cachedHeight {
            return cachedHeight
        }

        // Use deterministic calculation instead of Auto Layout.
        // This matches estimatedHeightForRowAt's fallback, so estimate == actual → no scroll jumps.
        // The cell still uses Auto Layout internally for content positioning;
        // only the cell height is pre-determined.
        return Self.calculateTweetHeight(for: tweet)
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

        // Forward media visibility to the cell
        if let tweetCell = cell as? TweetTableViewCell {
            tweetCell.tweetContentView.setMediaVisible(true)
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
            let needsEmbeddedTweet = tweet.originalTweetId != nil
            let embeddedTweetLoaded = !needsEmbeddedTweet ||
                                     (Tweet.getInstance(for: tweet.originalTweetId!)?.author != nil)
            if embeddedTweetLoaded {
                // Sanity check: if the actual height is much smaller than expected,
                // the cell likely hasn't finished rendering (async content pending).
                // Don't cache — let Auto Layout re-determine on next display.
                let expectedHeight = Self.calculateTweetHeight(for: tweet)
                let isReasonable = cell.frame.height >= expectedHeight - 20

                if isReasonable {
                    tweet.cachedHeight = cell.frame.height
                    TweetHeightCache.shared.setHeight(cell.frame.height, for: tweet.mid)
                } else {
                    tweet.cachedHeight = nil
                    TweetHeightCache.shared.removeHeight(for: tweet.mid)
                }
            }
        }
    }

    override func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Forward media invisibility to the cell
        if let tweetCell = cell as? TweetTableViewCell {
            tweetCell.tweetContentView.setMediaVisible(false)
        }
    }

    // MARK: - UIScrollViewDelegate

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let currentOffset = scrollView.contentOffset.y
        let frameDelta = currentOffset - lastContentOffset
        lastContentOffset = currentOffset  // always update for frame-level tracking

        // Update scroll direction only during active user dragging
        if isUserDragging && abs(frameDelta) >= 2.0 {
            isScrollingBackward = frameDelta < 0
        }

        // Throttle video visibility updates (CACurrentMediaTime is cheaper than Date())
        let now = CACurrentMediaTime()

        // Update video visibility during all scroll phases (drag + deceleration).
        // Throttle limits frequency to avoid excessive work.
        if now - lastVideoVisibilityUpdate >= videoVisibilityThrottleInterval {
            lastVideoVisibilityUpdate = now
            updateVisibleTweetsForVideoPlayback()
        }

        // Detect bottom pull-to-load gesture (always check, even before initial layout)
        let contentHeight = scrollView.contentSize.height
        let scrollViewHeight = scrollView.frame.size.height
        let contentInsetBottom = scrollView.contentInset.bottom
        let bottomOffset = scrollView.contentOffset.y + scrollViewHeight - contentHeight + contentInsetBottom

        if tweets.count >= 4 && bottomOffset > bottomPullThreshold && !isLoadingMore && !isBottomPullActive {
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
            onScroll?(currentOffset, delta)
        } else {
            // Scrolling up → show bars immediately without animation.
            // Post notification so parent sets isNavigationVisible without withAnimation;
            // viewDidLayoutSubviews compensates contentOffset for the instant frame shift.
            showBarsWithoutAnimation()
        }

        lastCallbackOffset = currentOffset
        lastScrollCallbackTime = now
    }
    
    override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // User started dragging - reset callback baseline to current position
        // so accumulated delta starts fresh from the new drag gesture
        isUserDragging = true
        isDecelerating = false
        lastCallbackOffset = scrollView.contentOffset.y
    }

    override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // User lifted finger
        isUserDragging = false
        isDecelerating = decelerate

        // CRITICAL: Save scroll position immediately when user stops dragging
        // (if not decelerating, scroll has stopped - save now to survive app termination)
        if !decelerate {
            saveScrollPositionIfNeeded()
        }
    }

    override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        isDecelerating = false

        // Deceleration skipped video visibility updates — do one final update now
        updateVisibleTweetsForVideoPlayback()

        // CRITICAL: Save scroll position immediately when scroll momentum stops
        // This ensures position is persisted even if app is killed before viewWillDisappear
        saveScrollPositionIfNeeded()

        // If decelerated to near the top, show bars
        let topInset = scrollView.adjustedContentInset.top
        if scrollView.contentOffset.y <= -topInset + 10 {
            showBarsWithoutAnimation()
        }
    }

    /// Show bars immediately without animation.
    ///
    /// Posts `.showBarsAfterScrollEnd` so the parent view sets isNavigationVisible
    /// **without animation**.  The instant frame change is then compensated in
    /// `viewDidLayoutSubviews` so visible content stays at the same screen position.
    private func showBarsWithoutAnimation() {
        // Record baseline before the header expands
        isCompensatingForBarAppearance = true
        compensationBaseOriginY = view.convert(CGPoint.zero, to: nil).y

        NotificationCenter.default.post(name: .showBarsAfterScrollEnd, object: nil)

        // Safety timeout — stop compensating even if layout never fires
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.isCompensatingForBarAppearance = false
            self?.compensationBaseOriginY = nil
        }
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
        } else {
            // Clear position if at/near top
            savedScrollPosition = nil
            ScrollPositionManager.shared.clearScrollPosition(for: feedIdentifier)
        }
    }
    
    // MARK: - Height Estimation
    
    /// Preflight height estimates for new tweets to reduce initial layout jumps
    
    // MARK: - Video Playback Coordination
    
    private func updateVisibleTweetsForVideoPlayback() {
        guard !tweets.isEmpty || !pinnedTweets.isEmpty else { return }

        let visibleIndexPaths = tableView.indexPathsForVisibleRows ?? []

        // Calculate the actual user-visible rect, excluding areas behind translucent bars.
        // adjustedContentInset accounts for navigation bar, status bar, and toolbar.
        let insets = tableView.adjustedContentInset
        let visibleTop = tableView.contentOffset.y + insets.top
        let visibleBottom = tableView.contentOffset.y + tableView.bounds.height - insets.bottom
        let visibleRect = CGRect(x: 0, y: visibleTop, width: tableView.bounds.width, height: max(0, visibleBottom - visibleTop))

        // Only include tweets whose cells are at least 50% visible in the user-visible area.
        // This ensures videos stop/pause when scrolled mostly out of view, not only when
        // the cell fully leaves the screen (didEndDisplaying).
        let visibleTweetIds = Set(visibleIndexPaths.compactMap { indexPath -> String? in
            let totalRows = pinnedTweets.count + tweets.count
            guard indexPath.row < totalRows else { return nil }

            // Require ≥50% of cell height visible (was: any intersection)
            let cellRect = tableView.rectForRow(at: indexPath)
            let intersection = cellRect.intersection(visibleRect)
            let ratio = cellRect.height > 0 ? intersection.height / cellRect.height : 0
            guard ratio >= 0.5 else { return nil }

            // Determine which tweet this row represents
            if indexPath.row < pinnedTweets.count {
                return pinnedTweets[indexPath.row].mid
            } else {
                let regularIndex = indexPath.row - pinnedTweets.count
                guard regularIndex < tweets.count else { return nil }
                return tweets[regularIndex].mid
            }
        })

        // Forward visibility to cells based on the same 50% threshold.
        // MediaGridUIView and MediaCellUIView both guard against redundant state changes.
        for indexPath in visibleIndexPaths {
            guard let tweetCell = tableView.cellForRow(at: indexPath) as? TweetTableViewCell else { continue }
            let cellRect = tableView.rectForRow(at: indexPath)
            let intersection = cellRect.intersection(visibleRect)
            let ratio = cellRect.height > 0 ? intersection.height / cellRect.height : 0
            tweetCell.tweetContentView.setMediaVisible(ratio >= 0.5)
        }

        // Compute per-media-cell on-screen identifiers for fine-grained video switching.
        // This allows the coordinator to detect when a specific video cell within a
        // multi-video tweet scrolls off the viewport, even if the tweet cell is still visible.
        var onScreenVideoIds = Set<String>()
        for indexPath in visibleIndexPaths {
            guard let tweetCell = tableView.cellForRow(at: indexPath) as? TweetTableViewCell else { continue }
            let ids = tweetCell.tweetContentView.onScreenVideoIdentifiers(
                visibleRect: visibleRect, coordinateSpace: tableView
            )
            onScreenVideoIds.formUnion(ids)
        }
        if onScreenVideoIds != lastOnScreenVideoIds {
            lastOnScreenVideoIds = onScreenVideoIds
            videoCoordinator.updateOnScreenMediaCells(onScreenVideoIds)
        }

        // Only update coordinator if visible tweets actually changed
        // This prevents unnecessary video coordinator work during smooth scrolling
        if visibleTweetIds != lastVisibleTweetIds {
            lastVisibleTweetIds = visibleTweetIds
            videoCoordinator.updateVisibleTweets(visibleTweetIds)
        }

        // Compute preload zone: extend visible rows by a buffer for video preloading.
        // This uses spatial proximity (actual row neighbors) instead of index-based
        // adjacency in the allVideos array, which may skip many non-video tweets.
        if let firstVisible = visibleIndexPaths.first, let lastVisible = visibleIndexPaths.last {
            let totalRows = pinnedTweets.count + tweets.count
            let preloadBuffer = 5
            let preloadMin = max(0, firstVisible.row - preloadBuffer)
            let preloadMax = min(totalRows - 1, lastVisible.row + preloadBuffer)

            var preloadTweetIds = Set<String>()
            for row in preloadMin...preloadMax {
                // Skip rows already in the visible set
                if row >= firstVisible.row && row <= lastVisible.row { continue }
                if row < pinnedTweets.count {
                    preloadTweetIds.insert(pinnedTweets[row].mid)
                } else {
                    let regularIndex = row - pinnedTweets.count
                    if regularIndex < tweets.count {
                        preloadTweetIds.insert(tweets[regularIndex].mid)
                    }
                }
            }

            if preloadTweetIds != lastPreloadTweetIds {
                lastPreloadTweetIds = preloadTweetIds
                videoCoordinator.updateNearbyTweetsForPreloading(preloadTweetIds)
            }
        }
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
        if !hasMoreTweets && tweets.count > 0 {
            showNoMoreTweetsMessage()
        }
    }
    
    private func triggerBottomPullLoadMore() {
        guard !isLoadingMore else { return }

        // Check if there are no more tweets to load
        if !hasMoreTweets {
            // Show spinner first for exactly 500ms
            updateLoadingState(isLoadingMore: true, hasMoreTweets: false)

            // After 500ms, hide spinner (which will trigger message if conditions are met)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.updateLoadingState(isLoadingMore: false, hasMoreTweets: false)
                self.isBottomPullActive = false
            }
            return
        }

        updateLoadingState(isLoadingMore: true, hasMoreTweets: hasMoreTweets)
        
        // Call the load more callback with forceLoad=true to bypass hasMoreTweets check
        loadMoreTweets?(true)
        
        // Notify callback if registered
        onLoadMoreRequested?()
        
        // Reset flag after a delay to allow next pull
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.isBottomPullActive = false
        }
    }
    
    private func showNoMoreTweetsMessage() {
        guard !isShowingNoMoreTweetsMessage else { return }

        isShowingNoMoreTweetsMessage = true
        lastNoMoreTweetsShownTime = Date()
        noMoreTweetsMessageTimer?.invalidate()

        let footerView = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 120))
        footerView.backgroundColor = .clear

        let messageLabel = UILabel()
        messageLabel.text = NSLocalizedString("No more tweets", comment: "Message shown when there are no more tweets to load")
        messageLabel.textAlignment = .center
        messageLabel.font = .systemFont(ofSize: 15, weight: .medium)
        messageLabel.textColor = .secondaryLabel
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

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
                    if self.isLoadingMore && self.hasMoreTweets {
                        self.updateLoadingState(isLoadingMore: self.isLoadingMore, hasMoreTweets: self.hasMoreTweets)
                    }
                }
            }
        }
    }
}

// MARK: - Prefetching (Performance Optimization)
extension TweetTableViewController: UITableViewDataSourcePrefetching {
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        // PERFORMANCE: Prefetch limited cells ahead (max 3) to prevent height jumps
        // Synchronous execution ensures embedded tweets are loaded before cells display
        let limitedPrefetch = Array(indexPaths.prefix(3))

        // CRITICAL: Prefetch synchronously on main thread to ensure embedded tweets are loaded
        // BEFORE cells are displayed. This prevents height jumps from late-loading embedded tweets.
        // The cache fetch is fast (in-memory), so this won't block scrolling.
        for indexPath in limitedPrefetch {
            let totalRows = self.pinnedTweets.count + self.tweets.count
            guard indexPath.row < totalRows else { continue }

            let tweet: Tweet
            if indexPath.row < self.pinnedTweets.count {
                tweet = self.pinnedTweets[indexPath.row]
            } else {
                let regularIndex = indexPath.row - self.pinnedTweets.count
                guard regularIndex < self.tweets.count else { continue }
                tweet = self.tweets[regularIndex]
            }

            // Prefetch embedded tweet data if present
            // SYNCHRONOUS load ensures it's available before cell is displayed
            if let originalTweetId = tweet.originalTweetId {
                if let cachedEmbeddedTweet = TweetCacheManager.shared.fetchTweetSync(mid: originalTweetId) {
                    // Warm up the singleton immediately (already on main thread)
                    _ = Tweet.getInstance(
                        mid: cachedEmbeddedTweet.mid,
                        authorId: cachedEmbeddedTweet.authorId,
                        content: cachedEmbeddedTweet.content,
                        timestamp: cachedEmbeddedTweet.timestamp,
                        title: cachedEmbeddedTweet.title,
                        originalTweetId: cachedEmbeddedTweet.originalTweetId,
                        originalAuthorId: cachedEmbeddedTweet.originalAuthorId,
                        author: cachedEmbeddedTweet.author,
                        favorites: cachedEmbeddedTweet.favorites,
                        favoriteCount: cachedEmbeddedTweet.favoriteCount ?? 0,
                        bookmarkCount: cachedEmbeddedTweet.bookmarkCount ?? 0,
                        retweetCount: cachedEmbeddedTweet.retweetCount ?? 0,
                        commentCount: cachedEmbeddedTweet.commentCount ?? 0,
                        attachments: cachedEmbeddedTweet.attachments,
                        isPrivate: cachedEmbeddedTweet.isPrivate,
                        downloadable: cachedEmbeddedTweet.downloadable
                    )
                }
            }
        }
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        // No action needed - prefetch is lightweight synchronous work
    }
}
