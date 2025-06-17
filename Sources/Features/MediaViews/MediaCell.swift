//
//  MediaCell.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
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
    private let maxImageSize: Int = 5 * 1024 * 1024 // 5MB per image
    
    private init() {
        // Get the cache directory
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDirectory.appendingPathComponent("ImageCache")
        
        // Create cache directory if it doesn't exist
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Set cache limits
        cache.countLimit = 100 // Maximum number of images in memory
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB limit
        
        // Register for memory warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleMemoryWarning() {
        cache.removeAllObjects()
        cleanupOldCache()
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
    
    private func getCacheKey(for attachment: MimeiFileType, baseUrl: String) -> String {
        if !attachment.mid.isEmpty {
            return attachment.mid
        }
        if let url = attachment.getUrl(baseUrl) {
            return url.lastPathComponent
        }
        return UUID().uuidString
    }
    
    private func getCacheFileURL(for key: String) -> URL {
        return cacheDirectory.appendingPathComponent(key)
    }
    
    func getImage(for attachment: MimeiFileType, baseUrl: String) -> UIImage? {
        let key = getCacheKey(for: attachment, baseUrl: baseUrl)
        
        // Check memory cache first
        if let cachedImage = cache.object(forKey: key as NSString) {
            return cachedImage
        }
        
        // Check disk cache
        let fileURL = getCacheFileURL(for: key)
        if let data = try? Data(contentsOf: fileURL),
           let image = UIImage(data: data) {
            // Add to memory cache
            cache.setObject(image, forKey: key as NSString)
            return image
        }
        
        return nil
    }
    
    func cacheImageData(_ data: Data, for attachment: MimeiFileType, baseUrl: String) {
        let key = getCacheKey(for: attachment, baseUrl: baseUrl)
        
        // Check if data is too large
        if data.count > maxImageSize {
            print("Image too large to cache: \(data.count) bytes")
            return
        }
        
        // Create UIImage from data
        guard let image = UIImage(data: data) else { return }
        
        // Compress image with adaptive quality
        let compressionQuality = min(1.0, Double(maxImageSize) / Double(data.count))
        guard let compressedData = image.jpegData(compressionQuality: compressionQuality) else { return }
        
        // Save to disk
        let fileURL = getCacheFileURL(for: key)
        try? compressedData.write(to: fileURL)
        
        // Add to memory cache
        cache.setObject(image, forKey: key as NSString)
    }
    
    func loadAndCacheImage(from url: URL, for attachment: MimeiFileType, baseUrl: String) async -> UIImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            // Cache the data
            cacheImageData(data, for: attachment, baseUrl: baseUrl)
            
            // Return the image
            return UIImage(data: data)
        } catch {
            print("Error loading image: \(error)")
            return nil
        }
    }
}

// MARK: - MediaCell
struct MediaCell: View {
    let attachments: [MimeiFileType]
    let baseUrl: String
    var play: Bool = false
    var currentIndex: Int = 0
    let isVisible: Bool
    @State private var cachedImage: UIImage?
    @State private var isLoading = false
    @State private var showBrowser = false
    
    var body: some View {
        Group {
            let attachment = attachments[currentIndex]
            if attachment.type.lowercased() == "video", let url = attachment.getUrl(baseUrl) {
                SimpleVideoPlayer(url: url, autoPlay: play, isVisible: isVisible)
                    .environmentObject(MuteState.shared)
            } else if attachment.type.lowercased() == "audio", let url = attachment.getUrl(baseUrl) {
                SimpleAudioPlayer(url: url, autoPlay: play && isVisible)
            } else {
                if let cachedImage = cachedImage {
                    Image(uiImage: cachedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipped()
                } else if isLoading {
                    Color.gray
                } else {
                    Color.gray
                        .onAppear { loadImage() }
                }
            }
        }
        .onTapGesture { showBrowser = true }
        .fullScreenCover(isPresented: $showBrowser) {
            MediaBrowserView(
                attachments: attachments,
                baseUrl: baseUrl,
                initialIndex: currentIndex
            )
        }
        .onAppear {
            if let cached = ImageCacheManager.shared.getImage(for: attachments[currentIndex], baseUrl: baseUrl) {
                cachedImage = cached
            } else {
                loadImage()
            }
        }
        .onDisappear {
            // Clear cached image when view disappears
            cachedImage = nil
        }
        .onChange(of: currentIndex) { _ in
            // Clear and reload image when index changes
            cachedImage = nil
            loadImage()
        }
    }
    
    private func loadImage() {
        let attachment = attachments[currentIndex]
        guard let url = attachment.getUrl(baseUrl), cachedImage == nil else { return }
        isLoading = true
        Task {
            if let image = await ImageCacheManager.shared.loadAndCacheImage(from: url, for: attachment, baseUrl: baseUrl) {
                await MainActor.run {
                    cachedImage = image
                    isLoading = false
                }
            } else {
                await MainActor.run { isLoading = false }
            }
        }
    }
}


