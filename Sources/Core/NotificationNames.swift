import Foundation

extension Notification.Name {
    // MARK: - User Related
    /// Posted when a user successfully logs in
    static let userDidLogin = Notification.Name("UserDidLogin")
    static let userDidLogout = Notification.Name("UserDidLogout")
    
    // MARK: - Tweet Related
    /// Posted when a new tweet is created
    static let newTweetCreated = Notification.Name("NewTweetCreated")
    
    /// Posted when a tweet is deleted
    static let tweetDeleted = Notification.Name("TweetDeleted")
    
    /// Posted when a tweet deletion fails and needs to be restored
    static let tweetRestored = Notification.Name("TweetRestored")
    
    /// Posted when a tweet's pin status changes
    static let tweetPinStatusChanged = Notification.Name("TweetPinStatusChanged")
    
    /// Posted when a new comment is added
    static let newCommentAdded = Notification.Name("NewCommentAdded")
    static let commentDeleted = Notification.Name("CommentDeleted")
    
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
    
    // MARK: - System Errors
    static let backgroundUploadFailed = Notification.Name("BackgroundUploadFailed")
    static let tweetPublishFailed = Notification.Name("TweetPublishFailed")
    static let tweetDeletdFailed = Notification.Name("TweetDeletdFailed")
    static let commentPublishFailed = Notification.Name("CommentPublishFailed")
    static let commentDeleteFailed = Notification.Name("CommentDeleteFailed")
}
