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
    func fetchCachedTweets(for userId: String, page: Int, pageSize: Int) -> [Tweet] {
        let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
        request.predicate = NSPredicate(format: "uid == %@", userId)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchOffset = page * pageSize
        request.fetchLimit = pageSize
        
        if let cdTweets = try? context.fetch(request) {
            return cdTweets.compactMap { cdTweet in
                if let tweetData = cdTweet.tweetData,
                   let tweet = try? JSONDecoder().decode(Tweet.self, from: tweetData) {
                    return tweet
                }
                return nil
            }
        }
        return []
    }

    func fetchTweet(mid: String) -> Tweet? {
        let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
        request.predicate = NSPredicate(format: "tid == %@", mid)
        if let cdTweet = try? context.fetch(request).first {
            cdTweet.timeCached = Date()
            try? context.save()
            return Tweet.from(cdTweet: cdTweet)
        }
        return nil
    }

    func saveTweet(_ tweet: Tweet, _ userId: String? = nil) {
        let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
        request.predicate = NSPredicate(format: "tid == %@", tweet.mid)
        let cdTweet = (try? context.fetch(request).first) ?? CDTweet(context: context)
        cdTweet.tid = tweet.mid
        cdTweet.uid = userId ?? tweet.mid
        cdTweet.timestamp = tweet.timestamp
        cdTweet.timeCached = Date()
        
        // Encode tweet to binary data
        if let tweetData = try? JSONEncoder().encode(tweet) {
            cdTweet.tweetData = tweetData
        }
        
        try? context.save()
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
}

// MARK: - Tweet <-> Core Data Conversion
extension Tweet {
    static func from(cdTweet: CDTweet) -> Tweet {
        if let tweetData = cdTweet.tweetData,
           let tweet = try? JSONDecoder().decode(Tweet.self, from: tweetData) {
            return tweet
        }
        
        // Fallback to basic properties if decoding fails
        return Tweet(
            mid: cdTweet.tid,
            authorId: Constants.GUEST_ID,
            content: nil,
            timestamp: Date()
        )
    }
} 
