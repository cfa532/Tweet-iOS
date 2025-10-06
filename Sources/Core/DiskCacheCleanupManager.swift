import Foundation

/// Manages automatic cleanup of disk-based video caches with privacy-aware retention policies
class DiskCacheCleanupManager {
    static let shared = DiskCacheCleanupManager()
    
    private init() {
        setupCleanupTimer()
    }
    
    // MARK: - Configuration
    private let publicTweetRetentionInterval: TimeInterval = 7 * 24 * 60 * 60 // 1 week
    private let cleanupCheckInterval: TimeInterval = 24 * 60 * 60 // Check daily
    private var cleanupTimer: Timer?
    
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
        print("DEBUG: [DiskCacheCleanupManager] Starting scheduled cleanup...")
        
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
                
                // Check if this is a private tweet
                if isPrivateTweet(mediaID: mediaID) {
                    privateTweetCount += 1
                    print("DEBUG: [DiskCacheCleanupManager] Skipping private tweet cache: \(mediaID)")
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
                        print("DEBUG: [DiskCacheCleanupManager] Removed old cache for public tweet: \(mediaID) (age: \(Int(timeSinceAccess/86400)) days)")
                    } else {
                        print("DEBUG: [DiskCacheCleanupManager] Keeping cache for public tweet: \(mediaID) (age: \(Int(timeSinceAccess/86400)) days)")
                    }
                }
            }
            
            print("DEBUG: [DiskCacheCleanupManager] Cleanup completed - removed \(cleanedCount) old caches, kept \(privateTweetCount) private tweet caches")
            
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
        // Check if this media ID belongs to a private tweet
        // We'll look for the tweet in the Tweet singleton instances
        
        // Extract the tweet ID from the media ID if possible
        // Media IDs are typically IPFS hashes, so we need to find the associated tweet
        
        // For now, we'll check if there's a cached Tweet instance for this media ID
        // This is a simplified approach - in a real implementation, you might want to
        // maintain a separate mapping of mediaID -> tweetID -> isPrivate
        
        if let tweet = findTweetByMediaID(mediaID) {
            return tweet.isPrivate ?? false
        }
        
        // If we can't find the tweet, default to public (safer for cleanup)
        return false
    }
    
    /// Find a tweet by its media ID
    private func findTweetByMediaID(_ mediaID: String) -> Tweet? {
        // This is a simplified approach - in practice, you might need to maintain
        // a better mapping between media IDs and tweets
        
        // For now, we'll check if the media ID matches any tweet's ID
        // This works if media IDs are the same as tweet IDs
        return Tweet.getInstance(for: mediaID)
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
