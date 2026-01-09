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
    
    /// Flag to preserve state on foreground (cleared on explicit scroll)
    private var shouldPreserveStateOnForeground = false
    
    /// Timer for survey phase (2s per video)
    private var surveyTimer: Timer?
    
    /// Timer for detecting scroll stop (2s delay)
    private var scrollStopTimer: Timer?
    
    /// Timer for debouncing video playback (0.1s delay)
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
            print("🔄 [VideoOrchestrator] App backgrounded with active state - will preserve on foreground")
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
        
        print("🟢 [BUILD VIDEO LIST] Called with \(tweets.count) regular tweets and \(pinnedTweets.count) pinned tweets")
        
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
                        print("🟢 [BUILD VIDEO LIST] Skipping duplicate PINNED video: identifier=\(videoInfo.identifier)")
                        continue
                    }
                    
                    print("🟢 [BUILD VIDEO LIST] Adding PINNED video: tweetId=\(tweet.mid), videoMid=\(attachment.mid)")
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
            let isQuotedTweet = hasOriginalTweet && hasTweetContent // Has both original and own content (quoted tweet)
            
            if isPureRetweet {
                // PURE RETWEET: Get attachments from original tweet, use retweet's ID for positioning
                if let originalTweetId = tweet.originalTweetId,
                   let originalTweet = Tweet.getInstance(for: originalTweetId),
                   let originalAttachments = originalTweet.attachments {
                    
                    for (index, attachment) in originalAttachments.enumerated() {
                        if attachment.type == .video || attachment.type == .hls_video {
                            let videoInfo = VideoPlaybackInfo(
                                tweetId: tweet.mid,  // Use retweet's ID for positioning
                                videoMid: attachment.mid,
                                index: index
                            )
                            
                            if seenVideoIdentifiers.contains(videoInfo.identifier) {
                                print("🟢 [BUILD VIDEO LIST] Skipping duplicate RETWEETED video: identifier=\(videoInfo.identifier)")
                                continue
                            }
                            
                            print("🟢 [BUILD VIDEO LIST] Adding RETWEETED video: tweetId=\(tweet.mid), videoMid=\(attachment.mid), identifier=\(videoInfo.identifier)")
                            videos.append(videoInfo)
                            seenVideoIdentifiers.insert(videoInfo.identifier)
                        }
                    }
                } else {
                    print("🟢 [BUILD VIDEO LIST] Skipping pure retweet \(tweet.mid) - original tweet not cached yet")
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
                                print("🟢 [BUILD VIDEO LIST] Skipping duplicate video: identifier=\(videoInfo.identifier)")
                                continue
                            }
                            
                            let tweetType = isQuotedTweet ? "QUOTED TWEET (own content)" : "REGULAR"
                            print("🟢 [BUILD VIDEO LIST] Adding \(tweetType) video: tweetId=\(tweet.mid), videoMid=\(attachment.mid), identifier=\(videoInfo.identifier)")
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
            // This prevents restarting the video during small scrolls
            if phase == .primaryPlaying,
               let primaryId = primaryVideoId,
               currentVisibleVideoIds.contains(where: { primaryId.contains($0) }) {
                previousVisibleVideoIds = currentVisibleVideoIds
                return
            }
            
            // CRITICAL FIX: Don't reset if we're in surveying phase and just adding more videos
            // This prevents duplicate survey commands when new video cells appear during the survey
            if phase == .surveying {
                // Only add new videos to the survey, don't restart it
                let newVideos = visibleVideos.filter { video in
                    !currentlyPlayingVideoIds.contains(video.identifier)
                }
                for video in newVideos {
                    playVideoForSurvey(video)
                }
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
        
        // CRITICAL: Clear preserve flag when user explicitly scrolls
        // This ensures foreground recovery knows user changed context
        shouldPreserveStateOnForeground = false
        
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
    
    /// Start survey phase - play all visible videos for 2s each
    private func startSurveyPhase() {
        NSLog("🎬 [VideoOrchestrator] startSurveyPhase called (NSLog)")
        
        // Guard against starting survey if not in idle phase
        guard phase == .idle else {
            NSLog("🎬 [VideoOrchestrator] Cannot start survey - already in \(phase) phase")
            print("🎬 [VideoOrchestrator] Cannot start survey - already in \(phase) phase")
            return
        }
        
        NSLog("🎬 [VideoOrchestrator] Starting survey phase with \(visibleVideos.count) videos")
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
        // Guard against ending survey if not in surveying phase
        guard phase == .surveying else {
            print("🎬 [VideoOrchestrator] Ignoring endSurvey - not in surveying phase (current: \(phase))")
            return
        }
        
        // Invalidate survey timer to prevent duplicate calls
        surveyTimer?.invalidate()
        surveyTimer = nil
        
        // Identify primary video (most visible/centered)
        guard let primary = identifyPrimaryVideo() else {
            print("🎬 [VideoOrchestrator] No primary video found, stopping all")
            stopAllVideos()
            return
        }

        // Pause all non-primary videos
        for video in visibleVideos where video != primary {
            pauseVideo(video)
        }

        // Update state to primary phase
        primaryVideoId = primary.identifier
        currentlyPlayingVideoIds = [primary.identifier]
        phase = .primaryPlaying

        // CRITICAL: Always send play command for primary video, even if we think it's "already playing"
        // This ensures playback starts even if player creation failed during survey phase (e.g., network errors)
        // 
        // Why this is safe (NO JITTER):
        // - SimpleVideoPlayer checks `player.rate > 0` before playing
        // - If ACTUALLY playing, it returns immediately without seeking/restarting
        // - If NOT playing (failed creation), it starts playback
        // - This gives us reliability (handles failures) without jitter (idempotent)
        print("🎬 [VideoOrchestrator] Sending play command to ensure primary video plays")
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
            print("🎬 [VideoOrchestrator] No primary video to advance from")
            return
        }

        print("🎬 [VideoOrchestrator] Advancing from primary: \(currentPrimary)")
        print("🎬 [VideoOrchestrator] Visible videos: \(visibleVideos.map { $0.identifier })")

        // Find current primary in visible videos list
        guard let currentIndex = visibleVideos.firstIndex(where: { $0.identifier == currentPrimary }) else {
            print("🎬 [VideoOrchestrator] Current primary not in visible list - stopping all")
            stopAllVideos()
            return
        }

        // Find next video
        let nextIndex = currentIndex + 1
        print("🎬 [VideoOrchestrator] Current index: \(currentIndex), next index: \(nextIndex), total videos: \(visibleVideos.count)")
        
        guard nextIndex < visibleVideos.count else {
            print("🎬 [VideoOrchestrator] No more videos to play - stopping all")
            stopAllVideos()
            return
        }

        let nextVideo = visibleVideos[nextIndex]
        let currentVideo = visibleVideos[currentIndex]
        print("🎬 [VideoOrchestrator] Advancing to next video: \(nextVideo.videoMid)")

        // CRITICAL: Clear coordinatorWantsToPlay flag for finished video
        // This prevents it from auto-playing on next foreground recovery
        print("🎬 [VideoOrchestrator] Sending pause command to finished video: \(currentVideo.videoMid)")
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

        print("🎬 [VideoOrchestrator] Sending play command to next video")
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

        // If in survey phase, a video finishing means it's short or was near end
        // Immediately end survey and make it (or next one) primary
        if phase == .surveying {
            print("🎬 [VideoOrchestrator] Video finished during survey - ending survey early")
            endSurveyPhase()
            return
        }

        // If in primary playing phase, advance to next video
        if phase == .primaryPlaying,
           let primaryId = primaryVideoId,
           primaryId.contains(videoMid) {
            print("🎬 [VideoOrchestrator] Primary video finished - advancing to next")
            playNextVisibleVideo()
        } else {
            print("🎬 [VideoOrchestrator] Non-primary video finished (phase:\(phase), hasPrimary:\(primaryVideoId != nil)) - ignoring")
        }
    }
    
    /// Handle foreground recovery - intelligently decide whether to preserve or reset state
    /// Decision: Preserve if user didn't explicitly scroll away (flag set on background)
    @objc private func handleForegroundRecovery(_ notification: Notification) {
        NSLog("🔄 [VideoOrchestrator] Foreground recovery START (NSLog)")
        print("🔄 [VideoOrchestrator] Foreground recovery - checking if state should be preserved")
        
        // CRITICAL: Use flag instead of comparing IDs
        // Tweet list might refresh (new IDs) even though user is at same position
        // Flag is cleared only by explicit scroll (updateVisibleTweets)
        let hasActiveState = phase != .idle
        
        let shouldPreserveState = hasActiveState && shouldPreserveStateOnForeground
        
        if shouldPreserveState {
            // PRESERVE STATE: User didn't scroll away, just resume
            print("🔄 [VideoOrchestrator] State preservation flag set (phase:\(phase)) - preserving playback state")
            
            // Clear flag now that we've used it
            shouldPreserveStateOnForeground = false
            
            if phase == .primaryPlaying, let primaryId = primaryVideoId {
                // Resume primary video - find by videoMid (stable across refreshes)
                print("🔄 [VideoOrchestrator] Resuming primary video after foreground (primaryId: \(primaryId))")
                
                // Extract videoMid from identifier (format: tweetId_videoMid)
                let primaryVideoMid = primaryId.split(separator: "_").last.map(String.init)
                print("🔄 [VideoOrchestrator] Extracted videoMid: \(primaryVideoMid ?? "nil") from primaryId")
                print("🔄 [VideoOrchestrator] Current visible videos: \(visibleVideos.map { $0.videoMid })")
                
                if let primaryVideoMid = primaryVideoMid,
                   let primary = visibleVideos.first(where: { $0.videoMid == primaryVideoMid }) {
                    
                    // CRITICAL: If primary is not the first visible video, restart from first
                    // This ensures playback always starts from top when multiple videos are visible
                    let primaryIndex = visibleVideos.firstIndex(where: { $0.videoMid == primaryVideoMid }) ?? 0
                    
                    if primaryIndex > 0 && visibleVideos.count > 1 {
                        // Primary is not first - restart from first video
                        print("🔄 [VideoOrchestrator] Primary video is at index \(primaryIndex), restarting from first video")
                        
                        // CRITICAL: Clear stale coordinatorWantsToPlay flags from other videos
                        // Send pause commands to all videos except the first one
                        for (index, video) in visibleVideos.enumerated() where index > 0 {
                            print("🔄 [VideoOrchestrator] Clearing stale flag for video at index \(index): \(video.videoMid)")
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
                        
                        print("🔄 [VideoOrchestrator] Sending play command to first video: \(firstVideo.videoMid)")
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
                        print("🔄 [VideoOrchestrator] Found primary video, updating identifier from \(primaryVideoId!) to \(primary.identifier)")
                        primaryVideoId = primary.identifier
                        currentlyPlayingVideoIds = [primary.identifier]

                        print("🔄 [VideoOrchestrator] Sending play command to primary: \(primary.videoMid)")
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
                    // Primary video no longer in list (scrolled out), restart survey
                    print("🔄 [VideoOrchestrator] Primary video (\(primaryVideoMid ?? "unknown")) no longer visible - restarting survey")
                    print("🔄 [VideoOrchestrator] Available videos: \(visibleVideos.map { $0.videoMid })")
                    phase = .idle
                    primaryVideoId = nil
                    currentlyPlayingVideoIds.removeAll()
                    if !visibleVideos.isEmpty {
                        startSurveyPhase()
                    }
                }
            } else if phase == .surveying {
                // Continue survey phase
                print("🔄 [VideoOrchestrator] Continuing survey phase after foreground")
                // Re-send play commands to ensure survey continues
                for video in visibleVideos {
                    playVideoForSurvey(video)
                }
            }
        } else {
            // RESET STATE: User scrolled away or no active state
            print("🔄 [VideoOrchestrator] User scrolled or no active state - restarting survey")
            print("🔄 [VideoOrchestrator] (hasActive:\(hasActiveState), preserveFlag:\(shouldPreserveStateOnForeground))")
            
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
            
            // If there are visible videos, restart survey
            if !visibleVideos.isEmpty {
                print("🔄 [VideoOrchestrator] Found \(visibleVideos.count) visible videos - restarting survey phase")
                
                // Small delay to ensure video infrastructure is ready
                let timer = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if self.phase == .idle && !self.visibleVideos.isEmpty {
                            print("🔄 [VideoOrchestrator] Starting survey phase after foreground recovery")
                            self.startSurveyPhase()
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                playbackDebounceTimer = timer
            } else {
                print("🔄 [VideoOrchestrator] No visible videos - waiting for scroll updates")
            }
        }
    }
}

