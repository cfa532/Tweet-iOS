import CoreData
import Foundation
import UIKit

final class TweetCacheManager: @unchecked Sendable {
    static let shared = TweetCacheManager()
    private let coreDataManager = CoreDataManager.shared
    private let maxCacheAge: TimeInterval = 14 * 24 * 60 * 60 // 14 days (2 weeks) for auto-cleanup
    private let maxCacheSize: Int = 5000 // Maximum number of tweets to cache
    private var cleanupTimer: Timer?
    
    // Track last access time for tweets (in memory, persisted to UserDefaults)
    private var tweetAccessTimes: [String: Date] = [:]
    private let accessTimesKey = "TweetAccessTimes"

    private init() {
        // Load access times from UserDefaults
        loadAccessTimes()
        
        // Set up periodic cleanup
        setupPeriodicCleanup()
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
    
    // Load access times from UserDefaults
    private func loadAccessTimes() {
        if let data = UserDefaults.standard.data(forKey: accessTimesKey),
           let times = try? JSONDecoder().decode([String: Date].self, from: data) {
            tweetAccessTimes = times
            print("DEBUG: [TweetCacheManager] Loaded \(times.count) tweet access times")
        }
    }
    
    // Save access times to UserDefaults
    private func saveAccessTimes() {
        if let data = try? JSONEncoder().encode(tweetAccessTimes) {
            UserDefaults.standard.set(data, forKey: accessTimesKey)
        }
    }
    
    // Mark tweet as accessed (called when tweet is viewed)
    func markTweetAccessed(_ tweetId: String) {
        tweetAccessTimes[tweetId] = Date()
        // Save periodically, not on every access (performance)
        if tweetAccessTimes.count % 20 == 0 {
            saveAccessTimes()
        }
    }
    
    private func performPeriodicCleanup() {
        context.performAndWait {
            // Delete expired tweets (2 weeks old, excluding private tweets)
            deleteExpiredTweets()
            
            // Save access times after cleanup
            saveAccessTimes()
            
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
    
    // MARK: - Media Cleanup
    
    /// Delete media files associated with a tweet
    private func deleteMediaForTweet(_ tweet: Tweet) {
        // Collect all media IDs from attachments
        var mediaIds: [String] = []
        
        if let attachments = tweet.attachments {
            for attachment in attachments {
                mediaIds.append(attachment.mid)
            }
        }
        
        if mediaIds.isEmpty { return }
        
        print("DEBUG: [TweetCacheManager] Deleting \(mediaIds.count) media files for tweet \(tweet.mid)")
        
        // Delete from SharedAssetCache (videos/audio) on main actor
        Task { @MainActor in
            for mediaId in mediaIds {
                SharedAssetCache.shared.clearAssetCache(for: mediaId)
            }
        }
        
        // Delete from ImageCacheManager (images)
        for mediaId in mediaIds {
            ImageCacheManager.shared.clearCache(for: mediaId)
        }
    }
    
    // MARK: - Manual Cleanup (Settings Screen)
    
    /// Manual cleanup from settings screen - clears everything including private tweets
    func manualClearAllCache() {
        print("DEBUG: [TweetCacheManager] Manual cache clear - clearing EVERYTHING")
        
        context.performAndWait {
            // Get all tweets
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            if let allTweets = try? context.fetch(request) {
                print("DEBUG: [TweetCacheManager] Manual clear: deleting \(allTweets.count) tweets and their media")
                
                for cdTweet in allTweets {
                    // Delete associated media (clears from caches per media ID)
                    if let tweet = try? Tweet.from(cdTweet: cdTweet) {
                        deleteMediaForTweet(tweet)
                    }
                    
                    // Delete tweet from CoreData
                    context.delete(cdTweet)
                }
                
                try? context.save()
            }
        }
        
        // Clear access times
        tweetAccessTimes.removeAll()
        saveAccessTimes()
        
        // Final sweep: clear any remaining caches that might not be tweet-associated
        Task { @MainActor in
            SharedAssetCache.shared.clearAllCaches()
        }
        ImageCacheManager.shared.clearAllCache()
        
        // Clear memory cache
        Tweet.clearAllInstances()
        
        print("✅ Manual cache clear complete")
    }
    
    // MARK: - Signout Cleanup
    
    /// Clear everything on signout
    func clearCacheOnSignout() {
        print("DEBUG: [TweetCacheManager] Signout - clearing EVERYTHING")
        manualClearAllCache()
    }
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
                            
                            // NOTE: Author will be lazy-loaded by the view when needed
                            // Removed synchronous author population to avoid blocking
                            
                            // Filter out tweets with invalid timestamps
                            if tweet.timestamp.timeIntervalSince1970 <= 0 {
                                print("ERROR: [TweetCacheManager] Found cached tweet with invalid timestamp: \(tweet.timestamp), skipping")
                                tweets.append(nil)
                                continue
                            }
                            
                            // Filter out ALL private tweets in main feed (regardless of author)
                            if tweet.isPrivate == true {
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
                        // NOTE: Author will be lazy-loaded by the view when needed
                        // Removed synchronous author population to avoid blocking
                        
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
    /// If a tweet with the same mid already exists, it will be updated with new counts and favorites instead of being replaced.
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
            
            // Always save the current in-memory tweet state to cache
            // This ensures that any updates made to the tweet in memory are preserved
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            if let tweetData = try? encoder.encode(tweet) {
                cdTweet.tweetData = tweetData
            }
                        
            // Update common fields
            cdTweet.tid = tweet.mid
            cdTweet.uid = userId
            cdTweet.timestamp = tweet.timestamp
            cdTweet.timeCached = Date()
            
            try? context.save()
        }
    }

    /// Update a tweet using unified cache strategy:
    /// - AppUser's public tweets → "main_feed" cache (appear in feed and profile)
    /// - AppUser's private tweets → appUser.mid cache only (profile-only visibility)
    /// - Other users' tweets → "main_feed" cache
    func updateTweetInAppUserCaches(_ tweet: Tweet, appUserId: String) {
        if tweet.authorId == appUserId && tweet.isPrivate == true {
            // AppUser's private tweet - save only to profile cache
            saveTweet(tweet, userId: appUserId)
        } else {
            // Public tweet (any user) or other users' tweets - save to main_feed
            saveTweet(tweet, userId: "main_feed")
        }
    }

    func deleteExpiredTweets() {
        context.performAndWait {
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            let expirationDate = Date().addingTimeInterval(-maxCacheAge)
            
            if let allCachedTweets = try? context.fetch(request) {
                var deletedCount = 0
                var preservedPrivateCount = 0
                
                for cdTweet in allCachedTweets {
                    guard let tweetId = cdTweet.tid else { continue }
                    
                    // Decode tweet to check if it's private
                    guard let tweet = try? Tweet.from(cdTweet: cdTweet) else { continue }
                    
                    // NEVER auto-delete private tweets - only manual or signout
                    if tweet.isPrivate == true {
                        preservedPrivateCount += 1
                        continue
                    }
                    
                    // Check last access time (if available), otherwise fall back to timeCached
                    let lastAccess = tweetAccessTimes[tweetId] ?? (cdTweet.timeCached ?? Date.distantPast)
                    
                    if lastAccess < expirationDate {
                        // Tweet hasn't been accessed in 2 weeks - delete it and its media
                        print("DEBUG: [TweetCacheManager] Deleting expired tweet: \(tweetId) (last access: \(lastAccess))")
                        
                        // Delete associated media files
                        deleteMediaForTweet(tweet)
                        
                        // Remove from access times
                        tweetAccessTimes.removeValue(forKey: tweetId)
                        
                        // Delete tweet from CoreData
                        context.delete(cdTweet)
                        deletedCount += 1
                    }
                }
                
                if deletedCount > 0 {
                    try? context.save()
                    saveAccessTimes()
                    print("DEBUG: [TweetCacheManager] Deleted \(deletedCount) expired tweets, preserved \(preservedPrivateCount) private tweets")
                }
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
        
        // Also clear all users for soft restart
        clearAllUsers()
    }
    
    /// Clear only memory cache (for memory management)
    func clearMemoryCache() {
        // Clear in-memory tweet instances
        Tweet.clearAllInstances()
        print("DEBUG: [TweetCacheManager] Cleared memory cache")
    }
    
    /// Release a percentage of tweet cache to free memory
    func releasePartialCache(percentage: Int) {
        let percentageToRemove = max(1, min(percentage, 90)) // Ensure 1-90% range
        
        context.performAndWait {
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            
            // Sort by cache time (oldest first) for LRU strategy
            request.sortDescriptors = [NSSortDescriptor(key: "timeCached", ascending: true)]
            
            if let allTweets = try? context.fetch(request) {
                let countToRemove = max(1, (allTweets.count * percentageToRemove) / 100)
                let tweetsToRemove = Array(allTweets.prefix(countToRemove))
                
                for tweet in tweetsToRemove {
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
    
}

// MARK: - User Caching
/// Might need to update baseUrl of cached user, which might be outdated.
extension TweetCacheManager {
    func fetchUser(mid: String) async -> User {
        return await withCheckedContinuation { continuation in
            context.perform {
                let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
                request.predicate = NSPredicate(format: "mid == %@", mid)
                
                if let cdUser = try? self.context.fetch(request).first {
                    let user = User.from(cdUser: cdUser)
                    continuation.resume(returning: user)
                } else {
                    continuation.resume(returning: User.getInstance(mid: mid))
                }
            }
        }
    }
    
    /// Internal method used by User.hasExpired computed property
    /// Checks if a user's cache has expired (30 minutes)
    func hasExpired(mid: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            context.perform {
                let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
                request.predicate = NSPredicate(format: "mid == %@", mid)
                if let cdUser = try? self.context.fetch(request).first {
                    let hasExpired = cdUser.timeCached?.timeIntervalSinceNow ?? 0 < -1800 // 30 minutes
                    continuation.resume(returning: hasExpired)
                } else {
                    // If no cached user found, hasExpired is true
                    continuation.resume(returning: true)
                }
            }
        }
    }

    func saveUser(_ user: User) {
        // Use async perform to avoid blocking the main thread
        context.perform {
            let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
            request.predicate = NSPredicate(format: "mid == %@", user.mid)
            let cdUser = (try? self.context.fetch(request).first) ?? CDUser(context: self.context)
            cdUser.mid = user.mid
            cdUser.timeCached = Date()
            if let userData = try? JSONEncoder().encode(user) {
                cdUser.userData = userData
            }
            try? self.context.save()
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
