//
//  GridVideoContext.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  Independent video context for grid views with sequential playback
//

import Foundation
import AVFoundation
import AVKit
import SwiftUI

/// Independent video playback context for grid views (feeds, search results)
/// Uses shared VideoAssetCache but maintains its own player instances and sequential playback logic
class GridVideoContext: ObservableObject {
    
    // Player management
    private var players: [String: AVPlayer] = [:]
    private var playerObservers: [String: NSKeyValueObservation] = [:]
    
    // Sequential playback state
    @Published var currentVideoIndex: Int = -1
    @Published var videoMids: [String] = []
    @Published var isSequentialPlaybackEnabled: Bool = false
    
    // Visibility tracking
    private var visibleVideoMids: Set<String> = []
    
    // Global mute state (will be connected to MuteState when implemented)
    @Published var isMuted: Bool = false
    
    // App lifecycle management
    private var didEnterBackgroundObserver: NSObjectProtocol?
    private var willEnterForegroundObserver: NSObjectProtocol?
    
    init() {
        // Will be connected to global mute state when MuteState is implemented
        setupAppLifecycleObservers()
    }
    
    deinit {
        cleanupSync()
    }
    
    /// Get or create an independent AVPlayer for the given video
    func getPlayer(for videoMid: String, url: URL, contentType: String) async -> AVPlayer? {
        // Check if we already have a player for this video
        if let existingPlayer = players[videoMid] {
            print("DEBUG: [GRID VIDEO CONTEXT] Returning existing player for: \(videoMid)")
            return existingPlayer
        }
        
        // Get shared asset from cache
        let asset = await VideoAssetCache.shared.getAsset(for: videoMid, originalURL: url, contentType: contentType)
        
        // Create independent player instance
        let playerItem = asset.createPlayerItem()
        let player = AVPlayer(playerItem: playerItem)
        
        // Configure for grid playback
        player.isMuted = isMuted
        player.automaticallyWaitsToMinimizeStalling = true
        
        // Store player and setup observers
        players[videoMid] = player
        setupPlayerObserver(for: videoMid, player: player)
        
        print("DEBUG: [GRID VIDEO CONTEXT] Created new player for: \(videoMid), muted: \(isMuted)")
        return player
    }
    
    /// Set up sequential playback for a list of videos
    func setupSequentialPlayback(for videoMids: [String]) {
        self.videoMids = videoMids
        self.currentVideoIndex = -1
        self.isSequentialPlaybackEnabled = true
        
        print("DEBUG: [GRID VIDEO CONTEXT] Setup sequential playback for \(videoMids.count) videos")
    }
    
    /// Stop sequential playback
    func stopSequentialPlayback() {
        isSequentialPlaybackEnabled = false
        currentVideoIndex = -1
        
        // Pause all videos
        for (_, player) in players {
            player.pause()
        }
        
        print("DEBUG: [GRID VIDEO CONTEXT] Stopped sequential playback")
    }
    
    /// Set video visibility (for performance optimization)
    func setVideoVisible(_ videoMid: String, isVisible: Bool) {
        if isVisible {
            visibleVideoMids.insert(videoMid)
        } else {
            visibleVideoMids.remove(videoMid)
            // Pause if not visible
            if let player = players[videoMid] {
                player.pause()
            }
        }
        
        // Update sequential playback if needed
        if isSequentialPlaybackEnabled {
            updateSequentialPlayback()
        }
    }
    
    /// Update sequential playback based on visibility
    private func updateSequentialPlayback() {
        guard isSequentialPlaybackEnabled else { return }
        
        // Find the first visible video
        for (index, videoMid) in videoMids.enumerated() {
            if visibleVideoMids.contains(videoMid) {
                if currentVideoIndex != index {
                    // Switch to this video
                    if currentVideoIndex >= 0 && currentVideoIndex < videoMids.count {
                        let previousVideoMid = videoMids[currentVideoIndex]
                        players[previousVideoMid]?.pause()
                    }
                    
                    currentVideoIndex = index
                    if let player = players[videoMid], player.currentItem?.status == .readyToPlay {
                        startPlayback(for: videoMid)
                    }
                    print("DEBUG: [GRID VIDEO CONTEXT] Sequential playback switched to index \(index): \(videoMid)")
                }
                break
            }
        }
    }
    
    /// Start playback for a specific video
    private func startPlayback(for videoMid: String) {
        guard let player = players[videoMid] else { return }
        
        print("DEBUG: [GRID VIDEO CONTEXT] Starting playback for: \(videoMid)")
        player.seek(to: .zero)
        player.play()
    }
    
    /// Update global mute state for all players
    func updateMuteState(_ isMuted: Bool) {
        self.isMuted = isMuted
        
        for (mid, player) in players {
            player.isMuted = isMuted
            print("DEBUG: [GRID VIDEO CONTEXT] Updated mute state for \(mid) to: \(isMuted)")
        }
    }
    
    /// Clean up all players and observers
    func cleanup() {
        cleanupSync()
    }
    
    /// Clean up (synchronous version for deinit)
    private func cleanupSync() {
        print("DEBUG: [GRID VIDEO CONTEXT] Cleaning up context")
        
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
        visibleVideoMids.removeAll()
        videoMids.removeAll()
        currentVideoIndex = -1
        isSequentialPlaybackEnabled = false
        
        // Remove app lifecycle observers
        if let observer = didEnterBackgroundObserver {
            NotificationCenter.default.removeObserver(observer)
            didEnterBackgroundObserver = nil
        }
        if let observer = willEnterForegroundObserver {
            NotificationCenter.default.removeObserver(observer)
            willEnterForegroundObserver = nil
        }
        
        print("DEBUG: [GRID VIDEO CONTEXT] Cleanup completed")
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
            print("DEBUG: [GRID VIDEO CONTEXT] Player ready for: \(videoMid)")
            // Start playback if this video should play and is visible
            if shouldPlayVideo(for: videoMid) {
                startPlayback(for: videoMid)
            }
        case .failed:
            if let error = player.currentItem?.error {
                print("ERROR: [GRID VIDEO CONTEXT] Player failed for \(videoMid): \(error)")
            }
        case .unknown:
            print("DEBUG: [GRID VIDEO CONTEXT] Player status unknown for: \(videoMid)")
        @unknown default:
            print("DEBUG: [GRID VIDEO CONTEXT] Unknown player status for: \(videoMid)")
        }
    }
    
    /// Check if a video should play based on sequential playback rules
    private func shouldPlayVideo(for videoMid: String) -> Bool {
        guard isSequentialPlaybackEnabled else { return false }
        guard let index = videoMids.firstIndex(of: videoMid) else { return false }
        
        return index == currentVideoIndex && visibleVideoMids.contains(videoMid)
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
        print("DEBUG: [GRID VIDEO CONTEXT] App entering background, pausing videos")
        for (_, player) in players {
            player.pause()
        }
    }
    
    /// Handle app entering foreground
    private func handleAppWillEnterForeground() {
        print("DEBUG: [GRID VIDEO CONTEXT] App entering foreground")
        if isSequentialPlaybackEnabled {
            updateSequentialPlayback()
        }
    }
}
