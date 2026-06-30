import Foundation

/// Manages automatic cleanup of disk-based video caches with privacy-aware retention policies
final class DiskCacheCleanupManager: @unchecked Sendable {
    static let shared = DiskCacheCleanupManager()
    
    private init() {
        setupCleanupTimer()
    }
    
    // MARK: - Configuration
    private let publicTweetRetentionInterval: TimeInterval = 7 * 24 * 60 * 60 // 1 week
    private let cleanupCheckInterval: TimeInterval = 24 * 60 * 60 // Check daily
    private nonisolated(unsafe) var cleanupTimer: Timer?
    
    // Set of media IDs from bookmarked/favorited tweets (never expire)
    private var permanentMediaIDs: Set<String> = []
    private let permanentMediaIDsQueue = DispatchQueue(label: "com.tweet.permanentMediaIDs")
    
    // MARK: - Cache Directory
    private var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    }
    
    // MARK: - Setup
    
    private func setupCleanupTimer() {
        // Run cleanup daily
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: cleanupCheckInterval, repeats: true) { [weak self] _ in
            self?.performScheduledCleanup()
        }
        
        // Perform initial cleanup after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            self.performScheduledCleanup()
        }
        
        print("DEBUG: [DiskCacheCleanupManager] Setup cleanup timer - will check daily")
    }
    
    // MARK: - Public Methods
    
    /// Mark media IDs from bookmarks/favorites as permanent (never expire)
    func markMediaIDsAsPermanent(_ mediaIDs: [String]) {
        permanentMediaIDsQueue.async {
            self.permanentMediaIDs.formUnion(mediaIDs)
            // Only log if marking 5+ items to reduce log spam
            if mediaIDs.count >= 5 {
                print("💾 [PERMANENT CACHE] Marked \(mediaIDs.count) media IDs as permanent (total: \(self.permanentMediaIDs.count))")
            }
        }
    }
    
    /// Remove media IDs from permanent set (when unbookmarked/unfavorited)
    func unmarkMediaIDsAsPermanent(_ mediaIDs: [String]) {
        permanentMediaIDsQueue.async {
            self.permanentMediaIDs.subtract(mediaIDs)
            print("🗑️ [PERMANENT CACHE] Unmarked \(mediaIDs.count) media IDs (remaining: \(self.permanentMediaIDs.count))")
        }
    }
    
    /// Check if media ID is marked as permanent
    private func isPermanentMediaID(_ mediaID: String) -> Bool {
        var result = false
        permanentMediaIDsQueue.sync {
            result = permanentMediaIDs.contains(mediaID)
        }
        return result
    }
    
    /// Perform scheduled cleanup of old cache files
    func performScheduledCleanup() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.cleanupOldCacheFiles()
        }
    }
    
    /// Manually clear all cache (for settings)
    func clearAllCache() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.clearAllCacheFiles()
        }
    }
    
    /// Manually clear cache for specific media IDs
    func clearCacheForMediaIDs(_ mediaIDs: [String]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.performClearCacheForMediaIDs(mediaIDs)
        }
    }
    
    // MARK: - Private Methods
    
    private func cleanupOldCacheFiles() {
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            
            let now = Date()
            var cleanedCount = 0
            var privateTweetCount = 0
            
            for cacheDir in contents {
                // Only process directories that look like media IDs (IPFS hashes)
                guard cacheDir.hasDirectoryPath,
                      let mediaID = cacheDir.lastPathComponent as String?,
                      isValidMediaID(mediaID) else {
                    continue
                }
                
                // NEVER delete: private tweets OR bookmarks/favorites
                let isPrivate = isPrivateTweet(mediaID: mediaID)
                let isPermanent = isPermanentMediaID(mediaID)
                
                if isPrivate || isPermanent {
                    if isPrivate {
                        privateTweetCount += 1
                    }
                    continue
                }
                
                // Check last access time for public tweets
                if let attributes = try? FileManager.default.attributesOfItem(atPath: cacheDir.path),
                   let modificationDate = attributes[.modificationDate] as? Date {
                    
                    let timeSinceAccess = now.timeIntervalSince(modificationDate)
                    
                    if timeSinceAccess > publicTweetRetentionInterval {
                        // Remove old public tweet cache
                        try FileManager.default.removeItem(at: cacheDir)
                        cleanedCount += 1
                    }
                    // Removed repetitive "Keeping cache" log
                }
            }
            
            
        } catch {
            print("DEBUG: [DiskCacheCleanupManager] Error during cleanup: \(error.localizedDescription)")
        }
    }
    
    private func clearAllCacheFiles() {
        print("DEBUG: [DiskCacheCleanupManager] Clearing ALL cache files...")
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            
            var clearedCount = 0
            
            for cacheDir in contents {
                guard cacheDir.hasDirectoryPath,
                      let mediaID = cacheDir.lastPathComponent as String?,
                      isValidMediaID(mediaID) else {
                    continue
                }
                
                // Remove all cache directories (both public and private)
                try FileManager.default.removeItem(at: cacheDir)
                clearedCount += 1
                print("DEBUG: [DiskCacheCleanupManager] Cleared cache for: \(mediaID)")
            }
            
            print("DEBUG: [DiskCacheCleanupManager] Cleared \(clearedCount) cache directories")
            
        } catch {
            print("DEBUG: [DiskCacheCleanupManager] Error clearing all cache: \(error.localizedDescription)")
        }
    }
    
    private func performClearCacheForMediaIDs(_ mediaIDs: [String]) {
        print("DEBUG: [DiskCacheCleanupManager] Clearing cache for specific media IDs: \(mediaIDs)")
        
        for mediaID in mediaIDs {
            let cacheDir = cacheDirectory.appendingPathComponent(mediaID)
            
            if FileManager.default.fileExists(atPath: cacheDir.path) {
                do {
                    try FileManager.default.removeItem(at: cacheDir)
                    print("DEBUG: [DiskCacheCleanupManager] Cleared cache for media ID: \(mediaID)")
                } catch {
                    print("DEBUG: [DiskCacheCleanupManager] Error clearing cache for \(mediaID): \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    /// Check if a string looks like a valid media ID (IPFS hash)
    private func isValidMediaID(_ mediaID: String) -> Bool {
        // IPFS hashes typically start with "Qm" and are 46 characters long
        return mediaID.hasPrefix("Qm") && mediaID.count == 46
    }
    
    /// Check if a media ID belongs to a private tweet
    private func isPrivateTweet(mediaID: String) -> Bool {
        // Private/bookmarked/favorited media is retained by markMediaIDsAsPermanent(_:)
        // when tweets are saved. Disk cleanup must not read live Tweet UI models from
        // its background queue.
        return false
    }
    
    /// Get cache statistics
    func getCacheStatistics() -> (totalCaches: Int, publicCaches: Int, privateCaches: Int, totalSize: Int64) {
        var totalCaches = 0
        var publicCaches = 0
        var privateCaches = 0
        var totalSize: Int64 = 0
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            
            for cacheDir in contents {
                guard cacheDir.hasDirectoryPath,
                      let mediaID = cacheDir.lastPathComponent as String?,
                      isValidMediaID(mediaID) else {
                    continue
                }
                
                totalCaches += 1
                
                if isPrivateTweet(mediaID: mediaID) {
                    privateCaches += 1
                } else {
                    publicCaches += 1
                }
                
                // Calculate directory size
                if let size = try? FileManager.default.sizeOfDirectory(at: cacheDir) {
                    totalSize += size
                }
            }
            
        } catch {
            print("DEBUG: [DiskCacheCleanupManager] Error getting cache statistics: \(error.localizedDescription)")
        }
        
        return (totalCaches, publicCaches, privateCaches, totalSize)
    }
    
    deinit {
        cleanupTimer?.invalidate()
    }
}

// MARK: - FileManager Extension for Directory Size
extension FileManager {
    func sizeOfDirectory(at url: URL) throws -> Int64 {
        let contents = try contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        
        var totalSize: Int64 = 0
        
        for fileURL in contents {
            if let attributes = try? attributesOfItem(atPath: fileURL.path),
               let fileSize = attributes[.size] as? Int64 {
                totalSize += fileSize
            }
        }
        
        return totalSize
    }
}
