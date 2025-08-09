//
//  DetailVideoContext.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  Independent video context for detail views (TweetDetailView, CommentDetailView)
//

import Foundation
import AVFoundation
import AVKit
import SwiftUI

/// Independent video playback context for detail views
/// Uses shared VideoAssetCache but maintains its own player instances and state
@MainActor
class DetailVideoContext: ObservableObject {
    
    // Player management
    private var players: [String: AVPlayer] = [:]
    private var playerObservers: [String: NSKeyValueObservation] = [:]
    
    // Selection-based autoplay state
    private var selectedVideoMids: Set<String> = []
    private var hasAutoPlayed: Set<String> = []
    private var pendingAutoplay: Set<String> = [] // Videos waiting to autoplay when ready
    
    // Local mute state (independent from global)
    @Published var localMuteStates: [String: Bool] = [:]
    
    // App lifecycle management
    private var didEnterBackgroundObserver: NSObjectProtocol?
    private var willEnterForegroundObserver: NSObjectProtocol?
    
    init() {
        setupAppLifecycleObservers()
    }
    
    deinit {
        // Clean up synchronously in deinit
        cleanupSync()
    }
    
    /// Get or create an independent AVPlayer for the given video
    func getPlayer(for videoMid: String, url: URL, contentType: String) async -> AVPlayer? {
        // Check if we already have a player for this video
        if let existingPlayer = players[videoMid] {
            print("DEBUG: [DETAIL VIDEO CONTEXT] Returning existing player for: \(videoMid)")
            return existingPlayer
        }
        
        // Get shared asset from cache
        let asset = await VideoAssetCache.shared.getAsset(for: videoMid, originalURL: url, contentType: contentType)
        
        // Create independent player instance using shared asset
        let playerItem = asset.createPlayerItem()
        let player = AVPlayer(playerItem: playerItem)
        
        // Configure player
        player.automaticallyWaitsToMinimizeStalling = true
        
        // IMPORTANT: Prevent old system interference by ensuring we control this player
        // Add a delay to ensure asset is fully loaded before any interference
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if player.currentItem?.status != .readyToPlay {
                print("DEBUG: [DETAIL VIDEO CONTEXT] Player not immediately ready, will wait for status change")
            }
        }
        
        // Set initial mute state (default to false for detail views)
        let isLocalMuted = localMuteStates[videoMid] ?? false
        player.isMuted = isLocalMuted
        
        // Store player and setup observers
        players[videoMid] = player
        setupPlayerObserver(for: videoMid, player: player)
        
