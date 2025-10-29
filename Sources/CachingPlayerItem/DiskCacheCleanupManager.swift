import Foundation

/// Manages automatic cleanup of disk-based video caches with smart size-based and priority eviction
class DiskCacheCleanupManager {
    static let shared = DiskCacheCleanupManager()
    
    private init() {
        loadCachedMetadata()
        setupCleanupTimer()
    }
    
    // MARK: - Configuration
    private let maxCacheSizeGB: Double = 2.0  // 2GB max cache (configurable in Settings)
    private let targetCacheSizeGB: Double = 1.5  // Target after cleanup (75%)
    private let minFreeSpaceGB: Double = 0.5  // Minimum free space to maintain
    private let cleanupCheckInterval: TimeInterval = 24 * 60 * 60 // Check daily
    private var cleanupTimer: Timer?
    
    // MARK: - Cache Metadata
    struct VideoMetadata: Codable {
        let mediaId: String
        let fileSize: Int64
        let firstCached: Date
        var lastAccessed: Date
        var accessCount: Int
        let videoType: VideoType
        let isPrivate: Bool
        let tweetAuthorId: String?
        let duration: TimeInterval?
        
        enum VideoType: String, Codable {
            case hls
            case progressive
            case audio
        }
        
        // Calculate priority score for eviction (lower score = higher priority to delete)
        func priorityScore(now: Date = Date()) -> Double {
            // 1. Access frequency (normalized, max score: 10)
            let frequencyScore = min(Double(accessCount), 10.0) * 2.0
            
            // 2. Recency (days since last access, inverted)
            let daysSinceAccess = max(0, now.timeIntervalSince(lastAccessed) / 86400.0)
            let recencyScore = max(0, 10.0 - daysSinceAccess) * 1.5
            
            // 3. Type weight (HLS is expensive to re-download)
            let typeWeight: Double = {
                switch videoType {
                case .hls: return 1.5
                case .progressive: return 1.0
                case .audio: return 0.5
                }
            }()
            
            // 4. Privacy weight (keep private tweets longer)
            let privacyWeight: Double = isPrivate ? 3.0 : 1.0
            
            // 5. Size penalty (prefer keeping smaller files)
            let sizeMB = Double(fileSize) / (1024.0 * 1024.0)
            let sizePenalty = min(sizeMB / 100.0, 5.0) * 0.5
            
            // 6. Duration bonus (complete videos more valuable)
            let durationBonus = (duration ?? 0) > 30 ? 1.0 : 0.0
            
            let score = (frequencyScore + recencyScore + typeWeight + durationBonus) * privacyWeight - sizePenalty
            
            return max(0, score)
        }
    }
    
