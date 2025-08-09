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
    private var pendingAutoplay: Set<String> = []
    
    // Local mute state (independent from global)
    @Published var localMuteStates: [String: Bool] = [:]
    
    // App lifecycle management
    private var didEnterBackgroundObserver: NSObjectProtocol?
    private var willEnterForegroundObserver: NSObjectProtocol?
    
    init() {
        setupAppLifecycleObservers()
    }
    
    deinit {
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
            // Trigger autoplay if player is ready
            if players[videoMid]?.currentItem?.status == .readyToPlay {
                startPlayback(for: videoMid)
            } else {
                pendingAutoplay.insert(videoMid)
                print("DEBUG: [DETAIL VIDEO CONTEXT] Added to pending autoplay: \(videoMid)")
            }
        } else {
            selectedVideoMids.remove(videoMid)
            pendingAutoplay.remove(videoMid)
            if let player = players[videoMid] {
                player.pause()
                print("DEBUG: [DETAIL VIDEO CONTEXT] Paused due to deselection: \(videoMid)")
            }
        }
    }
    
    /// Start playback for selected video
    private func startPlayback(for videoMid: String) {
        guard selectedVideoMids.contains(videoMid),
              let player = players[videoMid] else { return }
        
        // Check if we've already auto-played this video
        if hasAutoPlayed.contains(videoMid) {
            print("DEBUG: [DETAIL VIDEO CONTEXT] Video already auto-played, skipping: \(videoMid)")
            return
        }
        
        print("DEBUG: [DETAIL VIDEO CONTEXT] Auto-playing video: \(videoMid)")
        player.seek(to: .zero)
        player.play()
        hasAutoPlayed.insert(videoMid)
        pendingAutoplay.remove(videoMid)
    }
    
    /// Manual play/pause control
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
    
    /// Clean up all players and observers
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
        
        // Clean up players
        for (_, player) in players {
            player.pause()
        }
        players.removeAll()
        
        // Clear state
        selectedVideoMids.removeAll()
        hasAutoPlayed.removeAll()
        pendingAutoplay.removeAll()
        
        // Remove app lifecycle observers
        if let observer = didEnterBackgroundObserver {
            NotificationCenter.default.removeObserver(observer)
            didEnterBackgroundObserver = nil
        }
        if let observer = willEnterForegroundObserver {
            NotificationCenter.default.removeObserver(observer)
            willEnterForegroundObserver = nil
        }
        
        print("DEBUG: [DETAIL VIDEO CONTEXT] Cleanup completed")
    }
    
    /// Set up player status observer
    private func setupPlayerObserver(for videoMid: String, player: AVPlayer) {
        let observer = player.observe(\.currentItem?.status) { [weak self] observedPlayer, change in
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
            print("DEBUG: [DETAIL VIDEO CONTEXT] Player ready for: \(videoMid)")
            // Check if this video should autoplay
            if pendingAutoplay.contains(videoMid) && selectedVideoMids.contains(videoMid) {
                startPlayback(for: videoMid)
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
        print("DEBUG: [DETAIL VIDEO CONTEXT] App entering background, pausing videos")
        for (_, player) in players {
            player.pause()
        }
    }
    
    /// Handle app entering foreground
    private func handleAppWillEnterForeground() {
        print("DEBUG: [DETAIL VIDEO CONTEXT] App entering foreground")
        // Videos will resume based on selection state
    }
}
