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

class TweetTableViewController: UITableViewController {
    
    // Data
    private var tweets: [Tweet] = []
    private var pinnedTweets: [Tweet] = []  // Pinned tweets rendered as first N rows
    private var hasMoreTweets: Bool = true
    private var isLoadingMore: Bool = false
    
    // Bottom pull-to-load state
    private var isBottomPullActive: Bool = false
    private var bottomPullThreshold: CGFloat = 80  // Pull down 80pt to trigger
    
    // Spinner timing
    private var loadingSpinnerStartTime: Date? = nil
    private let minimumSpinnerDisplayTime: TimeInterval = 0.5  // 500ms minimum
    
    // Callbacks
    var loadMoreTweets: ((Bool) -> Void)?  // Parameter: forceLoad
    var onRefresh: (() async -> Void)?  // Pull-to-refresh callback
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
    
    // Height cache for layout stability (prevents jumps when cells with videos load)
    // Throttling for video visibility updates (avoid expensive checks on every scroll frame)
    private var lastVideoVisibilityUpdate: Date?
    private let videoVisibilityThrottleInterval: TimeInterval = 0.1 // 100ms throttle
    
    // Cached main content rect to avoid recalculating on every visibility check
    private var cachedMainContentRect: CGRect?
    private var lastContentOffset: CGFloat = 0
    private var lastHeaderHeight: CGFloat = 0
    private var lastFooterHeight: CGFloat = 0
    
    // Notification observer for scroll to top
    private var scrollToTopObserver: NSObjectProtocol?
    // Notification observer for tweet height changes
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupTableView()
        setupRefreshControl()
        setupScrollToTopObserver()
        
