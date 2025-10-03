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
class DetailVideoManager: ObservableObject {
    static let shared = DetailVideoManager()
    private init() {
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
            currentPlayer = nil
        }
        
        currentVideoMid = mid
        
        // Activate audio session for video playback
        AudioSessionManager.shared.activateForVideoPlayback()
        
        Task.detached(priority: .userInitiated) {
            do {
                print("DEBUG: [DETAIL VIDEO MANAGER] Creating completely independent player for: \(mid)")
                
                // Use the exact same approach as SimpleVideoPlayer but create independent player
                // This ensures proper asset loading while maintaining independence
                let asset = try await SharedAssetCache.shared.getAsset(for: url, tweetId: mid)
                let playerItem = AVPlayerItem(asset: asset)
                let independentPlayer = AVPlayer(playerItem: playerItem)
                
                await MainActor.run {
                    // Configure the independent player
                    independentPlayer.isMuted = false // Always unmuted in detail
                    self.currentPlayer = independentPlayer
                    
                    if autoPlay {
                        independentPlayer.play()
                        self.isPlaying = true
                        print("DEBUG: [DETAIL VIDEO MANAGER] Started independent player for: \(mid)")
                    }
                    
                    print("DEBUG: [DETAIL VIDEO MANAGER] Successfully created independent player for: \(mid)")
                }
            } catch {
                await MainActor.run {
                    print("DEBUG: [DETAIL VIDEO MANAGER] Failed to create independent player: \(error)")
                }
            }
        }
    }
    
    /// Clear current video
    func clearCurrentVideo() {
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

