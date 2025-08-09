//
//  GridVideoContext.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  Independent video context for grid views (MediaGridView) with sequential playback
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
    
    // Global mute state (follows MuteState.shared)
    @Published var isMuted: Bool = false
    
    // App lifecycle management
    private var didEnterBackgroundObserver: NSObjectProtocol?
    private var willEnterForegroundObserver: NSObjectProtocol?
    
    init() {
        // Subscribe to global mute state
        self.isMuted = MuteState.shared.isMuted
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
        
        // Create independent player instance using shared asset
        let playerItem = asset.createPlayerItem()
        let player = AVPlayer(playerItem: playerItem)
        
        // Configure player
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = isMuted // Use global mute state
        
        // Store player and setup observers
        players[videoMid] = player
        setupPlayerObserver(for: videoMid, player: player)
        
        print("DEBUG: [GRID VIDEO CONTEXT] Created new player for: \(videoMid), muted: \(isMuted)")
        return player
    }
    
    /// Setup sequential playback for a list of video mids
    func setupSequentialPlayback(for mids: [String]) {
        // Check if this is a new sequence or the same sequence
        let isNewSequence = videoMids != mids && !videoMids.isEmpty
        
        videoMids = mids
        currentVideoIndex = 0 // Always start with first video
        isSequentialPlaybackEnabled = mids.count > 1
        
        if isNewSequence {
            print("DEBUG: [GRID VIDEO CONTEXT] Setup NEW sequential playback for \(mids.count) videos - starting at index 0")
            // Pause all existing players when starting new sequence
            for (mid, player) in players {
                if mids.contains(mid) {
                    player.seek(to: .zero) // Reset video position
                }
            }
        } else {
            print("DEBUG: [GRID VIDEO CONTEXT] Setup \(videoMids.isEmpty ? "FIRST TIME" : "EXISTING") sequential playback for \(mids.count) videos - starting at index 0")
        }
    }
    
    /// Stop sequential playback
    func stopSequentialPlayback() {
        videoMids = []
        currentVideoIndex = -1
        isSequentialPlaybackEnabled = false
        
        // Pause all players
        for (_, player) in players {
            player.pause()
        }
        
        print("DEBUG: [GRID VIDEO CONTEXT] Stopped sequential playback")
    }
    
    /// Check if a video should play based on sequential logic and visibility
    func shouldPlayVideo(for videoMid: String) -> Bool {
        // Must be visible to play
        guard visibleVideoMids.contains(videoMid) else {
            print("DEBUG: [GRID VIDEO CONTEXT] Video \(videoMid) should not play - not visible")
            return false
        }
        
        // Single video case
        if videoMids.count == 1 && videoMids.first == videoMid {
            print("DEBUG: [GRID VIDEO CONTEXT] Single video playback - video \(videoMid) should play: true")
            return true
        }
        
        // Sequential playback case
        if isSequentialPlaybackEnabled,
           let videoIndex = videoMids.firstIndex(of: videoMid) {
            let shouldPlay = videoIndex == currentVideoIndex
            print("DEBUG: [GRID VIDEO CONTEXT] Sequential playback - video \(videoMid) should play: \(shouldPlay) (current index: \(currentVideoIndex))")
            return shouldPlay
        }
        
        print("DEBUG: [GRID VIDEO CONTEXT] Video \(videoMid) should not play - no matching conditions")
        return false
    }
    
    /// Set video visibility state
    func setVideoVisible(_ videoMid: String, isVisible: Bool) {
        if isVisible {
            visibleVideoMids.insert(videoMid)
            print("DEBUG: [GRID VIDEO CONTEXT] Video \(videoMid) became visible")
            
            // Start playback if this video should play
            if shouldPlayVideo(for: videoMid) {
                startPlayback(for: videoMid)
            }
        } else {
            visibleVideoMids.remove(videoMid)
            print("DEBUG: [GRID VIDEO CONTEXT] Video \(videoMid) became invisible")
            
            // Pause when not visible
            pausePlayback(for: videoMid)
        }
    }
    
    /// Handle video finished playing (for sequential playback)
    func onVideoFinished(for videoMid: String) {
        guard isSequentialPlaybackEnabled,
              let finishedIndex = videoMids.firstIndex(of: videoMid),
              finishedIndex == currentVideoIndex else { return }
        
        // Move to next video
        let nextIndex = finishedIndex + 1
        if nextIndex < videoMids.count {
            currentVideoIndex = nextIndex
            let nextVideoMid = videoMids[nextIndex]
            print("DEBUG: [GRID VIDEO CONTEXT] Video finished - moving to next: \(nextVideoMid) (index: \(nextIndex))")
            
            // Start next video if it's visible
            if visibleVideoMids.contains(nextVideoMid) {
                startPlayback(for: nextVideoMid)
            }
        } else {
            print("DEBUG: [GRID VIDEO CONTEXT] Sequential playback completed")
            stopSequentialPlayback()
        }
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
    
    // MARK: - Private Methods
    
    /// Start playback for a video
    private func startPlayback(for videoMid: String) {
        guard let player = players[videoMid] else {
            print("DEBUG: [GRID VIDEO CONTEXT] No player found for playback: \(videoMid)")
            return
        }
        
        guard player.status == .readyToPlay || player.currentItem?.status == .readyToPlay else {
            print("DEBUG: [GRID VIDEO CONTEXT] Player not ready for playback: \(videoMid)")
            return
        }
        
        player.play()
        print("DEBUG: [GRID VIDEO CONTEXT] Started playback for: \(videoMid)")
    }
    
    /// Pause playback for a video
    private func pausePlayback(for videoMid: String) {
        guard let player = players[videoMid] else {
            print("DEBUG: [GRID VIDEO CONTEXT] No player found for pause: \(videoMid)")
            return
        }
        
        player.pause()
        print("DEBUG: [GRID VIDEO CONTEXT] Paused playback for: \(videoMid)")
    }
    
    /// Setup KVO observer for player status changes
    private func setupPlayerObserver(for videoMid: String, player: AVPlayer) {
        let observer = player.observe(\.currentItem?.status, options: [.new, .initial]) { [weak self] player, change in
            guard let self = self, let status = change.newValue else { return }
            
            DispatchQueue.main.async {
                switch status {
                case .readyToPlay:
                    print("DEBUG: [GRID VIDEO CONTEXT] Player ready for: \(videoMid)")
                    // Start playback if this video should play and is visible
                    if self.shouldPlayVideo(for: videoMid) {
                        self.startPlayback(for: videoMid)
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
        print("DEBUG: [GRID VIDEO CONTEXT] App entered background - pausing all videos")
        for (mid, player) in players {
            player.pause()
            print("DEBUG: [GRID VIDEO CONTEXT] Paused \(mid) for background")
        }
    }
    
    /// Handle app entering foreground
    private func handleAppWillEnterForeground() {
        print("DEBUG: [GRID VIDEO CONTEXT] App entered foreground - resuming visible videos")
        for mid in visibleVideoMids {
            if shouldPlayVideo(for: mid) {
                startPlayback(for: mid)
            }
        }
    }
    
    /// Clean up all players and observers (synchronous version for deinit)
    private func cleanupSync() {
        print("DEBUG: [GRID VIDEO CONTEXT] Cleaning up context")
        
        // Remove all observers
        for (_, observer) in playerObservers {
            observer.invalidate()
        }
        playerObservers.removeAll()
        
        // Pause and remove all players
        for (mid, player) in players {
            player.pause()
            print("DEBUG: [GRID VIDEO CONTEXT] Cleaned up player for: \(mid)")
        }
        players.removeAll()
        
        // Clear state
        videoMids.removeAll()
        currentVideoIndex = -1
        isSequentialPlaybackEnabled = false
        visibleVideoMids.removeAll()
        
        // Remove app lifecycle observers
        if let observer = didEnterBackgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = willEnterForegroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

// MARK: - Extensions

extension GridVideoContext {
    /// Remove a specific video player (when no longer needed)
    func removePlayer(for videoMid: String) {
        if let observer = playerObservers.removeValue(forKey: videoMid) {
            observer.invalidate()
        }
        
        if let player = players.removeValue(forKey: videoMid) {
            player.pause()
            print("DEBUG: [GRID VIDEO CONTEXT] Removed player for: \(videoMid)")
        }
        
        visibleVideoMids.remove(videoMid)
        
        // Update sequential playback if this was the current video
        if let removedIndex = videoMids.firstIndex(of: videoMid) {
            videoMids.remove(at: removedIndex)
            if currentVideoIndex >= removedIndex && currentVideoIndex > 0 {
                currentVideoIndex -= 1
            }
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
