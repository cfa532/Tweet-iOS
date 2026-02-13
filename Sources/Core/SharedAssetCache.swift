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
    
    // CRITICAL: Track visible videos to prevent their players from being removed
    private var visibleVideoMids: Set<String> = []

    // Track app foreground state — when foreground, protect visible + nearby videos from eviction
    private var isAppInForeground: Bool = true
    
    // MARK: - CachingPlayerItem Delegate
    private class CachingPlayerItemDelegateImpl: NSObject, CachingPlayerItemDelegate {
        func playerItem(_ playerItem: CachingPlayerItem, didFinishDownloadingFileAt filePath: String) {
        }
        
        func playerItem(_ playerItem: CachingPlayerItem, didDownloadBytesSoFar bytesDownloaded: Int, outOf bytesExpected: Int) {
            _ = bytesExpected > 0 ? Double(bytesDownloaded) / Double(bytesExpected) * 100 : 0
        }
        
        func playerItem(_ playerItem: CachingPlayerItem, downloadingFailedWith error: Error) {
        }
        
        func playerItemReadyToPlay(_ playerItem: CachingPlayerItem) {
        }
        
        func playerItemDidFailToPlay(_ playerItem: CachingPlayerItem, withError error: Error?) {
        }
        
        func playerItemPlaybackStalled(_ playerItem: CachingPlayerItem) {
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
    
    // MARK: - Retry Management (ID-based to avoid memory leaks)
    private var videoRetryCount: [String: Int] = [:] // mediaID -> retry count
    private var scheduledVideoRetries: [String: Task<Void, Never>] = [:] // mediaID -> retry task

    // MARK: - Network Failure Tracking
    private var consecutiveNetworkFailures: Int = 0
    private let maxConsecutiveFailures = 3 // Trigger cleanup after 3 consecutive failures

    // MARK: - Disk Cache Status Cache (to avoid repeated disk I/O)
    private var diskCacheStatus: [String: (exists: Bool, timestamp: Date)] = [:] // mediaID -> (cache exists, check timestamp)
    private let diskCacheStatusTTL: TimeInterval = 60 // Cache disk status for 60 seconds
    
    // MARK: - Configuration
    private let maxCacheSize = Constants.MAX_ASSET_CACHE_SIZE
    private let maxPlayerCacheSize = Constants.MAX_PLAYER_CACHE_SIZE
    private let maxConcurrentCreations = Constants.MAX_CONCURRENT_PLAYER_CREATIONS
    private let cacheExpirationInterval: TimeInterval = Constants.CACHE_EXPIRATION_SECONDS
    
    // MARK: - Player Creation Throttling
    private var activeCreations = 0
    private var pendingCreations: [(url: URL, tweetId: String?, mediaType: MediaType?, continuation: CheckedContinuation<AVPlayer, Error>)] = []
    
    // MARK: - Cache Persistence
    private let cacheMetadataKey = "SharedAssetCache_Metadata"
    
    // MARK: - Background Cleanup
    private var cleanupTimer: Timer?
    private var memoryMonitorTimer: Timer?
    
    private func startBackgroundCleanup() {
        // BALANCED CLEANUP: 10s interval - frequent enough to prevent memory buildup but not disruptive
        // MEMORY LEAK FIX: Use [weak self] to prevent timer from keeping SharedAssetCache alive forever
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.performCleanup()
            }
        }
    }
    
    private func startMemoryMonitoring() {
        // PERFORMANCE FIX: Monitor memory every 30 seconds (reduced from 15s for better responsiveness)
        // MEMORY LEAK FIX: Use [weak self] to prevent timer from keeping SharedAssetCache alive forever
        memoryMonitorTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.checkMemoryPressure()
            }
        }
    }
    
    private func performCleanup() {
        let now = Date()
        // CRITICAL: Never evict visible or near-visible videos while app is in foreground
        let protected = foregroundProtectedMids
        let expiredKeys = cacheTimestamps.filter { !protected.contains($0.key) && now.timeIntervalSince($0.value) > cacheExpirationInterval }.map { $0.key }
        
        for key in expiredKeys {
            // CRITICAL: Properly release player using releasePlayer() method
            // This does complete cleanup: stops buffering, cancels loading, removes observers
            if let player = playerCache[key] {
                releasePlayer(player)
            }
            
            assetCache.removeValue(forKey: key)
            playerCache.removeValue(forKey: key)
            cacheTimestamps.removeValue(forKey: key)
            cachingPlayerItems.removeValue(forKey: key)
            resourceLoaderDelegates.removeValue(forKey: key)
            
            // PERFORMANCE FIX: Clean up tweet URL mappings for evicted assets
            cleanupTweetMappings(for: key)
        }
        
        // Manage cache size
        manageCacheSize()
        
        // PERFORMANCE FIX: Also trigger player cache size management
        managePlayerCacheSize()
        
        // PERFORMANCE FIX: Clean up expired disk cache status entries
        cleanupExpiredDiskCacheStatus()
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
            } else {
            }
        }
        
        // Cancel preload task if exists and no cache is available
        if let preloadTask = preloadTasks[mediaID] {
            if !hasCachedAsset && !hasCachedPlayer {
                preloadTask.cancel()
                preloadTasks.removeValue(forKey: mediaID)
            } else {
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
                    diskCacheExists = true
                }
            } catch {
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
    
    /// PERFORMANCE FIX: Clean up expired disk cache status entries to prevent unbounded growth
    private func cleanupExpiredDiskCacheStatus() {
        let now = Date()
        let expiredKeys = diskCacheStatus.filter { 
            now.timeIntervalSince($0.value.timestamp) > diskCacheStatusTTL 
        }.map { $0.key }
        
        for key in expiredKeys {
            diskCacheStatus.removeValue(forKey: key)
        }
    }
    
    /// PERFORMANCE FIX: Clean up tweet URL mappings for a specific mediaID
    private func cleanupTweetMappings(for mediaID: String) {
        // Find and remove the mediaID from all tweet mappings
        var tweetsToClean: [String] = []
        for (tweetId, mediaIds) in tweetUrlMapping {
            if mediaIds.contains(mediaID) {
                tweetsToClean.append(tweetId)
            }
        }
        
        for tweetId in tweetsToClean {
            tweetUrlMapping[tweetId]?.remove(mediaID)
            if tweetUrlMapping[tweetId]?.isEmpty == true {
                tweetUrlMapping.removeValue(forKey: tweetId)
            }
        }
    }
    
    /// Cancel all loading tasks for a tweet only if no cache is available
    @MainActor func cancelLoadingForTweet(_ tweetId: String) {
        // Check if tweet has cached content
        let hasCache = hasCachedContent(for: tweetId)
        
        if hasCache {
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
        
        // Find all mediaIDs associated with this tweet and cancel their loading
        // This cancels active loading tasks even if cached content exists
        let tweetMediaIDs = getMediaIDsForTweet(tweetId)
        for mediaID in tweetMediaIDs {
            // Cancel loading tasks regardless of cache status
            if let loadingTask = loadingTasks[mediaID] {
                loadingTask.cancel()
                loadingTasks.removeValue(forKey: mediaID)
            }
            
            // Cancel preload tasks
            if let preloadTask = preloadTasks[mediaID] {
                preloadTask.cancel()
                preloadTasks.removeValue(forKey: mediaID)
            }
            
            // Stop buffering for CachingPlayerItem if it exists
            if let cachingPlayerItem = cachingPlayerItems[mediaID] {
                // Reduce buffer duration to stop aggressive buffering
                cachingPlayerItem.preferredForwardBufferDuration = 0.0
                // Ensure network resources are not used while paused
                cachingPlayerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
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
    }
    
    /// Extract mediaID from URL
    func extractMediaID(from url: URL) -> String? {
        let urlString = url.absoluteString        
        // Look for IPFS hash pattern (Qm...)
        // IPFS hashes typically start with Qm and are 46 characters long
        if let range = urlString.range(of: "Qm[A-Za-z0-9]{44}") {
            let mediaID = String(urlString[range])
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
                    return mediaID
                }
            }
        }
        
        return nil
    }
    
    /// Get cached asset or create new one
    @MainActor func getAsset(for url: URL, tweetId: String? = nil, mediaType: MediaType? = nil) async throws -> AVAsset {
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
            // Check cancellation before starting
            try Task.checkCancellation()
            
            // Determine if this is HLS based on MediaType
            let isHLSVideo: Bool
            if let mediaType = mediaType {
                isHLSVideo = (mediaType == .hls_video)
            } else {
                // Fallback: check URL if MediaType not provided
                isHLSVideo = url.absoluteString.hasSuffix(".m3u8")
            }
            
            let asset: AVAsset
            if isHLSVideo {
                // Check cancellation before HLS resolution
                try Task.checkCancellation()
                
                // Resolve HLS URL (master.m3u8 or playlist.m3u8)
                let resolvedURL = await resolveHLSURL(url)
                
                // Check cancellation after async operation
                try Task.checkCancellation()
                
                // For HLS videos, use CachingPlayerItem which handles LocalHTTPServer
                LocalHTTPServer.shared.start()
                
                let cachingPlayerItem = CachingPlayerItem(hlsURL: resolvedURL, mediaID: mediaID, avUrlAssetOptions: nil)
                asset = cachingPlayerItem.asset
                
                // Check cancellation before storing
                try Task.checkCancellation()
                
                // Store caching player item to prevent deallocation
                await MainActor.run {
                    // Check cancellation on main actor
                    guard !Task.isCancelled else { return }
                    self.cachingPlayerItems[mediaID] = cachingPlayerItem
                }
            } else {
                // Check cancellation before progressive video setup
                try Task.checkCancellation()
                
                // For progressive videos, use LocalHTTPServer for IP-independent caching
                LocalHTTPServer.shared.start()
                
                // Remove query parameters for cleaner URL
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.query = nil
                let cleanURL = components?.url ?? url
                
                // Register with LocalHTTPServer (handles mediaID-based caching and IP changes)
                let localURL = LocalHTTPServer.shared.registerAndGetURL(for: mediaID, realURL: cleanURL)
                
                // Check cancellation before creating asset
                try Task.checkCancellation()
                
                asset = AVURLAsset(url: localURL)
            }
            
            // Check cancellation before caching
            try Task.checkCancellation()
            
            // Cache the asset
            await MainActor.run {
                // Check cancellation on main actor - don't cache if cancelled
                guard !Task.isCancelled else {
                    // Clean up task tracking if cancelled
                    self.loadingTasks.removeValue(forKey: cacheKey)
                    return
                }
                
                self.assetCache[cacheKey] = asset
                self.cacheTimestamps[cacheKey] = Date()
                self.loadingTasks.removeValue(forKey: cacheKey)

                // Reset network failure counter on successful load
                self.consecutiveNetworkFailures = 0

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
            // ✅ CRITICAL MEMORY FIX: Remove completed task to prevent memory leak
            loadingTasks.removeValue(forKey: cacheKey)
            return asset
        } catch {
            // ✅ CRITICAL MEMORY FIX: Remove failed task to prevent memory leak
            loadingTasks.removeValue(forKey: cacheKey)

            // Only notify failure if not cancelled (cancellation is normal cleanup)
            if !(error is CancellationError) {
                // Track consecutive network failures
                consecutiveNetworkFailures += 1
                print("DEBUG: [SharedAssetCache] Network failure count: \(consecutiveNetworkFailures)/\(maxConsecutiveFailures)")

                // Trigger emergency cleanup if too many consecutive failures
                if consecutiveNetworkFailures >= maxConsecutiveFailures {
                    print("DEBUG: [SharedAssetCache] Too many consecutive network failures, triggering cleanup")
                    handleNetworkFailureCleanup()
                    consecutiveNetworkFailures = 0 // Reset counter after cleanup
                }

                // Notify VideoLoadingManager that the load failed
                VideoLoadingManager.shared.videoLoadCompleted()
            }

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
    
    /// Check if a player is in a healthy, usable state
    /// Returns true only if player is fully functional and ready to play
    private func isPlayerHealthy(_ player: AVPlayer, for mediaID: String) -> Bool {
        // Check 1: Player must have a current item
        guard let playerItem = player.currentItem else {
            print("⚠️ [PLAYER HEALTH] Player \(mediaID.prefix(8)) has no current item")
            return false
        }

        // Check 2: Player item must not be in failed state
        if playerItem.status == .failed {
            print("⚠️ [PLAYER HEALTH] Player \(mediaID.prefix(8)) item status is .failed (error: \(playerItem.error?.localizedDescription ?? "unknown"))")
            return false
        }

        // Check 3: Player itself must not have an error
        if player.error != nil {
            print("⚠️ [PLAYER HEALTH] Player \(mediaID.prefix(8)) has error: \(player.error!.localizedDescription)")
            return false
        }

        // Check 4: Player item error check (catches asset loading failures)
        if let itemError = playerItem.error {
            print("⚠️ [PLAYER HEALTH] Player \(mediaID.prefix(8)) item has error: \(itemError.localizedDescription)")
            return false
        }

        // All checks passed - player is healthy
        return true
    }

    /// Get cached player if available and healthy
    /// If player exists but is unhealthy, it will be removed and nil returned
    func getCachedPlayer(for mediaID: String) -> AVPlayer? {
        if let player = playerCache[mediaID] {
            // CRITICAL: Perform comprehensive health check before returning player
            // This catches broken players that occur after backgrounding
            if !isPlayerHealthy(player, for: mediaID) {
                print("🔄 [PLAYER HEALTH] Removing unhealthy player \(mediaID.prefix(8)) - will recreate on next request")
                removeInvalidPlayer(for: mediaID)
                return nil
            }

            // Player is healthy - check if it needs buffer reload
            let playerItem = player.currentItem!
            let hasBufferedData = !playerItem.loadedTimeRanges.isEmpty

            // If no buffered data, force preroll to reload from disk cache
            if !hasBufferedData && playerItem.status == .readyToPlay {
                playerItem.preferredForwardBufferDuration = 15.0  // Balanced prefetch
                player.preroll(atRate: 1.0) { success in
                    if !success {
                        print("⚠️ [PLAYER HEALTH] Preroll failed for \(mediaID.prefix(8))")
                    }
                }
            }

            cacheTimestamps[mediaID] = Date() // Update access time
            return player
        }
        return nil
    }
    
    /// Remove invalid cached player
    /// Mark a video as visible (prevents player removal)
    func markAsVisible(_ mediaID: String) {
        visibleVideoMids.insert(mediaID)
    }
    
    /// Mark a video as not visible (allows player removal)
    func markAsNotVisible(_ mediaID: String) {
        visibleVideoMids.remove(mediaID)
    }

    /// Media IDs that must not be evicted while app is in foreground.
    /// Includes visible videos plus videos belonging to nearby tweets (preload window).
    private var foregroundProtectedMids: Set<String> {
        guard isAppInForeground else { return [] }
        var protected = visibleVideoMids
        // Also protect media belonging to tweets in the VideoLoadingManager visible window
        for tweetId in VideoLoadingManager.shared.visibleTweetIds {
            let mediaIDs = getMediaIDsForTweet(tweetId)
            protected.formUnion(mediaIDs)
        }
        return protected
    }

    /// MEMORY FIX: Immediately release player and all video data when video goes out of sight
    /// This is called when MediaCell disappears to free memory immediately (not wait for 30-60s timer)
    @MainActor func releasePlayerImmediately(for mediaID: String) {
        // Don't release visible or near-visible videos while in foreground
        guard !foregroundProtectedMids.contains(mediaID) else {
            print("⚠️ [IMMEDIATE RELEASE] Refusing to release protected video \(mediaID)")
            return
        }

        print("🗑️ [IMMEDIATE RELEASE] Releasing player and video data for \(mediaID)")
        let memoryBefore = getMemoryUsageString()

        // 0. CRITICAL: Cancel any active loading/downloading tasks FIRST
        // This stops ongoing segment downloads that consume memory
        if let loadingTask = loadingTasks[mediaID] {
            loadingTask.cancel()
            loadingTasks.removeValue(forKey: mediaID)
            print("🚫 [IMMEDIATE RELEASE] Canceled active loading task for \(mediaID)")
        }

        if let preloadTask = preloadTasks[mediaID] {
            preloadTask.cancel()
            preloadTasks.removeValue(forKey: mediaID)
            print("🚫 [IMMEDIATE RELEASE] Canceled preload task for \(mediaID)")
        }

        // Stop buffering on CachingPlayerItem if it exists
        if let cachingPlayerItem = cachingPlayerItems[mediaID] {
            cachingPlayerItem.preferredForwardBufferDuration = 0.0
            cachingPlayerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            cachingPlayerItem.asset.cancelLoading()
            print("🚫 [IMMEDIATE RELEASE] Stopped buffering for \(mediaID)")
        }

        // 1. Release the player properly (stops playback, clears buffers, replaces item with nil)
        if let player = playerCache[mediaID] {
            releasePlayer(player)
        }

        // 2. Remove from all caches
        playerCache.removeValue(forKey: mediaID)
        assetCache.removeValue(forKey: mediaID)
        cacheTimestamps.removeValue(forKey: mediaID)
        cachingPlayerItems.removeValue(forKey: mediaID)
        resourceLoaderDelegates.removeValue(forKey: mediaID)
        cleanupTweetMappings(for: mediaID)

        // 3. KEEP DISK CACHE - only release memory
        // Disk cache allows fast reload when scrolling back
        // Periodic cleanup will remove old disk cache based on time expiration
        let memoryAfter = getMemoryUsageString()
        print("✅ [IMMEDIATE RELEASE] Released player from memory for \(mediaID) (memory: \(memoryBefore) → \(memoryAfter), disk cache preserved)")
    }

    func removeInvalidPlayer(for mediaID: String, force: Bool = false) {
        // CRITICAL: Never remove players for protected videos (unless forced for error recovery)
        if !force && foregroundProtectedMids.contains(mediaID) {
            return
        }
        playerCache.removeValue(forKey: mediaID)
        if force {
        }
    }
    
    /// Clear asset cache for a specific mediaID
    @MainActor func clearAssetCache(for mediaID: String) {
        assetCache.removeValue(forKey: mediaID)
        cacheTimestamps.removeValue(forKey: mediaID)
        cachingPlayerItems.removeValue(forKey: mediaID)
        resourceLoaderDelegates.removeValue(forKey: mediaID)
        
        // CRITICAL: Also delete disk cache files (playlists and segments)
        // Without this, retry uses stale cached playlists leading to "no available resources" errors
        Task.detached {
            // Delete the main mediaID directory used by LocalHTTPServer (includes all playlists and segments)
            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let mediaDir = cacheDir.appendingPathComponent(mediaID)
            try? FileManager.default.removeItem(at: mediaDir)
            
            await MainActor.run {
                // Also delete HLS cache (playlists + segments) - legacy locations
                CachingPlayerItem.clearHLSCache(for: mediaID)
            }
        }
    }
    
    /// Clear player and associated assets for a specific mediaID (for failed players)
    @MainActor func clearPlayerForMediaID(_ mediaID: String) {
        // CRITICAL: Properly release player to free memory (not just pause!)
        if let player = playerCache.removeValue(forKey: mediaID) {
            releasePlayer(player) // ✅ Calls replaceCurrentItem(nil) to release memory
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
        }

        // CRITICAL: Delete disk cache files (segments, playlists) to free disk space
        // This prevents memory leak from cached segments staying in memory
        Task.detached {
            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let mediaDir = cacheDir.appendingPathComponent(mediaID)
            try? FileManager.default.removeItem(at: mediaDir)
            
            await MainActor.run {
                CachingPlayerItem.clearHLSCache(for: mediaID)
            }
        }

        print("🗑️ [MEMORY LEAK FIX] Properly released failed player and disk cache for \(mediaID)")
    }
    
    /// Get cached player or create new one with asset
    func getOrCreatePlayer(for url: URL, tweetId: String? = nil, mediaType: MediaType? = nil) async throws -> AVPlayer {
        guard let mediaID = extractMediaID(from: url) else {
            throw NSError(domain: "SharedAssetCache", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Cannot extract mediaID from URL", comment: "Media ID extraction error")])
        }
        
        // ✅ CHECK BLACKLIST FIRST - Don't waste resources on known-bad videos
        let mimeiId = MimeiId(mediaID)
        if BlackList.shared.isBlacklisted(mimeiId) {
            print("🚫 [VIDEO BLACKLIST] Skipping blacklisted video: \(mediaID)")
            throw NSError(domain: "SharedAssetCache", code: -2, 
                         userInfo: [NSLocalizedDescriptionKey: "Video is blacklisted due to repeated failures"])
        }
        
        // CRITICAL: Cache key must ALWAYS be the mediaID (video attachment mid).
        // tweetId must never affect player caching; it caused incorrect reuse/eviction behavior.
        let cacheKey = mediaID

        // Try to get cached player first
        if let cachedPlayer = await MainActor.run(body: { getCachedPlayer(for: cacheKey) }) {
            // Check if this is a player shell (item was removed to free memory)
            if cachedPlayer.currentItem == nil {
                print("🔄 [SharedAssetCache SHELL] Video \(mediaID.prefix(10)) found player shell - reloading item...")
                let itemStartTime = Date()
                // Player exists but item was cleared - reload the item into existing player
                do {
                    let playerItem = try await getOrCreatePlayerItem(for: url, mediaID: mediaID, mediaType: mediaType)
                    let itemElapsed = Date().timeIntervalSince(itemStartTime)
                    await MainActor.run {
                        cachedPlayer.replaceCurrentItem(with: playerItem)
                        let itemStatus = playerItem.status.rawValue
                        let duration = playerItem.duration.seconds
                        print("✅ [SharedAssetCache SHELL] Video \(mediaID.prefix(10)) item reloaded in \(String(format: "%.3f", itemElapsed))s: itemStatus=\(itemStatus), duration=\(String(format: "%.2f", duration))s")
                    }
                    return cachedPlayer
                } catch {
                    // Failed to reload item - fall through to create new player
                    print("⚠️ [SharedAssetCache SHELL] Video \(mediaID.prefix(10)) failed to reload item: \(error)")
                    // Remove broken shell from cache
                    await MainActor.run {
                        _ = playerCache.removeValue(forKey: cacheKey)
                    }
                }
            } else {
                // Player has item - return it
                let currentTime = cachedPlayer.currentTime().seconds
                let itemStatus = cachedPlayer.currentItem?.status.rawValue ?? -1
                let duration = cachedPlayer.currentItem?.duration.seconds ?? 0
                print("♻️ [SharedAssetCache CACHED] Video \(mediaID.prefix(10)) returning cached player: currentTime=\(String(format: "%.2f", currentTime))s, itemStatus=\(itemStatus), duration=\(String(format: "%.2f", duration))s")
                return cachedPlayer
            }
        }
        
        // NEW: Throttle concurrent player creation to prevent memory spikes
        print("🆕 [SharedAssetCache NEW] Video \(mediaID.prefix(10)) no cached player - creating new...")
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                if self.activeCreations < self.maxConcurrentCreations {
                    // Can create immediately
                    self.activeCreations += 1
                    let createStartTime = Date()

                    Task {
                        do {
                            let player = try await self.createPlayerNow(for: url, tweetId: tweetId, mediaType: mediaType)
                            let createElapsed = Date().timeIntervalSince(createStartTime)
                            let itemStatus = player.currentItem?.status.rawValue ?? -1
                            let duration = player.currentItem?.duration.seconds ?? 0
                            print("✅ [SharedAssetCache NEW] Video \(mediaID.prefix(10)) created in \(String(format: "%.3f", createElapsed))s: itemStatus=\(itemStatus), duration=\(String(format: "%.2f", duration))s")
                            await MainActor.run {
                                self.activeCreations -= 1
                                self.processNextPendingCreation()
                            }
                            continuation.resume(returning: player)
                        } catch {
                            print("❌ [SharedAssetCache NEW] Video \(mediaID.prefix(10)) creation failed: \(error)")
                            await MainActor.run {
                                self.activeCreations -= 1
                                self.processNextPendingCreation()
                            }
                            continuation.resume(throwing: error)
                        }
                    }
                } else {
                    // Queue for later
                    print("⏳ [SharedAssetCache THROTTLE] Video \(mediaID.prefix(10)) queuing (active: \(self.activeCreations), pending: \(self.pendingCreations.count + 1))")
                    self.pendingCreations.append((url, tweetId, mediaType, continuation))
                }
            }
        }
    }
    
    /// Process next pending creation when a slot opens
    @MainActor
    private func processNextPendingCreation() {
        guard !pendingCreations.isEmpty, activeCreations < maxConcurrentCreations else { return }
        
        let next = pendingCreations.removeFirst()
        activeCreations += 1
        
        Task {
            do {
                let player = try await self.createPlayerNow(for: next.url, tweetId: next.tweetId, mediaType: next.mediaType)
                await MainActor.run {
                    self.activeCreations -= 1
                    self.processNextPendingCreation()
                }
                next.continuation.resume(returning: player)
            } catch {
                await MainActor.run {
                    self.activeCreations -= 1
                    self.processNextPendingCreation()
                }
                next.continuation.resume(throwing: error)
            }
        }
    }
    
    /// Actually create the player (called after throttling check)
    private func createPlayerNow(for url: URL, tweetId: String? = nil, mediaType: MediaType? = nil) async throws -> AVPlayer {
        guard let mediaID = extractMediaID(from: url) else {
            throw NSError(domain: "SharedAssetCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot extract mediaID"])
        }
        
        // Clean up cache BEFORE creating new player
        await MainActor.run {
            self.managePlayerCacheSize()
        }
        
        // CRITICAL: Notify VideoLoadingManager that a load is starting
        await MainActor.run {
            VideoLoadingManager.shared.videoLoadStarted()
        }
        
        // Use MediaType to determine video type if available, otherwise fall back to URL-based detection
        let isHLSVideo: Bool
        if let mediaType = mediaType {
            isHLSVideo = (mediaType == .hls_video)
        } else {
            // Fallback to URL-based detection for backward compatibility
            let urlString = url.absoluteString
            isHLSVideo = urlString.hasSuffix(".m3u8")
        }
        
        if isHLSVideo {
            // Use CachingPlayerItem for HLS videos WITH RETRY
            do {
                let player = try await createCachingPlayerWithRetry(for: url, mediaID: mediaID, tweetId: tweetId)
                // Notify success
                await MainActor.run {
                    VideoLoadingManager.shared.videoLoadCompleted()
                    // Clear retry count on success
                    videoRetryCount.removeValue(forKey: mediaID)
                    // ✅ RECORD SUCCESS TO BLACKLIST
                    BlackList.shared.recordSuccess(MimeiId(mediaID))
                }
                return player
            } catch {
                // Notify failure
                await MainActor.run {
                    VideoLoadingManager.shared.videoLoadCompleted()
                    // ❌ RECORD FAILURE TO BLACKLIST
                    BlackList.shared.recordFailure(MimeiId(mediaID))
                }
                throw error
            }
        } else {
            // For progressive videos, use LocalHTTPServer to proxy and fix Content-Type WITH RETRY
            do {
                let player = try await createProgressivePlayerWithRetry(for: url, mediaID: mediaID, tweetId: tweetId)
                // Notify success
                await MainActor.run {
                    VideoLoadingManager.shared.videoLoadCompleted()
                    // Clear retry count on success
                    videoRetryCount.removeValue(forKey: mediaID)
                    // ✅ RECORD SUCCESS TO BLACKLIST
                    BlackList.shared.recordSuccess(MimeiId(mediaID))
                }
                return player
            } catch {
                // Notify failure
                await MainActor.run {
                    VideoLoadingManager.shared.videoLoadCompleted()
                    // ❌ RECORD FAILURE TO BLACKLIST
                    BlackList.shared.recordFailure(MimeiId(mediaID))
                }
                throw error
            }
        }
    }
    
    /// Create progressive video player with ONE retry after refreshing author's baseUrl
    /// If it fails twice, it fails - no additional fallback attempts
    private func createProgressivePlayerWithRetry(for url: URL, mediaID: String, tweetId: String?) async throws -> AVPlayer {
        let currentRetry = await MainActor.run { videoRetryCount[mediaID] ?? 0 }
        
        do {
            // Try to create player
            let player = try await createProgressivePlayer(for: url, mediaID: mediaID)
            return player
        } catch let originalError {
            // Only retry ONCE with baseUrl refresh
            if currentRetry == 0 {
                await MainActor.run {
                    videoRetryCount[mediaID] = 1
                }
                
                print("🔄 [PROGRESSIVE VIDEO RETRY] Attempt #1 for: \(mediaID) - refreshing author baseUrl...")
                
                // CRITICAL: Refresh author's baseUrl before retry
                let refreshed = await refreshAuthorBaseUrlForVideo(mediaID: mediaID, originalUrl: url, tweetId: tweetId)
                
                if refreshed {
                    print("✅ [PROGRESSIVE VIDEO RETRY] Author baseUrl refreshed successfully, retrying with new URL")
                } else {
                    print("⚠️ [PROGRESSIVE VIDEO RETRY] Could not refresh author baseUrl, retrying anyway")
                }
                
                // Check if cancelled
                if Task.isCancelled {
                    throw CancellationError()
                }
                
                // Retry ONCE with (potentially) refreshed baseUrl
                do {
                    return try await createProgressivePlayer(for: url, mediaID: mediaID)
                } catch {
                    print("❌ [PROGRESSIVE VIDEO] Failed after 1 retry with baseUrl refresh: \(mediaID)")
                    // Reset retry count for next time
                    _ = await MainActor.run {
                        videoRetryCount.removeValue(forKey: mediaID)
                    }
                    throw error
                }
            } else {
                // Already retried once, give up
                print("❌ [PROGRESSIVE VIDEO] Failed - already attempted retry: \(mediaID)")
                // Reset retry count for next time
                _ = await MainActor.run {
                    videoRetryCount.removeValue(forKey: mediaID)
                }
                throw originalError
            }
        }
    }
    
    /// Create progressive video player (no retry logic, called by retry wrapper)
    private func createProgressivePlayer(for url: URL, mediaID: String) async throws -> AVPlayer {
        // Remove query parameters
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        let cleanURL = components?.url ?? url
        
        // Start LocalHTTPServer
        LocalHTTPServer.shared.start()
        
        // Register real URL and get localhost proxy URL
        let localURL = LocalHTTPServer.shared.registerAndGetURL(for: mediaID, realURL: cleanURL)
        print("🔗 [PROGRESSIVE VIDEO] Original URL: \(url.absoluteString)")
        
        // Create AVPlayer with localhost URL (LocalHTTPServer fixes Content-Type)
        let asset = AVURLAsset(url: localURL)

        // NOTE: Removed strict isPlayable validation since LocalHTTPServer proxy URLs
        // may not immediately report as playable, but the video should still work.
        // Let the player creation proceed and fail naturally if truly unplayable.
        
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
        }
        
        return player
    }
    
    /// Create HLS video player with ONE retry after refreshing author's baseUrl
    /// If it fails twice, it fails - no additional fallback attempts
    private func createCachingPlayerWithRetry(for url: URL, mediaID: String, tweetId: String?) async throws -> AVPlayer {
        let currentRetry = await MainActor.run { videoRetryCount[mediaID] ?? 0 }
        
        do {
            // Try to create player (tries master.m3u8 then playlist.m3u8)
            let player = try await createCachingPlayer(for: url, tweetId: tweetId)
            return player
        } catch let originalError {
            // Only retry ONCE with baseUrl refresh
            if currentRetry == 0 {
                await MainActor.run {
                    videoRetryCount[mediaID] = 1
                }
                
                print("🔄 [HLS VIDEO RETRY] Attempt #1 for: \(mediaID) - refreshing author baseUrl...")
                
                // CRITICAL: Refresh author's baseUrl before retry
                let refreshed = await refreshAuthorBaseUrlForVideo(mediaID: mediaID, originalUrl: url, tweetId: tweetId)
                
                if refreshed {
                    print("✅ [HLS VIDEO RETRY] Author baseUrl refreshed successfully, retrying with new URL")
                } else {
                    print("⚠️ [HLS VIDEO RETRY] Could not refresh author baseUrl, retrying anyway")
                }
                
                // Check if cancelled
                if Task.isCancelled {
                    throw CancellationError()
                }
                
                // Retry ONCE with (potentially) refreshed baseUrl
                do {
                    return try await createCachingPlayer(for: url, tweetId: tweetId)
                } catch {
                    print("❌ [HLS VIDEO] Failed after 1 retry with baseUrl refresh: \(mediaID)")
                    // Reset retry count for next time
                    await MainActor.run {
                        _ = videoRetryCount.removeValue(forKey: mediaID)
                    }
                    throw error
                }
            } else {
                // Already retried once, give up
                print("❌ [HLS VIDEO] Failed - already attempted retry: \(mediaID)")
                // Reset retry count for next time
                await MainActor.run {
                    _ = videoRetryCount.removeValue(forKey: mediaID)
                }
                throw originalError
            }
        }
    }
    
    /// Attempt to refresh the author's baseUrl for a video
    /// Returns true if baseUrl was successfully refreshed
    private func refreshAuthorBaseUrlForVideo(mediaID: String, originalUrl: URL, tweetId: String?) async -> Bool {
        // Try to find the author ID from the tweet or attachment
        guard let authorId = await findAuthorIdForVideo(mediaID: mediaID, tweetId: tweetId) else {
            print("⚠️ [BASEURL REFRESH] Cannot find author ID for video: \(mediaID)")
            return false
        }
        
        print("🔍 [BASEURL REFRESH] Found author ID: \(authorId) for video: \(mediaID)")
        
        // Fetch fresh user data to get updated baseUrl
        do {
            // Force baseUrl refresh by passing empty baseUrl
            let refreshedUser = try await HproseInstance.shared.fetchUser(authorId, baseUrl: "")
            
            if let newBaseUrl = refreshedUser?.baseUrl {
                print("✅ [BASEURL REFRESH] Successfully refreshed baseUrl for author \(authorId): \(newBaseUrl.absoluteString)")
                
                // Update any cached Tweet instances with the new author info
                await MainActor.run {
                    if let cachedTweet = Tweet.getInstance(for: tweetId ?? "") {
                        cachedTweet.author = refreshedUser
                        print("✅ [BASEURL REFRESH] Updated cached tweet with refreshed author")
                    }
                }
                
                return true
            } else {
                print("⚠️ [BASEURL REFRESH] Fetched user but no baseUrl available for author: \(authorId)")
                return false
            }
        } catch {
            print("❌ [BASEURL REFRESH] Failed to fetch user \(authorId): \(error.localizedDescription)")
            return false
        }
    }
    
    /// Find the author ID for a video by searching tweets and attachments
    private func findAuthorIdForVideo(mediaID: String, tweetId: String?) async -> String? {
        // Strategy 1: Try to get from tweet if we have tweetId (most reliable)
        if let tweetId = tweetId, !tweetId.isEmpty {
            // Check singleton cache first (fast)
            if let tweet = Tweet.getInstance(for: tweetId) {
                let authorId = !tweet.authorId.isEmpty ? tweet.authorId : tweet.author?.mid
                if let authorId = authorId, !authorId.isEmpty {
                    print("✅ [AUTHOR SEARCH] Found author from tweetId singleton: \(authorId)")
                    return authorId
                }
            }
            
            // Check Core Data cache (synchronous but reliable)
            if let tweet = TweetCacheManager.shared.fetchTweetSync(mid: tweetId) {
                let authorId = !tweet.authorId.isEmpty ? tweet.authorId : tweet.author?.mid
                if let authorId = authorId, !authorId.isEmpty {
                    print("✅ [AUTHOR SEARCH] Found author from Core Data: \(authorId)")
                    return authorId
                }
            }
        }
        
        // Strategy 2: Check if this video belongs to current user (common case for own videos)
        // This is a reasonable assumption - many video playback failures are on user's own content
        // because server reboots affect the current user's videos most visibly
        let currentUserMid = HproseInstance.shared.appUser.mid
        if !currentUserMid.isEmpty {
            print("⚠️ [AUTHOR SEARCH] Could not find specific author for video \(mediaID), trying current user: \(currentUserMid)")
            return currentUserMid
        }
        
        print("❌ [AUTHOR SEARCH] Could not find author for video: \(mediaID)")
        return nil
    }
    
    /// Create CachingPlayerItem for HLS videos only
    private func createCachingPlayer(for url: URL, tweetId: String?) async throws -> AVPlayer {
        guard let mediaID = extractMediaID(from: url) else {
            throw NSError(domain: "SharedAssetCache", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Cannot extract mediaID from URL", comment: "Media ID extraction error")])
        }
                
        // Check if we have cached content first to avoid network requests
        let cachedResolvedURL = await checkCachedHLSPlaylist(for: mediaID, baseURL: url)
        
        // Resolve the HLS URL (use cached info if available, otherwise make network requests)
        let resolvedURL: URL
        if let cachedURL = cachedResolvedURL {
            resolvedURL = cachedURL
        } else {
            let networkResolvedURL = await resolveHLSURL(url)
            
            // If network resolution returns the base URL unchanged (resolution failed),
            // try cache check ONE MORE TIME with more relaxed validation
            if networkResolvedURL == url {
                print("⚠️ [HLS FALLBACK] Network resolution failed, retrying cache check for mediaID: \(mediaID)")
                if let fallbackCachedURL = await checkCachedHLSPlaylist(for: mediaID, baseURL: url) {
                    resolvedURL = fallbackCachedURL
                } else {
                    print("❌ [HLS FALLBACK] Cache check retry also failed for mediaID: \(mediaID)")
                    resolvedURL = networkResolvedURL
                }
            } else {
                resolvedURL = networkResolvedURL
            }
        }
        
        // Start LocalHTTPServer for HLS video serving
        LocalHTTPServer.shared.start()
        
        // Create CachingPlayerItem using HLS initializer (handles LocalHTTPServer internally)
        let cachingPlayerItem = CachingPlayerItem(hlsURL: resolvedURL, mediaID: mediaID, avUrlAssetOptions: nil)
        
        
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
        return player
    }
    
    /// Get or create a player item for the given URL and media type
    /// Used by singleton players that want to swap items instead of creating new players
    /// IMPORTANT: Always creates NEW items because AVPlayerItem can only be attached to ONE AVPlayer
    func getOrCreatePlayerItem(for url: URL, mediaID: String, mediaType: MediaType? = nil) async throws -> AVPlayerItem {
        // Check cancellation before starting
        try Task.checkCancellation()
        
        guard let extractedMediaID = extractMediaID(from: url) else {
            throw NSError(domain: "SharedAssetCache", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Cannot extract mediaID from URL", comment: "Media ID extraction error")])
        }
        
        // Determine if this is HLS
        let isHLSVideo: Bool
        if let mediaType = mediaType {
            isHLSVideo = (mediaType == .hls_video)
        } else {
            isHLSVideo = url.absoluteString.hasSuffix(".m3u8")
        }
        
        if isHLSVideo {
            // Check cancellation before HLS resolution
            try Task.checkCancellation()
            
            // Create fresh HLS player item for singleton player
            let resolvedURL = await resolveHLSURL(url)
            
            // Check cancellation after async operation
            try Task.checkCancellation()
            
            LocalHTTPServer.shared.start()
            let cachingPlayerItem = CachingPlayerItem(hlsURL: resolvedURL, mediaID: extractedMediaID, avUrlAssetOptions: nil)
            
            // Create delegate but DON'T cache it (singleton manages its own lifecycle)
            let delegate = CachingPlayerItemDelegateImpl()
            cachingPlayerItem.delegate = delegate
            
            return cachingPlayerItem
        } else {
            // Check cancellation before progressive video setup
            try Task.checkCancellation()
            
            // Create fresh progressive video player item using LocalHTTPServer for IP-independent caching
            LocalHTTPServer.shared.start()
            
            // Register with LocalHTTPServer (handles mediaID-based caching and IP changes)
            let localURL = LocalHTTPServer.shared.registerAndGetURL(for: extractedMediaID, realURL: url)
            
            // Check cancellation before creating asset
            try Task.checkCancellation()
            
            let asset = AVURLAsset(url: localURL)
            let playerItem = AVPlayerItem(asset: asset)
            
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
                    }
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
                
                return reconstructedURL
            }
        }
        
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
        
        
        // Step 1: Try master.m3u8 first (wait for completion before proceeding)
        if await urlExists(masterURL, timeout: 8.0) {
            return masterURL
        }
        
        // Step 2: Only if master.m3u8 failed, try playlist.m3u8 (sequential, not simultaneous)
        if await urlExists(playlistURL, timeout: 8.0) {
            return playlistURL
        }
        
        // If both fail, return original URL and let it fail
        return url
    }
    
    /// Check if URL exists with configurable timeout
    private func urlExists(_ url: URL, timeout: TimeInterval = 8.0) async -> Bool {
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
        
        // Clear retry tasks
        for task in scheduledVideoRetries.values {
            task.cancel()
        }
        scheduledVideoRetries.removeAll()
        videoRetryCount.removeAll()
        
        // Clear timestamps
        cacheTimestamps.removeAll()
        
        // Clear URL tracking
        tweetUrlMapping.removeAll()
        
        // Clear disk cache status
        diskCacheStatus.removeAll()
        
        // Clear disk cache using the cleanup manager
        DiskCacheCleanupManager.shared.clearAllCache()
        
    }
    
    /// Cancel all active loading tasks to free memory immediately
    @MainActor func cancelAllLoadingTasks() {
        // Cancel all asset loading tasks
        for (_, task) in loadingTasks {
            task.cancel()
        }
        loadingTasks.removeAll()
        
        // Cancel all preload tasks
        for (_, task) in preloadTasks {
            task.cancel()
        }
        preloadTasks.removeAll()
        
        // Cancel all retry tasks
        for (_, task) in scheduledVideoRetries {
            task.cancel()
        }
        scheduledVideoRetries.removeAll()
        videoRetryCount.removeAll()
    }

    /// Emergency cleanup during network failures
    @MainActor func handleNetworkFailureCleanup() {
        print("DEBUG: [SharedAssetCache] Network failure detected, performing emergency cleanup")

        // Cancel all active loading tasks
        for (mediaID, task) in loadingTasks {
            print("DEBUG: [SharedAssetCache] Cancelling active load: \(mediaID)")
            task.cancel()
        }
        loadingTasks.removeAll()

        // Cancel all preload tasks
        for (mediaID, task) in preloadTasks {
            print("DEBUG: [SharedAssetCache] Cancelling preload: \(mediaID)")
            task.cancel()
        }
        preloadTasks.removeAll()

        // Cancel all retry tasks
        for (mediaID, task) in scheduledVideoRetries {
            print("DEBUG: [SharedAssetCache] Cancelling retry: \(mediaID)")
            task.cancel()
        }
        scheduledVideoRetries.removeAll()

        // Clear retry counts for failed requests
        videoRetryCount.removeAll()

        // Release cache aggressively
        releasePartialCache(percentage: 30)
    }

    /// Release a percentage of cache to free memory (preserves current playing videos)
    @MainActor func releasePartialCache(percentage: Int) {
        let percentageToRemove = max(1, min(percentage, 90)) // Ensure 1-90% range
        
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
    }
    
    // MARK: - Enhanced Preloading Methods
    
    /// Preload video for immediate display (high priority)
    func preloadVideo(for url: URL, tweetId: String? = nil) {
        // Use mediaID as cache key (stable identifier), not URL which can change
        guard let mediaID = extractMediaID(from: url) else { return }
        let cacheKey = mediaID
        
        // Cancel existing preload task if any
        preloadTasks[cacheKey]?.cancel()
        preloadTasks.removeValue(forKey: cacheKey)
        
        let task = Task {
            defer {
                // ✅ CRITICAL MEMORY FIX: Remove completed preload task
                preloadTasks.removeValue(forKey: cacheKey)
            }
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
        preloadTasks.removeValue(forKey: cacheKey)
        
        let task = Task {
            defer {
                // ✅ CRITICAL MEMORY FIX: Remove completed preload task
                preloadTasks.removeValue(forKey: cacheKey)
            }
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
                        // PERFORMANCE FIX: Clean up tweet URL mappings
                        self.cleanupTweetMappings(for: key)
                    }
                }
            }
        }
    }
    
    /// Properly release an AVPlayer instance to prevent memory leaks
    /// Based on Apple best practices and Stack Overflow recommendations
    private func releasePlayer(_ player: AVPlayer) {
        // CRITICAL: Stop playback and set rate to 0
        player.pause()
        player.rate = 0.0
        
        // MEMORY LEAK FIX: Cancel any active downloads in CachingPlayerItem before releasing
        // This prevents buffered video data from staying in memory
        if let currentItem = player.currentItem {
            // Reduce buffer to 0 to release buffered data
            currentItem.preferredForwardBufferDuration = 0.0

            // Clear any cached frames/thumbnails that might be held
            currentItem.asset.cancelLoading()

            // If it's a CachingPlayerItem, clear references to help with cleanup
            if let _ = currentItem as? CachingPlayerItem {
                // CachingPlayerItem cleanup is handled by its deinit method
                // The important cleanup (buffer duration = 0) is already done above
            }

            // Force deallocation by removing all observers
            NotificationCenter.default.removeObserver(currentItem)
        }

        // CRITICAL: Replace current item with nil to release memory
        // This is the #1 fix from web research - ALWAYS do this, no conditions!
        player.replaceCurrentItem(with: nil)

        // Force garbage collection hint by creating a new autorelease pool
        autoreleasepool {
            // This forces immediate cleanup of any autoreleased objects
        }
        
        // Note: AVPlayerLayer automatically releases player when layer is deallocated
        // No need to manually access playerLayer property (causes crash)
    }
    
    /// Validate all cached players and remove any that are unhealthy
    /// Useful to call after returning from background to clean up broken players
    /// Returns the number of unhealthy players removed
    @MainActor func validateAndCleanupPlayers() -> Int {
        print("🔍 [PLAYER HEALTH] Validating \(playerCache.count) cached players")

        var removedCount = 0
        let mediaIDsToCheck = Array(playerCache.keys)

        for mediaID in mediaIDsToCheck {
            guard let player = playerCache[mediaID] else { continue }

            if !isPlayerHealthy(player, for: mediaID) {
                print("🗑️ [PLAYER HEALTH] Removing unhealthy player: \(mediaID.prefix(8))")
                removeInvalidPlayer(for: mediaID)
                removedCount += 1
            }
        }

        if removedCount > 0 {
            print("✅ [PLAYER HEALTH] Removed \(removedCount) unhealthy players, \(playerCache.count) healthy players remain")
        } else {
            print("✅ [PLAYER HEALTH] All \(playerCache.count) cached players are healthy")
        }

        return removedCount
    }

    /// PUBLIC: Aggressively release all players to free memory
    /// Call this when navigating away from video pages
    func releaseAllPlayers() {
        print("🗑️ [MEMORY] Releasing ALL players (\(playerCache.count) total)")

        let playersToRelease = playerCache.values
        let count = playersToRelease.count

        // Release each player properly
        for player in playersToRelease {
            releasePlayer(player)
        }

        // Clear all caches
        playerCache.removeAll()
        cachingPlayerItems.removeAll()
        resourceLoaderDelegates.removeAll()

        // Keep timestamps and asset cache for faster recovery

        print("✅ [MEMORY] Released \(count) players successfully")
    }

    /// MEMORY FIX: Force immediate cleanup of old/inactive players to release memory during fast scrolling
    @MainActor func forceMemoryCleanup() {
        let memoryBefore = getMemoryUsageString()
        let cacheSizeBefore = playerCache.count
        print("🧹 [MEMORY] Starting force cleanup (memory: \(memoryBefore), cache: \(cacheSizeBefore) players)")

        let now = Date()
        let memoryUsage = getCurrentMemoryUsage() / (1024 * 1024)

        // DYNAMIC AGE THRESHOLD: Be more aggressive when memory is high
        // During fast scrolling, all players are recently accessed, so we need lower thresholds
        let ageThreshold: TimeInterval
        if memoryUsage > 1200 {
            ageThreshold = 10  // Very aggressive: 10 seconds during high memory
        } else if memoryUsage > 1000 {
            ageThreshold = 30  // Aggressive: 30 seconds during elevated memory
        } else {
            ageThreshold = 60  // Normal: 60 seconds during moderate memory
        }

        // CRITICAL: Never evict visible or near-visible videos while app is in foreground
        let protected = foregroundProtectedMids
        let oldKeys = cacheTimestamps
            .filter { !protected.contains($0.key) && now.timeIntervalSince($0.value) > ageThreshold }
            .map { $0.key }

        print("📊 [MEMORY] Using age threshold: \(Int(ageThreshold))s (memory: \(memoryUsage)MB, protected videos: \(protected.count))")

        if !oldKeys.isEmpty {
            print("🗑️ [MEMORY] Found \(oldKeys.count) old players to remove")

            for key in oldKeys {
                if let player = playerCache[key] {
                    releasePlayer(player)
                }
                playerCache.removeValue(forKey: key)
                assetCache.removeValue(forKey: key)
                cacheTimestamps.removeValue(forKey: key)
                cachingPlayerItems.removeValue(forKey: key)
                resourceLoaderDelegates.removeValue(forKey: key)
                cleanupTweetMappings(for: key)
            }

            let memoryAfter = getMemoryUsageString()
            let cacheSizeAfter = playerCache.count
            print("✅ [MEMORY] Force cleanup completed - freed \(oldKeys.count) players (memory: \(memoryBefore) → \(memoryAfter), cache: \(cacheSizeBefore) → \(cacheSizeAfter))")
        } else {
            print("ℹ️ [MEMORY] Force cleanup: no old players to remove (memory: \(memoryBefore))")
        }
    }
    
    private func managePlayerCacheSize() {
        // Normal LRU eviction - enforce cache size limits
        if playerCache.count > maxPlayerCacheSize {
            let memoryBefore = getMemoryUsageString()
            print("⚠️ [PLAYER CACHE] Over limit: \(playerCache.count)/\(maxPlayerCacheSize) - evicting oldest (memory: \(memoryBefore))")

            // CRITICAL: Never evict visible or near-visible videos while app is in foreground
            let protected = foregroundProtectedMids
            let sortedKeys = cacheTimestamps
                .filter { !protected.contains($0.key) } // Skip protected videos
                .sorted { $0.value < $1.value }
                .map { $0.key }
            let keysToRemove = sortedKeys.prefix(playerCache.count - maxPlayerCacheSize)

            for key in keysToRemove {
                if let player = playerCache[key] {
                    // CRITICAL: Properly release player to prevent memory leaks
                    releasePlayer(player)
                }
                playerCache.removeValue(forKey: key)
                cacheTimestamps.removeValue(forKey: key)
                cachingPlayerItems.removeValue(forKey: key)
                resourceLoaderDelegates.removeValue(forKey: key)
                // PERFORMANCE FIX: Clean up tweet URL mappings
                cleanupTweetMappings(for: key)
            }

            if !keysToRemove.isEmpty {
                let memoryAfter = getMemoryUsageString()
                print("🗑️ [PLAYER CACHE] Evicted \(keysToRemove.count) players (memory: \(memoryBefore) → \(memoryAfter))")
            }
        }

        // REMOVED: Time-based inactive cleanup (was 15s threshold)
        // Reason: Too aggressive during scrolling - causes videos to reload when scrolling back
        // Cache size is already managed by LRU eviction above (MAX_PLAYER_CACHE_SIZE = 6)
    }
    
    /// Update access time for a player to prevent premature cleanup (called when video becomes visible)
    @MainActor func updatePlayerAccessTime(mediaID: String) {
        guard playerCache[mediaID] != nil else { return }
        cacheTimestamps[mediaID] = Date()
    }

    /// Get formatted memory usage string for logging (when actually needed)
    @MainActor func getMemoryUsageString() -> String {
        let memoryUsage = getCurrentMemoryUsage()
        let memoryUsageMB = memoryUsage / (1024 * 1024)
        return "\(memoryUsageMB)MB"
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
    private var lastMemoryWarningTime: Date?
    private let memoryWarningCooldown: TimeInterval = 30 // 30 seconds cooldown between warnings
    
    private func checkMemoryPressure() {
        let memoryUsage = getCurrentMemoryUsage()
        let memoryUsageMB = memoryUsage / (1024 * 1024)

        // BALANCED THRESHOLDS: Prevent memory growth without being too aggressive
        // - Only trigger cleanup at genuinely high usage levels
        // - Allow normal scrolling without constant cleanup interruptions
        if memoryUsageMB > 1000 {  // Reasonable threshold - only cleanup when truly needed
            // Check cooldown to prevent repeated cleanups
            if let lastWarning = lastMemoryWarningTime,
               Date().timeIntervalSince(lastWarning) < memoryWarningCooldown {
                // Still in cooldown period
                return
            }

            print("⚠️ [MEMORY] High usage: \(memoryUsageMB)MB (>1GB) - triggering cleanup")
            lastMemoryWarningTime = Date()
            handleMemoryWarning()
        } else if memoryUsageMB > 800 {
            // Only log when approaching concerning levels, don't trigger cleanup yet
            print("📊 [MEMORY] Elevated usage: \(memoryUsageMB)MB (monitoring)")
        } else {
            // Log current memory state periodically for visibility
            print("📈 [MEMORY] Current usage: \(memoryUsageMB)MB (normal)")
        }
        // Silent monitoring below 1GB
    }
    
    // MARK: - Memory Warning Handling
    
    private func setupMemoryWarningNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSystemMemoryWarning()
            }
        }
    }
    
    /// Handle SYSTEM memory warning (more aggressive than proactive checks)
    private func handleSystemMemoryWarning() {
        let memoryUsage = getCurrentMemoryUsage()
        let memoryUsageMB = memoryUsage / (1024 * 1024)
        let cacheSize = playerCache.count

        print("🚨 [SYSTEM MEMORY WARNING] iOS triggered - memory: \(memoryUsageMB)MB, cache: \(cacheSize) players")

        if UploadProgressManager.shared.isProcessingVideo {
            print("⚠️ [SYSTEM MEMORY WARNING] Video upload in progress, skipping cleanup")
            return
        }

        // Only perform aggressive cleanup if memory usage exceeds 1.2GB
        // This prevents wasteful cleanup when memory usage is actually low
        if memoryUsageMB > 1200 {
            print("🧹 [SYSTEM MEMORY WARNING] High usage detected, performing aggressive cleanup")
            // System warning means iOS is serious - be more aggressive
            cancelAllLoadingTasks()
            releasePartialCache(percentage: 60) // Release 60% (not 100% - preserve some UX)

            let memoryAfter = getMemoryUsageString()
            print("✅ [SYSTEM MEMORY WARNING] Cleanup completed (memory: \(memoryUsageMB)MB → \(memoryAfter))")
        } else {
            print("ℹ️ [SYSTEM MEMORY WARNING] Memory usage moderate (\(memoryUsageMB)MB), light cleanup only")
            // Even at moderate levels, do a small cleanup
            forceMemoryCleanup()
        }
    }
    
    private func handleMemoryWarning() {
        let memoryUsage = getCurrentMemoryUsage()
        let memoryUsageMB = memoryUsage / (1024 * 1024)
        let cacheSize = playerCache.count

        print("⚠️ [MEMORY WARNING] Proactive cleanup triggered - memory: \(memoryUsageMB)MB, cache: \(cacheSize) players")

        // CRITICAL: Check if video upload is in progress
        // During FFmpeg video conversion, memory spikes are expected
        // Clearing video player caches during upload breaks existing players
        if UploadProgressManager.shared.isProcessingVideo {
            print("⚠️ [MEMORY WARNING] Video upload in progress, skipping cleanup")
            return
        }

        // Research-backed: Players are NOT the main memory consumer
        // Logs showed: releasing ALL players (10 total) didn't reduce memory (752MB -> 886MB!)
        // Real culprits: images, video segments, LocalHTTPServer cache

        if memoryUsageMB > 1200 {
            print("🗑️ [MEMORY WARNING] High usage - performing moderate cleanup")
            // Cancel active downloads first (prevents memory growth)
            cancelAllLoadingTasks()

            // MODERATE: Release only 30% of players (preserve 70% for good UX)
            releasePartialCache(percentage: 30)

            let memoryAfter = getMemoryUsageString()
            print("✅ [MEMORY WARNING] Cleanup complete (memory: \(memoryUsageMB)MB → \(memoryAfter))")
        } else {
            print("ℹ️ [MEMORY WARNING] Memory usage moderate, performing light cleanup")
            // Even at moderate levels, trigger force cleanup
            forceMemoryCleanup()
        }
        
        // Don't clear URL mapping - preserve user's browsing context
        // NEVER release ALL players unless system sends memory warning
    }
    
    // MARK: - App Lifecycle Handling
    
    private func setupAppLifecycleNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isAppInForeground = true
                self?.handleAppWillEnterForeground()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isAppInForeground = false
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isAppInForeground = true
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
    }
    
    private func handleAppDidBecomeActive() {
        // DON'T refresh players automatically - AppDelegate handles recovery strategy
    }
    
    /// Gentle refresh for short backgrounds - keep players intact, just refresh video layers
    /// This is called when app returns from SHORT background (< 5 minutes)
    /// iOS hasn't invalidated the video layers yet, so we can keep everything and avoid black screens
    func refreshVideoLayersForShortBackground() {
        // For short backgrounds, we keep players/assets but refresh their state
        // The connection pool reset in LocalHTTPServer is usually enough
        // But we need to verify players are still healthy (no action needed, just validation)
    }
    
    /// Clear video players for background recovery after long background periods
    /// This is called when app returns from extended background (>5 minutes)
    /// Release video memory but keep AVPlayer shells for fast recovery
    /// This releases heavy video buffers while preserving player objects for quick resume
    func releaseVideoMemoryButKeepPlayers() {
        print("💾 [SharedAssetCache] Releasing video memory (keeping player shells for fast recovery)")

        // Pause all players and detach their items to release video buffers
        // This releases the heavy memory (decoded frames, buffered data) but keeps the AVPlayer objects
        for (key, player) in playerCache {
            player.pause()
            player.replaceCurrentItem(with: nil) // Releases video buffers and assets
            print("💾 [SharedAssetCache] Released memory for player: \(key)")
        }
        // DON'T remove from playerCache - keep the shells for fast recovery

        // Clear CachingPlayerItem instances - they hold heavy references
        cachingPlayerItems.removeAll()

        // Clear assets - they contain the heavy video data
        assetCache.removeAll()

        // Cancel loading tasks to prevent memory usage during background
        loadingTasks.removeAll()
        preloadTasks.removeAll()

        // Keep playerCache, resourceLoaderDelegates, cacheTimestamps for fast recovery
        print("💾 [SharedAssetCache] Memory released - kept \(playerCache.count) player shells for recovery")
    }

    func clearVideoPlayersForBackgroundRecovery() {
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
    }
    
    /// Aggressively cleanup video players when navigating away from video-heavy screens
    /// This prevents memory accumulation when navigating between bookmarks/favorites/profile
    @MainActor func cleanupForNavigation() {
        print("🧹 [NAVIGATION CLEANUP] Starting aggressive cleanup - playerCache: \(playerCache.count), assetCache: \(assetCache.count)")
        
        // Cancel all ongoing loading tasks to prevent new players from being created
        cancelAllLoadingTasks()
        
        // Pause and release ALL video players
        for (key, player) in playerCache {
            player.pause()
            player.replaceCurrentItem(with: nil)
            print("🧹 [NAVIGATION CLEANUP] Released player: \(key)")
        }
        playerCache.removeAll()
        
        // Clear CachingPlayerItem instances
        cachingPlayerItems.removeAll()
        
        // Clear asset cache to free memory
        assetCache.removeAll()
        
        // Clear timestamps
        cacheTimestamps.removeAll()
        
        print("🧹 [NAVIGATION CLEANUP] Cleanup complete - all players and assets released")
    }
    
    // MARK: - Cache Persistence Methods
    
    /// Restore cache metadata from UserDefaults on app startup
    private func restoreCacheFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: cacheMetadataKey),
              let metadata = try? JSONDecoder().decode(CacheMetadata.self, from: data) else {
            return
        }
        
        
        // Since we're using on-demand caching, we don't need to validate existing cache files
        // Just restore the metadata for reference
        let validMediaIDs = metadata.cachedMediaIDs
        
        cacheTimestamps = validMediaIDs
    }
    
    /// Save cache metadata to UserDefaults
    private func saveCacheMetadata() {
        let metadata = CacheMetadata(cachedMediaIDs: cacheTimestamps)
        if let data = try? JSONEncoder().encode(metadata) {
            UserDefaults.standard.set(data, forKey: cacheMetadataKey)
        }
    }
    
    
    private func refreshCachedPlayers() {
        var invalidPlayers = 0
        
        // Validate and refresh all cached players
        for (_, player) in playerCache {
            // Check if player item is still valid
            guard let playerItem = player.currentItem else {
                invalidPlayers += 1
                continue
            }
            
            if playerItem.status == .failed {
                invalidPlayers += 1
                continue
            }
            
            // Force a seek to refresh the video layer and ensure buffering
            let currentTime = player.currentTime()
            player.seek(to: currentTime) { finished in
                if finished {
                    // Trigger preroll to ensure video is ready to play
                    player.preroll(atRate: 1.0) { _ in }
                }
            }
        }
        
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
