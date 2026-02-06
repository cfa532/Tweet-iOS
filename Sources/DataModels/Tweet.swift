import Foundation

class Tweet: Identifiable, Codable, ObservableObject {
    // MARK: - Singleton
    private static var instances: [MimeiId: Tweet] = [:]
    private static let instanceLock = NSLock()
    
    /// Get or create a Tweet singleton instance
    /// Always use this instead of direct Tweet() initialization to ensure singleton pattern
    static func getInstance(mid: MimeiId, authorId: MimeiId, content: String? = nil, timestamp: Date = Date(timeIntervalSince1970: Date().timeIntervalSince1970), title: String? = nil,
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
        newInstance.cachedHeight = TweetHeightCache.shared.getHeight(for: mid)
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

    /// Clean up old tweet instances to prevent memory growth
    /// - Parameter activeTweetIds: Set of tweet IDs that are currently active/visible
    /// - Parameter maxInstances: Maximum number of instances to keep (default: 1000)
    static func cleanupOldInstances(activeTweetIds: Set<String>, maxInstances: Int = 1000) {
        instanceLock.lock()
        defer { instanceLock.unlock() }

        // Don't cleanup if we're below the limit
        guard instances.count > maxInstances else { return }

        // Keep tweets that are currently active
        let tweetsToKeep = instances.filter { activeTweetIds.contains($0.key) }

        // If we still have too many, remove oldest ones
        if tweetsToKeep.count > maxInstances {
            // Sort by timestamp (most recent first) and keep only the most recent ones
            let sortedTweets = tweetsToKeep.sorted { $0.value.timestamp > $1.value.timestamp }
            let tweetsToRemove = sortedTweets.dropFirst(maxInstances)
            for tweet in tweetsToRemove {
                instances.removeValue(forKey: tweet.key)
            }
        } else {
            // Remove all inactive tweets
            instances = tweetsToKeep
        }
    }
    
    static func getInstance(for mid: MimeiId) -> Tweet? {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        return instances[mid]
    }
    
    static func getAllInstances() -> [MimeiId: Tweet] {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        return instances
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
    var attachments: [MimeiFileType]? {
        didSet {
            // When attachments change, update them to observe the author's baseUrl
            updateAttachmentsAuthor()
        }
    }
    var isPrivate: Bool?
    var downloadable: Bool?

    // Display only properties
    @Published var author: User? {
        didSet {
            // When author changes, update all attachments to observe the new author's baseUrl
            updateAttachmentsAuthor()
        }
    }
    
    // TRANSIENT: Cached rendered height (not persisted)
    // Used for scroll stability - once a tweet is rendered, we remember its exact height
    var cachedHeight: CGFloat?
    
    /// Update all attachments to observe the current author's baseUrl
    private func updateAttachmentsAuthor() {
        guard let author = author else { return }
        attachments?.forEach { attachment in
            attachment.setAuthor(author)
        }
    }
    
    // User interaction flags - batched to reduce update frequency
    @Published var favorites: [Bool]? // [favorite, bookmark, retweeted]
    @Published var favoriteCount: Int?
    @Published var bookmarkCount: Int?
    @Published var retweetCount: Int?
    @Published var commentCount: Int?
    @Published var isVisible: Bool = false  // Track visibility state

    // Batch update mechanism to reduce ObservableObject notifications during bulk operations
    private var isInBatchUpdate = false

    /// Perform batched updates to reduce ObservableObject notification frequency
    func performBatchUpdate(_ updates: () -> Void) {
        let wasInBatchUpdate = isInBatchUpdate
        isInBatchUpdate = true

        updates()

        // Send single notification after all updates complete
        if !wasInBatchUpdate {
            isInBatchUpdate = false
            // Trigger single objectWillChange notification for all batched changes
            objectWillChange.send()
        }
    }
    
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
        // author is NOT saved - always reconstructed from singleton
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
        // author is NOT decoded - always reconstructed from singleton using authorId
        author = nil
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
        
        // Update attachments to observe author's baseUrl if both are present
        if author != nil {
            updateAttachmentsAuthor()
        }
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
        // author is NOT encoded - always reconstructed from singleton using authorId
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
        performBatchUpdate {
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
            performBatchUpdate {
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
            }
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
    /// Determines whether `candidate` should appear before `other` in a descending timeline order.
    private func shouldPlace(_ candidate: Tweet, before other: Tweet) -> Bool {
        if candidate.timestamp == other.timestamp {
            return candidate.mid > other.mid
        }
        return candidate.timestamp > other.timestamp
    }
    
    /// Finds the correct insertion index for `tweet` while keeping the array sorted by descending timestamp.
    private func orderedInsertionIndex(for tweet: Tweet) -> Int {
        var lowerBound = 0
        var upperBound = count
        
        while lowerBound < upperBound {
            let midIndex = (lowerBound + upperBound) / 2
            let comparisonTarget = self[midIndex]
            
            if shouldPlace(tweet, before: comparisonTarget) {
                upperBound = midIndex
            } else {
                lowerBound = midIndex + 1
            }
        }
        
        return lowerBound
    }
    
    /// Core merge implementation - optimized for layout stability
    /// Updates tweet properties in place, letting SwiftUI recompose naturally
    /// Only inserts truly new tweets, avoiding array mutations that cause scroll jumps
    private mutating func mergeTweetsInternal(_ newTweets: [Tweet]) {
        guard !newTweets.isEmpty else { return }

        // Early exit optimization: if newTweets is small and we have many existing tweets,
        // check if most tweets are updates rather than inserts to avoid expensive sorting
        let shouldOptimizeForUpdates = newTweets.count <= 20 && self.count > 100

        // Build dictionary index map for O(1) lookups (only when beneficial)
        var indexMap: [String: Int] = [:]
        if shouldOptimizeForUpdates || newTweets.count > 5 {
            for (index, tweet) in self.enumerated() {
                indexMap[tweet.mid] = index
            }
        }

        var processedIds = Set<String>()
        var tweetsToInsert: [Tweet] = []

        for newTweet in newTweets {
            guard processedIds.insert(newTweet.mid).inserted else { continue }

            if let existingIndex = indexMap[newTweet.mid] ?? firstIndex(where: { $0.mid == newTweet.mid }) {
                // Tweet exists - update its properties in place
                // The singleton pattern ensures all references see the update
                // SwiftUI's @ObservedObject will trigger recomposition automatically
                let existingTweet = self[existingIndex]

                // Use existing update method (cleaner, DRY)
                try? existingTweet.update(from: newTweet)

                // NOTE: No need to invalidate cachedHeight
                // Tweet content is immutable - height never changes after first render

                // No array mutation - tweet stays at same index, SwiftUI recomposes
            } else {
                // New tweet - collect for insertion
                tweetsToInsert.append(newTweet)
            }
        }

        // Insert new tweets at their correct positions
        // Process in sorted order to maintain correct positions as we insert
        guard !tweetsToInsert.isEmpty else { return }

        let sortedNewTweets = tweetsToInsert.sorted { shouldPlace($0, before: $1) }

        for newTweet in sortedNewTweets {
            let insertionIndex = orderedInsertionIndex(for: newTweet)
            insert(newTweet, at: insertionIndex)
        }
    }
    
    /// Merge new tweets into the array, overwriting existing ones with the same mid and inserting new ones at the correct position.
    mutating func mergeTweets(_ newTweets: [Tweet]) {
        mergeTweetsInternal(newTweets)
    }

    /// Append new tweets preserving the input order (for bookmarks/favorites where order matters)
    /// Updates existing tweets in place, appends new ones at the end in input order
    mutating func appendTweetsPreservingOrder(_ newTweets: [Tweet]) {
        guard !newTweets.isEmpty else { return }

        // Build index map for O(1) lookups
        var indexMap: [String: Int] = [:]
        for (index, tweet) in self.enumerated() {
            indexMap[tweet.mid] = index
        }

        var processedIds = Set<String>()
        var tweetsToAppend: [Tweet] = []

        for newTweet in newTweets {
            guard processedIds.insert(newTweet.mid).inserted else { continue }

            if let existingIndex = indexMap[newTweet.mid] {
                // Tweet exists - update its properties in place
                let existingTweet = self[existingIndex]
                try? existingTweet.update(from: newTweet)
            } else {
                // New tweet - collect for appending (preserving input order)
                tweetsToAppend.append(newTweet)
            }
        }

        // Append new tweets at the end in the order they appeared in input
        self.append(contentsOf: tweetsToAppend)
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
