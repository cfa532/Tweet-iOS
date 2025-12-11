//
//  VideoPlaybackSettings.swift
//  Tweet
//
//  User preferences for video playback behavior
//

import Foundation
import SwiftUI

/// Video playback preferences
@MainActor
class VideoPlaybackSettings: ObservableObject {
    static let shared = VideoPlaybackSettings()
    
    private init() {}
    
    /// Whether to continue playback when screen locks (future feature)
    /// Currently disabled - always pauses on screen lock
    @Published var continuePlaybackOnScreenLock: Bool = false {
        didSet {
            UserDefaults.standard.set(continuePlaybackOnScreenLock, forKey: "continuePlaybackOnScreenLock")
        }
    }
    
    /// Load settings from UserDefaults
    func loadSettings() {
        continuePlaybackOnScreenLock = UserDefaults.standard.bool(forKey: "continuePlaybackOnScreenLock")
    }
}
