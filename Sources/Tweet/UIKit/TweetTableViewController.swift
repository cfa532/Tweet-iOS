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
    
    // Bottom pull-to-load state (manual pull past bottom edge)
    private var isBottomPullActive: Bool = false
    private var bottomPullThreshold: CGFloat = 50
    
    // Spinner timing
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
    private var lastLoadVisibleVideoIds: Set<String> = [] // Cache media that is physically on screen and should load
    private var lastContinuePlaybackVideoIds: Set<String> = [] // Cache media visible enough to keep current playback
    private var lastOnScreenVideoIds: Set<String> = [] // Cache per-cell on-screen video identifiers
    
    // Cached main content rect to avoid recalculating on every visibility check
    private var cachedMainContentRect: CGRect?
    private var lastContentOffset: CGFloat = 0
    private var lastCallbackOffset: CGFloat = 0  // Only updated when onScroll fires — gives accumulated delta
    private var isCompensatingForBarAppearance: Bool = false  // Compensate contentOffset when header expands
    private var compensationBaseOriginY: CGFloat?
    private var lastHeaderHeight: CGFloat = 0
    private var lastHeaderLayoutWidth: CGFloat = 0
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
    private let directionalPreloadRowCount = 2
    private let oppositeStopPreloadRowCount = 1
    private let maxDirectionalImagePreloadsInFlight = 4
    private var activeDirectionalImagePreloadTasks: [String: Task<Void, Never>] = [:]
    private var didScheduleInitialVisibilityRefresh = false

    // Scroll state tracking to prevent direction detection jitter during deceleration
    private var isUserDragging: Bool = false
    private var isDecelerating: Bool = false
    private var isTableViewUpdating: Bool = false
    private var pendingHeightRelayoutTweetIds = Set<String>()
    /// Tweet IDs whose content is currently expanded by the user ("More..." tapped).
    /// `heightForRowAt` returns `automaticDimension` for these so the table re-measures
    /// the cell at full expanded height instead of using the cached truncated height.
    private var expandedTweetIds = Set<String>()
    private var embeddedTweetPrefetchInFlight = Set<String>()

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
        embeddedTweetPrefetchInFlight.removeAll()
        cancelDirectionalImagePreloads()

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
        ) { [weak self] notification in
            guard let self = self else { return }

            // Only process if this notification targets our feed
            if let feedId = notification.userInfo?["feedIdentifier"] as? String,
               feedId != self.feedIdentifier {
                return
            }

            // When the same video was playing on the profile we left, main feed and profile share
            // one AVPlayer (SharedAssetCache). The profile's SimpleVideoPlayer.onDisappear runs
            // during teardown and calls player.pause() on that shared instance. If we send our
            // resume-play command before the profile has torn down, the profile's onDisappear
            // can run afterward and pause the player again. Delay so teardown completes first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self else { return }
                Task { @MainActor in
                    print("📺 [VIDEO RESTART] Feed '\(self.feedIdentifier)' view appeared - resuming video playback")
                    if self.videoCoordinator.primaryVideoId != nil {
                        // A primary is already playing (overlay handler or viewWillAppear handled it).
                        // Don't force a full re-evaluation — that can override the correct selection
                        // with a stalling video. Just re-send the play command to the current primary.
                        self.videoCoordinator.requestResumePrimaryPlaybackIfVisible()
                    } else {
                        // No primary playing — full re-evaluation needed (e.g. returning from tab switch
                        // where viewWillDisappear called stopAllVideos).
                        self.lastVisibleTweetIds = []
                        self.lastLoadVisibleVideoIds = []
                        self.lastContinuePlaybackVideoIds = []
                        self.lastOnScreenVideoIds = []
                        self.updateVisibleTweetsForVideoPlayback()
                        self.videoCoordinator.requestResumePrimaryPlaybackIfVisible()
                    }
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
            if let self, self.tableView.window != nil, let visibleIndexPaths = self.tableView.indexPathsForVisibleRows {
                self.isTableViewUpdating = true
                self.tableView.reloadRows(at: visibleIndexPaths, with: .none)
                self.isTableViewUpdating = false
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
            guard self.videoCoordinator.isFeedVisible else { return }

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

            // Directional image preloads are useful only while actively scrolling the feed.
            // AppDelegate/MemoryCapManager clears global media caches on background; cancel
            // these direct warmup tasks here so they do not keep network work alive.
            self.cancelDirectionalImagePreloads()

            // Show cached thumbnails on visible video cells before AppDelegate releases video memory.
            // This prevents black AVPlayerLayer in the app switcher snapshot.
            if !self.isTableViewUpdating {
                for cell in self.tableView.visibleCells {
                    guard let tweetCell = cell as? TweetTableViewCell else { continue }
                    tweetCell.tweetContentView.showVideoThumbnailsForBackground()
                }
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
            guard self.videoCoordinator.isFeedVisible else { return }

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
            guard let self = self, self.needsVideoLayerRefresh, !self.isTableViewUpdating else { return }
            guard self.videoCoordinator.isFeedVisible else { return }
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

        // Step 2: Recompute full viewport media geometry, not just tweet rows.
        // Autoplay is driven by media-cell visibility; using tweet IDs alone can
        // leave visibleVideos stale after foreground/detail transitions.
        lastVisibleTweetIds = []
        lastLoadVisibleVideoIds = []
        lastContinuePlaybackVideoIds = []
        lastOnScreenVideoIds = []
        updateVisibleTweetsForVideoPlayback()

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

        if needsHeaderUpdate {
            updateHeader()
        }

        videoCoordinator.isFeedVisible = true

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
                // Overlay dismiss timer will handle resume — don't compete
                guard !self.videoCoordinator.isOverlayDismissPending else { return }
                if self.videoCoordinator.primaryVideoId != nil {
                    // Overlay handler already picked a primary — just re-send play command.
                    self.videoCoordinator.requestResumePrimaryPlaybackIfVisible()
                } else {
                    self.lastVisibleTweetIds = []
                    self.lastLoadVisibleVideoIds = []
                    self.lastContinuePlaybackVideoIds = []
                    self.lastOnScreenVideoIds = []
                    self.updateVisibleTweetsForVideoPlayback()
                    self.videoCoordinator.requestResumePrimaryPlaybackIfVisible()
                }
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

        if needsFooterUpdate {
            needsFooterUpdate = false
            updateLoadingState(isLoadingMore: isLoadingMore, hasMoreTweets: hasMoreTweets)
        }

        scheduleVideoVisibilityRefresh(reason: "viewDidAppear")
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        videoCoordinator.isFeedVisible = false

        // Stop all feed videos when navigating away (detail view push, profile tap, etc.).
        // Without this the feed keeps active AVPlayer XPC sessions alive while the destination
        // view tries to open its own, hitting the system's concurrent-player limit and causing
        // PlayerRemoteXPC -12860 errors that prevent the destination video from playing.
        // Playback is restored by the .feedViewDidAppear handler when the feed becomes visible again.
        videoCoordinator.stopAllVideos()
        cancelDirectionalImagePreloads()

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
            let hasSavedPosition = savedScrollPosition != nil || ScrollPositionManager.shared.getScrollPosition(for: feedIdentifier) != nil
            if currentOffset < -topInset && !hasSavedPosition {
                tableView.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false)
                lastScrollOffset = -topInset
            }
        }

        if headerViewBuilder != nil,
           tableView.window != nil,
           abs(tableView.bounds.width - lastHeaderLayoutWidth) > 1 {
            updateHeader()
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
            _ = await TweetCacheManager.shared.fetchTweet(mid: originalTweetId)
            self?.embeddedTweetPrefetchInFlight.remove(originalTweetId)
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
        let oldCount = pinnedTweets.count
        let oldPinnedTweets = pinnedTweets
        let oldOriginalTweetIds = Set(oldPinnedTweets.compactMap(\.originalTweetId))
        self.pinnedTweets = tweets

        guard tableView.window != nil else { return }

        let newOriginalTweetIds = Set(tweets.compactMap(\.originalTweetId))
        prefetchEmbeddedTweetIdsIfNeeded(newOriginalTweetIds.subtracting(oldOriginalTweetIds))

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
                scheduleVideoVisibilityRefresh(reason: "pinnedTweetsSameOrder")
                return
            }
        }

        // Reload table to reflect new pinned tweets
        isTableViewUpdating = true
        if oldCount != tweets.count {
            // Number of rows changed, do a full reload
            tableView.reloadData()
        } else if oldCount > 0 {
            // Different tweets in same positions, update the content
            let indexPaths = (0..<oldCount).map { IndexPath(row: $0, section: 0) }
            tableView.reloadRows(at: indexPaths, with: .none)
        }
        isTableViewUpdating = false

        // CRITICAL: Update visibility after reload so coordinator knows pinned videos are visible
        scheduleVideoVisibilityRefresh(reason: "pinnedTweetsReload")
    }
    
    func updateTweets(_ newTweets: [Tweet]) {
        let oldCount = tweets.count
        let oldTweets = tweets
        tweets = newTweets

        // Skip all UIKit table operations if the view is not in the window hierarchy.
        // This can happen when a pending SwiftUI update fires after navigation has already
        // popped this view (e.g. immediately after logout). Updating a detached table view
        // causes UITableView row-count assertion failures.
        guard tableView.window != nil else { return }

        // Cleanup old tweet instances to prevent memory growth
        Task.detached(priority: .background) {
            let activeTweetIds = Set(newTweets.map { $0.mid })
            Tweet.cleanupOldInstances(activeTweetIds: activeTweetIds)
        }

        let newOriginalTweetIds = Set(newTweets.compactMap(\.originalTweetId))
        
        
        // Handle initial load
        if oldCount == 0 && newTweets.count > 0 {
            prefetchEmbeddedTweetIdsIfNeeded(newOriginalTweetIds)
            isTableViewUpdating = true
            tableView.reloadData()
            isTableViewUpdating = false
            videoCoordinator.buildVideoList(from: newTweets, pinnedTweets: pinnedTweets)
            
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
                // OPTIMIZATION: Same tweets in same order - only hit counts changed
                // Tweet.getInstance() already updated the @Published count properties
                // SwiftUI will automatically re-render action buttons, no need to reload cells
                videoCoordinator.buildVideoList(from: newTweets, pinnedTweets: pinnedTweets)
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
                isTableViewUpdating = true
                let indexPaths = (0..<potentialPrependCount).map { IndexPath(row: $0, section: 0) }
                tableView.insertRows(at: indexPaths, with: .automatic)
                isTableViewUpdating = false
                videoCoordinator.buildVideoList(from: newTweets, pinnedTweets: pinnedTweets)
                scheduleVideoVisibilityRefresh(reason: "tweetsPrepended")
                return
            }
        }
        
        // Case 2: Tweets appended (pagination) - common for load more
        if newTweets.count > oldCount {
            let newIdsPrefix = Array(getNewIds().prefix(oldCount))
            
            if newIdsPrefix == getOldIds() {
                isTableViewUpdating = true
                let indexPaths = (oldCount..<newTweets.count).map { IndexPath(row: $0, section: 0) }
                tableView.insertRows(at: indexPaths, with: .none)
                isTableViewUpdating = false
                videoCoordinator.buildVideoList(from: newTweets, pinnedTweets: pinnedTweets)
                scheduleVideoVisibilityRefresh(reason: "tweetsAppended")
                return
            }
        }

        // Case 3: Single tweet removed - common for delete
        // OPTIMIZED: Use Set for O(1) lookup instead of O(n)
        if newTweets.count == oldCount - 1 {
            let newIdsSet = Set(getNewIds())
            if let removedIndex = getOldIds().firstIndex(where: { !newIdsSet.contains($0) }) {
                isTableViewUpdating = true
                tableView.deleteRows(at: [IndexPath(row: removedIndex, section: 0)], with: .automatic)
                isTableViewUpdating = false
                videoCoordinator.buildVideoList(from: newTweets, pinnedTweets: pinnedTweets)
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
            videoCoordinator.buildVideoList(from: newTweets, pinnedTweets: pinnedTweets)
            scheduleVideoVisibilityRefresh(reason: "emptyDiff")
            return
        }

        isTableViewUpdating = true
        tableView.performBatchUpdates {
            for change in diff {
                switch change {
                case .remove(let offset, _, _):
                    tableView.deleteRows(at: [IndexPath(row: offset, section: 0)], with: .none)
                case .insert(let offset, _, _):
                    tableView.insertRows(at: [IndexPath(row: offset, section: 0)], with: .none)
                }
            }
        }
        isTableViewUpdating = false
        videoCoordinator.buildVideoList(from: newTweets, pinnedTweets: pinnedTweets)
        scheduleVideoVisibilityRefresh(reason: "diffUpdate")
    }
    
    private var needsHeaderUpdate = false

    func updateHeader() {
        // Defer header layout until the view is in the hierarchy to avoid
        // "UITableView layout outside view hierarchy" warnings.
        guard viewIfLoaded?.window != nil else {
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
            
            // Recalculate size with frame-based layout
            if let headerView = headerHostingController?.view, let containerView = tableView.tableHeaderView {
                let tableWidth = max(tableView.bounds.width, 100)
                lastHeaderLayoutWidth = tableWidth
                let contentWidth = tableWidth - (leadingPadding + trailingPadding)
                
                // Set fixed width before calculating height
                headerView.frame.size.width = contentWidth
                headerView.setNeedsLayout()
                headerView.layoutIfNeeded()
                
                let targetSize = CGSize(width: contentWidth, height: UIView.layoutFittingExpandedSize.height)
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

        guard stateChanged || needsFooterUpdate else { return }
        
        // ✅ FIX: Only log state changes, and avoid logging Date() or complex objects
        // Excessive logging can cause Xcode console to stop showing logs (FontServicesDaemonManager error)
        if stateChanged {
        }

        guard tableView.window != nil else {
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

        guard tableView.window != nil else {
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

        if let originalTweetId = tweet.originalTweetId {
            prefetchEmbeddedTweetIfNeeded(originalTweetId: originalTweetId)
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

        // Content expansion callback — fires when user taps "More..." to expand truncated text.
        // expandedTweetIds makes heightForRowAt return automaticDimension so the table
        // re-measures the cell at expanded height instead of using the cached truncated value.
        cell.onContentExpanded = { [weak self, weak cell] in
            guard let self, let cell,
                  let indexPath = self.tableView.indexPath(for: cell) else { return }
            let tweet: Tweet
            if indexPath.row < self.pinnedTweets.count {
                tweet = self.pinnedTweets[indexPath.row]
            } else {
                let idx = indexPath.row - self.pinnedTweets.count
                guard idx < self.tweets.count else { return }
                tweet = self.tweets[idx]
            }

            self.expandedTweetIds.insert(tweet.mid)
            tweet.cachedHeight = nil

            let expectedCount = self.pinnedTweets.count + self.tweets.count
            let currentCount = self.tableView.numberOfRows(inSection: 0)
            if expectedCount == currentCount {
                UIView.performWithoutAnimation {
                    self.isTableViewUpdating = true
                    self.tableView.beginUpdates()
                    self.tableView.endUpdates()
                    self.isTableViewUpdating = false
                }
            }
        }

        // Height change callback for embedded tweets that load asynchronously
        // When the embedded tweet loads, the cell expands and the table must re-layout
        cell.onHeightChanged = { [weak self, weak cell] desiredHeight in
            guard let self, let cell,
                  let indexPath = self.tableView.indexPath(for: cell) else { return }
            // Use Auto Layout's fitting height directly. calculateTweetHeight is a
            // manual estimate that can disagree with the cell's actual content
            // (esp. when an embedded tweet finishes loading after first render).
            let tweet: Tweet
            if indexPath.row < self.pinnedTweets.count {
                tweet = self.pinnedTweets[indexPath.row]
            } else {
                let idx = indexPath.row - self.pinnedTweets.count
                guard idx < self.tweets.count else { return }
                tweet = self.tweets[idx]
            }
            tweet.cachedHeight = desiredHeight
            TweetHeightCache.shared.setHeight(desiredHeight, for: tweet.mid)

            if self.isUserDragging || self.isDecelerating {
                self.pendingHeightRelayoutTweetIds.insert(tweet.mid)
            } else {
                self.performPendingHeightRelayout(include: tweet.mid)
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
                    // fileName caption only shown when tweet has no text (matches singleVideoCaption)
                    if hasTitle || (hasFileName && !hasTextContent) {
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

                // Must be computed before hasEmbeddedCaption (fileName caption depends on it)
                let hasEmbeddedText = embeddedTweet.content != nil &&
                    !(embeddedTweet.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

                // Check for video caption in embedded tweet
                // fileName caption only shown when embedded tweet has no text (matches singleVideoCaption)
                var hasEmbeddedCaption = false
                if embeddedMedia.count == 1 {
                    let att = embeddedMedia[0]
                    if att.type == .video || att.type == .hls_video {
                        let hasTitle = embeddedTweet.title != nil &&
                            !(embeddedTweet.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                        let hasFileName = att.fileName != nil &&
                            !(att.fileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                        hasEmbeddedCaption = hasTitle || (hasFileName && !hasEmbeddedText)
                    }
                }

                // Calculate embedded bodyView height (matches TweetBodyUIView auto layout)
                var embeddedBodyH: CGFloat = 2 // contentStack top padding

                if hasEmbeddedText {
                    // bodyView spans full EmbeddedTweetUIView contentStack width (NOT beside avatar)
                    // contentStack.width = screenWidth - 77 = contentWidth - 12
                    let embeddedWidth = contentWidth - 12
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
                }

                if !embeddedMedia.isEmpty {
                    if hasEmbeddedText {
                        embeddedBodyH += 4 // customSpacing(after: contentLabel) only when text+media both present
                    }
                    embeddedBodyH += MediaGridViewModel.calculateHeight(for: embeddedMedia, isEmbedded: true)
                    if hasEmbeddedCaption {
                        embeddedBodyH += 2 + 17 // spacing + caption label
                    }
                }

                // EmbeddedTweetUIView.contentStack (spacing=4):
                //   headerRow height = max(32pt avatar, ~21pt header text) = 32pt
                //   bodyView height = embeddedBodyH
                // Total: 32 + 4 + embeddedBodyH = 36 + embeddedBodyH
                // Bottom padding: 0 when media present without caption, 8 otherwise
                let hasMedia = !embeddedMedia.isEmpty
                let reduceBottom = hasMedia && !hasEmbeddedCaption
                let bottomPadding: CGFloat = reduceBottom ? 0 : 8

                let embeddedHeight: CGFloat = 8 + 36 + embeddedBodyH + bottomPadding
                height += embeddedHeight
            } else {
                // Not loaded: show placeholder (60pt)
                height += 60
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
            tweet.cachedHeight = nil
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

        // Directional image warmup is done at scroll stop. Starting network work
        // during active dragging/deceleration competes with visible media and video.

        // Auto-load next page when scrolling near the bottom
        let contentHeight = scrollView.contentSize.height
        let scrollViewHeight = scrollView.frame.size.height
        let distanceFromBottom = contentHeight - scrollView.contentOffset.y - scrollViewHeight
        let contentInsetBottom = scrollView.contentInset.bottom
        let bottomOffset = scrollView.contentOffset.y + scrollViewHeight - contentHeight + contentInsetBottom

        // Auto-load: trigger when within 2 screen heights of the bottom (only if more tweets exist)
        if tweets.count >= 4 && hasMoreTweets && distanceFromBottom < scrollViewHeight * 2 && !isLoadingMore {
            triggerBottomPullLoadMore()
        }

        // Manual pull-to-load: user pulled past the bottom edge (works even when hasMoreTweets is false)
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
        // Start 2s grace period — preloads cancelled if scroll still active after 2s
        videoCoordinator.onScrollStarted()
    }

    override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // User lifted finger
        isUserDragging = false
        isDecelerating = decelerate

        // CRITICAL: Save scroll position immediately when user stops dragging
        // (if not decelerating, scroll has stopped - save now to survive app termination)
        if !decelerate {
            performPendingHeightRelayout()
            saveScrollPositionIfNeeded()
            triggerPreloadOnScrollStop()
        }
    }

    override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        isDecelerating = false

        // Deceleration skipped video visibility updates — do one final update now
        updateVisibleTweetsForVideoPlayback()
        performPendingHeightRelayout()

        triggerPreloadOnScrollStop()

        // CRITICAL: Save scroll position immediately when scroll momentum stops
        // This ensures position is persisted even if app is killed before viewWillDisappear
        saveScrollPositionIfNeeded()

        // If decelerated to near the top, show bars
        let topInset = scrollView.adjustedContentInset.top
        if scrollView.contentOffset.y <= -topInset + 10 {
            showBarsWithoutAnimation()
        }
    }

    private func performPendingHeightRelayout(include tweetId: String? = nil) {
        if let tweetId {
            pendingHeightRelayoutTweetIds.insert(tweetId)
        }
        guard !pendingHeightRelayoutTweetIds.isEmpty else { return }

        let expectedCount = pinnedTweets.count + tweets.count
        let currentCount = tableView.numberOfRows(inSection: 0)
        guard expectedCount == currentCount else { return }

        pendingHeightRelayoutTweetIds.removeAll()
        UIView.performWithoutAnimation {
            isTableViewUpdating = true
            tableView.beginUpdates()
            tableView.endUpdates()
            isTableViewUpdating = false
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
        preloadImagesForRows(preloadRows + oppositeRows)

        videoCoordinator.performPreloadOnScrollStop()
    }

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

    private func preloadImagesForRows(_ rows: [Int]) {
        var targetImageIds = Set<String>()
        var cachedTargetImageIds = Set<String>()
        var candidates: [(attachment: MimeiFileType, url: URL)] = []
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
                          !BlackList.shared.isBlacklisted(MimeiId(attachment.mid)),
                          let baseUrl = resolvedMediaBaseUrl(for: source),
                          let url = attachment.getUrl(baseUrl) else {
                        continue
                    }

                    candidateIds.insert(attachment.mid)
                    candidates.append((attachment, url))
                }
            }
        }

        let activeImageIds = Set(activeDirectionalImagePreloadTasks.keys)
        let staleImageIds = activeImageIds
            .subtracting(targetImageIds)
            .union(activeImageIds.intersection(visibleImageIds))
            .union(activeImageIds.intersection(cachedTargetImageIds))
        for imageId in staleImageIds {
            activeDirectionalImagePreloadTasks[imageId]?.cancel()
            activeDirectionalImagePreloadTasks.removeValue(forKey: imageId)
        }

        var availableSlots = max(0, maxDirectionalImagePreloadsInFlight - activeDirectionalImagePreloadTasks.count)
        guard availableSlots > 0 else { return }

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
        } else {
            // Clear position if at/near top
            savedScrollPosition = nil
            ScrollPositionManager.shared.clearScrollPosition(for: feedIdentifier)
        }
    }
    
    // MARK: - Height Estimation
    
    /// Preflight height estimates for new tweets to reduce initial layout jumps
    
    // MARK: - Video Playback Coordination

    private func scheduleVideoVisibilityRefresh(reason _: String) {
        let delays: [TimeInterval] = [0, 0.1, 0.35, 0.8]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.tableView.window != nil else { return }
                self.forceLayoutVisibleCellsForVisibilityPass()
                self.updateVisibleTweetsForVideoPlayback()
            }
        }
    }

    private func forceLayoutVisibleCellsForVisibilityPass() {
        tableView.layoutIfNeeded()
        for cell in tableView.visibleCells {
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
            cell.contentView.setNeedsLayout()
            cell.contentView.layoutIfNeeded()
        }
    }
    
    private func updateVisibleTweetsForVideoPlayback() {
        guard tableView.window != nil else { return }
        guard !isTableViewUpdating else { return }
        guard !tweets.isEmpty || !pinnedTweets.isEmpty else { return }

        let visibleIndexPaths = tableView.indexPathsForVisibleRows ?? []

        // Calculate the actual user-visible rect, excluding areas behind translucent bars.
        // adjustedContentInset accounts for navigation bar, status bar, and toolbar.
        let insets = tableView.adjustedContentInset
        let visibleTop = tableView.contentOffset.y + insets.top
        let visibleBottom = tableView.contentOffset.y + tableView.bounds.height - insets.bottom
        let visibleRect = CGRect(x: 0, y: visibleTop, width: tableView.bounds.width, height: max(0, visibleBottom - visibleTop))

        // Single pass over visible cells: compute tweet visibility, toggle media visibility,
        // and gather load-visible/playable video IDs together so scrolling does less repeated work.
        var visibleTweetIds = Set<String>()
        var loadVisibleVideoIds = Set<String>()
        var continuePlaybackVideoIds = Set<String>()
        var onScreenVideoIds = Set<String>()
        for indexPath in visibleIndexPaths {
            guard let tweetCell = tableView.cellForRow(at: indexPath) as? TweetTableViewCell else { continue }

            let cellRect = tableView.rectForRow(at: indexPath)
            let intersection = cellRect.intersection(visibleRect)
            let ratio = cellRect.height > 0 ? intersection.height / cellRect.height : 0
            let isRowOnScreen = intersection.height > 0
            let isTweetVisible = ratio >= 0.5

            // Any media that is physically on screen should load. Autoplay still
            // uses the stricter 50% media-cell threshold returned as `playable`.
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
        if !hasMoreTweets && tweets.count > 0 {
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

        updateLoadingState(isLoadingMore: true, hasMoreTweets: hasMoreTweets)

        // Call the load more callback with forceLoad=true to bypass hasMoreTweets check
        loadMoreTweets?(true)

        // Notify callback if registered
        onLoadMoreRequested?()

        // Reset manual pull flag after a delay to allow next pull
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.isBottomPullActive = false
        }
    }
    
    private func showNoMoreTweetsMessage() {
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
