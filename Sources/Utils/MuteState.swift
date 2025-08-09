//
//  MuteState.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  Global mute state compatibility layer that exposes HproseInstance mute state
//

import SwiftUI
import Combine

/// Compatibility layer for MuteState that syncs with HproseInstance
class MuteState: ObservableObject {
    /// Shared instance that syncs with HproseInstance
    static let shared = MuteState()
    
    /// Published property that syncs with HproseInstance
    @Published var isMuted: Bool = true
    
    private var cancellable: AnyCancellable?
    
    private init() {
        // Initialize with current HproseInstance state (must be called on main queue)
        DispatchQueue.main.async { [weak self] in
            self?.isMuted = HproseInstance.shared.isMuted
        }
        
        // Keep in sync with HproseInstance
        cancellable = HproseInstance.shared.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newValue in
                self?.isMuted = newValue
            }
    }
    
    /// Toggle the global mute state
    func toggleMute() {
        HproseInstance.shared.toggleMute()
    }
    
    /// Set the global mute state
    func setMuted(_ muted: Bool) {
        HproseInstance.shared.setMuted(muted)
        // The cancellable will automatically update our local isMuted
    }
    
    /// Refresh mute state from stored preferences
    func refreshFromPreferences() {
        HproseInstance.shared.refreshMuteFromPreferences()
    }
}
