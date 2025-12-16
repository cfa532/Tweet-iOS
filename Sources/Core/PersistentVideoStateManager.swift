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
    
    // Storage for video states, isolated by context (detail vs fullscreen vs feed cell)
    // This prevents one surface (e.g. feed) from overwriting another (e.g. detail view).
    private var videoStates: [VideoPlaybackState.VideoContext: [String: VideoPlaybackState]] = [:]
    
    /// Video playback state
    struct VideoPlaybackState {
        let videoMid: String
        let currentTime: CMTime
        let wasPlaying: Bool
        let timestamp: Date
        let context: VideoContext // Track which screen the video is in
        
        enum VideoContext: String, CaseIterable {
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
        var bucket = videoStates[context] ?? [:]
        bucket[videoMid] = state
        videoStates[context] = bucket
        
        print("📝 [VIDEO STATE] Saved state for \(videoMid): time=\(currentTime.seconds)s, wasPlaying=\(wasPlaying), context=\(context.rawValue)")
    }
    
    /// Get saved video playback state
    func getState(videoMid: String, context: VideoPlaybackState.VideoContext) -> VideoPlaybackState? {
        return videoStates[context]?[videoMid]
    }
    
    /// Remove saved state for a video
    func clearState(videoMid: String, context: VideoPlaybackState.VideoContext) {
        videoStates[context]?.removeValue(forKey: videoMid)
        print("🗑️ [VIDEO STATE] Cleared state for \(videoMid) in context \(context.rawValue)")
    }

    /// Remove saved state for a video across all contexts
    func clearState(videoMid: String) {
        for context in VideoPlaybackState.VideoContext.allCases {
            videoStates[context]?.removeValue(forKey: videoMid)
        }
        print("🗑️ [VIDEO STATE] Cleared state for \(videoMid) (all contexts)")
    }
    
    /// Clear states older than 1 hour
    func clearStaleStates() {
        let oneHourAgo = Date().addingTimeInterval(-3600)
        var removedCount = 0

        for context in VideoPlaybackState.VideoContext.allCases {
            guard var bucket = videoStates[context] else { continue }
            let staleMids = bucket.filter { $0.value.timestamp < oneHourAgo }.map { $0.key }
            for mid in staleMids {
                bucket.removeValue(forKey: mid)
                removedCount += 1
            }
            videoStates[context] = bucket
        }

        if removedCount > 0 {
            print("🗑️ [VIDEO STATE] Cleared \(removedCount) stale states")
        }
    }
    
    /// Clear all states
    func clearAllStates() {
        videoStates.removeAll()
        print("🗑️ [VIDEO STATE] Cleared all states")
    }
    
    /// Check if we should restore playback for a video
    func shouldRestorePlayback(videoMid: String, context: VideoPlaybackState.VideoContext) -> Bool {
        guard let state = getState(videoMid: videoMid, context: context) else {
            return false
        }
        
        // Context is isolated by dictionary key; this is a safety check.
        guard state.context == context else { return false }
        
        // Only restore if saved within last 5 minutes
        let fiveMinutesAgo = Date().addingTimeInterval(-300)
        guard state.timestamp > fiveMinutesAgo else {
            print("⚠️ [VIDEO STATE] State too old for \(videoMid): \(Date().timeIntervalSince(state.timestamp))s ago")
            return false
        }
        
        return true
    }
}
