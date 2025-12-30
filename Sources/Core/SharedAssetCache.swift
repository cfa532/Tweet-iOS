//
//  SharedAssetCache.swift
//  Tweet
//
//  Shared asset cache for video players with background loading support
//

import Foundation
import AVFoundation
import UIKit

// MARK: - Cache Metadata Structure
private struct CacheMetadata: Codable {
    let cachedMediaIDs: [String: Date] // mediaID -> timestamp
}
// CachingPlayerItem is now integrated directly

/// Shared asset cache for video players with background loading and priority management
@MainActor
class SharedAssetCache: ObservableObject {
    static let shared = SharedAssetCache()
    
    // MARK: - CachingPlayerItem Delegate
    private class CachingPlayerItemDelegateImpl: NSObject, CachingPlayerItemDelegate {
        func playerItem(_ playerItem: CachingPlayerItem, didFinishDownloadingFileAt filePath: String) {
            print("DEBUG: [CachingPlayerItem] Finished downloading file at: \(filePath)")
        }
        
        func playerItem(_ playerItem: CachingPlayerItem, didDownloadBytesSoFar bytesDownloaded: Int, outOf bytesExpected: Int) {
            let progress = bytesExpected > 0 ? Double(bytesDownloaded) / Double(bytesExpected) * 100 : 0
            print("DEBUG: [CachingPlayerItem] Download progress: \(String(format: "%.1f", progress))% (\(bytesDownloaded)/\(bytesExpected) bytes)")
        }
        
        func playerItem(_ playerItem: CachingPlayerItem, downloadingFailedWith error: Error) {
            print("DEBUG: [CachingPlayerItem] Download failed: \(error)")
        }
        
        func playerItemReadyToPlay(_ playerItem: CachingPlayerItem) {
            print("DEBUG: [CachingPlayerItem] Player item ready to play")
        }
        
        func playerItemDidFailToPlay(_ playerItem: CachingPlayerItem, withError error: Error?) {
            print("DEBUG: [CachingPlayerItem] Player item failed to play: \(error?.localizedDescription ?? "Unknown error")")
        }
        
        func playerItemPlaybackStalled(_ playerItem: CachingPlayerItem) {
            print("DEBUG: [CachingPlayerItem] Player item playback stalled")
        }
    }
    
    private init() {
        // Restore cache from disk on startup
        restoreCacheFromDisk()
        
        // Start background cleanup timer
        startBackgroundCleanup()
        
        // Set up app lifecycle notifications
        setupAppLifecycleNotifications()
        
        // Set up memory warning notifications
        setupMemoryWarningNotifications()
        
        // Start proactive memory monitoring
        startMemoryMonitoring()
        
        // Initialize disk cache cleanup manager
        _ = DiskCacheCleanupManager.shared
        
        // Initialize memory cap manager
        _ = MemoryCapManager.shared
    }
    
    // MARK: - Cache Storage
    private var assetCache: [String: AVAsset] = [:] // mediaID -> AVAsset
    private var playerCache: [String: AVPlayer] = [:] // mediaID -> AVPlayer
    private var cacheTimestamps: [String: Date] = [:] // mediaID -> timestamp
    private var cachingPlayerDelegates: [String: CachingPlayerItemDelegateImpl] = [:] // mediaID -> Delegate
    private var cachingPlayerItems: [String: CachingPlayerItem] = [:] // mediaID -> CachingPlayerItem
    private var resourceLoaderDelegates: [String: ResourceLoaderDelegate] = [:] // mediaID -> ResourceLoaderDelegate
    private var loadingTasks: [String: Task<AVAsset, Error>] = [:] // mediaID -> loading task
    private var preloadTasks: [String: Task<Void, Never>] = [:] // mediaID -> preload task
    private var tweetUrlMapping: [String: Set<String>] = [:] // tweetId -> Set of mediaIDs
    
    // MARK: - Disk Cache Status Cache (to avoid repeated disk I/O)
    private var diskCacheStatus: [String: (exists: Bool, timestamp: Date)] = [:] // mediaID -> (cache exists, check timestamp)
    private let diskCacheStatusTTL: TimeInterval = 60 // Cache disk status for 60 seconds
    
    // MARK: - Configuration
    private let maxCacheSize = Constants.MAX_ASSET_CACHE_SIZE
    private let maxPlayerCacheSize = Constants.MAX_PLAYER_CACHE_SIZE
    private let cacheExpirationInterval: TimeInterval = Constants.CACHE_EXPIRATION_SECONDS
    private let maxVideoFileSize: Int64 = Constants.MAX_VIDEO_FILE_CACHE_SIZE
    
    // MARK: - Cache Persistence
    private let cacheMetadataKey = "SharedAssetCache_Metadata"
    
    // MARK: - Background Cleanup
    private var cleanupTimer: Timer?
    private var memoryMonitorTimer: Timer?
    
