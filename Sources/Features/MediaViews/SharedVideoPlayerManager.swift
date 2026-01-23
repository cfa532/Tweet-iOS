//
//  SharedVideoPlayerManager.swift
//  Tweet
//
//  Shared video player coordinator for Twitter-style video playback
//  Ensures only one video plays at a time across the entire app
//

import Foundation
import SwiftUI
import Combine
import CoreMedia
import QuartzCore

/// Delegate protocol for video player lifecycle events
@MainActor
protocol SharedVideoPlayerDelegate: AnyObject {
    func videoPlayerDidStartPlaying(videoId: String)
    func videoPlayerDidPause(videoId: String)
    func videoPlayerDidFinish(videoId: String)
    func videoPlayerDidUpdateTime(videoId: String, currentTime: CMTime, duration: CMTime)
    func videoPlayerDidFail(videoId: String, error: Error)

    /// The video ID this delegate is interested in
    var interestedVideoId: String { get }
}

// MARK: - Shared Display Link Manager

/// Twitter-style shared display link for video timer updates
/// ONE display link for entire app, eliminating timer accumulation
@MainActor
class SharedDisplayLinkManager {
    static let shared = SharedDisplayLinkManager()

    // MARK: - Properties

    /// The single shared display link
    private var displayLink: CADisplayLink?

    /// Registered observers for display link updates
    private var observers: NSHashTable<AnyObject> = NSHashTable.weakObjects()

    /// Is the display link currently running
    private(set) var isRunning = false

    /// Update interval (default: 30fps, can throttle to 15fps or 10fps)
    var preferredFramesPerSecond: Int = 30 {
        didSet {
            if isRunning {
                stop()
                start()
            }
        }
    }

    private init() {
        setupDisplayLink()
    }

    // MARK: - Public API

    /// Start the display link
    func start() {
        guard !isRunning, let displayLink = displayLink else { return }

        displayLink.preferredFramesPerSecond = preferredFramesPerSecond
        displayLink.add(to: .main, forMode: .common)
        isRunning = true
        print("⏱️ [DISPLAY LINK] Started (targeting \(preferredFramesPerSecond)fps)")
    }

    /// Stop the display link
    func stop() {
        guard isRunning, let displayLink = displayLink else { return }

        displayLink.remove(from: .main, forMode: .common)
        isRunning = false
        print("⏱️ [DISPLAY LINK] Stopped")
    }

    /// Add an observer to receive display link updates
    func addObserver(_ observer: SharedDisplayLinkObserver) {
        observers.add(observer)
        print("⏱️ [DISPLAY LINK] Added observer, total: \(observers.count)")

        // Start display link if this is the first observer
        if observers.count == 1 {
            start()
        }
    }

    /// Remove an observer
    func removeObserver(_ observer: SharedDisplayLinkObserver) {
        observers.remove(observer)
        print("⏱️ [DISPLAY LINK] Removed observer, total: \(observers.count)")

        // Stop display link if no observers remain
        if observers.count == 0 {
            stop()
        }
    }

    // MARK: - Private Methods

    private func setupDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        displayLink?.preferredFramesPerSecond = preferredFramesPerSecond
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        // Notify all observers
        let allObservers = observers.allObjects
        for case let observer as SharedDisplayLinkObserver in allObservers {
            observer.displayLinkDidFire(link)
        }
    }
}

/// Protocol for objects that want to observe display link updates
@MainActor
protocol SharedDisplayLinkObserver: AnyObject {
    func displayLinkDidFire(_ link: CADisplayLink)
}

// MARK: - Shared Video Player Manager

/// Shared video player coordinator for Twitter-style video playback
/// Ensures only one video plays at a time while leveraging SimpleVideoPlayer instances
/// 
/// Video Identification:
/// Videos are identified by a composite key: `cellTweetId + videoMid + attachmentIndex`
/// - cellTweetId: The ID of the visible cell (retweet ID for retweets, quoting tweet ID for quoted tweets)
/// - videoMid: The attachment's mid (unique file identifier)
/// - attachmentIndex: Index in the attachments array
///
/// This allows the same video file to appear in multiple tweets (retweets, quotes) and be treated as separate instances.
@MainActor
class SharedVideoPlayerManager: ObservableObject {
    static let shared = SharedVideoPlayerManager()

    // MARK: - Properties

    /// Currently playing video identifier (sourceTweetId_videoMid_attachmentIndex)
    @Published private(set) var currentlyPlayingVideoId: String?

    /// Current video mid (for backward compatibility checks)
    @Published private(set) var currentVideoMid: String?

    /// Current video URL (for debugging)
    private var currentVideoURL: URL?

    /// Delegates registered for video events
    private var delegates: NSHashTable<AnyObject> = NSHashTable.weakObjects()

    /// Playback state cache (for resuming playback)
    private var videoStates: [String: VideoState] = [:]

    /// Debug: Track playback history
    private var playbackHistory: [String] = []

    private init() {
        print("🎬 [SHARED PLAYER] Initialized - Coordinating single video playback")
    }

    // MARK: - Public API

