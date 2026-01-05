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
    let isLoading: Bool
    let loadMoreTweets: () -> Void
    let onRefresh: (() async -> Void)?  // Pull-to-refresh callback
    let onScroll: ((CGFloat, CGFloat) -> Void)?  // (offset, delta)
    let leadingPadding: CGFloat  // Leading padding for cells
    let trailingPadding: CGFloat  // Trailing padding for cells
    
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
        
        print("DEBUG: [TweetTableView] Created TweetTableViewController")
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: TweetTableViewController, context: Context) {
        print("DEBUG: [TweetTableView] updateUIViewController - tweets count: \(tweets.count)")
        
        // Update tweets
        uiViewController.updateTweets(tweets)
        
        // Update loading state
        uiViewController.updateLoadingState(
            isLoading: isLoading,
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

