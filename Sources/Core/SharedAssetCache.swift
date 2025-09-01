//
//  SharedAssetCache.swift
//  Tweet
//
//  Shared asset cache for video players with background loading support
//

import Foundation
import AVFoundation
import UIKit

/// Shared asset cache for video players with background loading and priority management
@MainActor
class SharedAssetCache: ObservableObject {
    static let shared = SharedAssetCache()
    
    private init() {
        // Start background cleanup timer
        startBackgroundCleanup()
        
        // Set up app lifecycle notifications
        setupAppLifecycleNotifications()
    }
    
    // MARK: - Cache Storage
    private var assetCache: [String: AVAsset] = [:]
    private var playerCache: [String: AVPlayer] = [:]
    private var cacheTimestamps: [String: Date] = [:]
    private var loadingTasks: [String: Task<AVAsset, Error>] = [:]
    private var preloadTasks: [String: Task<Void, Never>] = [:]
    private var tweetUrlMapping: [String: Set<String>] = [:] // tweetId -> Set of URLs
    
    // MARK: - Configuration
    private let maxCacheSize = 50 // Maximum number of cached assets and players
    private let cacheExpirationInterval: TimeInterval = 300 // 5 minutes
    
    // MARK: - Background Cleanup
    private var cleanupTimer: Timer?
    
    private func startBackgroundCleanup() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                self.performCleanup()
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
    @MainActor func cancelLoading(for url: URL) {
        let cacheKey = url.absoluteString
        
        // Cancel loading task if exists
        if let loadingTask = loadingTasks[cacheKey] {
            loadingTask.cancel()
            loadingTasks.removeValue(forKey: cacheKey)
            print("DEBUG: [SharedAssetCache] Cancelled loading task for \(cacheKey)")
        }
        
        // Cancel preload task if exists
        if let preloadTask = preloadTasks[cacheKey] {
            preloadTask.cancel()
            preloadTasks.removeValue(forKey: cacheKey)
            print("DEBUG: [SharedAssetCache] Cancelled preload task for \(cacheKey)")
        }
    }
    
    /// Get URLs associated with a tweet
    private func getUrlsForTweet(_ tweetId: String) -> [URL] {
        guard let urlStrings = tweetUrlMapping[tweetId] else { return [] }
        return urlStrings.compactMap { URL(string: $0) }
    }
    
    /// Track URL for a tweet
    private func trackUrl(_ url: URL, for tweetId: String) {
        let urlString = url.absoluteString
        if tweetUrlMapping[tweetId] == nil {
            tweetUrlMapping[tweetId] = Set<String>()
        }
        tweetUrlMapping[tweetId]?.insert(urlString)
    }
    
    /// Cancel all loading tasks for a tweet
    @MainActor func cancelLoadingForTweet(_ tweetId: String) {
        // Find all URLs associated with this tweet and cancel their loading
        let tweetUrls = getUrlsForTweet(tweetId)
        for url in tweetUrls {
            cancelLoading(for: url)
        }
        print("DEBUG: [SharedAssetCache] Cancelled all loading tasks for tweet \(tweetId)")
    }
    
    /// Trigger video preloading for a tweet
    @MainActor func triggerVideoPreloadingForTweet(_ tweetId: String) {
        // Find all URLs associated with this tweet and trigger preloading
        let tweetUrls = getUrlsForTweet(tweetId)
        for url in tweetUrls {
            preloadVideo(for: url, tweetId: tweetId)
        }
        print("DEBUG: [SharedAssetCache] Triggered video preloading for tweet \(tweetId) with \(tweetUrls.count) URLs")
    }
    
    /// Get cached asset or create new one
    @MainActor func getAsset(for url: URL, tweetId: String? = nil) async throws -> AVAsset {
        let cacheKey = url.absoluteString
        
        // Track URL for tweet if provided
        if let tweetId = tweetId {
            trackUrl(url, for: tweetId)
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
    func cachePlayer(_ player: AVPlayer, for url: URL) {
        let cacheKey = url.absoluteString
        
        // Remove old player if exists - do this asynchronously to avoid blocking
        if let oldPlayer = playerCache[cacheKey] {
            Task.detached {
                oldPlayer.pause()
            }
        }
        
        playerCache[cacheKey] = player
        cacheTimestamps[cacheKey] = Date()
        
        // Manage cache size asynchronously
        Task.detached {
            await MainActor.run {
                self.managePlayerCacheSize()
            }
        }
    }
    
    /// Get cached player if available
    func getCachedPlayer(for url: URL) -> AVPlayer? {
        let cacheKey = url.absoluteString
        if let player = playerCache[cacheKey] {
            // Validate player before returning it
            guard let playerItem = player.currentItem else {
                print("DEBUG: [SHARED ASSET CACHE] Cached player has no currentItem, removing invalid player for: \(url)")
                removeInvalidPlayer(for: url)
                return nil
            }
            
            if playerItem.status == .failed {
                print("DEBUG: [SHARED ASSET CACHE] Cached player item is in failed state, removing invalid player for: \(url)")
                removeInvalidPlayer(for: url)
                return nil
            }
            
            cacheTimestamps[cacheKey] = Date() // Update access time
            return player
        }
        return nil
    }
    
    /// Remove invalid cached player
    func removeInvalidPlayer(for url: URL) {
        let cacheKey = url.absoluteString
        playerCache.removeValue(forKey: cacheKey)
    }
    
    /// Clear asset cache for a specific URL
    @MainActor func clearAssetCache(for url: URL) {
        let cacheKey = url.absoluteString
        assetCache.removeValue(forKey: cacheKey)
        cacheTimestamps.removeValue(forKey: cacheKey)
        print("DEBUG: [SHARED ASSET CACHE] Cleared asset cache for URL: \(url)")
    }
    
    /// Get cached player or create new one with asset
    @MainActor func getOrCreatePlayer(for url: URL, tweetId: String? = nil) async throws -> AVPlayer {
        // Try to get cached player first
        if let cachedPlayer = getCachedPlayer(for: url) {
            return cachedPlayer
        }
        
        // Create new player with asset
        let asset = try await getAsset(for: url, tweetId: tweetId)
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
        
        // Try to find HLS playlist with shorter timeout
        let masterURL = url.appendingPathComponent("master.m3u8")
        let playlistURL = url.appendingPathComponent("playlist.m3u8")
        
        // Use shorter timeout to prevent blocking
        if await urlExists(masterURL, timeout: 3.0) {
            return masterURL
        }
        
        if await urlExists(playlistURL, timeout: 3.0) {
            return playlistURL
        }
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
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll()
        preloadTasks.values.forEach { $0.cancel() }
        preloadTasks.removeAll()
    }
    
    /// Clear all caches (emergency cleanup)
    @MainActor func clearAllCaches() {
        print("DEBUG: [SharedAssetCache] Clearing all caches")
        
        // Pause and remove all cached players
        for (_, player) in playerCache {
            player.pause()
        }
        playerCache.removeAll()
        
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
        if playerCache.count > maxCacheSize {
            // Remove least recently used players - do sorting on background thread
            Task.detached {
                let sortedKeys = await MainActor.run {
                    self.cacheTimestamps.sorted { $0.value < $1.value }.map { $0.key }
                }
                let keysToRemove = sortedKeys.prefix(await MainActor.run { self.playerCache.count - self.maxCacheSize })
                
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
        // Invalidate timer
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        
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
