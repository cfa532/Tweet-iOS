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

/// Persistent storage for scroll positions across view controller deallocation
@MainActor
class ScrollPositionManager {
    static let shared = ScrollPositionManager()
    private var scrollPositions: [String: CGFloat] = [:]
    
    private init() {}
    
    func saveScrollPosition(_ position: CGFloat, for identifier: String) {
        scrollPositions[identifier] = position
    }
    
    func getScrollPosition(for identifier: String) -> CGFloat? {
        return scrollPositions[identifier]
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
    var rowViewBuilder: ((Tweet) -> AnyView)?
    var headerViewBuilder: (() -> AnyView)?
    var onScroll: ((CGFloat, CGFloat) -> Void)?  // (offset, delta)
    var leadingPadding: CGFloat = 8  // Configurable leading padding for cells
    var trailingPadding: CGFloat = 8  // Configurable trailing padding for cells
    
    // Header hosting controller
    private var headerHostingController: UIHostingController<AnyView>?
    
    // Refresh control
    private var customRefreshControl: UIRefreshControl?
    
    // Video playback coordinator
    private let videoCoordinator = VideoPlaybackCoordinator.shared
    
    // Scroll tracking for toolbar hiding
    private var lastScrollOffset: CGFloat = 0
    private var hasCompletedInitialLayout: Bool = false
    private var hasAdjustedInitialPosition: Bool = false
    private var lastScrollCallbackTime: Date?
    private let scrollCallbackThrottleInterval: TimeInterval = 0.1 // 100ms throttle for scroll callbacks
    
    // Height cache for layout stability (prevents jumps when cells with videos load)
    // Throttling for video visibility updates (avoid expensive checks on every scroll frame)
    private var lastVideoVisibilityUpdate: Date?
    private let videoVisibilityThrottleInterval: TimeInterval = 0.1 // 100ms - faster video starts
    private var lastVisibleTweetIds: Set<String> = [] // Cache last visible tweet IDs
    
    // Cached main content rect to avoid recalculating on every visibility check
    private var cachedMainContentRect: CGRect?
    private var lastContentOffset: CGFloat = 0
    private var lastHeaderHeight: CGFloat = 0
    private var lastFooterHeight: CGFloat = 0
    
    // Notification observer for scroll to top
    private var scrollToTopObserver: NSObjectProtocol?

    // Foreground/background observer to prevent white space issue
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var scrollPositionBeforeBackground: CGFloat?

    // Observer for feed view appearance (to restart video playback after navigation)
    private var feedViewDidAppearObserver: NSObjectProtocol?

    // Scroll position preservation
    private var savedScrollPosition: CGFloat?
    private var isScrollingToTop: Bool = false
    
    // Feed identifier for persistent scroll position storage
    var feedIdentifier: String = "mainFeed"  // Default to main feed
    
    // Counter for periodic cache cleanup during scrolling
    private var scrollUpdateCount: Int = 0

    // Track scroll direction for height caching strategy
    private var isScrollingBackward: Bool = false

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

        if let observer = feedViewDidAppearObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        // Clean up timers
        noMoreTweetsMessageTimer?.invalidate()
        loadingTimeoutTimer?.invalidate()

        // MEMORY FIX: Clear view cache to free memory
        SwiftUIViewCache.shared.clearCache()

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
        ) { [weak self] _ in
            self?.scrollToTop()
        }
    }

    /// Setup observer for feed view appearance to restart video playback after navigation
    private func setupFeedViewDidAppearObserver() {
        feedViewDidAppearObserver = NotificationCenter.default.addObserver(
            forName: .feedViewDidAppear,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // Only restart if this is the main feed (not profile's tweet list)
            guard self.feedIdentifier == "mainFeed" else { return }

            Task { @MainActor in
                print("📺 [VIDEO RESTART] Main feed view appeared - rebuilding video list")

                // Reset cached visible tweet IDs so updateVisibleTweetsForVideoPlayback will call coordinator
                self.lastVisibleTweetIds = []

                // CRITICAL: Rebuild video list with main feed's tweets
                // Profile view overwrites the coordinator's allVideos list, so we must rebuild it
                // Use completion handler to update visible tweets AFTER video list is rebuilt
                // NOTE: Don't call stopAllVideos() here - it causes flickering. Let the visibility
                // tracking in updateVisibleTweetsForVideoPlayback handle stopping/starting videos.
                print("📺 [VIDEO RESTART] Rebuilding video list with \(self.tweets.count) tweets and \(self.pinnedTweets.count) pinned tweets")
                self.videoCoordinator.buildVideoList(from: self.tweets, pinnedTweets: self.pinnedTweets) { [weak self] in
                    guard let self = self else { return }
                    // Now allVideos contains main feed's videos
                    // Update visibleTweetIds with main feed's visible tweets
                    print("📺 [VIDEO RESTART] Video list rebuilt, updating visible tweets")
                    self.updateVisibleTweetsForVideoPlayback()
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
            print("⚠️ [MEMORY] Memory warning received - clearing caches")
            
            // Clear SwiftUI view cache
            SwiftUIViewCache.shared.clearCache()
            
            // Stop all videos and clear coordinator caches via notification
            NotificationCenter.default.post(name: .shouldStopAllVideos, object: nil)
            
            // Force reload visible cells to free up old hosting controllers
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
            let memoryBefore = self.getMemoryUsage()
            print("🌙 [BACKGROUND] App entering background - starting aggressive memory cleanup")
            print("📊 [MEMORY] Before cleanup: \(memoryBefore)MB")

            // Save the current scroll position before backgrounding
            self.scrollPositionBeforeBackground = self.tableView.contentOffset.y
            print("📍 [SCROLL] Saved scroll position: \(self.scrollPositionBeforeBackground ?? 0)")

            // AGGRESSIVE MEMORY CLEANUP
            // 1. Release all video players to free memory
            Task { @MainActor in
                self.videoCoordinator.releaseAllPlayersForBackground()
            }

            // 2. Clear SwiftUI view cache
            SwiftUIViewCache.shared.clearCache()

            // 3. Force table view to release non-visible cells
            self.tableView.reloadData()

            // 4. Clear any cached images if you have an image cache
            // URLCache.shared.removeAllCachedResponses()  // Uncomment if using URL caching

            // Log memory after cleanup and end background task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                let memoryAfter = self.getMemoryUsage()
                let memoryFreed = memoryBefore - memoryAfter
                print("✅ [BACKGROUND] Cleanup complete")
                print("📊 [MEMORY] After cleanup: \(memoryAfter)MB (freed: \(memoryFreed)MB)")

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

            // Log current memory
            let memoryNow = self.getMemoryUsage()
            print("📊 [MEMORY] Current: \(memoryNow)MB")

            guard let savedPosition = self.scrollPositionBeforeBackground else { return }

            print("📍 [SCROLL] Restoring scroll position: \(savedPosition)")

            // Restore the scroll position after a brief delay to let layout settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self else { return }
                self.tableView.setContentOffset(CGPoint(x: 0, y: savedPosition), animated: false)
                self.scrollPositionBeforeBackground = nil

                // Restore visible video players and preload 2 more in scroll direction
                self.restoreVideoPlayersAfterForeground()
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
        // Clear saved scroll position when scrolling to top (both instance and persistent)
        savedScrollPosition = nil
        ScrollPositionManager.shared.clearScrollPosition(for: feedIdentifier)
        isScrollingToTop = true
        
        // Scroll to the top of the table view with animation
        let topInset = tableView.adjustedContentInset.top
        tableView.setContentOffset(CGPoint(x: 0, y: -topInset), animated: true)
        
        // Reset flag after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isScrollingToTop = false
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Restore scroll position from persistent storage if available
        // This handles cases where the view controller was deallocated and recreated
        if !isScrollingToTop {
            // First check instance variable (for same-session navigation)
            if let savedPosition = savedScrollPosition {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, !self.isScrollingToTop else { return }
                    self.tableView.setContentOffset(CGPoint(x: 0, y: savedPosition), animated: false)
                    self.lastScrollOffset = savedPosition
                    self.savedScrollPosition = nil
                }
            } else if let persistentPosition = ScrollPositionManager.shared.getScrollPosition(for: feedIdentifier) {
                // Restore from persistent storage (for tab switching)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, !self.isScrollingToTop else { return }
                    // Wait a bit longer for layout when restoring from persistent storage
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        guard let self = self, !self.isScrollingToTop else { return }
                        self.tableView.setContentOffset(CGPoint(x: 0, y: persistentPosition), animated: false)
                        self.lastScrollOffset = persistentPosition
                        // Keep position in storage until we scroll away or scroll to top
                    }
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
            // Also ignore if we just restored a saved position (check both instance and persistent)
            let hasSavedPosition = savedScrollPosition != nil || ScrollPositionManager.shared.getScrollPosition(for: feedIdentifier) != nil
            if topInset > 0 && currentOffset >= -5 && currentOffset <= 5 && !hasSavedPosition {
                tableView.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false)
                lastScrollOffset = -topInset
            }
        }

        // NOTE: Video playback restart is handled by .feedViewDidAppear notification
        // (see setupFeedViewDidAppearObserver) which properly rebuilds the video list
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Save current scroll position when view disappears
        // Only save if we're not at the very top (to avoid saving top position unnecessarily)
        let topInset = tableView.adjustedContentInset.top
        let currentOffset = tableView.contentOffset.y
        let topPosition = -topInset
        
        // Save position if we're scrolled down from the top (more than 10 points)
        if currentOffset > topPosition + 10 {
            // Save to both instance variable (for same-session) and persistent storage (for tab switching)
            savedScrollPosition = currentOffset
            ScrollPositionManager.shared.saveScrollPosition(currentOffset, for: feedIdentifier)
        } else {
            // At or near top, clear saved position
            savedScrollPosition = nil
            ScrollPositionManager.shared.clearScrollPosition(for: feedIdentifier)
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
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
            if currentOffset < -topInset && savedScrollPosition == nil {
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
        
        // CRITICAL: Disable ALL prefetching to prevent SwiftUI layout hangs during cell preparation
        // Setting prefetchDataSource to nil only disables custom prefetching, but iOS still
        // does automatic prefetching. We must explicitly disable it to avoid the 8ms+ hang
        // seen in Instruments when UITableView prefetches cells with UIHostingView content.
        tableView.prefetchDataSource = nil
        if #available(iOS 15.0, *) {
            tableView.isPrefetchingEnabled = false
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
        print("🔵 [PINNED UPDATE] updatePinnedTweets called with \(tweets.count) tweets: \(tweets.map { $0.mid })")
        let oldCount = pinnedTweets.count
        let oldPinnedTweets = pinnedTweets
        self.pinnedTweets = tweets

        // CRITICAL: Rebuild video list when pinned tweets change
        // This ensures pinned tweet videos are registered with the coordinator
        print("🔵 [PINNED UPDATE] Rebuilding video list with \(self.tweets.count) regular tweets and \(pinnedTweets.count) pinned tweets")
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
                print("🔄 [PINNED UPDATE OPTIMIZATION] Only hit counts changed - skipping reload")

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
                    print("🔄 [UPDATE CHECK] Order changed at index \(i): \(oldTweets[i].mid) -> \(newTweets[i].mid)")
                    break
                }
            }

            if sameOrder {
                // OPTIMIZATION: Same tweets in same order - only hit counts changed
                // Tweet.getInstance() already updated the @Published count properties
                // SwiftUI will automatically re-render action buttons, no need to reload cells
                print("✅ [UPDATE OPTIMIZATION] Only hit counts changed - skipping table reload (count: \(oldCount))")
                videoCoordinator.buildVideoList(from: newTweets, pinnedTweets: pinnedTweets)
                return
            } else {
                print("⚠️ [UPDATE] Same count but different order - will use smart update")
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
            // Use simple format to avoid overwhelming console
            print("🔄 [LOADING STATE] isLoadingMore: \(isLoadingMore), hasMoreTweets: \(hasMoreTweets)")
        }
        
        // Show/hide loading spinner with animations
        if isLoadingMore {
            // ✅ FIX: Don't show spinner if we just showed/have no-more-tweets message
            // If there are no more tweets and we just showed the message, don't show spinner
            // This prevents the spinner flash right after the message disappears
            if isShowingNoMoreTweetsMessage || (!hasMoreTweets && lastNoMoreTweetsShownTime != nil) {
                let timeSinceMessage = lastNoMoreTweetsShownTime.map { Date().timeIntervalSince($0) } ?? 0
                if timeSinceMessage < 3.0 {  // Within 3 seconds of showing message (2s display + 1s buffer)
                    print("⏳ [FOOTER SPINNER] Skipping spinner - no-more-tweets message was recently shown")
                    return
                }
            }
            
            // Record when spinner was shown
            loadingSpinnerStartTime = Date()
            // ✅ FIX: Don't print Date() directly - can cause Xcode console to stop showing logs
            print("⏳ [FOOTER SPINNER] Showing spinner with animation")
            
            // Start timeout timer as safety measure (30 second timeout)
            loadingTimeoutTimer?.invalidate()
            loadingTimeoutTimer = Timer.scheduledTimer(withTimeInterval: maximumLoadingTime, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                print("⚠️ [TIMEOUT] Loading took longer than \(Int(self.maximumLoadingTime))s - forcing spinner to hide")
                
                // Force hide spinner and reset state
                if self.isLoadingMore {
                    self.updateLoadingState(isLoadingMore: false, hasMoreTweets: self.hasMoreTweets)
                }
            }
            
            // Use taller footer to position spinner just above bottom nav bar
            let footerView = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 80))
            footerView.backgroundColor = .clear
            
            let spinner = UIActivityIndicatorView(style: .medium)
            // Position spinner in lower part of footer, closer to bottom nav
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
                    print("⏳ [FOOTER SPINNER] Delaying hide for \(Int(remainingTime * 1000))ms to meet minimum 500ms")
                    DispatchQueue.main.asyncAfter(deadline: .now() + remainingTime) { [weak self] in
                        guard let self = self else { return }
                        self.hideSpinner(shouldShowMessage: shouldShowMessage && canShowMessage)
                    }
                } else {
                    hideSpinner(shouldShowMessage: shouldShowMessage && canShowMessage)
                }
            } else {
                // No start time recorded, hide immediately
                // ✅ FIX: Don't clear footer if we're showing the "no more tweets" message
                // This prevents the message from being removed prematurely
                if isShowingNoMoreTweetsMessage {
                    print("✅ [FOOTER SPINNER] Skipping footer clear - no-more-tweets message is showing")
                    return
                }
                if tableView.tableFooterView != nil {
                    print("✅ [FOOTER SPINNER] Hiding spinner (no start time)")
                }
                tableView.tableFooterView = nil
            }
        }
    }
    
    private func hideSpinner(shouldShowMessage: Bool) {
        // Cancel timeout timer since loading completed normally
        loadingTimeoutTimer?.invalidate()
        loadingTimeoutTimer = nil
        
        // ✅ FIX: Don't hide spinner if we're showing the "no more tweets" message
        // This prevents the message from being removed when hideSpinner is called
        if isShowingNoMoreTweetsMessage {
            print("✅ [FOOTER SPINNER] Skipping hide - no-more-tweets message is showing")
            loadingSpinnerStartTime = nil
            return
        }
        
        guard let footerView = tableView.tableFooterView else {
            print("✅ [FOOTER SPINNER] No footer view to hide")
            loadingSpinnerStartTime = nil
            if shouldShowMessage {
                showNoMoreTweetsMessage()
            }
            return
        }
        
        if let startTime = loadingSpinnerStartTime {
            let displayDuration = Date().timeIntervalSince(startTime)
            print("✅ [FOOTER SPINNER] Hiding spinner with animation (displayed for \(String(format: "%.2f", displayDuration * 1000))ms)")
        } else {
            print("✅ [FOOTER SPINNER] Hiding spinner with animation (no start time)")
        }
        
        // Fade out and slide down animation
        UIView.animate(withDuration: 0.2, animations: {
            footerView.alpha = 0
            footerView.transform = CGAffineTransform(translationX: 0, y: 10)
        }) { [weak self] _ in
            guard let self = self else { return }
            if self.tableView.tableFooterView === footerView {
                self.tableView.tableFooterView = nil
                print("✅ [FOOTER SPINNER] Footer view removed from table")
            }
            self.loadingSpinnerStartTime = nil
            
            // Show message after spinner clears
            if shouldShowMessage {
                print("📭 [TRANSITION] Showing 'no more tweets' message after spinner")
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
        // This prevents layout shifts when the embedded tweet loads asynchronously
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
                print("DEBUG: [cellForRowAt] Pre-loaded embedded tweet \(originalTweetId) from cache")
            }
        }

        if let rowView = rowViewBuilder {
            cell.configure(
                with: tweet,
                rowView: rowView,
                parentViewController: self,
                leadingPadding: leadingPadding,
                trailingPadding: trailingPadding
            )
        }

        // No height change callback needed - heights are calculated precisely upfront

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

        // If we have a cached height, use it for best estimate
        if let cachedHeight = tweet.cachedHeight {
            return cachedHeight
        }

        // Calculate estimate from tweet content
        var estimate: CGFloat = 0

        // Top padding (20pt from TweetItemView)
        estimate += 20

        // Header: author name + timestamp (~22pt)
        estimate += 22

        // Text content estimate (more accurate)
        if let content = tweet.content, !content.isEmpty {
            // Rough estimate: ~18pt per line, ~40 chars per line
            let estimatedLines = max(1, CGFloat(content.count) / 40)
            estimate += estimatedLines * 18 + 8  // +8 for spacing
        }

        // MediaGrid: PRECISE calculation (no estimation!)
        if let attachments = tweet.attachments, !attachments.isEmpty {
            let mediaHeight = MediaGridViewModel.calculateHeight(for: attachments, isEmbedded: false)
            estimate += mediaHeight + 8  // +8 for spacing
        }

        // Embedded tweet estimate (check if it's loaded for better accuracy)
        if let originalTweetId = tweet.originalTweetId {
            if let embeddedTweet = Tweet.getInstance(for: originalTweetId),
               embeddedTweet.author != nil {
                // Embedded tweet is loaded - calculate its height
                var embeddedHeight: CGFloat = 50  // Embedded header + padding

                if let embeddedContent = embeddedTweet.content, !embeddedContent.isEmpty {
                    let estimatedLines = max(1, CGFloat(embeddedContent.count) / 35)
                    embeddedHeight += estimatedLines * 16
                }

                if let embeddedAttachments = embeddedTweet.attachments, !embeddedAttachments.isEmpty {
                    embeddedHeight += MediaGridViewModel.calculateHeight(for: embeddedAttachments, isEmbedded: true)
                }

                estimate += embeddedHeight + 16
            } else {
                // Not loaded yet - use rough estimate
                estimate += 150
            }
        }

        // Actions row (44pt)
        estimate += 44

        // Bottom padding (~16pt from TweetItemView)
        estimate += 16

        return estimate
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

        // Use cached height if available (content is immutable, height never changes)
        if let cachedHeight = tweet.cachedHeight {
            return cachedHeight
        }

        // First render: let SwiftUI measure
        return UITableView.automaticDimension
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

        // Cache height if not already cached and cell has valid height
        if tweet.cachedHeight == nil && cell.frame.height > 0 {
            tweet.cachedHeight = cell.frame.height
        }
    }

    // MARK: - UIScrollViewDelegate
    
    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Track scroll direction for height caching strategy and toolbar hiding
        let currentOffset = scrollView.contentOffset.y
        isScrollingBackward = currentOffset < lastContentOffset
        let delta = currentOffset - lastContentOffset

        // Throttle video visibility updates to avoid expensive calculations on every scroll frame
        // Use time-based throttling: execute immediately on first call, then throttle subsequent calls
        let now = Date()
        let shouldUpdate: Bool

        if let lastUpdate = lastVideoVisibilityUpdate {
            // Check if enough time has passed since last update
            shouldUpdate = now.timeIntervalSince(lastUpdate) >= videoVisibilityThrottleInterval
        } else {
            // First update - execute immediately
            shouldUpdate = true
        }

        if shouldUpdate {
            lastVideoVisibilityUpdate = now
            updateVisibleTweetsForVideoPlayback()

            // MEMORY FIX: Periodically clean up SwiftUI view cache during long scroll sessions
            // This prevents cache from growing unbounded during extended scrolling
            // The cache has its own LRU eviction, but this provides an extra safety net
            scrollUpdateCount += 1
            if scrollUpdateCount % 50 == 0 { // Every 50 scroll updates (~20 seconds of scrolling)
                let _ = SwiftUIViewCache.shared.clearCache()
                print("🧹 [MEMORY] Periodic cache cleanup during scroll")
            }
        }

        // Detect bottom pull-to-load gesture (always check, even before initial layout)
        let contentHeight = scrollView.contentSize.height
        let scrollViewHeight = scrollView.frame.size.height
        let contentInsetBottom = scrollView.contentInset.bottom
        let bottomOffset = scrollView.contentOffset.y + scrollViewHeight - contentHeight + contentInsetBottom

        // Only allow pull-to-load if we have at least a few tweets
        if tweets.count >= 4 && bottomOffset > bottomPullThreshold && !isLoadingMore && !isBottomPullActive {
            // User pulled down past threshold
            print("📱 [BOTTOM PULL] Threshold reached, triggering loadMore (hasMoreTweets: \(hasMoreTweets))")
            isBottomPullActive = true
            triggerBottomPullLoadMore()
        } else if bottomOffset <= 0 {
            // User released or scrolled back up
            isBottomPullActive = false
        }

        // Don't trigger toolbar hiding until initial layout is complete
        // This prevents incorrect hiding when view first loads
        guard hasCompletedInitialLayout else {
            lastContentOffset = currentOffset
            return
        }

        // Time-based throttling: don't send callbacks too frequently
        let shouldThrottleByTime = lastScrollCallbackTime.map { now.timeIntervalSince($0) < scrollCallbackThrottleInterval } ?? false

        // Only forward significant changes to reduce jitter (matching old SwiftUI implementation)
        // Increased threshold to reduce CPU usage during rapid scrolling
        let headerThreshold: CGFloat = 30
        let shouldThrottleByDistance = abs(delta) < headerThreshold

        guard !shouldThrottleByTime && !shouldThrottleByDistance else {
            lastContentOffset = currentOffset
            return
        }

        // Call the onScroll callback with accumulated delta
        onScroll?(currentOffset, delta)

        lastContentOffset = currentOffset
        lastScrollCallbackTime = now
    }
    
    override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // Scroll started - video coordinator handles playback
    }
    
    override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // Scroll ended - handled by coordinator
    }
    
    override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // Deceleration ended - handled by coordinator
    }
    
    // MARK: - Height Estimation
    
    /// Preflight height estimates for new tweets to reduce initial layout jumps
    
    // MARK: - Video Playback Coordination
    
    private func updateVisibleTweetsForVideoPlayback() {
        guard !tweets.isEmpty || !pinnedTweets.isEmpty else { return }

        // OPTIMIZATION: Use simpler visibility calculation to reduce CPU usage
        // Instead of complex intersection calculations, use index-based approximation
        let visibleIndexPaths = tableView.indexPathsForVisibleRows ?? []

        // Convert visible index paths to tweet IDs more efficiently
        let visibleTweetIds = Set(visibleIndexPaths.compactMap { indexPath -> String? in
            let totalRows = pinnedTweets.count + tweets.count
            guard indexPath.row < totalRows else { return nil }

            // Determine which tweet this row represents
            if indexPath.row < pinnedTweets.count {
                return pinnedTweets[indexPath.row].mid
            } else {
                let regularIndex = indexPath.row - pinnedTweets.count
                guard regularIndex < tweets.count else { return nil }
                return tweets[regularIndex].mid
            }
        })

        // Only update coordinator if visible tweets actually changed
        // This prevents unnecessary video coordinator work during smooth scrolling
        if visibleTweetIds != lastVisibleTweetIds {
            lastVisibleTweetIds = visibleTweetIds
            videoCoordinator.updateVisibleTweets(visibleTweetIds)
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
        print("🔄 [PROGRAMMATIC] Load more requested")
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
            print("📭 [BOTTOM PULL] No more tweets - showing spinner for 500ms then message for 2s")
            
            // Show spinner first for exactly 500ms
            updateLoadingState(isLoadingMore: true, hasMoreTweets: false)
            
            // After 500ms, hide spinner (which will trigger message if conditions are met)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                print("⏰ [TIMING] 500ms elapsed - hiding spinner and showing message")
                self.updateLoadingState(isLoadingMore: false, hasMoreTweets: false)
                
                // Reset flag to allow next pull
                self.isBottomPullActive = false
            }
            return
        }
        
        print("🔄 [BOTTOM PULL] Manual pull - calling loadMoreTweets(forceLoad: true)")
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
        // Prevent showing multiple messages at once
        guard !isShowingNoMoreTweetsMessage else {
            print("📭 [NO MORE TWEETS] Already showing message, skipping")
            return
        }
        
        isShowingNoMoreTweetsMessage = true
        lastNoMoreTweetsShownTime = Date()
        
        // Cancel any existing timer
        noMoreTweetsMessageTimer?.invalidate()
        
        // ✅ FIX: Don't print Date() directly - can cause Xcode console to stop showing logs
        print("📭 [NO MORE TWEETS] Showing message with animation")
        
        // Create footer view with message - increased height for more spacing from tweet above
        let footerView = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 120))
        footerView.backgroundColor = .clear
        
        let messageLabel = UILabel()
        messageLabel.text = NSLocalizedString("No more tweets", comment: "Message shown when there are no more tweets to load")
        messageLabel.textAlignment = .center
        messageLabel.font = .systemFont(ofSize: 15, weight: .medium)
        messageLabel.textColor = .secondaryLabel
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        
        footerView.addSubview(messageLabel)
        
        // ✅ FIX: Position message lower in footer to increase distance from tweet above
        // Increased top padding from 20 to 40 to add more space
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: footerView.centerXAnchor),
            messageLabel.topAnchor.constraint(equalTo: footerView.topAnchor, constant: 40)
        ])
        
        // Fade in and slide up animation (matching Android)
        footerView.alpha = 0
        footerView.transform = CGAffineTransform(translationX: 0, y: 20)
        tableView.tableFooterView = footerView
        
        UIView.animate(withDuration: 0.4, delay: 0, options: .curveEaseOut) {
            footerView.alpha = 1.0
            footerView.transform = .identity
        }
        
        // Auto-hide after 2 seconds
        let messageDisplayDuration: TimeInterval = 2.0
        print("📭 [NO MORE TWEETS] Setting \(messageDisplayDuration)-second timer")
        noMoreTweetsMessageTimer = Timer.scheduledTimer(withTimeInterval: messageDisplayDuration, repeats: false) { [weak self] timer in
            guard let self = self else {
                print("📭 [NO MORE TWEETS] Timer fired but self is nil")
                return
            }
            
            // ✅ FIX: Don't print Date() directly - can cause Xcode console to stop showing logs
            print("📭 [NO MORE TWEETS] Timer fired - hiding message with animation (2s cooldown active)")
            
            // Fade out and slide up animation
            UIView.animate(withDuration: 0.3, animations: {
                footerView.alpha = 0
                footerView.transform = CGAffineTransform(translationX: 0, y: -10)
            }) { _ in
                if self.tableView.tableFooterView === footerView {
                    self.tableView.tableFooterView = nil
                    // ✅ FIX: Don't print Date() directly - can cause Xcode console to stop showing logs
                    print("📭 [NO MORE TWEETS] Message hidden and removed from table")
                }
                // ✅ FIX: Clear flag AFTER removing footer, but add small delay before allowing spinner
                // This prevents updateLoadingState (called from SwiftUI updates) from immediately showing spinner
                self.isShowingNoMoreTweetsMessage = false
                
                // Small delay to prevent immediate spinner flash after message removal
                // updateUIViewController might be called right after this, and without the delay,
                // it could show a spinner if isLoadingMore is still true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // After brief delay, if state says we should load, allow it
                    // But if there are no more tweets, don't show spinner
                    if self.isLoadingMore && self.hasMoreTweets {
                        // Only update if we should actually be loading
                        self.updateLoadingState(isLoadingMore: self.isLoadingMore, hasMoreTweets: self.hasMoreTweets)
                    }
                }
            }
        }
    }
}
