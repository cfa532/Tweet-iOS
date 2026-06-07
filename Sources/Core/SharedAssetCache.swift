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
    var hlsExtensions: [String: String] // mediaID -> "master.m3u8" or "playlist.m3u8"

    init(cachedMediaIDs: [String: Date], hlsExtensions: [String: String] = [:]) {
        self.cachedMediaIDs = cachedMediaIDs
        self.hlsExtensions = hlsExtensions
    }
}
// CachingPlayerItem is now integrated directly

/// Shared asset cache for video players with background loading and priority management
@MainActor
class SharedAssetCache: ObservableObject {
    static let shared = SharedAssetCache()
    
    // CRITICAL: Track visible videos to prevent their players from being removed.
    // Count by media ID because the same video can be visible in more than one cell.
    private var visibleVideoMidCounts: [String: Int] = [:]
    private var visibleVideoMids: Set<String> {
        Set(visibleVideoMidCounts.keys)
    }

    // Track preloaded players (next videos in scroll direction) — protected from LRU eviction
    private var preloadedPlayerMids: Set<String> = []

    // Keep just-finished directional preloads alive through short list rebuilds/pagination churn.
    // Without this grace window, a preload can complete, then be unprotected before its cell
    // scrolls into view, producing a black first paint.
    private var preloadedPlayerGraceExpirations: [String: Date] = [:]
    private let preloadedPlayerGraceInterval: TimeInterval = 12

    // Track media IDs that are intentional off-screen preload targets. These may not
    // have a cached player yet, but their in-flight loads should survive visibility cleanup.
    private var protectedPreloadMids: Set<String> = []

    // Track app foreground state — when foreground, protect visible + directional preloads from eviction
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
    private var preloadedThumbnailMids: Set<String> = []
    private var tweetUrlMapping: [String: Set<String>] = [:] // tweetId -> Set of mediaIDs

    private enum VideoLoadKind: Hashable {
        case asset
        case player
    }

    private struct VideoLoadTicket: Hashable {
        let mediaID: String
        let kind: VideoLoadKind
    }

    private var activeVideoLoadTickets: Set<VideoLoadTicket> = []
    
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
    private let cacheExpirationInterval: TimeInterval = Constants.CACHE_EXPIRATION_SECONDS
    private let feedMaxVideoDimension: CGFloat = 2560

    /// Truncate a mediaID to 8 chars for log readability.
    private func shortMID(_ id: String) -> String { id.count > 8 ? String(id.prefix(8)) : id }

    private func applyFeedVideoDecodeLimit(to item: AVPlayerItem) {
        // Feed/preload players should comfortably allow 1080p and QHD, but avoid
        // inline 4K-class decode pressure. Fullscreen creates uncapped items.
        item.preferredMaximumResolution = CGSize(
            width: feedMaxVideoDimension,
            height: feedMaxVideoDimension
        )
    }

    private func beginVideoLoad(mediaID: String, kind: VideoLoadKind) {
        let ticket = VideoLoadTicket(mediaID: mediaID, kind: kind)
        guard activeVideoLoadTickets.insert(ticket).inserted else { return }
        VideoLoadingManager.shared.videoLoadStarted()
    }

    private func finishVideoLoad(mediaID: String, kind: VideoLoadKind) {
        let ticket = VideoLoadTicket(mediaID: mediaID, kind: kind)
        guard activeVideoLoadTickets.remove(ticket) != nil else { return }
        VideoLoadingManager.shared.videoLoadCompleted()
    }

    private func finishAllVideoLoads() {
        let count = activeVideoLoadTickets.count
        activeVideoLoadTickets.removeAll()
        for _ in 0..<count {
            VideoLoadingManager.shared.videoLoadCompleted()
        }
    }

    private func cancelAssetLoadTask(for mediaID: String) {
        if let task = loadingTasks.removeValue(forKey: mediaID) {
            task.cancel()
            finishVideoLoad(mediaID: mediaID, kind: .asset)
        }
    }

    private func cancelPreloadTaskEntry(for mediaID: String) {
        if let task = preloadTasks.removeValue(forKey: mediaID) {
            task.cancel()
        }
    }

    private func cancelPlayerCreationTasks(for mediaID: String) {
        if let task = inFlightPlayerCreations.removeValue(forKey: mediaID) {
            task.cancel()
            finishVideoLoad(mediaID: mediaID, kind: .player)
        }
        if let task = activeCreationTasks.removeValue(forKey: mediaID) {
            task.cancel()
            finishVideoLoad(mediaID: mediaID, kind: .player)
        }
    }
    
    // MARK: - Player Creation Deduplication
    private var activeCreationTasks: [String: Task<AVPlayer, Error>] = [:] // mediaID -> creation task (for cancellation)
    private var inFlightPlayerCreations: [String: Task<AVPlayer, Error>] = [:] // mediaID -> dedup: covers queued + in-flight
    
    // MARK: - Cache Persistence
    private let cacheMetadataKey = "SharedAssetCache_Metadata"
    private var hlsExtensions: [String: String] = [:] // mediaID -> "master.m3u8" or "playlist.m3u8"
    
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

        // MEMORY LEAK FIX: Clean up tweetUrlMapping entries that have no cached content
        // Failed videos create tweetUrlMapping entries but never get cache timestamps,
        // so they are never cleaned by the expiredKeys loop above
        cleanupOrphanedTweetMappings()

