//
//  MuteState.swift
//  Tweet
//
//  Created by 超方 on 2025/8/10.
//
import SwiftUI

// MARK: - Global Mute State
class MuteState: ObservableObject {
    static let shared = MuteState()
    @Published var isMuted: Bool = false { // Default to unmuted
        didSet {
            Task { @MainActor in
                // Save to preferences whenever the mute state changes
                if oldValue != isMuted {
                    await HproseInstance.shared.preferenceHelper?.setSpeakerMute(isMuted)
                    print("DEBUG: [MUTE STATE] Mute state changed to: \(isMuted)")
                }
            }
        }
    }
    
    private init() {
        // Initialize from saved preference
        refreshFromPreferences()
        
        // Listen for UserDefaults changes to sync with database preference
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func userDefaultsDidChange() {
        // Check for changes to the speakerMuted key
        // If the key was removed (reset to default), default to unmuted
        Task {
            let newMuteState = await HproseInstance.shared.preferenceHelper?.getSpeakerMute() ?? false
            if self.isMuted != newMuteState {
                await MainActor.run {
                    self.isMuted = newMuteState
                    print("DEBUG: [MUTE STATE] Synced from UserDefaults change: \(newMuteState)")
                }
            }
        }
    }
    
    func refreshFromPreferences() {
        // Read the current preference and update the published property
        Task {
            let savedMuteState = await HproseInstance.shared.preferenceHelper?.getSpeakerMute() ?? false
            if self.isMuted != savedMuteState {
                await MainActor.run {
                    self.isMuted = savedMuteState
                }
            }
        }
    }
    
    func toggleMute() {
        isMuted.toggle()
        // Note: The didSet observer will handle saving to preferences
    }
    
    func setMuted(_ muted: Bool) {
        if self.isMuted != muted {
            self.isMuted = muted
            // Note: The didSet observer will handle saving to preferences
        }
    }
}
