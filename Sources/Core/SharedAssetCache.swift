//
//  SharedAssetCache.swift
//  Tweet
//
//  Created by 超方 on 2025/8/11.
//
import SwiftUI
import AVKit
import AVFoundation

// MARK: - Asset Sharing System
/// Shared asset cache to avoid duplicate network requests and provide immediate cached content
class SharedAssetCache: ObservableObject {
    static let shared = SharedAssetCache()
    private init() {}
    
    @MainActor private var assetCache: [String: AVAsset] = [:]
    @MainActor private var playerCache: [String: AVPlayer] = [:]
    @MainActor private var loadingTasks: [String: Task<AVAsset, Error>] = [:]
    @MainActor private var cacheTimestamps: [String: Date] = [:]
    
    /// Get cached player immediately if available
    @MainActor func getCachedPlayer(for url: URL) -> AVPlayer? {
        let cacheKey = url.absoluteString
        return playerCache[cacheKey]
    }
    
    /// Get or create asset for URL with HLS resolution
    @MainActor func getAsset(for url: URL) async throws -> AVAsset {
        let cacheKey = url.absoluteString
        
        // Check if we have a cached asset
        if let cachedAsset = assetCache[cacheKey] {
            print("DEBUG: [SHARED ASSET CACHE] Using cached asset for: \(url.lastPathComponent)")
            return cachedAsset
        }
        
        // Check if there's already a loading task
        if let existingTask = loadingTasks[cacheKey] {
            print("DEBUG: [SHARED ASSET CACHE] Waiting for existing loading task for: \(url.lastPathComponent)")
            do {
                return try await existingTask.value
            } catch {
                print("DEBUG: [SHARED ASSET CACHE] Error waiting for existing task: \(error)")
                loadingTasks.removeValue(forKey: cacheKey)
                // Fall through to create new task
            }
        }
        
        // Create new loading task
        let task = Task<AVAsset, Error> {
            print("DEBUG: [SHARED ASSET CACHE] Creating new asset for: \(url.lastPathComponent)")
            let resolvedURL = await resolveHLSURL(url)
            let asset = AVAsset(url: resolvedURL)
            
            // Cache the asset
            await MainActor.run {
                self.assetCache[cacheKey] = asset
                self.cacheTimestamps[cacheKey] = Date()
                self.loadingTasks.removeValue(forKey: cacheKey)
            }
            
            print("DEBUG: [SHARED ASSET CACHE] Cached asset for: \(url.lastPathComponent)")
            return asset
        }
        
        // Store the task
        loadingTasks[cacheKey] = task
        
        do {
            return try await task.value
        } catch {
            print("DEBUG: [SHARED ASSET CACHE] Error creating asset: \(error)")
            loadingTasks.removeValue(forKey: cacheKey)
            throw error
        }
    }
    
    /// Cache a player instance for immediate reuse
    @MainActor func cachePlayer(_ player: AVPlayer, for url: URL) {
        let cacheKey = url.absoluteString
        playerCache[cacheKey] = player
        print("DEBUG: [SHARED ASSET CACHE] Cached player for: \(url.lastPathComponent)")
    }
    
    /// Remove cached player (when it becomes invalid)
    @MainActor func removeCachedPlayer(for url: URL) {
        let cacheKey = url.absoluteString
        playerCache.removeValue(forKey: cacheKey)
        print("DEBUG: [SHARED ASSET CACHE] Removed invalid cached player for: \(url.lastPathComponent)")
    }
    
    /// Get cached player or create new one with asset
    @MainActor func getOrCreatePlayer(for url: URL) async throws -> AVPlayer {
        // Try to get cached player first
        if let cachedPlayer = getCachedPlayer(for: url) {
            print("DEBUG: [SHARED ASSET CACHE] Using cached player for: \(url.lastPathComponent)")
            return cachedPlayer
        }
        
        // Create new player with asset
        let asset = try await getAsset(for: url)
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        
        // Cache the player for future use
        cachePlayer(player, for: url)
        
        return player
    }
    
    /// Resolve HLS URL if needed
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
            print("DEBUG: [SHARED ASSET CACHE] Found master.m3u8 for: \(url.lastPathComponent)")
            return masterURL
        }
        
        if await urlExists(playlistURL) {
            print("DEBUG: [SHARED ASSET CACHE] Found playlist.m3u8 for: \(url.lastPathComponent)")
            return playlistURL
        }
        return url
    }
    
    /// Check if URL exists
    private func urlExists(_ url: URL) async -> Bool {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 15.0
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
    
    /// Clear cache
    @MainActor func clearCache() {
        assetCache.removeAll()
        playerCache.removeAll()
        cacheTimestamps.removeAll()
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll()
        print("DEBUG: [SHARED ASSET CACHE] Cache cleared")
    }
    
    /// Preload video for immediate display
    func preloadVideo(for url: URL) {
        Task {
            do {
                _ = try await getOrCreatePlayer(for: url)
            } catch {
                print("DEBUG: [SHARED ASSET CACHE] Error preloading video: \(error)")
            }
        }
    }
    
    /// Preload asset only (for background loading)
    func preloadAsset(for url: URL) {
        Task {
            do {
                _ = try await getAsset(for: url)
            } catch {
                print("DEBUG: [SHARED ASSET CACHE] Error preloading asset: \(error)")
            }
        }
    }
    
    /// Get cache statistics
    @MainActor func getCacheStats() -> (assetCount: Int, playerCount: Int) {
        return (assetCache.count, playerCache.count)
    }
}
