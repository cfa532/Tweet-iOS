//
//  SingletonVideoManagers.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  Singleton video managers for detail and fullscreen contexts
//

import Foundation
import AVFoundation
import UIKit

/// Singleton video manager for detail view context
@MainActor
class DetailVideoManager: NSObject, ObservableObject {
    static let shared = DetailVideoManager()
    private override init() {
        super.init()
        setupAppLifecycleNotifications()
        setupAudioInterruptionNotifications()
    }
    
    @Published var currentPlayer: AVPlayer?
    @Published var currentVideoMid: String?
    @Published var isPlaying = false
    
    private var videoCompletionObserver: NSObjectProtocol?
    
    /// Setup audio interruption notifications to handle incoming calls
    private func setupAudioInterruptionNotifications() {
        AudioSessionManager.shared.setupInterruptionNotifications()
    }
    
    /// Set current video for detail view
    func setCurrentVideo(url: URL, mid: String, autoPlay: Bool = true) {
        // If switching to a different video, stop the current one
        if currentVideoMid != mid {
            currentPlayer?.pause()
            
            // Remove KVO observer from previous player item
            if let player = currentPlayer, let playerItem = player.currentItem {
                playerItem.removeObserver(self, forKeyPath: "status")
            }
            
            // Remove video completion observer from previous video
            if let observer = videoCompletionObserver {
                NotificationCenter.default.removeObserver(observer)
                videoCompletionObserver = nil
            }
        }
        
        currentVideoMid = mid
        
        // Activate audio session for video playback
        AudioSessionManager.shared.activateForVideoPlayback()
        
        Task.detached(priority: .userInitiated) {
            do {
                
                // Create independent player with disk caching support
                // Get the asset from SharedAssetCache (which uses CachingPlayerItem for HLS)
                // but create our own independent player instance
                let asset = try await SharedAssetCache.shared.getAsset(for: url, tweetId: mid)
                let playerItem = await AVPlayerItem(asset: asset)
                let newPlayer = AVPlayer(playerItem: playerItem)
                
                await MainActor.run {
                    // Store the new player (independent from MediaCell)
                    self.currentPlayer = newPlayer
                    
                    // Configure the player
                    self.currentPlayer?.isMuted = false // Always unmuted in detail
                    
                    // Add observers for the player item
                    if let playerItem = self.currentPlayer?.currentItem {
                        // Add KVO observer for player item status
                        playerItem.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
                        
                        // Add video completion observer
                        self.setupVideoCompletionObserver(playerItem)
                        
                        // Check if player item is ready immediately
                        if playerItem.status == .readyToPlay {
                            if autoPlay {
                                self.currentPlayer?.play()
                                self.isPlaying = true
                            }
                        }
                    }
                    
                    // Auto-play immediately if requested
                    if autoPlay {
                        self.currentPlayer?.play()
                        self.isPlaying = true
                        print("DEBUG: [DETAIL VIDEO MANAGER] Auto-playing player for mediaID: \(mid)")
                    }
                }
            } catch {
                await MainActor.run {
                    print("ERROR: [DETAIL VIDEO MANAGER] Failed to load video: \(error)")
                }
            }
        }
    }
    
    /// Clear current video
    func clearCurrentVideo() {
        // Remove KVO observer before clearing
        if let player = currentPlayer, let playerItem = player.currentItem {
            playerItem.removeObserver(self, forKeyPath: "status")
        }
        
        // Remove video completion observer
        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
        
        currentPlayer?.pause()
        currentPlayer = nil
        currentVideoMid = nil
        isPlaying = false
        
        // Deactivate audio session when video is cleared
        AudioSessionManager.shared.deactivateForVideoPlayback()
        
    }
    
    /// Setup video completion observer
    private func setupVideoCompletionObserver(_ playerItem: AVPlayerItem) {
        print("DEBUG: [DETAIL VIDEO MANAGER] Setting up video completion observer for \(currentVideoMid ?? "unknown")")
        
        // Remove existing observer if any
        if let observer = videoCompletionObserver {
            print("DEBUG: [DETAIL VIDEO MANAGER] Removing existing video completion observer for \(currentVideoMid ?? "unknown")")
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
        
        // Add new observer for video completion
        videoCompletionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard let player = self.currentPlayer else { 
                    print("DEBUG: [DETAIL VIDEO MANAGER] No current player when video finished")
                    return 
                }
                let currentMid = self.currentVideoMid
                print("DEBUG: [DETAIL VIDEO MANAGER] Video completion notification received for \(currentMid ?? "unknown")")
                print("DEBUG: [DETAIL VIDEO MANAGER] Notification object: \(notification.object ?? "nil")")
                print("DEBUG: [DETAIL VIDEO MANAGER] Player current item: \(player.currentItem?.description ?? "nil")")
                
                // Reset video to beginning (but don't auto-restart)
                player.seek(to: .zero) { finished in
                    guard finished else { 
                        print("DEBUG: [DETAIL VIDEO MANAGER] Seek to zero failed for \(currentMid ?? "unknown")")
                        return 
                    }
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        print("DEBUG: [DETAIL VIDEO MANAGER] Successfully seeked to zero for \(currentMid ?? "unknown")")
                        print("DEBUG: [DETAIL VIDEO MANAGER] Video reset to beginning, ready to replay for \(currentMid ?? "unknown")")
                        self.isPlaying = false
                    }
                }
            }
        }
        
        print("DEBUG: [DETAIL VIDEO MANAGER] Video completion observer setup complete for \(currentVideoMid ?? "unknown")")
    }
    
    /// Toggle play/pause
    func togglePlayback() {
        guard let player = currentPlayer else { return }
        
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }
    
    // MARK: - KVO Observer
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "status" {
            if let playerItem = object as? AVPlayerItem {
                if playerItem.status == .readyToPlay {
                    if let player = currentPlayer, player.currentItem == playerItem {
                        player.play()
                        isPlaying = true
                    }
                } else if playerItem.status == .failed {
                    print("ERROR: [DETAIL VIDEO MANAGER] Player item failed to load")
                }
            }
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
    
    private func handleAppWillEnterForeground() {
        refreshVideoLayer()
    }
    
    private func handleAppDidBecomeActive() {
        // Refresh immediately when app becomes active
        refreshVideoLayer()
    }
    
    private func refreshVideoLayer() {
        guard let player = currentPlayer else { return }
        
        print("DEBUG: [DetailVideoManager] Refreshing video layer after background/foreground transition")
        
        // Store current state
        let wasPlaying = isPlaying
        let currentTime = player.currentTime()
        
        // Pause first to ensure clean state
        player.pause()
        
        // Force a seek with zero tolerance to refresh the video layer
        // This triggers the AVPlayerLayer to redraw its contents
        player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            if finished {
                print("DEBUG: [DetailVideoManager] Seek completed after layer refresh")
                if wasPlaying {
                    // Resume playback if it was playing before
                    player.play()
                    Task { @MainActor [weak self] in
                        self?.isPlaying = true
                    }
                }
            }
        }
    }
}
