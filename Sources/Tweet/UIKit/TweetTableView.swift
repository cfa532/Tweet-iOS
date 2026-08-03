//
//  TweetTableView.swift
//  Tweet
//
//  SwiftUI wrapper for UIKit TweetTableViewController.
//  No longer generic — cells are rendered entirely in UIKit.
//
import SwiftUI

struct TweetTableView: UIViewControllerRepresentable {
    struct TweetRenderKey: Equatable {
        let id: String
        let isPrivate: Bool
    }

    @Binding var tweets: [Tweet]
    let colorScheme: ColorScheme
    let isDarkMode: Bool
    let header: (() -> AnyView)?
    let headerRefreshToken: Int
    let hproseInstance: HproseInstance
    let hasMoreTweets: Bool
    let canShowNoMoreTweetsMessage: Bool
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
    /// Incremented by TweetListView's debounced memory maintenance to request a
    /// viewport-aware trim. The controller decides whether/how to trim and reports
    /// the result back via onTweetsTrimmed.
    let trimRequestToken: Int
    let trimMaxCount: Int
    let trimTargetCount: Int
    let onTweetsTrimmed: (([Tweet]) -> Void)?
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let pinnedTweets: [Tweet]
    let feedIdentifier: String
    let videoCoordinator: VideoPlaybackCoordinator
    let onAvatarTap: ((User) -> Void)?
    let onTweetTap: ((Tweet) -> Void)?
    let onShowLogin: (() -> Void)?
    let onShowToast: ((String, Bool) -> Void)?
    let onRetweetUnavailable: ((String) -> Void)?
    let allowDeleteAll: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var lastTweetRenderKeys: [TweetRenderKey] = []
        var lastPinnedTweetIds: [String] = []
        var lastHeaderWasPresent: Bool?
        var lastHeaderRefreshToken: Int?
        var lastTrimRequestToken: Int?
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
        controller.onRetweetUnavailable = onRetweetUnavailable
        controller.allowDeleteAll = allowDeleteAll
        controller.preservesScrollPositionOnPrepend = preservesScrollPositionOnPrepend
        controller.onTweetsTrimmed = onTweetsTrimmed

        controller.updateHeader()
        context.coordinator.lastHeaderWasPresent = header != nil
        context.coordinator.lastHeaderRefreshToken = headerRefreshToken
        context.coordinator.lastTrimRequestToken = trimRequestToken

        return controller
    }

    func updateUIViewController(_ uiViewController: TweetTableViewController, context: Context) {
        let coordinator = context.coordinator
        uiViewController.isDarkModeEnabled = isDarkMode
        uiViewController.preservesScrollPositionOnPrepend = preservesScrollPositionOnPrepend
        uiViewController.applyTheme()

        // Update when row identity or render-affecting state changes.
        let currentTweetRenderKeys = tweets.map {
            TweetRenderKey(id: $0.mid, isPrivate: $0.isPrivate == true)
        }
        let previousTweetRenderKeys = coordinator.lastTweetRenderKeys
        if coordinator.lastTweetRenderKeys != currentTweetRenderKeys {
            coordinator.lastTweetRenderKeys = currentTweetRenderKeys
            let sameTweetIds = previousTweetRenderKeys.map(\.id) == currentTweetRenderKeys.map(\.id)
            uiViewController.updateTweets(tweets, reloadSameOrderRows: sameTweetIds)
        }

        // Only update pinned tweets if they actually changed
        let currentPinnedTweetIds = pinnedTweets.map { $0.mid }
        let pinnedVisibilityChanged = coordinator.lastPinnedTweetIds.isEmpty != currentPinnedTweetIds.isEmpty
        if coordinator.lastPinnedTweetIds != currentPinnedTweetIds {
            coordinator.lastPinnedTweetIds = currentPinnedTweetIds
            uiViewController.updatePinnedTweets(pinnedTweets)
        }

        // Update loading state
        uiViewController.updateLoadingState(
            isLoading: isLoading,
            isLoadingMore: isLoadingMore,
            hasMoreTweets: hasMoreTweets,
            canShowNoMoreTweetsMessage: canShowNoMoreTweetsMessage
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
        uiViewController.onRetweetUnavailable = onRetweetUnavailable
        uiViewController.allowDeleteAll = allowDeleteAll
        uiViewController.onTweetsTrimmed = onTweetsTrimmed

        if coordinator.lastTrimRequestToken != trimRequestToken {
            coordinator.lastTrimRequestToken = trimRequestToken
            uiViewController.trimTweetsIfOverCapacity(maxCount: trimMaxCount, targetCount: trimTargetCount)
        }

        // Only rebuild the hosted header when its presence changes. The hosted
        // SwiftUI view continues to observe its own model changes; reassigning it
        // on every wrapper update causes expensive sizeThatFits/layout work while scrolling.
        let headerChanged = (header != nil) != (uiViewController.headerViewBuilder != nil)
        let headerRefreshChanged = coordinator.lastHeaderRefreshToken != headerRefreshToken
        uiViewController.headerViewBuilder = header
        if headerChanged || headerRefreshChanged || pinnedVisibilityChanged || coordinator.lastHeaderWasPresent != (header != nil) {
            coordinator.lastHeaderWasPresent = header != nil
            coordinator.lastHeaderRefreshToken = headerRefreshToken
            uiViewController.updateHeader()
        }
    }
}
