//
//  VideoAssetCache.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  Shared video asset cache for optimal resource sharing across different video contexts
//

import Foundation
import AVFoundation
import AVKit

/// Cached video asset that can be shared across different playback contexts
struct CachedVideoAsset {
    let videoMid: String
    let originalURL: URL
    let resolvedURL: URL
    let isHLS: Bool
    let duration: TimeInterval
    let aspectRatio: Float
    let metadata: [String: Any]
    
    /// Create a new AVPlayerItem from this cached asset
    func createPlayerItem() -> AVPlayerItem {
        let options: [String: Any]
        if isHLS {
            // HLS video options
            options = [
                "AVURLAssetOutOfBandMIMETypeKey": "application/x-mpegURL",
                "AVURLAssetHTTPHeaderFieldsKey": ["Accept": "*/*"]
            ]
        } else {
            // Regular video options
            options = [
                "AVURLAssetHTTPHeaderFieldsKey": ["Accept": "*/*"]
            ]
        }
        
        let asset = AVURLAsset(url: resolvedURL, options: options)
        let playerItem = AVPlayerItem(asset: asset)
        
        // Configure player item for better performance
        playerItem.preferredForwardBufferDuration = 10.0
        playerItem.preferredPeakBitRate = 0 // Let system decide
        
        return playerItem
    }
}

/// Shared cache for video assets that can be used across all video playback contexts
class VideoAssetCache {
    static let shared = VideoAssetCache()
    
    // Cache of video assets using mid as key
    private var assetCache: [String: CachedVideoAsset] = [:]
    private let cacheLock = NSLock()
    
    // Network request deduplication
    private var pendingRequests: [String: Task<CachedVideoAsset, Error>] = [:]
    
    // Cache configuration
    private let maxCacheSize = 50 // Maximum number of cached assets
    private var lastAccessTimes: [String: Date] = [:]
    
    private init() {
        // Set up memory warning observer
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
    
    /// Get or create a video asset for the given parameters
    /// This method handles HLS resolution and metadata extraction automatically
    func getAsset(for videoMid: String, originalURL: URL, contentType: String) async -> CachedVideoAsset {
        // Simple implementation without complex async locking
        
        // Check cache first
        if let cachedAsset = assetCache[videoMid] {
            lastAccessTimes[videoMid] = Date()
            print("DEBUG: [VIDEO ASSET CACHE] Found cached asset for video mid: \(videoMid)")
            return cachedAsset
        }
        
        print("DEBUG: [VIDEO ASSET CACHE] Creating new asset for video mid: \(videoMid)")
        
        // Create new asset
        do {
            let asset = try await createAsset(for: videoMid, originalURL: originalURL, contentType: contentType)
            
            // Store in cache
            assetCache[videoMid] = asset
            lastAccessTimes[videoMid] = Date()
            
            // Clean up cache if needed
            if assetCache.count > maxCacheSize {
                cleanupCacheIfNeeded()
            }
            
            print("DEBUG: [VIDEO ASSET CACHE] Successfully cached asset for video mid: \(videoMid)")
            return asset
        } catch {
            print("ERROR: [VIDEO ASSET CACHE] Failed to create asset for \(videoMid): \(error)")
            
            // Return fallback asset
            return CachedVideoAsset(
                videoMid: videoMid,
                originalURL: originalURL,
                resolvedURL: originalURL,
                isHLS: contentType.lowercased().contains("hls"),
                duration: 0.0,
                aspectRatio: 16.0/9.0,
                metadata: [:]
            )
        }
    }
    
    /// Check if we have a cached asset for the given video mid
    func hasAsset(for videoMid: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return assetCache[videoMid] != nil
    }
    
    /// Remove a specific asset from cache
    func removeAsset(for videoMid: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        if assetCache.removeValue(forKey: videoMid) != nil {
            lastAccessTimes.removeValue(forKey: videoMid)
            print("DEBUG: [VIDEO ASSET CACHE] Removed asset for video mid: \(videoMid)")
        }
    }
    
    /// Clear all cached assets
    func clearCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        assetCache.removeAll()
        lastAccessTimes.removeAll()
        print("DEBUG: [VIDEO ASSET CACHE] Cleared all cached assets")
    }
    
    // MARK: - Private Methods
    
    /// Create a new video asset with HLS resolution and metadata extraction
    private func createAsset(for videoMid: String, originalURL: URL, contentType: String) async throws -> CachedVideoAsset {
        let isHLS = contentType.lowercased().contains("hls")
        
        // Resolve URL if needed (HLS playlist resolution)
        let resolvedURL: URL
        if isHLS {
            resolvedURL = try await resolveHLSPlaylist(originalURL)
        } else {
            resolvedURL = originalURL
        }
        
        // Extract metadata
        let metadata = try await extractVideoMetadata(from: resolvedURL, isHLS: isHLS)
        
        return CachedVideoAsset(
            videoMid: videoMid,
            originalURL: originalURL,
            resolvedURL: resolvedURL,
            isHLS: isHLS,
            duration: metadata.duration,
            aspectRatio: metadata.aspectRatio,
            metadata: metadata.additionalInfo
        )
    }
    
