import Foundation

class Tweet: Identifiable, Codable, ObservableObject {
    var id: String { mid }  // Computed property that returns mid
    var mid: String
    let authorId: String // mid of the author
    var content: String?
    var timestamp: Date = Date()
    var title: String?
    
    var originalTweetId: String? // retweet id of the original tweet
    var originalAuthorId: String? // authorId of the forwarded tweet
    
    // Display only properties
    var author: User?
    
    // User interaction flags
    @Published var favorites: [Bool]? // [favorite, bookmark, retweeted]
    @Published var favoriteCount: Int?
    @Published var bookmarkCount: Int?
    @Published var retweetCount: Int?
    @Published var commentCount: Int?
    
    // Media attachments
    var attachments: [MimeiFileType]?
    var isPrivate: Bool?
    var downloadable: Bool?
    
    // Computed properties for user interaction states
    var isFavorite: Bool {
        get { favorites?[0] ?? false }
        set {
            if favorites == nil {
                favorites = [false, false, false]
            }
            favorites?[0] = newValue
        }
    }
    
    var isBookmarked: Bool {
        get { favorites?[1] ?? false }
        set {
            if favorites == nil {
                favorites = [false, false, false]
            }
            favorites?[1] = newValue
        }
    }
    
    var isRetweeted: Bool {
        get { favorites?[2] ?? false }
        set {
            if favorites == nil {
                favorites = [false, false, false]
            }
            favorites?[2] = newValue
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case mid
        case authorId
        case content
        case timestamp
        case title
        case originalTweetId
        case originalAuthorId
        case author
        case favorites
        case favoriteCount
        case bookmarkCount
        case retweetCount
        case commentCount
        case attachments
        case isPrivate
        case downloadable
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mid = try container.decode(String.self, forKey: .mid)
        authorId = try container.decode(String.self, forKey: .authorId)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        originalTweetId = try container.decodeIfPresent(String.self, forKey: .originalTweetId)
        originalAuthorId = try container.decodeIfPresent(String.self, forKey: .originalAuthorId)
        author = try container.decodeIfPresent(User.self, forKey: .author)
        favorites = try container.decodeIfPresent([Bool].self, forKey: .favorites)
        favoriteCount = try container.decodeIfPresent(Int.self, forKey: .favoriteCount)
        bookmarkCount = try container.decodeIfPresent(Int.self, forKey: .bookmarkCount)
        retweetCount = try container.decodeIfPresent(Int.self, forKey: .retweetCount)
        commentCount = try container.decodeIfPresent(Int.self, forKey: .commentCount)
        attachments = try container.decodeIfPresent([MimeiFileType].self, forKey: .attachments)
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate)
        downloadable = try container.decodeIfPresent(Bool.self, forKey: .downloadable)
    }
    
