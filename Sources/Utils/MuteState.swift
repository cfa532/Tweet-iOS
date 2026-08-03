//
//  MuteState.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/8/10.
//
import SwiftUI

// MARK: - Global Mute State
@MainActor
class MuteState: ObservableObject {
    static let shared = MuteState()
    @Published var isMuted: Bool = true { // Default to muted (matches PreferenceHelper default)
        didSet {
            // Save to preferences whenever the mute state changes
            if oldValue != isMuted {
                HproseInstance.shared.preferenceHelper?.setSpeakerMute(isMuted)
                print("DEBUG: [MUTE STATE] Mute state changed to: \(isMuted)")
            }
        }
    }
    
    private init() {
        // Initialize from saved preference
        refreshFromPreferences()
        
        print("🔇 [MUTE STATE INIT] MuteState initialized - isMuted: \(isMuted)")
        
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
    
    // NotificationCenter invokes selector-based observers synchronously on whatever
    // thread posts the notification. UserDefaults.didChangeNotification can be posted
    // from a background thread (e.g. PencilKit's Scribble setup on iPad calling
    // -[NSUserDefaults registerDefaults:] lazily off-main), which would trip Swift's
    // main-actor isolation check on this @objc method and crash. Stay nonisolated here
    // and hop to the main actor explicitly for the actual work.
    @objc private nonisolated func userDefaultsDidChange() {
        Task { @MainActor in
            self.syncMuteStateFromUserDefaults()
        }
    }

    @MainActor
    private func syncMuteStateFromUserDefaults() {
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
            self.isMuted = newMuteState
            print("DEBUG: [MUTE STATE] Synced from UserDefaults change: \(newMuteState)")
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
