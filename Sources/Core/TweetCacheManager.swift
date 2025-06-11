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
                        if let tweetData = cdTweet.tweetData,
                           let tweetDict = try? JSONSerialization.jsonObject(with: tweetData) as? [String: Any] {
                            do {
                                let tweet = try Tweet.from(dict: tweetDict)
                                tweets.append(tweet)
                            } catch {
                                print("Error processing tweet: \(error)")
                                tweets.append(nil)
                            }
                        } else {
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
//        if let tweetData = try? JSONEncoder().encode(tweet),
//           let tweetJson = String(data: tweetData, encoding: .utf8) {
//            print("Saving coredata tweet: \(tweetJson)")
//        } else {
//            print("Saving coredata tweet: <failed to encode tweet>")
//        }
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
            if let tweetDict = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(tweet)) as? [String: Any],
               let tweetData = try? JSONSerialization.data(withJSONObject: tweetDict) {
                cdTweet.tweetData = tweetData
            }
            try? context.save()
        }
    }

    func deleteExpiredTweets() {
        context.performAndWait {
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

    func clearAllTweets() {
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
    
    func shouldRefreshUser(mid: String) -> Bool {
        var shouldRefresh = true
        context.performAndWait {
            let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
            request.predicate = NSPredicate(format: "mid == %@", mid)
            if let cdUser = try? context.fetch(request).first {
                shouldRefresh = cdUser.timeCached?.timeIntervalSinceNow ?? 0 < -300 // 5 minutes
            }
            // If no cached user found, shouldRefresh remains true
        }
        return shouldRefresh
    }

    func saveUser(_ user: User) {
        if let userData = try? JSONEncoder().encode(user),
           let userJson = String(data: userData, encoding: .utf8) {
            print("Saving coredata user: \(userJson)")
        } else {
            print("Saving coredata user: <failed to encode user>")
        }
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
} 
