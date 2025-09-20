import Foundation

class Tweet: Identifiable, Codable, ObservableObject {
    // MARK: - Singleton
    private static var instances: [MimeiId: Tweet] = [:]
    private static let instanceLock = NSLock()
    
    private static func getInstance(mid: MimeiId, authorId: MimeiId, content: String? = nil, timestamp: Date = Date(timeIntervalSince1970: Date().timeIntervalSince1970), title: String? = nil,
                          originalTweetId: MimeiId? = nil, originalAuthorId: MimeiId? = nil, author: User? = nil,
                          favorites: [Bool]? = [false, false, false], favoriteCount: Int = 0, bookmarkCount: Int = 0, retweetCount: Int = 0,
                          commentCount: Int = 0, attachments: [MimeiFileType]? = nil, isPrivate: Bool? = nil,
                          downloadable: Bool? = nil) -> Tweet {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        
        if let existingInstance = instances[mid] {
            // Update existing instance with new values
            if let content = content { existingInstance.content = content }
            if let title = title { existingInstance.title = title }
            if let author = author { existingInstance.author = author }
            if let favorites = favorites { existingInstance.favorites = favorites }
            existingInstance.favoriteCount = favoriteCount
            existingInstance.bookmarkCount = bookmarkCount
            existingInstance.retweetCount = retweetCount
            existingInstance.commentCount = commentCount
            if let attachments = attachments { existingInstance.attachments = attachments }
            if let isPrivate = isPrivate { existingInstance.isPrivate = isPrivate }
            if let downloadable = downloadable { existingInstance.downloadable = downloadable }
            return existingInstance
        }
        
        let newInstance = Tweet(mid: mid, authorId: authorId, content: content, timestamp: timestamp, title: title,
                              originalTweetId: originalTweetId, originalAuthorId: originalAuthorId, author: author,
                              favorites: favorites, favoriteCount: favoriteCount, bookmarkCount: bookmarkCount,
                              retweetCount: retweetCount, commentCount: commentCount, attachments: attachments,
                              isPrivate: isPrivate, downloadable: downloadable)
        instances[mid] = newInstance
        return newInstance
    }
    
    static func clearInstance(mid: MimeiId) {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        instances.removeValue(forKey: mid)
    }
    
    static func clearAllInstances() {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        instances.removeAll()
    }
    
    // MARK: - Properties
    var id: String { mid }  // Computed property that returns mid
    var mid: MimeiId
    let authorId: MimeiId // mid of the author
    var content: String?
    var timestamp: Date = Date(timeIntervalSince1970: Date().timeIntervalSince1970)
    var title: String?
    
    var originalTweetId: MimeiId? // retweet id of the original tweet
    var originalAuthorId: MimeiId? // authorId of the forwarded tweet
        
    // Media attachments
    var attachments: [MimeiFileType]?
    var isPrivate: Bool?
    var downloadable: Bool?

    // Display only properties
    var author: User?
    
    // User interaction flags
    @Published var favorites: [Bool]? // [favorite, bookmark, retweeted]
    @Published var favoriteCount: Int?
    @Published var bookmarkCount: Int?
    @Published var retweetCount: Int?
    @Published var commentCount: Int?
    @Published var isVisible: Bool = false  // Track visibility state
    
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
    