        print("DEBUG: [DETAIL VIDEO CONTEXT] Created new player for: \(videoMid), muted: \(isLocalMuted)")
        return player
    }
    
    /// Set video selection state (for TabView-based autoplay)
    func setVideoSelected(_ videoMid: String, isSelected: Bool) {
        if isSelected {
            selectedVideoMids.insert(videoMid)
            
            // Autoplay if this is the first time selecting this video
            if !hasAutoPlayed.contains(videoMid) {
                hasAutoPlayed.insert(videoMid)
                startPlayback(for: videoMid)
                print("DEBUG: [DETAIL VIDEO CONTEXT] First-time autoplay for: \(videoMid)")
            } else {
                print("DEBUG: [DETAIL VIDEO CONTEXT] Video \(videoMid) selected but already auto-played once")
            }
        } else {
            selectedVideoMids.remove(videoMid)
            pausePlayback(for: videoMid)
            print("DEBUG: [DETAIL VIDEO CONTEXT] Video \(videoMid) deselected - pausing")
        }
    }
    
    /// Toggle playback for a specific video
    func togglePlayback(for videoMid: String) {
        guard let player = players[videoMid] else {
            print("DEBUG: [DETAIL VIDEO CONTEXT] No player found for toggle: \(videoMid)")
            return
        }
        
        if player.rate > 0 {
            player.pause()
            print("DEBUG: [DETAIL VIDEO CONTEXT] Manual pause for: \(videoMid)")
        } else {
            player.play()
            print("DEBUG: [DETAIL VIDEO CONTEXT] Manual play for: \(videoMid)")
        }
    }
    
    /// Detail videos are always unmuted - no mute controls needed
    /// This ensures detail videos play with sound regardless of global mute state
    
    /// Toggle mute state for a specific video (local mute, doesn't affect global)
    func toggleMute(for videoMid: String) {
        guard let player = players[videoMid] else {
            print("DEBUG: [DETAIL VIDEO CONTEXT] No player found for mute toggle: \(videoMid)")
            return
        }
        
        let newMuteState = !player.isMuted
        player.isMuted = newMuteState
        localMuteStates[videoMid] = newMuteState
        
        print("DEBUG: [DETAIL VIDEO CONTEXT] Toggled mute for \(videoMid) to: \(newMuteState)")
    }
    
    /// Set mute state for a specific video
    func setMute(for videoMid: String, isMuted: Bool) {
        guard let player = players[videoMid] else {
            print("DEBUG: [DETAIL VIDEO CONTEXT] No player found for mute set: \(videoMid)")
            return
        }
        
        player.isMuted = isMuted
        localMuteStates[videoMid] = isMuted
        
        print("DEBUG: [DETAIL VIDEO CONTEXT] Set mute for \(videoMid) to: \(isMuted)")
    }
    
    /// Get current mute state for a video
    func isMuted(for videoMid: String) -> Bool {
        return localMuteStates[videoMid] ?? false
    }
    
    /// Clean up all players and observers (MainActor version)
    func cleanup() {
        cleanupSync()
    }
    
    /// Clean up all players and observers (synchronous version for deinit)
    private func cleanupSync() {
        print("DEBUG: [DETAIL VIDEO CONTEXT] Cleaning up context")
        
        // Remove all observers
        for (_, observer) in playerObservers {
            observer.invalidate()
        }
        playerObservers.removeAll()
        
        // Pause and remove all players
        for (mid, player) in players {
            player.pause()
            print("DEBUG: [DETAIL VIDEO CONTEXT] Cleaned up player for: \(mid)")
        }
        players.removeAll()
        
        // Clear state
        selectedVideoMids.removeAll()
        hasAutoPlayed.removeAll()
        pendingAutoplay.removeAll()
        localMuteStates.removeAll()
        
        // Remove app lifecycle observers
        if let observer = didEnterBackgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = willEnterForegroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Private Methods
    
    /// Start playback for a video
    private func startPlayback(for videoMid: String) {
        guard let player = players[videoMid] else {
            print("DEBUG: [DETAIL VIDEO CONTEXT] No player found for playback: \(videoMid) - adding to pending autoplay")
            pendingAutoplay.insert(videoMid)
            return
        }
        
        guard player.status == .readyToPlay || player.currentItem?.status == .readyToPlay else {
            print("DEBUG: [DETAIL VIDEO CONTEXT] Player not ready for playback: \(videoMid) - adding to pending autoplay")
            pendingAutoplay.insert(videoMid)
            return
        }
        
        player.play()
        pendingAutoplay.remove(videoMid) // Remove from pending since we started playback
        print("DEBUG: [DETAIL VIDEO CONTEXT] Started playback for: \(videoMid)")
    }
    
    /// Pause playback for a video
    private func pausePlayback(for videoMid: String) {
        guard let player = players[videoMid] else {
            print("DEBUG: [DETAIL VIDEO CONTEXT] No player found for pause: \(videoMid)")
            return
        }
        
        player.pause()
        print("DEBUG: [DETAIL VIDEO CONTEXT] Paused playback for: \(videoMid)")
    }
    
    /// Setup KVO observer for player status changes
    private func setupPlayerObserver(for videoMid: String, player: AVPlayer) {
        let observer = player.observe(\.currentItem?.status, options: [.new, .initial]) { [weak self] player, change in
            guard let self = self, let status = change.newValue else { return }
            
            DispatchQueue.main.async {
                switch status {
                case .readyToPlay:
                    print("DEBUG: [DETAIL VIDEO CONTEXT] Player ready for: \(videoMid)")
                    // If this video has pending autoplay, start playback
                    if self.pendingAutoplay.contains(videoMid) {
                        self.startPlayback(for: videoMid)
                    }
                    // Or if this video is selected and should autoplay, start playback
                    else if self.selectedVideoMids.contains(videoMid) && !self.hasAutoPlayed.contains(videoMid) {
                        self.hasAutoPlayed.insert(videoMid)
                        self.startPlayback(for: videoMid)
                    }
                case .failed:
                    if let error = player.currentItem?.error {
                        print("ERROR: [DETAIL VIDEO CONTEXT] Player failed for \(videoMid): \(error)")
                    }
                case .unknown:
                    print("DEBUG: [DETAIL VIDEO CONTEXT] Player status unknown for: \(videoMid)")
                @unknown default:
                    print("DEBUG: [DETAIL VIDEO CONTEXT] Unknown player status for: \(videoMid)")
                }
            }
        }
        
        playerObservers[videoMid] = observer
    }
    
    /// Setup app lifecycle observers
    private func setupAppLifecycleObservers() {
        didEnterBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppDidEnterBackground()
        }
        
        willEnterForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppWillEnterForeground()
        }
    }
    
    /// Handle app entering background
    private func handleAppDidEnterBackground() {
        print("DEBUG: [DETAIL VIDEO CONTEXT] App entered background - pausing all videos")
        for (mid, player) in players {
            if player.rate > 0 {
                player.pause()
                print("DEBUG: [DETAIL VIDEO CONTEXT] Paused \(mid) for background")
            }
        }
    }
    
    /// Handle app entering foreground
    private func handleAppWillEnterForeground() {
        print("DEBUG: [DETAIL VIDEO CONTEXT] App entering foreground - checking video restoration")
        // Videos will resume based on their selection state
        // This handles any video layer restoration issues
        for (mid, _) in players {
            if selectedVideoMids.contains(mid) {
                // Force a refresh by seeking to current position
                if let player = players[mid] {
                    let currentTime = player.currentTime()
                    player.seek(to: currentTime)
                    print("DEBUG: [DETAIL VIDEO CONTEXT] Refreshed player layer for: \(mid)")
                }
            }
        }
    }
}

