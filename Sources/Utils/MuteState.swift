//
//  MuteState.swift
//  Tweet
//
//  Created by 超方 on 2025/8/10.
//
import SwiftUI
import Foundation

// MARK: - Global Mute State
class MuteState: ObservableObject {
    static let shared = MuteState()
    @Published var isMuted: Bool = true // Default to muted
    
    private init() {
        // Initialize from saved preference
        refreshFromPreferences()
    }
    
    func refreshFromPreferences() {
        // Read the current preference and update the published property
        let savedMuteState = HproseInstance.shared.preferenceHelper?.getSpeakerMute() ?? true
        if self.isMuted != savedMuteState {
            self.isMuted = savedMuteState
        }
    }
    
    func toggleMute() {
        isMuted.toggle()
        // Save to preferences immediately when mute state changes
        HproseInstance.shared.preferenceHelper?.setSpeakerMute(isMuted)
        print("DEBUG: [MUTE STATE] Mute state changed to: \(isMuted)")
    }
    
    func setMuted(_ muted: Bool) {
        if self.isMuted != muted {
            self.isMuted = muted
            // Save to preferences immediately when mute state changes
            HproseInstance.shared.preferenceHelper?.setSpeakerMute(isMuted)
            print("DEBUG: [MUTE STATE] Mute state set to: \(isMuted)")
        }
    }
}

// MARK: - Refresh Debouncer
/// Manages debounced refresh operations to prevent rapid refresh calls
class RefreshDebouncer: ObservableObject {
    private var refreshTimer: Timer?
    private let debounceInterval: TimeInterval
    
    init(debounceInterval: TimeInterval = 1.0) {
        self.debounceInterval = debounceInterval
    }
    
    /// Debounced refresh function that delays execution
    func debouncedRefresh(operation: @escaping () async -> Void) async {
        // Cancel any existing timer
        refreshTimer?.invalidate()
        
        // Create a new timer that will execute the operation after the debounce interval
        refreshTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { _ in
            Task {
                await operation()
            }
        }
    }
    
    /// Cancel any pending refresh operation
    func cancelRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    deinit {
        refreshTimer?.invalidate()
    }
}

/// SwiftUI view modifier for debounced refresh
struct DebouncedRefreshModifier: ViewModifier {
    let debouncer: RefreshDebouncer
    let refreshOperation: () async -> Void
    
    func body(content: Content) -> some View {
        content
            .refreshable {
                await debouncer.debouncedRefresh(operation: refreshOperation)
            }
    }
}

/// Extension to add debounced refresh to any view
extension View {
    func debouncedRefresh(
        debouncer: RefreshDebouncer,
        operation: @escaping () async -> Void
    ) -> some View {
        modifier(DebouncedRefreshModifier(debouncer: debouncer, refreshOperation: operation))
    }
}
