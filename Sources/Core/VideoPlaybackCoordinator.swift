//
//  VideoPlaybackCoordinator.swift
//  Tweet
//
//  Coordinates video playback across the app
//  New behavior: 2s autoplay survey -> primary video selection -> sequential playback
//
import Foundation
import SwiftUI
import UIKit

/// Notification names for video playback coordination
extension Notification.Name {
    static let shouldPlayVideo = Notification.Name("shouldPlayVideo")
    static let shouldStopVideo = Notification.Name("shouldStopVideo")
    static let shouldStopAllVideos = Notification.Name("shouldStopAllVideos")
    static let videoDidFinishPlaying = Notification.Name("videoDidFinishPlaying")
    static let shouldPauseVideo = Notification.Name("shouldPauseVideo")
    static let videoTimerUpdate = Notification.Name("videoTimerUpdate")
    static let requestVideoTimerUpdate = Notification.Name("requestVideoTimerUpdate")
}

/// Video state during orchestration
private enum VideoPlaybackPhase {
    case idle                    // No playback
    case surveying               // Playing all visible videos for 2s each
    case primaryPlaying          // Primary video is playing to completion
}

/// Individual video tracking info for orchestration
/// Shared structure for video metadata (used by VideoPlaybackCoordinator and FullScreenVideoManager)
struct VideoPlaybackInfo: Equatable {
    let tweetId: String
    let videoMid: String
    let index: Int
    
    var identifier: String {
        "\(tweetId)_\(videoMid)"
    }
    
    static func == (lhs: VideoPlaybackInfo, rhs: VideoPlaybackInfo) -> Bool {
        lhs.identifier == rhs.identifier
    }
}

/// Coordinates video playback with intelligent primary video selection
/// New behavior:
/// 1. Load and autoplay all visible videos for 2s (survey phase)
/// 2. Identify primary video (most visible/centered)
/// 3. Keep primary video playing to completion
/// 4. When primary finishes, move to next visible video
/// 5. Keep videos playing during scroll
/// 6. After scroll stops (2s delay), re-identify primary video
@MainActor
class VideoPlaybackCoordinator: ObservableObject {
    static let shared = VideoPlaybackCoordinator()
    
    // MARK: - Published State
    
    /// Currently playing videos (can be multiple during survey phase)
    @Published private(set) var currentlyPlayingVideoIds: Set<String> = []
    
    /// Primary video that's playing to completion
    @Published private(set) var primaryVideoId: String?
    
    // MARK: - Private State
    
    /// Current playback phase
    private var phase: VideoPlaybackPhase = .idle
    
    /// Timer for survey phase (2s per video)
    private var surveyTimer: Timer?
    
    /// Timer for detecting scroll stop (2s delay)
    private var scrollStopTimer: Timer?
    
    /// Timer for debouncing video playback (0.1s delay)
    private var playbackDebounceTimer: Timer?
    
    /// Timer for each video's 2s autoplay during survey
    private var videoTimers: [String: Timer] = [:]
    
    /// Visible tweet IDs (updated by scroll tracking)
    private var visibleTweetIds: Set<String> = []
    
    /// All videos in the feed (ordered)
    private var allVideos: [VideoPlaybackInfo] = []
    
    /// Currently visible videos (computed from visibleTweetIds + allVideos)
    private var visibleVideos: [VideoPlaybackInfo] {
        allVideos.filter { visibleTweetIds.contains($0.tweetId) }
    }
    
    /// Is currently scrolling
    private var isScrolling: Bool = false
    
    /// Table view reference for viewport calculations
    private weak var tableView: UITableView?
    
    // MARK: - Initialization
    
