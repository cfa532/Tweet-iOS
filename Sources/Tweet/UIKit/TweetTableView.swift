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
    
    func makeUIViewController(context: Context) -> TweetTableViewController {
        let controller = TweetTableViewController()
        
        controller.loadMoreTweets = loadMoreTweets
        controller.headerViewBuilder = header
        controller.rowViewBuilder = { tweet in
            AnyView(rowView(tweet))
        }
        
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
        uiViewController.headerViewBuilder = header
        uiViewController.rowViewBuilder = { tweet in
            AnyView(rowView(tweet))
        }
    }
}

