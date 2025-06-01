import Foundation

extension Notification.Name {
    // MARK: - User Related
    /// Posted when a user successfully logs in
    static let userDidLogin = Notification.Name("UserDidLogin")
    
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
    
    // MARK: - Navigation Related
    /// Posted to pop to root view
    static let popToRoot = Notification.Name("PopToRoot")
} 
