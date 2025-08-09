//
//  VideoAssetCache.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  Shared video asset caching layer for the new video architecture
//

import Foundation
import AVFoundation
import AVKit

/// Cached video asset with metadata
struct CachedVideoAsset {
    let playerItem: AVPlayerItem
    let duration: TimeInterval
    let aspectRatio: CGFloat
    let resolvedURL: URL
    
    func createPlayerItem() -> AVPlayerItem {
        // Create a new player item from the same asset
        return AVPlayerItem(asset: playerItem.asset)
    }
}

/// Shared cache for video assets, metadata, and resolved URLs
/// Separates data caching from player management
class VideoAssetCache {
    static let shared = VideoAssetCache()
    
    // Cache storage
    private var assetCache: [String: CachedVideoAsset] = [:]
    private var urlCache: [String: URL] = [:]
    private let maxCacheSize = 50
    
    private init() {}
    
    /// Get cached asset or create new one
    func getAsset(for videoMid: String, originalURL: URL, contentType: String) async -> CachedVideoAsset {
        // Check cache first (simple check without complex locking)
        if let cached = assetCache[videoMid] {
            print("DEBUG: [VIDEO ASSET CACHE] Cache hit for: \(videoMid)")
            return cached
        }
        
        print("DEBUG: [VIDEO ASSET CACHE] Cache miss, creating asset for: \(videoMid)")
        
        do {
            let asset = try await createAsset(for: videoMid, originalURL: originalURL, contentType: contentType)
            
            // Store in cache with simple LRU management
            assetCache[videoMid] = asset
            if assetCache.count > maxCacheSize {
                // Remove oldest entry (simple LRU)
                if let firstKey = assetCache.keys.first {
                    assetCache.removeValue(forKey: firstKey)
                }
            }
            
            return asset
        } catch {
            print("ERROR: [VIDEO ASSET CACHE] Failed to create asset for \(videoMid): \(error)")
            // Return fallback asset
            let fallbackAsset = AVAsset(url: originalURL)
            let fallbackItem = AVPlayerItem(asset: fallbackAsset)
            return CachedVideoAsset(
                playerItem: fallbackItem,
                duration: 0,
                aspectRatio: 16.0/9.0,
                resolvedURL: originalURL
            )
        }
    }
    
    /// Create asset with metadata extraction
    private func createAsset(for videoMid: String, originalURL: URL, contentType: String) async throws -> CachedVideoAsset {
        let resolvedURL: URL
        
        // Resolve HLS URLs if needed
        if contentType.lowercased() == "hls_video" {
            resolvedURL = try await resolveHLSPlaylist(originalURL)
            print("DEBUG: [VIDEO ASSET CACHE] HLS resolved: \(originalURL) -> \(resolvedURL)")
        } else {
            resolvedURL = originalURL
        }
        
        // Create asset and load metadata
        let asset = AVAsset(url: resolvedURL)
        let playerItem = AVPlayerItem(asset: asset)
        
        // Extract metadata
        let duration = try await asset.load(.duration).seconds
        var aspectRatio: CGFloat = 16.0/9.0 // Default
        
        // Get video tracks for aspect ratio
        let tracks = try await asset.load(.tracks)
        for track in tracks {
            let mediaType = track.mediaType
            if mediaType == .video {
                let naturalSize = try await track.load(.naturalSize)
                if naturalSize.height > 0 {
                    aspectRatio = naturalSize.width / naturalSize.height
                }
                break
            }
        }
        
        print("DEBUG: [VIDEO ASSET CACHE] Asset created - duration: \(duration)s, aspect: \(aspectRatio)")
        
        return CachedVideoAsset(
            playerItem: playerItem,
            duration: duration,
            aspectRatio: aspectRatio,
            resolvedURL: resolvedURL
        )
    }
    
    /// Resolve HLS playlist URL
    private func resolveHLSPlaylist(_ url: URL) async throws -> URL {
        print("DEBUG: [VIDEO ASSET CACHE] HLS URL resolution for: \(url)")
        
        let masterURL = url.appendingPathComponent("master.m3u8")
        let playlistURL = url.appendingPathComponent("playlist.m3u8")
        
        if await urlExists(masterURL) {
            print("DEBUG: [VIDEO ASSET CACHE] Found master.m3u8 for: \(url)")
            return masterURL
        }
        
        if await urlExists(playlistURL) {
            print("DEBUG: [VIDEO ASSET CACHE] Found playlist.m3u8 for: \(url)")
            return playlistURL
        }
        
        print("DEBUG: [VIDEO ASSET CACHE] No HLS playlist found, using original URL: \(url)")
        return url
    }
    
    /// Check if URL exists
    private func urlExists(_ url: URL) async -> Bool {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5.0
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }
    
    /// Clear cache
    func clearCache() {
        assetCache.removeAll()
        urlCache.removeAll()
        print("DEBUG: [VIDEO ASSET CACHE] Cache cleared")
    }
}
