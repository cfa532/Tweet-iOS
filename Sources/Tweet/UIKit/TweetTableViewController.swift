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
    private var heightCache: [String: CGFloat] = [:]
    
    // Throttling for video visibility updates (avoid expensive checks on every scroll frame)
    private var videoVisibilityUpdateTimer: Timer?
    private var lastVideoVisibilityUpdate: Date?
    private let videoVisibilityThrottleInterval: TimeInterval = 0.1 // 100ms throttle
    
    // Cached main content rect to avoid recalculating on every visibility check
    private var cachedMainContentRect: CGRect?
    private var lastContentOffset: CGFloat = 0
    private var lastHeaderHeight: CGFloat = 0
    private var lastFooterHeight: CGFloat = 0
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupTableView()
        setupRefreshControl()
        
        // Pass table view reference to video coordinator for viewport calculations
        videoCoordinator.setTableView(tableView)
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
        } else {
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
    
    func updateTweets(_ newTweets: [Tweet]) {
        let oldCount = tweets.count
        let oldTweets = tweets
        tweets = newTweets
        
        // Clean up height cache for tweets no longer in the list (memory optimization)
        let currentTweetIds = Set(newTweets.map { $0.mid })
        heightCache = heightCache.filter { currentTweetIds.contains($0.key) }
        
        // Handle initial load
        if oldCount == 0 && newTweets.count > 0 {
            // Preflight: estimate heights for new tweets before layout
            // This reduces first-time layout jumps by providing better initial estimates
            preflightHeightEstimates(for: newTweets)
            
            tableView.reloadData()
            videoCoordinator.buildVideoList(from: newTweets)
            
            // Trigger video detection after initial load
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.updateVisibleTweetsForVideoPlayback()
            }
            return
        }
        
        // No change
        if oldCount == newTweets.count && oldTweets.map({ $0.mid }) == newTweets.map({ $0.mid }) {
            videoCoordinator.buildVideoList(from: newTweets)
            return
        }
        
        // Smart update: Check for common patterns
        let oldIds = oldTweets.map { $0.mid }
        let newIds = newTweets.map { $0.mid }
        
        // Case 1: Tweets prepended (new tweets at top) - most common for new posts
        if newTweets.count > oldCount {
            let potentialPrependCount = newTweets.count - oldCount
            let afterNewOnes = Array(newIds.dropFirst(potentialPrependCount))
            
            if afterNewOnes == oldIds {
                // Preflight: estimate heights for new tweets to reduce layout jumps
                let prependedTweets = Array(newTweets.prefix(potentialPrependCount))
                preflightHeightEstimates(for: prependedTweets)
                
                let indexPaths = (0..<potentialPrependCount).map { IndexPath(row: $0, section: 0) }
                tableView.insertRows(at: indexPaths, with: .automatic)
                videoCoordinator.buildVideoList(from: newTweets)
                return
            }
        }
        
        // Case 2: Tweets appended (pagination) - common for load more
        if newTweets.count > oldCount {
            let newIdsPrefix = Array(newIds.prefix(oldCount))
            
            if newIdsPrefix == oldIds {
                // Preflight: estimate heights for new tweets to reduce layout jumps
                let appendedTweets = Array(newTweets[oldCount...])
                preflightHeightEstimates(for: appendedTweets)
                
                let indexPaths = (oldCount..<newTweets.count).map { IndexPath(row: $0, section: 0) }
                tableView.insertRows(at: indexPaths, with: .none)
                videoCoordinator.buildVideoList(from: newTweets)
                return
            }
        }
        
        // Case 3: Single tweet removed - common for delete
        if newTweets.count == oldCount - 1 {
            if let removedIndex = oldIds.firstIndex(where: { id in !newIds.contains(id) }) {
                tableView.deleteRows(at: [IndexPath(row: removedIndex, section: 0)], with: .automatic)
                videoCoordinator.buildVideoList(from: newTweets)
                return
            }
        }
        
        // Complex change: fallback to full reload
        tableView.reloadData()
        videoCoordinator.buildVideoList(from: newTweets)
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
        self.isLoadingMore = isLoadingMore
        self.hasMoreTweets = hasMoreTweets
        
        print("🔄 [LOADING STATE] isLoadingMore: \(isLoadingMore), hasMoreTweets: \(hasMoreTweets)")
        
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
        return tweets.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: TweetTableViewCell.reuseIdentifier,
            for: indexPath
        ) as? TweetTableViewCell else {
            return UITableViewCell()
        }
        
        let tweet = tweets[indexPath.row]
        
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
        guard indexPath.row < tweets.count else { return 250 }
        let tweetId = tweets[indexPath.row].mid
        
        // Use cached height if available for better estimation
        if let cachedHeight = heightCache[tweetId] {
            return cachedHeight
        }
        
        // Otherwise, estimate based on tweet content
        let tweet = tweets[indexPath.row]
        return estimateHeight(for: tweet)
    }
    
    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Cache the actual rendered height for future estimations
        guard indexPath.row < tweets.count else { return }
        let tweetId = tweets[indexPath.row].mid
        heightCache[tweetId] = cell.frame.height
        
        // Auto-load disabled - only manual pull-to-load at bottom
    }
    
    override func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Keep height cached even after cell disappears
        // Height cache persists for better scroll stability
    }
    
    
    // MARK: - UIScrollViewDelegate
    
    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Throttle video visibility updates to avoid expensive calculations on every scroll frame
        // Schedule update if not already scheduled
        if videoVisibilityUpdateTimer == nil {
            videoVisibilityUpdateTimer = Timer.scheduledTimer(
                withTimeInterval: videoVisibilityThrottleInterval,
                repeats: false
            ) { [weak self] _ in
                self?.updateVisibleTweetsForVideoPlayback()
                self?.videoVisibilityUpdateTimer?.invalidate()
                self?.videoVisibilityUpdateTimer = nil
            }
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
    private func preflightHeightEstimates(for tweets: [Tweet]) {
        // Calculate estimated heights for new tweets before first layout
        // This provides better initial estimates and reduces jumps
        for tweet in tweets where heightCache[tweet.mid] == nil {
            let estimated = estimateHeight(for: tweet)
            heightCache[tweet.mid] = estimated
        }
    }
    
    /// Estimate cell height based on tweet content for better layout stability
    private func estimateHeight(for tweet: Tweet) -> CGFloat {
        var estimatedHeight: CGFloat = 0
        
        // Base tweet content height (author info, text, actions)
        estimatedHeight += 80 // Author row + padding
        
        // Estimate text height using actual font metrics (more accurate than character count)
        if let content = tweet.content, !content.isEmpty {
            // Use actual system font to calculate height
            let font = UIFont.systemFont(ofSize: 17, weight: .regular) // Default tweet text font
            let screenWidth = UIScreen.main.bounds.width
            let textWidth = screenWidth - (leadingPadding + trailingPadding) - 16 // Account for padding and margins
            
            // Calculate bounding rect for text
            let maxSize = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
            let textRect = (content as NSString).boundingRect(
                with: maxSize,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            
            estimatedHeight += ceil(textRect.height) + 8 // Add padding
        }
        
        // Add media height if present
        if let attachments = tweet.attachments, !attachments.isEmpty {
            // Calculate media grid height
            let screenWidth = UIScreen.main.bounds.width
            let gridWidth = screenWidth - (leadingPadding + trailingPadding) - 16 // Account for padding
            
            // Get aspect ratio from MediaGridViewModel logic
            let aspectRatio = MediaGridViewModel.aspectRatio(for: attachments)
            let mediaHeight = gridWidth / aspectRatio
            
            estimatedHeight += mediaHeight + 8 // Media + padding
        }
        
        // Add quoted tweet height if present
        if tweet.originalTweetId != nil {
            estimatedHeight += 120 // Approximate quoted tweet height
        }
        
        // Actions bar height
        estimatedHeight += 40
        
        // Clamp to reasonable bounds to prevent extreme estimates
        return min(max(estimatedHeight, 150), 1000)
    }
    
    // MARK: - Video Playback Coordination
    
    private func updateVisibleTweetsForVideoPlayback() {
        guard !tweets.isEmpty else { return }
        
        // Calculate main content area (excluding header and footer)
        let mainContentRect = calculateMainContentRect()
        
        // Get visible cells and filter by main content area
        let visibleIndexPaths = tableView.indexPathsForVisibleRows ?? []
        let visibleTweetIds = Set(visibleIndexPaths.compactMap { indexPath -> String? in
            guard indexPath.row < tweets.count else { return nil }
            
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
            
            return tweets[indexPath.row].mid
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
