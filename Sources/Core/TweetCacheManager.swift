import CoreData
import Foundation
import UIKit

class TweetCacheManager {
    static let shared = TweetCacheManager()
    private let coreDataManager = CoreDataManager.shared
    private let maxCacheAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private let maxCacheSize: Int = 1000 // Maximum number of tweets to cache
    private var cleanupTimer: Timer?

    private init() {
        // Set up periodic cleanup
        setupPeriodicCleanup()
        
        // Register for memory warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    deinit {
        cleanupTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupPeriodicCleanup() {
        // Clean up every hour
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.performPeriodicCleanup()
        }
    }
    
    @objc private func handleMemoryWarning() {
        performPeriodicCleanup()
    }
    
    private func performPeriodicCleanup() {
        context.performAndWait {
            // Delete expired tweets
            deleteExpiredTweets()
            
            // Limit total number of tweets
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "timeCached", ascending: false)]
            request.fetchLimit = maxCacheSize
            
            if let allTweets = try? context.fetch(request) {
                // Only delete tweets if we have more than maxCacheSize
                if allTweets.count > maxCacheSize {
                    let tweetsToDelete = Array(allTweets[maxCacheSize...])
                    for tweet in tweetsToDelete {
                        context.delete(tweet)
                    }
                    try? context.save()
                }
            }
        }
    }
    
    var context: NSManagedObjectContext { coreDataManager.context }
}