// MARK: - Convenience Extensions

extension DetailVideoContext {
    /// Remove a specific video player (when no longer needed)
    func removePlayer(for videoMid: String) {
        if let observer = playerObservers.removeValue(forKey: videoMid) {
            observer.invalidate()
        }
        
        if let player = players.removeValue(forKey: videoMid) {
            player.pause()
            print("DEBUG: [DETAIL VIDEO CONTEXT] Removed player for: \(videoMid)")
        }
        
        selectedVideoMids.remove(videoMid)
        hasAutoPlayed.remove(videoMid)
        pendingAutoplay.remove(videoMid)
        localMuteStates.removeValue(forKey: videoMid)
    }
    
    /// Check if a video is currently playing
    func isPlaying(_ videoMid: String) -> Bool {
        guard let player = players[videoMid] else { return false }
        return player.rate > 0
    }
    
    /// Get current playback time for a video
    func getCurrentTime(for videoMid: String) -> TimeInterval {
        guard let player = players[videoMid] else { return 0 }
        return player.currentTime().seconds
    }
    
    /// Get duration for a video
    func getDuration(for videoMid: String) -> TimeInterval {
        guard let player = players[videoMid],
              let item = player.currentItem else { return 0 }
        return item.duration.seconds
    }
}

// MARK: - FullscreenVideoContext

/// Independent video playback context for fullscreen media browser
/// Optimized for fullscreen viewing with tabview navigation and native controls
class FullscreenVideoContext: ObservableObject {
    
    // Player management
    private var players: [String: AVPlayer] = [:]
    private var playerObservers: [String: NSKeyValueObservation] = [:]
    
    // Fullscreen-specific state
    private var currentVideoMid: String?
    private var hasAutoPlayed: Set<String> = []
    
    // All videos are unmuted in fullscreen (independent from global mute)
    private let isUnmuted = true
    
    // App lifecycle management
    private var didEnterBackgroundObserver: NSObjectProtocol?
    private var willEnterForegroundObserver: NSObjectProtocol?
    
    init() {
        setupAppLifecycleObservers()
    }
    
    deinit {
        cleanupSync()
    }
    
    /// Get or create an independent AVPlayer for fullscreen viewing
    func getPlayer(for videoMid: String, url: URL, contentType: String) async -> AVPlayer? {
        // Check if we already have a player for this video
        if let existingPlayer = players[videoMid] {
            print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Returning existing player for: \(videoMid)")
            return existingPlayer
        }
        
        print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Creating new player for: \(videoMid)")
        
        // Get video asset from shared cache
        let asset = await VideoAssetCache.shared.getAsset(for: videoMid, originalURL: url, contentType: contentType)
        
        // Create player with the resolved asset
        let playerItem = asset.createPlayerItem()
        let player = AVPlayer(playerItem: playerItem)
        
        // Configure for fullscreen playback
        player.isMuted = false // Always unmuted in fullscreen
        player.allowsExternalPlayback = true
        
        // Store player
        players[videoMid] = player
        
        // Set up observer for player status
        setupPlayerObserver(for: player, videoMid: videoMid)
        
        print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Created new player for: \(videoMid), muted: false")
        return player
    }
    
    /// Set the current video (TabView selection changed)
    func setCurrentVideo(_ videoMid: String) {
        let previousVideo = currentVideoMid
        currentVideoMid = videoMid
        
        print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Current video changed from \(previousVideo ?? "none") to \(videoMid)")
        
        // Pause previous video
        if let prevMid = previousVideo, let prevPlayer = players[prevMid] {
            prevPlayer.pause()
            print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Paused previous video: \(prevMid)")
        }
        
        // Start current video if it exists and ready
        if let currentPlayer = players[videoMid] {
            if currentPlayer.currentItem?.status == .readyToPlay {
                startPlayback(for: videoMid)
            } else {
                print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Player not ready, will autoplay when ready: \(videoMid)")
            }
        }
    }
    
