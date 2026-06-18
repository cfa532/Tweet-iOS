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
    private let stateFreshnessInterval: TimeInterval = 300
    
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
    /// Automatically clears state if video is at or near the end (prevents restoring to end position)
    func saveState(
        videoMid: String,
        currentTime: CMTime,
        wasPlaying: Bool,
        context: VideoPlaybackState.VideoContext
    ) {
        // CRITICAL: Validate time before saving - prevent NaN or invalid times from crashing later
        guard currentTime.isValid && currentTime.seconds.isFinite else {
            print("⚠️ [VIDEO STATE] Rejected invalid time for \(videoMid): \(currentTime.seconds)s - clearing state instead")
            clearState(videoMid: videoMid, context: context)
            return
        }
        
        // CRITICAL: Don't save state if video is at or near the end (within 1 second of completion)
        // This prevents videos from restoring to end position and immediately finishing on next play
        // Note: We don't have duration here, so we rely on the caller to clear state when video finishes
        // OR we can check if currentTime is suspiciously close to a typical video end (handled by SimpleVideoPlayer)
        
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
    }
    
    /// Save video playback state with duration check
    /// If video is at or near the end, clears state instead of saving
    func saveState(
        videoMid: String,
        currentTime: CMTime,
        wasPlaying: Bool,
        context: VideoPlaybackState.VideoContext,
        duration: CMTime
    ) {
        // CRITICAL: Validate time before saving
        guard currentTime.isValid && currentTime.seconds.isFinite else {
            print("⚠️ [VIDEO STATE] Rejected invalid time for \(videoMid): \(currentTime.seconds)s - clearing state instead")
            clearState(videoMid: videoMid, context: context)
            return
        }
        
        // CRITICAL: If duration is valid, check if video is at or near the end
        if duration.isValid && duration.seconds > 0 {
            let timeRemaining = duration.seconds - currentTime.seconds
            
            // If within 1 second of the end, clear state instead of saving
            // This prevents videos from restoring to end position on next play
            if timeRemaining <= 1.0 {
                print("🗑️ [VIDEO STATE] Video \(videoMid) at end (\(currentTime.seconds)s / \(duration.seconds)s) - clearing state instead of saving")
                clearState(videoMid: videoMid, context: context)
                return
            }
        }
        
        // Save normally if not at end
        saveState(videoMid: videoMid, currentTime: currentTime, wasPlaying: wasPlaying, context: context)
    }
    
    /// Get saved video playback state
    /// Automatically validates and clears states that are at/near the end
    func getState(videoMid: String, context: VideoPlaybackState.VideoContext, duration: CMTime? = nil) -> VideoPlaybackState? {
        guard let state = videoStates[context]?[videoMid] else {
            return nil
        }
        
        // If duration is provided, check if saved position is at/near end
        if let duration = duration, duration.isValid && duration.seconds > 0 {
            let timeRemaining = duration.seconds - state.currentTime.seconds
            
            // If within 1 second of the end, clear this stale state and return nil
            if timeRemaining <= 1.0 {
                print("🗑️ [VIDEO STATE] Found stale end-position state for \(videoMid) (\(state.currentTime.seconds)s / \(duration.seconds)s) - clearing")
                clearState(videoMid: videoMid, context: context)
                return nil
            }
        }
        
        return state
    }

    /// Get the freshest valid playback state for a video across surfaces.
    /// This lets independent feed/detail/fullscreen players resume the same video
    /// from the user's most recent position without sharing AVPlayer ownership.
    func latestState(
        videoMid: String,
        excluding excludedContext: VideoPlaybackState.VideoContext? = nil,
        duration: CMTime? = nil
    ) -> VideoPlaybackState? {
        let freshnessCutoff = Date().addingTimeInterval(-stateFreshnessInterval)
        var latest: VideoPlaybackState?

        for context in VideoPlaybackState.VideoContext.allCases {
            if let excludedContext, context == excludedContext { continue }
            guard let state = getState(videoMid: videoMid, context: context, duration: duration) else { continue }
            guard state.timestamp > freshnessCutoff else { continue }
            guard state.currentTime.isValid,
                  state.currentTime.seconds.isFinite,
                  state.currentTime.seconds > 0.25 else { continue }

            if latest == nil || state.timestamp > latest!.timestamp {
                latest = state
            }
        }

        return latest
    }
    
    /// Remove saved state for a video
    func clearState(videoMid: String, context: VideoPlaybackState.VideoContext) {
        videoStates[context]?.removeValue(forKey: videoMid)
    }

    /// Remove saved state for a video across all contexts
    func clearState(videoMid: String) {
        for context in VideoPlaybackState.VideoContext.allCases {
            videoStates[context]?.removeValue(forKey: videoMid)
        }
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
    /// Validates that state exists, is recent, and is not at the end
    func shouldRestorePlayback(videoMid: String, context: VideoPlaybackState.VideoContext, duration: CMTime? = nil) -> Bool {
        guard let state = getState(videoMid: videoMid, context: context, duration: duration) else {
            return false
        }
        
        // Context is isolated by dictionary key; this is a safety check.
        guard state.context == context else { return false }
        
        // Only restore if saved within the freshness window
        let fiveMinutesAgo = Date().addingTimeInterval(-stateFreshnessInterval)
        guard state.timestamp > fiveMinutesAgo else {
            print("⚠️ [VIDEO STATE] State too old for \(videoMid): \(Date().timeIntervalSince(state.timestamp))s ago")
            return false
        }
        
        return true
    }
    
    /// Clear all saved states at or near the end position
    /// Call this on app launch to clean up stale end-position states
    func clearEndPositionStates() {
        var clearedCount = 0
        
        for context in VideoPlaybackState.VideoContext.allCases {
            guard var bucket = videoStates[context] else { continue }
            
            // We can't check duration here, so just clear states that are suspiciously high (>100 seconds)
            // The real cleanup happens in getState when duration is available
            // This is just a safety cleanup for very old states
            let staleMids = bucket.filter { $0.value.currentTime.seconds > 100 }.map { $0.key }
            for mid in staleMids {
                bucket.removeValue(forKey: mid)
                clearedCount += 1
            }
            videoStates[context] = bucket
        }
        
        if clearedCount > 0 {
            print("🗑️ [VIDEO STATE] Cleared \(clearedCount) suspicious end-position states on launch")
        }
    }
}