// MARK: - Tweet Caching
extension TweetCacheManager {
    func fetchCachedTweets(for userId: String, page: UInt, pageSize: UInt, currentUserId: String? = nil) async -> [Tweet?] {
        return await withCheckedContinuation { continuation in
            context.perform {
                let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
                request.predicate = NSPredicate(format: "uid == %@", userId)
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                request.fetchOffset = Int(page * pageSize)
                request.fetchLimit = Int(pageSize)
                
                if let cdTweets = try? self.context.fetch(request) {
                    var tweets: [Tweet?] = []
                    for cdTweet in cdTweets {
                        do {
                            let tweet = try Tweet.from(cdTweet: cdTweet)
                            
                            // Filter out tweets with invalid timestamps
                            if tweet.timestamp.timeIntervalSince1970 <= 0 {
                                print("ERROR: [TweetCacheManager] Found cached tweet with invalid timestamp: \(tweet.timestamp), skipping")
                                tweets.append(nil)
                                continue
                            }
                            
                            // Filter out private tweets if they don't belong to the current user
                            if let currentUserId = currentUserId,
                               tweet.isPrivate == true && tweet.authorId != currentUserId {
                                tweets.append(nil)
                                continue
                            }
                            tweets.append(tweet)
                        } catch {
                            print("Error processing tweet: \(error)")
                            tweets.append(nil)
                        }
                    }
                    continuation.resume(returning: tweets)
                } else {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    func fetchTweet(mid: String) async -> Tweet? {
        return await withCheckedContinuation { continuation in
            context.perform {
                let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
                request.predicate = NSPredicate(format: "tid == %@", mid)
                
                // First, get the tweet and convert it
                if let cdTweet = try? self.context.fetch(request).first {
                    do {
                        let tweet = try Tweet.from(cdTweet: cdTweet)
                        // Then update the cache time in a separate operation
                        cdTweet.timeCached = Date()
                        try? self.context.save()
                        continuation.resume(returning: tweet)
                    } catch {
                        print("Error processing tweet: \(error)")
                        continuation.resume(returning: nil)
                    }
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Save a tweet to the cache. If tweet is nil, do nothing. To remove a tweet, use deleteTweet.
    func saveTweet(_ tweet: Tweet, userId: String) {
        // Validate timestamp before caching
        if tweet.timestamp.timeIntervalSince1970 <= 0 {
            print("ERROR: [TweetCacheManager] Attempting to cache tweet with invalid timestamp: \(tweet.timestamp), skipping cache")
            return
        }
        
        context.performAndWait {
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            request.predicate = NSPredicate(format: "tid == %@", tweet.mid)
            let cdTweet: CDTweet
            if let existingTweet = try? context.fetch(request).first {
                cdTweet = existingTweet
            } else {
                cdTweet = CDTweet(context: context)
            }
            cdTweet.tid = tweet.mid
            cdTweet.uid = userId
            cdTweet.timestamp = tweet.timestamp
            cdTweet.timeCached = Date()
            
            // Save tweet data directly using JSONEncoder
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            
            if let tweetData = try? encoder.encode(tweet) {
                cdTweet.tweetData = tweetData
                do {
                    try context.save()
                    print("[TweetCacheManager] Successfully saved tweet \(tweet.mid) to cache for user \(userId)")
                } catch {
                    print("[TweetCacheManager] ERROR: Failed to save tweet \(tweet.mid) to cache: \(error)")
                }
            } else {
                print("[TweetCacheManager] ERROR: Failed to encode tweet \(tweet.mid) for caching")
            }
        }
    }
    
    /// Update only specific fields of a cached tweet instead of replacing the whole object
    func updateTweetFields(mid: String, favorites: [Bool]? = nil, favoriteCount: Int? = nil, bookmarkCount: Int? = nil, retweetCount: Int? = nil, commentCount: Int? = nil) {
        context.performAndWait {
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            request.predicate = NSPredicate(format: "tid == %@", mid)
            
            if let cdTweet = try? context.fetch(request).first,
               let tweetData = cdTweet.tweetData {
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .millisecondsSince1970
                    var tweet = try decoder.decode(Tweet.self, from: tweetData)
                    
                    // Update only the specified fields
                    if let favorites = favorites {
                        tweet.favorites = favorites
                    }
                    if let favoriteCount = favoriteCount {
                        tweet.favoriteCount = favoriteCount
                    }
                    if let bookmarkCount = bookmarkCount {
                        tweet.bookmarkCount = bookmarkCount
                    }
                    if let retweetCount = retweetCount {
                        tweet.retweetCount = retweetCount
                    }
                    if let commentCount = commentCount {
                        tweet.commentCount = commentCount
                    }
                    
                    // Re-encode and save
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .millisecondsSince1970
                    if let updatedTweetData = try? encoder.encode(tweet) {
                        cdTweet.tweetData = updatedTweetData
                        cdTweet.timeCached = Date()
                        try? context.save()
                        print("[TweetCacheManager] Updated fields for tweet: \(mid)")
                    }
                } catch {
                    print("ERROR: [TweetCacheManager] Failed to update tweet fields for \(mid): \(error)")
                }
            }
        }
    }
    
    /// Update tweet fields from server data while preserving cached data
    func updateTweetFieldsFromServer(_ serverTweet: Tweet, userId: String? = nil) {
        context.performAndWait {
            // Find all cached instances of this tweet (could be in main_feed and user cache)
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            request.predicate = NSPredicate(format: "tid == %@", serverTweet.mid)
            
            do {
                let cachedTweets = try context.fetch(request)
                
                for cdTweet in cachedTweets {
                    // Decode existing tweet
                    if let tweetData = cdTweet.tweetData {
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .millisecondsSince1970
                        var cachedTweet = try decoder.decode(Tweet.self, from: tweetData)
                        
                        // Update only the fields that might change from server
                        cachedTweet.favorites = serverTweet.favorites
                        cachedTweet.favoriteCount = serverTweet.favoriteCount
                        cachedTweet.bookmarkCount = serverTweet.bookmarkCount
                        cachedTweet.retweetCount = serverTweet.retweetCount
                        cachedTweet.commentCount = serverTweet.commentCount
                        
                        // Preserve existing attachments completely - don't replace with server data
                        // Server data doesn't contain cached URLs, so we keep the cached attachments
                        print("[TweetCacheManager] Preserving existing attachments for tweet \(serverTweet.mid)")
                        if let cachedAttachments = cachedTweet.attachments {
                            for attachment in cachedAttachments {
                                if let url = attachment.url, !url.isEmpty {
                                    print("[TweetCacheManager] Preserved cached URL for attachment \(attachment.mid): \(url)")
                                }
                            }
                        }
                        
                        // Re-encode and save
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .millisecondsSince1970
                        if let updatedTweetData = try? encoder.encode(cachedTweet) {
                            cdTweet.tweetData = updatedTweetData
                            cdTweet.timeCached = Date()
                            print("[TweetCacheManager] Updated tweet fields from server while preserving cached data: \(serverTweet.mid) in cache: \(cdTweet.uid ?? "unknown")")
                        }
                    }
                }
                
                // Save all changes
                try? context.save()
                print("[TweetCacheManager] Updated tweet \(serverTweet.mid) in \(cachedTweets.count) cache(s)")
                
            } catch {
                print("ERROR: [TweetCacheManager] Failed to update tweet fields from server for \(serverTweet.mid): \(error)")
            }
        }
    }

    func deleteExpiredTweets() {
        context.performAndWait {
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            let expirationDate = Date().addingTimeInterval(-maxCacheAge)
            request.predicate = NSPredicate(format: "timeCached < %@", expirationDate as NSDate)
            if let expiredTweets = try? context.fetch(request) {
                for tweet in expiredTweets {
                    context.delete(tweet)
                }
                try? context.save()
            }
        }
    }
    
    func deleteTweetsWithInvalidTimestamps() {
        context.performAndWait {
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            // Find tweets with timestamps before 1970 (invalid dates)
            let invalidDate = Date(timeIntervalSince1970: 0)
            request.predicate = NSPredicate(format: "timestamp <= %@", invalidDate as NSDate)
            if let invalidTweets = try? context.fetch(request) {
                print("ERROR: [TweetCacheManager] Found \(invalidTweets.count) tweets with invalid timestamps, deleting them")
                for tweet in invalidTweets {
                    context.delete(tweet)
                }
                try? context.save()
            }
        }
    }

    func deleteTweet(mid: String) {
        context.performAndWait {
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            request.predicate = NSPredicate(format: "tid == %@", mid)
            if let cdTweet = try? context.fetch(request).first {
                context.delete(cdTweet)
                try? context.save()
            }
        }
    }

    func clearAllCache() {
        context.performAndWait {
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            if let allTweets = try? context.fetch(request) {
                for tweet in allTweets {
                    context.delete(tweet)
                }
                try? context.save()
            }
        }
    }
    
    func clearCacheForUser(userId: String) {
        context.performAndWait {
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            request.predicate = NSPredicate(format: "uid == %@", userId)
            if let userTweets = try? context.fetch(request) {
                for tweet in userTweets {
                    context.delete(tweet)
                }
                try? context.save()
                print("[TweetCacheManager] Cleared cache for user: \(userId)")
            }
        }
    }
    
    /// Check if a tweet exists in cache
    func tweetExists(mid: String, userId: String) -> Bool {
        var exists = false
        context.performAndWait {
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            request.predicate = NSPredicate(format: "tid == %@ AND uid == %@", mid, userId)
            request.fetchLimit = 1
            let count = (try? context.count(for: request)) ?? 0
            exists = count > 0
            print("[TweetCacheManager] Checking if tweet \(mid) exists for user \(userId): \(exists) (count: \(count))")
        }
        return exists
    }
}

// MARK: - Tweet <-> Core Data Conversion
extension Tweet {
    static func from(cdTweet: CDTweet) throws -> Tweet {
        if let tweetData = cdTweet.tweetData {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(Tweet.self, from: tweetData)
        }
        
        throw NSError(domain: "TweetCacheManager", code: -1, 
                     userInfo: [NSLocalizedDescriptionKey: "Failed to decode tweet data from Core Data"])
    }
    
    static func from(cdTweet: CDTweet) async throws -> Tweet {
        return try await MainActor.run {
            try from(cdTweet: cdTweet)
        }
    }
}

// MARK: - User Caching
/// Might need to update baseUrl of cached user, which might be outdated.
extension TweetCacheManager {
    func fetchUser(mid: String) -> User {
        var user: User?
        context.performAndWait {
            let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
            request.predicate = NSPredicate(format: "mid == %@", mid)
            
            // First, get the user and convert it
            if let cdUser = try? context.fetch(request).first {
                user = User.from(cdUser: cdUser)
                // Then update the cache time in a separate operation
                cdUser.timeCached = Date()
                try? context.save()
            }
        }
        return user ?? User.getInstance(mid: mid)
    }
    
    /// Internal method used by User.hasExpired computed property
    /// Checks if a user's cache has expired (30 minutes)
    func hasExpired(mid: String) -> Bool {
        var hasExpired = true
        context.performAndWait {
            let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
            request.predicate = NSPredicate(format: "mid == %@", mid)
            if let cdUser = try? context.fetch(request).first {
                hasExpired = cdUser.timeCached?.timeIntervalSinceNow ?? 0 < -1800 // 30 minutes
            }
            // If no cached user found, hasExpired remains true
        }
        return hasExpired
    }

    func saveUser(_ user: User) {
        context.performAndWait {
            let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
            request.predicate = NSPredicate(format: "mid == %@", user.mid)
            let cdUser = (try? context.fetch(request).first) ?? CDUser(context: context)
            cdUser.mid = user.mid
            cdUser.timeCached = Date()
            if let userData = try? JSONEncoder().encode(user) {
                cdUser.userData = userData
            }
            try? context.save()
        }
    }

    func deleteExpiredUsers() {
        context.performAndWait {
            let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
            let oneMonthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
            request.predicate = NSPredicate(format: "timeCached < %@", oneMonthAgo as NSDate)
            
            // Create a separate array to store the objects to delete
            if let expiredUsers = try? context.fetch(request) {
                let usersToDelete = Array(expiredUsers)
                for user in usersToDelete {
                    context.delete(user)
                }
                try? context.save()
            }
        }
    }

    func deleteUser(mid: String) {
        context.performAndWait {
            let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
            request.predicate = NSPredicate(format: "mid == %@", mid)
            if let cdUser = try? context.fetch(request).first {
                context.delete(cdUser)
                try? context.save()
            }
        }
    }

    func clearAllUsers() {
        context.performAndWait {
            let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
            if let allUsers = try? context.fetch(request) {
                for user in allUsers {
                    context.delete(user)
                }
                try? context.save()
            }
        }
    }
} 
