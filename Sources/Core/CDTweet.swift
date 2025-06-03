//
//  CDTweet.swift
//  Tweet
//
//  Created by 超方 on 2025/6/3.
//

import CoreData

@objc(CDTweet)
public class CDTweet: NSManagedObject {
    @NSManaged public var mid: String
    @NSManaged public var tweetData: Data?
    @NSManaged public var lastAccessed: Date
}

// MARK: - Core Data Properties
extension CDTweet {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDTweet> {
        return NSFetchRequest<CDTweet>(entityName: "CDTweet")
    }
}
