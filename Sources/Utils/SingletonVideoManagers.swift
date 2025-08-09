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
        // If switching to a different video, stop the current one
        if currentVideoMid != mid {
            currentPlayer?.pause()
            currentPlayer = nil
        }
        
        currentVideoMid = mid
        
        Task {
            let sharedAsset = await SharedAssetCache.shared.getAsset(for: url)
            let playerItem = AVPlayerItem(asset: sharedAsset)
            let newPlayer = AVPlayer(playerItem: playerItem)
            
            await MainActor.run {
                newPlayer.isMuted = false // Always unmuted in detail
                self.currentPlayer = newPlayer
                
                if autoPlay {
                    newPlayer.play()
                    self.isPlaying = true
                }
                
                print("DEBUG: [DETAIL VIDEO MANAGER] Set current video: \(mid)")
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
            let sharedAsset = await SharedAssetCache.shared.getAsset(for: url)
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
