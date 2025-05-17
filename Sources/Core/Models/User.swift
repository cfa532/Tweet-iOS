import Foundation

struct User: Codable, Identifiable, Hashable {
    var id: String { mid }  // Computed property that returns mid
    var mid: String
    var baseUrl: String?
    var writableUrl: String?
    var name: String?
    var username: String?
    var password: String?
    var avatar: String? // MimeiId
    var email: String?
    var profile: String?
    var timestamp: Date
    var lastLogin: Date?
    var cloudDrivePort: Int?
    
    var tweetCount: Int
    var followingCount: Int?
    var followersCount: Int?
    var bookmarksCount: Int?
    var favoritesCount: Int?
    var commentsCount: Int?
    
    var hostIds: [String]? // List of MimeiId
    var publicKey: String?
    
    var fansList: [String]? // List of MimeiId
    var followingList: [String]? // List of MimeiId
    var bookmarkedTweets: [String]? // List of MimeiId
    var favoriteTweets: [String]? // List of MimeiId
    var repliedTweets: [String]? // List of MimeiId
    var commentsList: [String]? // List of MimeiId
    var topTweets: [String]? // List of MimeiId
    
    init(mid: String = Constants.GUEST_ID, baseUrl: String? = nil) {
        self.mid = mid
        self.baseUrl = baseUrl
        self.timestamp = Date()
        self.tweetCount = 0
    }
    
    var isGuest: Bool {
        return mid == Constants.GUEST_ID
    }
    
    func copy(baseUrl: String? = nil, followingList: [String]? = nil) -> User {
        var copy = self
        if let baseUrl = baseUrl {
            copy.baseUrl = baseUrl
        }
        if let followingList = followingList {
            copy.followingList = followingList
        }
        return copy
    }
}

enum Constants {
    static let GUEST_ID = "000000000000000000000000000"
} 
