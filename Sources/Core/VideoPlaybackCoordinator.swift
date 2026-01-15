//
//  VideoPlaybackCoordinator.swift
//  Tweet
//
//  Coordinates video playback across the app
//  Behavior: Play topmost video on screen, switch to next when current video is 30% out of view
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

/// Coordinates video playback with topmost video selection
/// Behavior:
/// 1. Play topmost video on screen immediately (no survey phase)
/// 2. Monitor scroll position during playback
/// 3. When current video is 30% out of view, switch to next video
/// 4. When video finishes, move to next visible video
/// 5. Debounce timer: 0.2s
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
    
    /// Flag to preserve state on foreground (cleared on explicit scroll)
    private var shouldPreserveStateOnForeground = false
    
    /// Timer for survey phase (2s per video)
    private var surveyTimer: Timer?
    
    /// Timer for detecting scroll stop (2s delay)
    private var scrollStopTimer: Timer?
    
    /// Timer for debouncing video playback (0.2s delay)
    private var playbackDebounceTimer: Timer?
    
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

        // Listen for foreground recovery and intelligently decide whether to preserve state
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleForegroundRecovery),
            name: .reloadVisibleVideosOnly,
            object: nil
        )
        
        // Listen for app background to set preservation flag
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }
    
    /// Handle app entering background - set flag to preserve state on foreground
    @objc private func handleAppDidEnterBackground() {
        // If we have active playback state, preserve it on foreground
        // This flag will be cleared if user explicitly scrolls
        if phase != .idle {
            shouldPreserveStateOnForeground = true
        }
    }
    
    // MARK: - Public API
    
    /// Set table view reference for viewport calculations
    func setTableView(_ tableView: UITableView) {
        self.tableView = tableView
    }
    
    /// Build video list from tweets (including pinned tweets)
    func buildVideoList(from tweets: [Tweet], pinnedTweets: [Tweet] = []) {
        var videos: [VideoPlaybackInfo] = []
        var seenVideoIdentifiers = Set<String>() // Track seen video identifiers (tweetId_videoMid) to prevent duplicates
        
        // Process pinned tweets first (they appear at the top)
        for (_, tweet) in pinnedTweets.enumerated() {
            guard let attachments = tweet.attachments else { continue }
            
            for (index, attachment) in attachments.enumerated() {
                if attachment.type == .video || attachment.type == .hls_video {
                    let videoInfo = VideoPlaybackInfo(
                        tweetId: tweet.mid,
                        videoMid: attachment.mid,
                        index: index
                    )
                    
                    // Skip if we've already added this exact video (same tweet + same video)
                    if seenVideoIdentifiers.contains(videoInfo.identifier) {
                        continue
                    }
                    
                    videos.append(videoInfo)
                    seenVideoIdentifiers.insert(videoInfo.identifier)
                }
            }
        }
        
        // Then process regular tweets
        for (_, tweet) in tweets.enumerated() {
            // Determine if this is a pure retweet (no own content, just forwarding)
            let hasTweetContent = tweet.attachments != nil && !(tweet.attachments?.isEmpty ?? true)
            let hasOriginalTweet = tweet.originalTweetId != nil
            let isPureRetweet = hasOriginalTweet && !hasTweetContent // Has original but no own content
            
            if isPureRetweet {
                // PURE RETWEET: Get attachments from original tweet, use retweet's ID for positioning
                // Use fetchTweetSync to check both singleton cache AND Core Data cache
                if let originalTweetId = tweet.originalTweetId {
                    // Try singleton first (fast), then Core Data (still synchronous)
                    let originalTweet = Tweet.getInstance(for: originalTweetId) 
                        ?? TweetCacheManager.shared.fetchTweetSync(mid: originalTweetId)
                    
                    if let originalTweet = originalTweet,
                       let originalAttachments = originalTweet.attachments {
                        
                        for (index, attachment) in originalAttachments.enumerated() {
                            if attachment.type == .video || attachment.type == .hls_video {
                                let videoInfo = VideoPlaybackInfo(
                                    tweetId: tweet.mid,  // Use retweet's ID for positioning
                                    videoMid: attachment.mid,
                                    index: index
                                )
                                
                                if seenVideoIdentifiers.contains(videoInfo.identifier) {
                                    continue
                                }
                                
                                videos.append(videoInfo)
                                seenVideoIdentifiers.insert(videoInfo.identifier)
                            }
                        }
                    } else {
                        print("  ⚠️ Original tweet not found for retweet: \(tweet.mid)")
                    }
                }
            } else {
                // REGULAR TWEET or QUOTED TWEET: Process the tweet's own attachments
                // NOTE: For quoted tweets, we DON'T process the embedded tweet's videos
                // because they use independent autoplay logic (not coordinated)
                if let attachments = tweet.attachments {
                    for (index, attachment) in attachments.enumerated() {
                        if attachment.type == .video || attachment.type == .hls_video {
                            let videoInfo = VideoPlaybackInfo(
                                tweetId: tweet.mid,
                                videoMid: attachment.mid,
                                index: index
                            )
                            
                            if seenVideoIdentifiers.contains(videoInfo.identifier) {
                                continue
                            }
                            
                            videos.append(videoInfo)
                            seenVideoIdentifiers.insert(videoInfo.identifier)
                        }
                    }
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
            // This prevents restarting the video during small scrolls, but we still check for 30% threshold
            if phase == .primaryPlaying,
               let primaryId = primaryVideoId,
               currentVisibleVideoIds.contains(where: { primaryId.contains($0) }) {
                // Primary video still visible - just update tracking and check 30% threshold
                previousVisibleVideoIds = currentVisibleVideoIds
                // Continue to checkAndSwitchVideoIfNeeded() below
            } else {
                // Primary video no longer visible or not in primaryPlaying phase - reset
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
                let timer = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in
                    // Use DispatchQueue to ensure MainActor isolation
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if self.phase == .idle && !self.visibleVideos.isEmpty {
                            self.startPrimaryVideoPlayback()
                        } else {
                            print("⚠️ [VideoPlaybackCoordinator] Skipping playback - phase: \(self.phase), videos: \(self.visibleVideos.count)")
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                playbackDebounceTimer = timer
                
                // Update previous state
                previousVisibleVideoIds = currentVisibleVideoIds
            }
        } else if !videoVisibilityChanged && phase == .idle && !currentVisibleVideoIds.isEmpty && playbackDebounceTimer == nil {
            // Handle case where videos are already visible but we're in idle (e.g., initial load)
            let timer = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if self.phase == .idle && !self.visibleVideos.isEmpty {
                        self.startPrimaryVideoPlayback()
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            playbackDebounceTimer = timer
            
            // Update previous state
            previousVisibleVideoIds = currentVisibleVideoIds
        } else {
            // Update previous state for all other cases
            previousVisibleVideoIds = currentVisibleVideoIds
        }
        
        // CRITICAL: Clear preserve flag when user explicitly scrolls
        // This ensures foreground recovery knows user changed context
        shouldPreserveStateOnForeground = false
        
        // Check if current primary video is 30% out of view and switch to next
        // This check runs on every scroll update to monitor video position
        checkAndSwitchVideoIfNeeded()
        
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
    }
    
    /// Start primary video playback - play topmost video immediately
    private func startPrimaryVideoPlayback() {
        // Guard against starting if not in idle phase
        guard phase == .idle else {
            print("⚠️ [VideoPlaybackCoordinator] startPrimaryVideoPlayback called but not in idle phase (current: \(phase))")
            return
        }
        
        // Identify topmost video
        guard let primary = identifyPrimaryVideo() else {
            print("⚠️ [VideoPlaybackCoordinator] No primary video identified, stopping all videos")
            stopAllVideos()
            return
        }

        // Pause all other videos
        for video in visibleVideos where video != primary {
            pauseVideo(video)
        }

        // Update state to primary phase BEFORE sending play command
        phase = .primaryPlaying
        primaryVideoId = primary.identifier
        currentlyPlayingVideoIds = [primary.identifier]

        // Send play command for topmost video
        print("📤 [VideoPlaybackCoordinator] Sending play command for topmost video: \(primary.videoMid)")
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
    }
    
    /// Start survey phase - play all visible videos for 2s each (kept for backward compatibility)
    private func startSurveyPhase() {
        // Redirect to new immediate playback
        startPrimaryVideoPlayback()
    }
    
    /// Play a video during survey phase (2s duration) - kept for backward compatibility
    private func playVideoForSurvey(_ video: VideoPlaybackInfo) {
        // No-op - survey phase is no longer used
    }
    
    /// End survey phase and identify primary video - kept for backward compatibility
    private func endSurveyPhase() {
        // No-op - survey phase is no longer used
    }
    
    /// Identify the primary video (topmost video on screen - lowest Y coordinate)
    private func identifyPrimaryVideo() -> VideoPlaybackInfo? {
        guard let tableView = tableView,
              tableView.window != nil else {
            // Fallback: return first visible video if table view not in hierarchy
            return visibleVideos.first
        }
        
        let visibleRect = CGRect(
            x: 0,
            y: tableView.contentOffset.y,
            width: tableView.bounds.width,
            height: tableView.bounds.height
        )
        
        // Find topmost video (lowest Y coordinate)
        var topmostVideo: VideoPlaybackInfo?
        var topmostY: CGFloat = .infinity
        
        for video in visibleVideos {
            // Find the cell containing this video
            guard let cell = findCell(for: video.tweetId, in: tableView) else { continue }
            
            let cellFrame = tableView.convert(cell.frame, to: tableView)
            let cellTopY = cellFrame.minY
            
            // Check if cell is at least partially visible
            let intersection = cellFrame.intersection(visibleRect)
            if intersection.height > 0 && cellTopY < topmostY {
                topmostY = cellTopY
                topmostVideo = video
            }
        }
        
        return topmostVideo ?? visibleVideos.first
    }
    
    /// Check if current primary video is 30% out of view and switch to next video if needed
    private func checkAndSwitchVideoIfNeeded() {
        // Only check during primary playing phase
        guard phase == .primaryPlaying,
              let primaryId = primaryVideoId,
              let tableView = tableView,
              tableView.window != nil else {
            // Skip check if table view not in view hierarchy
            return
        }
        
        // Find current primary video
        guard let currentPrimary = visibleVideos.first(where: { $0.identifier == primaryId }),
              let cell = findCell(for: currentPrimary.tweetId, in: tableView) else {
            return
        }
        
        let visibleRect = CGRect(
            x: 0,
            y: tableView.contentOffset.y,
            width: tableView.bounds.width,
            height: tableView.bounds.height
        )
        
        let cellFrame = tableView.convert(cell.frame, to: tableView)
        let intersection = cellFrame.intersection(visibleRect)
        
        // Calculate visibility ratio (0.0 = completely out of view, 1.0 = fully visible)
        let visibilityRatio = intersection.height / cellFrame.height
        
        // If video is 30% or less visible (70% out of view), switch to next video
        if visibilityRatio <= 0.3 {
            // Find next video in visible videos list
            guard let currentIndex = visibleVideos.firstIndex(where: { $0.identifier == primaryId }),
                  currentIndex + 1 < visibleVideos.count else {
                return
            }
            
            let nextVideo = visibleVideos[currentIndex + 1]
            
            // Pause current video
            pauseVideo(currentPrimary)
            
            // Switch to next video
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
            
            print("🔄 [VideoPlaybackCoordinator] Switched from \(currentPrimary.videoMid) to \(nextVideo.videoMid) (visibility: \(visibilityRatio * 100)%%)")
        }
    }
    
    /// Find table view cell for a given tweet ID
    private func findCell(for tweetId: String, in tableView: UITableView) -> UITableViewCell? {
        // Ensure table view is in view hierarchy before accessing visibleCells
        guard tableView.window != nil else {
            return nil
        }
        
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
        guard let currentPrimary = primaryVideoId else {
            return
        }


        // Find current primary in visible videos list
        guard let currentIndex = visibleVideos.firstIndex(where: { $0.identifier == currentPrimary }) else {
            stopAllVideos()
            return
        }

        // Find next video
        let nextIndex = currentIndex + 1
        
        guard nextIndex < visibleVideos.count else {
            stopAllVideos()
            return
        }

        let nextVideo = visibleVideos[nextIndex]
        let currentVideo = visibleVideos[currentIndex]

        // CRITICAL: Clear coordinatorWantsToPlay flag for finished video
        // This prevents it from auto-playing on next foreground recovery
        NotificationCenter.default.post(
            name: .shouldPauseVideo,
            object: nil,
            userInfo: [
                "videoMid": currentVideo.videoMid
            ]
        )

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
            return
        }

        // If in primary playing phase, advance to next video when current finishes
        if phase == .primaryPlaying,
           let primaryId = primaryVideoId,
           primaryId.contains(videoMid) {
            playNextVisibleVideo()
        }
    }
    
    /// Handle foreground recovery - intelligently decide whether to preserve or reset state
    /// Decision: Preserve if user didn't explicitly scroll away (flag set on background)
    @objc private func handleForegroundRecovery(_ notification: Notification) {
        
        // CRITICAL: Use flag instead of comparing IDs
        // Tweet list might refresh (new IDs) even though user is at same position
        // Flag is cleared only by explicit scroll (updateVisibleTweets)
        let hasActiveState = phase != .idle
        
        let shouldPreserveState = hasActiveState && shouldPreserveStateOnForeground
        
        if shouldPreserveState {
            // PRESERVE STATE: User didn't scroll away, just resume
            
            // Clear flag now that we've used it
            shouldPreserveStateOnForeground = false
            
            if phase == .primaryPlaying, let primaryId = primaryVideoId {
                // Resume primary video - find by videoMid (stable across refreshes)
                
                // Extract videoMid from identifier (format: tweetId_videoMid)
                let primaryVideoMid = primaryId.split(separator: "_").last.map(String.init)
                
                if let primaryVideoMid = primaryVideoMid,
                   let primary = visibleVideos.first(where: { $0.videoMid == primaryVideoMid }) {
                    
                    // CRITICAL: If primary is not the first visible video, restart from first
                    // This ensures playback always starts from top when multiple videos are visible
                    let primaryIndex = visibleVideos.firstIndex(where: { $0.videoMid == primaryVideoMid }) ?? 0
                    
                    if primaryIndex > 0 && visibleVideos.count > 1 {
                        // Primary is not first - restart from first video
                        
                        // CRITICAL: Clear stale coordinatorWantsToPlay flags from other videos
                        // Send pause commands to all videos except the first one
                        for (index, video) in visibleVideos.enumerated() where index > 0 {
                            NotificationCenter.default.post(
                                name: .shouldPauseVideo,
                                object: nil,
                                userInfo: [
                                    "videoMid": video.videoMid
                                ]
                            )
                        }
                        
                        let firstVideo = visibleVideos[0]
                        primaryVideoId = firstVideo.identifier
                        currentlyPlayingVideoIds = [firstVideo.identifier]
                        
                        NotificationCenter.default.post(
                            name: .shouldPlayVideo,
                            object: nil,
                            userInfo: [
                                "tweetId": firstVideo.tweetId,
                                "videoMid": firstVideo.videoMid,
                                "videoIndex": firstVideo.index,
                                "isPrimary": true
                            ]
                        )
                    } else {
                        // Primary is first or only video - resume it
                        primaryVideoId = primary.identifier
                        currentlyPlayingVideoIds = [primary.identifier]

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
                    }
                } else {
                    // Primary video no longer in list (scrolled out), restart playback
                    phase = .idle
                    primaryVideoId = nil
                    currentlyPlayingVideoIds.removeAll()
                    if !visibleVideos.isEmpty {
                        startPrimaryVideoPlayback()
                    }
                }
            }
        } else {
            // RESET STATE: User scrolled away or no active state
            
            // Clear flag
            shouldPreserveStateOnForeground = false
            
            // Clear playing state
            currentlyPlayingVideoIds.removeAll()
            primaryVideoId = nil
            phase = .idle
            
            // Cancel all timers
            surveyTimer?.invalidate()
            surveyTimer = nil
            playbackDebounceTimer?.invalidate()
            playbackDebounceTimer = nil
            scrollStopTimer?.invalidate()
            scrollStopTimer = nil
            
            // If there are visible videos, restart playback
            if !visibleVideos.isEmpty {
                
                // Small delay to ensure video infrastructure is ready
                let timer = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if self.phase == .idle && !self.visibleVideos.isEmpty {
                            self.startPrimaryVideoPlayback()
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                playbackDebounceTimer = timer
            }
        }
    }
}

