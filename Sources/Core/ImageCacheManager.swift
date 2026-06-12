//
//  ImageCacheManager.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/6/27.
//
import SwiftUI
import UIKit
import AVFoundation
import CryptoKit
import ImageIO

// MARK: - Image Cache Manager
class ImageCacheManager: @unchecked Sendable {
    static let shared = ImageCacheManager()
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let maxCacheAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days in seconds
    // Disk cache: no size limit — only 7-day age expiry via cleanupOldCache()
    private let maxCompressedImageSize: Int = 300 * 1024 // 300KB for compressed images
    private let maxDownsampleDimension: CGFloat = 1024
    
    // Permanent image IDs (from bookmarks/favorites - never expire)
    private var permanentImageIDs: Set<String> = []
    private let permanentImageIDsQueue = DispatchQueue(label: "com.tweet.permanentImageIDs")
    
    // Avatar cache key tracking (for memory protection)
    private var avatarCacheKeys: Set<String> = []
    private var memoryCachedKeys: Set<String> = []
    private var memoryCacheAccessTimes: [String: Date] = [:]
    private var recentImageCache: [String: UIImage] = [:]
    private var recentImageCacheCosts: [String: Int] = [:]
    private var recentImageCacheCost: Int = 0
    private let recentImageProtectionInterval: TimeInterval = 10 * 60
    private let maxRecentImageCacheCount = 80
    private let maxRecentImageCacheCost = 160 * 1024 * 1024
    private let cacheKeysQueue = DispatchQueue(label: "com.tweet.cacheKeys", attributes: .concurrent)
    
    // Request deduplication: Track ongoing requests to prevent duplicate downloads
    private var ongoingRequests: [String: Task<UIImage?, Never>] = [:]
    private let requestsQueue = DispatchQueue(label: "com.zz.imagecache.requests", attributes: .concurrent)
    
    // Avatar loading throttling
    private let maxConcurrentAvatarLoads = 4 // Balanced for stable network performance
    private var activeAvatarLoads: [String: Task<UIImage?, Never>] = [:]
    private var pendingAvatarRequests: [(cacheKey: String, url: URL, attachment: MimeiFileType, baseUrl: URL, continuation: CheckedContinuation<UIImage?, Never>)] = []
    private let avatarQueue = DispatchQueue(label: "com.zz.imagecache.avatars", attributes: .concurrent)
    
    private func memoryDuplicateBlockState() -> (blocked: Bool, percentage: Double, threshold: Double) {
        let manager = MemoryCapManager.shared
        return (
            blocked: manager.isAboveDuplicateBlockThreshold,
            percentage: manager.memoryUsagePercentage,
            threshold: manager.duplicateBlockThresholdPercentage
        )
    }
    
    private func waitForMemoryWindow(cacheKey: String, retryLabel: String, priority: ImageLoadingPriority = .normal) async -> Bool {
        // Critical priority bypasses memory pressure — visible content must load
        if priority == .critical { return true }

        // Fast-path if we're comfortably below the threshold
        if !memoryDuplicateBlockState().blocked {
            return true
        }

        let maxAttempts = 3
        for attempt in 0..<maxAttempts {
            let state = memoryDuplicateBlockState()
            if !state.blocked {
                if attempt > 0 {
                    print("✅ [ImageCacheManager] Memory cooled down after \(attempt) backoff attempts for \(retryLabel) \(cacheKey)")
                }
                return true
            }

            let delaySeconds = pow(2.0, Double(attempt)) * 0.4
            print("⏳ [ImageCacheManager] Memory at \(String(format: "%.1f", state.percentage * 100))% (threshold \(String(format: "%.0f", state.threshold * 100))%) - delaying new image download \(retryLabel) \(cacheKey) by \(String(format: "%.1f", delaySeconds))s")
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))