    init(mid: String, authorId: String, content: String? = nil, timestamp: Date = Date(), title: String? = nil,
         originalTweetId: String? = nil, originalAuthorId: String? = nil, author: User? = nil,
         favorites: [Bool]? = [false, false, false], favoriteCount: Int = 0, bookmarkCount: Int = 0, retweetCount: Int = 0,
         commentCount: Int = 0, attachments: [MimeiFileType]? = nil, isPrivate: Bool? = nil,
         downloadable: Bool? = nil) {
        self.mid = mid
        self.authorId = authorId
        self.content = content
        self.timestamp = timestamp
        self.title = title
        self.originalTweetId = originalTweetId
        self.originalAuthorId = originalAuthorId
        self.author = author
        self.favorites = favorites
        self.favoriteCount = favoriteCount
        self.bookmarkCount = bookmarkCount
        self.retweetCount = retweetCount
        self.commentCount = commentCount
        self.attachments = attachments
        self.isPrivate = isPrivate
        self.downloadable = downloadable
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mid, forKey: .mid)
        try container.encode(authorId, forKey: .authorId)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(originalTweetId, forKey: .originalTweetId)
        try container.encodeIfPresent(originalAuthorId, forKey: .originalAuthorId)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encodeIfPresent(favorites, forKey: .favorites)
        try container.encodeIfPresent(favoriteCount, forKey: .favoriteCount)
        try container.encodeIfPresent(bookmarkCount, forKey: .bookmarkCount)
        try container.encodeIfPresent(retweetCount, forKey: .retweetCount)
        try container.encodeIfPresent(commentCount, forKey: .commentCount)
        try container.encodeIfPresent(attachments, forKey: .attachments)
        try container.encodeIfPresent(isPrivate, forKey: .isPrivate)
        try container.encodeIfPresent(downloadable, forKey: .downloadable)
    }
    
    // MARK: - Factory Methods
    
    /// Creates a Tweet from a dictionary returned by the network call
    /// - Parameter dict: Dictionary containing tweet data
    /// - Returns: A Tweet object if successful, nil if conversion fails
    static func from(dict: [String: Any]) -> Tweet? {
        do {
            // Create a new dictionary with validated fields and proper mapping
            var validatedDict = dict
            
            // Convert timestamp from string to Date
            if let timestampStr = dict["timestamp"] as? String,
               let timestampMillis = Double(timestampStr) {
                // Update the dictionary with the timestamp in milliseconds
                validatedDict["timestamp"] = timestampMillis
            }
            
            // Convert dictionary to JSON data
            let jsonData = try JSONSerialization.data(withJSONObject: validatedDict, options: [])
            
            // Decode the JSON data into a Tweet object
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            
            return try decoder.decode(Tweet.self, from: jsonData)
        } catch {
            print("Error converting dictionary to Tweet: \(error)")
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .keyNotFound(let key, let context):
                    print("Missing key: \(key.stringValue), context: \(context.debugDescription)")
                case .typeMismatch(let type, let context):
                    print("Type mismatch: expected \(type), context: \(context.debugDescription)")
                case .valueNotFound(let type, let context):
                    print("Value not found: expected \(type), context: \(context.debugDescription)")
                case .dataCorrupted(let context):
                    print("Data corrupted: \(context.debugDescription)")
                @unknown default:
                    print("Unknown decoding error")
                }
            }
            return nil
        }
    }
    
    /// Creates a copy of the tweet with updated attributes
    /// - Parameters:
    ///   - content: New content for the tweet
    ///   - title: New title for the tweet
    ///   - author: New author for the tweet
    ///   - favorites: New favorites array
    ///   - favoriteCount: New favorite count
    ///   - bookmarkCount: New bookmark count
    ///   - retweetCount: New retweet count
    ///   - commentCount: New comment count
    ///   - attachments: New attachments array
    ///   - isPrivate: New privacy setting
    ///   - downloadable: New downloadability setting
    /// - Returns: A new Tweet instance with the updated values
    func copy(
        content: String? = nil,
        title: String? = nil,
        author: User? = nil,
        favorites: [Bool]? = nil,
        favoriteCount: Int? = nil,
        bookmarkCount: Int? = nil,
        retweetCount: Int? = nil,
        commentCount: Int? = nil,
        attachments: [MimeiFileType]? = nil,
        isPrivate: Bool? = nil,
        downloadable: Bool? = nil
    ) -> Tweet {
        var copy = self
        if let content = content { copy.content = content }
        if let title = title { copy.title = title }
        if let author = author { copy.author = author }
        if let favorites = favorites { copy.favorites = favorites }
        if let favoriteCount = favoriteCount { copy.favoriteCount = favoriteCount }
        if let bookmarkCount = bookmarkCount { copy.bookmarkCount = bookmarkCount }
        if let retweetCount = retweetCount { copy.retweetCount = retweetCount }
        if let commentCount = commentCount { copy.commentCount = commentCount }
        if let attachments = attachments { copy.attachments = attachments }
        if let isPrivate = isPrivate { copy.isPrivate = isPrivate }
        if let downloadable = downloadable { copy.downloadable = downloadable }
        return copy
    }
    
    /// Checks if this tweet is pinned based on a list of pinned tweets
    /// - Parameter pinnedTweets: List of pinned tweets with their pin timestamps
    /// - Returns: True if the tweet is pinned, false otherwise
    func isPinned(in pinnedTweets: [[String: Any]]) -> Bool {
        return pinnedTweets.contains { dict in
            if let pinnedTweet = dict["tweet"] as? Tweet {
                return pinnedTweet.mid == self.mid
            }
            return false
        }
    }
}
