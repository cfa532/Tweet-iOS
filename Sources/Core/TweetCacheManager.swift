import CoreData
import Foundation

class TweetCacheManager {
    static let shared = TweetCacheManager()
    let container: NSPersistentContainer

    private init() {
        container = NSPersistentContainer(name: "TweetModel")
        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Core Data failed: \(error)")
            }
        }
    }

    var context: NSManagedObjectContext { container.viewContext }
}

// MARK: - Tweet Caching
extension TweetCacheManager {
    func fetchTweet(mid: String) -> Tweet? {
        let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
        request.predicate = NSPredicate(format: "mid == %@", mid)
        if let cdTweet = try? context.fetch(request).first {
            cdTweet.lastAccessed = Date()
            try? context.save()
            return Tweet.from(cdTweet: cdTweet)
        }
        return nil
    }

    func saveTweet(_ tweet: Tweet) {
        let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
        request.predicate = NSPredicate(format: "mid == %@", tweet.mid)
        let cdTweet = (try? context.fetch(request).first) ?? CDTweet(context: context)
        cdTweet.mid = tweet.mid
        cdTweet.authorId = tweet.authorId
        cdTweet.content = tweet.content
        cdTweet.timestamp = tweet.timestamp
        cdTweet.lastAccessed = Date()
        // ... set other fields as needed ...
        try? context.save()
    }

    func deleteExpiredTweets() {
        let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
        let oneMonthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        request.predicate = NSPredicate(format: "lastAccessed < %@", oneMonthAgo as NSDate)
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
        Tweet(
            mid: cdTweet.mid ?? "",
            authorId: cdTweet.authorId ?? "",
            content: cdTweet.content,
            timestamp: cdTweet.timestamp ?? Date()
            // ... map other fields as needed ...
        )
    }
} 