        // MEMORY LEAK FIX: Clean up cachingPlayerDelegates for media IDs that have no player
        // Failed HLS player creations store delegates that are never cleaned
        cleanupOrphanedDelegates()
    }
    
    // MARK: - Asset Management
    
    /// Cancel loading tasks for a specific URL only if no cache is available
    @MainActor func cancelLoading(for mediaID: String) {
        // Check if we have cached content before cancelling
        let hasCachedAsset = assetCache[mediaID] != nil
        let hasCachedPlayer = playerCache[mediaID] != nil
        
        // Cancel loading task if exists and no cache is available
        if loadingTasks[mediaID] != nil {
            if !hasCachedAsset && !hasCachedPlayer {
                cancelAssetLoadTask(for: mediaID)
            } else {
            }
        }
        
        // Cancel preload task if exists and no cache is available
        if preloadTasks[mediaID] != nil {
            if !hasCachedAsset && !hasCachedPlayer {
                cancelPreloadTaskEntry(for: mediaID)
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
    
    /// MEMORY LEAK FIX: Clean up tweetUrlMapping entries whose mediaIDs have no cached content
    /// and no active loading tasks. These are left behind by failed video loads.
    private func cleanupOrphanedTweetMappings() {
        var tweetsToRemove: [String] = []
        for (tweetId, mediaIDs) in tweetUrlMapping {
            // Check if any mediaID for this tweet has cached content or active tasks
            let hasAnyCachedOrActive = mediaIDs.contains { mediaID in
                assetCache[mediaID] != nil ||
                playerCache[mediaID] != nil ||
                loadingTasks[mediaID] != nil ||
                preloadTasks[mediaID] != nil
            }
            if !hasAnyCachedOrActive {
                tweetsToRemove.append(tweetId)
            }
        }
        for tweetId in tweetsToRemove {
            tweetUrlMapping.removeValue(forKey: tweetId)
        }
    }

    /// MEMORY LEAK FIX: Clean up cachingPlayerDelegates for mediaIDs that have no player or player item
    /// Failed HLS creations store delegates that are never cleaned up
    private func cleanupOrphanedDelegates() {
        let orphanedDelegateKeys = cachingPlayerDelegates.keys.filter { mediaID in
            playerCache[mediaID] == nil && cachingPlayerItems[mediaID] == nil
        }
        for key in orphanedDelegateKeys {
            cachingPlayerDelegates.removeValue(forKey: key)
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
        let protected = outOfSightCancellationProtectedMids
        for mediaID in tweetMediaIDs {
            if protected.contains(mediaID) {
                print("🔮 [PLAYER PRELOAD] Keeping protected out-of-sight load for \(shortMID(mediaID))")
                continue
            }

            // Cancel loading tasks regardless of cache status
            cancelAssetLoadTask(for: mediaID)

            // Cancel preload tasks
            cancelPreloadTaskEntry(for: mediaID)

            // Cancel in-flight player creation dedup task
            cancelPlayerCreationTasks(for: mediaID)

            // Stop network usage for CachingPlayerItem if it exists
            if let cachingPlayerItem = cachingPlayerItems[mediaID] {
                cachingPlayerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
                cachingPlayerItem.asset.cancelLoading()
            }

            // Cancel active LocalHTTPServer downloads (progressive streams + HLS segments)
            // Without this, URLSession downloads persist independently of Task cancellation
            LocalHTTPServer.shared.cancelDownloads(for: mediaID)
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
    @MainActor func getAsset(for url: URL, mediaID explicitMediaID: String? = nil, tweetId: String? = nil, mediaType: MediaType? = nil) async throws -> AVAsset {
        guard let mediaID = explicitMediaID ?? extractMediaID(from: url) else {
            throw NSError(domain: "SharedAssetCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot extract mediaID from URL"])
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
        
        beginVideoLoad(mediaID: cacheKey, kind: .asset)
        
        // Create new loading task
        let task = Task<AVAsset, Error> {
            defer {
                Task { @MainActor in
                    self.finishVideoLoad(mediaID: cacheKey, kind: .asset)
                }
            }

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

                // Resolve HLS URL, using persisted extension when available
                let cachedFilename = await MainActor.run { self.hlsExtensions[mediaID] }
                let resolvedURL: URL
                let resolvedFilename: String?
                if let cachedFilename {
                    resolvedURL = url.appendingPathComponent(cachedFilename)
                    resolvedFilename = nil // already persisted, no need to re-save
                } else {
                    let networkResolvedURL = await resolveHLSURL(url)
                    resolvedURL = networkResolvedURL
                    resolvedFilename = (networkResolvedURL != url) ? networkResolvedURL.lastPathComponent : nil
                }

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
                    // Persist the resolved extension alongside the cached asset
                    if let filename = resolvedFilename {
                        self.hlsExtensions[mediaID] = filename
                    }
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

                // Trigger emergency cleanup if too many consecutive failures
                if consecutiveNetworkFailures >= maxConsecutiveFailures {
                    handleNetworkFailureCleanup()
                    consecutiveNetworkFailures = 0 // Reset counter after cleanup
                }

            }

            throw error
        }
    }
    
    /// Cache a player instance for immediate reuse
    func cachePlayer(_ player: AVPlayer, for mediaID: String) {
        // Remove old player if exists - do this asynchronously to avoid blocking
        if let oldPlayer = playerCache[mediaID], oldPlayer !== player {
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

    /// Move a prepared feed/preload player into fullscreen ownership without releasing it.
    /// Mirrors Android's takePlayerForFullScreen(): preserve the prepared item/buffer,
    /// remove feed/preload bookkeeping, and let fullscreen attach the same AVPlayer directly.
    @MainActor func takePlayerForFullscreen(_ mediaID: String) -> AVPlayer? {
        guard let player = playerCache.removeValue(forKey: mediaID),
              player.currentItem != nil else {
            return nil
        }

        cancelPreloadTaskEntry(for: mediaID)
        visibleVideoMidCounts.removeValue(forKey: mediaID)
        preloadedPlayerMids.remove(mediaID)
        protectedPreloadMids.remove(mediaID)
        preloadedPlayerGraceExpirations.removeValue(forKey: mediaID)
        cacheTimestamps.removeValue(forKey: mediaID)

        player.pause()
        print("🎬 [SharedAssetCache] Handed off prepared player to fullscreen for \(shortMID(mediaID))")
        return player
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
                removeInvalidPlayer(for: mediaID, force: true)
                return nil
            }

            // Cache lookup must stay side-effect free. Playback/preload callers
            // decide when to enable network and play; doing preroll here can fight
            // coordinator decisions and can crash if AVPlayer.status is not ready.
            cacheTimestamps[mediaID] = Date() // Update access time
            return player
        }
        return nil
    }
    
    /// Remove invalid cached player
    /// Mark a video as visible (prevents player removal)
    func markAsVisible(_ mediaID: String) {
        visibleVideoMidCounts[mediaID, default: 0] += 1
    }
    
    /// Mark a video as not visible (allows player removal)
    func markAsNotVisible(_ mediaID: String) {
        let nextCount = max((visibleVideoMidCounts[mediaID] ?? 0) - 1, 0)
        if nextCount == 0 {
            visibleVideoMidCounts.removeValue(forKey: mediaID)
        } else {
            visibleVideoMidCounts[mediaID] = nextCount
        }
    }

    /// Media IDs that must not be evicted while app is in foreground.
    /// Includes visible videos plus current scroll-direction preload targets.
    private var foregroundProtectedMids: Set<String> {
        guard isAppInForeground else { return [] }
        expirePreloadGrace()
        var protected = visibleVideoMids
        // Protect preloaded players (next videos in scroll direction)
        protected.formUnion(preloadedPlayerMids)
        protected.formUnion(preloadedPlayerGraceExpirations.keys)
        // Protect current preload targets before their players are cached.
        protected.formUnion(protectedPreloadMids)
        protected.formUnion(preloadTasks.keys)
        // Protect players still being created — evicting mid-flight causes stuck spinner
        protected.formUnion(inFlightPlayerCreations.keys)
        // Also protect media belonging to tweets in the VideoLoadingManager visible window
        for tweetId in VideoLoadingManager.shared.visibleTweetIds {
            let mediaIDs = getMediaIDsForTweet(tweetId)
            protected.formUnion(mediaIDs)
        }
        return protected
    }

    /// Media IDs allowed to keep active network work while their cell is out of sight.
    /// This is intentionally narrower than eviction protection: an in-flight creation or
    /// queued preload must not protect itself, otherwise stale loads survive scrolling.
    private var outOfSightCancellationProtectedMids: Set<String> {
        guard isAppInForeground else { return [] }
        expirePreloadGrace()
        var protected = visibleVideoMids
        protected.formUnion(protectedPreloadMids)
        protected.formUnion(preloadedPlayerMids)
        protected.formUnion(preloadedPlayerGraceExpirations.keys)
        return protected
    }

    private func expirePreloadGrace(now: Date = Date()) {
        preloadedPlayerGraceExpirations = preloadedPlayerGraceExpirations.filter { mediaID, expiry in
            expiry > now && playerCache[mediaID] != nil
        }
    }

    private func protectPreloadedPlayerBriefly(_ mediaID: String, now: Date = Date()) {
        guard playerCache[mediaID] != nil else { return }
        preloadedPlayerGraceExpirations[mediaID] = now.addingTimeInterval(preloadedPlayerGraceInterval)
    }

    /// Cancel in-flight preload/loading tasks for a specific mediaID without releasing the cached player.
    /// Called by VideoPlaybackCoordinator when the directional preload set changes and old downloads should stop.
    @MainActor func cancelPreloadTask(for mediaID: String) {
        protectPreloadedPlayerBriefly(mediaID)
        protectedPreloadMids.remove(mediaID)
        preloadedPlayerMids.remove(mediaID)

        cancelPreloadTaskEntry(for: mediaID)
        cancelAssetLoadTask(for: mediaID)
        cancelPlayerCreationTasks(for: mediaID)
        if let cachingPlayerItem = cachingPlayerItems[mediaID] {
            cachingPlayerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            cachingPlayerItem.asset.cancelLoading()
        }
        // Stop any active HLS segment downloads for this preloaded player.
        // Task cancellation alone doesn't stop already-running AVPlayer segment requests
        // since AVPlayer makes them independently via the local HTTP proxy.
        LocalHTTPServer.shared.cancelDownloads(for: mediaID)
        // Don't release cached player — LRU handles eviction
    }

    /// Fullscreen owns the user's active video. Match Android's behavior: stop preload
    /// work, release stale preloaded players, and pause other feed players without
    /// tearing down the tapped/protected playback path.
    @MainActor func suspendFeedActivityForFullscreen(protecting protectedMediaID: String) {
        let protected = Set([protectedMediaID])
        let stalePreloadedPlayers = Array(preloadedPlayerMids).filter { mediaID in
            !protected.contains(mediaID) &&
            (visibleVideoMidCounts[mediaID] ?? 0) == 0
        }

        let preloadIDs = Set(preloadTasks.keys)
            .union(preloadedPlayerMids)
            .union(protectedPreloadMids)
            .subtracting(protected)
        for mediaID in preloadIDs {
            cancelPreloadTaskEntry(for: mediaID)
            protectedPreloadMids.remove(mediaID)
            preloadedPlayerMids.remove(mediaID)
            preloadedPlayerGraceExpirations.removeValue(forKey: mediaID)
            LocalHTTPServer.shared.cancelDownloads(for: mediaID)
        }

        var releasedPlayers = 0
        for mediaID in stalePreloadedPlayers {
            if let player = playerCache.removeValue(forKey: mediaID) {
                // Do not call releasePlayer() here. A player listed as a stale preload can
                // still be referenced by a feed cell or VideoStateCache after fullscreen
                // handoff/return; replaceCurrentItem(nil) would mutate that shared AVPlayer
                // and leave the feed with a cached player shell that has no currentItem.
                player.pause()
                player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = false
                releasedPlayers += 1
            }
            cacheTimestamps.removeValue(forKey: mediaID)
        }

        for (mediaID, player) in playerCache where !protected.contains(mediaID) {
            player.pause()
            player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        }

        print("🎬 [SharedAssetCache] Suspended feed activity for fullscreen \(String(protectedMediaID.prefix(8))): cancelled \(preloadIDs.count) preload(s), released \(releasedPlayers) preloaded player(s)")
    }

    /// Fullscreen could not reuse a cached player for this media, so any feed/preload
    /// work for the same mid is now stale. Cancel only the in-flight work, keep finished
    /// cache entries, and let fullscreen start a primary load with the local proxy priority.
    @MainActor func prepareUncachedFullscreenLoad(for mediaID: String) {
        var cancelledWork = 0

        if loadingTasks[mediaID] != nil {
            cancelAssetLoadTask(for: mediaID)
            cancelledWork += 1
        }
        if preloadTasks[mediaID] != nil {
            cancelPreloadTaskEntry(for: mediaID)
            cancelledWork += 1
        }
        if inFlightPlayerCreations[mediaID] != nil || activeCreationTasks[mediaID] != nil {
            cancelPlayerCreationTasks(for: mediaID)
            cancelledWork += 1
        }
        if let item = cachingPlayerItems.removeValue(forKey: mediaID) {
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            item.asset.cancelLoading()
            cancelledWork += 1
        }

        preloadedPlayerMids.remove(mediaID)
        protectedPreloadMids.remove(mediaID)
        preloadedPlayerGraceExpirations.removeValue(forKey: mediaID)
        LocalHTTPServer.shared.cancelDownloads(for: mediaID)

        if cancelledWork > 0 {
            print("🎬 [SharedAssetCache] Prepared uncached fullscreen load for \(shortMID(mediaID)): cancelled \(cancelledWork) stale feed/preload work item(s)")
        }
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
        if loadingTasks[mediaID] != nil {
            cancelAssetLoadTask(for: mediaID)
            print("🚫 [IMMEDIATE RELEASE] Canceled active loading task for \(mediaID)")
        }

        if preloadTasks[mediaID] != nil {
            cancelPreloadTaskEntry(for: mediaID)
            print("🚫 [IMMEDIATE RELEASE] Canceled preload task for \(mediaID)")
        }

        cancelPlayerCreationTasks(for: mediaID)

        // Stop network usage on CachingPlayerItem if it exists
        if let cachingPlayerItem = cachingPlayerItems[mediaID] {
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
        cachingPlayerDelegates.removeValue(forKey: mediaID)
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
        preloadedPlayerMids.remove(mediaID)
        protectedPreloadMids.remove(mediaID)
        preloadedPlayerGraceExpirations.removeValue(forKey: mediaID)
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
    /// Soft-reset a player for buffering timeout recovery. Only removes the AVPlayer
    /// from `playerCache` (so the retry path creates a fresh one from the cached asset),
    /// but preserves the asset, CachingPlayerItem, resource loader delegates, disk cache,
    /// and — critically — active LocalHTTPServer downloads. This lets in-flight segment
    /// downloads finish so the next player can use them immediately.
    @MainActor func softResetPlayer(for mediaID: String) {
        if let player = playerCache.removeValue(forKey: mediaID) {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        // Keep: assetCache, cachingPlayerItems, cachingPlayerDelegates,
        //        resourceLoaderDelegates, diskCacheStatus, active downloads
        print("🔄 [SOFT RESET] Player removed for \(mediaID) — asset/downloads preserved")
    }

    /// - Parameter deleteDiskCache: When true (default), also deletes the on-disk HLS segment cache.
    ///   Pass false for stuck-player recovery (slow server, not corrupt content) so the partial
    ///   disk cache is preserved for the next attempt. Pass true only when content is likely corrupt
    ///   (e.g. player status == .failed) or to reclaim disk space.
    @MainActor func clearPlayerForMediaID(_ mediaID: String, deleteDiskCache: Bool = true) {
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
        cancelAssetLoadTask(for: mediaID)
        cancelPreloadTaskEntry(for: mediaID)
        cancelPlayerCreationTasks(for: mediaID)

        // Cancel active LocalHTTPServer downloads for this mediaID BEFORE deleting disk cache.
        // Without this, in-flight segment writes fail with "file not found" (directory deleted
        // while download was writing), and dedup waiters time out and spawn untracked background
        // retries that waste bandwidth even though the player is gone.
        LocalHTTPServer.shared.cancelDownloads(for: mediaID)

        if deleteDiskCache {
            // Delete disk cache files (segments, playlists) to free disk space and force a clean
            // retry when content is likely corrupt (.failed player status).
            // Skipped for stuck-player recovery — server was just slow, partial cache is still
            // valid and saves bandwidth on the next attempt.
            Task.detached {
                let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                let mediaDir = cacheDir.appendingPathComponent(mediaID)
                try? FileManager.default.removeItem(at: mediaDir)

                await MainActor.run {
                    CachingPlayerItem.clearHLSCache(for: mediaID)
                }
            }
        }

        print("🗑️ [MEMORY LEAK FIX] Released player for \(mediaID) (deleteDiskCache: \(deleteDiskCache))")
    }
    
    /// Get cached player or create new one. Bandwidth is managed by NodeConnectionPool in
    /// LocalHTTPServer — no slot throttling needed here.
    func getOrCreatePlayer(for url: URL, mediaID explicitMediaID: String? = nil, tweetId: String? = nil, mediaType: MediaType? = nil) async throws -> AVPlayer {
        guard let mediaID = explicitMediaID ?? extractMediaID(from: url) else {
            throw NSError(domain: "SharedAssetCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot extract mediaID from URL"])
        }

        // ✅ CHECK BLACKLIST FIRST - Don't waste resources on known-bad videos
        let mimeiId = MimeiId(mediaID)
        if BlackList.shared.isBlacklisted(mimeiId) {
            print("🚫 [VIDEO BLACKLIST] Skipping blacklisted video: \(mediaID)")
            throw NSError(domain: "SharedAssetCache", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Video is blacklisted due to repeated failures"])
        }

        // CRITICAL: Cache key must ALWAYS be the mediaID (video attachment mid).
        let cacheKey = mediaID

        // Try to get cached player first
        if let cachedPlayer = await MainActor.run(body: { getCachedPlayer(for: cacheKey) }) {
            if cachedPlayer.currentItem == nil {
                // Player shell — reload item
                do {
                    let playerItem = try await getOrCreatePlayerItem(for: url, mediaID: mediaID, mediaType: mediaType)
                    await MainActor.run { cachedPlayer.replaceCurrentItem(with: playerItem) }
                    return cachedPlayer
                } catch {
                    await MainActor.run { _ = playerCache.removeValue(forKey: cacheKey) }
                }
            } else {
                return cachedPlayer
            }
        }

        // Deduplicate: join an existing in-flight creation for the same mediaID.
        if let existingTask = inFlightPlayerCreations[mediaID] {
            print("♻️ [SharedAssetCache] Joining in-flight creation for \(shortMID(mediaID))")
            return try await existingTask.value
        }

        // Create immediately — NodeConnectionPool in LocalHTTPServer manages bandwidth.
        let creationTask = Task<AVPlayer, Error> {
            let task = Task<AVPlayer, Error> { try await self.createPlayerNow(for: url, mediaID: mediaID, tweetId: tweetId, mediaType: mediaType) }
            await MainActor.run { self.activeCreationTasks[mediaID] = task }
            do {
                let player = try await task.value
                await MainActor.run { _ = self.activeCreationTasks.removeValue(forKey: mediaID) }
                return player
            } catch {
                await MainActor.run { _ = self.activeCreationTasks.removeValue(forKey: mediaID) }
                throw error
            }
        }
        inFlightPlayerCreations[mediaID] = creationTask

        do {
            let player = try await creationTask.value
            inFlightPlayerCreations.removeValue(forKey: mediaID)
            return player
        } catch {
            inFlightPlayerCreations.removeValue(forKey: mediaID)
            throw error
        }
    }

    /// Actually create the player
    private func createPlayerNow(for url: URL, mediaID: String, tweetId: String? = nil, mediaType: MediaType? = nil) async throws -> AVPlayer {
        // Bail early if this creation was cancelled (e.g. by makeRoomForPlayers)
        try Task.checkCancellation()

        // Re-check cache: another creation may have completed while this was queued
        // (e.g. visible cell finished while preload was pending in the queue)
        if let cachedPlayer = await MainActor.run(body: { self.getCachedPlayer(for: mediaID) }),
           cachedPlayer.currentItem != nil {
            let shortId = shortMID(mediaID)
            print("♻️ [SharedAssetCache] Skipping duplicate creation for \(shortId) — already cached")
            return cachedPlayer
        }

        // Clean up cache BEFORE creating new player — evict to make room for incoming player
        await MainActor.run {
            self.managePlayerCacheSize(reserveSlots: 1)
        }

        beginVideoLoad(mediaID: mediaID, kind: .player)
        defer {
            finishVideoLoad(mediaID: mediaID, kind: .player)
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
            try Task.checkCancellation()
            do {
                let player = try await createCachingPlayerWithRetry(for: url, mediaID: mediaID, tweetId: tweetId)
                await MainActor.run {
                    // Clear retry count on success
                    videoRetryCount.removeValue(forKey: mediaID)
                    // ✅ RECORD SUCCESS TO BLACKLIST
                    BlackList.shared.recordSuccess(MimeiId(mediaID))
                }
                return player
            } catch {
                let isCancellation = (error as NSError).code == NSURLErrorCancelled || error is CancellationError
                await MainActor.run {
                    if !isCancellation {
                        BlackList.shared.recordFailure(MimeiId(mediaID))
                    }
                }
                throw error
            }
        } else {
            // For progressive videos, use LocalHTTPServer to proxy and fix Content-Type WITH RETRY
            try Task.checkCancellation()
            do {
                let player = try await createProgressivePlayerWithRetry(for: url, mediaID: mediaID, tweetId: tweetId)
                await MainActor.run {
                    // Clear retry count on success
                    videoRetryCount.removeValue(forKey: mediaID)
                    BlackList.shared.recordSuccess(MimeiId(mediaID))
                }
                return player
            } catch {
                let isCancellation = (error as NSError).code == NSURLErrorCancelled || error is CancellationError
                await MainActor.run {
                    if !isCancellation {
                        BlackList.shared.recordFailure(MimeiId(mediaID))
                    }
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
                guard let refreshedURL = await refreshAuthorBaseUrlForVideo(mediaID: mediaID, originalUrl: url, tweetId: tweetId) else {
                    videoRetryCount.removeValue(forKey: mediaID)
                    print("❌ [PROGRESSIVE VIDEO RETRY] Could not refresh author baseUrl; failing instead of retrying stale URL")
                    throw originalError
                }
                print("✅ [PROGRESSIVE VIDEO RETRY] Author baseUrl refreshed successfully, retrying with new URL")
                
                // Check if cancelled
                if Task.isCancelled {
                    throw CancellationError()
                }
                
                // Retry ONCE with the refreshed baseUrl. Never retry the failed URL.
                do {
                    return try await createProgressivePlayer(for: refreshedURL, mediaID: mediaID)
                } catch {
                    // Reset retry count for next time
                    _ = await MainActor.run {
                        videoRetryCount.removeValue(forKey: mediaID)
                    }
                    throw error
                }
            } else {
                // Already retried once, give up
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
        
        // Create AVPlayer with localhost URL (LocalHTTPServer fixes Content-Type)
        let asset = AVURLAsset(url: localURL)

        // NOTE: Removed strict isPlayable validation since LocalHTTPServer proxy URLs
        // may not immediately report as playable, but the video should still work.
        // Let the player creation proceed and fail naturally if truly unplayable.
        
        let playerItem = AVPlayerItem(asset: asset)
        applyFeedVideoDecodeLimit(to: playerItem)
        let player = AVPlayer(playerItem: playerItem)

        // CRITICAL: Mute player at creation - will be unmuted by mode if needed
        player.isMuted = true
        // Let AVPlayer bridge short IPFS/proxy gaps by waiting for more data and
        // resuming on its own. Disabling this made primary videos pause for a long
        // time after a buffer drain because our manual keepUp callback could miss
        // waitingToPlayAtSpecifiedRate transitions.
        player.automaticallyWaitsToMinimizeStalling = true

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
            let player = try await createCachingPlayer(for: url, mediaID: mediaID, tweetId: tweetId)
            return player
        } catch let originalError {
            // Only retry ONCE with baseUrl refresh
            if currentRetry == 0 {
                await MainActor.run {
                    videoRetryCount[mediaID] = 1
                }
                
                print("🔄 [HLS VIDEO RETRY] Attempt #1 for: \(mediaID) - refreshing author baseUrl...")
                
                // CRITICAL: Refresh author's baseUrl before retry
                guard let refreshedURL = await refreshAuthorBaseUrlForVideo(mediaID: mediaID, originalUrl: url, tweetId: tweetId) else {
                    videoRetryCount.removeValue(forKey: mediaID)
                    print("❌ [HLS VIDEO RETRY] Could not refresh author baseUrl; failing instead of retrying stale URL")
                    throw originalError
                }
                print("✅ [HLS VIDEO RETRY] Author baseUrl refreshed successfully, retrying with new URL")
                
                // Check if cancelled
                if Task.isCancelled {
                    throw CancellationError()
                }
                
                // Retry ONCE with the refreshed baseUrl. Never retry the failed URL.
                do {
                    return try await createCachingPlayer(for: refreshedURL, mediaID: mediaID, tweetId: tweetId)
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
    
    /// Attempt to refresh the author's baseUrl for a video.
    /// Returns a URL rebased onto the fresh baseUrl, or nil if refresh failed.
    private func refreshAuthorBaseUrlForVideo(mediaID: String, originalUrl: URL, tweetId: String?) async -> URL? {
        // Try to find the author ID from the tweet or attachment
        guard let authorId = await findAuthorIdForVideo(mediaID: mediaID, tweetId: tweetId) else {
            print("⚠️ [BASEURL REFRESH] Cannot find author ID for video: \(mediaID)")
            return nil
        }
        
        print("🔍 [BASEURL REFRESH] Found author ID: \(authorId) for video: \(mediaID)")
        
        // Fetch fresh user data to get updated baseUrl
        do {
            // Force baseUrl refresh by passing empty baseUrl
            let refreshedUser = try await HproseInstance.shared.fetchUser(authorId, baseUrl: "")
            
            if let newBaseUrl = refreshedUser?.baseUrl {
                print("✅ [BASEURL REFRESH] Successfully refreshed baseUrl for author \(authorId): \(newBaseUrl.absoluteString)")
                let refreshedURL = rebaseMediaURL(originalUrl, onto: newBaseUrl, mediaID: mediaID)
                
                // Update any cached Tweet instances with the new author info
                await MainActor.run {
                    if let cachedTweet = Tweet.getInstance(for: tweetId ?? "") {
                        cachedTweet.author = refreshedUser
                        print("✅ [BASEURL REFRESH] Updated cached tweet with refreshed author")
                    }
                }
                
                return refreshedURL
            } else {
                print("⚠️ [BASEURL REFRESH] Fetched user but no baseUrl available for author: \(authorId)")
                return nil
            }
        } catch {
            print("❌ [BASEURL REFRESH] Failed to fetch user \(authorId): \(error.localizedDescription)")
            return nil
        }
    }

    private func rebaseMediaURL(_ originalURL: URL, onto baseURL: URL, mediaID: String) -> URL {
        if var originalComponents = URLComponents(url: originalURL, resolvingAgainstBaseURL: false),
           let baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
           let scheme = baseComponents.scheme,
           let host = baseComponents.host {
            originalComponents.scheme = scheme
            originalComponents.host = host
            originalComponents.port = baseComponents.port
            originalComponents.user = baseComponents.user
            originalComponents.password = baseComponents.password
            if let rebasedURL = originalComponents.url {
                return rebasedURL
            }
        }

        let path = mediaID.count > Constants.MIMEI_ID_LENGTH ? "ipfs/\(mediaID)" : "mm/\(mediaID)"
        return baseURL.appendingPathComponent(path)
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
    private func createCachingPlayer(for url: URL, mediaID: String, tweetId: String?) async throws -> AVPlayer {
        // Fast path: use persisted extension from CacheMetadata (no disk I/O or network)
        let resolvedURL: URL
        if let cachedFilename = hlsExtensions[mediaID] {
            resolvedURL = url.appendingPathComponent(cachedFilename)
        } else {
            // Slow path: check cached files on disk first, then network HEAD requests
            let cachedResolvedURL = await checkCachedHLSPlaylist(for: mediaID, baseURL: url)

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
                        // Both network HEAD requests timed out and no disk cache exists.
                        // Throw instead of creating CachingPlayerItem with an unresolved base URL,
                        // which would leave the player stuck in .unknown status with the spinner
                        // showing forever.
                        print("❌ [HLS FALLBACK] Network resolution and cache check both failed for mediaID: \(mediaID) — server unreachable")
                        throw NSError(domain: "SharedAssetCache", code: -5,
                            userInfo: [NSLocalizedDescriptionKey: "HLS URL resolution failed: server did not respond to master.m3u8 or playlist.m3u8"])
                    }
                } else {
                    // Save the resolved filename so future loads skip this lookup entirely
                    hlsExtensions[mediaID] = networkResolvedURL.lastPathComponent
                    saveCacheMetadata()
                    resolvedURL = networkResolvedURL
                }
            }
        }
        
        // Start LocalHTTPServer for HLS video serving
        LocalHTTPServer.shared.start()
        
        // Create CachingPlayerItem using HLS initializer (handles LocalHTTPServer internally)
        let cachingPlayerItem = CachingPlayerItem(hlsURL: resolvedURL, mediaID: mediaID, avUrlAssetOptions: nil)
        applyFeedVideoDecodeLimit(to: cachingPlayerItem)
        
        
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
        // Let AVPlayer bridge short IPFS/proxy gaps by waiting for more data and
        // resuming on its own. Disabling this made primary videos pause for a long
        // time after a buffer drain because our manual keepUp callback could miss
        // waitingToPlayAtSpecifiedRate transitions.
        player.automaticallyWaitsToMinimizeStalling = true

        
        cachingPlayerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        
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

            // Resolve HLS URL, using persisted extension when available
            let resolvedURL: URL
            if let cachedFilename = hlsExtensions[mediaID] {
                resolvedURL = url.appendingPathComponent(cachedFilename)
            } else {
                let networkResolvedURL = await resolveHLSURL(url)
                if networkResolvedURL != url {
                    hlsExtensions[mediaID] = networkResolvedURL.lastPathComponent
                    saveCacheMetadata()
                }
                resolvedURL = networkResolvedURL
            }

            // Check cancellation after async operation
            try Task.checkCancellation()

            LocalHTTPServer.shared.start()
            let cachingPlayerItem = CachingPlayerItem(hlsURL: resolvedURL, mediaID: mediaID, avUrlAssetOptions: nil)
            applyFeedVideoDecodeLimit(to: cachingPlayerItem)
            
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
            let localURL = LocalHTTPServer.shared.registerAndGetURL(for: mediaID, realURL: url)
            
            // Check cancellation before creating asset
            try Task.checkCancellation()
            
            let asset = AVURLAsset(url: localURL)
            let playerItem = AVPlayerItem(asset: asset)
            applyFeedVideoDecodeLimit(to: playerItem)
            
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

        // HLS fallback strategy: try master.m3u8 and playlist.m3u8 in parallel
        let masterURL = url.appendingPathComponent("master.m3u8")
        let playlistURL = url.appendingPathComponent("playlist.m3u8")

        // Launch both HEAD requests concurrently
        async let masterExists = urlExists(masterURL, timeout: 8.0)
        async let playlistExists = urlExists(playlistURL, timeout: 8.0)

        // Prefer master.m3u8 if it exists
        if await masterExists {
            return masterURL
        }

        if await playlistExists {
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
        
        cancelAllLoadingTasks()
        
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

        // Clear HLS extension cache
        hlsExtensions.removeAll()

        // Clear disk cache using the cleanup manager
        DiskCacheCleanupManager.shared.clearAllCache()

    }
    
    /// Cancel all active loading tasks to free memory immediately
    @MainActor func cancelAllLoadingTasks() {
        for task in loadingTasks.values {
            task.cancel()
        }
        loadingTasks.removeAll()
        for task in preloadTasks.values {
            task.cancel()
        }
        preloadTasks.removeAll()
        for task in inFlightPlayerCreations.values {
            task.cancel()
        }
        inFlightPlayerCreations.removeAll()
        for task in activeCreationTasks.values {
            task.cancel()
        }
        activeCreationTasks.removeAll()
        finishAllVideoLoads()
        
        // Cancel all retry tasks
        for (_, task) in scheduledVideoRetries {
            task.cancel()
        }
        scheduledVideoRetries.removeAll()
        videoRetryCount.removeAll()
    }

    /// Emergency cleanup during network failures
    @MainActor func handleNetworkFailureCleanup() {

        cancelAllLoadingTasks()

        // Cancel all retry tasks
        for (_, task) in scheduledVideoRetries {
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
    func preloadVideo(for url: URL, mediaID explicitMediaID: String? = nil, tweetId: String? = nil) {
        // Use mediaID as cache key (stable identifier), not URL which can change
        guard let mediaID = explicitMediaID ?? extractMediaID(from: url) else { return }
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
                let player = try await getOrCreatePlayer(for: url, mediaID: mediaID)
                _ = player
            } catch {
                // Handle error silently
            }
        }

        preloadTasks[cacheKey] = task
    }

    /// Preload asset only (for background loading - lower priority)
    func preloadAsset(for url: URL, mediaID explicitMediaID: String? = nil, tweetId: String? = nil, mediaType: MediaType? = nil) {
        // Use mediaID as cache key (stable identifier), not URL which can change
        guard let mediaID = explicitMediaID ?? extractMediaID(from: url) else { return }
        let cacheKey = mediaID

        // Skip if asset already cached
        if assetCache[cacheKey] != nil { return }

        // Skip if already downloading
        if loadingTasks[cacheKey] != nil { return }

        // Cancel existing preload task if any
        preloadTasks[cacheKey]?.cancel()
        preloadTasks.removeValue(forKey: cacheKey)

        let task = Task {
            defer {
                // ✅ CRITICAL MEMORY FIX: Remove completed preload task
                preloadTasks.removeValue(forKey: cacheKey)
            }
            do {
                _ = try await getAsset(for: url, mediaID: mediaID, tweetId: tweetId, mediaType: mediaType)
            } catch {
                // Handle error silently
            }
        }

        preloadTasks[cacheKey] = task
    }
    
    /// Preload player (not just asset) for upcoming video in scroll direction.
    /// Creates an AVPlayer, warms a small initial buffer, and decodes a non-black
    /// poster frame so the cell has content before it becomes visible.
    func preloadPlayer(for url: URL, mediaID explicitMediaID: String? = nil, tweetId: String? = nil, mediaType: MediaType? = nil) {
        guard let mediaID = explicitMediaID ?? extractMediaID(from: url) else { return }

        // Skip if player already cached
        if let player = playerCache[mediaID] {
            preloadedPlayerGraceExpirations.removeValue(forKey: mediaID)
            preloadedPlayerMids.insert(mediaID)
            NotificationCenter.default.post(
                name: .videoPlayerPreloaded,
                object: self,
                userInfo: ["mediaID": mediaID]
            )
            if !visibleVideoMids.contains(mediaID), player.rate == 0 {
                player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            }

            if cachedThumbnail(for: mediaID) == nil {
                startPreloadThumbnailTask(for: player, mediaID: mediaID)
            }
            return
        }

        // Cancel existing preload task for this media
        preloadTasks[mediaID]?.cancel()
        preloadTasks.removeValue(forKey: mediaID)

        let task = Task {
            defer {
                preloadTasks.removeValue(forKey: mediaID)
            }
            do {
                let player = try await getOrCreatePlayer(for: url, mediaID: mediaID, tweetId: tweetId, mediaType: mediaType)
                await warmPreloadedPlayer(player, mediaID: mediaID)

                if cachedThumbnail(for: mediaID) == nil,
                   let readyAsset = await waitForPreloadReadyAsset(player, mediaID: mediaID) {
                    if await generateDecodedPreloadFrame(from: player, for: mediaID) == false,
                       cachedThumbnail(for: mediaID) == nil {
                        generateThumbnail(from: readyAsset, for: mediaID)
                    }
                }

                await MainActor.run {
                    if !self.visibleVideoMids.contains(mediaID), player.rate == 0 {
                        player.pause()
                        player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = false
                    }
                    self.preloadedPlayerGraceExpirations.removeValue(forKey: mediaID)
                    self.preloadedPlayerMids.insert(mediaID)
                    NotificationCenter.default.post(
                        name: .videoPlayerPreloaded,
                        object: self,
                        userInfo: ["mediaID": mediaID]
                    )
                }

                print("🔮 [PLAYER PRELOAD] Warmed player for \(String(mediaID.prefix(8)))")
            } catch {
                // Preload failure is non-critical
            }
        }
        preloadTasks[mediaID] = task
    }

    private func startPreloadThumbnailTask(for player: AVPlayer, mediaID: String) {
        guard preloadTasks[mediaID] == nil else { return }

        let task = Task {
            defer { preloadTasks.removeValue(forKey: mediaID) }
            guard cachedThumbnail(for: mediaID) == nil else { return }

            if let readyAsset = await waitForPreloadReadyAsset(player, mediaID: mediaID),
               cachedThumbnail(for: mediaID) == nil {
                if await generateDecodedPreloadFrame(from: player, for: mediaID) == false,
                   cachedThumbnail(for: mediaID) == nil {
                    generateThumbnail(from: readyAsset, for: mediaID)
                }
            }
        }
        preloadTasks[mediaID] = task
    }

    private func warmPreloadedPlayer(_ player: AVPlayer, mediaID: String) async {
        guard let item = player.currentItem else { return }

        await MainActor.run {
            item.preferredForwardBufferDuration = 1.0
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        }
        defer {
            if !visibleVideoMids.contains(mediaID) {
                player.pause()
                item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            }
        }

        for _ in 0..<20 {
            if Task.isCancelled { return }
            let readyEnough = await MainActor.run {
                item.status == .readyToPlay || self.bufferedTimeAhead(for: player) >= 0.75
            }
            if readyEnough { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Decode one real frame from a preloaded AVPlayer and cache it as the poster.
    /// AVAssetImageGenerator is unreliable for some local-HLS/proxy assets until
    /// playback has decoded media, so this path prerolls the muted off-screen player
    /// and grabs a pixel buffer before the cell scrolls into view.
    private func generateDecodedPreloadFrame(from player: AVPlayer, for mediaID: String) async -> Bool {
        guard cachedThumbnail(for: mediaID) == nil,
              let item = player.currentItem else { return cachedThumbnail(for: mediaID) != nil }

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        item.add(output)
        defer { item.remove(output) }

        player.isMuted = true
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        defer {
            player.pause()
            if !visibleVideoMids.contains(mediaID) {
                item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            }
        }

        if item.status != .readyToPlay {
            guard await waitForPreloadReadyAsset(player, mediaID: mediaID) != nil else { return false }
        }

        let currentSeconds = player.currentTime().seconds
        if !currentSeconds.isFinite || currentSeconds < 0.05 {
            _ = await seek(player, to: .zero)
        }

        _ = await preroll(player, atRate: 0.1)

        for _ in 0..<20 {
            if Task.isCancelled { return false }
            if let image = copyPreloadFrame(from: output, player: player),
               !VideoFrameExtractor.isMostlyBlack(image) {
                storeCachedThumbnail(image, for: mediaID, source: "preload")
                player.pause()
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        player.pause()
        return false
    }

    private func copyPreloadFrame(from output: AVPlayerItemVideoOutput, player: AVPlayer) -> UIImage? {
        let current = player.currentTime()
        let hostTime = output.itemTime(forHostTime: CACurrentMediaTime())
        var candidates: [CMTime] = []

        if current.isValid {
            candidates.append(current)
            let offsets: [Double] = [0.05, 0.10, 0.25, 0.5]
            for offset in offsets {
                candidates.append(CMTime(seconds: max(0, current.seconds + offset), preferredTimescale: 600))
            }
        }
        if hostTime.isValid {
            candidates.append(hostTime)
        }

        var displayTime = CMTime.zero
        for time in candidates {
            guard time.isValid,
                  let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayTime),
                  let image = VideoFrameExtractor.makeDownscaledUIImage(from: pixelBuffer, maxDimension: 480) else {
                continue
            }
            return image
        }
        return nil
    }

    private func seek(_ player: AVPlayer, to time: CMTime) async -> Bool {
        await withCheckedContinuation { continuation in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                continuation.resume(returning: finished)
            }
        }
    }

    private func preroll(_ player: AVPlayer, atRate rate: Float) async -> Bool {
        await withCheckedContinuation { continuation in
            player.preroll(atRate: rate) { finished in
                continuation.resume(returning: finished)
            }
        }
    }

    /// Wait briefly for a preloaded player to decode enough metadata for a poster frame.
    /// The task is cancellable, so stale scroll-direction preloads still stop promptly.
    private func waitForPreloadReadyAsset(_ player: AVPlayer, mediaID: String) async -> AVAsset? {
        for _ in 0..<80 {
            if Task.isCancelled { return nil }

            let state = await MainActor.run { () -> (asset: AVAsset?, failed: Bool) in
                guard let item = player.currentItem else { return (nil, true) }
                if item.status == .readyToPlay { return (item.asset, false) }
                if item.status == .failed { return (nil, true) }
                return (nil, false)
            }

            if let asset = state.asset { return asset }
            if state.failed { return nil }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// Generate and cache a first-frame thumbnail from a video asset.
    private func generateThumbnail(from asset: AVAsset, for mediaID: String) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let times = [0.0, 0.1, 0.5, 1.0].map {
            NSValue(time: CMTime(seconds: $0, preferredTimescale: 600))
        }
        generator.generateCGImagesAsynchronously(forTimes: times) { _, cgImage, _, result, _ in
            guard result == .succeeded, let cgImage else { return }
            let image = UIImage(cgImage: cgImage)
            Task { @MainActor in
                guard self.cachedThumbnail(for: mediaID) == nil else { return }
                self.storeCachedThumbnail(image, for: mediaID, source: "preload")
            }
        }
    }

    private func bufferedTimeAhead(for player: AVPlayer) -> Double {
        guard let item = player.currentItem else { return 0 }
        let currentSeconds = player.currentTime().seconds
        guard currentSeconds.isFinite else { return 0 }

        var bestBufferAhead: Double = 0
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let duration = range.duration.seconds
            guard start.isFinite, duration.isFinite else { continue }
            let end = start + duration
            if currentSeconds >= start && currentSeconds <= end {
                return max(0, end - currentSeconds)
            } else if end > currentSeconds {
                bestBufferAhead = max(bestBufferAhead, end - currentSeconds)
            }
        }
        return bestBufferAhead
    }

    /// Read a cached thumbnail for mediaID. Filters/clears dark frames so callers
    /// never treat black snapshots as valid poster images.
    func cachedThumbnail(for mediaID: String) -> UIImage? {
        return VideoLastFrameCache.shared.image(for: mediaID)
    }

    func hasPreloadedThumbnail(for mediaID: String) -> Bool {
        guard cachedThumbnail(for: mediaID) != nil else {
            preloadedThumbnailMids.remove(mediaID)
            return false
        }
        return preloadedThumbnailMids.contains(mediaID)
    }

    /// Update cached thumbnail from a runtime-captured frame (pause/stop/scroll-out).
    /// Keeps the poster in sync with the last meaningful frame so re-entry resumes visually.
    func updateCachedThumbnail(_ image: UIImage, for mediaID: String) {
        storeCachedThumbnail(image, for: mediaID, source: "runtime")
    }

    /// Generate a thumbnail from a cached asset if no thumbnail exists yet.
    /// Calls completion on main thread with the generated image, or does nothing if asset isn't cached.
    func generateThumbnailIfNeeded(for mediaID: String, completion: @escaping @MainActor (UIImage) -> Void) {
        guard cachedThumbnail(for: mediaID) == nil else { return }
        guard let asset = assetCache[mediaID] else { return }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let times = [0.0, 0.1, 0.5, 1.0].map {
            NSValue(time: CMTime(seconds: $0, preferredTimescale: 600))
        }
        generator.generateCGImagesAsynchronously(forTimes: times) { _, cgImage, _, result, _ in
            guard result == .succeeded, let cgImage else { return }
            let image = UIImage(cgImage: cgImage)
            Task { @MainActor in
                guard self.cachedThumbnail(for: mediaID) == nil else { return }
                self.storeCachedThumbnail(image, for: mediaID, source: "cached-asset")
                completion(image)
            }
        }
    }

    private func storeCachedThumbnail(_ image: UIImage, for mediaID: String, source: String) {
        guard !VideoFrameExtractor.isMostlyBlack(image) else { return }
        VideoLastFrameCache.shared.set(image, for: mediaID)
        if source == "preload" {
            preloadedThumbnailMids.insert(mediaID)
        } else {
            preloadedThumbnailMids.remove(mediaID)
        }
        NotificationCenter.default.post(
            name: .videoThumbnailCached,
            object: self,
            userInfo: ["mediaID": mediaID]
        )
        if source == "preload" {
            print("🖼️ [PLAYER PRELOAD] Generated thumbnail for \(mediaID)")
        }
    }

    /// Update off-screen preload protection — called when scroll direction changes.
    /// Protects active directional player preloads from generic visibility cleanup.
    /// NodeConnectionPool manages their bandwidth.
    func updateProtectedPreloadMids(_ mids: Set<String>) {
        let now = Date()
        expirePreloadGrace(now: now)
        let previousProtectedCount = protectedPreloadMids.count
        let previousDirectionalCachedMids = protectedPreloadMids.intersection(playerCache.keys)
        protectedPreloadMids = mids

        let newSet = mids.intersection(playerCache.keys)
        for mediaID in previousDirectionalCachedMids.subtracting(newSet) {
            protectPreloadedPlayerBriefly(mediaID, now: now)
        }

        let previousCount = preloadedPlayerMids.count
        preloadedPlayerMids = newSet.union(preloadedPlayerGraceExpirations.keys)
        let newCount = preloadedPlayerMids.count
        if newCount != previousCount || protectedPreloadMids.count != previousProtectedCount {
            print("🔮 [PLAYER PRELOAD] Protected targets: \(protectedPreloadMids.count), cached players: \(newCount) (was \(previousCount))")
        }
    }

    /// Backward-compatible wrapper for callers that only track player preloads.
    func updatePreloadedPlayerMids(_ mids: Set<String>) {
        updateProtectedPreloadMids(mids)
    }

    /// Cancel preload for specific URL
    func cancelPreload(for url: URL, mediaID explicitMediaID: String? = nil) {
        // Use mediaID as cache key (stable identifier), not URL which can change
        guard let mediaID = explicitMediaID ?? extractMediaID(from: url) else { return }
        cancelPreloadTask(for: mediaID)
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

        let playersToRelease = playerCache.values

        // Release each player properly
        for player in playersToRelease {
            releasePlayer(player)
        }

        // Clear all caches
        playerCache.removeAll()
        cachingPlayerItems.removeAll()
        resourceLoaderDelegates.removeAll()

        // Keep timestamps and asset cache for faster recovery

    }

    /// MEMORY FIX: Force immediate cleanup of old/inactive players to release memory during fast scrolling
    @MainActor func forceMemoryCleanup() {
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


        if !oldKeys.isEmpty {

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
        }
    }
    
    /// Release ALL feed cached players and cancel all creation tasks.
    /// Called when entering a new screen (e.g. chat) to free AVPlayer decode sessions.
    /// Clears feed visibility state first since the feed is no longer on screen.
    @MainActor func releaseAllFeedPlayers() {
        // Clear feed visibility state — feed is no longer on screen
        let previousVisible = visibleVideoMids.count
        let previousPreloaded = max(preloadedPlayerMids.count, protectedPreloadMids.count)
        visibleVideoMidCounts.removeAll()
        preloadedPlayerMids.removeAll()
        protectedPreloadMids.removeAll()

        // 1. Release ALL cached players to free decode sessions
        var releasedCount = 0
        for (_, player) in playerCache {
            releasePlayer(player)
            releasedCount += 1
        }
        playerCache.removeAll()
        cacheTimestamps.removeAll()
        cachingPlayerItems.removeAll()
        resourceLoaderDelegates.removeAll()
        tweetUrlMapping.removeAll()

        // 2. Cancel all active creation tasks
        var cancelledActive = 0
        for (_, task) in activeCreationTasks {
            task.cancel()
            cancelledActive += 1
        }

        print("🔄 [SharedAssetCache] releaseAllFeedPlayers: released \(releasedCount) cached (was \(previousVisible) visible, \(previousPreloaded) preloaded), cancelled \(cancelledActive) active")
    }

    private func managePlayerCacheSize(reserveSlots: Int = 0) {
        // Normal LRU eviction - enforce cache size limits
        let targetSize = maxPlayerCacheSize - reserveSlots
        if playerCache.count > targetSize {

            // CRITICAL: Never evict visible or near-visible videos while app is in foreground
            let protected = foregroundProtectedMids
            let sortedKeys = cacheTimestamps
                .filter { !protected.contains($0.key) } // Skip protected videos
                .sorted { $0.value < $1.value }
                .map { $0.key }
            let keysToRemove = sortedKeys.prefix(playerCache.count - targetSize)

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
        }

        // REMOVED: Time-based inactive cleanup (was 15s threshold)
        // Reason: Too aggressive during scrolling - causes videos to reload when scrolling back
        // Cache size is already managed by LRU eviction above (Constants.MAX_PLAYER_CACHE_SIZE)
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
        if memoryUsageMB > 1500 {  // Foreground can use more memory; background releases aggressively
            // Check cooldown to prevent repeated cleanups
            if let lastWarning = lastMemoryWarningTime,
               Date().timeIntervalSince(lastWarning) < memoryWarningCooldown {
                // Still in cooldown period
                return
            }

            lastMemoryWarningTime = Date()
            handleMemoryWarning()
        } else if memoryUsageMB > 1200 {
            // Only log when approaching concerning levels, don't trigger cleanup yet
        } else {
            // Log current memory state periodically for visibility
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

        // iOS sends memory warnings even at very low usage (other apps need memory).
        // Nothing meaningful to reclaim below 900MB; foreground media caches can stay useful.
        guard memoryUsageMB > 900 else { return }

        let cacheSize = playerCache.count
        print("🚨 [SYSTEM MEMORY WARNING] iOS triggered - memory: \(memoryUsageMB)MB, cache: \(cacheSize) players")

        if UploadProgressManager.shared.isProcessingVideo {
            print("⚠️ [SYSTEM MEMORY WARNING] Video upload in progress, skipping cleanup")
            return
        }

        // Only perform aggressive cleanup if memory usage exceeds 1.5GB
        if memoryUsageMB > 1500 {
            print("🧹 [SYSTEM MEMORY WARNING] High usage detected, performing aggressive cleanup")
            cancelAllLoadingTasks()
            releasePartialCache(percentage: 60)

            let memoryAfter = getMemoryUsageString()
            print("✅ [SYSTEM MEMORY WARNING] Cleanup completed (memory: \(memoryUsageMB)MB → \(memoryAfter))")
        } else {
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

        if memoryUsageMB > 1500 {
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
        
        for task in loadingTasks.values {
            task.cancel()
        }
        loadingTasks.removeAll()
        for task in preloadTasks.values {
            task.cancel()
        }
        preloadTasks.removeAll()
        for task in inFlightPlayerCreations.values {
            task.cancel()
        }
        inFlightPlayerCreations.removeAll()
        for task in activeCreationTasks.values {
            task.cancel()
        }
        activeCreationTasks.removeAll()
        activeVideoLoadTickets.removeAll()
        
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
    
    /// Lightweight pause for immediate background entry — keeps player items intact.
    /// Players can resume instantly on quick foreground return without server restart.
    func pauseAllPlayers() {
        for (_, player) in playerCache {
            player.pause()
        }
    }

    /// Clear video players for background recovery after long background periods
    /// This is called when app returns from extended background (>5 minutes)
    /// Release video memory but keep AVPlayer shells for fast recovery
    /// This releases heavy video buffers while preserving player objects for quick resume
    func releaseVideoMemoryButKeepPlayers() {

        // Pause all players and detach their items to release video buffers
        // This releases the heavy memory (decoded frames, buffered data) but keeps the AVPlayer objects
        for (mediaID, player) in playerCache {
            savePlaybackPositionForBackground(mediaID: mediaID, player: player)
            player.pause()
            player.replaceCurrentItem(with: nil) // Releases video buffers and assets
        }
        // DON'T remove from playerCache - keep the shells for fast recovery

        // Clear CachingPlayerItem instances - they hold heavy references
        cachingPlayerItems.removeAll()

        // Clear assets - they contain the heavy video data
        assetCache.removeAll()

        // Cancel loading tasks to prevent memory usage during background
        cancelAllLoadingTasks()

        // Clear resource loader delegates — they can retain URLSession/loading state
        resourceLoaderDelegates.removeAll()

        // Keep playerCache, cacheTimestamps for fast recovery
    }

    /// Release foreground media memory when the app enters background.
    /// Disk caches stay intact, but decoded players/assets and active network work are dropped
    /// so iOS has much less reason to terminate the suspended app.
    @MainActor func releaseForBackground() {
        let playerCount = playerCache.count
        let assetCount = assetCache.count
        let protectedVisibleMids = visibleVideoMids

        var mediaIDsToCancel = Set<String>()
        mediaIDsToCancel.formUnion(playerCache.keys)
        mediaIDsToCancel.formUnion(assetCache.keys)
        mediaIDsToCancel.formUnion(cachingPlayerItems.keys)
        mediaIDsToCancel.formUnion(loadingTasks.keys)
        mediaIDsToCancel.formUnion(preloadTasks.keys)
        mediaIDsToCancel.formUnion(inFlightPlayerCreations.keys)
        mediaIDsToCancel.formUnion(activeCreationTasks.keys)
        mediaIDsToCancel.formUnion(visibleVideoMids)
        mediaIDsToCancel.formUnion(preloadedPlayerMids)
        mediaIDsToCancel.formUnion(protectedPreloadMids)
        for ids in tweetUrlMapping.values {
            mediaIDsToCancel.formUnion(ids)
        }
        mediaIDsToCancel.subtract(protectedVisibleMids)

        cancelAllLoadingTasks()

        for item in cachingPlayerItems.values {
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            item.asset.cancelLoading()
        }

        for mediaID in mediaIDsToCancel {
            LocalHTTPServer.shared.cancelDownloads(for: mediaID)
        }

        for (mediaID, player) in playerCache {
            savePlaybackPositionForBackground(mediaID: mediaID, player: player)
            if protectedVisibleMids.contains(mediaID) {
                player.pause()
                player.isMuted = MuteState.shared.isMuted
            } else {
                releasePlayer(player)
            }
        }

        playerCache = playerCache.filter { protectedVisibleMids.contains($0.key) }
        assetCache = assetCache.filter { protectedVisibleMids.contains($0.key) }
        cacheTimestamps = cacheTimestamps.filter { protectedVisibleMids.contains($0.key) }
        cachingPlayerDelegates = cachingPlayerDelegates.filter { protectedVisibleMids.contains($0.key) }
        cachingPlayerItems = cachingPlayerItems.filter { protectedVisibleMids.contains($0.key) }
        resourceLoaderDelegates = resourceLoaderDelegates.filter { protectedVisibleMids.contains($0.key) }
        tweetUrlMapping = tweetUrlMapping
            .mapValues { $0.intersection(protectedVisibleMids) }
            .filter { !$0.value.isEmpty }
        diskCacheStatus = diskCacheStatus.filter { protectedVisibleMids.contains($0.key) }

        preloadedPlayerMids.removeAll()
        protectedPreloadMids.removeAll()
        preloadedPlayerGraceExpirations.removeAll()

        let preservedCount = playerCache.count
        print("🌙 [SharedAssetCache] Background release: \(playerCount) players (\(preservedCount) visible preserved), \(assetCount) assets, \(mediaIDsToCancel.count) media downloads")
    }

    func clearVideoPlayersForBackgroundRecovery() {
        // Clear all cached players - they may have invalid video layers
        // Players will be recreated on demand with fresh video layers
        for (mediaID, player) in playerCache {
            savePlaybackPositionForBackground(mediaID: mediaID, player: player)
            player.pause()
            player.replaceCurrentItem(with: nil) // CRITICAL: Detach the item to invalidate layer
        }
        playerCache.removeAll()

        // Clear CachingPlayerItem instances - they hold references to old players
        cachingPlayerItems.removeAll()

        // CRITICAL: Also clear assets - they can have stale video layers after backgrounding
        assetCache.removeAll()

        // Clear loading tasks to force fresh loads
        cancelAllLoadingTasks()

        // CRITICAL: Clear disk cache status so videos will reload fresh from network
        diskCacheStatus.removeAll()

        // Keep resourceLoaderDelegates - they're needed for HLS playback
        // Keep cacheTimestamps - they track cache expiration
        // Keep HLS disk cache - playlists now use relative paths (port-independent!)
    }

    private func savePlaybackPositionForBackground(mediaID: String, player: AVPlayer) {
        let wasPlaying = player.rate > 0 || player.timeControlStatus == .playing
        FeedVideoResumeStore.save(mid: mediaID, player: player, wasPlaying: wasPlaying)
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
        hlsExtensions = metadata.hlsExtensions
    }

    /// Save cache metadata to UserDefaults
    private func saveCacheMetadata() {
        let metadata = CacheMetadata(cachedMediaIDs: cacheTimestamps, hlsExtensions: hlsExtensions)
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
            
            // Force a seek to refresh the video layer. Do not preroll here; these
            // players may be paused background/preload instances, and playback
            // ownership belongs to the active cell/coordinator.
            let currentTime = player.currentTime()
            player.seek(to: currentTime)
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