        // Pass table view reference to video coordinator for viewport calculations
        videoCoordinator.setTableView(tableView)
    }
    
    deinit {
        // Remove notification observers
        if let observer = scrollToTopObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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
    
    func scrollToTop() {
        // Scroll to the top of the table view with animation
        let topInset = tableView.adjustedContentInset.top
        tableView.setContentOffset(CGPoint(x: 0, y: -topInset), animated: true)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Only adjust once, and only if at the initial bad position (around 0)
        // Don't interfere with header-adjustment or user scrolling
        guard !hasAdjustedInitialPosition else { return }
        hasAdjustedInitialPosition = true
        
        let topInset = tableView.adjustedContentInset.top
        let currentOffset = tableView.contentOffset.y
        
        // Only adjust if offset is close to 0 (the bad initial position)
        // and topInset is set (nav bar is present)
        // Ignore if already properly positioned or if user has scrolled
        if topInset > 0 && currentOffset >= -5 && currentOffset <= 5 {
            tableView.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false)
            lastScrollOffset = -topInset
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
            if currentOffset < -topInset {
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
        
        // Disable prefetching to reduce complexity
        tableView.prefetchDataSource = nil
        
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
        let bottomInset: CGFloat = 60 // Extra padding to account for tab bar + safe area
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
        self.pinnedTweets = tweets
        
        // CRITICAL: Rebuild video list when pinned tweets change
        // This ensures pinned tweet videos are registered with the coordinator
        print("🔵 [PINNED UPDATE] Rebuilding video list with \(self.tweets.count) regular tweets and \(pinnedTweets.count) pinned tweets")
        videoCoordinator.buildVideoList(from: self.tweets, pinnedTweets: pinnedTweets)
        
        // Reload table to reflect new pinned tweets
        if oldCount != tweets.count {
            // Number of rows changed, do a full reload
            tableView.reloadData()
        } else if oldCount > 0 {
            // Same number, just update the content
            let indexPaths = (0..<oldCount).map { IndexPath(row: $0, section: 0) }
            tableView.reloadRows(at: indexPaths, with: .none)
        }
        
        // CRITICAL: Update visibility after reload so coordinator knows pinned videos are visible
        // Delay slightly to ensure cells have been created
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.updateVisibleTweetsForVideoPlayback()
        }
    }
    
    func updateTweets(_ newTweets: [Tweet]) {
        let oldCount = tweets.count
        let oldTweets = tweets
        tweets = newTweets
        
        
        // Handle initial load
        if oldCount == 0 && newTweets.count > 0 {
            tableView.reloadData()
            videoCoordinator.buildVideoList(from: newTweets, pinnedTweets: pinnedTweets)
            
            // Trigger video detection after initial load
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.updateVisibleTweetsForVideoPlayback()
            }
            return
        }
        
        // No change - use early exit to avoid allocations
        if oldCount == newTweets.count {
            var hasChange = false
            for i in 0..<oldCount {
                if oldTweets[i].mid != newTweets[i].mid {
                    hasChange = true
                    break
                }
            }
            if !hasChange {
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
        // Only log and update UI if state actually changed
        let stateChanged = self.isLoadingMore != isLoadingMore || self.hasMoreTweets != hasMoreTweets
        
        self.isLoadingMore = isLoadingMore
        self.hasMoreTweets = hasMoreTweets
        
        // Only log when state actually changes to avoid spam
        if stateChanged {
            print("🔄 [LOADING STATE] isLoadingMore: \(isLoadingMore), hasMoreTweets: \(hasMoreTweets)")
        }
        
        // Show/hide loading spinner at bottom using table footer (simple approach)
        if isLoadingMore {
            // Record when spinner was shown
            loadingSpinnerStartTime = Date()
            print("⏳ [FOOTER SPINNER] Showing spinner")
            let footerView = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 56))
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.center = CGPoint(x: footerView.bounds.width / 2, y: footerView.bounds.height / 2)
            spinner.startAnimating()
            footerView.addSubview(spinner)
            tableView.tableFooterView = footerView
        } else {
            // Hide spinner, but ensure minimum display time
            if let startTime = loadingSpinnerStartTime {
                let elapsedTime = Date().timeIntervalSince(startTime)
                let remainingTime = max(0, minimumSpinnerDisplayTime - elapsedTime)
                
                if remainingTime > 0 {
                    print("⏳ [FOOTER SPINNER] Delaying hide for \(Int(remainingTime * 1000))ms to meet minimum 500ms")
                    DispatchQueue.main.asyncAfter(deadline: .now() + remainingTime) { [weak self] in
                        guard let self = self else { return }
                        if self.tableView.tableFooterView != nil {
                            print("✅ [FOOTER SPINNER] Hiding spinner after minimum time")
                        }
                        self.tableView.tableFooterView = nil
                        self.loadingSpinnerStartTime = nil
                    }
                } else {
                    if tableView.tableFooterView != nil {
                        print("✅ [FOOTER SPINNER] Hiding spinner (minimum time already met)")
                    }
                    tableView.tableFooterView = nil
                    loadingSpinnerStartTime = nil
                }
            } else {
                // No start time recorded, hide immediately
                if tableView.tableFooterView != nil {
                    print("✅ [FOOTER SPINNER] Hiding spinner (no start time)")
                }
                tableView.tableFooterView = nil
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
        
        if let rowView = rowViewBuilder {
            cell.configure(
                with: tweet,
                rowView: rowView,
                parentViewController: self,
                leadingPadding: leadingPadding,
                trailingPadding: trailingPadding
            )
        }
        
        return cell
    }
    
    // MARK: - UITableViewDelegate
    
    override func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        let totalRows = pinnedTweets.count + tweets.count
        guard indexPath.row < totalRows else { return 250 }
        
        // Determine which tweet this row represents
        let tweet: Tweet
        if indexPath.row < pinnedTweets.count {
            tweet = pinnedTweets[indexPath.row]
        } else {
            let regularIndex = indexPath.row - pinnedTweets.count
            guard regularIndex < tweets.count else { return 250 }
            tweet = tweets[regularIndex]
        }
        
        // Use tweet's cached height if available (best estimate!)
        if let cachedHeight = tweet.cachedHeight {
            return cachedHeight
        }
        
        // First time: fallback estimate
        return 250
    }
    
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let totalRows = pinnedTweets.count + tweets.count
        guard indexPath.row < totalRows else { return UITableView.automaticDimension }
        
        // Determine which tweet this row represents
        let tweet: Tweet
        if indexPath.row < pinnedTweets.count {
            tweet = pinnedTweets[indexPath.row]
        } else {
            let regularIndex = indexPath.row - pinnedTweets.count
            guard regularIndex < tweets.count else { return UITableView.automaticDimension }
            tweet = tweets[regularIndex]
        }
        
        // CRITICAL: If we have cached height, use it as FIXED height
        // This prevents re-measurement and eliminates scroll jumps when scrolling UP
        if let cachedHeight = tweet.cachedHeight {
            return cachedHeight
        }
        
        // First time rendering: let auto-layout measure
        return UITableView.automaticDimension
    }
    
    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let totalRows = pinnedTweets.count + tweets.count
        guard indexPath.row < totalRows else { return }
        
        // Get the tweet
        let tweet: Tweet
        if indexPath.row < pinnedTweets.count {
            tweet = pinnedTweets[indexPath.row]
        } else {
            let regularIndex = indexPath.row - pinnedTweets.count
            guard regularIndex < tweets.count else { return }
            tweet = tweets[regularIndex]
        }
        
        // Cache the rendered height on the tweet object itself
        // This will be used as FIXED height when scrolling back
        tweet.cachedHeight = cell.frame.height
    }
    
    override func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Heights are cached on tweet objects - nothing to do here
    }
    
    
    // MARK: - UIScrollViewDelegate
    
    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
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
        }
        
        // Detect bottom pull-to-load gesture (always check, even before initial layout)
        let contentHeight = scrollView.contentSize.height
        let scrollViewHeight = scrollView.frame.size.height
        let bottomOffset = scrollView.contentOffset.y + scrollViewHeight - contentHeight
        
        // Only allow pull-to-load if we have at least a few tweets
        if tweets.count >= 4 && bottomOffset > bottomPullThreshold && !isLoadingMore && !isBottomPullActive {
            // User pulled down past threshold
            print("📱 [BOTTOM PULL] Threshold reached, triggering loadMore")
            isBottomPullActive = true
            triggerBottomPullLoadMore()
        } else if bottomOffset <= 0 {
            // User released or scrolled back up
            isBottomPullActive = false
        }
        
        // Don't trigger toolbar hiding until initial layout is complete
        // This prevents incorrect hiding when view first loads
        guard hasCompletedInitialLayout else { return }
        
        // Track scroll offset and delta for toolbar hiding
        let currentOffset = scrollView.contentOffset.y
        let delta = currentOffset - lastScrollOffset
        
        // Only forward significant changes to reduce jitter (matching old SwiftUI implementation)
        let headerThreshold: CGFloat = 20
        guard abs(delta) >= headerThreshold else { return }
        
        // Call the onScroll callback with accumulated delta
        onScroll?(currentOffset, delta)
        
        lastScrollOffset = currentOffset
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
        
        // Calculate main content area (excluding header and footer) for row visibility
        let mainContentRect = calculateMainContentRect()
        
        // Get visible cells and check visibility
        let visibleIndexPaths = tableView.indexPathsForVisibleRows ?? []
        let visibleTweetIds = Set(visibleIndexPaths.compactMap { indexPath -> String? in
            let totalRows = pinnedTweets.count + tweets.count
            guard indexPath.row < totalRows else { return nil }
            
            // Get the cell for this index path
            guard let cell = tableView.cellForRow(at: indexPath) else { return nil }
            
            // Convert cell frame to table view coordinates
            let cellFrame = tableView.convert(cell.frame, to: tableView)
            
            // Check if cell intersects with main content area
            let intersection = cellFrame.intersection(mainContentRect)
            
            // Only consider cells that have at least 30% of their height visible in main content area
            // This ensures videos are sufficiently visible before starting playback
            let visibilityRatio = intersection.height / cellFrame.height
            guard visibilityRatio >= 0.3 else { return nil }
            
            // Determine which tweet this row represents
            if indexPath.row < pinnedTweets.count {
                return pinnedTweets[indexPath.row].mid
            } else {
                let regularIndex = indexPath.row - pinnedTweets.count
                guard regularIndex < tweets.count else { return nil }
                return tweets[regularIndex].mid
            }
        })
        
        // Update coordinator
        videoCoordinator.updateVisibleTweets(visibleTweetIds)
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
    
    private func triggerBottomPullLoadMore() {
        guard !isLoadingMore else { return }
        
        print("🔄 [BOTTOM PULL] Manual pull - calling loadMoreTweets(forceLoad: true)")
        updateLoadingState(isLoadingMore: true, hasMoreTweets: hasMoreTweets)
        
        // Call the load more callback with forceLoad=true to bypass hasMoreTweets check
        loadMoreTweets?(true)
        
        // Reset flag after a delay to allow next pull
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.isBottomPullActive = false
        }
    }
}
