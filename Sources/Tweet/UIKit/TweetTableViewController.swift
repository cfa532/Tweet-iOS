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
    private var isLoading: Bool = false
    
    // Callbacks
    var loadMoreTweets: (() -> Void)?
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
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupTableView()
        setupRefreshControl()
        
        print("DEBUG: [TweetTableViewController] viewDidLoad - delegate is set to self")
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // Initialize lastScrollOffset to current offset to prevent incorrect delta on first scroll
        // This prevents toolbar from hiding incorrectly when view loads with negative content offset
        if !hasCompletedInitialLayout {
            lastScrollOffset = tableView.contentOffset.y
            hasCompletedInitialLayout = true
            print("DEBUG: [TweetTableViewController] Initial layout completed - lastScrollOffset: \(lastScrollOffset)")
        }
    }
    
    private func setupTableView() {
        tableView.register(TweetTableViewCell.self, forCellReuseIdentifier: TweetTableViewCell.reuseIdentifier)
        tableView.separatorStyle = .none
        tableView.backgroundColor = .systemBackground
        tableView.estimatedRowHeight = 200
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
        
        // Use automatic adjustment to respect safe area (navigation bar)
        // The scroll jump is prevented by not reassigning tableHeaderView in updateHeader()
        tableView.contentInsetAdjustmentBehavior = .automatic
        
        print("DEBUG: [TweetTableViewController] Table view configured - delegate: \(String(describing: tableView.delegate))")
    }
    
    private func setupRefreshControl() {
        customRefreshControl = UIRefreshControl()
        customRefreshControl?.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        tableView.refreshControl = customRefreshControl
    }
    
    @objc private func handleRefresh() {
        print("DEBUG: [TweetTableViewController] Pull-to-refresh triggered")
        
        // Call async refresh callback
        Task {
            await onRefresh?()
            
            // End refreshing on main thread
            await MainActor.run {
                self.customRefreshControl?.endRefreshing()
            }
        }
    }
    
    // MARK: - Public API
    
    func updateTweets(_ newTweets: [Tweet]) {
        let oldCount = tweets.count
        tweets = newTweets
        
        if oldCount == 0 && newTweets.count > 0 {
            // Initial load
            tableView.reloadData()
        } else if newTweets.count > oldCount {
            // New tweets added
            let indexPaths = (oldCount..<newTweets.count).map { IndexPath(row: $0, section: 0) }
            tableView.insertRows(at: indexPaths, with: .none)
        } else if newTweets.count < oldCount {
            // Tweets removed
            tableView.reloadData()
        }
        
        // Update video coordinator with new tweets
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
            
            // Create a container view with horizontal padding (5pt leading, 7pt trailing for profile)
            let containerView = UIView()
            containerView.backgroundColor = .clear
            containerView.addSubview(headerView)
            
            headerView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                headerView.topAnchor.constraint(equalTo: containerView.topAnchor),
                headerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: leadingPadding),
                headerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -trailingPadding),
                headerView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
            ])
            
            // Calculate the required size for the header (accounting for padding)
            let targetSize = CGSize(width: tableView.bounds.width - (leadingPadding + trailingPadding), height: UIView.layoutFittingCompressedSize.height)
            let size = headerView.systemLayoutSizeFitting(
                targetSize,
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            
            // Set the container frame and assign as table header view (ONLY ONCE)
            containerView.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: size.height)
            tableView.tableHeaderView = containerView
        } else {
            // SUBSEQUENT UPDATES: Only update content, don't reassign tableHeaderView
            // This prevents scroll position jumps
            headerHostingController?.rootView = headerBuilder()
            
            // Force layout to ensure size is correct
            headerHostingController?.view.setNeedsLayout()
            headerHostingController?.view.layoutIfNeeded()
        }
    }
    
    func updateLoadingState(isLoading: Bool, isLoadingMore: Bool, hasMoreTweets: Bool) {
        self.isLoading = isLoading
        self.isLoadingMore = isLoadingMore
        self.hasMoreTweets = hasMoreTweets
        
        if !isLoading {
            customRefreshControl?.endRefreshing()
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
    
    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Load more when approaching end
        if indexPath.row >= tweets.count - 3 && hasMoreTweets && !isLoadingMore && !isLoading {
            print("DEBUG: [TweetTableViewController] Triggering load more at row \(indexPath.row)")
            loadMoreTweets?()
        }
    }
    
    
    // MARK: - UIScrollViewDelegate
    
    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Update visible tweets for video playback coordination
        updateVisibleTweetsForVideoPlayback()
        
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
        print("DEBUG: [TweetTableViewController] ✅ scrollViewWillBeginDragging")
    }
    
    override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        print("DEBUG: [TweetTableViewController] ✅ scrollViewDidEndDragging - decelerate: \(decelerate)")
    }
    
    override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        print("DEBUG: [TweetTableViewController] ✅ scrollViewDidEndDecelerating")
    }
    
    // MARK: - Video Playback Coordination
    
    private func updateVisibleTweetsForVideoPlayback() {
        guard !tweets.isEmpty else { return }
        
        // Get visible cells
        let visibleIndexPaths = tableView.indexPathsForVisibleRows ?? []
        let visibleTweetIds = Set(visibleIndexPaths.compactMap { indexPath -> String? in
            guard indexPath.row < tweets.count else { return nil }
            return tweets[indexPath.row].mid
        })
        
        // Update coordinator
        videoCoordinator.updateVisibleTweets(visibleTweetIds)
    }
}
