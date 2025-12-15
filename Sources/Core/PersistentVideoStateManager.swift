//
//  PersistentVideoStateManager.swift
//  Tweet
//
//  Manages persistent video playback state across screen locks and player recreation
//

import Foundation
import AVFoundation

/// Persistent storage for video playback state that survives player recreation
@MainActor
class PersistentVideoStateManager: ObservableObject {
    static let shared = PersistentVideoStateManager()
    
    private init() {}
    
    // Storage for video states
    private var videoStates: [String: VideoPlaybackState] = [:]
    
    /// Video playback state
    struct VideoPlaybackState {
        let videoMid: String
        let currentTime: CMTime
        let wasPlaying: Bool
        let timestamp: Date
        let context: VideoContext // Track which screen the video is in
        
        enum VideoContext: String {
            case detailView = "detail"
            case fullScreen = "fullscreen"
            case mediaCell = "cell"
        }
    }
    
    /// Save video playback state
    func saveState(
        videoMid: String,
        currentTime: CMTime,
        wasPlaying: Bool,
        context: VideoPlaybackState.VideoContext
    ) {
        let state = VideoPlaybackState(
            videoMid: videoMid,
            currentTime: currentTime,
            wasPlaying: wasPlaying,
            timestamp: Date(),
            context: context
        )
        videoStates[videoMid] = state
        
        print("📝 [VIDEO STATE] Saved state for \(videoMid): time=\(currentTime.seconds)s, wasPlaying=\(wasPlaying), context=\(context.rawValue)")
    }
    
    /// Get saved video playback state
    func getState(videoMid: String) -> VideoPlaybackState? {
        return videoStates[videoMid]
    }
    
    /// Remove saved state for a video
    func clearState(videoMid: String) {
        videoStates.removeValue(forKey: videoMid)
        print("🗑️ [VIDEO STATE] Cleared state for \(videoMid)")
    }
    
    /// Clear states older than 1 hour
    func clearStaleStates() {
        let oneHourAgo = Date().addingTimeInterval(-3600)
        let staleMids = videoStates.filter { $0.value.timestamp < oneHourAgo }.map { $0.key }
        
        for mid in staleMids {
            videoStates.removeValue(forKey: mid)
        }
        
        if !staleMids.isEmpty {
            print("🗑️ [VIDEO STATE] Cleared \(staleMids.count) stale states")
        }
    }
    
    /// Clear all states
    func clearAllStates() {
        videoStates.removeAll()
        print("🗑️ [VIDEO STATE] Cleared all states")
    }
    
    /// Check if we should restore playback for a video
    func shouldRestorePlayback(videoMid: String, context: VideoPlaybackState.VideoContext) -> Bool {
        guard let state = getState(videoMid: videoMid) else {
            return false
        }
        
        // Allow cross-context restoration: mediaCell -> detailView or fullScreen
        // This allows videos to continue from where they were playing in the feed when opened in detail/fullscreen
        let contextMatches = state.context == context || 
            (state.context == .mediaCell && (context == .detailView || context == .fullScreen))
        
        guard contextMatches else {
            print("⚠️ [VIDEO STATE] Context mismatch for \(videoMid): saved=\(state.context.rawValue), current=\(context.rawValue)")
            return false
        }
        
        // Only restore if saved within last 5 minutes
        let fiveMinutesAgo = Date().addingTimeInterval(-300)
        guard state.timestamp > fiveMinutesAgo else {
            print("⚠️ [VIDEO STATE] State too old for \(videoMid): \(Date().timeIntervalSince(state.timestamp))s ago")
            return false
        }
        
        return true
    }
}
