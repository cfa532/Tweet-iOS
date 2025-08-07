//
//  VideoCacheManager.swift
//  Tweet
//
//  Video cache manager that uses mid field as key and doesn't release videos when they finish
//

import Foundation
import AVKit
import AVFoundation

class VideoCacheManager: ObservableObject {
    static let shared = VideoCacheManager()
    
    // Cache of video players using mid as key
    private var videoCache: [String: CachedVideoPlayer] = [:]
    private let cacheLock = NSLock()
    
    // Maximum number of cached videos to keep in memory
    private let maxCacheSize = Constants.VIDEO_CACHE_POOL_SIZE
    
    private init() {
        // Set up memory warning observer to clean up cache when system needs memory
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
    
    /// Get or create a video player for the given video mid
    func getVideoPlayer(for videoMid: String, url: URL, isHLS: Bool = true) -> AVPlayer? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        // Check if we already have a cached player for this video mid
        if let cachedPlayer = videoCache[videoMid] {
            print("DEBUG: [VIDEO CACHE] Found cached player for video mid: \(videoMid)")
            cachedPlayer.lastAccessed = Date()
            return cachedPlayer.player
        }
        
        // Create new player and cache it
        print("DEBUG: [VIDEO CACHE] Creating new player for video mid: \(videoMid), isHLS: \(isHLS)")
        let player = createVideoPlayer(for: url, isHLS: isHLS)
        let cachedPlayer = CachedVideoPlayer(player: player, videoMid: videoMid, url: url)
        videoCache[videoMid] = cachedPlayer
        
        // Clean up cache if it's too large
        cleanupCacheIfNeeded()
        
        return player
    }
    
    /// Create a new video player for the given URL
    private func createVideoPlayer(for url: URL, isHLS: Bool = true) -> AVPlayer {
        // Create asset with appropriate options based on video type
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
        
        let asset = AVURLAsset(url: url, options: options)
        
        // Create player item with asset
        let playerItem = AVPlayerItem(asset: asset)
        
        // Configure player item for better performance
        playerItem.preferredForwardBufferDuration = 10.0
        playerItem.preferredPeakBitRate = 0 // Let system decide
        
        // Create AVPlayer with the player item
        let player = AVPlayer(playerItem: playerItem)
        
        // Enable hardware acceleration
        player.automaticallyWaitsToMinimizeStalling = true
        
        return player
    }
    
    /// Reset a video player to the beginning without recreating it
    func resetVideoPlayer(for videoMid: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        if let cachedPlayer = videoCache[videoMid] {
            print("DEBUG: [VIDEO CACHE] Resetting player for video mid: \(videoMid)")
            cachedPlayer.player.seek(to: CMTime.zero)
            cachedPlayer.lastAccessed = Date()
        }
    }
    
    /// Pause a video player without removing it from cache
    func pauseVideoPlayer(for videoMid: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        if let cachedPlayer = videoCache[videoMid] {
            print("DEBUG: [VIDEO CACHE] Pausing player for video mid: \(videoMid)")
            cachedPlayer.player.pause()
            cachedPlayer.lastAccessed = Date()
        }
    }
    
    /// Pause all videos except the specified one (useful for force play scenarios)
    func pauseAllVideosExcept(for videoMid: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        for (mid, cachedPlayer) in videoCache {
            if mid != videoMid {
                print("DEBUG: [VIDEO CACHE] Pausing other video with mid: \(mid)")
                cachedPlayer.player.pause()
                cachedPlayer.lastAccessed = Date()
            }
        }
    }
    
    /// Pause all videos in cache (useful for app lifecycle management)
    func pauseAllVideos() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        for (mid, cachedPlayer) in videoCache {
            print("DEBUG: [VIDEO CACHE] Pausing player for video mid: \(mid)")
            cachedPlayer.player.pause()
            cachedPlayer.lastAccessed = Date()
        }
    }
    
    /// Set mute state for a video player
    func setMuteState(for videoMid: String, isMuted: Bool) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        if let cachedPlayer = videoCache[videoMid] {
            print("DEBUG: [VIDEO CACHE] Setting mute state for video mid: \(videoMid) to: \(isMuted)")
            cachedPlayer.player.isMuted = isMuted
            cachedPlayer.lastAccessed = Date()
        }
    }
    
    /// Check if a video player exists in cache
    func hasVideoPlayer(for videoMid: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        return videoCache[videoMid] != nil
    }
    
    /// Remove a specific video from cache (only when explicitly needed)
    func removeVideoPlayer(for videoMid: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        if let cachedPlayer = videoCache.removeValue(forKey: videoMid) {
            print("DEBUG: [VIDEO CACHE] Removed player for video mid: \(videoMid)")
            cachedPlayer.player.pause()
            // Player will be deallocated when no references remain
        }
    }
    
    /// Clean up cache if it exceeds maximum size
    private func cleanupCacheIfNeeded() {
        guard videoCache.count > maxCacheSize else { return }
        
        print("DEBUG: [VIDEO CACHE] Cache size (\(videoCache.count)) exceeds limit (\(maxCacheSize)), cleaning up")
        
        // Sort by last accessed time and remove oldest entries
        let sortedEntries = videoCache.sorted { $0.value.lastAccessed < $1.value.lastAccessed }
        let entriesToRemove = sortedEntries.prefix(videoCache.count - maxCacheSize)
        
        for (mid, _) in entriesToRemove {
            videoCache.removeValue(forKey: mid)
            print("DEBUG: [VIDEO CACHE] Removed old cached player for mid: \(mid)")
        }
    }
    
    /// Handle memory warning by cleaning up cache
    @objc private func handleMemoryWarning() {
        print("DEBUG: [VIDEO CACHE] Memory warning received, cleaning up cache")
        
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        // Remove all cached videos when memory is low
        let midsToRemove = Array(videoCache.keys)
        for mid in midsToRemove {
            if let cachedPlayer = videoCache.removeValue(forKey: mid) {
                cachedPlayer.player.pause()
                print("DEBUG: [VIDEO CACHE] Removed player for mid: \(mid) due to memory warning")
            }
        }
    }
    
    /// Get cache statistics for debugging
    func getCacheStats() -> (count: Int, maxSize: Int) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        return (videoCache.count, maxCacheSize)
    }
    
    /// Clear entire cache (for testing or explicit cleanup)
    func clearCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        print("DEBUG: [VIDEO CACHE] Clearing entire cache")
        let midsToRemove = Array(videoCache.keys)
        for mid in midsToRemove {
            if let cachedPlayer = videoCache.removeValue(forKey: mid) {
                cachedPlayer.player.pause()
            }
        }
    }
}

/// Cached video player wrapper
class CachedVideoPlayer {
    let player: AVPlayer
    let videoMid: String
    let url: URL
    var lastAccessed: Date
    
    init(player: AVPlayer, videoMid: String, url: URL) {
        self.player = player
        self.videoMid = videoMid
        self.url = url
        self.lastAccessed = Date()
    }
} 