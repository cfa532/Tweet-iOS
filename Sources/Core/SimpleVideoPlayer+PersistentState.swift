//
//  SimpleVideoPlayer+PersistentState.swift
//  Tweet
//
//  Extension to integrate SimpleVideoPlayer with PersistentVideoStateManager
//  Add this file to your project and SimpleVideoPlayer will automatically
//  save/restore video positions on screen lock
//

import Foundation
import AVFoundation
import SwiftUI

// MARK: - Notification Names
extension Notification.Name {
    static let restoreVideoPosition = Notification.Name("RestoreVideoPosition")
    static let saveVideoPosition = Notification.Name("SaveVideoPosition")
    static let requestVideoPosition = Notification.Name("RequestVideoPosition")
    static let videoPositionResponse = Notification.Name("VideoPositionResponse")
}

// MARK: - SimpleVideoPlayer Helper for Persistent State
/// This extension provides helper methods that SimpleVideoPlayer can use
/// to integrate with PersistentVideoStateManager
@MainActor
class SimpleVideoPlayerStateHelper: ObservableObject {
    static let shared = SimpleVideoPlayerStateHelper()
    
    private init() {
        setupNotificationObservers()
    }
    
    private func setupNotificationObservers() {
        // Listen for save requests from DetailMediaCell
        NotificationCenter.default.addObserver(
            forName: .saveVideoPosition,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleSavePosition(notification)
            }
        }
        
        // Listen for restore requests from DetailMediaCell
        NotificationCenter.default.addObserver(
            forName: .restoreVideoPosition,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleRestorePosition(notification)
            }
        }
        
        // Listen for position requests (from views that need current position)
        NotificationCenter.default.addObserver(
            forName: .requestVideoPosition,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handlePositionRequest(notification)
            }
        }
    }
    
    private func handleSavePosition(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let videoMid = userInfo["videoMid"] as? String,
              let contextString = userInfo["context"] as? String else {
            return
        }
        
        // Get the player from DetailVideoManager
        guard let player = DetailVideoManager.shared.currentPlayer,
              DetailVideoManager.shared.currentVideoMid == videoMid else {
            print("⚠️ [StateHelper] No player found for videoMid: \(videoMid)")
            return
        }
        
        let wasPlaying = player.rate > 0
        let currentTime = player.currentTime()
        
        // Parse context
        let context: PersistentVideoStateManager.VideoPlaybackState.VideoContext
        switch contextString {
        case "detail":
            context = .detailView
        case "fullscreen":
            context = .fullScreen
        default:
            context = .mediaCell
        }
        
        PersistentVideoStateManager.shared.saveState(
            videoMid: videoMid,
            currentTime: currentTime,
            wasPlaying: wasPlaying,
            context: context
        )
        
        print("💾 [StateHelper] Saved state: time=\(currentTime.seconds)s, wasPlaying=\(wasPlaying), context=\(context.rawValue)")
    }
    
    private func handleRestorePosition(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let videoMid = userInfo["videoMid"] as? String,
              let time = userInfo["time"] as? CMTime,
              let wasPlaying = userInfo["wasPlaying"] as? Bool else {
            return
        }
        
        // Get the player from DetailVideoManager
        guard let player = DetailVideoManager.shared.currentPlayer,
              DetailVideoManager.shared.currentVideoMid == videoMid else {
            print("⚠️ [StateHelper] No player found for videoMid: \(videoMid)")
            return
        }
        
        print("🔄 [StateHelper] Restoring position for \(videoMid): \(time.seconds)s, wasPlaying: \(wasPlaying)")
        
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            guard finished else { return }
            
            Task { @MainActor in
                print("✅ [StateHelper] Restored position to \(time.seconds)s")
                
                if wasPlaying {
                    player.play()
                    DetailVideoManager.shared.isPlaying = true
                    print("▶️ [StateHelper] Resumed playback")
                }
            }
        }
    }
    
    private func handlePositionRequest(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let videoMid = userInfo["videoMid"] as? String,
              let responseId = userInfo["responseId"] as? String else {
            return
        }
        
        // Get current position from DetailVideoManager
        guard let player = DetailVideoManager.shared.currentPlayer,
              DetailVideoManager.shared.currentVideoMid == videoMid else {
            return
        }
        
        let wasPlaying = player.rate > 0
        let currentTime = player.currentTime()
        
        // Send response
        NotificationCenter.default.post(
            name: .videoPositionResponse,
            object: nil,
            userInfo: [
                "responseId": responseId,
                "videoMid": videoMid,
                "time": currentTime,
                "wasPlaying": wasPlaying
            ]
        )
    }
    
    /// Manually save current state for a video
    func saveCurrentState(videoMid: String, context: PersistentVideoStateManager.VideoPlaybackState.VideoContext) {
        guard let player = DetailVideoManager.shared.currentPlayer,
              DetailVideoManager.shared.currentVideoMid == videoMid else {
            return
        }
        
        let wasPlaying = player.rate > 0
        let currentTime = player.currentTime()
        
        PersistentVideoStateManager.shared.saveState(
            videoMid: videoMid,
            currentTime: currentTime,
            wasPlaying: wasPlaying,
            context: context
        )
        
        print("💾 [StateHelper] Manually saved state: time=\(currentTime.seconds)s, wasPlaying=\(wasPlaying)")
    }
    
    /// Check if there's a saved state for restoration
    func hasSavedState(videoMid: String, context: PersistentVideoStateManager.VideoPlaybackState.VideoContext) -> (hasState: Bool, time: CMTime?, wasPlaying: Bool?) {
        guard PersistentVideoStateManager.shared.shouldRestorePlayback(videoMid: videoMid, context: context),
              let savedState = PersistentVideoStateManager.shared.getState(videoMid: videoMid) else {
            return (false, nil, nil)
        }
        
        return (true, savedState.currentTime, savedState.wasPlaying)
    }
}
