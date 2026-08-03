//
//  AudioSessionManager.swift
//  Tweet
//
//  Centralized audio session management to prevent interference with incoming calls
//

import Foundation
import AVFoundation

/// Centralized audio session manager to ensure proper audio routing
/// and prevent interference with incoming calls in communication apps
@MainActor
final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private var isUsingPlaybackCategory = false
    private var isInitialized = false

    private init() {
        // Defer audio session setup until first needed
    }

    /// Ensure audio session is initialized (called lazily)
    private func ensureInitialized() {
        guard !isInitialized else { return }
        setupAudioSession()
        isInitialized = true
    }

    /// Configure audio session for video playback without interfering with calls
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Use .ambient category with .mixWithOthers to allow incoming calls
            // This category is designed for background audio that shouldn't interfere with calls
            // It allows mixing with other audio sources and doesn't block communication apps
            try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
            isUsingPlaybackCategory = false
            
            print("DEBUG: [AudioSessionManager] Audio session configured for call-friendly playback")
        } catch {
            print("DEBUG: [AudioSessionManager] Failed to configure audio session: \(error)")
        }
    }
    
    /// Activate audio session for video playback
    func activateForVideoPlayback() {
        ensureInitialized()
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Force playback category so audio ignores the mute switch in fullscreen/detail modes
            let desiredOptions: AVAudioSession.CategoryOptions = [.mixWithOthers]
            if audioSession.category != .playback ||
                audioSession.mode != .moviePlayback ||
                audioSession.categoryOptions != desiredOptions {
                try audioSession.setCategory(.playback, mode: .moviePlayback, options: desiredOptions)
            }
            
            try audioSession.setActive(true)
            isUsingPlaybackCategory = true
        } catch {
            print("DEBUG: [AudioSessionManager] Failed to activate audio session: \(error)")
        }
    }
    
    /// Deactivate audio session when video playback stops
    /// NOTE: Does NOT call setActive(false) to avoid interrupting MediaCell playback
    /// Only changes category back to .ambient while keeping session active
    func deactivateForVideoPlayback() {
        ensureInitialized()
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // CRITICAL: Do NOT call setActive(false) as it pauses all players including MediaCell
            // Instead, just change category back to .ambient while keeping session active
            // This allows MediaCell (muted videos) to continue playing seamlessly
            if audioSession.category != .ambient ||
                audioSession.mode != .default ||
                !audioSession.categoryOptions.contains(.mixWithOthers) {
                try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            }
            // Keep session active - don't deactivate it
            // try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            isUsingPlaybackCategory = false
            print("DEBUG: [AudioSessionManager] Audio session restored to ambient (kept active for MediaCell)")
        } catch {
            print("DEBUG: [AudioSessionManager] Failed to restore audio session: \(error)")
        }
    }
    
    /// Check if audio session is properly configured for call compatibility
    func isCallCompatible() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        return audioSession.category == .ambient && audioSession.categoryOptions.contains(.mixWithOthers)
    }
    
    /// Handle audio interruption (e.g., incoming call)
    @objc func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            print("DEBUG: [AudioSessionManager] Audio interruption began - likely incoming call")
            // Audio interruption started - pause all video playback
            NotificationCenter.default.post(name: .stopAllVideos, object: nil)
            
        case .ended:
            print("DEBUG: [AudioSessionManager] Audio interruption ended")
            // Audio interruption ended - can resume playback if needed
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    print("DEBUG: [AudioSessionManager] Audio session can resume")
                }
            }
            
        @unknown default:
            break
        }
    }
    
    /// Setup audio interruption notifications
    func setupInterruptionNotifications() {
        ensureInitialized()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        
        print("DEBUG: [AudioSessionManager] Audio interruption notifications setup complete")
    }
    
    /// Cleanup audio session manager
    func cleanup() {
        NotificationCenter.default.removeObserver(self)
        deactivateForVideoPlayback()
    }
}
