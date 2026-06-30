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
    let colorScheme: ColorScheme
    let isDarkMode: Bool
    let header: (() -> AnyView)?
    let headerRefreshToken: Int
    let hproseInstance: HproseInstance
    @Binding var hasMoreTweets: Bool
    let isLoading: Bool
    let isLoadingMore: Bool
    /// True for the long-lived main feed, where new tweets must NOT move the user's
    /// scroll position. False for bounded feeds (profile/list/bookmarks) where freshly
    /// prepended tweets should be brought to the top so the user sees them.
    let preservesScrollPositionOnPrepend: Bool
    let loadMoreTweets: (Bool) -> Void  // Parameter: forceLoad
    let onRefresh: (() async -> Void)?
    let onScroll: ((CGFloat, CGFloat) -> Void)?
    let onScrollStateChange: ((CGFloat, Bool, Bool) -> Void)?
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let pinnedTweets: [Tweet]
    let feedIdentifier: String
    let videoCoordinator: VideoPlaybackCoordinator
    let onAvatarTap: ((User) -> Void)?
    let onTweetTap: ((Tweet) -> Void)?
    let onShowLogin: (() -> Void)?
    let onShowToast: ((String, Bool) -> Void)?
    let allowDeleteAll: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var lastTweetIds: [String] = []
        var lastPinnedTweetIds: [String] = []
        var lastHeaderWasPresent: Bool?
        var lastHeaderRefreshToken: Int?
        weak var controller: TweetTableViewController?

        @MainActor
        func triggerLoadMore() {
            controller?.triggerLoadMore()
        }

        @MainActor
        func showNoMoreTweetsMessage() {
            controller?.showNoMoreTweetsMessageIfNeeded()
        }
    }

    func makeUIViewController(context: Context) -> TweetTableViewController {
        let controller = TweetTableViewController(videoCoordinator: videoCoordinator)

        context.coordinator.controller = controller

        controller.loadMoreTweets = loadMoreTweets
        controller.onRefresh = onRefresh
        controller.onScroll = onScroll
        controller.onScrollStateChange = onScrollStateChange
        controller.leadingPadding = leadingPadding
        controller.trailingPadding = trailingPadding
        controller.feedIdentifier = feedIdentifier
        controller.isDarkModeEnabled = isDarkMode
        controller.headerViewBuilder = header

        // UIKit cell configuration
        controller.hproseInstance = hproseInstance
        controller.onAvatarTap = onAvatarTap
        controller.onTweetTap = onTweetTap
        controller.onShowLogin = onShowLogin
        controller.onShowToast = onShowToast
        controller.allowDeleteAll = allowDeleteAll
        controller.preservesScrollPositionOnPrepend = preservesScrollPositionOnPrepend

        controller.updateHeader()
        context.coordinator.lastHeaderWasPresent = header != nil
        context.coordinator.lastHeaderRefreshToken = headerRefreshToken

        return controller
    }

    func updateUIViewController(_ uiViewController: TweetTableViewController, context: Context) {
        let coordinator = context.coordinator
        uiViewController.isDarkModeEnabled = isDarkMode
        uiViewController.preservesScrollPositionOnPrepend = preservesScrollPositionOnPrepend
        uiViewController.applyTheme()

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
            isLoading: isLoading,
            isLoadingMore: isLoadingMore,
            hasMoreTweets: hasMoreTweets
        )

        // Update callbacks
        uiViewController.loadMoreTweets = loadMoreTweets
        uiViewController.onRefresh = onRefresh
        uiViewController.onScroll = onScroll
        uiViewController.onScrollStateChange = onScrollStateChange
        uiViewController.leadingPadding = leadingPadding
        uiViewController.trailingPadding = trailingPadding
        uiViewController.feedIdentifier = feedIdentifier

        // UIKit cell configuration
        uiViewController.hproseInstance = hproseInstance
        uiViewController.onAvatarTap = onAvatarTap
        uiViewController.onTweetTap = onTweetTap
        uiViewController.onShowLogin = onShowLogin
        uiViewController.onShowToast = onShowToast
        uiViewController.allowDeleteAll = allowDeleteAll

        // Only rebuild the hosted header when its presence changes. The hosted
        // SwiftUI view continues to observe its own model changes; reassigning it
        // on every wrapper update causes expensive sizeThatFits/layout work while scrolling.
        let headerChanged = (header != nil) != (uiViewController.headerViewBuilder != nil)
        let headerRefreshChanged = coordinator.lastHeaderRefreshToken != headerRefreshToken
        uiViewController.headerViewBuilder = header
        if headerChanged || headerRefreshChanged || coordinator.lastHeaderWasPresent != (header != nil) {
            coordinator.lastHeaderWasPresent = header != nil
            coordinator.lastHeaderRefreshToken = headerRefreshToken
            uiViewController.updateHeader()
        }
    }
}
