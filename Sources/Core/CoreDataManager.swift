import CoreData
import Foundation

class CoreDataManager {
    static let shared = CoreDataManager()
    
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
                print("Core Data failed to load: \(error)")
                do {
                    try self.recoverFromError()
                } catch {
                    print("Failed to recover from Core Data error: \(error)")
                }
            }
        }
    }
    
    private func recoverFromError() throws {
        guard let storeURL = container.persistentStoreDescriptions.first?.url else {
            throw NSError(domain: "CoreDataManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No store URL found"])
        }
        
        try container.persistentStoreCoordinator.destroyPersistentStore(at: storeURL, ofType: NSSQLiteStoreType, options: nil)
        try container.persistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: nil)
    }
    
    var context: NSManagedObjectContext { container.viewContext }
} 