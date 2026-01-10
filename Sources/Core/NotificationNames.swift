import Foundation
import Combine

extension Notification.Name {
    // MARK: - User Related
    /// Posted when a user's avatar changes
    static let avatarDidChange = Notification.Name("avatarDidChange")
    /// Posted when a user successfully logs in
    static let userDidLogin = Notification.Name("UserDidLogin")
    static let userDidLogout = Notification.Name("UserDidLogout")
    /// Posted when app user is ready (guest or logged-in)
    static let appUserReady = Notification.Name("AppUserReady")
    /// Posted when a user is fetched/updated from server (userId in userInfo)
    static let userDidUpdate = Notification.Name("UserDidUpdate")
    
    // MARK: - Tweet Related
    /// Posted when a new tweet is created
    static let newTweetCreated = Notification.Name("newTweetCreated")
    
    /// Posted when a tweet is successfully submitted (for UI feedback)
    static let tweetSubmitted = Notification.Name("tweetSubmitted")
    
    /// Posted when a tweet is deleted
    static let tweetDeleted = Notification.Name("tweetDeleted")
    
    /// Posted when a tweet deletion fails and needs to be restored
    static let tweetRestored = Notification.Name("TweetRestored")
    
    /// Posted when a tweet's pin status changes
    static let tweetPinStatusChanged = Notification.Name("TweetPinStatusChanged")
    
    /// Posted when a tweet's privacy status changes
    static let tweetPrivacyChanged = Notification.Name("TweetPrivacyChanged")
    
    /// Posted when a tweet's privacy status is successfully updated (for toast notification)
    static let tweetPrivacyUpdated = Notification.Name("TweetPrivacyUpdated")
    
    /// Posted when a new comment is added
    static let newCommentAdded = Notification.Name("newCommentAdded")
    static let commentDeleted = Notification.Name("commentDeleted")
    /// Posted when a comment deletion fails and needs to be restored
    static let commentRestored = Notification.Name("commentRestored")
    
    /// Posted when a tweet is bookmarked
    static let bookmarkAdded = Notification.Name("BookmarkAdded")
    /// Posted when a tweet is removed from bookmarks
    static let bookmarkRemoved = Notification.Name("BookmarkRemoved")
    /// Posted when a tweet is favorited
    static let favoriteAdded = Notification.Name("FavoriteAdded")
    /// Posted when a tweet is removed from favorites
    static let favoriteRemoved = Notification.Name("FavoriteRemoved")
    
    // MARK: - Navigation Related
    /// Posted to pop to root view
    static let popToRoot = Notification.Name("PopToRoot")
    /// Posted to scroll to top of a view
    static let scrollToTop = Notification.Name("ScrollToTop")
    /// Posted when navigation visibility changes (for scroll-based hiding/showing)
    static let navigationVisibilityChanged = Notification.Name("NavigationVisibilityChanged")
    /// Posted when a deeplink URL is received
    static let deeplinkReceived = Notification.Name("DeeplinkReceived")
    /// Posted when a deeplink tweet is not found
    static let deeplinkTweetNotFound = Notification.Name("DeeplinkTweetNotFound")
    
    // MARK: - System Errors
    static let backgroundUploadFailed = Notification.Name("backgroundUploadFailed")
    static let backgroundUploadRetrying = Notification.Name("backgroundUploadRetrying")
    static let uploadCancelled = Notification.Name("uploadCancelled")
    static let tweetPublishFailed = Notification.Name("TweetPublishFailed")
    static let tweetDeletdFailed = Notification.Name("TweetDeletdFailed")
    static let commentPublishFailed = Notification.Name("CommentPublishFailed")
    static let commentDeleteFailed = Notification.Name("CommentDeleteFailed")
    
    // MARK: - Memory Management
    /// Posted when memory usage is critically high
    static let memoryWarningCritical = Notification.Name("MemoryWarningCritical")
    
    // MARK: - Chat Related
    /// Posted when a new chat message is received
    static let newChatMessageReceived = Notification.Name("NewChatMessageReceived")
    /// Posted when a chat message is successfully sent
    static let chatMessageSent = Notification.Name("ChatMessageSent")
    /// Posted when chat message sending fails
    static let chatMessageSendFailed = Notification.Name("ChatMessageSendFailed")
    /// Posted when a chat notification is tapped to open chat screen
    static let openChatFromNotification = Notification.Name("OpenChatFromNotification")
    
    // MARK: - App Lifecycle
    /// Posted when the app becomes active (returns from background)
    static let appDidBecomeActive = Notification.Name("AppDidBecomeActive")
    /// Posted when the app startup phase has ended and deferred operations can proceed
    static let startupPhaseEnded = Notification.Name("StartupPhaseEnded")
    
    // MARK: - Cache Related
    /// Posted when all cache is cleared (manual or on signout) to trigger media reload
    static let cacheCleared = Notification.Name("CacheCleared")
    /// Posted when video infrastructure is restarted after background recovery
    static let videoInfrastructureRestarted = Notification.Name("VideoInfrastructureRestarted")
    /// Posted when an image is successfully cached (avatarId in userInfo)
    static let imageCached = Notification.Name("ImageCached")
    
    // MARK: - Video Related
    /// Posted to stop all videos in the tweet list when entering full screen
    static let stopAllVideos = Notification.Name("StopAllVideos")
    /// Posted when app content is covered/uncovered by an overlay (sheet/fullScreenCover/login/share).
    /// userInfo: ["isCovered": Bool, "activeCount": Int, "source": String?]
    static let overlayCoverageChanged = Notification.Name("OverlayCoverageChanged")
    /// Posted to force video layer refresh after screen lock recovery
    static let videoLayerRefresh = Notification.Name("VideoLayerRefresh")
    /// Posted to reload only visible videos after foreground recovery (not all videos)
    static let reloadVisibleVideosOnly = Notification.Name("ReloadVisibleVideosOnly")
    
    // MARK: - Error Handling
    /// Posted when an error occurs that should be displayed as a toast
    static let errorOccurred = Notification.Name("ErrorOccurred")
}

/// Centralized overlay coverage state for the app.
///
/// This replaces polling-based \"is content covered\" checks by providing explicit begin/end calls
/// from SwiftUI sheets/fullScreenCovers and other overlay presenters.
@MainActor
final class OverlayVisibilityCoordinator: ObservableObject {
    static let shared = OverlayVisibilityCoordinator()

    @Published private(set) var isCovered: Bool = false

    private var activeOverlayIds: Set<String> = []

    private init() {}

    func beginOverlay(id: String, source: String? = nil) {
        let inserted = activeOverlayIds.insert(id).inserted
        if inserted {
            updateIfNeeded(source: source)
        }
    }

    func endOverlay(id: String, source: String? = nil) {
        let removed = activeOverlayIds.remove(id) != nil
        if removed {
            updateIfNeeded(source: source)
        }
    }

    func reset(source: String? = nil) {
        guard !activeOverlayIds.isEmpty else { return }
        activeOverlayIds.removeAll()
        updateIfNeeded(source: source)
    }

    private func updateIfNeeded(source: String?) {
        let newCovered = !activeOverlayIds.isEmpty
        guard newCovered != isCovered else { return }
        isCovered = newCovered

        var userInfo: [AnyHashable: Any] = [
            "isCovered": newCovered,
            "activeCount": activeOverlayIds.count
        ]
        if let source {
            userInfo["source"] = source
        }

        NotificationCenter.default.post(
            name: .overlayCoverageChanged,
            object: nil,
            userInfo: userInfo
        )
    }
}
