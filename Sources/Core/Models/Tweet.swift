import Foundation

struct Tweet: Identifiable, Codable {
    var id: String { mid }  // Computed property that returns mid
    var mid: String
    let authorId: String // mid of the author
    var content: String?
    var timestamp: Date
    var title: String?
    
    var originalTweetId: String? // retweet id of the original tweet
    var originalAuthorId: String? // authorId of the forwarded tweet
    
    // Display only properties
    var author: User?
    var originalTweet: Tweet? { nil } // Computed property to avoid recursive reference
    
    // User interaction flags
    var favorites: [Bool]? // [liked, bookmarked, retweeted]
    var favoriteCount: Int
    var bookmarkCount: Int
    var retweetCount: Int
    var commentCount: Int
    
    // Media attachments
    var attachments: [MimeiFileType]?
    var isPrivate: Bool
    var downloadable: Bool?
    
    // Computed properties for user interaction states
    var isLiked: Bool {
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
        case originalTweet
        case favorites
        case favoriteCount
        case bookmarkCount
        case retweetCount
        case commentCount
        case attachments
        case isPrivate
        case downloadable
    }
    
    init(from decoder: Decoder) throws {
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
        favoriteCount = try container.decode(Int.self, forKey: .favoriteCount)
        bookmarkCount = try container.decode(Int.self, forKey: .bookmarkCount)
        retweetCount = try container.decode(Int.self, forKey: .retweetCount)
        commentCount = try container.decode(Int.self, forKey: .commentCount)
        attachments = try container.decodeIfPresent([MimeiFileType].self, forKey: .attachments)
        isPrivate = try container.decode(Bool.self, forKey: .isPrivate)
        downloadable = try container.decodeIfPresent(Bool.self, forKey: .downloadable)
    }
    
    init(mid: String, authorId: String, content: String? = nil, timestamp: Date = Date(), title: String? = nil,
         originalTweetId: String? = nil, originalAuthorId: String? = nil, author: User? = nil,
         favorites: [Bool]? = [false, false, false], favoriteCount: Int = 0, bookmarkCount: Int = 0, retweetCount: Int = 0,
         commentCount: Int = 0, attachments: [MimeiFileType]? = nil, isPrivate: Bool = false,
         downloadable: Bool? = false) {
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
        try container.encode(favoriteCount, forKey: .favoriteCount)
        try container.encode(bookmarkCount, forKey: .bookmarkCount)
        try container.encode(retweetCount, forKey: .retweetCount)
        try container.encode(commentCount, forKey: .commentCount)
        try container.encodeIfPresent(attachments, forKey: .attachments)
        try container.encode(isPrivate, forKey: .isPrivate)
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
}
