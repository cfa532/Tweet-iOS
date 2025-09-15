import Foundation

extension Notification.Name {
    // MARK: - User Related
    /// Posted when a user successfully logs in
    static let userDidLogin = Notification.Name("UserDidLogin")
    static let userDidLogout = Notification.Name("UserDidLogout")
    /// Posted when app user is ready (guest or logged-in)
    static let appUserReady = Notification.Name("AppUserReady")
    
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
    
    // MARK: - System Errors
    static let backgroundUploadFailed = Notification.Name("backgroundUploadFailed")
    static let tweetPublishFailed = Notification.Name("TweetPublishFailed")
    static let tweetDeletdFailed = Notification.Name("TweetDeletdFailed")
    static let commentPublishFailed = Notification.Name("CommentPublishFailed")
    static let commentDeleteFailed = Notification.Name("CommentDeleteFailed")
    
    // MARK: - Chat Related
    /// Posted when a new chat message is received
    static let newChatMessageReceived = Notification.Name("NewChatMessageReceived")
    /// Posted when chat message sending fails
    static let chatMessageSendFailed = Notification.Name("ChatMessageSendFailed")
    /// Posted when a chat notification is tapped to open chat screen
    static let openChatFromNotification = Notification.Name("OpenChatFromNotification")
    
    // MARK: - App Lifecycle
    /// Posted when the app becomes active (returns from background)
    static let appDidBecomeActive = Notification.Name("AppDidBecomeActive")
    
    // MARK: - Video Related
    /// Posted to stop all videos in the tweet list when entering full screen
    static let stopAllVideos = Notification.Name("StopAllVideos")
    
    // MARK: - Error Handling
    /// Posted when an error occurs that should be displayed as a toast
    static let errorOccurred = Notification.Name("ErrorOccurred")
}
