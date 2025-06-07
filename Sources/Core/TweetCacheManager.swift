import CoreData
import Foundation

class TweetCacheManager {
    static let shared = TweetCacheManager()
    let container: NSPersistentContainer

    private init() {
        container = NSPersistentContainer(name: "TweetModel")
        
        // Enable automatic lightweight migration
        let description = NSPersistentStoreDescription()
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]
        
        container.loadPersistentStores { _, error in
            if let error = error {
                // Log the error but don't crash
                print("Core Data failed to load: \(error)")
                
                // Try to recover by removing the store and creating a new one
                do {
                    try self.recoverFromError()
                } catch {
                    print("Failed to recover from Core Data error: \(error)")
                }
            }
        }
    }
    
    private func recoverFromError() throws {
        // Get the store URL
        guard let storeURL = container.persistentStoreDescriptions.first?.url else {
            throw NSError(domain: "TweetCacheManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No store URL found"])
        }
        
        // Remove the existing store
        try container.persistentStoreCoordinator.destroyPersistentStore(at: storeURL, ofType: NSSQLiteStoreType, options: nil)
        
        // Create a new store
        try container.persistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: nil)
    }

    var context: NSManagedObjectContext { container.viewContext }
}

// MARK: - Tweet Caching
extension TweetCacheManager {
    func fetchCachedTweets(for userId: String, page: UInt, pageSize: UInt) async -> [Tweet?] {
        let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
        request.predicate = NSPredicate(format: "uid == %@", userId)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchOffset = Int(page * pageSize)
        request.fetchLimit = Int(pageSize)
        
        if let cdTweets = try? context.fetch(request) {
            var tweets: [Tweet?] = []
            for cdTweet in cdTweets {
                if cdTweet.isNilPlaceholder {
                    tweets.append(nil)
                    continue
                }
                if let tweetData = cdTweet.tweetData,
                   let tweetDict = try? JSONSerialization.jsonObject(with: tweetData) as? [String: Any] {
                    do {
                        let tweet = try await MainActor.run {
                            try Tweet.from(dict: tweetDict)
                        }
                        tweets.append(tweet)
                    } catch {
                        print("Error processing tweet: \(error)")
                        tweets.append(nil)
                    }
                } else {
                    tweets.append(nil)
                }
            }
            return tweets
        }
        return []
    }

    func fetchTweet(mid: String) async -> Tweet? {
        let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
        request.predicate = NSPredicate(format: "tid == %@", mid)
        
        // First, get the tweet and convert it
        if let cdTweet = try? context.fetch(request).first {
            do {
                let tweet = try await MainActor.run {
                    try Tweet.from(cdTweet: cdTweet)
                }
                // Then update the cache time in a separate operation
                cdTweet.timeCached = Date()
                try? context.save()
                return tweet
            } catch {
                print("Error processing tweet: \(error)")
                return nil
            }
        }
        return nil
    }

    /// Save a tweet or a nil placeholder to the cache.
    func saveTweet(_ tweet: Tweet?, mid: String, userId: String) {
        context.performAndWait {
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            request.predicate = NSPredicate(format: "tid == %@", mid)
            
            let cdTweet: CDTweet
            if let existingTweet = try? context.fetch(request).first {
                cdTweet = existingTweet
            } else {
                cdTweet = CDTweet(context: context)
            }
            
            cdTweet.tid = mid
            cdTweet.uid = userId
            cdTweet.timestamp = Date()
            cdTweet.timeCached = Date()
            
            if let tweet = tweet {
                cdTweet.isNilPlaceholder = false
                // Convert tweet to dictionary for storage
                if let tweetDict = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(tweet)) as? [String: Any],
                   let tweetData = try? JSONSerialization.data(withJSONObject: tweetDict) {
                    cdTweet.tweetData = tweetData
                }
            } else {
                cdTweet.isNilPlaceholder = true
                cdTweet.tweetData = nil
            }
            
            try? context.save()
        }
    }

    func deleteExpiredTweets() {
        let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
        let oneMonthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        request.predicate = NSPredicate(format: "timeCached < %@", oneMonthAgo as NSDate)
        if let expiredTweets = try? context.fetch(request) {
            for tweet in expiredTweets {
                context.delete(tweet)
            }
            try? context.save()
        }
    }

    func deleteTweet(mid: String) {
        let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
        request.predicate = NSPredicate(format: "tid == %@", mid)
        if let cdTweet = try? context.fetch(request).first {
            context.delete(cdTweet)
            try? context.save()
        }
    }

    func clearAllTweets() {
        let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
        if let allTweets = try? context.fetch(request) {
            for tweet in allTweets {
                context.delete(tweet)
            }
            try? context.save()
        }
    }
}

// MARK: - Tweet <-> Core Data Conversion
extension Tweet {
    static func from(cdTweet: CDTweet) throws -> Tweet {
        if let tweetData = cdTweet.tweetData,
           let tweetDict = try? JSONSerialization.jsonObject(with: tweetData) as? [String: Any] {
            return try Tweet.from(dict: tweetDict)
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
extension TweetCacheManager {
    func fetchUser(mid: String) -> User {
        let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
        request.predicate = NSPredicate(format: "mid == %@", mid)
        
        // First, get the user and convert it
        if let cdUser = try? context.fetch(request).first {
            let user = User.from(cdUser: cdUser)
            // Then update the cache time in a separate operation
            cdUser.timeCached = Date()
            try? context.save()
            return user
        }
        return User.getInstance(mid: mid)
    }
    
    func shouldRefreshUser(mid: String) -> Bool {
        let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
        request.predicate = NSPredicate(format: "mid == %@", mid)
        if let cdUser = try? context.fetch(request).first {
            return cdUser.timeCached?.timeIntervalSinceNow ?? 0 < -300 // 5 minutes
        }
        return true // No cached user, we should refresh
    }

    func saveUser(_ user: User) {
        let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
        request.predicate = NSPredicate(format: "mid == %@", user.mid)
        let cdUser = (try? context.fetch(request).first) ?? CDUser(context: context)
        
        // Update essential properties
        cdUser.mid = user.mid
        cdUser.timeCached = Date()
        
        // Encode full user data
        if let userData = try? JSONEncoder().encode(user) {
            cdUser.userData = userData
        }
        
        try? context.save()
    }

    func deleteExpiredUsers() {
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
