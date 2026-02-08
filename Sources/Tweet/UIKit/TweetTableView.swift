//
//  TweetTableView.swift
//  Tweet
//
//  SwiftUI wrapper for UIKit TweetTableViewController.
//  No longer generic — cells are rendered entirely in UIKit.
//
import SwiftUI

struct TweetTableView: UIViewControllerRepresentable {
    @Binding var tweets: [Tweet]
    let header: (() -> AnyView)?
    let hproseInstance: HproseInstance
    @Binding var hasMoreTweets: Bool
    let isLoadingMore: Bool
    let loadMoreTweets: (Bool) -> Void  // Parameter: forceLoad
    let onRefresh: (() async -> Void)?
    let onScroll: ((CGFloat, CGFloat) -> Void)?
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let pinnedTweets: [Tweet]
    let feedIdentifier: String
    let onAvatarTap: ((User) -> Void)?
    let onTweetTap: ((Tweet) -> Void)?
    let onShowLogin: (() -> Void)?
    let onShowToast: ((String, Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var lastTweetIds: [String] = []
        var lastPinnedTweetIds: [String] = []
        weak var controller: TweetTableViewController?

        func triggerLoadMore() {
            controller?.triggerLoadMore()
        }

        func showNoMoreTweetsMessage() {
            controller?.showNoMoreTweetsMessageIfNeeded()
        }
    }

    func makeUIViewController(context: Context) -> TweetTableViewController {
        let controller = TweetTableViewController()

        context.coordinator.controller = controller

        controller.loadMoreTweets = loadMoreTweets
        controller.onRefresh = onRefresh
        controller.onScroll = onScroll
        controller.leadingPadding = leadingPadding
        controller.trailingPadding = trailingPadding
        controller.feedIdentifier = feedIdentifier
        controller.headerViewBuilder = header

        // UIKit cell configuration
        controller.hproseInstance = hproseInstance
        controller.onAvatarTap = onAvatarTap
        controller.onTweetTap = onTweetTap
        controller.onShowLogin = onShowLogin
        controller.onShowToast = onShowToast

        controller.updateHeader()

        return controller
    }

    func updateUIViewController(_ uiViewController: TweetTableViewController, context: Context) {
        let coordinator = context.coordinator

        // Only update tweets if they actually changed
        let currentTweetIds = tweets.map { $0.mid }
        if coordinator.lastTweetIds != currentTweetIds {
            coordinator.lastTweetIds = currentTweetIds
            uiViewController.updateTweets(tweets)
        }

        // Only update pinned tweets if they actually changed
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
        uiViewController.feedIdentifier = feedIdentifier
        uiViewController.headerViewBuilder = header

        // UIKit cell configuration
        uiViewController.hproseInstance = hproseInstance
        uiViewController.onAvatarTap = onAvatarTap
        uiViewController.onTweetTap = onTweetTap
        uiViewController.onShowLogin = onShowLogin
        uiViewController.onShowToast = onShowToast

        uiViewController.updateHeader()
    }
}