    // MARK: - In-Memory Index
    private var metadataIndex: [String: VideoMetadata] = [:]  // mediaId -> metadata
    private let indexQueue = DispatchQueue(label: "DiskCacheCleanupManager", qos: .utility)
    private var needsCleanupCheck = false
    
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            self.performScheduledCleanup()
        }
        
        print("DEBUG: [DiskCacheCleanupManager] Setup cleanup timer with smart size-based eviction")
    }
    
    // MARK: - Video Access Tracking
    
    /// Record video access (call when video starts playing)
    func recordAccess(mediaId: String) {
        indexQueue.async { [weak self] in
            guard let self = self else { return }
            
            if var metadata = self.metadataIndex[mediaId] {
                metadata.accessCount += 1
                metadata.lastAccessed = Date()
                self.metadataIndex[mediaId] = metadata
                self.saveMetadata(metadata)
            }
        }
    }
    
    /// Register new video in cache (call when video is cached)
    func registerVideo(
        mediaId: String,
        fileSize: Int64,
        videoType: VideoMetadata.VideoType,
        isPrivate: Bool,
        tweetAuthorId: String? = nil,
        duration: TimeInterval? = nil
    ) {
        indexQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Don't re-register if already exists
            guard self.metadataIndex[mediaId] == nil else {
                self.recordAccess(mediaId: mediaId)
                return
            }
            
            let metadata = VideoMetadata(
                mediaId: mediaId,
                fileSize: fileSize,
                firstCached: Date(),
                lastAccessed: Date(),
                accessCount: 1,
                videoType: videoType,
                isPrivate: isPrivate,
                tweetAuthorId: tweetAuthorId,
                duration: duration
            )
            
            self.metadataIndex[mediaId] = metadata
            self.saveMetadata(metadata)
            
            // Mark that we need a cleanup check
            self.needsCleanupCheck = true
            
            // Check size after a short delay (batch multiple registrations)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.checkSizeAndCleanupIfNeeded()
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Perform scheduled cleanup of old cache files
    func performScheduledCleanup() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.checkSizeAndCleanupIfNeeded()
        }
    }
    
    /// Check cache size and cleanup if needed
    func checkSizeAndCleanupIfNeeded() {
        guard needsCleanupCheck else { return }
        needsCleanupCheck = false
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            
            let currentSize = self.calculateTotalCacheSize()
            let maxBytes = Int64(self.maxCacheSizeGB * 1024 * 1024 * 1024)
            let targetBytes = Int64(self.targetCacheSizeGB * 1024 * 1024 * 1024)
            
            print("📊 [Cache] Current: \(self.formatBytes(currentSize)) / Max: \(self.formatBytes(maxBytes))")
            
            guard currentSize > maxBytes else {
                print("✅ [Cache] Size OK, no cleanup needed")
                return
            }
            
            print("🧹 [Cache] Cleanup needed - Current: \(self.formatBytes(currentSize)), Target: \(self.formatBytes(targetBytes))")
            
            let bytesToRemove = currentSize - targetBytes
            self.performSmartCleanup(bytesToRemove: bytesToRemove)
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
    
    /// Smart cleanup based on priority scores
    private func performSmartCleanup(bytesToRemove: Int64) {
        let now = Date()
        
        // 1. Get all cached videos with their scores
        var scoredVideos: [(metadata: VideoMetadata, score: Double)] = []
        
        indexQueue.sync {
            scoredVideos = metadataIndex.values.map { metadata in
                (metadata, metadata.priorityScore(now: now))
            }
        }
        
        // 2. Sort by priority (lowest first = candidates for deletion)
        scoredVideos.sort { $0.score < $1.score }
        
        // 3. Remove videos until we reach target size
        var removedSize: Int64 = 0
        var removedCount = 0
        
        for (metadata, score) in scoredVideos {
            // NEVER remove private tweets
            guard !metadata.isPrivate else {
                print("🔒 [Cache] Skipping private video: \(metadata.mediaId)")
                continue
            }
            
            // NEVER remove recently accessed videos (< 24 hours)
            let hoursSinceAccess = now.timeIntervalSince(metadata.lastAccessed) / 3600.0
            guard hoursSinceAccess > 24 else {
                print("⏰ [Cache] Skipping recent video: \(metadata.mediaId) (accessed \(Int(hoursSinceAccess))h ago)")
                continue
            }
            
            // Remove this video
            let cacheDir = cacheDirectory.appendingPathComponent(metadata.mediaId)
            
            do {
                try FileManager.default.removeItem(at: cacheDir)
                
                indexQueue.async { [weak self] in
                    self?.metadataIndex.removeValue(forKey: metadata.mediaId)
                    self?.deleteMetadata(metadata.mediaId)
                }
                
                removedSize += metadata.fileSize
                removedCount += 1
                
                print("🗑️ [Cache] Removed: \(metadata.mediaId) | Score: \(String(format: "%.2f", score)) | Size: \(self.formatBytes(metadata.fileSize)) | Accessed: \(Int(hoursSinceAccess))h ago")
                
            } catch {
                print("❌ [Cache] Failed to remove \(metadata.mediaId): \(error)")
            }
            
            if removedSize >= bytesToRemove {
                break
            }
        }
        
        print("✅ [Cache] Cleanup complete - Removed \(removedCount) videos (\(self.formatBytes(removedSize)))")
    }
    
    /// Legacy cleanup method (for compatibility)
    private func cleanupOldCacheFiles() {
        print("DEBUG: [DiskCacheCleanupManager] Starting legacy cleanup...")
        
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
                    let legacyRetentionDays: TimeInterval = 7 * 24 * 60 * 60  // 7 days for legacy cleanup
                    
                    if timeSinceAccess > legacyRetentionDays {
                        // Remove old public tweet cache
                        try FileManager.default.removeItem(at: cacheDir)
                        cleanedCount += 1
                        print("DEBUG: [DiskCacheCleanupManager] Removed old cache for public tweet: \(mediaID) (age: \(Int(timeSinceAccess/86400)) days)")
                    }
                    // Removed repetitive "Keeping cache" log
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
    
    /// Get cache statistics (enhanced version)
    func getCacheStatistics() -> (totalCaches: Int, publicCaches: Int, privateCaches: Int, totalSize: Int64, oldestAccess: Date?, newestAccess: Date?) {
        return indexQueue.sync {
            let totalCaches = metadataIndex.count
            let publicCaches = metadataIndex.values.filter { !$0.isPrivate }.count
            let privateCaches = metadataIndex.values.filter { $0.isPrivate }.count
            let totalSize = metadataIndex.values.reduce(Int64(0)) { $0 + $1.fileSize }
            let oldestAccess = metadataIndex.values.map { $0.lastAccessed }.min()
            let newestAccess = metadataIndex.values.map { $0.lastAccessed }.max()
            
            return (totalCaches, publicCaches, privateCaches, totalSize, oldestAccess, newestAccess)
        }
    }
    
    // MARK: - Helper Methods
    
    private func calculateTotalCacheSize() -> Int64 {
        var totalSize: Int64 = 0
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            
            for item in contents where item.hasDirectoryPath {
                if let size = try? FileManager.default.sizeOfDirectory(at: item) {
                    totalSize += size
                }
            }
        } catch {
            print("❌ [Cache] Error calculating size: \(error)")
        }
        
        return totalSize
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }
    
    // MARK: - Persistence
    
    private func saveMetadata(_ metadata: VideoMetadata) {
        let key = "video_cache_metadata_\(metadata.mediaId)"
        if let data = try? JSONEncoder().encode(metadata) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    private func deleteMetadata(_ mediaId: String) {
        let key = "video_cache_metadata_\(mediaId)"
        UserDefaults.standard.removeObject(forKey: key)
    }
    
    /// Load all metadata on app launch
    private func loadCachedMetadata() {
        indexQueue.async { [weak self] in
            guard let self = self else { return }
            
            let defaults = UserDefaults.standard
            let allKeys = defaults.dictionaryRepresentation().keys
            let metadataKeys = allKeys.filter { $0.hasPrefix("video_cache_metadata_") }
            
            for key in metadataKeys {
                if let data = defaults.data(forKey: key),
                   let metadata = try? JSONDecoder().decode(VideoMetadata.self, from: data) {
                    self.metadataIndex[metadata.mediaId] = metadata
                }
            }
            
            print("📦 [Cache] Loaded \(self.metadataIndex.count) video metadata entries")
            
            // Schedule initial cleanup check
            self.needsCleanupCheck = true
        }
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