    /// Resolve HLS playlist URL if needed
    private func resolveHLSPlaylist(_ url: URL) async throws -> URL {
        // For now, return the original URL as HLS resolution is complex
        // In a real implementation, you would:
        // 1. Fetch the m3u8 playlist
        // 2. Parse it to get the best quality stream URL
        // 3. Return the resolved stream URL
        
        print("DEBUG: [VIDEO ASSET CACHE] HLS URL resolution for: \(url)")
        return url
    }
    
    /// Extract video metadata (duration, aspect ratio, etc.)
    private func extractVideoMetadata(from url: URL, isHLS: Bool) async throws -> (duration: TimeInterval, aspectRatio: Float, additionalInfo: [String: Any]) {
        let options: [String: Any]
        if isHLS {
            options = [
                "AVURLAssetOutOfBandMIMETypeKey": "application/x-mpegURL",
                "AVURLAssetHTTPHeaderFieldsKey": ["Accept": "*/*"]
            ]
        } else {
            options = [
                "AVURLAssetHTTPHeaderFieldsKey": ["Accept": "*/*"]
            ]
        }
        
        let asset = AVURLAsset(url: url, options: options)
        
        // Load metadata asynchronously
        let duration: CMTime
        let naturalSize: CGSize
        
        if #available(iOS 15.0, *) {
            // Use async/await API for iOS 15+
            duration = try await asset.load(.duration)
            
            // Load tracks to get video size
            let tracks = try await asset.load(.tracks)
            let videoTracks = tracks.filter { track in
                // Use synchronous mediaType property for compatibility
                track.mediaType == .video
            }
            
            if let videoTrack = videoTracks.first {
                // Use the synchronous property for compatibility
                naturalSize = videoTrack.naturalSize
            } else {
                naturalSize = CGSize(width: 16, height: 9) // Default aspect ratio
            }
        } else {
            // Fallback for older iOS versions
            return await withCheckedContinuation { continuation in
                let keys = ["duration", "tracks"]
                asset.loadValuesAsynchronously(forKeys: keys) {
                    var error: NSError?
                    let durationStatus = asset.statusOfValue(forKey: "duration", error: &error)
                    let tracksStatus = asset.statusOfValue(forKey: "tracks", error: &error)
                    
                    guard durationStatus == .loaded && tracksStatus == .loaded else {
                        let fallbackDuration = 0.0
                        let fallbackAspectRatio: Float = 16.0 / 9.0
                        continuation.resume(returning: (fallbackDuration, fallbackAspectRatio, [:]))
                        return
                    }
                    
                    let assetDuration = asset.duration.seconds
                    let videoTracks = asset.tracks(withMediaType: .video)
                    let size = videoTracks.first?.naturalSize ?? CGSize(width: 16, height: 9)
                    let aspectRatio = size.height > 0 ? Float(size.width / size.height) : 16.0 / 9.0
                    
                    continuation.resume(returning: (assetDuration, aspectRatio, [:]))
                }
            }
        }
        
        let durationSeconds = duration.seconds.isFinite ? duration.seconds : 0.0
        let aspectRatio = naturalSize.height > 0 ? Float(naturalSize.width / naturalSize.height) : 16.0 / 9.0
        
        print("DEBUG: [VIDEO ASSET CACHE] Extracted metadata - duration: \(durationSeconds)s, aspect: \(aspectRatio)")
        
        return (
            duration: durationSeconds,
            aspectRatio: aspectRatio,
            additionalInfo: [
                "naturalSize": naturalSize,
                "url": url.absoluteString
            ]
        )
    }
    
    /// Clean up cache using LRU eviction policy
    private func cleanupCacheIfNeeded() {
        guard assetCache.count > maxCacheSize else { return }
        
        print("DEBUG: [VIDEO ASSET CACHE] Cache size (\(assetCache.count)) exceeds limit (\(maxCacheSize)), cleaning up")
        
        // Sort by last access time and remove oldest entries
        let sortedMids = lastAccessTimes.sorted { $0.value < $1.value }.map { $0.key }
        let midsToRemove = sortedMids.prefix(assetCache.count - maxCacheSize)
        
        for mid in midsToRemove {
            assetCache.removeValue(forKey: mid)
            lastAccessTimes.removeValue(forKey: mid)
            print("DEBUG: [VIDEO ASSET CACHE] Removed old cached asset for mid: \(mid)")
        }
    }
    
    /// Handle memory warning by cleaning up cache
    @objc private func handleMemoryWarning() {
        print("DEBUG: [VIDEO ASSET CACHE] Memory warning received, cleaning up cache")
        
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        // Remove half of the cached assets, keeping the most recently accessed
        let targetSize = maxCacheSize / 2
        guard assetCache.count > targetSize else { return }
        
        let sortedMids = lastAccessTimes.sorted { $0.value < $1.value }.map { $0.key }
        let midsToRemove = sortedMids.prefix(assetCache.count - targetSize)
        
        for mid in midsToRemove {
            assetCache.removeValue(forKey: mid)
            lastAccessTimes.removeValue(forKey: mid)
            print("DEBUG: [VIDEO ASSET CACHE] Removed asset for mid: \(mid) due to memory warning")
        }
    }
    
    /// Get cache statistics for debugging
    func getCacheStats() -> (count: Int, maxSize: Int, pendingRequests: Int) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        return (assetCache.count, maxCacheSize, pendingRequests.count)
    }
}
