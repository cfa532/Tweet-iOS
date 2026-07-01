import CoreData
import Foundation

final class CoreDataManager: @unchecked Sendable {
    static let shared = CoreDataManager()
    
    let container: NSPersistentContainer
    
    private init() {
        print("[CoreDataManager] Initializing CoreDataManager")
        container = NSPersistentContainer(name: "TweetModel")
        
        // Configure persistent store with proper URL
        let description = NSPersistentStoreDescription()
        
        // Get the documents directory for persistent storage
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let storeURL = documentsDirectory.appendingPathComponent("TweetModel.sqlite")
        
        description.url = storeURL
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]
        
        print("[CoreDataManager] Core Data store URL: \(description.url?.absoluteString ?? "nil")")
        
        // Eagerly create the background contexts BEFORE loadPersistentStores (whose escaping
        // completion captures self; all stored properties must be initialized first). Swift
        // `lazy` is non-atomic, so this also avoids a double-init race on concurrent access.
        let cacheCtx = container.newBackgroundContext()
        cacheCtx.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        cacheCtx.automaticallyMergesChangesFromParent = true
        cacheCtx.name = "TweetCacheManager.cacheContext"
        cacheContext = cacheCtx

        let cacheReadCtx = container.newBackgroundContext()
        cacheReadCtx.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        cacheReadCtx.automaticallyMergesChangesFromParent = true
        cacheReadCtx.name = "TweetCacheManager.cacheReadContext"
        cacheReadContext = cacheReadCtx

        container.loadPersistentStores { _, error in
            if let error = error {
                print("[CoreDataManager] Core Data failed to load: \(error)")
                do {
                    try self.recoverFromError()
                } catch {
                    print("[CoreDataManager] Failed to recover from Core Data error: \(error)")
                }
            } else {
                print("[CoreDataManager] Core Data loaded successfully")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
    }
    
    private func recoverFromError() throws {
        guard let storeURL = container.persistentStoreDescriptions.first?.url else {
            throw NSError(domain: "CoreDataManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No store URL found"])
        }
        
        try container.persistentStoreCoordinator.destroyPersistentStore(at: storeURL, ofType: NSSQLiteStoreType, options: nil)
        try container.persistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: nil)
    }
    
    var context: NSManagedObjectContext { container.viewContext }

    let cacheContext: NSManagedObjectContext
    let cacheReadContext: NSManagedObjectContext
}