    private func startBackgroundCleanup() {
        // PERFORMANCE FIX: Reduced cleanup interval from 30s to 15s for more aggressive cleanup
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in
                self.performCleanup()
            }
        }
    }
    
    private func startMemoryMonitoring() {
        // PERFORMANCE FIX: Monitor memory more frequently (every 5 seconds) to catch rapid growth
        memoryMonitorTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in
                self.checkMemoryPressure()
            }
        }
    }
    
    private func performCleanup() {
        let now = Date()
        let expiredKeys = cacheTimestamps.filter { now.timeIntervalSince($0.value) > cacheExpirationInterval }.map { $0.key }
        
        for key in expiredKeys {
            // PERFORMANCE FIX: Pause players before removing
            if let player = playerCache[key] {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
            
            assetCache.removeValue(forKey: key)
            playerCache.removeValue(forKey: key)
            cacheTimestamps.removeValue(forKey: key)
            cachingPlayerItems.removeValue(forKey: key)
            resourceLoaderDelegates.removeValue(forKey: key)
        }
        
        if !expiredKeys.isEmpty {
            print("DEBUG: [SharedAssetCache] Cleaned up \(expiredKeys.count) expired items")
        }
        
        // Manage cache size
        manageCacheSize()
        
        // PERFORMANCE FIX: Also trigger player cache size management
        managePlayerCacheSize()
    }
    
    // MARK: - Asset Management
    
    /// Cancel loading tasks for a specific URL only if no cache is available
    @MainActor func cancelLoading(for mediaID: String) {
        // Check if we have cached content before cancelling
        let hasCachedAsset = assetCache[mediaID] != nil
        let hasCachedPlayer = playerCache[mediaID] != nil
        
        // Cancel loading task if exists and no cache is available
        if let loadingTask = loadingTasks[mediaID] {
            if !hasCachedAsset && !hasCachedPlayer {
                loadingTask.cancel()
                loadingTasks.removeValue(forKey: mediaID)
                print("DEBUG: [SharedAssetCache] Cancelled loading task for mediaID: \(mediaID) (no cache available)")
            } else {
                print("DEBUG: [SharedAssetCache] Keeping loading task for mediaID: \(mediaID) (cache available)")
            }
        }
        
        // Cancel preload task if exists and no cache is available
        if let preloadTask = preloadTasks[mediaID] {
            if !hasCachedAsset && !hasCachedPlayer {
                preloadTask.cancel()
                preloadTasks.removeValue(forKey: mediaID)
                print("DEBUG: [SharedAssetCache] Cancelled preload task for mediaID: \(mediaID) (no cache available)")
            } else {
                print("DEBUG: [SharedAssetCache] Keeping preload task for mediaID: \(mediaID) (cache available)")
            }
        }
    }
    
    /// Get mediaIDs associated with a tweet
    private func getMediaIDsForTweet(_ tweetId: String) -> [String] {
        guard let mediaIDs = tweetUrlMapping[tweetId] else { return [] }
        return Array(mediaIDs)
    }
    
    /// Track mediaID for a tweet
    private func trackMediaID(_ mediaID: String, for tweetId: String) {
        if tweetUrlMapping[tweetId] == nil {
            tweetUrlMapping[tweetId] = Set<String>()
        }
        tweetUrlMapping[tweetId]?.insert(mediaID)
    }
    
    /// Check if content has been cached (works for both tweet IDs and media IDs)
    /// Just checks if the ID exists in any cache - IDs never overlap so no ambiguity
    @MainActor func hasCachedContent(for id: String) -> Bool {
        // Direct check - works for both tweet IDs and media IDs since they don't overlap
        if assetCache[id] != nil || playerCache[id] != nil {
            return true
        }
        
        if hasDiskCache(for: id) {
            return true
        }
        
        // Also check if this ID maps to any media (in case it's a tweet ID)
        let tweetMediaIDs = getMediaIDsForTweet(id)
        for mediaID in tweetMediaIDs {
            if assetCache[mediaID] != nil || playerCache[mediaID] != nil {
                return true
            }
            if hasDiskCache(for: mediaID) {
                return true
            }
        }
        
        return false
    }
    
    /// Check if mediaID has disk cache available (with in-memory caching to avoid repeated disk I/O)
    private func hasDiskCache(for mediaID: String) -> Bool {
        // Check in-memory cache first
        if let cachedStatus = diskCacheStatus[mediaID] {
            let age = Date().timeIntervalSince(cachedStatus.timestamp)
            if age < diskCacheStatusTTL {
                // Cache is still valid
                return cachedStatus.exists
            }
            // Cache expired, will recheck
        }
        
        // Perform disk check
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let mediaCacheDir = cacheDir.appendingPathComponent(mediaID)
        
        var diskCacheExists = false
        
        // Check if cache directory exists and has files
        if FileManager.default.fileExists(atPath: mediaCacheDir.path) {
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: mediaCacheDir.path)
                // Check for any video files (playlists or segments)
                let hasVideoFiles = contents.contains { file in
                    file.hasSuffix(".m3u8") || file.hasSuffix(".ts") || file.hasSuffix(".mp4")
                }
                if hasVideoFiles {
                    print("DEBUG: [SharedAssetCache] Found disk cache for mediaID: \(mediaID)")
                    diskCacheExists = true
                }
            } catch {
                print("DEBUG: [SharedAssetCache] Error checking disk cache for \(mediaID): \(error)")
            }
        }
        
        // Update in-memory cache
        diskCacheStatus[mediaID] = (exists: diskCacheExists, timestamp: Date())
        
        return diskCacheExists
    }
    
    /// Invalidate disk cache status for a mediaID (call when cache is created or deleted)
    private func invalidateDiskCacheStatus(for mediaID: String) {
        diskCacheStatus.removeValue(forKey: mediaID)
    }
    
    /// Cancel all loading tasks for a tweet only if no cache is available
    @MainActor func cancelLoadingForTweet(_ tweetId: String) {
        // Check if tweet has cached content
        let hasCache = hasCachedContent(for: tweetId)
        
        if hasCache {
            print("DEBUG: [SharedAssetCache] Tweet \(tweetId) has cached content, skipping cancellation")
            return
        }
        
        // Find all mediaIDs associated with this tweet and cancel their loading
        let tweetMediaIDs = getMediaIDsForTweet(tweetId)
        for mediaID in tweetMediaIDs {
            cancelLoading(for: mediaID)
        }
    }
    
    /// Cancel loading tasks for out-of-sight videos (even if cached content exists)
    /// This is used when videos scroll out of view to stop active buffering/downloading
    @MainActor func cancelLoadingForOutOfSightTweet(_ tweetId: String) {
        print("DEBUG: [SharedAssetCache] Cancelling loading for out-of-sight tweet \(tweetId)")
        
        // Find all mediaIDs associated with this tweet and cancel their loading
        // This cancels active loading tasks even if cached content exists
        let tweetMediaIDs = getMediaIDsForTweet(tweetId)
        for mediaID in tweetMediaIDs {
            // Cancel loading tasks regardless of cache status
            if let loadingTask = loadingTasks[mediaID] {
                loadingTask.cancel()
                loadingTasks.removeValue(forKey: mediaID)
                print("DEBUG: [SharedAssetCache] Cancelled loading task for out-of-sight mediaID: \(mediaID)")
            }
            
            // Cancel preload tasks
            if let preloadTask = preloadTasks[mediaID] {
                preloadTask.cancel()
                preloadTasks.removeValue(forKey: mediaID)
                print("DEBUG: [SharedAssetCache] Cancelled preload task for out-of-sight mediaID: \(mediaID)")
            }
            
            // Stop buffering for CachingPlayerItem if it exists
            if let cachingPlayerItem = cachingPlayerItems[mediaID] {
                // Reduce buffer duration to stop aggressive buffering
                cachingPlayerItem.preferredForwardBufferDuration = 0.0
                // Ensure network resources are not used while paused
                cachingPlayerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
                print("DEBUG: [SharedAssetCache] Stopped buffering for out-of-sight CachingPlayerItem: \(mediaID)")
            }
        }
    }
    
    /// Trigger video preloading for a tweet
    /// This works by posting a notification that MediaGridView listens to
    /// MediaGridView will then set shouldLoadVideo=true, causing MediaCell to load the video
    @MainActor func triggerVideoPreloadingForTweet(_ tweetId: String) {
        // Post notification for MediaGridView to handle
        // MediaGridView will enable video loading for this tweet
        NotificationCenter.default.post(
            name: .triggerVideoPreloading,
            object: nil,
            userInfo: ["tweetId": tweetId]
        )
        print("DEBUG: [SharedAssetCache] Posted video preloading notification for tweet \(tweetId)")
    }
    
    /// Extract mediaID from URL
    func extractMediaID(from url: URL) -> String? {
        let urlString = url.absoluteString        
        // Look for IPFS hash pattern (Qm...)
        // IPFS hashes typically start with Qm and are 46 characters long
        if let range = urlString.range(of: "Qm[A-Za-z0-9]{44}") {
            let mediaID = String(urlString[range])
            print("DEBUG: [SHARED ASSET CACHE] Extracted mediaID: \(mediaID)")
            return mediaID
        }
        
        // Also try to extract from /ipfs/ path
        if urlString.contains("/ipfs/") {
            let components = urlString.components(separatedBy: "/ipfs/")
            if components.count > 1 {
                let afterIpfs = components[1]
                // Extract the hash part (before any additional path or query parameters)
                let hashPart = afterIpfs.components(separatedBy: CharacterSet(charactersIn: "/?&")).first ?? afterIpfs
                if hashPart.hasPrefix("Qm") && hashPart.count >= 46 {
                    let mediaID = String(hashPart.prefix(46))
                    print("DEBUG: [SHARED ASSET CACHE] Extracted mediaID from /ipfs/ path: \(mediaID)")
                    return mediaID
                }
            }
        }
        
        print("DEBUG: [SHARED ASSET CACHE] No IPFS hash found in URL: \(urlString)")
        return nil
    }
    
    /// Get cached asset or create new one
    @MainActor func getAsset(for url: URL, tweetId: String? = nil) async throws -> AVAsset {
        guard let mediaID = extractMediaID(from: url) else {
            throw NSError(domain: "SharedAssetCache", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Cannot extract mediaID from URL", comment: "Media ID extraction error")])
        }
        let cacheKey = mediaID
        
        // Track mediaID for tweet if provided
        if let tweetId = tweetId {
            trackMediaID(mediaID, for: tweetId)
        }
        
        // Check if we have a cached asset
        if let cachedAsset = assetCache[cacheKey] {
            cacheTimestamps[cacheKey] = Date() // Update access time
            return cachedAsset
        }
        
        // Check if there's already a loading task
        if let existingTask = loadingTasks[cacheKey] {
            do {
                let asset = try await existingTask.value
                cacheTimestamps[cacheKey] = Date() // Update access time
                return asset
            } catch {
                loadingTasks.removeValue(forKey: cacheKey)
                // Fall through to create new task
            }
        }
        
        // Notify VideoLoadingManager that a load is starting
        VideoLoadingManager.shared.videoLoadStarted()
        
        // Create new loading task
        let task = Task<AVAsset, Error> {
            let resolvedURL = await resolveHLSURL(url)
            
            // Determine if this is HLS or progressive based on resolved URL
            let asset: AVAsset
            if resolvedURL.pathExtension == "m3u8" || resolvedURL.absoluteString.contains("/master.m3u8") || resolvedURL.absoluteString.contains("/playlist.m3u8") {
                // For HLS videos, use CachingPlayerItem which handles LocalHTTPServer
                LocalHTTPServer.shared.start()
                
                let cachingPlayerItem = CachingPlayerItem(hlsURL: resolvedURL, mediaID: mediaID, avUrlAssetOptions: nil)
                asset = cachingPlayerItem.asset
                
                print("DEBUG: [SHARED ASSET CACHE] Created HLS CachingPlayerItem with LocalHTTPServer for mediaID: \(mediaID), URL: \(resolvedURL.absoluteString)")
                
                // Store caching player item to prevent deallocation
                await MainActor.run { 
                    self.cachingPlayerItems[mediaID] = cachingPlayerItem
                }
            } else {
                // For progressive videos, use LocalHTTPServer for IP-independent caching
                LocalHTTPServer.shared.start()
                
                // Register with LocalHTTPServer (handles mediaID-based caching and IP changes)
                let localURL = LocalHTTPServer.shared.registerAndGetURL(for: mediaID, realURL: resolvedURL)
                
                asset = AVURLAsset(url: localURL)
                print("DEBUG: [SHARED ASSET CACHE] Created AVURLAsset with LocalHTTPServer for progressive video")
                print("DEBUG: [SHARED ASSET CACHE]   MediaID: \(mediaID)")
                print("DEBUG: [SHARED ASSET CACHE]   Local URL: \(localURL.absoluteString)")
                print("DEBUG: [SHARED ASSET CACHE]   Real URL: \(resolvedURL.absoluteString)")
            }
            
            // Cache the asset
            await MainActor.run {
                self.assetCache[cacheKey] = asset
                self.cacheTimestamps[cacheKey] = Date()
                self.loadingTasks.removeValue(forKey: cacheKey)
                
                // Save cache metadata to persist across app restarts
                self.saveCacheMetadata()
                
                // Notify VideoLoadingManager that the load completed
                VideoLoadingManager.shared.videoLoadCompleted()
            }
            
            return asset
        }
        
        // Store the task
        loadingTasks[cacheKey] = task
        
        do {
            let asset = try await task.value
            return asset
        } catch {
            loadingTasks.removeValue(forKey: cacheKey)
            // Notify VideoLoadingManager that the load failed
            VideoLoadingManager.shared.videoLoadCompleted()
            throw error
        }
    }
    
    /// Cache a player instance for immediate reuse
    func cachePlayer(_ player: AVPlayer, for mediaID: String) {
        // Remove old player if exists - do this asynchronously to avoid blocking
        if let oldPlayer = playerCache[mediaID] {
            Task.detached {
                oldPlayer.pause()
            }
        }
        
        playerCache[mediaID] = player
        cacheTimestamps[mediaID] = Date()
        
        // Save cache metadata to persist across app restarts
        saveCacheMetadata()
        
        // Manage cache size asynchronously
        Task.detached {
            await MainActor.run {
                self.managePlayerCacheSize()
            }
        }
    }
    
    /// Get cached player if available
    func getCachedPlayer(for mediaID: String) -> AVPlayer? {
        if let player = playerCache[mediaID] {
            // Validate player before returning it
            guard let playerItem = player.currentItem else {
                print("DEBUG: [SHARED ASSET CACHE] Cached player has no currentItem, removing invalid player for mediaID: \(mediaID)")
                removeInvalidPlayer(for: mediaID)
                return nil
            }
            
            if playerItem.status == .failed {
                print("DEBUG: [SHARED ASSET CACHE] Cached player item is in failed state, removing invalid player for mediaID: \(mediaID)")
                removeInvalidPlayer(for: mediaID)
                return nil
            }
            
            // Check if player has buffered data in memory
            let hasBufferedData = !playerItem.loadedTimeRanges.isEmpty
            print("DEBUG: [SHARED ASSET CACHE] Cached player has buffered data: \(hasBufferedData), loadedTimeRanges: \(playerItem.loadedTimeRanges.count)")
            
            // If no buffered data, force preroll to reload from disk cache
            if !hasBufferedData && playerItem.status == .readyToPlay {
                print("DEBUG: [SHARED ASSET CACHE] Cached player has no buffered data - forcing preroll to reload from cache")
                playerItem.preferredForwardBufferDuration = 15.0  // Balanced prefetch
                player.preroll(atRate: 1.0) { success in
                    print("DEBUG: [SHARED ASSET CACHE] Preroll completed for cached player: \(success)")
                }
            }
            
            cacheTimestamps[mediaID] = Date() // Update access time
            return player
        }
        return nil
    }
    
    /// Remove invalid cached player
    func removeInvalidPlayer(for mediaID: String) {
        playerCache.removeValue(forKey: mediaID)
    }
    
    /// Clear asset cache for a specific mediaID
    @MainActor func clearAssetCache(for mediaID: String) {
        assetCache.removeValue(forKey: mediaID)
        cacheTimestamps.removeValue(forKey: mediaID)
        cachingPlayerItems.removeValue(forKey: mediaID)
        resourceLoaderDelegates.removeValue(forKey: mediaID)
        print("DEBUG: [SHARED ASSET CACHE] Cleared asset cache for mediaID: \(mediaID)")
    }
    
    /// Clear player and associated assets for a specific mediaID (for failed players)
    @MainActor func clearPlayerForMediaID(_ mediaID: String) {
        // Pause and remove player
        if let player = playerCache.removeValue(forKey: mediaID) {
            player.pause()
            print("DEBUG: [SHARED ASSET CACHE] Paused and removed player for mediaID: \(mediaID)")
        }
        
        // Clear associated data
        assetCache.removeValue(forKey: mediaID)
        cacheTimestamps.removeValue(forKey: mediaID)
        cachingPlayerDelegates.removeValue(forKey: mediaID)
        cachingPlayerItems.removeValue(forKey: mediaID)
        resourceLoaderDelegates.removeValue(forKey: mediaID)
        
        // CRITICAL: Clear disk cache status so retry doesn't think there's cached content
        diskCacheStatus.removeValue(forKey: mediaID)
        
        // Cancel any pending loading tasks
        if let task = loadingTasks.removeValue(forKey: mediaID) {
            task.cancel()
            print("DEBUG: [SHARED ASSET CACHE] Cancelled loading task for mediaID: \(mediaID)")
        }
        
        print("DEBUG: [SHARED ASSET CACHE] Completely cleared failed player and assets for mediaID: \(mediaID)")
    }
    
    /// Get cached player or create new one with asset
    func getOrCreatePlayer(for url: URL, tweetId: String? = nil, mediaType: MediaType? = nil) async throws -> AVPlayer {
        guard let mediaID = extractMediaID(from: url) else {
            throw NSError(domain: "SharedAssetCache", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Cannot extract mediaID from URL", comment: "Media ID extraction error")])
        }
        
        NSLog("DEBUG: [SHARED ASSET CACHE] getOrCreatePlayer called for URL: \(url.absoluteString), mediaID: \(mediaID), mediaType: \(mediaType?.rawValue ?? "nil")")
        if let tweetId {
            NSLog("DEBUG: [SHARED ASSET CACHE] getOrCreatePlayer received tweetId (ignored for caching): \(tweetId)")
        } else {
            NSLog("DEBUG: [SHARED ASSET CACHE] getOrCreatePlayer called with no tweetId")
        }
        
        // CRITICAL: Cache key must ALWAYS be the mediaID (video attachment mid).
        // tweetId must never affect player caching; it caused incorrect reuse/eviction behavior.
        let cacheKey = mediaID
        NSLog("DEBUG: [SHARED ASSET CACHE] Using cache key (mediaID): \(cacheKey)")
        
        // Try to get cached player first
        if let cachedPlayer = await MainActor.run(body: { getCachedPlayer(for: cacheKey) }) {
            NSLog("DEBUG: [SHARED ASSET CACHE] ✅ Returning cached player for mediaID: \(cacheKey)")
            return cachedPlayer
        }
        
        // CRITICAL: Notify VideoLoadingManager that a load is starting
        await MainActor.run {
            VideoLoadingManager.shared.videoLoadStarted()
        }
        
        // Use MediaType to determine video type if available, otherwise fall back to URL-based detection
        let isHLSVideo: Bool
        if let mediaType = mediaType {
            isHLSVideo = (mediaType == .hls_video)
            NSLog("DEBUG: [SHARED ASSET CACHE] Using MediaType to determine video type - mediaType: \(mediaType.rawValue), isHLSVideo: \(isHLSVideo)")
        } else {
            // Fallback to URL-based detection for backward compatibility
            let urlString = url.absoluteString
            isHLSVideo = urlString.hasSuffix(".m3u8")
            NSLog("DEBUG: [SHARED ASSET CACHE] Using URL-based detection - hasSuffix(.m3u8): \(isHLSVideo)")
        }
        
        if isHLSVideo {
            // Use CachingPlayerItem for HLS videos
            NSLog("DEBUG: [SHARED ASSET CACHE] Using CachingPlayerItem for HLS video: \(url.absoluteString)")
            do {
                let player = try await createCachingPlayer(for: url, tweetId: tweetId)
                // Notify success
                await MainActor.run {
                    VideoLoadingManager.shared.videoLoadCompleted()
                }
                return player
            } catch {
                // Notify failure
                await MainActor.run {
                    VideoLoadingManager.shared.videoLoadCompleted()
                }
                throw error
            }
        } else {
            // For progressive videos, use LocalHTTPServer to proxy and fix Content-Type
            NSLog("DEBUG: [SHARED ASSET CACHE] Creating progressive video player via LocalHTTPServer for \(mediaID)")
            
            // Remove query parameters
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            let cleanURL = components?.url ?? url
            
            // Start LocalHTTPServer
            LocalHTTPServer.shared.start()
            
            // Register real URL and get localhost proxy URL
            let localURL = LocalHTTPServer.shared.registerAndGetURL(for: mediaID, realURL: cleanURL)
            NSLog("🔗 [PROGRESSIVE VIDEO] Original URL: \(url.absoluteString)")
            NSLog("🔗 [PROGRESSIVE VIDEO] LocalHTTPServer proxy URL: \(localURL.absoluteString)")
            NSLog("🔗 [PROGRESSIVE VIDEO] Real URL registered: \(cleanURL.absoluteString)")
            
            // Create AVPlayer with localhost URL (LocalHTTPServer fixes Content-Type)
            let asset = AVURLAsset(url: localURL)
            let playerItem = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: playerItem)
            
            // CRITICAL: Mute player at creation - will be unmuted by mode if needed
            player.isMuted = true
            
            // Optimize buffering for progressive video playback
            player.automaticallyWaitsToMinimizeStalling = false
            playerItem.preferredForwardBufferDuration = 30.0  // Buffer 30 seconds ahead to reduce spinner frequency
            
            // Cache the player
            await MainActor.run { 
                cachePlayer(player, for: mediaID)
                NSLog("DEBUG: [SHARED ASSET CACHE] Cached progressive player with cacheKey (mediaID): \(mediaID)")
                // Notify completion
                VideoLoadingManager.shared.videoLoadCompleted()
            }
            
            return player
        }
    }
    
    /// Create CachingPlayerItem for HLS videos only
    private func createCachingPlayer(for url: URL, tweetId: String?) async throws -> AVPlayer {
        guard let mediaID = extractMediaID(from: url) else {
            throw NSError(domain: "SharedAssetCache", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Cannot extract mediaID from URL", comment: "Media ID extraction error")])
        }
        
        let startTime = Date()
        NSLog("⏱️ [VIDEO LOAD START] Creating CachingPlayerItem for mediaID: \(mediaID)")
        NSLog("DEBUG: [SHARED ASSET CACHE] Creating CachingPlayerItem for HLS video: \(url.absoluteString), mediaID: \(mediaID)")
        
        // Check if we have cached content first to avoid network requests
        let cachedResolvedURL = await checkCachedHLSPlaylist(for: mediaID, baseURL: url)
        
        // Resolve the HLS URL (use cached info if available, otherwise make network requests)
        let resolvedURL: URL
        if let cachedURL = cachedResolvedURL {
            NSLog("DEBUG: [SHARED ASSET CACHE] Using cached HLS URL (no network request needed): \(cachedURL.absoluteString)")
            resolvedURL = cachedURL
        } else {
            NSLog("DEBUG: [SHARED ASSET CACHE] No cached playlist found, resolving HLS URL from network")
            let resolveStart = Date()
            let networkResolvedURL = await resolveHLSURL(url)
            let resolveTime = Date().timeIntervalSince(resolveStart)
            NSLog("⏱️ [HLS RESOLVE] Took \(String(format: "%.2f", resolveTime))s for mediaID: \(mediaID)")
            
            // If network resolution returns the base URL unchanged (resolution failed),
            // try cache check ONE MORE TIME with more relaxed validation
            if networkResolvedURL == url {
                NSLog("⚠️ [HLS FALLBACK] Network resolution failed, retrying cache check for mediaID: \(mediaID)")
                if let fallbackCachedURL = await checkCachedHLSPlaylist(for: mediaID, baseURL: url) {
                    NSLog("✅ [HLS FALLBACK] Found cached playlist on retry: \(fallbackCachedURL.absoluteString)")
                    resolvedURL = fallbackCachedURL
                } else {
                    NSLog("❌ [HLS FALLBACK] Cache check retry also failed for mediaID: \(mediaID)")
                    resolvedURL = networkResolvedURL
                }
            } else {
                NSLog("DEBUG: [SHARED ASSET CACHE] Resolved HLS URL from network: \(networkResolvedURL.absoluteString)")
                resolvedURL = networkResolvedURL
            }
        }
        
        // Start LocalHTTPServer for HLS video serving
        LocalHTTPServer.shared.start()
        
        // Create CachingPlayerItem using HLS initializer (handles LocalHTTPServer internally)
        let cachingPlayerItem = CachingPlayerItem(hlsURL: resolvedURL, mediaID: mediaID, avUrlAssetOptions: nil)
        
        print("DEBUG: [SHARED ASSET CACHE] Created HLS CachingPlayerItem with LocalHTTPServer for mediaID: \(mediaID), URL: \(resolvedURL.absoluteString)")
        
        // Create and store delegate for caching events
        let delegate = CachingPlayerItemDelegateImpl()
        cachingPlayerItem.delegate = delegate
        
        // Store the delegate to prevent deallocation (use mediaID to ignore query params)
        await MainActor.run { 
            cachingPlayerDelegates[mediaID] = delegate
            cachingPlayerItems[mediaID] = cachingPlayerItem
        }
        
        // Create player with CachingPlayerItem
        let player = AVPlayer(playerItem: cachingPlayerItem)
        
        // CRITICAL: Mute player at creation - will be unmuted by mode if needed
        player.isMuted = true
        NSLog("🔇 [PLAYER MUTE] Created player for \(mediaID) - isMuted: true (default)")

        
        // Optimize buffering for HLS playback
        player.automaticallyWaitsToMinimizeStalling = false
        cachingPlayerItem.preferredForwardBufferDuration = 15.0  // Buffer 15 seconds ahead (balanced prefetch)
        cachingPlayerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false  // Don't buffer when paused to avoid connection overload
        
        // Cache the player using mediaID (video attachment mid)
        await MainActor.run { 
            cachePlayer(player, for: mediaID)
            // Invalidate disk cache status since we're creating new cache content
            invalidateDiskCacheStatus(for: mediaID)
        }
        
        // DON'T auto-play here - let the view decide when to play
        // The player is ready, the view will call play() when appropriate
        let totalTime = Date().timeIntervalSince(startTime)
        NSLog("⏱️ [VIDEO LOAD COMPLETE] Total time: \(String(format: "%.2f", totalTime))s for mediaID: \(mediaID)")
        NSLog("DEBUG: [SHARED ASSET CACHE] Player created and cached for mediaID: \(mediaID), ready for playback")
        
        return player
    }
    
    /// Get or create a player item for the given URL and media type
    /// Used by singleton players that want to swap items instead of creating new players
    /// IMPORTANT: Always creates NEW items because AVPlayerItem can only be attached to ONE AVPlayer
    func getOrCreatePlayerItem(for url: URL, mediaID: String, mediaType: MediaType? = nil) async throws -> AVPlayerItem {
        guard let extractedMediaID = extractMediaID(from: url) else {
            throw NSError(domain: "SharedAssetCache", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Cannot extract mediaID from URL", comment: "Media ID extraction error")])
        }
        
        NSLog("DEBUG: [SHARED ASSET CACHE] getOrCreatePlayerItem called for mediaID: \(extractedMediaID) - creating fresh item")
        
        // Determine if this is HLS
        let isHLSVideo: Bool
        if let mediaType = mediaType {
            isHLSVideo = (mediaType == .hls_video)
        } else {
            isHLSVideo = url.absoluteString.hasSuffix(".m3u8")
        }
        
        if isHLSVideo {
            // Create fresh HLS player item for singleton player
            let resolvedURL = await resolveHLSURL(url)
            
            LocalHTTPServer.shared.start()
            let cachingPlayerItem = CachingPlayerItem(hlsURL: resolvedURL, mediaID: extractedMediaID, avUrlAssetOptions: nil)
            
            // Create delegate but DON'T cache it (singleton manages its own lifecycle)
            let delegate = CachingPlayerItemDelegateImpl()
            cachingPlayerItem.delegate = delegate
            
            NSLog("DEBUG: [SHARED ASSET CACHE] Created fresh HLS player item for singleton for mediaID: \(extractedMediaID)")
            return cachingPlayerItem
        } else {
            // Create fresh progressive video player item using LocalHTTPServer for IP-independent caching
            LocalHTTPServer.shared.start()
            
            // Register with LocalHTTPServer (handles mediaID-based caching and IP changes)
            let localURL = LocalHTTPServer.shared.registerAndGetURL(for: extractedMediaID, realURL: url)
            
            let asset = AVURLAsset(url: localURL)
            let playerItem = AVPlayerItem(asset: asset)
            
            NSLog("DEBUG: [SHARED ASSET CACHE] Created fresh progressive player item for singleton with LocalHTTPServer")
            NSLog("DEBUG: [SHARED ASSET CACHE]   MediaID: \(extractedMediaID)")
            NSLog("DEBUG: [SHARED ASSET CACHE]   Local URL: \(localURL.absoluteString)")
            NSLog("DEBUG: [SHARED ASSET CACHE]   Real URL: \(url.absoluteString)")
            return playerItem
        }
    }
    
    
    /// Check if we have cached HLS playlist locally (to avoid network requests for cached videos)
    private func checkCachedHLSPlaylist(for mediaID: String, baseURL: URL) async -> URL? {
        // Get the cache directory for this media
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let mediaCacheDir = cacheDir.appendingPathComponent(mediaID)
        
        // Check if cache directory exists
        guard FileManager.default.fileExists(atPath: mediaCacheDir.path) else {
            NSLog("DEBUG: [SHARED ASSET CACHE] No cache directory found for mediaID: \(mediaID)")
            return nil
        }
        
        // Look for cached playlist files in order of preference
        // Playlists may be in subdirectories like /720p, /480p, etc.
        let possiblePlaylistNames = ["master.m3u8", "_master.m3u8", "playlist.m3u8", "_playlist.m3u8"]
        
        // Search recursively for playlists in subdirectories
        guard let enumerator = FileManager.default.enumerator(
            at: mediaCacheDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            NSLog("DEBUG: [SHARED ASSET CACHE] Failed to create enumerator for \(mediaCacheDir.path)")
            return nil
        }
        
        // Collect all valid playlists found
        var foundPlaylists: [(url: URL, name: String)] = []
        
        while let fileURL = enumerator.nextObject() as? URL {
            let fileName = fileURL.lastPathComponent
            
            if possiblePlaylistNames.contains(fileName) {
                // Validate that the cached playlist is not empty and contains valid content
                if let data = try? Data(contentsOf: fileURL),
                   let playlistString = String(data: data, encoding: .utf8) {
                    
                    // More lenient validation - just check for #EXTM3U header
                    // Don't require .ts or .m3u8 in content since some playlists might use different formats
                    if playlistString.contains("#EXTM3U") {
                        foundPlaylists.append((url: fileURL, name: fileName))
                        NSLog("DEBUG: [SHARED ASSET CACHE] Found valid cached playlist: \(fileName), size: \(data.count) bytes")
                    } else {
                        NSLog("DEBUG: [SHARED ASSET CACHE] Found playlist file but missing #EXTM3U: \(fileName)")
                    }
                } else {
                    NSLog("DEBUG: [SHARED ASSET CACHE] Found playlist file but failed to read: \(fileName)")
                }
            }
        }
        
        // Return the highest priority playlist found
        for playlistName in possiblePlaylistNames {
            if let found = foundPlaylists.first(where: { $0.name == playlistName }) {
                // Remove underscore prefix from filename only (e.g., _master.m3u8 -> master.m3u8)
                let cachedFileName = found.url.lastPathComponent
                let fileName = cachedFileName.hasPrefix("_") ? String(cachedFileName.dropFirst()) : cachedFileName
                
                // baseURL already contains the full path including mediaID (e.g., http://.../ipfs/QmHash)
                // We just need to append the filename directly
                let reconstructedURL = baseURL.appendingPathComponent(fileName)
                
                NSLog("DEBUG: [SHARED ASSET CACHE] ✅ Found cached playlist (NO NETWORK): \(found.url.path)")
                NSLog("DEBUG: [SHARED ASSET CACHE] Reconstructed URL: \(reconstructedURL.absoluteString)")
                return reconstructedURL
            }
        }
        
        NSLog("DEBUG: [SHARED ASSET CACHE] No valid cached playlist found for mediaID: \(mediaID), searched playlists: \(foundPlaylists.map { $0.name })")
        return nil
    }
    
    /// Resolve HLS URL with specific fallback strategy
    /// Sequential approach: tries master.m3u8 first, then playlist.m3u8 only if master fails
    /// Does NOT try them simultaneously
    private func resolveHLSURL(_ url: URL) async -> URL {
        let urlString = url.absoluteString
        
        // If already an m3u8 file, return as-is
        if urlString.hasSuffix(".m3u8") {
            return url
        }
        
        // If it's a progressive video (mp4), return as-is - no HLS resolution needed
        if urlString.hasSuffix(".mp4") {
            return url
        }
        
        // HLS fallback strategy: master.m3u8 -> playlist.m3u8 (sequential, not simultaneous)
        let masterURL = url.appendingPathComponent("master.m3u8")
        let playlistURL = url.appendingPathComponent("playlist.m3u8")
        
        print("DEBUG: [SharedAssetCache] Resolving HLS URL: \(url.absoluteString)")
        
        // Step 1: Try master.m3u8 first (wait for completion before proceeding)
        print("DEBUG: [SharedAssetCache] Checking master.m3u8...")
        if await urlExists(masterURL, timeout: 15.0) {
            print("DEBUG: [SharedAssetCache] Found master.m3u8 at: \(masterURL.absoluteString)")
            return masterURL
        }
        
        // Step 2: Only if master.m3u8 failed, try playlist.m3u8 (sequential, not simultaneous)
        print("DEBUG: [SharedAssetCache] master.m3u8 not found, trying playlist.m3u8...")
        if await urlExists(playlistURL, timeout: 15.0) {
            print("DEBUG: [SharedAssetCache] Found playlist.m3u8 at: \(playlistURL.absoluteString)")
            return playlistURL
        }
        
        // If both fail, return original URL and let it fail
        print("DEBUG: [SharedAssetCache] HLS resolution failed - neither master.m3u8 nor playlist.m3u8 found for: \(url.absoluteString)")
        return url
    }
    
    /// Check if URL exists with configurable timeout
    private func urlExists(_ url: URL, timeout: TimeInterval = 15.0) async -> Bool {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = timeout
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
    
    /// Clear cache
    /// Clear all caches (manual cleanup, signout, or emergency)
    @MainActor func clearAllCaches() {
        print("DEBUG: [SharedAssetCache] Clearing all caches")
        
        // Pause and remove all cached players
        for (_, player) in playerCache {
            player.pause()
        }
        playerCache.removeAll()
        cachingPlayerDelegates.removeAll()
        cachingPlayerItems.removeAll()
        resourceLoaderDelegates.removeAll()
        
        // Clear asset cache
        assetCache.removeAll()
        
        // Clear loading tasks
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll()
        
        // Clear preload tasks
        preloadTasks.values.forEach { $0.cancel() }
        preloadTasks.removeAll()
        
        // Clear timestamps
        cacheTimestamps.removeAll()
        
        // Clear URL tracking
        tweetUrlMapping.removeAll()
        
        // Clear disk cache status
        diskCacheStatus.removeAll()
        
        // Clear disk cache using the cleanup manager
        DiskCacheCleanupManager.shared.clearAllCache()
        
        print("DEBUG: [SharedAssetCache] All caches cleared")
    }
    
    /// Cancel all active loading tasks to free memory immediately
    @MainActor func cancelAllLoadingTasks() {
        let taskCount = loadingTasks.count + preloadTasks.count
        
        if taskCount > 0 {
            print("⚠️ [SharedAssetCache] EMERGENCY: Cancelling \(taskCount) active downloads to prevent crash")
        }
        
        // Cancel all asset loading tasks
        for (key, task) in loadingTasks {
            task.cancel()
            print("🚫 [SharedAssetCache] Cancelled loading task: \(key)")
        }
        loadingTasks.removeAll()
        
        // Cancel all preload tasks
        for (_, task) in preloadTasks {
            task.cancel()
        }
        preloadTasks.removeAll()
        
        print("DEBUG: [SharedAssetCache] All loading tasks cancelled")
    }
    
    /// Release a percentage of cache to free memory (preserves current playing videos)
    @MainActor func releasePartialCache(percentage: Int) {
        let percentageToRemove = max(1, min(percentage, 90)) // Ensure 1-90% range
        print("DEBUG: [SharedAssetCache] Releasing \(percentageToRemove)% of cache")
        
        // Calculate how many items to remove
        let assetCountToRemove = max(1, (assetCache.count * percentageToRemove) / 100)
        let playerCountToRemove = max(1, (playerCache.count * percentageToRemove) / 100)
        
        // Remove oldest assets first (LRU strategy)
        let sortedAssetKeys = cacheTimestamps.sorted { $0.value < $1.value }.map { $0.key }
        let assetsToRemove = sortedAssetKeys.prefix(assetCountToRemove)
        
        for key in assetsToRemove {
            assetCache.removeValue(forKey: key)
            cacheTimestamps.removeValue(forKey: key)
        }
        
        // Remove oldest players first (LRU strategy)
        let sortedPlayerKeys = cacheTimestamps.sorted { $0.value < $1.value }.map { $0.key }
        let playersToRemove = sortedPlayerKeys.prefix(playerCountToRemove)
        
        for key in playersToRemove {
            if let player = playerCache[key] {
                player.pause()
                playerCache.removeValue(forKey: key)
            }
        }
        
        print("DEBUG: [SharedAssetCache] Released \(assetsToRemove.count) assets and \(playersToRemove.count) players")
    }
    
    // MARK: - Enhanced Preloading Methods
    
    /// Preload video for immediate display (high priority)
    func preloadVideo(for url: URL, tweetId: String? = nil) {
        // Use mediaID as cache key (stable identifier), not URL which can change
        guard let mediaID = extractMediaID(from: url) else { return }
        let cacheKey = mediaID
        
        // Cancel existing preload task if any
        preloadTasks[cacheKey]?.cancel()
        
        let task = Task {
            do {
                _ = try await getOrCreatePlayer(for: url)
            } catch {
                // Handle error silently
            }
        }
        
        preloadTasks[cacheKey] = task
    }
    
    /// Preload asset only (for background loading - lower priority)
    func preloadAsset(for url: URL, tweetId: String? = nil) {
        // Use mediaID as cache key (stable identifier), not URL which can change
        guard let mediaID = extractMediaID(from: url) else { return }
        let cacheKey = mediaID
        
        // Cancel existing preload task if any
        preloadTasks[cacheKey]?.cancel()
        
        let task = Task {
            do {
                _ = try await getAsset(for: url, tweetId: tweetId)
            } catch {
                // Handle error silently
            }
        }
        
        preloadTasks[cacheKey] = task
    }
    
    /// Cancel preload for specific URL
    func cancelPreload(for url: URL) {
        // Use mediaID as cache key (stable identifier), not URL which can change
        guard let mediaID = extractMediaID(from: url) else { return }
        preloadTasks[mediaID]?.cancel()
        preloadTasks.removeValue(forKey: mediaID)
    }
    
    /// Preload multiple videos with priority management
    func preloadVideos(_ urls: [URL], priority: PreloadPriority = .normal) {
        for (index, url) in urls.enumerated() {
            let delay = priority.delay(for: index)
            
            Task {
                // Preload immediately if delay is 0, otherwise use async timing
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                
                guard !Task.isCancelled else { return }
                
                switch priority {
                case .high:
                    await MainActor.run {
                        preloadVideo(for: url)
                    }
                case .normal, .low:
                    await MainActor.run {
                        preloadAsset(for: url)
                    }
                }
            }
        }
    }
    
    // MARK: - Cache Management
    
    private func manageCacheSize() {
        if assetCache.count > maxCacheSize {
            // Remove least recently used assets - do sorting on background thread
            Task.detached {
                let sortedKeys = await MainActor.run {
                    self.cacheTimestamps.sorted { $0.value < $1.value }.map { $0.key }
                }
                let keysToRemove = sortedKeys.prefix(await MainActor.run { self.assetCache.count - self.maxCacheSize })
                
                await MainActor.run {
                    for key in keysToRemove {
                        self.assetCache.removeValue(forKey: key)
                        self.cacheTimestamps.removeValue(forKey: key)
                        self.cachingPlayerItems.removeValue(forKey: key)
                        self.resourceLoaderDelegates.removeValue(forKey: key)
                    }
                }
            }
        }
    }
    
    private func managePlayerCacheSize() {
        // PERFORMANCE FIX: More aggressive player cleanup
        if playerCache.count > maxPlayerCacheSize {
            // Remove least recently used players
            let sortedKeys = cacheTimestamps.sorted { $0.value < $1.value }.map { $0.key }
            let keysToRemove = sortedKeys.prefix(playerCache.count - maxPlayerCacheSize)
            
            for key in keysToRemove {
                if let player = playerCache[key] {
                    // Pause and clear player item immediately
                    player.pause()
                    player.replaceCurrentItem(with: nil)
                    print("DEBUG: [SharedAssetCache] Removed LRU player: \(key)")
                }
                playerCache.removeValue(forKey: key)
                cacheTimestamps.removeValue(forKey: key)
                cachingPlayerItems.removeValue(forKey: key)
                resourceLoaderDelegates.removeValue(forKey: key)
            }
            
            if !keysToRemove.isEmpty {
                print("DEBUG: [SharedAssetCache] Cleaned up \(keysToRemove.count) players (cache size: \(playerCache.count))")
            }
        }
        
        // PERFORMANCE FIX: Also remove players not accessed in last 5 minutes
        let now = Date()
        let inactiveThreshold: TimeInterval = 300 // 5 minutes
        let inactiveKeys = cacheTimestamps.filter { now.timeIntervalSince($0.value) > inactiveThreshold }.map { $0.key }
        
        if !inactiveKeys.isEmpty {
            for key in inactiveKeys {
                if let player = playerCache[key] {
                    player.pause()
                    player.replaceCurrentItem(with: nil)
                }
                playerCache.removeValue(forKey: key)
                cacheTimestamps.removeValue(forKey: key)
                cachingPlayerItems.removeValue(forKey: key)
                resourceLoaderDelegates.removeValue(forKey: key)
            }
            print("DEBUG: [SharedAssetCache] Removed \(inactiveKeys.count) inactive players (>5min old)")
        }
    }
    
    /// Get cache statistics
    @MainActor func getCacheStats() -> (assetCount: Int, playerCount: Int) {
        return (assetCache.count, playerCache.count)
    }
    
    /// Get current memory usage in bytes using phys_footprint (matches Xcode's memory gauge)
    private func getCurrentMemoryUsage() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / mach_msg_type_number_t(MemoryLayout<natural_t>.size)
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_,
                         task_flavor_t(TASK_VM_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            // phys_footprint is the actual physical memory used by the app
            // This matches what Xcode shows in the memory debugger
            return UInt64(info.phys_footprint)
        } else {
            return 0
        }
    }
    
    /// Proactive memory pressure check - runs every 10 seconds
    private func checkMemoryPressure() {
        let memoryUsage = getCurrentMemoryUsage()
        let memoryUsageMB = memoryUsage / (1024 * 1024)
        
        // Log memory usage for monitoring
        if memoryUsageMB > 500 { // Log when memory exceeds 500MB
            print("DEBUG: [SharedAssetCache] Proactive memory check - current usage: \(memoryUsageMB)MB")
        }
        
        // Take action if memory exceeds 800MB (more aggressive than 1GB)
        if memoryUsageMB > 800 {
            print("DEBUG: [SharedAssetCache] Proactive memory cleanup triggered at \(memoryUsageMB)MB")
            handleMemoryWarning()
        }
    }
    
    // MARK: - Memory Warning Handling
    
    private func setupMemoryWarningNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                print("DEBUG: [SharedAssetCache] System memory warning received")
                self?.handleMemoryWarning()
            }
        }
    }
    
    private func handleMemoryWarning() {
        // CRITICAL: Check if video upload is in progress
        // During FFmpeg video conversion, memory spikes are expected
        // Clearing video player caches during upload breaks existing players
        if UploadProgressManager.shared.isProcessingVideo {
            print("⚠️ [SharedAssetCache] Video upload in progress - SKIPPING video cache cleanup to prevent player breakage")
            print("ℹ️ [SharedAssetCache] Memory spike during FFmpeg conversion is temporary and expected")
            
            // Don't cancel downloads or clear caches during upload
            // The memory spike will subside after FFmpeg completes
            return
        }
        
        // Check if memory usage exceeds 1.4GB before taking action
        let memoryUsage = getCurrentMemoryUsage()
        let memoryUsageMB = memoryUsage / (1024 * 1024)
        
        print("DEBUG: [SharedAssetCache] Memory warning - current usage: \(memoryUsageMB)MB")
        
        // Only release cache if memory usage exceeds 1.4GB (preventive cleanup threshold)
        if memoryUsageMB > 1400 {
            print("DEBUG: [SharedAssetCache] Memory usage exceeds 1.4GB, releasing 30% of cache")
            
            // CRITICAL: Cancel active downloads to prevent memory from growing further
            cancelAllLoadingTasks()
            
            // Release 30% of cache (less aggressive)
            releasePartialCache(percentage: 30)
        } else {
            print("DEBUG: [SharedAssetCache] Memory usage under 1.4GB, no action needed")
        }
        
        // Don't clear URL mapping - preserve user's browsing context
    }
    
    // MARK: - App Lifecycle Handling
    
    private func setupAppLifecycleNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppWillEnterForeground()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppDidBecomeActive()
            }
        }
    }
    
    deinit {
        // Invalidate timers
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        memoryMonitorTimer?.invalidate()
        memoryMonitorTimer = nil
        
        // Cancel all loading tasks
        for (_, task) in loadingTasks {
            task.cancel()
        }
        loadingTasks.removeAll()
        
        // Cancel all preload tasks
        for (_, task) in preloadTasks {
            task.cancel()
        }
        preloadTasks.removeAll()
        
        // Pause and clean up all cached players
        for (_, player) in playerCache {
            player.pause()
        }
        playerCache.removeAll()
        
        // Clear all caches
        assetCache.removeAll()
        cacheTimestamps.removeAll()
        
        // Remove NotificationCenter observers
        NotificationCenter.default.removeObserver(self)
    }
    
    private func handleAppWillEnterForeground() {
        // DON'T refresh players automatically - AppDelegate handles recovery strategy
        // For short backgrounds, players are kept intact (no refresh needed)
        // For long backgrounds, players are cleared and recreated (no refresh needed)
        print("DEBUG: [SharedAssetCache] App entering foreground - skipping auto-refresh (handled by AppDelegate)")
    }
    
    private func handleAppDidBecomeActive() {
        // DON'T refresh players automatically - AppDelegate handles recovery strategy
        print("DEBUG: [SharedAssetCache] App became active - skipping auto-refresh (handled by AppDelegate)")
    }
    
    /// Gentle refresh for short backgrounds - keep players intact, just refresh video layers
    /// This is called when app returns from SHORT background (< 5 minutes)
    /// iOS hasn't invalidated the video layers yet, so we can keep everything and avoid black screens
    func refreshVideoLayersForShortBackground() {
        print("DEBUG: [SharedAssetCache] Refreshing video layers for short background (keeping players intact)")
        
        // For short backgrounds, we keep players/assets but refresh their state
        // The connection pool reset in LocalHTTPServer is usually enough
        // But we need to verify players are still healthy
        
        var unhealthyPlayers = 0
        for (cid, player) in playerCache {
            if let item = player.currentItem {
                // Check if player is in failed state
                if item.status == .failed {
                    print("DEBUG: [SharedAssetCache] Found unhealthy player for \(cid), status: failed")
                    unhealthyPlayers += 1
                }
            } else {
                print("DEBUG: [SharedAssetCache] Found player with nil currentItem for \(cid)")
                unhealthyPlayers += 1
            }
        }
        
        if unhealthyPlayers > 0 {
            print("⚠️ [SharedAssetCache] Short background found \(unhealthyPlayers) unhealthy players - they will be recreated by notification")
        }
        
        NSLog("DEBUG: [SharedAssetCache] Short background refresh complete - kept \(playerCache.count) players (\(unhealthyPlayers) unhealthy), \(assetCache.count) assets intact")
    }
    
    /// Clear video players for background recovery after long background periods
    /// This is called when app returns from extended background (>5 minutes)
    func clearVideoPlayersForBackgroundRecovery() {
        print("DEBUG: [SharedAssetCache] Clearing video players for LONG background recovery")
        
        // Count before
        let playerCountBefore = playerCache.count
        let assetCountBefore = assetCache.count
        
        // Clear all cached players - they may have invalid video layers
        // Players will be recreated on demand with fresh video layers
        for (_, player) in playerCache {
            player.pause()
            player.replaceCurrentItem(with: nil) // CRITICAL: Detach the item to invalidate layer
        }
        playerCache.removeAll()
        
        // Clear CachingPlayerItem instances - they hold references to old players
        cachingPlayerItems.removeAll()
        
        // CRITICAL: Also clear assets - they can have stale video layers after backgrounding
        assetCache.removeAll()
        
        // Clear loading tasks to force fresh loads
        loadingTasks.removeAll()
        preloadTasks.removeAll()
        
        // CRITICAL: Clear disk cache status so videos will reload fresh from network
        diskCacheStatus.removeAll()
        
        // Keep resourceLoaderDelegates - they're needed for HLS playback
        // Keep cacheTimestamps - they track cache expiration
        // Keep HLS disk cache - playlists now use relative paths (port-independent!)
        
        NSLog("DEBUG: [SharedAssetCache] Long background recovery - cleared \(playerCountBefore) players, \(assetCountBefore) assets, disk cache status (HLS cache kept - port-independent)")
    }
    
    // MARK: - Cache Persistence Methods
    
    /// Restore cache metadata from UserDefaults on app startup
    private func restoreCacheFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: cacheMetadataKey),
              let metadata = try? JSONDecoder().decode(CacheMetadata.self, from: data) else {
            print("DEBUG: [SHARED ASSET CACHE] No cache metadata found, starting fresh")
            return
        }
        
        print("DEBUG: [SHARED ASSET CACHE] Restoring cache metadata for \(metadata.cachedMediaIDs.count) mediaIDs")
        
        // Since we're using on-demand caching, we don't need to validate existing cache files
        // Just restore the metadata for reference
        let validMediaIDs = metadata.cachedMediaIDs
        
        cacheTimestamps = validMediaIDs
        print("DEBUG: [SHARED ASSET CACHE] Restored \(validMediaIDs.count) valid cached entries")
    }
    
    /// Save cache metadata to UserDefaults
    private func saveCacheMetadata() {
        let metadata = CacheMetadata(cachedMediaIDs: cacheTimestamps)
        if let data = try? JSONEncoder().encode(metadata) {
            UserDefaults.standard.set(data, forKey: cacheMetadataKey)
        }
    }
    
    
    private func refreshCachedPlayers() {
        print("DEBUG: [SharedAssetCache] Refreshing \(playerCache.count) cached players")
        
        var validPlayers = 0
        var invalidPlayers = 0
        
        // Validate and refresh all cached players
        for (mediaID, player) in playerCache {
            // Check if player item is still valid
            guard let playerItem = player.currentItem else {
                print("DEBUG: [SharedAssetCache] Player \(mediaID) has no currentItem, marking for removal")
                invalidPlayers += 1
                continue
            }
            
            if playerItem.status == .failed {
                print("DEBUG: [SharedAssetCache] Player \(mediaID) is in failed state, marking for removal")
                invalidPlayers += 1
                continue
            }
            
            // Player is valid, refresh its video layer
            validPlayers += 1
            
            // Force a seek to refresh the video layer and ensure buffering
            let currentTime = player.currentTime()
            player.seek(to: currentTime) { finished in
                if finished {
                    // Trigger preroll to ensure video is ready to play
                    player.preroll(atRate: 1.0) { success in
                        if success {
                            print("DEBUG: [SharedAssetCache] Player \(mediaID) refreshed and prerolled successfully")
                        }
                    }
                }
            }
        }
        
        print("DEBUG: [SharedAssetCache] Player refresh complete - valid: \(validPlayers), invalid: \(invalidPlayers)")
        
        // Clean up invalid players after iteration
        if invalidPlayers > 0 {
            Task { @MainActor in
                // Remove invalid players in a separate task to avoid mutation during iteration
                let invalidMediaIDs = self.playerCache.filter { (_, player) in
                    guard let item = player.currentItem else { return true }
                    return item.status == .failed
                }.map { $0.key }
                
                for mediaID in invalidMediaIDs {
                    self.removeInvalidPlayer(for: mediaID)
                }
                
                print("DEBUG: [SharedAssetCache] Removed \(invalidMediaIDs.count) invalid players")
            }
        }
    }
}

// MARK: - Preload Priority

enum PreloadPriority {
    case high
    case normal
    case low
    
    func delay(for index: Int) -> TimeInterval {
        switch self {
        case .high:
            return 0 // No delay for high priority
        case .normal:
            return Double(index) * 0.1 // 0.1 second delay per item
        case .low:
            return Double(index) * 0.3 // 0.3 second delay per item
        }
    }
}
