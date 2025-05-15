import Foundation

struct Tweet: Identifiable, Codable {
    let id: String
    let content: String
    let author: User
    let createdAt: Date
    let likes: Int
    let retweets: Int
    let comments: Int
    var isLiked: Bool
    var isRetweeted: Bool
    
    enum CodingKeys: String, CodingKey {
        case id
        case content
        case author
        case createdAt = "created_at"
        case likes
        case retweets
        case comments
        case isLiked = "is_liked"
        case isRetweeted = "is_retweeted"
    }
}

struct User: Identifiable, Codable {
    let id: String
    let username: String
    let displayName: String
    let avatarUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
    }
} 