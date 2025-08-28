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
class AudioSessionManager {
    static let shared = AudioSessionManager()
    
    private init() {
        setupAudioSession()
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
            
            print("DEBUG: [AudioSessionManager] Audio session configured for call-friendly playback")
        } catch {
            print("DEBUG: [AudioSessionManager] Failed to configure audio session: \(error)")
        }
    }
    
    /// Activate audio session for video playback
    func activateForVideoPlayback() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Ensure audio session is active with ambient category
            if audioSession.category != .ambient {
                try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            }
            
            if !audioSession.isOtherAudioPlaying {
                try audioSession.setActive(true)
            }
            
            print("DEBUG: [AudioSessionManager] Audio session activated for video playback")
        } catch {
            print("DEBUG: [AudioSessionManager] Failed to activate audio session: \(error)")
        }
    }
    
    /// Deactivate audio session when video playback stops
    func deactivateForVideoPlayback() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Only deactivate if no other audio is playing
            if !audioSession.isOtherAudioPlaying {
                try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                print("DEBUG: [AudioSessionManager] Audio session deactivated")
            }
        } catch {
            print("DEBUG: [AudioSessionManager] Failed to deactivate audio session: \(error)")
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
