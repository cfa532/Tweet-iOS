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
    var rowViewBuilder: ((Tweet) -> AnyView)?
    var headerViewBuilder: (() -> AnyView)?
    var onScroll: ((CGFloat, CGFloat) -> Void)?  // (offset, delta)
    
    // Header hosting controller
    private var headerHostingController: UIHostingController<AnyView>?
    
    // Refresh control
    private var customRefreshControl: UIRefreshControl?
    
    // Video playback coordinator
    private let videoCoordinator = VideoPlaybackCoordinator.shared
    
    // Scroll tracking for toolbar hiding
    private var lastScrollOffset: CGFloat = 0
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupTableView()
        setupRefreshControl()
        
        print("DEBUG: [TweetTableViewController] viewDidLoad - delegate is set to self")
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
        
        print("DEBUG: [TweetTableViewController] Table view configured - delegate: \(String(describing: tableView.delegate))")
    }
    
    private func setupRefreshControl() {
        customRefreshControl = UIRefreshControl()
        customRefreshControl?.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        tableView.refreshControl = customRefreshControl
    }
    
    @objc private func handleRefresh() {
        // Trigger refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.customRefreshControl?.endRefreshing()
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
                parentViewController: self
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
    
    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let headerBuilder = headerViewBuilder else { return nil }
        
        if headerHostingController == nil {
            let headerView = headerBuilder()
            let hostingController = UIHostingController(rootView: headerView)
            hostingController.view.backgroundColor = .clear
            self.headerHostingController = hostingController
            addChild(hostingController)
            hostingController.didMove(toParent: self)
        }
        
        return headerHostingController?.view
    }
    
    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return headerViewBuilder != nil ? UITableView.automaticDimension : 0
    }
    
    override func tableView(_ tableView: UITableView, estimatedHeightForHeaderInSection section: Int) -> CGFloat {
        return headerViewBuilder != nil ? 100 : 0
    }
    
    // MARK: - UIScrollViewDelegate
    
    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Update visible tweets for video playback coordination
        updateVisibleTweetsForVideoPlayback()
        
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
