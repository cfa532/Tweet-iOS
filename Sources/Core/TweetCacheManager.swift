import CoreData
import Foundation
import UIKit

final class TweetCacheManager: @unchecked Sendable {
    static let shared = TweetCacheManager()
    static func mainFeedCacheKey(appUserId: String) -> String {
        "main_feed_\(appUserId)"
    }

    static func bookmarkCacheKey(userId: String) -> String {
        "\(UserContentType.BOOKMARKS.rawValue)_\(userId)"
    }

    static func favoriteCacheKey(userId: String) -> String {
        "\(UserContentType.FAVORITES.rawValue)_\(userId)"
    }

    private let coreDataManager = CoreDataManager.shared
    private let maxCacheAge: TimeInterval = 14 * 24 * 60 * 60 // 14 days (2 weeks) for auto-cleanup
    private let maxCacheSize: Int = 5000 // Maximum number of tweets to cache
    private nonisolated(unsafe) var cleanupTimer: Timer?
    
    // Track last access time for tweets (in memory, persisted to UserDefaults).
    // TweetCacheManager is @unchecked Sendable; all access to this dict goes through
    // locked helpers so a future off-main caller can't race the dict.
    private var tweetAccessTimes: [String: Date] = [:]
    private let accessTimesLock = NSLock()
    private let accessTimesKey = "TweetAccessTimes"

