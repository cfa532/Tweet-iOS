//
//  SingletonVideoManagers.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  Singleton video managers for detail and fullscreen contexts
//

import Foundation
import AVFoundation

/// Singleton video manager for detail view context
@MainActor
class DetailVideoManager: ObservableObject {
    static let shared = DetailVideoManager()
    private init() {}
    
    @Published var currentPlayer: AVPlayer?
    @Published var currentVideoMid: String?
    @Published var isPlaying = false
    
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
        
        Task {
            do {
                print("DEBUG: [DETAIL VIDEO MANAGER] Loading asset for: \(mid)")
                let sharedAsset = try await SharedAssetCache.shared.getAsset(for: url)
                let playerItem = AVPlayerItem(asset: sharedAsset)
                let newPlayer = AVPlayer(playerItem: playerItem)
                
                // Since DetailVideoManager is @MainActor, we can directly update properties
                newPlayer.isMuted = false // Always unmuted in detail
                self.currentPlayer = newPlayer
                
                if autoPlay {
                    newPlayer.play()
                    self.isPlaying = true
                }
                
                print("DEBUG: [DETAIL VIDEO MANAGER] Successfully set current video: \(mid), player: \(newPlayer)")
            } catch {
                print("DEBUG: [DETAIL VIDEO MANAGER] Failed to load video: \(error)")
            }
        }
    }
    
    /// Clear current video
    func clearCurrentVideo() {
        currentPlayer?.pause()
        currentPlayer = nil
        currentVideoMid = nil
        isPlaying = false
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
}

/// Singleton video manager for fullscreen context
@MainActor  
class FullscreenVideoManager: ObservableObject {
    static let shared = FullscreenVideoManager()
    private init() {}
    
    @Published var currentPlayer: AVPlayer?
    @Published var currentVideoMid: String?
    @Published var isPlaying = false
    
    /// Set current video for fullscreen
    func setCurrentVideo(url: URL, mid: String, autoPlay: Bool = true) {
        // If switching to a different video, stop the current one
        if currentVideoMid != mid {
            currentPlayer?.pause()
            currentPlayer = nil
        }
        
        currentVideoMid = mid
        
        Task {
            do {
                let sharedAsset = try await SharedAssetCache.shared.getAsset(for: url)
                let playerItem = AVPlayerItem(asset: sharedAsset)
                let newPlayer = AVPlayer(playerItem: playerItem)
                
                await MainActor.run {
                    newPlayer.isMuted = false // Always unmuted in fullscreen
                    self.currentPlayer = newPlayer
                    
                    if autoPlay {
                        newPlayer.play()
                        self.isPlaying = true
                    }
                    
                    print("DEBUG: [FULLSCREEN VIDEO MANAGER] Set current video: \(mid)")
                }
            } catch {
                print("DEBUG: [FULLSCREEN VIDEO MANAGER] Failed to load video: \(error)")
            }
        }
    }
    
    /// Clear current video
    func clearCurrentVideo() {
        currentPlayer?.pause()
        currentPlayer = nil
        currentVideoMid = nil
        isPlaying = false
        print("DEBUG: [FULLSCREEN VIDEO MANAGER] Cleared current video")
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
}
