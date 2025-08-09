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
class DetailVideoContext: ObservableObject {
    
    // Player management
    private var players: [String: AVPlayer] = [:]
    private var playerObservers: [String: NSKeyValueObservation] = [:]
    
    // Selection-based autoplay state
    private var selectedVideoMids: Set<String> = []
    private var hasAutoPlayed: Set<String> = []
    
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
    
    /// Toggle mute state for a specific video (local mute, doesn't affect global)
    @MainActor
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
    @MainActor
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
            print("DEBUG: [DETAIL VIDEO CONTEXT] No player found for playback: \(videoMid)")
            return
        }
        
        guard player.status == .readyToPlay || player.currentItem?.status == .readyToPlay else {
            print("DEBUG: [DETAIL VIDEO CONTEXT] Player not ready for playback: \(videoMid)")
            return
        }
        
        player.play()
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
                    // If this video is selected and should autoplay, start playback
                    if self.selectedVideoMids.contains(videoMid) && !self.hasAutoPlayed.contains(videoMid) {
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
