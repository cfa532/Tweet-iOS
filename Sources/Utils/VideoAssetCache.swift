//
//  VideoAssetCache.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  Asset-level caching for efficient video sharing across contexts
//

import AVFoundation
import Foundation

/// Cached video asset with metadata
struct CachedVideoAsset {
    let asset: AVAsset
    let url: URL
    let duration: CMTime
    let naturalSize: CGSize
    let aspectRatio: Float
    
    /// Create a new player item from this cached asset
    func createPlayerItem() -> AVPlayerItem {
        return AVPlayerItem(asset: asset)
    }
}

/// Manages shared video assets to avoid duplicate network requests and memory usage
@MainActor
class VideoAssetCache: ObservableObject {
    static let shared = VideoAssetCache()
    
    private init() {}
    
    // MARK: - Cache Storage
    private var assetCache: [String: CachedVideoAsset] = [:]
    private var loadingTasks: [String: Task<CachedVideoAsset, Error>] = [:]
    
    // MARK: - Cache Management
    private let maxCacheSize = 50 // Maximum number of cached assets
    
    /// Get cached asset or load if not available
    func getAsset(for url: URL) async -> CachedVideoAsset {
        let cacheKey = url.absoluteString
        
        // Return cached asset if available
        if let cachedAsset = assetCache[cacheKey] {
            print("DEBUG: [VIDEO ASSET CACHE] Cache HIT for: \(url.lastPathComponent)")
            return cachedAsset
        }
        
        // Check if already loading
        if let existingTask = loadingTasks[cacheKey] {
            print("DEBUG: [VIDEO ASSET CACHE] Already loading: \(url.lastPathComponent)")
            do {
                return try await existingTask.value
            } catch {
                print("ERROR: [VIDEO ASSET CACHE] Loading task failed: \(error)")
                // Fall through to create new task
            }
        }
        
        // Create new loading task
        print("DEBUG: [VIDEO ASSET CACHE] Cache MISS - loading: \(url.lastPathComponent)")
        let loadingTask = Task<CachedVideoAsset, Error> {
            return try await createAsset(from: url)
        }
        
        loadingTasks[cacheKey] = loadingTask
        
        do {
            let asset = try await loadingTask.value
            
            // Cache the asset
            assetCache[cacheKey] = asset
            loadingTasks.removeValue(forKey: cacheKey)
            
            // Manage cache size
            manageCacheSize()
            
            print("DEBUG: [VIDEO ASSET CACHE] Cached asset for: \(url.lastPathComponent)")
            return asset
            
        } catch {
            loadingTasks.removeValue(forKey: cacheKey)
            print("ERROR: [VIDEO ASSET CACHE] Failed to load asset: \(error)")
            
            // Return fallback asset
            return createFallbackAsset(for: url)
        }
    }
    
    /// Create asset with metadata
    private func createAsset(from url: URL) async throws -> CachedVideoAsset {
        // Resolve HLS URLs if needed
        let resolvedURL = await resolveHLSURL(url)
        
        // Create asset
        let asset = AVAsset(url: resolvedURL)
        
        // Load metadata
        let duration = try await asset.load(.duration)
        
        // Get video track for size information
        let allTracks = try await asset.load(.tracks)
        var videoTracks: [AVAssetTrack] = []
        
        // Filter video tracks using synchronous mediaType property
        for track in allTracks {
            if track.mediaType == .video {
                videoTracks.append(track)
            }
        }
        
        var naturalSize = CGSize(width: 1920, height: 1080) // Default
        if let videoTrack = videoTracks.first {
            naturalSize = try await videoTrack.load(.naturalSize)
        }
        
        let aspectRatio = Float(naturalSize.width / naturalSize.height)
        
        return CachedVideoAsset(
            asset: asset,
            url: resolvedURL,
            duration: duration,
            naturalSize: naturalSize,
            aspectRatio: aspectRatio
        )
    }
    
    /// Handle HLS URL resolution
    private func resolveHLSURL(_ url: URL) async -> URL {
        let urlString = url.absoluteString
        
        // If already an m3u8 file, return as-is
        if urlString.hasSuffix(".m3u8") || urlString.hasSuffix(".mp4") {
            return url
        }
        
        // Try to find HLS playlist
        let masterURL = url.appendingPathComponent("master.m3u8")
        let playlistURL = url.appendingPathComponent("playlist.m3u8")
        
        if await urlExists(masterURL) {
            print("DEBUG: [VIDEO ASSET CACHE] Found master.m3u8 for: \(url.lastPathComponent)")
            return masterURL
        }
        
        if await urlExists(playlistURL) {
            print("DEBUG: [VIDEO ASSET CACHE] Found playlist.m3u8 for: \(url.lastPathComponent)")
            return playlistURL
        }
        
        print("DEBUG: [VIDEO ASSET CACHE] No HLS playlist found, using original URL: \(url.lastPathComponent)")
        return url
    }
    
    /// Check if URL exists
    private func urlExists(_ url: URL) async -> Bool {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 3.0
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
    
    /// Create fallback asset for failed loads
    private func createFallbackAsset(for url: URL) -> CachedVideoAsset {
        let asset = AVAsset(url: url) // Basic asset without metadata
        return CachedVideoAsset(
            asset: asset,
            url: url,
            duration: .zero,
            naturalSize: CGSize(width: 1920, height: 1080),
            aspectRatio: 16.0/9.0
        )
    }
    
    /// Manage cache size using LRU
    private func manageCacheSize() {
        if assetCache.count > maxCacheSize {
            // Remove oldest entries (simple implementation)
            let keysToRemove = Array(assetCache.keys.prefix(assetCache.count - maxCacheSize))
            for key in keysToRemove {
                assetCache.removeValue(forKey: key)
            }
            print("DEBUG: [VIDEO ASSET CACHE] Cleaned cache, removed \(keysToRemove.count) assets")
        }
    }
    
    /// Clear all cached assets
    func clearCache() {
        assetCache.removeAll()
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll()
        print("DEBUG: [VIDEO ASSET CACHE] Cache cleared")
    }
    
    /// Get cache statistics
    func getCacheStats() -> (cached: Int, loading: Int) {
        return (assetCache.count, loadingTasks.count)
    }
}
