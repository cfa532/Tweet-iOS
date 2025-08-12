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
    
    // Track individual video restoration to prevent per-video duplicates
    private var videoRestorationTimestamps: [String: Date] = [:]
    private let perVideoRestorationCooldown: TimeInterval = 0.1 // 100ms per video
    
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
    
    /// Get cached playlist URL for HLS videos
    func getCachedPlaylistURL(for videoMid: String) -> (url: URL?, isHLS: Bool)? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        if let cachedPlayer = videoCache[videoMid] {
            cachedPlayer.lastAccessed = Date()
            return (cachedPlayer.resolvedPlaylistURL, cachedPlayer.isHLSMode)
        }
        return nil
    }
    
    /// Set cached playlist URL for HLS videos
    func setCachedPlaylistURL(for videoMid: String, playlistURL: URL?, isHLS: Bool) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        if let cachedPlayer = videoCache[videoMid] {
            cachedPlayer.resolvedPlaylistURL = playlistURL
            cachedPlayer.isHLSMode = isHLS
            cachedPlayer.lastAccessed = Date()
            print("DEBUG: [VIDEO CACHE] Cached playlist URL for \(videoMid): \(playlistURL?.absoluteString ?? "nil"), isHLS: \(isHLS)")
        }
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
    
    /// Check if a video player's layer is healthy (has visual content) - LOCK-FREE VERSION
    private func checkVideoLayerHealthUnsafe(for videoMid: String) -> Bool {
        // This method assumes cacheLock is already held by caller
        guard let cachedPlayer = videoCache[videoMid] else {
            print("DEBUG: [VIDEO CACHE] No cached player for health check: \(videoMid)")
            return false
        }
        
        let player = cachedPlayer.player
        
        // Check if player has content and is ready
        guard let playerItem = player.currentItem,
              playerItem.status == .readyToPlay else {
            print("DEBUG: [VIDEO CACHE] Player not ready for health check: \(videoMid)")
            return false
        }
        
        // Get timing information first
        let currentTime = player.currentTime().seconds
        let duration = playerItem.duration.seconds
        let isPlaying = player.rate > 0
        
        // Check if video has video tracks (not just audio)
        let hasVideoTracks: Bool
        if #available(iOS 16.0, *) {
            // For iOS 16+, we'll use a different approach since tracks is deprecated
            // and load(.tracks) is async, but this is a synchronous health check.
            // We'll check if the asset has duration and the player has visual content
            hasVideoTracks = duration > 0 && playerItem.presentationSize.width > 0
        } else {
            hasVideoTracks = playerItem.asset.tracks(withMediaType: .video).count > 0
        }
        
        print("DEBUG: [VIDEO CACHE] Health check for \(videoMid) - hasVideo: \(hasVideoTracks), time: \(currentTime), duration: \(duration), playing: \(isPlaying)")
        
        return hasVideoTracks && duration > 0
    }
    
    /// Check if a video player's layer is healthy (has visual content)
    func checkVideoLayerHealth(for videoMid: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return checkVideoLayerHealthUnsafe(for: videoMid)
    }
    
    /// Nuclear option: Force recreation of VideoPlayer view for a specific video
    func recreateVideoPlayerView(for videoMid: String) {
        print("DEBUG: [VIDEO CACHE] Nuclear option - recreating VideoPlayer view for \(videoMid)")
        
        // Post notification to trigger VideoPlayer recreation
        NotificationCenter.default.post(
            name: NSNotification.Name("RecreateVideoPlayer"),
            object: nil,
            userInfo: ["videoMid": videoMid]
        )
    }
    
    /// Enhanced immediate restoration for faster recovery from background
    func immediateRestoreVideoPlayers() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        print("DEBUG: [VIDEO CACHE] Immediate video player restoration initiated")
        let now = Date()
        
        for (mid, cachedPlayer) in videoCache {
            // Check per-video cooldown to prevent excessive restoration of individual videos
            if let lastRestoration = videoRestorationTimestamps[mid],
               now.timeIntervalSince(lastRestoration) < perVideoRestorationCooldown {
                print("DEBUG: [VIDEO CACHE] Skipping restoration for \(mid) - too recent")
                continue
            }
            
            videoRestorationTimestamps[mid] = now
            
            // Use preserved state for faster restoration
            let player = cachedPlayer.player
            
            // Simple restoration without preserved state
            let currentTime = player.currentTime()
            print("DEBUG: [VIDEO CACHE] Restoring \(mid) with current time: \(currentTime.seconds)")
            
            // Basic restoration
            player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { completed in
                if completed {
                    print("DEBUG: [VIDEO CACHE] Restoration completed for \(mid)")
                }
            }
            
            cachedPlayer.lastAccessed = Date()
        }
        
        // Comprehensive health check temporarily disabled to prevent freezing
        // TODO: Re-implement without deadlocks
    }
    
    /// Check all cached videos and recreate those with broken layers
    private func checkAndRecreateUnhealthyVideos() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        print("DEBUG: [VIDEO CACHE] Checking all cached videos for layer health")
        
        var unhealthyVideos: [String] = []
        
        for (mid, _) in videoCache {
            let isHealthy = checkVideoLayerHealthUnsafe(for: mid) // Use lock-free version
            if !isHealthy {
                print("DEBUG: [VIDEO CACHE] Found unhealthy video \(mid) - will schedule recreation")
                unhealthyVideos.append(mid)
            }
        }
        
        // Schedule recreations outside the lock to prevent deadlock
        for mid in unhealthyVideos {
            DispatchQueue.main.async {
                self.recreateVideoPlayerView(for: mid)
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
    var resolvedPlaylistURL: URL? = nil // Cache resolved HLS playlist URL
    var isHLSMode: Bool = true // Remember if this is HLS or regular video
    
    init(player: AVPlayer, videoMid: String, url: URL) {
        self.player = player
        self.videoMid = videoMid
        self.url = url
        self.lastAccessed = Date()
        self.resolvedPlaylistURL = nil
        self.isHLSMode = true
    }
} 