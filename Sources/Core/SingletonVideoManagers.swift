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
    
    /// Setup audio interruption notifications to handle incoming calls
    private func setupAudioInterruptionNotifications() {
        AudioSessionManager.shared.setupInterruptionNotifications()
    }
    
    /// Set current video for detail view
    func setCurrentVideo(url: URL, mid: String, autoPlay: Bool = true) {
        print("DEBUG: [DETAIL VIDEO MANAGER] Setting current video: \(mid), autoPlay: \(autoPlay)")
        
        // If switching to a different video, stop the current one
        if currentVideoMid != mid {
            print("DEBUG: [DETAIL VIDEO MANAGER] Switching from \(currentVideoMid ?? "none") to \(mid)")
            currentPlayer?.pause()
            
            // Remove KVO observer from previous player item
            if let player = currentPlayer, let playerItem = player.currentItem {
                playerItem.removeObserver(self, forKeyPath: "status")
            }
        }
        
        currentVideoMid = mid
        
        // Activate audio session for video playback
        AudioSessionManager.shared.activateForVideoPlayback()
        
        Task.detached(priority: .userInitiated) {
            do {
                print("DEBUG: [DETAIL VIDEO MANAGER] Loading new video for shared player: \(mid)")
                
                // Use the exact same approach as SimpleVideoPlayer but create independent player
                // This ensures proper asset loading while maintaining independence
                let asset = try await SharedAssetCache.shared.getAsset(for: url, tweetId: mid)
                let playerItem = await AVPlayerItem(asset: asset)
                
                await MainActor.run {
                    // Create player only if it doesn't exist, otherwise just replace the player item
                    if self.currentPlayer == nil {
                        print("DEBUG: [DETAIL VIDEO MANAGER] Creating shared independent player")
                        self.currentPlayer = AVPlayer()
                    }
                    
                    // Replace the player item with the new video
                    self.currentPlayer?.replaceCurrentItem(with: playerItem)
                    
                    // Configure the player
                    self.currentPlayer?.isMuted = false // Always unmuted in detail
                    
                    // Set up player item status monitoring
                    print("DEBUG: [DETAIL VIDEO MANAGER] Player item status for \(mid): \(playerItem.status.rawValue)")
                    
                    // Add KVO observer for player item status
                    playerItem.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
                    
                    // Check if player item is ready immediately
                    if playerItem.status == .readyToPlay {
                        if autoPlay {
                            self.currentPlayer?.play()
                            self.isPlaying = true
                            print("DEBUG: [DETAIL VIDEO MANAGER] Started shared player for: \(mid) - player item ready immediately")
                        }
                    } else {
                        print("DEBUG: [DETAIL VIDEO MANAGER] Player item not ready yet for: \(mid), waiting for ready status")
                    }
                    
                    print("DEBUG: [DETAIL VIDEO MANAGER] Successfully loaded video for shared player: \(mid)")
                }
            } catch {
                await MainActor.run {
                    print("DEBUG: [DETAIL VIDEO MANAGER] Failed to load video: \(error)")
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
        
        currentPlayer?.pause()
        currentPlayer = nil
        currentVideoMid = nil
        isPlaying = false
        
        // Deactivate audio session when video is cleared
        AudioSessionManager.shared.deactivateForVideoPlayback()
        
        print("DEBUG: [DETAIL VIDEO MANAGER] Cleared current video")
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
                    print("DEBUG: [DETAIL VIDEO MANAGER] Player item became ready to play")
                    if let player = currentPlayer, player.currentItem == playerItem {
                        player.play()
                        isPlaying = true
                        print("DEBUG: [DETAIL VIDEO MANAGER] Started playback after player item became ready")
                    }
                } else if playerItem.status == .failed {
                    print("DEBUG: [DETAIL VIDEO MANAGER] Player item failed to load")
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
        print("DEBUG: [DETAIL VIDEO MANAGER] App will enter foreground - refreshing video layer")
        refreshVideoLayer()
    }
    
    private func handleAppDidBecomeActive() {
        print("DEBUG: [DETAIL VIDEO MANAGER] App did become active - ensuring video layer visibility")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.refreshVideoLayer()
        }
    }
    
    private func refreshVideoLayer() {
        guard let player = currentPlayer else { return }
        
        print("DEBUG: [DETAIL VIDEO MANAGER] Refreshing video layer")
        
        // Store current state
        let wasPlaying = isPlaying
        let currentTime = player.currentTime()
        
        // Force a seek to refresh the video layer
        player.seek(to: currentTime) { finished in
            if finished && wasPlaying {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    print("DEBUG: [DETAIL VIDEO MANAGER] Resuming playback after refresh")
                    player.play()
                    self.isPlaying = true
                }
            }
        }
    }
}