    /// Request to play a specific video instance (coordinates to ensure only one plays)
    /// - Parameters:
    ///   - videoId: Full identifier (cellTweetId_videoMid_attachmentIndex)
    ///   - videoMid: The attachment's mid (for notification routing)
    ///   - cellTweetId: The visible cell's tweet ID (retweet ID for retweets, quoting tweet ID for quotes)
    func playVideo(videoId: String, videoMid: String, cellTweetId: String) {
        // If already playing this video instance, no action needed (prevent duplicate notifications)
        if currentlyPlayingVideoId == videoId {
            print("🎬 [SHARED PLAYER] Already coordinating playback for \(videoId) - ignoring duplicate request")
            return
        }

        print("🎬 [SHARED PLAYER] Coordinating playback for video: \(videoId) (mid: \(videoMid), cell: \(cellTweetId))")

        // Stop current video if different
        if let currentId = currentlyPlayingVideoId, currentId != videoId {
            pauseCurrentVideo()
        }

        // Update state BEFORE posting notification to prevent race conditions
        currentlyPlayingVideoId = videoId
        currentVideoMid = videoMid

        // Track playback
        playbackHistory.append(videoId)
        if playbackHistory.count > 100 {
            playbackHistory.removeFirst(playbackHistory.count - 100)
        }

        // Notify MediaCell to start playback for this video instance
        NotificationCenter.default.post(
            name: .shouldPlayVideo,
            object: nil,
            userInfo: [
                "videoId": videoId,           // Full identifier
                "videoMid": videoMid,         // Attachment mid (for routing)
                "cellTweetId": cellTweetId    // Cell tweet ID
            ]
        )

        print("🎬 [SHARED PLAYER] Started coordinated playback for: \(videoId)")
    }

    /// Pause the currently playing video
    func pauseCurrentVideo() {
        guard let videoId = currentlyPlayingVideoId,
              let videoMid = currentVideoMid else { return }

        print("⏸️ [SHARED PLAYER] Pausing video: \(videoId)")

        // Notify MediaCell to pause this video
        NotificationCenter.default.post(
            name: .shouldPauseVideo,
            object: nil,
            userInfo: [
                "videoId": videoId,
                "videoMid": videoMid
            ]
        )

        // Update state
        saveCurrentVideoState()

        // Notify delegates
        notifyDelegates(for: videoMid) { delegate in
            delegate.videoPlayerDidPause(videoId: videoMid)
        }
    }

    /// Stop the currently playing video
    func stopCurrentVideo() {
        guard let videoId = currentlyPlayingVideoId,
              let videoMid = currentVideoMid else { return }

        print("⏹️ [SHARED PLAYER] Stopping video: \(videoId)")

        // Notify MediaCell to stop this video
        NotificationCenter.default.post(
            name: .shouldStopVideo,
            object: nil,
            userInfo: [
                "videoId": videoId,
                "videoMid": videoMid
            ]
        )

        // Clean up state
        saveCurrentVideoState()
        currentlyPlayingVideoId = nil
        currentVideoMid = nil
        currentVideoURL = nil
    }

    /// Seek to specific time in current video
    func seekToTime(_ time: CMTime, completion: ((Bool) -> Void)? = nil) {
        guard let videoId = currentlyPlayingVideoId else {
            completion?(false)
            return
        }

        print("⏩ [SHARED PLAYER] Seeking to \(time.seconds)s in video: \(videoId)")

        // Notify MediaCell to seek this video
        NotificationCenter.default.post(
            name: .shouldSeekVideo,
            object: nil,
            userInfo: [
                "videoMid": videoId,
                "seekTime": time
            ]
        )

        completion?(true)
    }

    /// Get current playback time
    func getCurrentTime() -> CMTime {
        // This would need to be implemented by querying the SimpleVideoPlayer
        // For now, return saved time from state
        guard let videoId = currentlyPlayingVideoId,
              let state = videoStates[videoId] else {
            return .zero
        }
        return state.lastPlaybackTime
    }

    /// Get current video duration
    func getDuration() -> CMTime {
        guard let videoId = currentlyPlayingVideoId,
              let state = videoStates[videoId] else {
            return .zero
        }
        return state.duration
    }

    /// Check if video is currently playing
    func isPlaying() -> Bool {
        return currentlyPlayingVideoId != nil
    }

    /// Get saved state for a video
    func getVideoState(for videoId: String) -> VideoState? {
        return videoStates[videoId]
    }

    // MARK: - Delegate Management

    func addDelegate(_ delegate: SharedVideoPlayerDelegate) {
        delegates.add(delegate as AnyObject)
    }

    func removeDelegate(_ delegate: SharedVideoPlayerDelegate) {
        delegates.remove(delegate as AnyObject)
    }

    private func notifyDelegates(for videoId: String, action: (SharedVideoPlayerDelegate) -> Void) {
        let allDelegates = delegates.allObjects
        let interestedDelegates = allDelegates.filter { ($0 as? SharedVideoPlayerDelegate)?.interestedVideoId == videoId }
        for case let delegate as SharedVideoPlayerDelegate in interestedDelegates {
            action(delegate)
        }
    }

    // MARK: - State Management

    private func saveCurrentVideoState() {
        guard let videoId = currentlyPlayingVideoId else { return }

        // For now, we don't have direct access to playback time from SimpleVideoPlayer
        // This would need to be implemented by having SimpleVideoPlayer report time updates
        // For the Phase 1 implementation, we'll rely on the existing VideoStateCache
        print("💾 [SHARED PLAYER] State saving requested for \(videoId) (implementation needed)")
    }

    // MARK: - Debug

    func debugInfo() -> String {
        return """
        🎬 Shared Video Player Coordinator Debug Info:
        - Currently playing: \(currentlyPlayingVideoId ?? "none")
        - Tracked states: \(videoStates.count)
        - Recent playbacks: \(playbackHistory.suffix(5).joined(separator: ", "))
        - Delegates: \(delegates.count)
        """
    }
}

// MARK: - Supporting Types

/// Video playback state
struct VideoState {
    let url: URL
    var lastPlaybackTime: CMTime = .zero
    var duration: CMTime = .zero
    var wasPlaying: Bool = false
}

// MARK: - Notification Extensions

extension Notification.Name {
    static let shouldSeekVideo = Notification.Name("shouldSeekVideo")
    // Note: requestVideoSeek removed - SimpleVideoPlayer doesn't support external seek commands
}
