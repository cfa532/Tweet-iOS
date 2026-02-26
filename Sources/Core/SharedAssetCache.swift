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

        // Set up app lifecycle notifications
        setupAppLifecycleNotifications()

        // Set up memory warning notifications
        setupMemoryWarningNotifications()

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
    
    // MARK: - Configuration
    private let maxCacheSize = Constants.MAX_ASSET_CACHE_SIZE
    private let maxPlayerCacheSize = Constants.MAX_PLAYER_CACHE_SIZE
    private let maxConcurrentCreations = Constants.MAX_CONCURRENT_PLAYER_CREATIONS
    private let cacheExpirationInterval: TimeInterval = Constants.CACHE_EXPIRATION_SECONDS
    
    // MARK: - Player Creation Throttling
    private var activeCreations = 0
    private var activeCreationTasks: [String: Task<AVPlayer, Error>] = [:] // mediaID -> creation task (for cancellation)
    private var pendingCreations: [(url: URL, tweetId: String?, mediaType: MediaType?, isHighPriority: Bool, continuation: CheckedContinuation<AVPlayer, Error>)] = []
    private let maxPendingCreations = 10 // MEMORY LEAK FIX: Limit queue size to prevent unbounded continuation buildup
    
    // MARK: - Cache Persistence
    private let cacheMetadataKey = "SharedAssetCache_Metadata"
    private var hlsExtensions: [String: String] = [:] // mediaID -> "master.m3u8" or "playlist.m3u8"
    
    
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
    
    /// Check if content has been cached for a media ID
    @MainActor func hasCachedContent(for id: String) -> Bool {
        if assetCache[id] != nil || playerCache[id] != nil {
            return true
        }
        return false
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
    
    /// Get cached player if available — just return from cache and update timestamp
    func getCachedPlayer(for mediaID: String) -> AVPlayer? {
        if let player = playerCache[mediaID] {
            cacheTimestamps[mediaID] = Date() // Update access time
            return player
        }
        return nil
    }

    func removeInvalidPlayer(for mediaID: String, force: Bool = false) {
        playerCache.removeValue(forKey: mediaID)
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

        // Cancel any pending loading tasks
        if let task = loadingTasks.removeValue(forKey: mediaID) {
            task.cancel()
        }

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
    
    /// Get cached player or create new one with asset
    /// - Parameter isHighPriority: When true, can use reserved creation slots (for visible cells / detail views).
    ///   Preloads should pass false so they don't block visible content.
    func getOrCreatePlayer(for url: URL, tweetId: String? = nil, mediaType: MediaType? = nil, isHighPriority: Bool = true) async throws -> AVPlayer {
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
                // Player exists but item was cleared - reload the item into existing player
                do {
                    let playerItem = try await getOrCreatePlayerItem(for: url, mediaID: mediaID, mediaType: mediaType)
                    await MainActor.run {
                        cachedPlayer.replaceCurrentItem(with: playerItem)
                    }
                    return cachedPlayer
                } catch {
                    // Failed to reload item - fall through to create new player
                    // Remove broken shell from cache
                    await MainActor.run {
                        _ = playerCache.removeValue(forKey: cacheKey)
                    }
                }
            } else {
                return cachedPlayer
            }
        }

        // Throttle concurrent player creation to prevent memory spikes
        // Last reservedHighPrioritySlots slot(s) are reserved for high-priority (visible) requests
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                if self.canStartCreation(isHighPriority: isHighPriority) {
                    // Can create immediately
                    self.startCreationTask(url: url, tweetId: tweetId, mediaType: mediaType, continuation: continuation)
                } else if self.pendingCreations.count < self.maxPendingCreations {
                    // Queue for later — high priority goes to front, low priority to back
                    if isHighPriority {
                        self.pendingCreations.insert((url, tweetId, mediaType, true, continuation), at: 0)
                    } else {
                        self.pendingCreations.append((url, tweetId, mediaType, false, continuation))
                    }
                } else if isHighPriority, let lastLowIdx = self.pendingCreations.lastIndex(where: { !$0.isHighPriority }) {
                    // Queue is full but this is high-priority: evict oldest low-priority request to make room
                    let evicted = self.pendingCreations.remove(at: lastLowIdx)
                    print("⚠️ [SharedAssetCache] Evicting low-priority pending request to make room for high-priority")
                    evicted.continuation.resume(throwing: NSError(domain: "SharedAssetCache", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Evicted by higher priority request"]))
                    self.pendingCreations.insert((url, tweetId, mediaType, true, continuation), at: 0)
                } else {
                    // MEMORY LEAK FIX: Reject when queue is full to prevent unbounded continuation buildup
                    print("⚠️ [SharedAssetCache] Rejecting player creation - pending queue full (\(self.pendingCreations.count))")
                    continuation.resume(throwing: NSError(domain: "SharedAssetCache", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Player creation queue full"]))
                }
            }
        }
    }

    /// Check if a new player creation can start given priority-based slot reservation.
    /// Last slot is reserved for high-priority (visible) requests.
    @MainActor
    private func canStartCreation(isHighPriority: Bool) -> Bool {
        if isHighPriority {
            return activeCreations < maxConcurrentCreations
        }
        // Low priority (preloads): leave 2 slots reserved for visible content
        return activeCreations < maxConcurrentCreations - 2
    }

    /// Process next pending creation when a slot opens
    @MainActor
    private func processNextPendingCreation() {
        guard !pendingCreations.isEmpty else { return }

        let nextIsHighPriority = pendingCreations.first!.isHighPriority
        guard canStartCreation(isHighPriority: nextIsHighPriority) else { return }

        let next = pendingCreations.removeFirst()
        startCreationTask(url: next.url, tweetId: next.tweetId, mediaType: next.mediaType, continuation: next.continuation)
    }
    
    /// Start a tracked creation task, incrementing activeCreations and storing the Task for cancellation.
    @MainActor
    private func startCreationTask(url: URL, tweetId: String?, mediaType: MediaType?, continuation: CheckedContinuation<AVPlayer, Error>) {
        let mediaID = extractMediaID(from: url) ?? url.absoluteString
        activeCreations += 1
        let task = Task<AVPlayer, Error> {
            try await self.createPlayerNow(for: url, tweetId: tweetId, mediaType: mediaType)
        }
        activeCreationTasks[mediaID] = task
        Task {
            do {
                let player = try await task.value
                await MainActor.run {
                    self.activeCreations -= 1
                    self.activeCreationTasks.removeValue(forKey: mediaID)
                    self.processNextPendingCreation()
                }
                continuation.resume(returning: player)
            } catch {
                await MainActor.run {
                    self.activeCreations -= 1
                    self.activeCreationTasks.removeValue(forKey: mediaID)
                    self.processNextPendingCreation()
                }
                continuation.resume(throwing: error)
            }
        }
    }

    /// Actually create the player (called after throttling check)
    private func createPlayerNow(for url: URL, tweetId: String? = nil, mediaType: MediaType? = nil) async throws -> AVPlayer {
        guard let mediaID = extractMediaID(from: url) else {
            throw NSError(domain: "SharedAssetCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot extract mediaID"])
        }

        // Bail early if this creation was cancelled (e.g. by makeRoomForPlayers)
        try Task.checkCancellation()

        // Clean up cache BEFORE creating new player — evict to make room for incoming player
        await MainActor.run {
            self.managePlayerCacheSize(reserveSlots: 1)
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
                    BlackList.shared.recordSuccess(MimeiId(mediaID))
                }
                return player
            } catch {
                let isCancellation = (error as NSError).code == NSURLErrorCancelled || error is CancellationError
                if !isCancellation {
                    await MainActor.run {
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
                    BlackList.shared.recordSuccess(MimeiId(mediaID))
                }
                return player
            } catch {
                let isCancellation = (error as NSError).code == NSURLErrorCancelled || error is CancellationError
                if !isCancellation {
                    await MainActor.run {
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
        do {
            let player = try await createProgressivePlayer(for: url, mediaID: mediaID)
            return player
        } catch let originalError {
            print("🔄 [PROGRESSIVE VIDEO RETRY] Attempt #1 for: \(mediaID) - refreshing author baseUrl...")

            let refreshed = await refreshAuthorBaseUrlForVideo(mediaID: mediaID, originalUrl: url, tweetId: tweetId)

            if refreshed {
                print("✅ [PROGRESSIVE VIDEO RETRY] Author baseUrl refreshed successfully, retrying with new URL")
            } else {
                print("⚠️ [PROGRESSIVE VIDEO RETRY] Could not refresh author baseUrl, retrying anyway")
            }

            if Task.isCancelled {
                throw CancellationError()
            }

            return try await createProgressivePlayer(for: url, mediaID: mediaID)
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
        let player = AVPlayer(playerItem: playerItem)
        
        // CRITICAL: Mute player at creation - will be unmuted by mode if needed
        player.isMuted = true
        
        // Cache the player
        await MainActor.run { 
            cachePlayer(player, for: mediaID)
        }
        
        return player
    }
    
    /// Create HLS video player with ONE retry after refreshing author's baseUrl
    /// If it fails twice, it fails - no additional fallback attempts
    private func createCachingPlayerWithRetry(for url: URL, mediaID: String, tweetId: String?) async throws -> AVPlayer {
        do {
            let player = try await createCachingPlayer(for: url, tweetId: tweetId)
            return player
        } catch let originalError {
            print("🔄 [HLS VIDEO RETRY] Attempt #1 for: \(mediaID) - refreshing author baseUrl...")

            let refreshed = await refreshAuthorBaseUrlForVideo(mediaID: mediaID, originalUrl: url, tweetId: tweetId)

            if refreshed {
                print("✅ [HLS VIDEO RETRY] Author baseUrl refreshed successfully, retrying with new URL")
            } else {
                print("⚠️ [HLS VIDEO RETRY] Could not refresh author baseUrl, retrying anyway")
            }

            if Task.isCancelled {
                throw CancellationError()
            }

            do {
                return try await createCachingPlayer(for: url, tweetId: tweetId)
            } catch {
                print("❌ [HLS VIDEO] Failed after 1 retry with baseUrl refresh: \(mediaID)")
                throw error
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

        
        cachingPlayerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false  // Don't buffer when paused to avoid connection overload
        
        // Cache the player using mediaID (video attachment mid)
        await MainActor.run {
            cachePlayer(player, for: mediaID)
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

            // Resolve HLS URL, using persisted extension when available
            let resolvedURL: URL
            if let cachedFilename = hlsExtensions[extractedMediaID] {
                resolvedURL = url.appendingPathComponent(cachedFilename)
            } else {
                let networkResolvedURL = await resolveHLSURL(url)
                if networkResolvedURL != url {
                    hlsExtensions[extractedMediaID] = networkResolvedURL.lastPathComponent
                    saveCacheMetadata()
                }
                resolvedURL = networkResolvedURL
            }

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
        
        // Clear loading tasks
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll()
        
        // Clear preload tasks
        preloadTasks.values.forEach { $0.cancel() }
        preloadTasks.removeAll()

        // Clear timestamps
        cacheTimestamps.removeAll()

        // Clear HLS extension cache
        hlsExtensions.removeAll()

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
                _ = try await getOrCreatePlayer(for: url, isHighPriority: false)
            } catch {
                // Handle error silently
            }
        }

        preloadTasks[cacheKey] = task
    }

    /// Preload asset only (for background loading - lower priority)
    func preloadAsset(for url: URL, tweetId: String? = nil, mediaType: MediaType? = nil) {
        // Use mediaID as cache key (stable identifier), not URL which can change
        guard let mediaID = extractMediaID(from: url) else { return }
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
                _ = try await getAsset(for: url, tweetId: tweetId, mediaType: mediaType)
            } catch {
                // Handle error silently
            }
        }

        preloadTasks[cacheKey] = task
    }
    
    /// Preload player (not just asset) for upcoming video in scroll direction.
    /// Creates an AVPlayer, generates a first-frame thumbnail, and caches both
    /// so the cell has a poster image and an instantly-available player.
    func preloadPlayer(for url: URL, tweetId: String? = nil, mediaType: MediaType? = nil) {
        guard let mediaID = extractMediaID(from: url) else { return }

        // Skip if player already cached
        if playerCache[mediaID] != nil {
            // Still generate thumbnail if missing
            if cachedThumbnail(for: mediaID) == nil,
               let asset = assetCache[mediaID] {
                generateThumbnail(from: asset, for: mediaID)
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
                let player = try await getOrCreatePlayer(for: url, tweetId: tweetId, mediaType: mediaType, isHighPriority: false)
                // Pause immediately — this is a preloaded player, not for playback yet
                await MainActor.run {
                    player.pause()
                }
                // Generate first-frame thumbnail so the cell isn't black before playback
                if cachedThumbnail(for: mediaID) == nil,
                   let item = player.currentItem {
                    self.generateThumbnail(from: item.asset, for: mediaID)
                }
                print("🔮 [PLAYER PRELOAD] Pre-created player for \(mediaID)")
            } catch {
                // Preload failure is non-critical
            }
        }
        preloadTasks[mediaID] = task
    }

    /// Generate and cache a first-frame thumbnail from a video asset.
    private func generateThumbnail(from asset: AVAsset, for mediaID: String) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, result, _ in
            guard result == .succeeded, let cgImage else { return }
            let image = UIImage(cgImage: cgImage)
            DispatchQueue.main.async {
                VideoLastFrameCache.shared.set(image, for: mediaID)
                print("🖼️ [PLAYER PRELOAD] Generated thumbnail for \(mediaID)")
            }
        }
    }

    /// Read a cached thumbnail for mediaID. Filters/clears dark frames so callers
    /// never treat black snapshots as valid poster images.
    func cachedThumbnail(for mediaID: String) -> UIImage? {
        guard let image = VideoLastFrameCache.shared.image(for: mediaID) else { return nil }
        if VideoFrameExtractor.isMostlyBlack(image) {
            VideoLastFrameCache.shared.clear(for: mediaID)
            return nil
        }
        return image
    }

    /// Update cached thumbnail from a runtime-captured frame (pause/stop/scroll-out).
    /// Keeps the poster in sync with the last meaningful frame so re-entry resumes visually.
    func updateCachedThumbnail(_ image: UIImage, for mediaID: String) {
        guard !VideoFrameExtractor.isMostlyBlack(image) else { return }
        VideoLastFrameCache.shared.set(image, for: mediaID)
    }

    /// Generate a thumbnail from a cached asset if no thumbnail exists yet.
    /// Calls completion on main thread with the generated image, or does nothing if asset isn't cached.
    func generateThumbnailIfNeeded(for mediaID: String, completion: @escaping @MainActor (UIImage) -> Void) {
        guard cachedThumbnail(for: mediaID) == nil else { return }
        guard let asset = assetCache[mediaID] else { return }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, result, _ in
            guard result == .succeeded, let cgImage else { return }
            let image = UIImage(cgImage: cgImage)
            DispatchQueue.main.async {
                VideoLastFrameCache.shared.set(image, for: mediaID)
                completion(image)
            }
        }
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
        let ageThreshold: TimeInterval
        if memoryUsage > 1200 {
            ageThreshold = 10
        } else if memoryUsage > 1000 {
            ageThreshold = 30
        } else {
            ageThreshold = 60
        }

        let oldKeys = cacheTimestamps
            .filter { now.timeIntervalSince($0.value) > ageThreshold }
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
            }
        }
    }
    
    /// Release ALL feed cached players and cancel all creation tasks.
    /// Called when entering a new screen (e.g. chat) to free AVPlayer decode sessions.
    @MainActor func releaseAllFeedPlayers() {
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

        // 2. Cancel all pending creations
        var cancelledPending = 0
        for entry in pendingCreations {
            entry.continuation.resume(throwing: NSError(domain: "SharedAssetCache", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Released for incoming screen"]))
            cancelledPending += 1
        }
        pendingCreations.removeAll()

        // 3. Cancel all active creation tasks
        var cancelledActive = 0
        for (_, task) in activeCreationTasks {
            task.cancel()
            cancelledActive += 1
        }

        print("🔄 [SharedAssetCache] releaseAllFeedPlayers: released \(releasedCount) cached, cancelled \(cancelledPending) pending, cancelled \(cancelledActive) active")
    }

    private func managePlayerCacheSize(reserveSlots: Int = 0) {
        // Normal LRU eviction - enforce cache size limits
        let targetSize = maxPlayerCacheSize - reserveSlots
        if playerCache.count > targetSize {
            let sortedKeys = cacheTimestamps
                .sorted { $0.value < $1.value }
                .map { $0.key }
            let keysToRemove = sortedKeys.prefix(playerCache.count - targetSize)

            for key in keysToRemove {
                if let player = playerCache[key] {
                    releasePlayer(player)
                }
                playerCache.removeValue(forKey: key)
                cacheTimestamps.removeValue(forKey: key)
                cachingPlayerItems.removeValue(forKey: key)
                resourceLoaderDelegates.removeValue(forKey: key)
            }
        }
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
    
    /// Handle SYSTEM memory warning from iOS
    private func handleSystemMemoryWarning() {
        let memoryUsage = getCurrentMemoryUsage()
        let memoryUsageMB = memoryUsage / (1024 * 1024)
        let cacheSize = playerCache.count

        print("🚨 [SYSTEM MEMORY WARNING] iOS triggered - memory: \(memoryUsageMB)MB, cache: \(cacheSize) players")

        if UploadProgressManager.shared.isProcessingVideo {
            print("⚠️ [SYSTEM MEMORY WARNING] Video upload in progress, skipping cleanup")
            return
        }

        if memoryUsageMB > 1200 {
            print("🧹 [SYSTEM MEMORY WARNING] High usage detected, performing aggressive cleanup")
            cancelAllLoadingTasks()
            // Use LRU eviction via forceMemoryCleanup instead of percentage-based release
            forceMemoryCleanup()
            let memoryAfter = getMemoryUsageString()
            print("✅ [SYSTEM MEMORY WARNING] Cleanup completed (memory: \(memoryUsageMB)MB -> \(memoryAfter))")
        } else {
            print("ℹ️ [SYSTEM MEMORY WARNING] Memory usage moderate (\(memoryUsageMB)MB), light cleanup only")
            forceMemoryCleanup()
        }
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
        for (_, player) in playerCache {
            player.pause()
            player.replaceCurrentItem(with: nil) // Releases video buffers and assets
        }
        // DON'T remove from playerCache - keep the shells for fast recovery

        // Clear CachingPlayerItem instances - they hold heavy references
        cachingPlayerItems.removeAll()

        // Clear assets - they contain the heavy video data
        assetCache.removeAll()

        // Cancel loading tasks to prevent memory usage during background
        loadingTasks.removeAll()
        preloadTasks.removeAll()

        // Clear resource loader delegates — they can retain URLSession/loading state
        resourceLoaderDelegates.removeAll()

        // Keep playerCache, cacheTimestamps for fast recovery
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
