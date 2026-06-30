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
    static let saveVideoPosition = Notification.Name("SaveVideoPosition")
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
            guard let userInfo = notification.userInfo,
                  let videoMid = userInfo["videoMid"] as? String,
                  let contextString = userInfo["context"] as? String else {
                return
            }
            Task { @MainActor in
                self?.handleSavePosition(videoMid: videoMid, contextString: contextString)
            }
        }
    }
    
    private func handleSavePosition(videoMid: String, contextString: String) {
        // Get the player from DetailVideoManager.
        // This guard may fail during normal deactivation: TweetDetailView.onDisappear calls
        // deactivate() → clearCurrentVideo() (which saves state and nils the player) before
        // DetailMediaCell.onDisappear posts this notification. That's fine — the state was
        // already saved by clearCurrentVideo().
        guard let player = DetailVideoManager.shared.currentPlayer,
              DetailVideoManager.shared.currentVideoMid == videoMid else {
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
              let savedState = PersistentVideoStateManager.shared.getState(videoMid: videoMid, context: context) else {
            return (false, nil, nil)
        }
        
        return (true, savedState.currentTime, savedState.wasPlaying)
    }
}
