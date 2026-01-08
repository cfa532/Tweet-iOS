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
    func fetchCachedTweets(for userId: String, page: UInt, pageSize: UInt, currentUserId: String? = nil, isProfileView: Bool = false) async -> [Tweet?] {
        return await withCheckedContinuation { continuation in
            context.perform {
                let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
                
                // For profile views: load from userId cache and filter by authorId
                // For main feed: load from userId (appUser.mid) cache, no authorId filtering
                let shouldFilterByAuthorId = isProfileView
                
                // Always load from userId cache (which equals authorId for profile views)
                request.predicate = NSPredicate(format: "uid == %@", userId)
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                // Fetch more tweets if filtering by authorId (to account for filtering)
                let fetchLimit = shouldFilterByAuthorId ? Int(pageSize * 3) : Int(pageSize)
                request.fetchLimit = fetchLimit
                request.fetchOffset = Int(page * pageSize)
                
                if let cdTweets = try? self.context.fetch(request) {
                    var tweets: [Tweet?] = []
                    for cdTweet in cdTweets {
                        do {
                            let tweet = try Tweet.from(cdTweet: cdTweet)
                            
                            // For profile views, always filter to only include tweets authored by the profile user
                            // This ensures we only show that user's tweets, even if cache contains tweets from other authors
                            if shouldFilterByAuthorId && tweet.authorId != userId {
                                continue // Skip tweets from other authors
                            }
                            
                            // Load author from cache (Core Data) if available, otherwise use singleton
                            // This ensures cached user data is used as placeholder until refreshed from server
                            if tweet.author == nil {
                                // First get the singleton
                                let authorSingleton = User.getInstance(mid: tweet.authorId)
                                
                                // If singleton doesn't have data, try to load from Core Data cache
                                if authorSingleton.username == nil {
                                    let userRequest: NSFetchRequest<CDUser> = CDUser.fetchRequest()
                                    userRequest.predicate = NSPredicate(format: "mid == %@", tweet.authorId)
                                    if let cdUser = try? self.context.fetch(userRequest).first {
                                        // Update singleton with cached data (even if expired)
                                        _ = User.from(cdUser: cdUser)
                                    }
                                }
                                
                                // Use the singleton (either populated from cache or skeleton)
                                tweet.author = User.getInstance(mid: tweet.authorId)
                            }
                            
                            // NOTE: baseUrl will be assigned on MainActor after all tweets are collected
                            
                            // Filter out tweets with invalid timestamps
                            if tweet.timestamp.timeIntervalSince1970 <= 0 {
                                print("ERROR: [TweetCacheManager] Found cached tweet with invalid timestamp: \(tweet.timestamp), skipping")
                                tweets.append(nil)
                                continue
                            }
                            
                            // Filter private tweets:
                            // - Main feed: Always filter out private tweets (show all tweets, but no private ones)
                            // - Profile view: Only show private tweets if appUser is viewing their own profile
                            // - Bookmarks/Favorites: NEVER filter (user explicitly bookmarked/favorited them)
                            let isBookmarkOrFavorite = userId.hasPrefix("bookmark_list_") || userId.hasPrefix("favorite_list_")
                            
                            if tweet.isPrivate == true && !isBookmarkOrFavorite {
                                if shouldFilterByAuthorId && currentUserId != nil && userId == currentUserId {
                                    // Profile view: Allow private tweets only if viewing own profile (appUser == visited user)
                                    tweets.append(tweet)
                                } else {
                                    // Main feed or viewing other user's profile: Filter out private tweets
                                    continue
                                }
                            } else {
                                // Public tweet OR bookmarked/favorited private tweet: Always include
                                tweets.append(tweet)
                            }
                        } catch {
                            print("Error processing tweet: \(error)")
                            tweets.append(nil)
                        }
                    }
                    
                    // Filtered results - limit to pageSize
                    let limitedTweets = Array(tweets.prefix(Int(pageSize)))
                    continuation.resume(returning: limitedTweets)
                } else {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// Fetch a tweet by its mid (tweet ID) from cache
    /// IMPORTANT: Searches across ALL user caches, not just a specific user's cache
    /// This is necessary because:
    /// - Original tweets are cached under their authorId
    /// - Retweets are cached under appUser.mid
    /// - When we only have a tweet mid, we don't know which user's cache it's in
    func fetchTweet(mid: String) async -> Tweet? {
        return await withCheckedContinuation { continuation in
            // First check in-memory singleton
            if let tweetInstance = Tweet.getInstance(for: mid) {
                // Tweet is already in memory, return it immediately
                continuation.resume(returning: tweetInstance)
                return
            }
            
            // Otherwise, load from Core Data cache
            // Search by tid (tweet ID) across ALL caches, not filtered by userId
            context.perform {
                let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
                request.predicate = NSPredicate(format: "tid == %@", mid)
                
                // Get the tweet and convert it
                if let cdTweet = try? self.context.fetch(request).first {
                    do {
                        let tweet = try Tweet.from(cdTweet: cdTweet)
                        
                        // Load author from cache (Core Data) if available, otherwise use singleton
                        // This ensures cached user data is used as placeholder until refreshed from server
                        if tweet.author == nil {
                            // First get the singleton
                            let authorSingleton = User.getInstance(mid: tweet.authorId)
                            
                            // If singleton doesn't have data, try to load from Core Data cache
                            if authorSingleton.username == nil {
                                let userRequest: NSFetchRequest<CDUser> = CDUser.fetchRequest()
                                userRequest.predicate = NSPredicate(format: "mid == %@", tweet.authorId)
                                if let cdUser = try? self.context.fetch(userRequest).first {
                                    // Update singleton with cached data (even if expired)
                                    _ = User.from(cdUser: cdUser)
                                }
                            }
                            
                            // Use the singleton (either populated from cache or skeleton)
                            tweet.author = User.getInstance(mid: tweet.authorId)
                        }
                        
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
        
        // Mark media as permanent for: private tweets OR bookmarks/favorites
        let isPrivate = tweet.isPrivate == true
        let isBookmarkOrFavorite = userId.hasPrefix("bookmark_list_") || userId.hasPrefix("favorite_list_")
        
        if (isPrivate || isBookmarkOrFavorite), let attachments = tweet.attachments {
            // Mark videos as permanent
            let videoIDs = attachments.filter { $0.type == .video || $0.type == .hls_video }.compactMap { $0.mid }
            if !videoIDs.isEmpty {
                DiskCacheCleanupManager.shared.markMediaIDsAsPermanent(videoIDs)
                // Reduced logging to prevent buffer overflow
            }
            
            // Mark images as permanent
            let imageIDs = attachments.filter { $0.type == .image }.compactMap { $0.mid }
            if !imageIDs.isEmpty {
                ImageCacheManager.shared.markImageIDsAsPermanent(imageIDs)
                // Reduced logging to prevent buffer overflow
            }
        }
    }

    /// Update a tweet in cache for main feed.
    /// Main feed tweets are cached under appUser.mid for efficient loading.
    /// Profile tweets should use saveTweet directly with their authorId.
    func updateTweetInAppUserCaches(_ tweet: Tweet, appUserId: String) {
        // Cache main feed tweets under appUser.mid
        saveTweet(tweet, userId: appUserId)
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
                    
                    // NEVER auto-delete: private tweets OR bookmarks/favorites
                    let isPrivate = tweet.isPrivate == true
                    let isBookmarkOrFavorite = cdTweet.uid?.hasPrefix("bookmark_list_") == true || 
                                               cdTweet.uid?.hasPrefix("favorite_list_") == true
                    
                    if isPrivate || isBookmarkOrFavorite {
                        if isPrivate {
                            preservedPrivateCount += 1
                        }
                        print("💾 [TweetCacheManager] Preserving permanent tweet: \(tweetId) (private: \(isPrivate), bookmarked: \(isBookmarkOrFavorite))")
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
            // Delete ALL instances of this tweet (might be in multiple caches)
            if let cdTweets = try? context.fetch(request) {
                for cdTweet in cdTweets {
                    context.delete(cdTweet)
                }
                if !cdTweets.isEmpty {
                    print("DEBUG: [TweetCacheManager] Deleted \(cdTweets.count) cache entries for tweet: \(mid)")
                }
                try? context.save()
            }
        }
    }
    
    /// Delete all tweets from a specific user from a specific cache (e.g., when unfollowing)
    func deleteTweetsFromUser(userId: String, cacheKey: String) {
        context.performAndWait {
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            // Match tweets where uid (cache key) matches AND tweet's authorId matches userId
            request.predicate = NSPredicate(format: "uid == %@", cacheKey)
            
            if let cdTweets = try? context.fetch(request) {
                var deletedCount = 0
                for cdTweet in cdTweets {
                    // Decode tweet to check authorId
                    if let tweet = try? Tweet.from(cdTweet: cdTweet), tweet.authorId == userId {
                        // Remove from access times
                        tweetAccessTimes.removeValue(forKey: tweet.mid)
                        context.delete(cdTweet)
                        deletedCount += 1
                    }
                }
                if deletedCount > 0 {
                    try? context.save()
                    saveAccessTimes()
                    print("DEBUG: [TweetCacheManager] Deleted \(deletedCount) tweets from user \(userId) in cache: \(cacheKey)")
                }
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
            let tweet = try decoder.decode(Tweet.self, from: tweetData)
            
            // CRITICAL: Replace decoded author with singleton instance
            // When decoding, a new User instance is created, but we need to use the singleton
            if let decodedAuthor = tweet.author {
                // Get the singleton instance
                let authorSingleton = User.getInstance(mid: decodedAuthor.mid)
                
                // Update singleton with decoded data (preserves existing baseUrl if present)
                User.updateUserInstance(with: decodedAuthor)
                
                // Replace tweet's author with the singleton
                tweet.author = authorSingleton
                
                print("DEBUG: [Tweet.from(cdTweet)] Tweet \(tweet.mid) using author singleton for user \(authorSingleton.mid), baseUrl: \(authorSingleton.baseUrl?.absoluteString ?? "NIL")")
                
                // Trigger fetchUser if baseUrl is nil to resolve IP
                // (Rare case: old cache data before IP caching, or newly created user)
                // SKIP appUser - app initialization will handle it
                if authorSingleton.baseUrl == nil
                    && authorSingleton.mid != HproseInstance.shared.appUser.mid {
                    Task {
                        _ = try? await HproseInstance.shared.fetchUser(authorSingleton.mid)
                    }
                }
            }
            
            // CRITICAL: Use singleton pattern for Tweet instance as well
            // This ensures that the same tweet loaded from cache vs server uses the same instance
            // Without this, profile view (from cache) and main feed (from server) would have different instances
            // causing retweet count updates to not sync across views
            return Tweet.getInstance(
                mid: tweet.mid,
                authorId: tweet.authorId,
                content: tweet.content,
                timestamp: tweet.timestamp,
                title: tweet.title,
                originalTweetId: tweet.originalTweetId,
                originalAuthorId: tweet.originalAuthorId,
                author: tweet.author,
                favorites: tweet.favorites,
                favoriteCount: tweet.favoriteCount ?? 0,
                bookmarkCount: tweet.bookmarkCount ?? 0,
                retweetCount: tweet.retweetCount ?? 0,
                commentCount: tweet.commentCount ?? 0,
                attachments: tweet.attachments,
                isPrivate: tweet.isPrivate,
                downloadable: tweet.downloadable
            )
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
            // First check in-memory singleton
            let userSingleton = User.getInstance(mid: mid)
            
            // If singleton has data (username is not nil), return it immediately
            if userSingleton.username != nil {
                continuation.resume(returning: userSingleton)
                return
            }
            
            // Otherwise, load from Core Data cache
            // Capture only mid (Sendable) instead of userSingleton (non-Sendable)
            context.perform {
                let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
                request.predicate = NSPredicate(format: "mid == %@", mid)
                
                if let cdUser = try? self.context.fetch(request).first {
                    // Update singleton with cached data
                    _ = User.from(cdUser: cdUser)
                }
                // Always return the singleton (updated or not)
                continuation.resume(returning: User.getInstance(mid: mid))
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
    
    /// Synchronous save - blocks until complete (use for critical updates like avatar)
    func saveUserAndWait(_ user: User) {
        context.performAndWait {
            let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
            request.predicate = NSPredicate(format: "mid == %@", user.mid)
            let cdUser = (try? self.context.fetch(request).first) ?? CDUser(context: self.context)
            cdUser.mid = user.mid
            cdUser.timeCached = Date()
            if let userData = try? JSONEncoder().encode(user) {
                cdUser.userData = userData
                print("DEBUG: [saveUserAndWait] Saved user \(user.mid) with avatar: \(user.avatar ?? "nil")")
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
    
    /// Search for users by partial username or name match
    /// Only returns users with valid usernames (username is required, name is optional)
    /// Uses multi-source search with relevance scoring (matches Android implementation)
    func searchUsers(query: String, limit: Int = 25) async -> [User] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        
        let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var scoredResults: [String: (score: Int, user: User)] = [:]
        
        // Helper function to calculate match score (lower is better)
        func matchScore(for user: User, query: String) -> Int? {
            guard let username = user.username, !username.isEmpty else {
                return nil // Skip users without valid username
            }
            
            let usernameLower = username.lowercased()
            let nameLower = user.name?.lowercased() ?? ""
            
            // Prioritize matches: prefix > contains, username > name
            if usernameLower.hasPrefix(query) {
                return 0 // Best: username starts with query
            } else if usernameLower.contains(query) {
                return 1 // Good: username contains query
            } else if nameLower.hasPrefix(query) {
                return 2 // OK: name starts with query
            } else if nameLower.contains(query) {
                return 3 // Lower priority: name contains query
            }
            return nil
        }
        
        // Helper to consider a user for results
        func consider(_ user: User) {
            guard let score = matchScore(for: user, query: normalizedQuery) else { return }
            
            // Keep the best score for each user
            if let existing = scoredResults[user.mid] {
                if score < existing.score {
                    scoredResults[user.mid] = (score, user)
                }
            } else {
                scoredResults[user.mid] = (score, user)
            }
        }
        
        // Step 1: Search in-memory User singletons (fast)
        let memoryUsers = User.getAllInstances()
        for (_, user) in memoryUsers {
            consider(user)
            if scoredResults.count >= limit { break }
        }
        
        // Step 2: Search cached users in Core Data
        if scoredResults.count < limit {
            let coreDataUsers = await withCheckedContinuation { (continuation: CheckedContinuation<[User], Never>) in
                context.perform {
                    let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
                    request.fetchLimit = 100 // Get more candidates for better results
                    
                    var users: [User] = []
                    if let cdUsers = try? self.context.fetch(request) {
                        for cdUser in cdUsers {
                            let user = User.from(cdUser: cdUser)
                            users.append(user)
                        }
                    }
                    continuation.resume(returning: users)
                }
            }
            
            // Consider users outside the closure to avoid Sendable warnings
            for user in coreDataUsers {
                if scoredResults.count >= limit { break }
                consider(user)
            }
        }
        
        // Step 3: Search users from cached tweets (tweet authors)
        if scoredResults.count < limit {
            let candidateUserIds = await withCheckedContinuation { (continuation: CheckedContinuation<Set<String>, Never>) in
                context.perform {
                    let tweetRequest: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
                    tweetRequest.sortDescriptors = [NSSortDescriptor(key: "timeCached", ascending: false)]
                    tweetRequest.fetchLimit = 200 // Check recent tweets for author candidates
                    
                    var userIds = Set<String>()
                    if let cdTweets = try? self.context.fetch(tweetRequest) {
                        // Collect unique author IDs from recent tweets by decoding tweet data
                        for cdTweet in cdTweets {
                            if let tweetData = cdTweet.tweetData,
                               let tweet = try? JSONDecoder().decode(Tweet.self, from: tweetData) {
                                userIds.insert(tweet.authorId)
                            }
                            if userIds.count >= 50 { break }
                        }
                    }
                    continuation.resume(returning: userIds)
                }
            }
            
            // Fetch and consider these users outside the closure
            for userId in candidateUserIds {
                if scoredResults.count >= limit { break }
                if scoredResults[userId] != nil { continue } // Already have this user
                
                let user = User.getInstance(mid: userId)
                if user.username != nil {
                    consider(user)
                }
            }
        }
        
        // Sort by score (lower is better), then alphabetically by username
        let sortedResults = scoredResults.values
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score < rhs.score
                }
                let username1 = lhs.user.username?.lowercased() ?? ""
                let username2 = rhs.user.username?.lowercased() ?? ""
                return username1 < username2
            }
            .prefix(limit)
            .map { $0.user }
        
        return Array(sortedResults)
    }
    
    /// Search for users incrementally, calling the callback after each source completes
    /// This provides a responsive UI by showing results as they're found
    func searchUsersIncremental(
        query: String,
        limit: Int = 25,
        onResults: @escaping ([User]) async -> Void
    ) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await onResults([])
            return
        }
        
        let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var scoredResults: [String: (score: Int, user: User)] = [:]
        
        // Helper function to calculate match score (lower is better)
        func matchScore(for user: User, query: String) -> Int? {
            guard let username = user.username, !username.isEmpty else {
                return nil // Skip users without valid username
            }
            
            let usernameLower = username.lowercased()
            let nameLower = user.name?.lowercased() ?? ""
            
            // Prioritize matches: prefix > contains, username > name
            if usernameLower.hasPrefix(query) {
                return 0 // Best: username starts with query
            } else if usernameLower.contains(query) {
                return 1 // Good: username contains query
            } else if nameLower.hasPrefix(query) {
                return 2 // OK: name starts with query
            } else if nameLower.contains(query) {
                return 3 // Lower priority: name contains query
            }
            return nil
        }
        
        // Helper to consider a user for results
        func consider(_ user: User) {
            guard let score = matchScore(for: user, query: normalizedQuery) else { return }
            
            // Keep the best score for each user
            if let existing = scoredResults[user.mid] {
                if score < existing.score {
                    scoredResults[user.mid] = (score, user)
                }
            } else {
                scoredResults[user.mid] = (score, user)
            }
        }
        
        // Helper to sort and return current results
        func getSortedResults() -> [User] {
            let sorted = scoredResults.values
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score {
                        return lhs.score < rhs.score
                    }
                    let username1 = lhs.user.username?.lowercased() ?? ""
                    let username2 = rhs.user.username?.lowercased() ?? ""
                    return username1 < username2
                }
                .prefix(limit)
                .map { $0.user }
            return Array(sorted)
        }
        
        // Step 1: Search in-memory User singletons (fast) - show immediately
        let memoryUsers = User.getAllInstances()
        for (_, user) in memoryUsers {
            consider(user)
            if scoredResults.count >= limit { break }
        }
        
        // Show first results immediately
        if !scoredResults.isEmpty {
            await onResults(getSortedResults())
        }
        
        // Step 2: Search cached users in Core Data - update UI
        if scoredResults.count < limit {
            let coreDataUsers = await withCheckedContinuation { (continuation: CheckedContinuation<[User], Never>) in
                context.perform {
                    let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
                    request.fetchLimit = 100
                    
                    var users: [User] = []
                    if let cdUsers = try? self.context.fetch(request) {
                        for cdUser in cdUsers {
                            let user = User.from(cdUser: cdUser)
                            users.append(user)
                        }
                    }
                    continuation.resume(returning: users)
                }
            }
            
            // Consider users outside the closure to avoid Sendable warnings
            for user in coreDataUsers {
                if scoredResults.count >= limit { break }
                consider(user)
            }
            
            // Show updated results
            await onResults(getSortedResults())
        }
        
        // Step 3: Search users from cached tweets (tweet authors) - final update
        if scoredResults.count < limit {
            let candidateUserIds = await withCheckedContinuation { (continuation: CheckedContinuation<Set<String>, Never>) in
                context.perform {
                    let tweetRequest: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
                    tweetRequest.sortDescriptors = [NSSortDescriptor(key: "timeCached", ascending: false)]
                    tweetRequest.fetchLimit = 200
                    
                    var userIds = Set<String>()
                    if let cdTweets = try? self.context.fetch(tweetRequest) {
                        // Collect unique author IDs from recent tweets by decoding tweet data
                        for cdTweet in cdTweets {
                            if let tweetData = cdTweet.tweetData,
                               let tweet = try? JSONDecoder().decode(Tweet.self, from: tweetData) {
                                userIds.insert(tweet.authorId)
                            }
                            if userIds.count >= 50 { break }
                        }
                    }
                    continuation.resume(returning: userIds)
                }
            }
            
            // Fetch and consider these users outside the closure
            for userId in candidateUserIds {
                if scoredResults.count >= limit { break }
                if scoredResults[userId] != nil { continue }
                
                let user = User.getInstance(mid: userId)
                if user.username != nil {
                    consider(user)
                }
            }
            
            // Show final results
            await onResults(getSortedResults())
        }
    }
    
    /// Search for tweets by content and title only (not author username/name)
    /// Matches Android implementation - only searches in content and title
    func searchTweets(query: String, limit: Int = 40) async -> [Tweet] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        
        let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var scoredResults: [String: (score: Int, tweet: Tweet)] = [:]
        
        // Helper function to calculate match score (lower is better)
        // Only matches content and title, NOT author username/name
        func matchScore(for tweet: Tweet, query: String) -> Int? {
            // Skip private tweets
            if tweet.isPrivate ?? false {
                return nil
            }
            
            let contentLower = tweet.content?.lowercased() ?? ""
            let titleLower = tweet.title?.lowercased() ?? ""
            
            // Prioritize matches: prefix > contains, content > title
            if contentLower.hasPrefix(query) {
                return 0 // Best: content starts with query
            } else if contentLower.contains(query) {
                return 1 // Good: content contains query
            } else if titleLower.hasPrefix(query) {
                return 2 // OK: title starts with query
            } else if titleLower.contains(query) {
                return 3 // Lower priority: title contains query
            }
            return nil
        }
        
        // Helper to consider a tweet for results
        func consider(_ tweet: Tweet) {
            guard let score = matchScore(for: tweet, query: normalizedQuery) else { return }
            
            // Keep the best score for each tweet
            if let existing = scoredResults[tweet.mid] {
                if score < existing.score {
                    scoredResults[tweet.mid] = (score, tweet)
                }
            } else {
                scoredResults[tweet.mid] = (score, tweet)
            }
        }
        
        // Step 1: Search in-memory tweet singletons (fast)
        let memoryTweets = Tweet.getAllInstances()
        for (_, tweet) in memoryTweets {
            consider(tweet)
            if scoredResults.count >= limit { break }
        }
        
        // Step 2: Search cached tweets in Core Data
        if scoredResults.count < limit {
            let coreDataTweets = await withCheckedContinuation { (continuation: CheckedContinuation<[Tweet], Never>) in
                context.perform {
                    let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
                    request.sortDescriptors = [NSSortDescriptor(key: "timeCached", ascending: false)]
                    request.fetchLimit = 400 // Get more candidates for better results
                    
                    var tweets: [Tweet] = []
                    if let cdTweets = try? self.context.fetch(request) {
                        for cdTweet in cdTweets {
                            if let tweetData = cdTweet.tweetData,
                               let tweet = try? JSONDecoder().decode(Tweet.self, from: tweetData) {
                                tweets.append(tweet)
                            }
                            if tweets.count >= 400 { break }
                        }
                    }
                    continuation.resume(returning: tweets)
                }
            }
            
            // Consider tweets outside the closure to avoid Sendable warnings
            for tweet in coreDataTweets {
                if scoredResults.count >= limit { break }
                consider(tweet)
            }
        }
        
        // Sort by score (lower is better), then by timestamp (newer first)
        let sortedResults = scoredResults.values
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score < rhs.score
                }
                // If scores are equal, sort by timestamp (newer first)
                return lhs.tweet.timestamp > rhs.tweet.timestamp
            }
            .prefix(limit)
            .map { $0.tweet }
        
        // Ensure authors are loaded for display
        for tweet in sortedResults {
            if tweet.author == nil {
                tweet.author = User.getInstance(mid: tweet.authorId)
            }
        }
        
        return Array(sortedResults)
    }
} 


