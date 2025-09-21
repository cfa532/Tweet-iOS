//
//  ImageCacheManager.swift
//  Tweet
//
//  Created by 超方 on 2025/6/27.
//
import SwiftUI
import AVFoundation
import CryptoKit

// MARK: - Image Cache Manager
class ImageCacheManager {
    static let shared = ImageCacheManager()
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let maxCacheAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days in seconds
    private let maxDiskCacheSize: Int64 = 5000 * 1024 * 1024 // 500MB
    private let maxCompressedImageSize: Int = 300 * 1024 // 300KB for compressed images
    
    private init() {
        // Get the cache directory
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDirectory.appendingPathComponent("ImageCache")
        
        // Create cache directory if it doesn't exist
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Set cache limits
        cache.countLimit = 100 // Maximum number of images in memory
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB limit
        
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
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
        if !attachment.mid.isEmpty {
            return attachment.mid
        }
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
            // Add to memory cache
            cache.setObject(image, forKey: cacheKey as NSString)
            return image
        }
        
        return nil
    }
    
    func cacheImageData(_ data: Data, for attachment: MimeiFileType, baseUrl: URL) {
        let key = getCacheKey(for: attachment, baseUrl: baseUrl)
        
        // Create UIImage from data
        guard let image = UIImage(data: data) else { 
            print("DEBUG: [ImageCacheManager] Failed to create UIImage from data for \(key)")
            return 
        }
        
        // Create compressed version (under 300KB)
        let compressedImage = compressImageToSize(image, maxSize: maxCompressedImageSize)
        let compressedFileURL = getCompressedCacheFileURL(for: key)
        
        // Write compressed data to disk
        do {
            try compressedImage.write(to: compressedFileURL)
        } catch {
            print("DEBUG: [ImageCacheManager] Failed to write compressed image to disk for \(key): \(error)")
        }
        
        // Add to memory cache if we can create UIImage from compressed data
        if let compressedUIImage = UIImage(data: compressedImage) {
            cache.setObject(compressedUIImage, forKey: "\(key)_compressed" as NSString)
            print("DEBUG: [ImageCacheManager] Successfully cached compressed image for \(key)")
        } else {
            print("DEBUG: [ImageCacheManager] Failed to create UIImage from compressed data for \(key)")
        }
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
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            // Cache the compressed version
            cacheImageData(data, for: attachment, baseUrl: baseUrl)
            
            // Return the compressed image for thumbnail use
            return getCompressedImage(for: attachment, baseUrl: baseUrl)
        } catch {
            print("Error loading image: \(error)")
            return nil
        }
    }
    
    func loadOriginalImage(from url: URL, for attachment: MimeiFileType, baseUrl: URL) async -> UIImage? {
        // Load original image directly from network (no caching)
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return UIImage(data: data)
        } catch {
            print("Error loading original image: \(error)")
            return nil
        }
    }
}