    private init() {
        // Listen for video finished notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVideoFinished),
            name: .videoDidFinishPlaying,
            object: nil
        )
    }
    
    // MARK: - Public API
    
    /// Set table view reference for viewport calculations
    func setTableView(_ tableView: UITableView) {
        self.tableView = tableView
    }
    
    /// Build video list from tweets
    func buildVideoList(from tweets: [Tweet]) {
        var videos: [VideoPlaybackInfo] = []
        
        for tweet in tweets {
            guard let attachments = tweet.attachments else { continue }
            
            for (index, attachment) in attachments.enumerated() {
                if attachment.type == .video || attachment.type == .hls_video {
                    videos.append(VideoPlaybackInfo(
                        tweetId: tweet.mid,
                        videoMid: attachment.mid,
                        index: index
                    ))
                }
            }
        }
        
        self.allVideos = videos
        
        // Share the video list with FullScreenVideoManager to avoid duplicate tracking
        // This consolidates video tracking in one place
        FullScreenVideoManager.shared.updateVideoList(videos: videos, tweets: tweets)
    }
    
    /// Previously visible video IDs (to detect actual video changes, not just tweet changes)
    private var previousVisibleVideoIds: Set<String> = []
    
    /// Update visible tweets (called during scrolling)
    func updateVisibleTweets(_ tweetIds: Set<String>) {
        self.visibleTweetIds = tweetIds
        self.isScrolling = true
        
        // Get current visible video IDs
        let currentVisibleVideoIds = Set(visibleVideos.map { $0.videoMid })
        let videoVisibilityChanged = previousVisibleVideoIds != currentVisibleVideoIds
        
        // Stop all videos if none are visible
        if currentVisibleVideoIds.isEmpty {
            previousVisibleVideoIds.removeAll()
            stopAllVideos()
            return
        }
        
        // Stop videos that are no longer visible
        if videoVisibilityChanged {
            let videosToStop = previousVisibleVideoIds.subtracting(currentVisibleVideoIds)
            for videoMid in videosToStop {
                NotificationCenter.default.post(
                    name: .shouldStopVideo,
                    object: nil,
                    userInfo: ["videoMid": videoMid]
                )
            }
        }
        
        // Start playback when videos become visible OR when in idle phase with videos
        // This handles both "new videos" and "coming back to idle with videos present"
        if videoVisibilityChanged && !currentVisibleVideoIds.isEmpty {
            // CRITICAL FIX: Don't reset if we're in primaryPlaying phase and the primary video is still visible
            // This prevents restarting the video during small scrolls
            if phase == .primaryPlaying,
               let primaryId = primaryVideoId,
               currentVisibleVideoIds.contains(where: { primaryId.contains($0) }) {
                previousVisibleVideoIds = currentVisibleVideoIds
                return
            }
            
            // Reset to idle phase
            phase = .idle
            currentlyPlayingVideoIds.removeAll()
            primaryVideoId = nil
            
            // Cancel existing timers
            surveyTimer?.invalidate()
            surveyTimer = nil
            playbackDebounceTimer?.invalidate()
            playbackDebounceTimer = nil
            
            // Start debounce timer for new visible videos
            // Use .common mode so timer fires even during active scrolling
            let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
                // Use DispatchQueue to ensure MainActor isolation
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if self.phase == .idle && !self.visibleVideos.isEmpty {
                        self.startSurveyPhase()
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            playbackDebounceTimer = timer
        } else if !videoVisibilityChanged && phase == .idle && !currentVisibleVideoIds.isEmpty && playbackDebounceTimer == nil {
            // Handle case where videos are already visible but we're in idle (e.g., initial load)
            let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if self.phase == .idle && !self.visibleVideos.isEmpty {
                        self.startSurveyPhase()
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            playbackDebounceTimer = timer
        }
        
        // Update previous state
        previousVisibleVideoIds = currentVisibleVideoIds
        
        // Cancel scroll stop timer - we don't need re-evaluation anymore
        // Videos start via debounce during scroll, no need for post-scroll restart
        scrollStopTimer?.invalidate()
        scrollStopTimer = nil
    }
    
    /// Stop all videos and reset state
    func stopAllVideos() {
        // Cancel all timers
        surveyTimer?.invalidate()
        surveyTimer = nil
        
        playbackDebounceTimer?.invalidate()
        playbackDebounceTimer = nil
        
        for timer in videoTimers.values {
            timer.invalidate()
        }
        videoTimers.removeAll()
        
        scrollStopTimer?.invalidate()
        scrollStopTimer = nil
        
        // Clear state
        currentlyPlayingVideoIds.removeAll()
        primaryVideoId = nil
        phase = .idle
        
        // Notify all videos to stop
        NotificationCenter.default.post(name: .shouldStopAllVideos, object: nil)
    }
    
    // MARK: - Private Methods
    
    /// Called when scrolling stops (after 2s delay)
    private func onScrollStopped() {
        isScrolling = false
        // Scroll stop handler is now a no-op since we handle everything via debounce during scroll
        // Videos continue playing through scroll and beyond
        print("🎬 [VideoOrchestrator] Scroll stopped (no action needed - videos already playing)")
    }
    
    /// Start survey phase - play all visible videos for 2s each
    private func startSurveyPhase() {
        phase = .surveying
        currentlyPlayingVideoIds.removeAll()
        
        // Start playing all visible videos
        for video in visibleVideos {
            playVideoForSurvey(video)
        }
        
        // After 2s, identify primary video and transition
        surveyTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.endSurveyPhase()
            }
        }
    }
    
    /// Play a video during survey phase (2s duration)
    private func playVideoForSurvey(_ video: VideoPlaybackInfo) {
        let videoId = video.identifier
        currentlyPlayingVideoIds.insert(videoId)
        
        // Notify video to start playing
        NotificationCenter.default.post(
            name: .shouldPlayVideo,
            object: nil,
            userInfo: [
                "tweetId": video.tweetId,
                "videoMid": video.videoMid,
                "videoIndex": video.index,
                "isSurvey": true
            ]
        )
    }
    
    /// End survey phase and identify primary video
    private func endSurveyPhase() {
        print("🎬 [VideoOrchestrator] Ending survey phase, identifying primary video")
        
        // Identify primary video (most visible/centered)
        guard let primary = identifyPrimaryVideo() else {
            print("🎬 [VideoOrchestrator] No primary video found, stopping all")
            stopAllVideos()
            return
        }
        
        print("🎬 [VideoOrchestrator] Primary video identified: \(primary.videoMid)")
        
        // Pause all non-primary videos
        for video in visibleVideos where video != primary {
            pauseVideo(video)
        }
        
        // Ensure primary video is playing (restart if finished)
        primaryVideoId = primary.identifier
        currentlyPlayingVideoIds = [primary.identifier]
        phase = .primaryPlaying
        
        // Send primary play command to ensure video plays (especially if it finished during survey)
        NotificationCenter.default.post(
            name: .shouldPlayVideo,
            object: nil,
            userInfo: [
                "tweetId": primary.tweetId,
                "videoMid": primary.videoMid,
                "videoIndex": primary.index,
                "isPrimary": true
            ]
        )
        
        print("🎬 [VideoOrchestrator] Transitioned to primary playback phase")
    }
    
    /// Identify the primary video (most visible/centered in viewport)
    private func identifyPrimaryVideo() -> VideoPlaybackInfo? {
        guard let tableView = tableView else {
            // Fallback: return first visible video
            return visibleVideos.first
        }
        
        let visibleRect = CGRect(
            x: 0,
            y: tableView.contentOffset.y,
            width: tableView.bounds.width,
            height: tableView.bounds.height
        )
        
        let centerY = visibleRect.midY
        
        // Find video closest to center of viewport
        var bestVideo: VideoPlaybackInfo?
        var bestDistance: CGFloat = .infinity
        
        for video in visibleVideos {
            // Find the cell containing this video
            guard let cell = findCell(for: video.tweetId, in: tableView) else { continue }
            
            let cellFrame = tableView.convert(cell.frame, to: tableView)
            let cellCenterY = cellFrame.midY
            let distance = abs(cellCenterY - centerY)
            
            // Also consider what percentage of the cell is visible
            let intersection = cellFrame.intersection(visibleRect)
            let visibilityRatio = intersection.height / cellFrame.height
            
            // Prefer videos that are more centered and more visible
            let score = distance / max(visibilityRatio, 0.1) // Lower is better
            
            if score < bestDistance {
                bestDistance = score
                bestVideo = video
            }
        }
        
        return bestVideo ?? visibleVideos.first
    }
    
    /// Find table view cell for a given tweet ID
    private func findCell(for tweetId: String, in tableView: UITableView) -> UITableViewCell? {
        for cell in tableView.visibleCells {
            // This assumes TweetTableViewCell has a way to identify its tweet
            // We'll need to add this functionality
            if let tweetCell = cell as? TweetTableViewCell,
               tweetCell.tweetId == tweetId {
                return cell
            }
        }
        return nil
    }
    
    /// Pause a specific video
    private func pauseVideo(_ video: VideoPlaybackInfo) {
        let videoId = video.identifier
        currentlyPlayingVideoIds.remove(videoId)
        
        print("🎬 [VideoOrchestrator] Pausing video \(video.videoMid)")
        
        NotificationCenter.default.post(
            name: .shouldPauseVideo,
            object: nil,
            userInfo: [
                "videoMid": video.videoMid
            ]
        )
    }
    
    /// Play next visible video after primary finishes
    private func playNextVisibleVideo() {
        guard let currentPrimary = primaryVideoId else { return }
        
        // Find current primary in visible videos list
        guard let currentIndex = visibleVideos.firstIndex(where: { $0.identifier == currentPrimary }) else {
            print("🎬 [VideoOrchestrator] Primary video no longer visible")
            stopAllVideos()
            return
        }
        
        // Find next video
        let nextIndex = currentIndex + 1
        guard nextIndex < visibleVideos.count else {
            print("🎬 [VideoOrchestrator] No more visible videos, stopping")
            stopAllVideos()
            return
        }
        
        let nextVideo = visibleVideos[nextIndex]
        print("🎬 [VideoOrchestrator] Playing next video: \(nextVideo.videoMid)")
        
        // Set new primary and start playing
        primaryVideoId = nextVideo.identifier
        currentlyPlayingVideoIds = [nextVideo.identifier]
        
        NotificationCenter.default.post(
            name: .shouldPlayVideo,
            object: nil,
            userInfo: [
                "tweetId": nextVideo.tweetId,
                "videoMid": nextVideo.videoMid,
                "videoIndex": nextVideo.index,
                "isPrimary": true
            ]
        )
    }
    
    /// Handle video finished notification
    @objc private func handleVideoFinished(_ notification: Notification) {
        guard let videoMid = notification.userInfo?["videoMid"] as? String else {
            print("⚠️ [VideoOrchestrator] Video finished notification received but no videoMid in userInfo")
            return
        }
        
        print("🎬 [VideoOrchestrator] Video finished: \(videoMid)")
        print("🎬 [VideoOrchestrator]   Current phase: \(phase)")
        print("🎬 [VideoOrchestrator]   Primary video: \(primaryVideoId ?? "nil")")
        print("🎬 [VideoOrchestrator]   Currently playing: \(currentlyPlayingVideoIds)")
        
        // Only handle if this is the primary video
        if phase == .primaryPlaying,
           let primaryId = primaryVideoId,
           primaryId.contains(videoMid) {
            print("🎬 [VideoOrchestrator] ✅ Primary video finished, playing next")
            playNextVisibleVideo()
        } else {
            if phase != .primaryPlaying {
                print("🎬 [VideoOrchestrator] ⏭️ Not in primaryPlaying phase - ignoring finish event")
            } else if primaryVideoId == nil {
                print("🎬 [VideoOrchestrator] ⏭️ No primary video set - ignoring finish event")
            } else if let primaryId = primaryVideoId, !primaryId.contains(videoMid) {
                print("🎬 [VideoOrchestrator] ⏭️ Finished video \(videoMid) is not the primary video - ignoring")
            }
        }
    }
}

