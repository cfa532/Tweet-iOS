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
    
    deinit {
        // Clean up when the cache is deallocated
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        
        // Cancel all loading tasks
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll()
        
        // Cancel all preload tasks
        preloadTasks.values.forEach { $0.cancel() }
        preloadTasks.removeAll()
        
        // Remove notification observers
        NotificationCenter.default.removeObserver(self)
        
        print("DEBUG: [SHARED ASSET CACHE] Cache deallocated")
    }
    
    // MARK: - Cache Storage
    private var assetCache: [String: AVAsset] = [:]
    private var playerCache: [String: AVPlayer] = [:]
    private var cacheTimestamps: [String: Date] = [:]
    private var loadingTasks: [String: Task<AVAsset, Error>] = [:]
    private var preloadTasks: [String: Task<Void, Never>] = [:]
    
    // MARK: - Configuration
    private let maxCacheSize = 20 // Maximum number of cached assets
    private let maxPlayerCacheSize = 10 // Maximum number of cached players
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
            print("DEBUG: [SHARED ASSET CACHE] Cleaned up expired asset: \(key)")
        }
        
        // Manage cache size
        manageCacheSize()
    }
    
    // MARK: - Asset Management
    
    /// Get cached asset or create new one
    @MainActor func getAsset(for url: URL) async throws -> AVAsset {
        let cacheKey = url.absoluteString
        
        // Check if we have a cached asset
        if let cachedAsset = assetCache[cacheKey] {
            print("DEBUG: [SHARED ASSET CACHE] Using cached asset for: \(url.lastPathComponent)")
            cacheTimestamps[cacheKey] = Date() // Update access time
            return cachedAsset
        }
        
        // Check if there's already a loading task
        if let existingTask = loadingTasks[cacheKey] {
            print("DEBUG: [SHARED ASSET CACHE] Waiting for existing loading task for: \(url.lastPathComponent)")
            do {
                let asset = try await existingTask.value
                cacheTimestamps[cacheKey] = Date() // Update access time
                return asset
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
            let asset = AVURLAsset(url: resolvedURL)
            
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
            let asset = try await task.value
            return asset
        } catch {
            print("DEBUG: [SHARED ASSET CACHE] Error creating asset: \(error)")
            loadingTasks.removeValue(forKey: cacheKey)
            throw error
        }
    }
    
    /// Cache a player instance for immediate reuse
    func cachePlayer(_ player: AVPlayer, for url: URL) {
        let cacheKey = url.absoluteString
        
        // Remove old player if exists
        if let oldPlayer = playerCache[cacheKey] {
            oldPlayer.pause()
            print("DEBUG: [SHARED ASSET CACHE] Replacing cached player for: \(url.lastPathComponent)")
        }
        
        playerCache[cacheKey] = player
        cacheTimestamps[cacheKey] = Date()
        
        // Manage cache size
        managePlayerCacheSize()
        
        print("DEBUG: [SHARED ASSET CACHE] Cached player for: \(url.lastPathComponent)")
    }
    
    /// Get cached player if available
    func getCachedPlayer(for url: URL) -> AVPlayer? {
        let cacheKey = url.absoluteString
        if let player = playerCache[cacheKey] {
            // Validate that the player is still valid before returning it
            guard let playerItem = player.currentItem,
                  playerItem.status != .failed else {
                print("DEBUG: [SHARED ASSET CACHE] Cached player is invalid, removing from cache")
                playerCache.removeValue(forKey: cacheKey)
                cacheTimestamps.removeValue(forKey: cacheKey)
                return nil
            }
            

            
            cacheTimestamps[cacheKey] = Date() // Update access time
            print("DEBUG: [SHARED ASSET CACHE] Using cached player for: \(url.lastPathComponent)")
            return player
        }
        return nil
    }
    
    /// Remove invalid cached player
    func removeInvalidPlayer(for url: URL) {
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
        preloadTasks.values.forEach { $0.cancel() }
        preloadTasks.removeAll()
        print("DEBUG: [SHARED ASSET CACHE] Cache cleared")
    }
    
    // MARK: - Enhanced Preloading Methods
    
    /// Preload video for immediate display (high priority)
    func preloadVideo(for url: URL) {
        let cacheKey = url.absoluteString
        
        // Cancel existing preload task if any
        preloadTasks[cacheKey]?.cancel()
        
        let task = Task {
            do {
                print("DEBUG: [SHARED ASSET CACHE] Starting high-priority video preload for: \(url.lastPathComponent)")
                _ = try await getOrCreatePlayer(for: url)
                print("DEBUG: [SHARED ASSET CACHE] High-priority video preload completed for: \(url.lastPathComponent)")
            } catch {
                print("DEBUG: [SHARED ASSET CACHE] Error in high-priority video preload: \(error)")
            }
        }
        
        preloadTasks[cacheKey] = task
    }
    
    /// Preload asset only (for background loading - lower priority)
    func preloadAsset(for url: URL) {
        let cacheKey = url.absoluteString
        
        // Cancel existing preload task if any
        preloadTasks[cacheKey]?.cancel()
        
        let task = Task {
            do {
                print("DEBUG: [SHARED ASSET CACHE] Starting background asset preload for: \(url.lastPathComponent)")
                _ = try await getAsset(for: url)
                print("DEBUG: [SHARED ASSET CACHE] Background asset preload completed for: \(url.lastPathComponent)")
            } catch {
                print("DEBUG: [SHARED ASSET CACHE] Error in background asset preload: \(error)")
            }
        }
        
        preloadTasks[cacheKey] = task
    }
    
    /// Cancel preload for specific URL
    func cancelPreload(for url: URL) {
        let cacheKey = url.absoluteString
        preloadTasks[cacheKey]?.cancel()
        preloadTasks.removeValue(forKey: cacheKey)
        print("DEBUG: [SHARED ASSET CACHE] Cancelled preload for: \(url.lastPathComponent)")
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
            // Remove least recently used assets
            let sortedKeys = cacheTimestamps.sorted { $0.value < $1.value }.map { $0.key }
            let keysToRemove = sortedKeys.prefix(assetCache.count - maxCacheSize)
            
            for key in keysToRemove {
                assetCache.removeValue(forKey: key)
                cacheTimestamps.removeValue(forKey: key)
                print("DEBUG: [SHARED ASSET CACHE] Removed LRU asset: \(key)")
            }
        }
    }
    
    private func managePlayerCacheSize() {
        if playerCache.count > maxPlayerCacheSize {
            // Remove least recently used players
            let sortedKeys = cacheTimestamps.sorted { $0.value < $1.value }.map { $0.key }
            let keysToRemove = sortedKeys.prefix(playerCache.count - maxPlayerCacheSize)
            
            for key in keysToRemove {
                if let player = playerCache[key] {
                    player.pause()
                    playerCache.removeValue(forKey: key)
                    cacheTimestamps.removeValue(forKey: key)
                    print("DEBUG: [SHARED ASSET CACHE] Removed LRU player: \(key)")
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
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppWillResignActive()
            }
        }
    }
    
    private func handleAppWillEnterForeground() {
        print("DEBUG: [SHARED ASSET CACHE] App will enter foreground - refreshing cached players")
        refreshCachedPlayers()
    }
    
    private func handleAppDidBecomeActive() {
        print("DEBUG: [SHARED ASSET CACHE] App did become active - ensuring cached players are ready")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.refreshCachedPlayers()
        }
    }
    
    private func handleAppWillResignActive() {
        print("DEBUG: [SHARED ASSET CACHE] App will resign active - pausing all cached players")
        // Pause all cached players to prevent crashes when app goes to background
        for (urlString, player) in playerCache {
            player.pause()
            print("DEBUG: [SHARED ASSET CACHE] Paused cached player for: \(URL(string: urlString)?.lastPathComponent ?? "unknown")")
        }
    }
    
    private func refreshCachedPlayers() {
        // Refresh all cached players to ensure they show cached content
        for (urlString, player) in playerCache {
            // Validate player before accessing its properties
            guard let playerItem = player.currentItem,
                  playerItem.status != .failed else {
                print("DEBUG: [SHARED ASSET CACHE] Skipping invalid cached player for: \(URL(string: urlString)?.lastPathComponent ?? "unknown")")
                continue
            }
            
            print("DEBUG: [SHARED ASSET CACHE] Refreshing cached player for: \(URL(string: urlString)?.lastPathComponent ?? "unknown")")
            
            // Force a seek to refresh the video layer
            let currentTime = player.currentTime()
            player.seek(to: currentTime) { _ in
                // Video layer should now be refreshed and showing cached content
                print("DEBUG: [SHARED ASSET CACHE] Refreshed cached player for: \(URL(string: urlString)?.lastPathComponent ?? "unknown")")
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