    /// Start playback for the current video
    private func startPlayback(for videoMid: String) {
        guard let player = players[videoMid],
              videoMid == currentVideoMid else { return }
        
        // Check if we've already auto-played this video
        if hasAutoPlayed.contains(videoMid) {
            print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Video already auto-played, skipping: \(videoMid)")
            return
        }
        
        print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Starting playback for: \(videoMid)")
        player.play()
        hasAutoPlayed.insert(videoMid)
    }
    
    /// Set up player status observer
    private func setupPlayerObserver(for player: AVPlayer, videoMid: String) {
        let observer = player.observe(\.currentItem?.status) { [weak self] observedPlayer, _ in
            DispatchQueue.main.async {
                self?.handlePlayerStatusChange(player: observedPlayer, videoMid: videoMid)
            }
        }
        playerObservers[videoMid] = observer
    }
    
    /// Handle player status changes
    private func handlePlayerStatusChange(player: AVPlayer, videoMid: String) {
        guard let status = player.currentItem?.status else { return }
        
        switch status {
        case .readyToPlay:
            print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Player ready for: \(videoMid)")
            // If this is the current video, start playback
            if videoMid == currentVideoMid {
                startPlayback(for: videoMid)
            }
        case .failed:
            print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Player failed for: \(videoMid)")
        case .unknown:
            print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Player status unknown for: \(videoMid)")
        @unknown default:
            break
        }
    }
    
    /// Toggle play/pause for current video
    func togglePlayPause() {
        guard let currentMid = currentVideoMid,
              let player = players[currentMid] else { return }
        
        if player.rate > 0 {
            player.pause()
            print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Paused: \(currentMid)")
        } else {
            player.play()
            print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Resumed: \(currentMid)")
        }
    }
    
    /// Clean up all players and observers
    private func cleanupSync() {
        print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Cleaning up all players")
        
        // Remove observers
        for observer in playerObservers.values {
            observer.invalidate()
        }
        playerObservers.removeAll()
        
        // Stop and remove players
        for (mid, player) in players {
            player.pause()
            print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Cleaned up player for: \(mid)")
        }
        players.removeAll()
        
        // Clear state
        currentVideoMid = nil
        hasAutoPlayed.removeAll()
        
        // Remove app lifecycle observers
        if let observer = didEnterBackgroundObserver {
            NotificationCenter.default.removeObserver(observer)
            didEnterBackgroundObserver = nil
        }
        if let observer = willEnterForegroundObserver {
            NotificationCenter.default.removeObserver(observer)
            willEnterForegroundObserver = nil
        }
    }
    
    /// Set up app lifecycle observers
    private func setupAppLifecycleObservers() {
        didEnterBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppDidEnterBackground()
        }
        
        willEnterForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppWillEnterForeground()
        }
    }
    
    /// Handle app entering background
    private func handleAppDidEnterBackground() {
        print("DEBUG: [FULLSCREEN VIDEO CONTEXT] App entering background - pausing all videos")
        for (mid, player) in players {
            player.pause()
            print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Paused video for background: \(mid)")
        }
    }
    
    /// Handle app entering foreground
    private func handleAppWillEnterForeground() {
        print("DEBUG: [FULLSCREEN VIDEO CONTEXT] App entering foreground - checking video restoration")
        // Resume current video if it was playing
        if let currentMid = currentVideoMid, let currentPlayer = players[currentMid] {
            // Force a refresh by seeking to current position
            let currentTime = currentPlayer.currentTime()
            currentPlayer.seek(to: currentTime)
            print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Refreshed player layer for: \(currentMid)")
        }
    }
}

// MARK: - FullscreenVideoContext Extensions

extension FullscreenVideoContext {
    /// Remove a specific video player (when no longer needed)
    func removePlayer(for videoMid: String) {
        if let observer = playerObservers.removeValue(forKey: videoMid) {
            observer.invalidate()
        }
        
        if let player = players.removeValue(forKey: videoMid) {
            player.pause()
            print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Removed player for: \(videoMid)")
        }
        
        hasAutoPlayed.remove(videoMid)
        
        // Clear current if it was this video
        if currentVideoMid == videoMid {
            currentVideoMid = nil
        }
    }
    
    /// Check if a video is currently playing
    func isPlaying(_ videoMid: String) -> Bool {
        guard let player = players[videoMid] else { return false }
        return player.rate > 0
    }
    
    /// Get current playback time for a video
    func getCurrentTime(for videoMid: String) -> TimeInterval {
        guard let player = players[videoMid] else { return 0 }
        return player.currentTime().seconds
    }
    
    /// Get duration for a video
    func getDuration(for videoMid: String) -> TimeInterval {
        guard let player = players[videoMid],
              let item = player.currentItem else { return 0 }
        return item.duration.seconds
    }
}
