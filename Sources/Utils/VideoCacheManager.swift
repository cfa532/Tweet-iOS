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
    
    /// Pause all video players except the specified one (for full-screen mode)
    func pauseAllVideosExcept(_ videoMid: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        print("DEBUG: [VIDEO CACHE] Pausing all videos except: \(videoMid)")
        for (mid, cachedPlayer) in videoCache {
            if mid != videoMid {
                print("DEBUG: [VIDEO CACHE] Pausing video: \(mid)")
                cachedPlayer.player.pause()
                cachedPlayer.lastAccessed = Date()
            }
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
    
    /// Get a cached video player without creating a new one
    func getCachedPlayer(for videoMid: String) -> AVPlayer? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        if let cachedPlayer = videoCache[videoMid] {
            cachedPlayer.lastAccessed = Date()
            return cachedPlayer.player
        }
        
        return nil
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
    
    /// Restore video players when app becomes active (fixes black screen issue)
    func restoreVideoPlayers() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        print("DEBUG: [VIDEO CACHE] Restoring video players after app became active")
        
        for (mid, cachedPlayer) in videoCache {
            // Force the player layer to refresh by seeking to current time
            let currentTime = cachedPlayer.player.currentTime()
            cachedPlayer.player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                // This forces the video layer to redraw
                print("DEBUG: [VIDEO CACHE] Restored video layer for mid: \(mid)")
            }
            cachedPlayer.lastAccessed = Date()
        }
    }
    
    /// Force refresh video layer for a specific video (for severe black screen cases)
    func forceRefreshVideoLayer(for videoMid: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        guard let cachedPlayer = videoCache[videoMid] else {
            print("DEBUG: [VIDEO CACHE] No cached player found for mid: \(videoMid)")
            return
        }
        
        print("DEBUG: [VIDEO CACHE] Force refreshing video layer for mid: \(videoMid)")
        
        // More aggressive restoration for severe black screen cases
        let currentTime = cachedPlayer.player.currentTime()
        
        // First, pause the player
        cachedPlayer.player.pause()
        
        // Then seek to current time with zero tolerance to force layer refresh
        cachedPlayer.player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            // Resume playback if it was playing before
            if cachedPlayer.player.rate != 0 {
                cachedPlayer.player.play()
            }
            print("DEBUG: [VIDEO CACHE] Force refreshed video layer for mid: \(videoMid)")
        }
        
        cachedPlayer.lastAccessed = Date()
    }
    
    /// Handle video restoration after app has been idle (fixes black screen from long idle periods)
    func handleVideoRestorationAfterIdle() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        print("DEBUG: [VIDEO CACHE] Handling video restoration after idle period")
        
        for (mid, cachedPlayer) in videoCache {
            // Check if the player item is still valid
            guard let playerItem = cachedPlayer.player.currentItem,
                  playerItem.status == .readyToPlay else {
                print("DEBUG: [VIDEO CACHE] Player item not ready for mid: \(mid), skipping restoration")
                continue
            }
            
            // For videos that were playing before, try to restore them
            let wasPlaying = cachedPlayer.player.rate != 0
            let currentTime = cachedPlayer.player.currentTime()
            
            // Force a seek to refresh the video layer
            cachedPlayer.player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                if wasPlaying {
                    // Resume playback if it was playing before
                    cachedPlayer.player.play()
                    print("DEBUG: [VIDEO CACHE] Restored and resumed video for mid: \(mid)")
                } else {
                    print("DEBUG: [VIDEO CACHE] Restored video layer for mid: \(mid) (was paused)")
                }
            }
            
            cachedPlayer.lastAccessed = Date()
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