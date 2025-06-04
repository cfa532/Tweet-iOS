import CoreData

@objc(CDUser)
public class CDUser: NSManagedObject {
    @NSManaged public var mid: String
    @NSManaged public var userData: Data?
    @NSManaged public var timeCached: Date
}

// MARK: - Core Data Properties
extension CDUser {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDUser> {
        return NSFetchRequest<CDUser>(entityName: "CDUser")
    }
} 