    init(mid: MimeiId, authorId: MimeiId, content: String? = nil, timestamp: Date = Date(timeIntervalSince1970: Date().timeIntervalSince1970), title: String? = nil,
         originalTweetId: MimeiId? = nil, originalAuthorId: MimeiId? = nil, author: User? = nil,
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
    
    /// Updates the tweet instance with values from another tweet
    /// - Parameter other: Tweet object containing the new values
    /// - Throws: DecodingError if the update fails
    func update(from other: Tweet) throws {
        // Update all properties except author
        if let content = other.content { self.content = content }
        if let title = other.title { self.title = title }
        if let favorites = other.favorites { self.favorites = favorites }
        self.favoriteCount = other.favoriteCount
        self.bookmarkCount = other.bookmarkCount
        self.retweetCount = other.retweetCount
        self.commentCount = other.commentCount
        if let attachments = other.attachments { self.attachments = attachments }
        if let isPrivate = other.isPrivate { self.isPrivate = isPrivate }
        if let downloadable = other.downloadable { self.downloadable = downloadable }
        self.timestamp = other.timestamp
    }
    
    /// Updates the tweet instance with values from a dictionary
    /// - Parameter dict: Dictionary containing tweet data
    /// - Throws: DecodingError if the dictionary cannot be converted to a Tweet
    func update(from dict: [String: Any]) throws {
        do {
            // Create a new dictionary with validated fields and proper mapping
            var validatedDict = dict
            
            // Convert timestamp from string to Date
            if let timestampStr = dict["timestamp"] as? String {
                
                // Try different timestamp formats
                var timestampMillis: Double?
                
                // First try: direct conversion (milliseconds since epoch)
                if let millis = Double(timestampStr) {
                    timestampMillis = millis
                }
                // Second try: seconds since epoch (convert to milliseconds)
                // Only treat as seconds if the value is small (less than 1e10, which is year 2286)
                else if let seconds = Double(timestampStr), seconds < 1e10 {
                    timestampMillis = seconds * 1000
                }
                // Third try: ISO 8601 date string
                else {
                    let formatter = ISO8601DateFormatter()
                    if let date = formatter.date(from: timestampStr) {
                        timestampMillis = date.timeIntervalSince1970 * 1000
                    }
                }
                
                if let millis = timestampMillis {
                    validatedDict["timestamp"] = millis
                } else {
                    // Use current time as fallback instead of epoch
                    validatedDict["timestamp"] = Date().timeIntervalSince1970 * 1000
                }
            } else if let timestampNum = dict["timestamp"] as? Double {
                // Server returns timestamp as double (in milliseconds)
                if timestampNum > 0 {
                    validatedDict["timestamp"] = timestampNum
                } else {
                    // Use current time as fallback
                    validatedDict["timestamp"] = Date().timeIntervalSince1970 * 1000
                }
            } else if let timestampNum = dict["timestamp"] as? Int {
                // Timestamp is an integer (in milliseconds)
                if timestampNum > 0 {
                    validatedDict["timestamp"] = Double(timestampNum)
                } else {
                    // Use current time as fallback
                    validatedDict["timestamp"] = Date().timeIntervalSince1970 * 1000
                }
            } else {
                // Use current time as fallback
                validatedDict["timestamp"] = Date().timeIntervalSince1970 * 1000
            }
            
            // Convert dictionary to JSON data
            let jsonData = try JSONSerialization.data(withJSONObject: validatedDict, options: [])
            
            // Decode the JSON data into a temporary Tweet object
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            
            let tempTweet = try decoder.decode(Tweet.self, from: jsonData)
            

            
            // Update this instance with the new values
            if let content = tempTweet.content { self.content = content }
            if let title = tempTweet.title { self.title = title }
            if let author = tempTweet.author { self.author = author }
            if let favorites = tempTweet.favorites { self.favorites = favorites }
            self.favoriteCount = tempTweet.favoriteCount
            self.bookmarkCount = tempTweet.bookmarkCount
            self.retweetCount = tempTweet.retweetCount
            self.commentCount = tempTweet.commentCount
            if let attachments = tempTweet.attachments { self.attachments = attachments }
            if let isPrivate = tempTweet.isPrivate { self.isPrivate = isPrivate }
            if let downloadable = tempTweet.downloadable { self.downloadable = downloadable }
            self.timestamp = tempTweet.timestamp
        } catch {
            print("Error updating tweet from dictionary: \(error)")
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
            throw error
        }
    }
    
    /// Creates a Tweet from a dictionary returned by the network call
    /// - Parameter dict: Dictionary containing tweet data
    /// - Returns: A Tweet object if successful
    /// - Throws: DecodingError if the dictionary cannot be converted to a Tweet
    static func from(dict: [String: Any]) throws -> Tweet {
        do {
            // Create a new dictionary with validated fields and proper mapping
            var validatedDict = dict
            

            
            // Convert timestamp from string to Date
            if let timestampStr = dict["timestamp"] as? String {
                
                // Try different timestamp formats
                var timestampMillis: Double?
                
                // First try: direct conversion (milliseconds since epoch)
                if let millis = Double(timestampStr) {
                    timestampMillis = millis
                }
                // Second try: seconds since epoch (convert to milliseconds)
                // Only treat as seconds if the value is small (less than 1e10, which is year 2286)
                else if let seconds = Double(timestampStr), seconds < 1e10 {
                    timestampMillis = seconds * 1000
                }
                // Third try: ISO 8601 date string
                else {
                    let formatter = ISO8601DateFormatter()
                    if let date = formatter.date(from: timestampStr) {
                        timestampMillis = date.timeIntervalSince1970 * 1000
                    }
                }
                
                if let millis = timestampMillis {
                    validatedDict["timestamp"] = millis
                } else {
                    // Use current time as fallback instead of epoch
                    validatedDict["timestamp"] = Date().timeIntervalSince1970 * 1000
                }
            } else if let timestampNum = dict["timestamp"] as? Double {
                // Server returns timestamp as double (in milliseconds)
                if timestampNum > 0 {
                    validatedDict["timestamp"] = timestampNum
                } else {
                    // Use current time as fallback
                    validatedDict["timestamp"] = Date().timeIntervalSince1970 * 1000
                }
            } else if let timestampNum = dict["timestamp"] as? Int {
                // Timestamp is an integer (in milliseconds)
                if timestampNum > 0 {
                    validatedDict["timestamp"] = Double(timestampNum)
                } else {
                    // Use current time as fallback
                    validatedDict["timestamp"] = Date().timeIntervalSince1970 * 1000
                }
            } else {
                // Use current time as fallback
                validatedDict["timestamp"] = Date().timeIntervalSince1970 * 1000
            }
            
            // Convert dictionary to JSON data
            let jsonData = try JSONSerialization.data(withJSONObject: validatedDict, options: [])
            
            // Decode the JSON data into a Tweet object
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            
            let tweet = try decoder.decode(Tweet.self, from: jsonData)
            

            
            return getInstance(mid: tweet.mid, authorId: tweet.authorId, content: tweet.content,
                             timestamp: tweet.timestamp, title: tweet.title,
                             originalTweetId: tweet.originalTweetId, originalAuthorId: tweet.originalAuthorId,
                             author: tweet.author, favorites: tweet.favorites,
                             favoriteCount: tweet.favoriteCount ?? 0,
                             bookmarkCount: tweet.bookmarkCount ?? 0,
                             retweetCount: tweet.retweetCount ?? 0,
                             commentCount: tweet.commentCount ?? 0,
                             attachments: tweet.attachments,
                             isPrivate: tweet.isPrivate,
                             downloadable: tweet.downloadable)
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
            throw error
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
        return Tweet.getInstance(
            mid: self.mid,
            authorId: self.authorId,
            content: content ?? self.content,
            timestamp: self.timestamp,
            title: title ?? self.title,
            originalTweetId: self.originalTweetId,
            originalAuthorId: self.originalAuthorId,
            author: author ?? self.author,
            favorites: favorites ?? self.favorites,
            favoriteCount: favoriteCount ?? self.favoriteCount ?? 0,
            bookmarkCount: bookmarkCount ?? self.bookmarkCount ?? 0,
            retweetCount: retweetCount ?? self.retweetCount ?? 0,
            commentCount: commentCount ?? self.commentCount ?? 0,
            attachments: attachments ?? self.attachments,
            isPrivate: isPrivate ?? self.isPrivate,
            downloadable: downloadable ?? self.downloadable
        )
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


// MARK: - Tweet Array Extension
extension Array where Element == Tweet {
    /// Merge new tweets into the array, overwriting existing ones with the same mid and appending new ones.
    mutating func mergeTweets(_ newTweets: [Tweet]) {
        // Create a dictionary to track unique tweets by their mid
        var uniqueTweets: [String: Tweet] = [:]
        
        // Add existing tweets to dictionary
        for tweet in self {
            uniqueTweets[tweet.mid] = tweet
        }
        
        // Add new tweets, overwriting existing ones if they have the same mid
        for tweet in newTweets {
            uniqueTweets[tweet.mid] = tweet
        }
        
        // Convert back to array and sort by timestamp in descending order
        self = Array(uniqueTweets.values).sorted { $0.timestamp > $1.timestamp }
    }
    
    /// Merge new tweets smoothly, preserving existing positions to prevent UI jumping
    mutating func mergeTweetsSmoothly(_ newTweets: [Tweet]) {
        // Create a set of existing tweet IDs for quick lookup
        let existingIds = Set(self.map { $0.mid })
        
        // Filter out tweets that already exist to avoid unnecessary updates
        let trulyNewTweets = newTweets.filter { !existingIds.contains($0.mid) }
        
        if trulyNewTweets.isEmpty {
            return
        }
        
        // Update existing tweets with new data (preserving positions)
        for newTweet in newTweets {
            if let existingIndex = self.firstIndex(where: { $0.mid == newTweet.mid }) {
                // Update existing tweet in place to preserve position
                self[existingIndex] = newTweet
            }
        }
        
        // Add truly new tweets at the end (they will be sorted by timestamp)
        self.append(contentsOf: trulyNewTweets)
        
        // Sort only if we added new tweets to maintain chronological order
        if !trulyNewTweets.isEmpty {
            self.sort { $0.timestamp > $1.timestamp }
        }
        
    }
}

extension Tweet: Equatable {
    static func == (lhs: Tweet, rhs: Tweet) -> Bool {
        return lhs.mid == rhs.mid
    }
}

extension Tweet: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(mid)
    }
}
