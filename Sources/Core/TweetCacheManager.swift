import CoreData
import Foundation

@MainActor
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
                if let tweetData = cdTweet.tweetData,
                   let tweetDict = try? JSONSerialization.jsonObject(with: tweetData) as? [String: Any] {
                    do {
                        let tweet = try await Tweet.from(dict: tweetDict)
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
        // First, get the tweet data on the main actor
        let tweetData = await MainActor.run { () -> Data? in
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            request.predicate = NSPredicate(format: "tid == %@", mid)
            guard let cdTweet = try? context.fetch(request).first,
                  let data = cdTweet.tweetData else {
                return nil
            }
            
            // Update the cache time
            cdTweet.timeCached = Date()
            try? context.save()
            
            return data
        }
        
        // If we found tweet data, process it
        if let tweetData = tweetData,
           let tweetDict = try? JSONSerialization.jsonObject(with: tweetData) as? [String: Any] {
            do {
                return try await Tweet.from(dict: tweetDict)
            } catch {
                print("Error processing tweet: \(error)")
                return nil
            }
        }
        
        return nil
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
    static func from(cdTweet: CDTweet) async throws -> Tweet? {
        do {
            if let tweetData = cdTweet.tweetData,
               let tweetDict = try? JSONSerialization.jsonObject(with: tweetData) as? [String: Any] {
                return try await Tweet.from(dict: tweetDict)
            }
        } catch {
            throw NSError(domain: "TweetCacheManager", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to decode tweet data from Core Data"])
        }
        return nil
    }
}

// MARK: - User Caching
extension TweetCacheManager {
    func fetchUser(mid: String) async -> User {
        // First, get the user data on the main actor
        let userData = await MainActor.run { () -> Data? in
            let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
            request.predicate = NSPredicate(format: "mid == %@", mid)
            
            guard let cdUser = try? context.fetch(request).first,
                  let data = cdUser.userData else {
                return nil
            }
            
            // Update the cache time
            cdUser.timeCached = Date()
            try? context.save()
            
            return data
        }
        
        // If we found user data, process it
        if let userData = userData,
           let user = try? JSONDecoder().decode(User.self, from: userData) {
            return user
        }
        
        // If no cached user is found, return a new instance
        return User.getInstance(mid: mid)
    }
    
    func shouldRefreshUser(mid: String) -> Bool {
        let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
        request.predicate = NSPredicate(format: "mid == %@", mid)
        
        if let cdUser = try? context.fetch(request).first,
           let timeCached = cdUser.timeCached {
            let oneHourAgo = Calendar.current.date(byAdding: .hour, value: -1, to: Date())!
            return timeCached < oneHourAgo
        }
        return true
    }
    
    func saveUser(_ user: User) {
        context.performAndWait {
            let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
            request.predicate = NSPredicate(format: "mid == %@", user.mid)
            let cdUser: CDUser
            if let existingUser = try? context.fetch(request).first {
                cdUser = existingUser
            } else {
                cdUser = CDUser(context: context)
            }
            cdUser.mid = user.mid
            cdUser.timeCached = Date()
            if let userData = try? JSONEncoder().encode(user) {
                cdUser.userData = userData
            }
            try? context.save()
        }
    }
    
    func deleteExpiredUsers() {
        let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
        let oneMonthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        request.predicate = NSPredicate(format: "timeCached < %@", oneMonthAgo as NSDate)
        if let expiredUsers = try? context.fetch(request) {
            for user in expiredUsers {
                context.delete(user)
            }
            try? context.save()
        }
    }
    
    func deleteUser(mid: String) {
        let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
        request.predicate = NSPredicate(format: "mid == %@", mid)
        if let cdUser = try? context.fetch(request).first {
            context.delete(cdUser)
            try? context.save()
        }
    }
    
    func clearAllUsers() {
        let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
        if let allUsers = try? context.fetch(request) {
            for user in allUsers {
                context.delete(user)
            }
            try? context.save()
        }
    }
} 
