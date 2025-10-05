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
    }
    
    // MARK: - Cache Storage
    private var assetCache: [String: AVAsset] = [:] // mediaID -> AVAsset
    private var playerCache: [String: AVPlayer] = [:] // mediaID -> AVPlayer
    private var cacheTimestamps: [String: Date] = [:] // mediaID -> timestamp
    private var cachingPlayerDelegates: [String: CachingPlayerItemDelegateImpl] = [:] // mediaID -> Delegate
    private var loadingTasks: [String: Task<AVAsset, Error>] = [:] // mediaID -> loading task
    private var preloadTasks: [String: Task<Void, Never>] = [:] // mediaID -> preload task
    private var tweetUrlMapping: [String: Set<String>] = [:] // tweetId -> Set of mediaIDs
    
    // MARK: - Configuration
    private let maxCacheSize = 30 // Maximum number of cached assets and players (reduced for memory)
    private let maxPlayerCacheSize = 10 // Maximum cached players (separate limit)
    private let cacheExpirationInterval: TimeInterval = 1800 // 30 minutes
    private let maxVideoFileSize: Int64 = 50 * 1024 * 1024 // 50MB max per video file
    
    // MARK: - Cache Persistence
    private let cacheMetadataKey = "SharedAssetCache_Metadata"
    
    // MARK: - Background Cleanup
    private var cleanupTimer: Timer?
    private var memoryMonitorTimer: Timer?
    
    private func startBackgroundCleanup() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                self.performCleanup()
            }
        }
    }
    
    private func startMemoryMonitoring() {
        // Monitor memory every 10 seconds to catch rapid memory growth
        memoryMonitorTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in
                self.checkMemoryPressure()
            }
        }
    }
    
    private func performCleanup() {
        let now = Date()
        let expiredKeys = cacheTimestamps.filter { now.timeIntervalSince($0.value) > cacheExpirationInterval }.map { $0.key }
        
        for key in expiredKeys {
            assetCache.removeValue(forKey: key)
            playerCache.removeValue(forKey: key)
            cacheTimestamps.removeValue(forKey: key)
        }
        
        // Manage cache size
        manageCacheSize()
    }
    
    // MARK: - Asset Management
    
    /// Cancel loading tasks for a specific URL
    @MainActor func cancelLoading(for mediaID: String) {
        // Cancel loading task if exists
        if let loadingTask = loadingTasks[mediaID] {
            loadingTask.cancel()
            loadingTasks.removeValue(forKey: mediaID)
            print("DEBUG: [SharedAssetCache] Cancelled loading task for mediaID: \(mediaID)")
        }
        
        // Cancel preload task if exists
        if let preloadTask = preloadTasks[mediaID] {
            preloadTask.cancel()
            preloadTasks.removeValue(forKey: mediaID)
            print("DEBUG: [SharedAssetCache] Cancelled preload task for mediaID: \(mediaID)")
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
    
    /// Cancel all loading tasks for a tweet
    @MainActor func cancelLoadingForTweet(_ tweetId: String) {
        // Find all mediaIDs associated with this tweet and cancel their loading
        let tweetMediaIDs = getMediaIDsForTweet(tweetId)
        for mediaID in tweetMediaIDs {
            cancelLoading(for: mediaID)
        }
        print("DEBUG: [SharedAssetCache] Cancelled all loading tasks for tweet \(tweetId)")
    }
    
    /// Trigger video preloading for a tweet
    @MainActor func triggerVideoPreloadingForTweet(_ tweetId: String) {
        // Find all mediaIDs associated with this tweet and trigger preloading
        let tweetMediaIDs = getMediaIDsForTweet(tweetId)
        for mediaID in tweetMediaIDs {
            // We need to reconstruct the URL from mediaID for preloading
            // This is a limitation - we might need to store URLs separately for preloading
            print("DEBUG: [SharedAssetCache] Cannot preload video for mediaID \(mediaID) without URL")
        }
        print("DEBUG: [SharedAssetCache] Triggered video preloading for tweet \(tweetId) with \(tweetMediaIDs.count) mediaIDs")
    }
    
    /// Extract mediaID from URL
    private func extractMediaID(from url: URL) -> String? {
        let urlString = url.absoluteString
        print("DEBUG: [SHARED ASSET CACHE] extractMediaID called for URL: \(urlString)")
        
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
            throw NSError(domain: "SharedAssetCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot extract mediaID from URL: \(url)"])
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
            let asset = AVURLAsset(url: resolvedURL)
            
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
        print("DEBUG: [SHARED ASSET CACHE] Cleared asset cache for mediaID: \(mediaID)")
    }
    
    /// Get cached player or create new one with asset
    func getOrCreatePlayer(for url: URL, tweetId: String? = nil, mediaType: MediaType? = nil) async throws -> AVPlayer {
        guard let mediaID = extractMediaID(from: url) else {
            throw NSError(domain: "SharedAssetCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot extract mediaID from URL: \(url)"])
        }
        
        NSLog("DEBUG: [SHARED ASSET CACHE] getOrCreatePlayer called for URL: \(url.absoluteString), mediaID: \(mediaID), mediaType: \(mediaType?.rawValue ?? "nil")")
        NSLog("DEBUG: [SHARED ASSET CACHE] getOrCreatePlayer called for tweetId: \(tweetId ?? "nil")")
        
        // Try to get cached player first
        if let cachedPlayer = await MainActor.run(body: { getCachedPlayer(for: mediaID) }) {
            print("DEBUG: [SHARED ASSET CACHE] Returning cached player for mediaID: \(mediaID)")
            return cachedPlayer
        }
        
        // Use MediaType to determine video type if available, otherwise fall back to URL-based detection
        let isHLSVideo: Bool
        if let mediaType = mediaType {
            isHLSVideo = (mediaType == .hls_video)
            print("DEBUG: [SHARED ASSET CACHE] Using MediaType to determine video type - isHLSVideo: \(isHLSVideo)")
        } else {
            // Fallback to URL-based detection for backward compatibility
            let urlString = url.absoluteString
            isHLSVideo = urlString.hasSuffix(".m3u8")
            print("DEBUG: [SHARED ASSET CACHE] Using URL-based detection - hasSuffix(.m3u8): \(isHLSVideo)")
        }
        
        if isHLSVideo {
            // Use CachingPlayerItem for HLS videos
            NSLog("DEBUG: [SHARED ASSET CACHE] Using CachingPlayerItem for HLS video: \(url.absoluteString)")
            return try await createCachingPlayer(for: url, tweetId: tweetId)
        } else {
            // Use regular AVPlayerItem for progressive videos
            NSLog("DEBUG: [SHARED ASSET CACHE] Using regular AVPlayerItem for progressive video: \(url.absoluteString)")
            let asset = try await getAsset(for: url, tweetId: tweetId)
            let playerItem = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: playerItem)
            
            // Cache the player for future use
            await MainActor.run { cachePlayer(player, for: mediaID) }
            
            return player
        }
    }
    
    /// Create CachingPlayerItem for HLS videos
    private func createCachingPlayer(for url: URL, tweetId: String?) async throws -> AVPlayer {
        guard let mediaID = extractMediaID(from: url) else {
            throw NSError(domain: "SharedAssetCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot extract mediaID from URL: \(url)"])
        }
        
        NSLog("DEBUG: [SHARED ASSET CACHE] Creating CachingPlayerItem for HLS video: \(url.absoluteString), mediaID: \(mediaID)")
        
        // Check if HLS content is already cached
        if CachingPlayerItem.isHLSCached(for: mediaID) {
            NSLog("DEBUG: [SHARED ASSET CACHE] HLS content already cached for mediaID: \(mediaID), using cached version")
            
            // Resolve the HLS URL to get the actual playlist URL (master.m3u8 or playlist.m3u8)
            let resolvedURL = await resolveHLSURL(url)
            print("DEBUG: [SHARED ASSET CACHE] Resolved HLS URL for cached content: \(resolvedURL.absoluteString)")
            
            // Create a unique save path for the HLS playlist
            let savePath = CachingPlayerItem.hlsPlaylistPath(for: mediaID)
            
            // Start LocalHTTPServer and register media
            LocalHTTPServer.shared.start()
            // Create media-specific directory path for LocalHTTPServer
            let cacheDir = URL(fileURLWithPath: savePath).deletingLastPathComponent()
            let mediaCacheDir = cacheDir.appendingPathComponent(mediaID)
            LocalHTTPServer.shared.registerMedia(mediaID: mediaID, cachePath: mediaCacheDir.path)
            
            // Create CachingPlayerItem with the RESOLVED HLS URL (not the LocalHTTPServer URL)
            let cachingPlayerItem = CachingPlayerItem(url: resolvedURL, saveFilePath: savePath, customFileExtension: "m3u8", avUrlAssetOptions: nil, isHLS: true, mediaID: mediaID)
            
            // Create and store delegate for caching events
            let delegate = CachingPlayerItemDelegateImpl()
            cachingPlayerItem.delegate = delegate
            
            // Store the delegate to prevent deallocation
            let cacheKey = url.absoluteString
            await MainActor.run { cachingPlayerDelegates[cacheKey] = delegate }
            
            // Create player with CachingPlayerItem
            let player = AVPlayer(playerItem: cachingPlayerItem)
            
            // Cache the player for future use
            await MainActor.run { cachePlayer(player, for: mediaID) }
            
            return player
        } else {
            NSLog("DEBUG: [SHARED ASSET CACHE] HLS content not cached for mediaID: \(mediaID), will download and cache")
            
            // Resolve the HLS URL to get the actual playlist URL (master.m3u8 or playlist.m3u8)
            let resolvedURL = await resolveHLSURL(url)
            print("DEBUG: [SHARED ASSET CACHE] Resolved HLS URL for CachingPlayerItem: \(resolvedURL.absoluteString)")
            
            // Create a unique save path for the HLS playlist
            let savePath = CachingPlayerItem.hlsPlaylistPath(for: mediaID)
            
            // Start LocalHTTPServer and register media
            LocalHTTPServer.shared.start()
            // Create media-specific directory path for LocalHTTPServer
            let cacheDir = URL(fileURLWithPath: savePath).deletingLastPathComponent()
            let mediaCacheDir = cacheDir.appendingPathComponent(mediaID)
            LocalHTTPServer.shared.registerMedia(mediaID: mediaID, cachePath: mediaCacheDir.path)
            
            // Create CachingPlayerItem with the RESOLVED HLS URL (not the LocalHTTPServer URL)
            let cachingPlayerItem = CachingPlayerItem(url: resolvedURL, saveFilePath: savePath, customFileExtension: "m3u8", avUrlAssetOptions: nil, isHLS: true, mediaID: mediaID)
            
            // Create and store delegate for caching events
            let delegate = CachingPlayerItemDelegateImpl()
            cachingPlayerItem.delegate = delegate
            
            // Store the delegate to prevent deallocation
            let cacheKey = url.absoluteString
            await MainActor.run { cachingPlayerDelegates[cacheKey] = delegate }
            
            // Create player with CachingPlayerItem
            let player = AVPlayer(playerItem: cachingPlayerItem)
            
            // Cache the player for future use
            await MainActor.run { cachePlayer(player, for: mediaID) }
            
            return player
        }
    }
    
    
    /// Resolve HLS URL with specific fallback strategy
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
        
        // HLS fallback strategy: master.m3u8 -> playlist.m3u8 -> retry once -> fail
        let masterURL = url.appendingPathComponent("master.m3u8")
        let playlistURL = url.appendingPathComponent("playlist.m3u8")
        
        print("DEBUG: [SharedAssetCache] Resolving HLS URL: \(url.absoluteString)")
        
        // First attempt: try master.m3u8, then playlist.m3u8
        if await urlExists(masterURL, timeout: 3.0) {
            print("DEBUG: [SharedAssetCache] Found master.m3u8 at: \(masterURL.absoluteString)")
            return masterURL
        }
        
        if await urlExists(playlistURL, timeout: 3.0) {
            print("DEBUG: [SharedAssetCache] Found playlist.m3u8 at: \(playlistURL.absoluteString)")
            return playlistURL
        }
        
        // Second attempt: retry the combo once more
        print("DEBUG: [SharedAssetCache] First attempt failed, retrying HLS URLs...")
        
        if await urlExists(masterURL, timeout: 3.0) {
            print("DEBUG: [SharedAssetCache] Retry successful - found master.m3u8 at: \(masterURL.absoluteString)")
            return masterURL
        }
        
        if await urlExists(playlistURL, timeout: 3.0) {
            print("DEBUG: [SharedAssetCache] Retry successful - found playlist.m3u8 at: \(playlistURL.absoluteString)")
            return playlistURL
        }
        
        // If both attempts fail, return original URL and let it fail
        print("DEBUG: [SharedAssetCache] HLS resolution failed for: \(url.absoluteString)")
        return url
    }
    
    /// Check if URL exists with configurable timeout
    private func urlExists(_ url: URL, timeout: TimeInterval = 3.0) async -> Bool {
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
    @MainActor func clearCache() {
        assetCache.removeAll()
        playerCache.removeAll()
        cacheTimestamps.removeAll()
        cachingPlayerDelegates.removeAll()
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll()
        preloadTasks.values.forEach { $0.cancel() }
        preloadTasks.removeAll()
        
        // Save empty cache metadata
        saveCacheMetadata()
    }
    
    /// Clear all caches (emergency cleanup)
    @MainActor func clearAllCaches() {
        print("DEBUG: [SharedAssetCache] Clearing all caches")
        
        // Pause and remove all cached players
        for (_, player) in playerCache {
            player.pause()
        }
        playerCache.removeAll()
        cachingPlayerDelegates.removeAll()
        
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
        
        print("DEBUG: [SharedAssetCache] All caches cleared")
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
        let cacheKey = url.absoluteString
        
        // Cancel existing preload task if any
        preloadTasks[cacheKey]?.cancel()
        
        let task = Task {
            do {
                _ = try await getOrCreatePlayer(for: url, tweetId: tweetId)
            } catch {
                // Handle error silently
            }
        }
        
        preloadTasks[cacheKey] = task
    }
    
    /// Preload asset only (for background loading - lower priority)
    func preloadAsset(for url: URL, tweetId: String? = nil) {
        let cacheKey = url.absoluteString
        
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
        let cacheKey = url.absoluteString
        preloadTasks[cacheKey]?.cancel()
        preloadTasks.removeValue(forKey: cacheKey)
    }
    
    /// Preload multiple videos with priority management
    func preloadVideos(_ urls: [URL], priority: PreloadPriority = .normal) {
        for (index, url) in urls.enumerated() {
            let delay = priority.delay(for: index)
            
            Task {
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
                    }
                }
            }
        }
    }
    
    private func managePlayerCacheSize() {
        if playerCache.count > maxPlayerCacheSize {
            // Remove least recently used players - do sorting on background thread
            Task.detached {
                let sortedKeys = await MainActor.run {
                    self.cacheTimestamps.sorted { $0.value < $1.value }.map { $0.key }
                }
                let keysToRemove = sortedKeys.prefix(await MainActor.run { self.playerCache.count - self.maxPlayerCacheSize })
                
                await MainActor.run {
                    for key in keysToRemove {
                        if let player = self.playerCache[key] {
                            // Pause player asynchronously
                            Task.detached {
                                player.pause()
                            }
                            self.playerCache.removeValue(forKey: key)
                            self.cacheTimestamps.removeValue(forKey: key)
                        }
                    }
                }
            }
        }
    }
    
    /// Get cache statistics
    @MainActor func getCacheStats() -> (assetCount: Int, playerCount: Int) {
        return (assetCache.count, playerCache.count)
    }
    
    /// Get current memory usage in bytes
    private func getCurrentMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return info.resident_size
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
                print("DEBUG: [SharedAssetCache] System memory warning received - performing aggressive cleanup")
                self?.handleMemoryWarning()
            }
        }
    }
    
    private func handleMemoryWarning() {
        // Check if memory usage exceeds 1GB before taking action
        let memoryUsage = getCurrentMemoryUsage()
        let memoryUsageMB = memoryUsage / (1024 * 1024)
        
        print("DEBUG: [SharedAssetCache] Memory warning - current usage: \(memoryUsageMB)MB")
        
        // Only release cache if memory usage exceeds 1GB
        if memoryUsageMB > 1024 {
            print("DEBUG: [SharedAssetCache] Memory usage exceeds 1GB, releasing 30% of cache")
            // Release 30% of cache (less aggressive)
            releasePartialCache(percentage: 30)
        } else {
            print("DEBUG: [SharedAssetCache] Memory usage under 1GB, no action needed")
        }
        
        // Don't cancel ongoing loadings - let them complete for better UX
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
        refreshCachedPlayers()
    }
    
    private func handleAppDidBecomeActive() {
        // Use Task to avoid potential MainActor deadlock
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
            self.refreshCachedPlayers()
        }
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
        
        // Check which cached files still exist on disk
        var validMediaIDs: [String: Date] = [:]
        for (mediaID, timestamp) in metadata.cachedMediaIDs {
            // Check if HLS video is still cached
            if CachingPlayerItem.isHLSCached(for: mediaID) {
                validMediaIDs[mediaID] = timestamp
                print("DEBUG: [SHARED ASSET CACHE] HLS video still cached: \(mediaID)")
            } else {
                // For progressive videos, check if file exists
                guard let cachesDirectory = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
                    continue
                }
                let cachePath = cachesDirectory.appendingPathComponent("\(mediaID).mp4").path
                if FileManager.default.fileExists(atPath: cachePath) {
                    validMediaIDs[mediaID] = timestamp
                    print("DEBUG: [SHARED ASSET CACHE] Progressive video still cached: \(mediaID)")
                }
            }
        }
        
        cacheTimestamps = validMediaIDs
        print("DEBUG: [SHARED ASSET CACHE] Restored \(validMediaIDs.count) valid cached entries")
    }
    
    /// Save cache metadata to UserDefaults
    private func saveCacheMetadata() {
        let metadata = CacheMetadata(cachedMediaIDs: cacheTimestamps)
        if let data = try? JSONEncoder().encode(metadata) {
            UserDefaults.standard.set(data, forKey: cacheMetadataKey)
            print("DEBUG: [SHARED ASSET CACHE] Saved cache metadata for \(cacheTimestamps.count) mediaIDs")
        }
    }
    
    
    private func refreshCachedPlayers() {
        // Refresh all cached players to ensure they show cached content
        for (_, player) in playerCache {
            // Force a seek to refresh the video layer
            let currentTime = player.currentTime()
            player.seek(to: currentTime) { _ in
                // Video layer should now be refreshed and showing cached content
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
