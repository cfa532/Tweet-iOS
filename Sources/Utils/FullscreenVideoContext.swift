//
//  FullscreenVideoContext.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  Independent video context for fullscreen media browser
//

import Foundation
import AVFoundation
import AVKit
import SwiftUI

/// Independent video playback context for fullscreen media browser
/// Optimized for fullscreen viewing with tabview navigation
class FullscreenVideoContext: ObservableObject {
    
    // Player management
    private var players: [String: AVPlayer] = [:]
    private var playerObservers: [String: NSKeyValueObservation] = [:]
    
    // Fullscreen-specific state
    private var currentVideoMid: String?
    private var hasAutoPlayed: Set<String> = []
    
    // Fullscreen videos are always unmuted (independent from global mute)
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
    
    /// Get or create player for fullscreen video
    func getPlayer(for videoMid: String, url: URL, contentType: String) async -> AVPlayer? {
        // Check if we already have a player for this video
        if let existingPlayer = players[videoMid] {
            print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Returning existing player for: \(videoMid)")
            return existingPlayer
        }
        
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
        setupPlayerObserver(for: player, videoMid: videoMid)
        
        print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Created new player for: \(videoMid)")
        return player
    }
    
    /// Set current video for autoplay
    func setCurrentVideo(_ videoMid: String) {
        // Pause previous video
        if let previousMid = currentVideoMid, let previousPlayer = players[previousMid] {
            previousPlayer.pause()
            print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Paused previous video: \(previousMid)")
        }
        
        currentVideoMid = videoMid
        
        // Start current video if ready
        if let player = players[videoMid] {
            if player.currentItem?.status == .readyToPlay {
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
            // Start playback if this is the current video
            if videoMid == currentVideoMid {
                startPlayback(for: videoMid)
            }
        case .failed:
            if let error = player.currentItem?.error {
                print("ERROR: [FULLSCREEN VIDEO CONTEXT] Player failed for \(videoMid): \(error)")
            }
        case .unknown:
            print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Player status unknown for: \(videoMid)")
        @unknown default:
            print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Unknown player status for: \(videoMid)")
        }
    }
    
    /// Clean up all players and observers
    func cleanup() {
        cleanupSync()
    }
    
    /// Clean up (synchronous version for deinit)
    private func cleanupSync() {
        print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Cleaning up context")
        
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
        
        print("DEBUG: [FULLSCREEN VIDEO CONTEXT] Cleanup completed")
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
        print("DEBUG: [FULLSCREEN VIDEO CONTEXT] App entering background, pausing videos")
        for (_, player) in players {
            player.pause()
        }
    }
    
    /// Handle app entering foreground
    private func handleAppWillEnterForeground() {
        print("DEBUG: [FULLSCREEN VIDEO CONTEXT] App entering foreground")
        // Resume current video if any
        if let currentMid = currentVideoMid {
            startPlayback(for: currentMid)
        }
    }
}
