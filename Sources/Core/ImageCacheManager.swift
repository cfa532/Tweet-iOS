//
//  ImageCacheManager.swift
//  Tweet
//
//  Created by 超方 on 2025/6/27.
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
    private let maxDiskCacheSize: Int64 = 5000 * 1024 * 1024 // 500MB
    private let maxCompressedImageSize: Int = 300 * 1024 // 300KB for compressed images
    private let maxDownsampleDimension: CGFloat = 1024
    
    // Request deduplication: Track ongoing requests to prevent duplicate downloads
    private var ongoingRequests: [String: Task<UIImage?, Never>] = [:]
    private let requestsQueue = DispatchQueue(label: "com.zz.imagecache.requests", attributes: .concurrent)
    
    // Avatar loading throttling
    private let maxConcurrentAvatarLoads = 4 // Balanced for stable network performance
    private var activeAvatarLoads: [String: Task<UIImage?, Never>] = [:]
    private var pendingAvatarRequests: [(cacheKey: String, url: URL, attachment: MimeiFileType, baseUrl: URL, continuation: CheckedContinuation<UIImage?, Never>)] = []
    private let avatarQueue = DispatchQueue(label: "com.zz.imagecache.avatars", attributes: .concurrent)
    
    // General image download throttling
    private let maxConcurrentImageDownloads = 3
    private let imageDownloadSemaphore: DispatchSemaphore
    
    private func memoryDuplicateBlockState() -> (blocked: Bool, percentage: Double, threshold: Double) {
        let manager = MemoryCapManager.shared
        return (
            blocked: manager.isAboveDuplicateBlockThreshold,
            percentage: manager.memoryUsagePercentage,
            threshold: manager.duplicateBlockThresholdPercentage
        )
    }
    
    private func waitForMemoryWindow(cacheKey: String, retryLabel: String) async -> Bool {
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
    
    private func withImageDownloadSlot<T>(_ work: () async throws -> T) async rethrows -> T {
        imageDownloadSemaphore.wait()
        defer { imageDownloadSemaphore.signal() }
        return try await work()
    }
    
    private init() {
        imageDownloadSemaphore = DispatchSemaphore(value: maxConcurrentImageDownloads)
        
        // Get the cache directory
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDirectory.appendingPathComponent("ImageCache")
        
        // Create cache directory if it doesn't exist
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Set cache limits
        cache.countLimit = 100 // Maximum number of images in memory
        cache.totalCostLimit = 35 * 1024 * 1024 // 35MB limit
        
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
        let maxPixelSize = max(1, Int(maxDimension * scale))
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
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        let cost = max(1, pixelWidth * pixelHeight * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
    
    func cleanupOldCache() {
        do {
            let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            let now = Date()
            var totalSize: Int64 = 0
            var filesToDelete: [URL] = []
            
            // First pass: Calculate total size and identify old files
            for fileURL in contents {
                if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                   let modificationDate = attributes[.modificationDate] as? Date,
                   let fileSize = attributes[.size] as? Int64 {
                    totalSize += fileSize
                    if now.timeIntervalSince(modificationDate) > maxCacheAge {
                        filesToDelete.append(fileURL)
                    }
                }
            }
            
            // Second pass: If still over limit, delete oldest files
            if totalSize > maxDiskCacheSize {
                let sortedFiles = contents.sorted { url1, url2 in
                    let date1 = (try? fileManager.attributesOfItem(atPath: url1.path)[.modificationDate] as? Date) ?? Date.distantPast
                    let date2 = (try? fileManager.attributesOfItem(atPath: url2.path)[.modificationDate] as? Date) ?? Date.distantPast
                    return date1 < date2
                }
                
                for fileURL in sortedFiles {
                    if let fileSize = try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 {
                        filesToDelete.append(fileURL)
                        totalSize -= fileSize
                        if totalSize <= maxDiskCacheSize {
                            break
                        }
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
        // Clear memory cache
        cache.removeAllObjects()
        
        // Clear all disk cache files
        do {
            let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [])
            for fileURL in contents {
                try? fileManager.removeItem(at: fileURL)
            }
        } catch {
            print("Error clearing all cache: \(error)")
        }
    }
    
    /// Clear cache for a specific media ID (image)
    func clearCache(for mediaId: String) {
        // Clear from memory cache
        cache.removeObject(forKey: mediaId as NSString)
        
        // Clear from disk cache
        let cachedFile = cacheDirectory.appendingPathComponent(mediaId)
        try? fileManager.removeItem(at: cachedFile)
        
        // Also try compressed version
        let compressedFile = cacheDirectory.appendingPathComponent("\(mediaId)_compressed")
        try? fileManager.removeItem(at: compressedFile)
    }
    
    func clearAvatarCache(for userId: String) {
        // NSCache doesn't have allKeys, so we'll just clear the disk cache
        // The memory cache will be cleared when the app receives memory warnings
        
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
        // NSCache doesn't have allKeys, so we'll just clear the disk cache
        // The memory cache will be cleared when the app receives memory warnings
        
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
        
        // Clear memory cache completely (NSCache doesn't support partial clearing)
        cache.removeAllObjects()
        
        // Remove percentage of disk cache files (oldest first)
        do {
            let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
            
            // Sort by modification date (oldest first)
            let sortedFiles = contents.sorted { url1, url2 in
                let date1 = (try? fileManager.attributesOfItem(atPath: url1.path)[.modificationDate] as? Date) ?? Date.distantPast
                let date2 = (try? fileManager.attributesOfItem(atPath: url2.path)[.modificationDate] as? Date) ?? Date.distantPast
                return date1 < date2
            }
            
            let countToRemove = max(1, (sortedFiles.count * percentageToRemove) / 100)
            let filesToRemove = Array(sortedFiles.prefix(countToRemove))
            
            for fileURL in filesToRemove {
                try? fileManager.removeItem(at: fileURL)
            }
            
            print("DEBUG: [ImageCacheManager] Released \(filesToRemove.count) image files from cache")
        } catch {
            print("Error releasing partial image cache: \(error)")
        }
    }
    
    private func getCacheKey(for attachment: MimeiFileType, baseUrl: URL) -> String {
        // ALWAYS use mid as the cache key (stable identifier)
        // If mid is somehow empty, this is a programming error that should be fixed at the source
        if !attachment.mid.isEmpty {
            return attachment.mid
        }
        
        // Fallback: This should never happen in production
        // If it does, log a warning so we can fix the root cause
        print("WARNING: [ImageCacheManager] MimeiFileType has empty mid! Using URL fallback. This should be fixed.")
        if let url = attachment.getUrl(baseUrl) {
            return url.lastPathComponent
        }
        return UUID().uuidString
    }
    
    private func getCompressedCacheFileURL(for key: String) -> URL {
        return cacheDirectory.appendingPathComponent("\(key)_compressed.jpg")
    }
    
    func getCompressedImage(for attachment: MimeiFileType, baseUrl: URL) -> UIImage? {
        let key = getCacheKey(for: attachment, baseUrl: baseUrl)
        let cacheKey = "\(key)_compressed"
        
        // Check memory cache first
        if let cachedImage = cache.object(forKey: cacheKey as NSString) {
            return cachedImage
        }
        
        // Check disk cache
        let fileURL = getCompressedCacheFileURL(for: key)
        if let data = try? Data(contentsOf: fileURL),
           let image = UIImage(data: data) {
            cacheImageInMemory(image, forKey: cacheKey)
            return image
        }
        
        return nil
    }
    
    /// Get cached compressed image by mid alone (for when baseUrl is not yet available)
    func getCachedCompressedImage(forMid mid: String) -> UIImage? {
        guard !mid.isEmpty else { return nil }
        
        let cacheKey = "\(mid)_compressed"
        
        // Check memory cache first
        if let cachedImage = cache.object(forKey: cacheKey as NSString) {
            return cachedImage
        }
        
        // Check disk cache
        let fileURL = getCompressedCacheFileURL(for: mid)
        if let data = try? Data(contentsOf: fileURL),
           let image = UIImage(data: data) {
            cacheImageInMemory(image, forKey: cacheKey)
            return image
        }
        
        return nil
    }
    
    @discardableResult
    func cacheImageData(_ data: Data, for attachment: MimeiFileType, baseUrl: URL) -> UIImage? {
        let key = getCacheKey(for: attachment, baseUrl: baseUrl)
        
        let targetImage: UIImage
        if let downsampled = downsampleImageData(data, maxDimension: maxDownsampleDimension) {
            targetImage = downsampled
        } else if let fallback = UIImage(data: data) {
            targetImage = fallback
        } else {
            print("DEBUG: [ImageCacheManager] Failed to create UIImage from data for \(key)")
            return nil
        }
        
        // Create compressed version (under 300KB)
        let compressedImage = compressImageToSize(targetImage, maxSize: maxCompressedImageSize)
        let compressedFileURL = getCompressedCacheFileURL(for: key)
        
        // Write compressed data to disk
        do {
            try compressedImage.write(to: compressedFileURL)
        } catch {
            print("DEBUG: [ImageCacheManager] Failed to write compressed image to disk for \(key): \(error)")
        }
        
        // Add to memory cache
        cacheImageInMemory(targetImage, forKey: "\(key)_compressed")
        print("DEBUG: [ImageCacheManager] Successfully cached compressed image for \(key)")
        return targetImage
    }
    
    private func compressImageToSize(_ image: UIImage, maxSize: Int) -> Data {
        var compression: CGFloat = 1.0
        
        // Try to get initial JPEG data
        guard var data = image.jpegData(compressionQuality: compression) else {
            print("DEBUG: [ImageCacheManager] Failed to create JPEG data from image")
            // Fallback to PNG if JPEG fails
            return image.pngData() ?? Data()
        }
        
        // Reduce quality until size is under maxSize
        while data.count > maxSize && compression > 0.1 {
            compression -= 0.1
            guard let newData = image.jpegData(compressionQuality: compression) else {
                print("DEBUG: [ImageCacheManager] Failed to create JPEG data with compression \(compression)")
                break
            }
            data = newData
        }
        
        // If still too large, reduce image size
        if data.count > maxSize {
            let scale = sqrt(Double(maxSize) / Double(data.count))
            let newSize = CGSize(
                width: image.size.width * scale,
                height: image.size.height * scale
            )
            
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            image.draw(in: CGRect(origin: .zero, size: newSize))
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
    
    func loadAndCacheImage(from url: URL, for attachment: MimeiFileType, baseUrl: URL) async -> UIImage? {
        let cacheKey = getCacheKey(for: attachment, baseUrl: baseUrl)
        
        // Check if there's already an ongoing request for this image
        let existingTask: Task<UIImage?, Never>? = requestsQueue.sync {
            return ongoingRequests[cacheKey]
        }
        
        if let existingTask = existingTask {
            let state = memoryDuplicateBlockState()
            if state.blocked {
                print("🚫 [ImageCacheManager] Memory at \(String(format: "%.1f", state.percentage * 100))% (threshold \(String(format: "%.0f", state.threshold * 100))%) - rejecting duplicate image request for \(cacheKey)")
                return nil
            }
            print("DEBUG: [ImageCacheManager] Reusing existing request for \(cacheKey)")
            return await existingTask.value
        }
        
        // Create new request task
        let task = Task<UIImage?, Never> {
            do {
                guard await self.waitForMemoryWindow(cacheKey: cacheKey, retryLabel: "[thumbnail]") else {
                    return nil
                }
                return try await self.withImageDownloadSlot {
                    try Task.checkCancellation()
                    
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 10.0 // 10 second timeout
                    request.cachePolicy = .returnCacheDataElseLoad
                    
                    let (tempURL, response) = try await URLSession.shared.download(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        print("Error: Invalid response for image at \(url)")
                        return nil
                    }
                    
                    let data = try Data(contentsOf: tempURL, options: .mappedIfSafe)
                    self.cacheImageData(data, for: attachment, baseUrl: baseUrl)
                    try? FileManager.default.removeItem(at: tempURL)
                    
                    return self.getCompressedImage(for: attachment, baseUrl: baseUrl)
                }
            } catch {
                print("Error loading image from \(url): \(error.localizedDescription)")
                return nil
            }
        }
        
        // Store the task to prevent duplicate requests
        requestsQueue.async(flags: .barrier) {
            self.ongoingRequests[cacheKey] = task
        }
        
        // Wait for result
        let result = await task.value
        
        // Remove completed task
        requestsQueue.async(flags: .barrier) {
            self.ongoingRequests.removeValue(forKey: cacheKey)
        }
        
        return result
    }
    
    func loadOriginalImage(from url: URL, for attachment: MimeiFileType, baseUrl: URL) async -> UIImage? {
        let cacheKey = getCacheKey(for: attachment, baseUrl: baseUrl) + "_original"
        
        // Check if there's already an ongoing request for this original image
        let existingTask: Task<UIImage?, Never>? = requestsQueue.sync {
            return ongoingRequests[cacheKey]
        }
        
        if let existingTask = existingTask {
            let state = memoryDuplicateBlockState()
            if state.blocked {
                print("🚫 [ImageCacheManager] Memory at \(String(format: "%.1f", state.percentage * 100))% (threshold \(String(format: "%.0f", state.threshold * 100))%) - rejecting duplicate original image request for \(cacheKey)")
                return nil
            }
            print("DEBUG: [ImageCacheManager] Reusing existing request for original image \(cacheKey)")
            return await existingTask.value
        }
        
        // Create new request task
        let task = Task<UIImage?, Never> {
            do {
                guard await self.waitForMemoryWindow(cacheKey: cacheKey, retryLabel: "[original]") else {
                    return nil
                }
                return try await self.withImageDownloadSlot {
                    try Task.checkCancellation()
                    
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 15.0 // 15 second timeout for original images (larger files)
                    request.cachePolicy = .returnCacheDataElseLoad
                    
                    let (tempURL, response) = try await URLSession.shared.download(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        print("Error: Invalid response for original image at \(url)")
                        return nil
                    }
                    
                    let image = UIImage(contentsOfFile: tempURL.path)
                    if image == nil {
                        print("Error loading original image from disk (nil) at \(tempURL)")
                    }
                    try? FileManager.default.removeItem(at: tempURL)
                    return image
                }
            } catch {
                print("Error loading original image from \(url): \(error.localizedDescription)")
                return nil
            }
        }
        
        // Store the task to prevent duplicate requests
        requestsQueue.async(flags: .barrier) {
            self.ongoingRequests[cacheKey] = task
        }
        
        // Wait for result
        let result = await task.value
        
        // Remove completed task
        requestsQueue.async(flags: .barrier) {
            self.ongoingRequests.removeValue(forKey: cacheKey)
        }
        
        return result
    }
    
    // MARK: - Avatar Loading with Throttling
    
    /// Load avatar with concurrency throttling to prevent network congestion
    func loadAndCacheAvatar(from url: URL, for attachment: MimeiFileType, baseUrl: URL) async -> UIImage? {
        let cacheKey = getCacheKey(for: attachment, baseUrl: baseUrl)
        
        // Check memory cache first (fast path)
        if let cached = getCompressedImage(for: attachment, baseUrl: baseUrl) {
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
            do {
                guard await self.waitForMemoryWindow(cacheKey: cacheKey, retryLabel: "[avatar]") else {
                    return nil
                }
                return try await self.withImageDownloadSlot {
                    try Task.checkCancellation()
                    
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 10.0
                    request.cachePolicy = .returnCacheDataElseLoad
                    
                    let (tempURL, response) = try await URLSession.shared.download(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        print("DEBUG: [ImageCacheManager] Invalid response for avatar at \(url)")
                        return nil
                    }
                    
                    let data = try Data(contentsOf: tempURL, options: .mappedIfSafe)
                    self.cacheImageData(data, for: attachment, baseUrl: baseUrl)
                    try? FileManager.default.removeItem(at: tempURL)
                    
                    return self.getCompressedImage(for: attachment, baseUrl: baseUrl)
                }
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