            if Task.isCancelled { return false }
        }

        let finalState = memoryDuplicateBlockState()
        if finalState.blocked {
            print("🚫 [ImageCacheManager] Aborting new image download \(retryLabel) \(cacheKey) - memory still high at \(String(format: "%.1f", finalState.percentage * 100))%")
            return false
        }

        return true
    }
    
    private init() {
        
        // Get the cache directory
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDirectory.appendingPathComponent("ImageCache")
        
        // Create cache directory if it doesn't exist
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Set cache limits
        cache.countLimit = 400 // Keep recently viewed feed images warm during scroll-back
        cache.totalCostLimit = 240 * 1024 * 1024 // Raw decoded image cost limit
        
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func downsampleImageData(_ data: Data, maxDimension: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        
        let scale: CGFloat = {
            if Thread.isMainThread {
                return UIScreen.main.scale
            } else {
                return DispatchQueue.main.sync { UIScreen.main.scale }
            }
        }()
        let maxPixelSize = max(1, Int(maxDimension))
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return nil
        }
        
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
    
    private func cacheImageInMemory(_ image: UIImage, forKey key: String) {
        let cost = imageMemoryCost(image)
        cache.setObject(image, forKey: key as NSString, cost: cost)
        
        // Track this key for selective memory cache release
        cacheKeysQueue.async(flags: .barrier) {
            self.memoryCachedKeys.insert(key)
            self.memoryCacheAccessTimes[key] = Date()
            self.recentImageCache[key] = image
            let previousCost = self.recentImageCacheCosts[key] ?? 0
            self.recentImageCacheCosts[key] = cost
            self.recentImageCacheCost += cost - previousCost
            
            // Mark as avatar if key contains "avatar_"
            if key.contains("avatar_") {
                self.avatarCacheKeys.insert(key)
            }

            self.trimRecentImageCacheLocked()
        }
    }

    private func markMemoryCacheAccess(forKey key: String) {
        cacheKeysQueue.async(flags: .barrier) {
            self.memoryCacheAccessTimes[key] = Date()
        }
    }

    private func imageMemoryCost(_ image: UIImage) -> Int {
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        return max(1, pixelWidth * pixelHeight * 4)
    }

    private func recentImageFromMemory(forKey key: String) -> UIImage? {
        cacheKeysQueue.sync {
            recentImageCache[key]
        }
    }

    private func removeMemoryTrackingLocked(forKey key: String) {
        memoryCachedKeys.remove(key)
        memoryCacheAccessTimes.removeValue(forKey: key)
        avatarCacheKeys.remove(key)
        recentImageCache.removeValue(forKey: key)
        recentImageCacheCost -= recentImageCacheCosts.removeValue(forKey: key) ?? 0
        recentImageCacheCost = max(0, recentImageCacheCost)
    }

    private func trimRecentImageCacheLocked() {
        while (recentImageCache.count > maxRecentImageCacheCount || recentImageCacheCost > maxRecentImageCacheCost),
              recentImageCache.count > 1 {
            guard let oldestKey = recentImageCache.keys.min(by: {
                (memoryCacheAccessTimes[$0] ?? .distantPast) < (memoryCacheAccessTimes[$1] ?? .distantPast)
            }) else { return }

            recentImageCache.removeValue(forKey: oldestKey)
            recentImageCacheCost -= recentImageCacheCosts.removeValue(forKey: oldestKey) ?? 0
            recentImageCacheCost = max(0, recentImageCacheCost)
        }
    }
    
    // MARK: - Permanent Image Management
    
    /// Mark image IDs from bookmarks/favorites as permanent (never expire)
    func markImageIDsAsPermanent(_ imageIDs: [String]) {
        permanentImageIDsQueue.async {
            self.permanentImageIDs.formUnion(imageIDs)
            // Only log if marking 5+ items to reduce log spam
            if imageIDs.count >= 5 {
                print("💾 [ImageCacheManager] Marked \(imageIDs.count) image IDs as permanent (total: \(self.permanentImageIDs.count))")
            }
        }
    }
    
    /// Remove image IDs from permanent set (when unbookmarked/unfavorited)
    func unmarkImageIDsAsPermanent(_ imageIDs: [String]) {
        permanentImageIDsQueue.async {
            self.permanentImageIDs.subtract(imageIDs)
            print("🗑️ [ImageCacheManager] Unmarked \(imageIDs.count) image IDs (remaining: \(self.permanentImageIDs.count))")
        }
    }
    
    /// Check if image ID is marked as permanent
    private func isPermanentImageID(_ imageID: String) -> Bool {
        var result = false
        permanentImageIDsQueue.sync {
            result = permanentImageIDs.contains(imageID)
        }
        return result
    }
    
    /// Check if an image ID belongs to a private tweet
    private func isPrivateTweet(imageID: String) -> Bool {
        // Check if this image ID belongs to a private tweet
        if let tweet = findTweetByMediaID(imageID) {
            return tweet.isPrivate ?? false
        }
        return false
    }
    
    /// Find a tweet by its media ID
    private func findTweetByMediaID(_ mediaID: String) -> Tweet? {
        return Tweet.getInstance(for: mediaID)
    }
    
    func cleanupOldCache() {
        do {
            let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
            let now = Date()
            var filesToDelete: [URL] = []

            // Delete files older than 7 days (skip protected content)
            for fileURL in contents {
                if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                   let modificationDate = attributes[.modificationDate] as? Date {

                    // Extract image ID from filename (format: imageID or imageID-thumb)
                    let filename = fileURL.deletingPathExtension().lastPathComponent
                    let imageID = filename.components(separatedBy: "-").first ?? filename

                    // NEVER delete: private tweets OR bookmarks/favorites OR avatars
                    let isPrivate = isPrivateTweet(imageID: imageID)
                    let isPermanent = isPermanentImageID(imageID)
                    let isAvatar = filename.contains("avatar_")

                    if isPrivate || isPermanent || isAvatar {
                        continue
                    }

                    if now.timeIntervalSince(modificationDate) > maxCacheAge {
                        filesToDelete.append(fileURL)
                    }
                }
            }

            // Delete identified files
            for fileURL in filesToDelete {
                try? fileManager.removeItem(at: fileURL)
            }
        } catch {
            print("Error cleaning up cache: \(error)")
        }
    }
    
    func clearAllCache() {
        print("DEBUG: [ImageCacheManager] Clearing all cache - memory and disk")

        // Clear memory cache
        cache.removeAllObjects()
        cacheKeysQueue.async(flags: .barrier) {
            self.memoryCachedKeys.removeAll()
            self.memoryCacheAccessTimes.removeAll()
            self.recentImageCache.removeAll()
            self.recentImageCacheCosts.removeAll()
            self.recentImageCacheCost = 0
            self.avatarCacheKeys.removeAll()
        }
        print("DEBUG: [ImageCacheManager] Cleared memory cache")

        // Clear all disk cache files
        do {
            let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [])
            print("DEBUG: [ImageCacheManager] Found \(contents.count) files in disk cache")
            for fileURL in contents {
                try? fileManager.removeItem(at: fileURL)
            }
            print("DEBUG: [ImageCacheManager] Cleared all disk cache files")
        } catch {
            print("Error clearing all cache: \(error)")
        }

        print("DEBUG: [ImageCacheManager] Cache clearing complete")
    }
    
    /// Clear cache for a specific media ID (image)
    func clearCache(for mediaId: String) {
        // Clear from memory cache
        cache.removeObject(forKey: mediaId as NSString)
        cache.removeObject(forKey: "\(mediaId)_compressed" as NSString)
        cacheKeysQueue.async(flags: .barrier) {
            self.removeMemoryTrackingLocked(forKey: mediaId)
            self.removeMemoryTrackingLocked(forKey: "\(mediaId)_compressed")
        }
        
        // Clear from disk cache
        let cachedFile = cacheDirectory.appendingPathComponent(mediaId)
        try? fileManager.removeItem(at: cachedFile)
        
        // Also try compressed version
        let compressedFile = cacheDirectory.appendingPathComponent("\(mediaId)_compressed")
        try? fileManager.removeItem(at: compressedFile)
    }
    
    func clearAvatarCache(for userId: String) {
        // Clear memory cache for this user's avatar
        cacheKeysQueue.async(flags: .barrier) {
            let keysToRemove = self.avatarCacheKeys.filter { $0.contains(userId) }
            for key in keysToRemove {
                self.cache.removeObject(forKey: key as NSString)
                self.removeMemoryTrackingLocked(forKey: key)
            }
        }
        
        // Clear disk cache for avatar files
        do {
            let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [])
            for fileURL in contents {
                let fileName = fileURL.lastPathComponent
                if fileName.contains("avatar_") && fileName.contains(userId) {
                    try? fileManager.removeItem(at: fileURL)
                }
            }
        } catch {
            print("Error clearing avatar cache: \(error)")
        }
    }
    
    func clearAllAvatarCache() {
        // Clear memory cache for all avatars
        cacheKeysQueue.async(flags: .barrier) {
            for key in Array(self.avatarCacheKeys) {
                self.cache.removeObject(forKey: key as NSString)
                self.removeMemoryTrackingLocked(forKey: key)
            }
            self.avatarCacheKeys.removeAll()
        }
        
        // Clear disk cache for all avatar files
        do {
            let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [])
            for fileURL in contents {
                let fileName = fileURL.lastPathComponent
                if fileName.contains("avatar_") {
                    try? fileManager.removeItem(at: fileURL)
                }
            }
        } catch {
            print("Error clearing all avatar cache: \(error)")
        }
    }
    
    /// Release a percentage of image cache to free memory
    func releasePartialCache(percentage: Int) {
        let percentageToRemove = max(1, min(percentage, 90)) // Ensure 1-90% range
        print("DEBUG: [ImageCacheManager] Releasing \(percentageToRemove)% of image cache")
        
        // Selectively clear memory cache (protect avatars and recently viewed feed images)
        cacheKeysQueue.sync(flags: .barrier) {
            let now = Date()
            let nonAvatarKeys = memoryCachedKeys.subtracting(avatarCacheKeys)
            let removableKeys = nonAvatarKeys.filter { key in
                guard let lastAccess = memoryCacheAccessTimes[key] else { return true }
                return now.timeIntervalSince(lastAccess) > recentImageProtectionInterval
            }
            let countToRemove = max(0, (nonAvatarKeys.count * percentageToRemove) / 100)
            let actualCountToRemove = min(countToRemove, removableKeys.count)
            
            if actualCountToRemove > 0 {
                // Remove percentage of non-avatar images from memory
                let keysToRemove = Array(removableKeys.prefix(actualCountToRemove))
                for key in keysToRemove {
                    cache.removeObject(forKey: key as NSString)
                    removeMemoryTrackingLocked(forKey: key)
                }
                print("DEBUG: [ImageCacheManager] Released \(keysToRemove.count) images from memory (avatars protected: \(avatarCacheKeys.count), recent protected: \(nonAvatarKeys.count - removableKeys.count))")
            } else {
                print("DEBUG: [ImageCacheManager] No old non-avatar images to release from memory")
            }
        }
        
        // Disk cache files don't consume RAM — skip disk deletion during memory pressure.
        // Disk cleanup is handled separately by cleanupOldCache() (7-day expiry / 500MB limit).
    }

    /// Clear memory cache only (keep disk cache intact)
    /// Use this for background cleanup - images will reload from disk when needed
    func clearMemoryCache() {
        cache.removeAllObjects()
        cacheKeysQueue.async(flags: .barrier) {
            self.memoryCachedKeys.removeAll()
            self.memoryCacheAccessTimes.removeAll()
            self.recentImageCache.removeAll()
            self.recentImageCacheCosts.removeAll()
            self.recentImageCacheCost = 0
            // Keep avatarCacheKeys - they'll be re-added when loaded from disk
        }
        cancelOngoingRequestsForBackground()
        print("🧹 [ImageCacheManager] Cleared memory cache (disk cache preserved)")
    }

    /// Cancel in-flight image loads and pending avatar requests when app enters background.
    /// Prevents stuck tasks and continuation buildup from holding memory.
    private func cancelOngoingRequestsForBackground() {
        requestsQueue.async(flags: .barrier) {
            for (_, task) in self.ongoingRequests {
                task.cancel()
            }
            self.ongoingRequests.removeAll()
        }
        avatarQueue.async(flags: .barrier) {
            for req in self.pendingAvatarRequests {
                req.continuation.resume(returning: nil)
            }
            self.pendingAvatarRequests.removeAll()
            for (_, task) in self.activeAvatarLoads {
                task.cancel()
            }
            self.activeAvatarLoads.removeAll()
        }
    }

    private func getCacheKey(for attachment: MimeiFileType) -> String? {
        // ALWAYS use mid as the cache key (stable identifier)
        // If mid is somehow empty, this is a programming error that should be fixed at the source
        if !attachment.mid.isEmpty {
            return attachment.mid
        }
        return nil
    }
    
    private func getCompressedCacheFileURL(for key: String) -> URL {
        return cacheDirectory.appendingPathComponent("\(key)_compressed.jpg")
    }

    private func getOriginalCacheFileURL(for key: String) -> URL {
        return cacheDirectory.appendingPathComponent("\(key)_original.jpg")
    }
    
    /// Get compressed image from memory cache only (safe for synchronous access in view body)
    /// This method does NOT perform disk I/O and is safe to call from the main thread
    func getCompressedImageFromMemory(for attachment: MimeiFileType) -> UIImage? {
        guard let key = getCacheKey(for: attachment) else { return nil }
        let cacheKey = "\(key)_compressed"
        
        if let recentImage = recentImageFromMemory(forKey: cacheKey) {
            markMemoryCacheAccess(forKey: cacheKey)
            cache.setObject(recentImage, forKey: cacheKey as NSString, cost: imageMemoryCost(recentImage))
            return recentImage
        }

        // Only check memory cache - no disk I/O to avoid blocking UI
        guard let image = cache.object(forKey: cacheKey as NSString) else { return nil }
        markMemoryCacheAccess(forKey: cacheKey)
        return image
    }
    
    /// Get compressed image from memory or disk cache
    /// ⚠️ WARNING: This method performs synchronous disk I/O and should NOT be called from main thread
    /// Use getCompressedImageFromMemory() for main thread access
    /// This method should only be used in background contexts (Task.detached, DispatchQueue.global, etc.)
    func getCompressedImage(for attachment: MimeiFileType) -> UIImage? {
        guard let key = getCacheKey(for: attachment) else { return nil }
        let cacheKey = "\(key)_compressed"
        
        if let recentImage = recentImageFromMemory(forKey: cacheKey) {
            markMemoryCacheAccess(forKey: cacheKey)
            cache.setObject(recentImage, forKey: cacheKey as NSString, cost: imageMemoryCost(recentImage))
            return recentImage
        }

        // Check memory cache first (thread-safe, NSCache handles locking)
        if let cachedImage = cache.object(forKey: cacheKey as NSString) {
            markMemoryCacheAccess(forKey: cacheKey)
            return cachedImage
        }
        
        // PERFORMANCE: Disk I/O happens here - should only be called from background thread
        // This is the source of the 227ms hang when called from main thread
        let fileURL = getCompressedCacheFileURL(for: key)
        if let data = try? Data(contentsOf: fileURL),
           let image = UIImage(data: data) {
            // Cache in memory for next time (NSCache is thread-safe)
            cacheImageInMemory(image, forKey: cacheKey)
            return image
        }
        
        return nil
    }
    
    /// Get cached compressed image by mid alone (memory only, for when baseUrl is not yet available)
    /// This method does NOT perform disk I/O and is safe to call from the main thread
    func getCachedCompressedImageFromMemory(forMid mid: String) -> UIImage? {
        guard !mid.isEmpty else { return nil }
        let cacheKey = "\(mid)_compressed"
        
        if let recentImage = recentImageFromMemory(forKey: cacheKey) {
            markMemoryCacheAccess(forKey: cacheKey)
            cache.setObject(recentImage, forKey: cacheKey as NSString, cost: imageMemoryCost(recentImage))
            return recentImage
        }

        // Only check memory cache - no disk I/O
        guard let image = cache.object(forKey: cacheKey as NSString) else { return nil }
        markMemoryCacheAccess(forKey: cacheKey)
        return image
    }
    
    /// Get cached compressed image by mid alone (for when baseUrl is not yet available)
    /// ⚠️ WARNING: This method performs synchronous disk I/O - only use in async contexts
    func getCachedCompressedImage(forMid mid: String) -> UIImage? {
        guard !mid.isEmpty else { return nil }
        
        let cacheKey = "\(mid)_compressed"
        
        if let recentImage = recentImageFromMemory(forKey: cacheKey) {
            markMemoryCacheAccess(forKey: cacheKey)
            cache.setObject(recentImage, forKey: cacheKey as NSString, cost: imageMemoryCost(recentImage))
            return recentImage
        }

        // Check memory cache first
        if let cachedImage = cache.object(forKey: cacheKey as NSString) {
            markMemoryCacheAccess(forKey: cacheKey)
            return cachedImage
        }
        
        // Check disk cache (synchronous I/O - only use in async contexts)
        let fileURL = getCompressedCacheFileURL(for: mid)
        if let data = try? Data(contentsOf: fileURL),
           let image = UIImage(data: data) {
            cacheImageInMemory(image, forKey: cacheKey)
            return image
        }
        
        return nil
    }
    
    @discardableResult
    func cacheImageData(_ data: Data, for attachment: MimeiFileType) -> UIImage? {
        guard let key = getCacheKey(for: attachment) else { 
            print("DEBUG: [ImageCacheManager] Cannot cache image - no cache key available")
            return nil 
        }
        
        let targetImage: UIImage
        if let downsampled = downsampleImageData(data, maxDimension: maxDownsampleDimension) {
            targetImage = downsampled
        } else if let fallback = UIImage(data: data) {
            targetImage = fallback
        } else {
            print("DEBUG: [ImageCacheManager] Failed to create UIImage from data for \(key)")
            return nil
        }
        
        // CRITICAL FIX: Cache to memory IMMEDIATELY so subsequent cache checks can find it
        // This prevents race condition where cells miss the cache and start loading again
        cacheImageInMemory(targetImage, forKey: "\(key)_compressed")
        
        // Then compress and write to disk in background
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            
            // Create compressed version (under 300KB) on background thread
            let compressedImage = self.compressImageToSize(targetImage, maxSize: self.maxCompressedImageSize)
            let compressedFileURL = self.getCompressedCacheFileURL(for: key)

            // Write compressed data to disk
            do {
                try compressedImage.write(to: compressedFileURL)
            } catch {
                print("DEBUG: [ImageCacheManager] Failed to write compressed image to disk for \(key): \(error)")
            }
            
            // Notify Avatar views that this image is now cached
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .imageCached,
                    object: nil,
                    userInfo: ["avatarId": key]
                )
            }
        }
        
        // Return immediately without waiting for compression
        return targetImage
    }
    
    private func compressImageToSize(_ image: UIImage, maxSize: Int) -> Data {
        // First, strip alpha channel if image is opaque to avoid ImageIO warnings
        let opaqueImage: UIImage
        if let alphaInfo = image.cgImage?.alphaInfo,
           alphaInfo == .none || alphaInfo == .noneSkipLast || alphaInfo == .noneSkipFirst {
            // Image is already opaque, use as-is
            opaqueImage = image
        } else {
            // MODERN API: Use UIGraphicsImageRenderer instead of old UIGraphicsBeginImageContext
            // This is more efficient and thread-safe
            let renderer = UIGraphicsImageRenderer(size: image.size, format: UIGraphicsImageRendererFormat.default())
            opaqueImage = renderer.image { context in
                // Set opaque background
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: image.size))
                // Draw image on top
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
        }
        
        var compression: CGFloat = 1.0
        
        // Try to get initial JPEG data (JPEG doesn't support alpha, so this will be opaque)
        guard var data = opaqueImage.jpegData(compressionQuality: compression) else {
            print("DEBUG: [ImageCacheManager] Failed to create JPEG data from image")
            // Fallback to PNG if JPEG fails, but PNG should also be without alpha now
            return opaqueImage.pngData() ?? Data()
        }
        
        // Reduce quality until size is under maxSize
        while data.count > maxSize && compression > 0.1 {
            compression -= 0.1
            guard let newData = opaqueImage.jpegData(compressionQuality: compression) else {
                print("DEBUG: [ImageCacheManager] Failed to create JPEG data with compression \(compression)")
                break
            }
            data = newData
        }
        
        // If still too large, reduce image size
        if data.count > maxSize {
            let scale = sqrt(Double(maxSize) / Double(data.count))
            let newSize = CGSize(
                width: opaqueImage.size.width * scale,
                height: opaqueImage.size.height * scale
            )
            
            // Use opaque: true to ensure no alpha channel
            UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
            opaqueImage.draw(in: CGRect(origin: .zero, size: newSize))
            let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            
            if let resizedImage = resizedImage,
               let resizedData = resizedImage.jpegData(compressionQuality: 0.8) {
                data = resizedData
            } else {
                print("DEBUG: [ImageCacheManager] Failed to create JPEG data from resized image")
            }
        }
        
        return data
    }
    
    func loadAndCacheImage(from url: URL, for attachment: MimeiFileType, priority: ImageLoadingPriority = .normal) async -> UIImage? {
        guard let cacheKey = getCacheKey(for: attachment) else {
            print("DEBUG: [ImageCacheManager] Cannot load image - no cache key available")
            return nil
        }

        let registration = requestsQueue.sync(flags: .barrier) { () -> (task: Task<UIImage?, Never>, created: Bool) in
            if let existingTask = ongoingRequests[cacheKey] {
                return (existingTask, false)
            }

            let task = Task<UIImage?, Never> {
            var tempURL: URL?
            defer {
                // ✅ CRITICAL MEMORY FIX: Always clean up temp file, even on error
                if let tempURL = tempURL {
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }

            do {
                guard await self.waitForMemoryWindow(cacheKey: cacheKey, retryLabel: "[thumbnail]", priority: priority) else {
                    return nil
                }
                try Task.checkCancellation()
                
                var request = URLRequest(url: url)
                request.timeoutInterval = Constants.IMAGE_LOAD_TIMEOUT
                request.cachePolicy = .returnCacheDataElseLoad
                
                let downloadResult = try await URLSession.shared.download(for: request)
                tempURL = downloadResult.0  // Store for cleanup in defer
                
                guard let httpResponse = downloadResult.1 as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    print("Error: Invalid response for image at \(url)")
                    return nil
                }
                
                let data = try Data(contentsOf: downloadResult.0, options: .mappedIfSafe)
                self.cacheImageData(data, for: attachment)
                
                return self.getCompressedImage(for: attachment)
            } catch {
                print("Error loading image from \(url): \(error.localizedDescription)")
                return nil
            }
            }

            ongoingRequests[cacheKey] = task
            return (task, true)
        }

        if !registration.created && priority != .critical {
            let state = memoryDuplicateBlockState()
            if state.blocked {
                print("🚫 [ImageCacheManager] Memory at \(String(format: "%.1f", state.percentage * 100))% (threshold \(String(format: "%.0f", state.threshold * 100))%) - rejecting duplicate image request for \(cacheKey)")
                return nil
            }
        }

        // Wait for result
        let result = await registration.task.value
        
        // Remove completed task
        requestsQueue.async(flags: .barrier) {
            self.ongoingRequests.removeValue(forKey: cacheKey)
        }
        
        return result
    }
    
    /// Load original image and optionally replace compressed cache with it
    /// - Parameters:
    ///   - url: URL to load the original image from
    ///   - attachment: The attachment to load the image for
    ///   - baseUrl: Base URL for the attachment
    ///   - replaceCompressedCache: If true, replace the compressed cache entry with the original image
    /// - Returns: The loaded original image, or nil if loading failed
    func loadOriginalImage(from url: URL, for attachment: MimeiFileType, baseUrl: URL, replaceCompressedCache: Bool = false, priority: ImageLoadingPriority = .normal) async -> UIImage? {
        guard let key = getCacheKey(for: attachment) else {
            print("DEBUG: [ImageCacheManager] Cannot load original image - no cache key available")
            return nil
        }
        let cacheKey = key + "_original"

        if let cachedOriginal = getOriginalImage(forKey: key) {
            if replaceCompressedCache {
                replaceCompressedCacheWithOriginal(image: cachedOriginal, for: key)
            }
            return cachedOriginal
        }

        let registration = requestsQueue.sync(flags: .barrier) { () -> (task: Task<UIImage?, Never>, created: Bool) in
            if let existingTask = ongoingRequests[cacheKey] {
                return (existingTask, false)
            }

            let task = Task<UIImage?, Never> {
            var tempURL: URL?
            defer {
                // ✅ CRITICAL MEMORY FIX: Always clean up temp file, even on error
                if let tempURL = tempURL {
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }

            do {
                guard await self.waitForMemoryWindow(cacheKey: cacheKey, retryLabel: "[original]", priority: priority) else {
                    return nil
                }
                try Task.checkCancellation()
                
                var request = URLRequest(url: url)
                request.timeoutInterval = Constants.IMAGE_LOAD_TIMEOUT
                request.cachePolicy = .returnCacheDataElseLoad
                
                let downloadResult = try await URLSession.shared.download(for: request)
                tempURL = downloadResult.0  // Store for cleanup in defer
                
                guard let httpResponse = downloadResult.1 as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    print("Error: Invalid response for original image at \(url)")
                    return nil
                }
                
                let image = UIImage(contentsOfFile: downloadResult.0.path)
                if image == nil {
                    print("Error loading original image from disk (nil) at \(downloadResult.0)")
                }
                
                // Replace compressed cache if requested
                if replaceCompressedCache, let originalImage = image {
                    replaceCompressedCacheWithOriginal(image: originalImage, for: key)
                }
                
                return image
            } catch {
                print("Error loading original image from \(url): \(error.localizedDescription)")
                return nil
            }
            }

            ongoingRequests[cacheKey] = task
            return (task, true)
        }

        if !registration.created && priority != .critical {
            let state = memoryDuplicateBlockState()
            if state.blocked {
                print("🚫 [ImageCacheManager] Memory at \(String(format: "%.1f", state.percentage * 100))% (threshold \(String(format: "%.0f", state.threshold * 100))%) - rejecting duplicate original image request for \(cacheKey)")
                return nil
            }
        }

        // Wait for result
        let result = await registration.task.value
        
        // Remove completed task
        requestsQueue.async(flags: .barrier) {
            self.ongoingRequests.removeValue(forKey: cacheKey)
        }
        
        return result
    }
    
    private func getOriginalImage(forKey key: String) -> UIImage? {
        let cacheKey = "\(key)_original"
        if let recentImage = recentImageFromMemory(forKey: cacheKey) {
            markMemoryCacheAccess(forKey: cacheKey)
            cache.setObject(recentImage, forKey: cacheKey as NSString, cost: imageMemoryCost(recentImage))
            return recentImage
        }

        if let cachedImage = cache.object(forKey: cacheKey as NSString) {
            markMemoryCacheAccess(forKey: cacheKey)
            return cachedImage
        }

        let fileURL = getOriginalCacheFileURL(for: key)
        if let image = UIImage(contentsOfFile: fileURL.path) {
            cacheImageInMemory(image, forKey: cacheKey)
            return image
        }

        return nil
    }

    /// Replace compressed cache entry with original image
    /// - Parameters:
    ///   - image: The original image to cache
    ///   - key: The cache key (without _compressed or _original suffix)
    private func replaceCompressedCacheWithOriginal(image: UIImage, for key: String) {
        let compressedKey = "\(key)_compressed"
        let originalKey = "\(key)_original"
        // Replace in memory cache
        cacheImageInMemory(image, forKey: compressedKey)
        cacheImageInMemory(image, forKey: originalKey)

        Task { @MainActor in
            NotificationCenter.default.post(
                name: .imageCached,
                object: nil,
                userInfo: ["avatarId": key]
            )
        }
        
        // Replace on disk (save original as both high-res preview and explicit original cache)
        let compressedFileURL = getCompressedCacheFileURL(for: key)
        let originalFileURL = getOriginalCacheFileURL(for: key)
        Task.detached(priority: .utility) {
            if let jpegData = image.jpegData(compressionQuality: 1.0) {
                try? jpegData.write(to: compressedFileURL)
                try? jpegData.write(to: originalFileURL)
                print("✅ [ImageCacheManager] Stored original image for \(key) as high-res preview and original cache")
            }
        }
    }
    
    // MARK: - Avatar Loading with Throttling
    
    /// Load avatar with concurrency throttling to prevent network congestion
    func loadAndCacheAvatar(from url: URL, for attachment: MimeiFileType, baseUrl: URL) async -> UIImage? {
        guard let cacheKey = getCacheKey(for: attachment) else {
            print("DEBUG: [ImageCacheManager] Cannot load avatar - no cache key available")
            return nil
        }
        
        // Check memory cache first (fast path)
        if let cached = getCompressedImage(for: attachment) {
            return cached
        }
        
        // Check if already loading this avatar
        let existingTask: Task<UIImage?, Never>? = avatarQueue.sync {
            return activeAvatarLoads[cacheKey]
        }
        
        if let existingTask = existingTask {
            let state = memoryDuplicateBlockState()
            if state.blocked {
                print("🚫 [ImageCacheManager] Memory at \(String(format: "%.1f", state.percentage * 100))% (threshold \(String(format: "%.0f", state.threshold * 100))%) - rejecting duplicate avatar request for \(cacheKey)")
                return nil
            }
            print("DEBUG: [ImageCacheManager] Avatar already loading, waiting: \(cacheKey)")
            return await existingTask.value
        }
        
        // Check if we can start loading immediately
        let canStartImmediately = avatarQueue.sync {
            return activeAvatarLoads.count < maxConcurrentAvatarLoads
        }
        
        if canStartImmediately {
            return await startAvatarLoad(cacheKey: cacheKey, url: url, attachment: attachment, baseUrl: baseUrl)
        } else {
            // Queue the request
            return await withCheckedContinuation { continuation in
                avatarQueue.async(flags: .barrier) {
                    self.pendingAvatarRequests.append((cacheKey: cacheKey, url: url, attachment: attachment, baseUrl: baseUrl, continuation: continuation))
                    print("DEBUG: [ImageCacheManager] Avatar queued (\(self.pendingAvatarRequests.count) pending): \(cacheKey)")
                }
            }
        }
    }
    
    private func startAvatarLoad(cacheKey: String, url: URL, attachment: MimeiFileType, baseUrl: URL) async -> UIImage? {
        let task = Task<UIImage?, Never> {
            var tempURL: URL?
            defer {
                // ✅ CRITICAL MEMORY FIX: Always clean up temp file, even on error
                if let tempURL = tempURL {
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }
            
            do {
                guard await self.waitForMemoryWindow(cacheKey: cacheKey, retryLabel: "[avatar]") else {
                    return nil
                }
                try Task.checkCancellation()
                
                var request = URLRequest(url: url)
                request.timeoutInterval = Constants.IMAGE_LOAD_TIMEOUT
                request.cachePolicy = .returnCacheDataElseLoad
                
                let downloadResult = try await URLSession.shared.download(for: request)
                tempURL = downloadResult.0  // Store for cleanup in defer
                
                guard let httpResponse = downloadResult.1 as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    print("DEBUG: [ImageCacheManager] Invalid response for avatar at \(url)")
                    return nil
                }
                
                let data = try Data(contentsOf: downloadResult.0, options: .mappedIfSafe)
                self.cacheImageData(data, for: attachment)
                
                return self.getCompressedImage(for: attachment)
            } catch {
                print("DEBUG: [ImageCacheManager] Error loading avatar from \(url): \(error.localizedDescription)")
                return nil
            }
        }
        
        // Register active load
        avatarQueue.async(flags: .barrier) {
            self.activeAvatarLoads[cacheKey] = task
        }
        
        // Wait for result
        let result = await task.value
        
        // Unregister and process next
        avatarQueue.async(flags: .barrier) {
            self.activeAvatarLoads.removeValue(forKey: cacheKey)
            self.processNextPendingAvatar()
        }
        
        return result
    }
    
    private func processNextPendingAvatar() {
        guard activeAvatarLoads.count < maxConcurrentAvatarLoads,
              !pendingAvatarRequests.isEmpty else {
            return
        }
        
        let nextRequest = pendingAvatarRequests.removeFirst()
        print("DEBUG: [ImageCacheManager] Processing queued avatar (\(pendingAvatarRequests.count) remaining): \(nextRequest.cacheKey)")
        
        // Start loading the next avatar
        Task {
            let result = await startAvatarLoad(
                cacheKey: nextRequest.cacheKey,
                url: nextRequest.url,
                attachment: nextRequest.attachment,
                baseUrl: nextRequest.baseUrl
            )
            nextRequest.continuation.resume(returning: result)
        }
    }
}
