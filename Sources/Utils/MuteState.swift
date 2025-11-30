//
//  MuteState.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/8/10.
//
import SwiftUI

// MARK: - Global Mute State
class MuteState: ObservableObject {
    static let shared = MuteState()
    @Published var isMuted: Bool = true { // Default to muted (matches PreferenceHelper default)
        didSet {
            Task { @MainActor in
                // Save to preferences whenever the mute state changes
                if oldValue != isMuted {
                    HproseInstance.shared.preferenceHelper?.setSpeakerMute(isMuted)
                    print("DEBUG: [MUTE STATE] Mute state changed to: \(isMuted)")
                }
            }
        }
    }
    
    private init() {
        // Initialize from saved preference
        refreshFromPreferences()
        
        NSLog("🔇 [MUTE STATE INIT] MuteState initialized - isMuted: \(isMuted)")
        
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
        // CRITICAL: Always try preferenceHelper first, but fall back to direct UserDefaults read
        let newMuteState: Bool
        if let helper = HproseInstance.shared.preferenceHelper {
            newMuteState = helper.getSpeakerMute()
        } else {
            // Fallback: Read directly from UserDefaults
            // IMPORTANT: Match PreferenceHelper's default logic (default to muted if not set)
            if UserDefaults.standard.object(forKey: "speakerMuted") == nil {
                newMuteState = true  // Default to muted
            } else {
                newMuteState = UserDefaults.standard.bool(forKey: "speakerMuted")
            }
        }
        
        if self.isMuted != newMuteState {
            DispatchQueue.main.async {
                self.isMuted = newMuteState
                print("DEBUG: [MUTE STATE] Synced from UserDefaults change: \(newMuteState)")
            }
        }
    }
    
    func refreshFromPreferences() {
        // Read the current preference and update the published property
        // CRITICAL: Always try preferenceHelper first, but fall back to direct UserDefaults read
        // This ensures we get the correct mute state even if preferenceHelper isn't ready yet
        let savedMuteState: Bool
        if let helper = HproseInstance.shared.preferenceHelper {
            savedMuteState = helper.getSpeakerMute()
        } else {
            // Fallback: Read directly from UserDefaults if preferenceHelper not ready
            // This prevents race condition during app startup where videos play unmuted
            // IMPORTANT: Match PreferenceHelper's default logic (default to muted if not set)
            if UserDefaults.standard.object(forKey: "speakerMuted") == nil {
                savedMuteState = true  // Default to muted
            } else {
                savedMuteState = UserDefaults.standard.bool(forKey: "speakerMuted")
            }
            print("DEBUG: [MUTE STATE] PreferenceHelper not ready, reading directly from UserDefaults: \(savedMuteState)")
        }
        
        if self.isMuted != savedMuteState {
            self.isMuted = savedMuteState
            print("DEBUG: [MUTE STATE] Refreshed from preferences: \(savedMuteState)")
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
