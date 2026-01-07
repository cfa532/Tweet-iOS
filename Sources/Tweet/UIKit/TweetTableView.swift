//
//  TweetTableView.swift
//  Tweet
//
//  SwiftUI wrapper for UIKit TweetTableViewController
//  Provides SwiftUI interface while using UIKit's efficient UITableView
//
import SwiftUI

struct TweetTableView<RowView: View>: UIViewControllerRepresentable {
    @Binding var tweets: [Tweet]
    let header: (() -> AnyView)?
    let rowView: (Tweet) -> RowView
    @Binding var hasMoreTweets: Bool
    let isLoadingMore: Bool
    let loadMoreTweets: (Bool) -> Void  // Parameter: forceLoad
    let onRefresh: (() async -> Void)?  // Pull-to-refresh callback
    let onScroll: ((CGFloat, CGFloat) -> Void)?  // (offset, delta)
    let leadingPadding: CGFloat  // Leading padding for cells
    let trailingPadding: CGFloat  // Trailing padding for cells
    let pinnedTweets: [Tweet]  // Pinned tweets for video coordination and visibility
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var lastTweetIds: [String] = []
        var lastPinnedTweetIds: [String] = []
    }
    
    func makeUIViewController(context: Context) -> TweetTableViewController {
        let controller = TweetTableViewController()
        
        controller.loadMoreTweets = loadMoreTweets
        controller.onRefresh = onRefresh
        controller.onScroll = onScroll
        controller.leadingPadding = leadingPadding
        controller.trailingPadding = trailingPadding
        controller.headerViewBuilder = header
        controller.rowViewBuilder = { tweet in
            AnyView(rowView(tweet))
        }
        
        // Set up header if present
        controller.updateHeader()
        
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: TweetTableViewController, context: Context) {
        let coordinator = context.coordinator
        
        // Only update tweets if they actually changed (compare IDs for efficiency)
        let currentTweetIds = tweets.map { $0.mid }
        if coordinator.lastTweetIds != currentTweetIds {
            coordinator.lastTweetIds = currentTweetIds
            uiViewController.updateTweets(tweets)
        }
        
        // Only update pinned tweets if they actually changed (compare IDs for efficiency)
        let currentPinnedTweetIds = pinnedTweets.map { $0.mid }
        if coordinator.lastPinnedTweetIds != currentPinnedTweetIds {
            coordinator.lastPinnedTweetIds = currentPinnedTweetIds
            uiViewController.updatePinnedTweets(pinnedTweets)
        }
        
        // Update loading state
        uiViewController.updateLoadingState(
            isLoadingMore: isLoadingMore,
            hasMoreTweets: hasMoreTweets
        )
        
        // Update callbacks
        uiViewController.loadMoreTweets = loadMoreTweets
        uiViewController.onRefresh = onRefresh
        uiViewController.onScroll = onScroll
        uiViewController.leadingPadding = leadingPadding
        uiViewController.trailingPadding = trailingPadding
        uiViewController.headerViewBuilder = header
        uiViewController.rowViewBuilder = { tweet in
            AnyView(rowView(tweet))
        }
        
        // Update header view
        uiViewController.updateHeader()
    }
}