    private func lockedAccessTime(for id: String) -> Date? {
        accessTimesLock.lock(); defer { accessTimesLock.unlock() }
        return tweetAccessTimes[id]
    }
    private func lockedSetAccessTime(_ date: Date, for id: String) {
        accessTimesLock.lock(); defer { accessTimesLock.unlock() }
        tweetAccessTimes[id] = date
    }
    private func lockedAccessCount() -> Int {
        accessTimesLock.lock(); defer { accessTimesLock.unlock() }
        return tweetAccessTimes.count
    }
    private func lockedRemoveAccessTime(for id: String) {
        accessTimesLock.lock(); defer { accessTimesLock.unlock() }
        tweetAccessTimes.removeValue(forKey: id)
    }
    private func lockedClearAccessTimes() {
        accessTimesLock.lock(); defer { accessTimesLock.unlock() }
        tweetAccessTimes.removeAll()
    }
    private func lockedSnapshotAccessTimes() -> [String: Date] {
        accessTimesLock.lock(); defer { accessTimesLock.unlock() }
        return tweetAccessTimes
    }
    private func lockedSetAccessTimes(_ times: [String: Date]) {
        accessTimesLock.lock(); defer { accessTimesLock.unlock() }
        tweetAccessTimes = times
    }

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
            lockedSetAccessTimes(times)
            print("DEBUG: [TweetCacheManager] Loaded \(times.count) tweet access times")
        }
    }
    
    // Save access times to UserDefaults
    private func saveAccessTimes() {
        if let data = try? JSONEncoder().encode(lockedSnapshotAccessTimes()) {
            UserDefaults.standard.set(data, forKey: accessTimesKey)
        }
    }
    
    // Mark tweet as accessed (called when tweet is viewed)
    func markTweetAccessed(_ tweetId: String) {
        lockedSetAccessTime(Date(), for: tweetId)
        // Save periodically, not on every access (performance)
        if lockedAccessCount() % 20 == 0 {
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
    
    var context: NSManagedObjectContext { coreDataManager.cacheContext }
    private var readContext: NSManagedObjectContext { coreDataManager.cacheReadContext }
    
    // MARK: - Media Cleanup

    @MainActor
    private func clearHeightCache(for tweetId: String) {
        if let tweet = Tweet.getInstance(for: tweetId) {
            tweet.cachedHeight = nil
            tweet.cachedHeightWidth = 0
        }
        TweetHeightCache.shared.removeHeight(for: tweetId)
    }

    @MainActor
    private func clearHeightCache(for tweet: Tweet) {
        tweet.cachedHeight = nil
        tweet.cachedHeightWidth = 0
        clearHeightCache(for: tweet.mid)
    }

    /// Delete media files associated with a tweet
    @MainActor
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

    private func deleteMediaForTweetRecord(_ tweet: TweetRecord) {
        let mediaIds = tweet.attachments?.map(\.mid) ?? []
        guard !mediaIds.isEmpty else { return }

        print("DEBUG: [TweetCacheManager] Deleting \(mediaIds.count) media files for tweet \(tweet.mid)")

        Task { @MainActor in
            for mediaId in mediaIds {
                SharedAssetCache.shared.clearAssetCache(for: mediaId)
            }
        }

        for mediaId in mediaIds {
            ImageCacheManager.shared.clearCache(for: mediaId)
        }
    }
    
    // MARK: - Manual Cleanup (Settings Screen)
    
    /// Manual cleanup from settings screen - clears everything including private tweets
    @MainActor
    func manualClearAllCache() {
        print("DEBUG: [TweetCacheManager] Manual cache clear - clearing EVERYTHING")

        // Log initial state
        let initialTweetCount = context.performAndWait {
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            return (try? context.fetch(request).count) ?? 0
        }
        print("DEBUG: [TweetCacheManager] Initial tweet count: \(initialTweetCount)")

        context.performAndWait {
            // Get all tweets
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            if let allTweets = try? context.fetch(request) {
                print("DEBUG: [TweetCacheManager] Manual clear: deleting \(allTweets.count) tweets and their media")

                for cdTweet in allTweets {
                    // Delete associated media (clears from caches per media ID)
                    if let tweet = try? decodeTweetRecord(from: cdTweet) {
                        deleteMediaForTweetRecord(tweet)
                    }

                    // Delete tweet from CoreData
                    context.delete(cdTweet)
                }

                try? context.save()
                print("DEBUG: [TweetCacheManager] CoreData tweets deleted successfully")
            }
        }

        // Clear access times
        lockedClearAccessTimes()
        saveAccessTimes()
        print("DEBUG: [TweetCacheManager] Access times cleared")
        TweetHeightCache.shared.clearAll()

        // Final sweep: clear any remaining caches that might not be tweet-associated
        Task { @MainActor in
            SharedAssetCache.shared.clearAllCaches()
            print("DEBUG: [TweetCacheManager] SharedAssetCache cleared")
        }
        ImageCacheManager.shared.clearAllCache()
        print("DEBUG: [TweetCacheManager] ImageCacheManager cleared")

        // Clear memory cache
        Tweet.clearAllInstances()
        print("DEBUG: [TweetCacheManager] Memory cache cleared")

        // Verify cleanup
        let finalTweetCount = context.performAndWait {
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            return (try? context.fetch(request).count) ?? 0
        }
        print("✅ Manual cache clear complete - final tweet count: \(finalTweetCount)")
    }
    
    // MARK: - Signout Cleanup
    
    /// Clear everything on signout
    @MainActor
    func clearCacheOnSignout() {
        print("DEBUG: [TweetCacheManager] Signout - clearing EVERYTHING")
        manualClearAllCache()
    }
}

// MARK: - Tweet Caching
extension TweetCacheManager {
    /// One Core Data row maps to either no list slot (skipped) or one slot in `[Tweet?]` (tweet or `nil` placeholder).
    private struct CachedTweetPayload: Sendable {
        var tweet: TweetRecord
        var author: UserRecord?
        var originalTweet: TweetRecord?
        var originalAuthor: UserRecord?
    }

    private enum CachedTweetListSlot {
        case skip
        case emit(CachedTweetPayload?)
    }

    /// Maps a cached row to a profile/main-feed list slot using the same rules as `fetchCachedTweets`.
    private func decodeTweetRecord(from cdTweet: CDTweet) throws -> TweetRecord {
        guard let tweetData = cdTweet.tweetData else {
            throw NSError(domain: "TweetCacheManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cached tweet row has no tweetData"])
        }
        return try TweetRecord.fromCacheData(tweetData)
    }

    private func cachedUserRecord(mid: String, in context: NSManagedObjectContext) -> UserRecord? {
        let userRequest: NSFetchRequest<CDUser> = CDUser.fetchRequest()
        userRequest.predicate = NSPredicate(format: "mid == %@", mid)
        guard let cdUser = try? context.fetch(userRequest).first,
              let userData = cdUser.userData else {
            return nil
        }
        return try? UserRecord.fromCacheData(userData)
    }

    /// Maps a cached row to a profile/main-feed list slot using the same rules as `fetchCachedTweets`.
    private func cachedTweetListSlot(
        cdTweet: CDTweet,
        userId: String,
        shouldFilterByAuthorId: Bool,
        currentUserId: String?,
        in context: NSManagedObjectContext
    ) -> CachedTweetListSlot {
        do {
            let tweet = try decodeTweetRecord(from: cdTweet)

            if shouldFilterByAuthorId && tweet.authorId != userId {
                return .skip
            }

            let authorRecord = cachedUserRecord(mid: tweet.authorId, in: context)

            var originalTweetRecord: TweetRecord?
            var originalAuthorRecord: UserRecord?
            if let originalTweetId = tweet.originalTweetId, tweet.originalAuthorId != nil {
                let origRequest: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
                origRequest.predicate = NSPredicate(format: "tid == %@", originalTweetId)
                origRequest.fetchLimit = 1
                if let cdOrigTweet = try? context.fetch(origRequest).first,
                   let decodedOriginal = try? decodeTweetRecord(from: cdOrigTweet) {
                    originalTweetRecord = decodedOriginal
                    originalAuthorRecord = cachedUserRecord(mid: decodedOriginal.authorId, in: context)
                }
            }

            if tweet.timestamp.timeIntervalSince1970 <= 0 {
                print("ERROR: [TweetCacheManager] Found cached tweet with invalid timestamp: \(tweet.timestamp), skipping")
                return .emit(nil)
            }

            let isBookmarkOrFavorite = userId.hasPrefix("bookmark_list_") || userId.hasPrefix("favorite_list_")

            if tweet.isPrivate == true && !isBookmarkOrFavorite {
                if shouldFilterByAuthorId && currentUserId != nil && userId == currentUserId {
                    return .emit(CachedTweetPayload(tweet: tweet, author: authorRecord, originalTweet: originalTweetRecord, originalAuthor: originalAuthorRecord))
                } else {
                    return .skip
                }
            } else {
                return .emit(CachedTweetPayload(tweet: tweet, author: authorRecord, originalTweet: originalTweetRecord, originalAuthor: originalAuthorRecord))
            }
        } catch {
            print("Error processing tweet: \(error)")
            return .emit(nil)
        }
    }

    func fetchCachedTweets(for userId: String, page: UInt, pageSize: UInt, currentUserId: String? = nil, isProfileView: Bool = false) async -> [Tweet?] {
        let cachedSlots = await withCheckedContinuation { (continuation: CheckedContinuation<[CachedTweetPayload?], Never>) in
            let readContext = self.readContext
            readContext.perform {
                readContext.refreshAllObjects()
                let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()

                // For profile views: load from the profile user's cache key and filter by authorId.
                // For main feed/list views: load from the explicit list cache key, no authorId filtering.
                let shouldFilterByAuthorId = isProfileView

                // Always load from the requested cache key. For profile views this equals authorId.
                request.predicate = NSPredicate(format: "uid == %@", userId)

                // For bookmarks and favorites, sort by timeCached (when bookmarked/favorited)
                // For other types, sort by timestamp (tweet creation time)
                let isBookmarkOrFavorite = userId.hasPrefix("bookmark_list_") || userId.hasPrefix("favorite_list_")
                if isBookmarkOrFavorite {
                    request.sortDescriptors = [NSSortDescriptor(key: "timeCached", ascending: false)]
                } else {
                    request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                }

                let pageSizeInt = Int(pageSize)
                let startSlot = Int(page) * pageSizeInt
                let endSlot = startSlot + pageSizeInt

                if shouldFilterByAuthorId {
                    // Profile: offset/limit on Core Data rows does NOT match filtered list slots (skipped rows
                    // don't count). Paginate by advancing through sorted CD rows in batches and counting emitted slots.
                    var slotIndex = 0
                    var pageTweets: [CachedTweetPayload?] = []
                    var cdOffset = 0
                    let batchSize = max(pageSizeInt * 4, 64)

                    fetchLoop: while pageTweets.count < pageSizeInt {
                        request.fetchOffset = cdOffset
                        request.fetchLimit = batchSize
                        guard let batch = try? readContext.fetch(request), !batch.isEmpty else { break }

                        for cdTweet in batch {
                            switch self.cachedTweetListSlot(
                                cdTweet: cdTweet,
                                userId: userId,
                                shouldFilterByAuthorId: shouldFilterByAuthorId,
                                currentUserId: currentUserId,
                                in: readContext
                            ) {
                            case .skip:
                                break
                            case .emit(let value):
                                if slotIndex >= startSlot && slotIndex < endSlot {
                                    pageTweets.append(value)
                                }
                                slotIndex += 1
                                if pageTweets.count >= pageSizeInt { break fetchLoop }
                            }
                        }

                        cdOffset += batch.count
                        if batch.count < batchSize { break }
                    }

                    continuation.resume(returning: pageTweets)
                    return
                }

                request.fetchLimit = pageSizeInt
                request.fetchOffset = startSlot

                if let cdTweets = try? readContext.fetch(request) {
                    var tweets: [CachedTweetPayload?] = []
                    for cdTweet in cdTweets {
                        switch self.cachedTweetListSlot(
                            cdTweet: cdTweet,
                            userId: userId,
                            shouldFilterByAuthorId: shouldFilterByAuthorId,
                            currentUserId: currentUserId,
                            in: readContext
                        ) {
                        case .skip:
                            break
                        case .emit(let value):
                            tweets.append(value)
                        }
                    }

                    continuation.resume(returning: tweets)
                } else {
                    continuation.resume(returning: [])
                }
            }
        }

        return await MainActor.run {
            cachedSlots.map { payload in
                guard let payload else { return nil }

                if let originalTweet = payload.originalTweet {
                    let originalAuthor = payload.originalAuthor.map {
                        UserStore.shared.merge($0, shouldUpdateBaseUrl: true)
                    } ?? UserStore.shared.user(mid: originalTweet.authorId)
                    _ = TweetStore.shared.merge(originalTweet, author: originalAuthor)
                }

                let author = payload.author.map {
                    UserStore.shared.merge($0, shouldUpdateBaseUrl: true)
                } ?? UserStore.shared.user(mid: payload.tweet.authorId)
                return TweetStore.shared.merge(payload.tweet, author: author)
            }
        }
    }

    /// Fetch a tweet by its mid (tweet ID) from cache
    /// IMPORTANT: Searches across ALL user caches, not just a specific user's cache
    /// This is necessary because:
    /// - Original tweets are cached under their authorId
    /// - Main feed entries are cached under `main_feed_<appUserId>`
    /// - When we only have a tweet mid, we don't know which user's cache it's in
    /// Synchronously fetch tweet from cache (in-memory singleton or Core Data)
    /// Used for height estimation and other synchronous operations
    /// Returns nil if tweet is not cached
    @MainActor
    func fetchTweetSync(mid: String) -> Tweet? {
        // First check in-memory singleton
        if let tweetInstance = TweetStore.shared.tweet(mid: mid) {
            return tweetInstance
        }
        
        // Otherwise, load from Core Data cache synchronously
        let cachedPayload = context.performAndWait { () -> (tweet: TweetRecord, author: UserRecord?)? in
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            request.predicate = NSPredicate(format: "tid == %@", mid)
            request.sortDescriptors = [NSSortDescriptor(key: "timeCached", ascending: false)]
            
            guard let cdTweet = try? context.fetch(request).first else {
                return nil
            }
            
            do {
                let tweet = try decodeTweetRecord(from: cdTweet)
                let author = cachedUserRecord(mid: tweet.authorId, in: context)
                return (tweet, author)
            } catch {
                print("Error processing tweet synchronously: \(error)")
                return nil
            }
        }

        guard let cachedPayload else { return nil }
        let author = cachedPayload.author.map {
            UserStore.shared.merge($0, shouldUpdateBaseUrl: true)
        } ?? UserStore.shared.user(mid: cachedPayload.tweet.authorId)
        return TweetStore.shared.merge(cachedPayload.tweet, author: author)
    }
    
    func fetchTweet(mid: String) async -> Tweet? {
        if let tweetInstance = await MainActor.run(body: { TweetStore.shared.tweet(mid: mid) }) {
            return tweetInstance
        }

        let cachedPayload = await withCheckedContinuation { (continuation: CheckedContinuation<(tweet: TweetRecord, author: UserRecord?)?, Never>) in
            context.perform {
                let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
                request.predicate = NSPredicate(format: "tid == %@", mid)
                request.sortDescriptors = [NSSortDescriptor(key: "timeCached", ascending: false)]

                guard let cdTweet = try? self.context.fetch(request).first else {
                    continuation.resume(returning: nil)
                    return
                }

                do {
                    let tweetRecord = try self.decodeTweetRecord(from: cdTweet)
                    let authorRecord = self.cachedUserRecord(mid: tweetRecord.authorId, in: self.context)

                    cdTweet.timeCached = Date()
                    try? self.context.save()

                    continuation.resume(returning: (tweetRecord, authorRecord))
                } catch {
                    print("Error processing tweet: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }

        guard let cachedPayload else { return nil }

        return await MainActor.run {
            let author = cachedPayload.author.map {
                UserStore.shared.merge($0, shouldUpdateBaseUrl: true)
            } ?? UserStore.shared.user(mid: cachedPayload.tweet.authorId)
            return TweetStore.shared.merge(cachedPayload.tweet, author: author)
        }
    }

    /// Save a tweet to the cache. If tweet is nil, do nothing. To remove a tweet, use deleteTweet.
    /// If a tweet with the same mid already exists, it will be updated with new counts and favorites instead of being replaced.
    /// - Parameters:
    ///   - tweet: The tweet to save
    ///   - userId: The cache key (e.g., "main_feed_userId", "bookmark_list_userId", or user's mid)
    ///   - timeCached: Optional timestamp to use for timeCached. If nil, uses current Date().
    ///                 For bookmarks/favorites, this should be set to preserve server order.
    @MainActor
    func saveTweet(_ tweet: Tweet, userId: String, timeCached: Date? = nil) {
        let record = TweetRecord(tweet: tweet)
        let tweetId = record.mid
        let timestamp = record.timestamp
        let attachments = record.attachments ?? []
        let isPrivate = record.isPrivate == true

        // Validate timestamp before caching
        if timestamp.timeIntervalSince1970 <= 0 {
            print("ERROR: [TweetCacheManager] Attempting to cache tweet with invalid timestamp: \(timestamp), skipping cache")
            return
        }

        // JSON encoding is moved inside context.perform so it runs on the CoreData
        // background queue rather than on @MainActor, preventing startup freezes when
        // saveTweet is called in a tight loop for many tweets.
        context.perform {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            guard let tweetData = try? encoder.encode(record) else {
                print("ERROR: [TweetCacheManager] Failed to encode tweet record \(tweetId), skipping cache")
                return
            }
            // A tweet can belong to multiple cached lists at the same time: main feed,
            // the author's profile, bookmarks, favorites, etc. Keep list membership
            // keyed by (tweet id, cache key) so saving one list does not move the tweet
            // out of another list's cache.
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            request.predicate = NSPredicate(format: "tid == %@", tweetId)
            let existingRows = (try? self.context.fetch(request)) ?? []
            let cdTweet = existingRows.first { $0.uid == userId } ?? CDTweet(context: self.context)

            let rowAlreadyExists = existingRows.contains { $0.objectID == cdTweet.objectID }
            let rowsToUpdate = rowAlreadyExists ? existingRows : existingRows + [cdTweet]
            if rowsToUpdate.contains(where: { $0.tweetData != nil && $0.tweetData != tweetData }) {
                Task { @MainActor in
                    self.clearHeightCache(for: tweetId)
                }
            }
            for row in rowsToUpdate {
                row.tweetData = tweetData
                row.tid = tweetId
                row.timestamp = timestamp
            }
                        
            // Update this list's membership fields.
            cdTweet.tid = tweetId
            cdTweet.uid = userId
            cdTweet.timestamp = timestamp
            // Use provided timeCached, or current time if not provided
            // For bookmarks/favorites, timeCached should be set to preserve server order
            cdTweet.timeCached = timeCached ?? Date()
            
            try? self.context.save()
        }
        
        // Mark media as permanent for: private tweets OR bookmarks/favorites
        let isBookmarkOrFavorite = userId.hasPrefix("bookmark_list_") || userId.hasPrefix("favorite_list_")
        
        if isPrivate || isBookmarkOrFavorite {
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
    /// Main feed tweets are cached under a dedicated list key for efficient loading.
    /// Profile tweets should use saveTweet directly with their authorId.
    @MainActor
    func updateTweetInAppUserCaches(_ tweet: Tweet, appUserId: String) {
        saveTweet(tweet, userId: Self.mainFeedCacheKey(appUserId: appUserId))
    }

    func deleteExpiredTweets() {
        // Fire-and-forget on the background context queue (perform, not performAndWait):
        // this iterates and decodes every cached tweet, which stalled startup when run
        // synchronously on the @MainActor caller. Cleanup has no completion dependency.
        context.perform { [self] in
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            let expirationDate = Date().addingTimeInterval(-maxCacheAge)
            
            if let allCachedTweets = try? context.fetch(request) {
                var deletedCount = 0
                var preservedPrivateCount = 0
                
                for cdTweet in allCachedTweets {
                    guard let tweetId = cdTweet.tid else { continue }
                    
                    // Decode tweet to check if it's private
                    guard let tweet = try? decodeTweetRecord(from: cdTweet) else { continue }
                    
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
                    let lastAccess = lockedAccessTime(for: tweetId) ?? (cdTweet.timeCached ?? Date.distantPast)
                    
                    if lastAccess < expirationDate {
                        // Tweet hasn't been accessed in 2 weeks - delete it and its media
                        print("DEBUG: [TweetCacheManager] Deleting expired tweet: \(tweetId) (last access: \(lastAccess))")
                        
                        // Delete associated media files
                        deleteMediaForTweetRecord(tweet)
                        
                        // Remove from access times
                        lockedRemoveAccessTime(for: tweetId)
                        Task { @MainActor in
                            self.clearHeightCache(for: tweetId)
                        }
                        
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
                    if let tweetId = tweet.tid {
                        Task { @MainActor in
                            self.clearHeightCache(for: tweetId)
                        }
                    }
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
                    if let tweetId = cdTweet.tid {
                        Task { @MainActor in
                            self.clearHeightCache(for: tweetId)
                        }
                    }
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
                    if let tweet = try? decodeTweetRecord(from: cdTweet), tweet.authorId == userId {
                        // Remove from access times
                        lockedRemoveAccessTime(for: tweet.mid)
                        Task { @MainActor in
                            self.clearHeightCache(for: tweet.mid)
                        }
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
        TweetHeightCache.shared.clearAll()
        
        // Also clear all users for soft restart
        clearAllUsers()
    }
    
    /// Clear only memory cache (for memory management)
    @MainActor
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
                    if let tweetId = tweet.tid {
                        Task { @MainActor in
                            self.clearHeightCache(for: tweetId)
                        }
                    }
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
                    if let tweetId = tweet.tid {
                        Task { @MainActor in
                            self.clearHeightCache(for: tweetId)
                        }
                    }
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
            let instance = Tweet.getInstance(
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
            TweetHeightPrewarmer.shared.prewarm(instance)
            return instance
        }
        throw NSError(domain: "TweetCacheManager", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Failed to decode tweet data from Core Data"])
    }
}

// MARK: - User Caching
/// Might need to update baseUrl of cached user, which might be outdated.
extension TweetCacheManager {
    func fetchUser(mid: String) async -> User {
        // Single @MainActor hop for the fast path: returns immediately if singleton has a username.
        let (fallbackUser, cachedSingleton) = await MainActor.run {
            let user = UserStore.shared.user(mid: mid)
            return (user, user.username != nil ? user : nil)
        }
        if let cachedSingleton {
            return cachedSingleton
        }

        let cachedRecord = await withCheckedContinuation { (continuation: CheckedContinuation<UserRecord?, Never>) in
            context.perform {
                let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
                request.predicate = NSPredicate(format: "mid == %@", mid)

                guard let cdUser = try? self.context.fetch(request).first,
                      let userData = cdUser.userData,
                      let record = try? UserRecord.fromCacheData(userData) else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: record)
            }
        }

        guard let cachedRecord else {
            return fallbackUser
        }

        return await MainActor.run {
            UserStore.shared.merge(cachedRecord, shouldUpdateBaseUrl: true)
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

    @MainActor
    func saveUser(_ user: User) {
        let record = UserRecord(user: user)
        guard record.hasValidUsername else {
            print("DEBUG: [TweetCacheManager] Skipping invalid user cache write for \(record.mid): username is empty")
            return
        }

        // Use async perform to avoid blocking the main thread
        context.perform {
            let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
            request.predicate = NSPredicate(format: "mid == %@", record.mid)
            let cdUser = (try? self.context.fetch(request).first) ?? CDUser(context: self.context)
            cdUser.mid = record.mid
            cdUser.timeCached = Date()

            var recordToSave = record
            if User.sanitizedAvatarId(record.avatar) == nil,
               let existingData = cdUser.userData,
               let existingUser = try? UserRecord.fromCacheData(existingData),
               let existingAvatar = User.sanitizedAvatarId(existingUser.avatar) {
                recordToSave.avatar = existingAvatar
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let encodedUserData = try? encoder.encode(recordToSave)
            if let userData = encodedUserData {
                cdUser.userData = userData
            }
            try? self.context.save()
        }
    }
    

    func deleteExpiredUsers() {
        // User metadata is treated as stale-but-useful rather than disposable.
        // fetchUser marks/refreshes stale users; it should not lose names,
        // avatars, or route hints just because the Core Data timestamp aged out.
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
    @MainActor
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
            let coreDataUserRecords = await withCheckedContinuation { (continuation: CheckedContinuation<[UserRecord], Never>) in
                context.perform {
                    let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
                    request.fetchLimit = 100 // Get more candidates for better results
                    
                    var users: [UserRecord] = []
                    if let cdUsers = try? self.context.fetch(request) {
                        for cdUser in cdUsers {
                            guard let userData = cdUser.userData,
                                  let user = try? UserRecord.fromCacheData(userData) else { continue }
                            users.append(user)
                        }
                    }
                    continuation.resume(returning: users)
                }
            }

            let coreDataUsers = await MainActor.run {
                coreDataUserRecords.map { UserStore.shared.merge($0, shouldUpdateBaseUrl: true) }
            }
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
                               let tweet = try? TweetRecord.fromCacheData(tweetData) {
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
    @MainActor
    func searchUsersIncremental(
        query: String,
        limit: Int = 25,
        onResults: @escaping @MainActor @Sendable ([User]) async -> Void
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
            let coreDataUserRecords = await withCheckedContinuation { (continuation: CheckedContinuation<[UserRecord], Never>) in
                context.perform {
                    let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
                    request.fetchLimit = 100
                    
                    var users: [UserRecord] = []
                    if let cdUsers = try? self.context.fetch(request) {
                        for cdUser in cdUsers {
                            guard let userData = cdUser.userData,
                                  let user = try? UserRecord.fromCacheData(userData) else { continue }
                            users.append(user)
                        }
                    }
                    continuation.resume(returning: users)
                }
            }

            let coreDataUsers = await MainActor.run {
                coreDataUserRecords.map { UserStore.shared.merge($0, shouldUpdateBaseUrl: true) }
            }
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
                               let tweet = try? TweetRecord.fromCacheData(tweetData) {
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
    @MainActor
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
            let coreDataTweetRecords = await withCheckedContinuation { (continuation: CheckedContinuation<[TweetRecord], Never>) in
                context.perform {
                    let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
                    request.sortDescriptors = [NSSortDescriptor(key: "timeCached", ascending: false)]
                    request.fetchLimit = 400 // Get more candidates for better results
                    
                    var tweets: [TweetRecord] = []
                    if let cdTweets = try? self.context.fetch(request) {
                        for cdTweet in cdTweets {
                            if let tweetData = cdTweet.tweetData,
                               let tweet = try? TweetRecord.fromCacheData(tweetData) {
                                tweets.append(tweet)
                            }
                            if tweets.count >= 400 { break }
                        }
                    }
                    continuation.resume(returning: tweets)
                }
            }

            let coreDataTweets = await MainActor.run {
                coreDataTweetRecords.map { record in
                    TweetStore.shared.merge(record)
                }
            }
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
