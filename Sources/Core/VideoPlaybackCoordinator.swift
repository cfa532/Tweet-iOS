//
//  VideoPlaybackCoordinator.swift
//  Tweet
//
//  Coordinates video playback across the app
//  Behavior: Play topmost video on screen, switch to next when current video is 50% out of view (next video must be 50% on screen)
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
/// 3. When current video is 50% out of view, switch to next video (next video must be 50% on screen)
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
    
    /// PERF FIX: Debounce timer for visibility checks to reduce expensive calculations
    private var visibilityCheckDebounceTimer: Timer?
    private let visibilityCheckDebounceInterval: TimeInterval = 0.15 // 150ms debounce
    
    /// PERF FIX: Cache for visibility ratios to avoid redundant calculations
    private var cachedVisibilityRatios: [String: CGFloat] = [:]
    private let visibilityRatioThreshold: CGFloat = 0.15 // Only update if ratio changes by 15%
    
    /// Timestamp when primary video was last switched (to prevent immediate re-switching)
    private var lastPrimarySwitchTime: Date?
    
    /// PERF FIX: Cache for cell lookups to avoid repeated expensive operations
    private var cellCache: [String: UITableViewCell] = [:]
    private var lastCacheClearTime: Date = Date()
    private let cellCacheClearInterval: TimeInterval = 5.0 // Clear cache every 5 seconds
    
    /// Visible tweet IDs (updated by scroll tracking)
    private var visibleTweetIds: Set<String> = []
    
    /// All videos in the feed (ordered)
    private var allVideos: [VideoPlaybackInfo] = []

    /// Track seen video identifiers (tweetId_videoMid) to prevent duplicates across video list updates
    private var seenVideoIdentifiers = Set<String>()

    /// Store current tweet list for embedded tweet lookup
    private var currentTweets: [Tweet] = []

    /// Currently visible videos (computed from visibleTweetIds + allVideos)
    /// Visible videos sorted by position (topmost first)
    private var visibleVideos: [VideoPlaybackInfo] {
        let filtered = allVideos.filter { visibleTweetIds.contains($0.tweetId) }
        
        // CRITICAL: Sort by position (Y coordinate) to ensure correct playback order
        // This ensures videos play in feed order, not array order
        guard let tableView = tableView, tableView.window != nil else {
            print("⚠️ [VideoPlaybackCoordinator] Table view not available, using filtered order (not sorted by position)")
            return filtered  // Fallback to filtered order if table view not available
        }
        
        // Sort by Y position (topmost first)
        let sorted = filtered.sorted { video1, video2 in
            guard let cell1 = findCell(for: video1.tweetId, in: tableView),
                  let cell2 = findCell(for: video2.tweetId, in: tableView) else {
                // If we can't find cells, use position in allVideos as fallback
                // This maintains original feed order
                if let index1 = allVideos.firstIndex(where: { $0.identifier == video1.identifier }),
                   let index2 = allVideos.firstIndex(where: { $0.identifier == video2.identifier }) {
                    return index1 < index2
                }
                return false
            }
            
            let frame1 = tableView.convert(cell1.frame, to: tableView)
            let frame2 = tableView.convert(cell2.frame, to: tableView)
            
            return frame1.minY < frame2.minY  // Lower Y = higher on screen = earlier in feed
        }
        
        return sorted
    }
    
    /// Is currently scrolling
    private var isScrolling: Bool = false
    
    /// Scroll direction (true = scrolling down, false = scrolling up)
    private var scrollDirection: Bool = true // Default to scrolling down
    
    /// Previous content offset to track scroll direction
    private var previousContentOffset: CGFloat = 0
    
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
    
    /// Add embedded tweet videos to the video list when they become available
    /// Called by TweetItem when embedded tweets are loaded
    func addEmbeddedTweetVideos(quotingTweetId: String, embeddedTweet: Tweet) {
        var videosToAdd: [VideoPlaybackInfo] = []

        if let embeddedAttachments = embeddedTweet.attachments {
            for (index, attachment) in embeddedAttachments.enumerated() {
                if attachment.type == .video || attachment.type == .hls_video {
                    let videoInfo = VideoPlaybackInfo(
                        tweetId: embeddedTweet.mid,  // Use embedded tweet's ID
                        videoMid: attachment.mid,
                        index: index
                    )

                    if seenVideoIdentifiers.contains(videoInfo.identifier) {
                        continue
                    }

                    videosToAdd.append(videoInfo)
                    seenVideoIdentifiers.insert(videoInfo.identifier)
                }
            }
        }

        if !videosToAdd.isEmpty {
            allVideos.append(contentsOf: videosToAdd)
            print("VideoPlaybackCoordinator: Added \(videosToAdd.count) embedded tweet videos, total videos now: \(allVideos.count)")

            // Update FullScreenVideoManager with the new video list
            FullScreenVideoManager.shared.updateVideoList(videos: allVideos, tweets: currentTweets)
        }
    }

    /// Build video list from tweets (including pinned tweets)
    func buildVideoList(from tweets: [Tweet], pinnedTweets: [Tweet] = []) {
        var videos: [VideoPlaybackInfo] = []

        // Clear and reset seen identifiers when rebuilding video list
        seenVideoIdentifiers.removeAll()

        // Store tweet list for embedded tweet lookup
        currentTweets = pinnedTweets + tweets

        // CRITICAL: Build a map of embedded tweet IDs (tweets that are quoted in other tweets)
        // A tweet is embedded if its ID appears as originalTweetId in another tweet
        // These should NOT have their videos tracked, even if they appear standalone in the feed
        let allTweets = pinnedTweets + tweets
        
        // First, collect all quoted tweets (tweets with originalTweetId AND own content)
        // A quoted tweet has originalTweetId AND (has content text OR has attachments)
        // A pure retweet has originalTweetId AND (no content text AND no attachments)
        var quotedTweets: [(id: String, originalTweetId: String)] = []
        for tweet in allTweets {
            if let originalTweetId = tweet.originalTweetId {
                // Check if this tweet has its own content (text OR attachments)
                let hasContentText = tweet.content != nil && !(tweet.content?.isEmpty ?? true)
                let hasAttachments = tweet.attachments != nil && !(tweet.attachments?.isEmpty ?? true)
                let hasOwnContent = hasContentText || hasAttachments
                
                if hasOwnContent {
                    // This is a quoted tweet (has originalTweetId AND own content)
                    quotedTweets.append((id: tweet.mid, originalTweetId: originalTweetId))
                }
            }
        }
        
        // Build set of embedded tweet IDs (IDs that are referenced as originalTweetId in quoted tweets)
        let embeddedTweetIds = Set(quotedTweets.map { $0.originalTweetId })
        
        // Process pinned tweets first (they appear at the top)
        for (_, tweet) in pinnedTweets.enumerated() {
            // Include embedded tweets - they should be managed by coordinator
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
                    
                    if embeddedTweetIds.contains(tweet.mid) {
                    }
                }
            }
        }
        
        // Then process regular tweets
        for (_, tweet) in tweets.enumerated() {
            // Include embedded tweets - they should be managed by coordinator
            // Determine if this is a pure retweet (no own content, just forwarding)
            // A pure retweet has originalTweetId AND (no content text AND no attachments)
            // A quoted tweet has originalTweetId AND (has content text OR has attachments)
            let hasContentText = tweet.content != nil && !(tweet.content?.isEmpty ?? true)
            let hasAttachments = tweet.attachments != nil && !(tweet.attachments?.isEmpty ?? true)
            let hasOwnContent = hasContentText || hasAttachments
            let hasOriginalTweet = tweet.originalTweetId != nil
            let isPureRetweet = hasOriginalTweet && !hasOwnContent // Has original but no own content
            let isQuotedTweet = hasOriginalTweet && hasOwnContent // Has original AND own content (quoted tweet)
            
            if isPureRetweet {
                // PURE RETWEET: Get attachments from original tweet, use retweet's ID for positioning
                // Only use cached tweets (non-blocking) - will be added later when fetched by TweetItemView
                if let originalTweetId = tweet.originalTweetId {
                    // Try singleton cache only (fast, non-blocking)
                    let originalTweet = Tweet.getInstance(for: originalTweetId)

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
                        print("VideoPlaybackCoordinator: Original tweet \(originalTweetId) not cached yet for retweet \(tweet.mid), will be added later when fetched by TweetItemView")
                    }
                }
            } else {
                // REGULAR TWEET or QUOTED TWEET: Process the tweet's own attachments
                // For quoted tweets, also process embedded tweet's videos (they're now managed by coordinator)
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
                
                // For quoted tweets, also process embedded tweet's videos (they're now managed by coordinator)
                if isQuotedTweet, let originalTweetId = tweet.originalTweetId {
                    // Try to get embedded tweet from cache only (non-blocking)
                    // They will be added later when fetched asynchronously by TweetItem
                    let embeddedTweet = Tweet.getInstance(for: originalTweetId)

                    // Only add embedded tweet videos if they're already cached
                    // They will be added later when fetched asynchronously by TweetItem
                    if let embeddedTweet = embeddedTweet,
                       let embeddedAttachments = embeddedTweet.attachments {
                        for (index, attachment) in embeddedAttachments.enumerated() {
                            if attachment.type == .video || attachment.type == .hls_video {
                                // Use embedded tweet's ID for tracking (not the quoting tweet's ID)
                                let videoInfo = VideoPlaybackInfo(
                                    tweetId: originalTweetId,  // Use embedded tweet's ID
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
                        print("VideoPlaybackCoordinator: Embedded tweet \(originalTweetId) not cached yet, will be added later when fetched by TweetItemView")
                    }
                }
            }
        }
        
        self.allVideos = videos
        
        // PERF FIX: Clear caches when video list is rebuilt to prevent stale data
        cellCache.removeAll()
        cachedVisibilityRatios.removeAll()
        lastCacheClearTime = Date()
        
        // Share the video list with FullScreenVideoManager to avoid duplicate tracking
        // This consolidates video tracking in one place
        FullScreenVideoManager.shared.updateVideoList(videos: videos, tweets: tweets)
    }
    
    /// Previously visible video IDs (to detect actual video changes, not just tweet changes)
    private var previousVisibleVideoIds: Set<String> = []
    
    /// Update visible tweets (called during scrolling)
    func updateVisibleTweets(_ tweetIds: Set<String>) {
        // Track scroll direction based on content offset
        if let tableView = tableView, tableView.window != nil {
            let currentOffset = tableView.contentOffset.y
            if previousContentOffset != 0 {
                // Determine scroll direction: true = scrolling down, false = scrolling up
                scrollDirection = currentOffset > previousContentOffset
            }
            previousContentOffset = currentOffset
        }
        // CRITICAL: Filter to only tweets that have videos in allVideos (similar to Android's playbackTweetId check)
        // This excludes embedded/quoted tweet videos that shouldn't be coordinated
        let tweetsWithVideos = Set(allVideos.map { $0.tweetId })
        
        var filteredTweetIds = tweetIds.intersection(tweetsWithVideos)
        
        // CRITICAL: Also include embedded tweet IDs when their quoting tweets are visible
        // When a quoted tweet is visible, its embedded tweet should also be considered visible
        for visibleTweetId in tweetIds {
            if let quotingTweet = Tweet.getInstance(for: visibleTweetId) ?? TweetCacheManager.shared.fetchTweetSync(mid: visibleTweetId) {
                if let embeddedTweetId = quotingTweet.originalTweetId,
                   tweetsWithVideos.contains(embeddedTweetId) {
                    // The quoting tweet is visible, so include the embedded tweet ID
                    filteredTweetIds.insert(embeddedTweetId)
                }
            }
        }
        
        self.visibleTweetIds = filteredTweetIds
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
            
            // PERF FIX: Clear caches for videos that are no longer visible
            // This prevents stale cell references and visibility ratios
            let tweetsToRemove = Set(allVideos.filter { videosToStop.contains($0.videoMid) }.map { $0.tweetId })
            for tweetId in tweetsToRemove {
                cellCache.removeValue(forKey: tweetId)
                // Clear visibility ratios for all videos in this tweet
                for video in allVideos where video.tweetId == tweetId {
                    cachedVisibilityRatios.removeValue(forKey: video.identifier)
                }
            }
        }
        
        // Start playback when videos become visible OR when in idle phase with videos
        // This handles both "new videos" and "coming back to idle with videos present"
        if videoVisibilityChanged && !currentVisibleVideoIds.isEmpty {
            // Allow primary video to change during scroll - re-identify primary video if needed
            if phase == .primaryPlaying,
               let primaryId = primaryVideoId,
               currentVisibleVideoIds.contains(where: { primaryId.contains($0) }) {
                // Primary video still visible - check if we should switch to a different primary video
                // This allows the primary video to change during scroll based on position
                checkAndSwitchVideoIfNeeded()
                previousVisibleVideoIds = currentVisibleVideoIds
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
        
        // PERF FIX: Debounce visibility checks to reduce expensive calculations
        // Cancel existing timer
        visibilityCheckDebounceTimer?.invalidate()
        
        // Schedule debounced check
        visibilityCheckDebounceTimer = Timer(timeInterval: visibilityCheckDebounceInterval, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.checkAndSwitchVideoIfNeeded()
            }
        }
        RunLoop.main.add(visibilityCheckDebounceTimer!, forMode: .common)
        
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
        
        // PERF FIX: Cancel visibility check debounce timer
        visibilityCheckDebounceTimer?.invalidate()
        visibilityCheckDebounceTimer = nil
        
        // PERF FIX: Clear caches
        cachedVisibilityRatios.removeAll()
        cellCache.removeAll()
        
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
        
        // Initialize visibility ratio cache for new primary video to prevent immediate re-switching
        // Set to 1.0 (fully visible) to prevent glitch where video stops shortly after becoming primary
        cachedVisibilityRatios[primary.identifier] = 1.0
        
        // Record switch time to prevent immediate re-checking
        lastPrimarySwitchTime = Date()

        // Send play command for primary video (topmost when scrolling down, bottommost when scrolling up)
        let direction = scrollDirection ? "topmost (scrolling DOWN)" : "bottommost (scrolling UP)"
        print("📤 [VideoPlaybackCoordinator] Sending play command for \(direction) video: \(primary.videoMid)")
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
    
    /// Identify the primary video based on scroll direction
    /// - Scrolling down: topmost video (lowest Y coordinate)
    /// - Scrolling up: bottommost video (highest Y coordinate)
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
        
        // PERF FIX: Clear cell cache periodically
        let now = Date()
        if now.timeIntervalSince(lastCacheClearTime) > cellCacheClearInterval {
            cellCache.removeAll()
            lastCacheClearTime = now
        }
        
        if scrollDirection {
            // Scrolling DOWN: Find topmost video (lowest Y coordinate) that is at least 50% visible
            var topmostVideo: VideoPlaybackInfo?
            var topmostY: CGFloat = .infinity
            
            for video in visibleVideos {
                // PERF FIX: Use cached cell if available
                let cell: UITableViewCell
                if let cachedCell = cellCache[video.tweetId] {
                    cell = cachedCell
                } else {
                    guard let foundCell = findCell(for: video.tweetId, in: tableView) else { continue }
                    cellCache[video.tweetId] = foundCell
                    cell = foundCell
                }
                
                let cellFrame = tableView.convert(cell.frame, to: tableView)
                let cellTopY = cellFrame.minY
                
                // PERF FIX: Early exit if this cell is already below our current topmost
                if cellTopY >= topmostY {
                    continue
                }
                
                // Check if cell is at least 50% visible
                let intersection = cellFrame.intersection(visibleRect)
                let visibilityRatio = cellFrame.height > 0 ? intersection.height / cellFrame.height : 0
                if visibilityRatio >= 0.5 && cellTopY < topmostY {
                    topmostY = cellTopY
                    topmostVideo = video
                }
            }
            
            return topmostVideo ?? visibleVideos.first
        } else {
            // Scrolling UP: Find bottommost video (highest Y coordinate) that is at least 50% visible
            var bottommostVideo: VideoPlaybackInfo?
            var bottommostY: CGFloat = -.infinity
            
            for video in visibleVideos {
                // PERF FIX: Use cached cell if available
                let cell: UITableViewCell
                if let cachedCell = cellCache[video.tweetId] {
                    cell = cachedCell
                } else {
                    guard let foundCell = findCell(for: video.tweetId, in: tableView) else { continue }
                    cellCache[video.tweetId] = foundCell
                    cell = foundCell
                }
                
                let cellFrame = tableView.convert(cell.frame, to: tableView)
                let cellBottomY = cellFrame.maxY
                
                // PERF FIX: Early exit if this cell is already above our current bottommost
                if cellBottomY <= bottommostY {
                    continue
                }
                
                // Check if cell is at least 50% visible
                let intersection = cellFrame.intersection(visibleRect)
                let visibilityRatio = cellFrame.height > 0 ? intersection.height / cellFrame.height : 0
                if visibilityRatio >= 0.5 && cellBottomY > bottommostY {
                    bottommostY = cellBottomY
                    bottommostVideo = video
                }
            }
            
            return bottommostVideo ?? visibleVideos.last
        }
    }
    
    /// Check if current primary video is less than 50% visible and switch to next video if needed
    private func checkAndSwitchVideoIfNeeded() {
        // Only check during primary playing phase
        guard phase == .primaryPlaying,
              let primaryId = primaryVideoId,
              let tableView = tableView,
              tableView.window != nil else {
            // Skip check if table view not in view hierarchy
            return
        }
        
        // Prevent immediate re-switching after a video becomes primary (prevents glitch when scrolling up)
        // Wait at least 0.3 seconds after a switch before allowing another switch
        if let lastSwitchTime = lastPrimarySwitchTime {
            let timeSinceSwitch = Date().timeIntervalSince(lastSwitchTime)
            if timeSinceSwitch < 0.3 {
                // Too soon after switch - skip check to prevent glitch
                return
            }
        }
        
        // Find current primary video
        guard let currentPrimary = visibleVideos.first(where: { $0.identifier == primaryId }) else {
            return
        }
        
        // PERF FIX: Use cached cell if available, otherwise find and cache it
        let cell: UITableViewCell
        if let cachedCell = cellCache[currentPrimary.tweetId] {
            cell = cachedCell
        } else {
            guard let foundCell = findCell(for: currentPrimary.tweetId, in: tableView) else {
                return
            }
            cellCache[currentPrimary.tweetId] = foundCell
            cell = foundCell
        }
        
        // PERF FIX: Clear cell cache periodically to prevent stale references
        let now = Date()
        if now.timeIntervalSince(lastCacheClearTime) > cellCacheClearInterval {
            cellCache.removeAll()
            lastCacheClearTime = now
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
        let visibilityRatio = cellFrame.height > 0 ? intersection.height / cellFrame.height : 0
        
        // PERF FIX: Only proceed if visibility ratio changed significantly or crossed threshold
        let previousRatio = cachedVisibilityRatios[primaryId] ?? 1.0
        let ratioChange = abs(visibilityRatio - previousRatio)
        
        // Update cache
        cachedVisibilityRatios[primaryId] = visibilityRatio
        
        // Only check threshold if ratio changed significantly or crossed the 50% threshold
        let crossedThreshold = (previousRatio > 0.5 && visibilityRatio <= 0.5) || (previousRatio <= 0.5 && visibilityRatio > 0.5)
        
        guard crossedThreshold || ratioChange >= visibilityRatioThreshold else {
            // No significant change, skip expensive operations
            return
        }
        
        // If video is less than 50% visible, switch to appropriate video based on scroll direction
        if visibilityRatio < 0.5 {
            // Re-identify primary video based on current scroll direction
            // This handles both scrolling down (switch to next) and scrolling up (switch to previous)
            guard let newPrimary = identifyPrimaryVideo(), newPrimary.identifier != primaryId else {
                return
            }
            
            // Pause current video
            pauseVideo(currentPrimary)
            
        // Switch to new primary video based on scroll direction
        primaryVideoId = newPrimary.identifier
        currentlyPlayingVideoIds = [newPrimary.identifier]
        
        // Initialize visibility ratio cache for new primary video to prevent immediate re-switching
        // Set to 1.0 (fully visible) to prevent glitch where video stops shortly after becoming primary
        cachedVisibilityRatios[newPrimary.identifier] = 1.0
        
        // Record switch time to prevent immediate re-checking
        lastPrimarySwitchTime = Date()
        
        NotificationCenter.default.post(
            name: .shouldPlayVideo,
            object: nil,
            userInfo: [
                "tweetId": newPrimary.tweetId,
                "videoMid": newPrimary.videoMid,
                "videoIndex": newPrimary.index,
                "isPrimary": true
            ]
        )
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

        // CRITICAL: visibleVideos is sorted by position, so advancing by index is correct
        // But we need to ensure we're advancing to the next video in feed order (by Y position)
        // Find current primary in visible videos list (sorted by position)
        guard let currentIndex = visibleVideos.firstIndex(where: { $0.identifier == currentPrimary }) else {
            print("⚠️ [VideoPlaybackCoordinator] Current primary \(currentPrimary) not found in visibleVideos")
            stopAllVideos()
            return
        }

        // Find next video based on scroll direction
        // Scrolling down: next video (index + 1)
        // Scrolling up: previous video (index - 1)
        let targetIndex: Int
        if scrollDirection {
            // Scrolling DOWN: advance to next video
            targetIndex = currentIndex + 1
            guard targetIndex < visibleVideos.count else {
                print("📹 [VideoPlaybackCoordinator] No more videos to play (current index: \(currentIndex), total: \(visibleVideos.count))")
                stopAllVideos()
                return
            }
        } else {
            // Scrolling UP: go back to previous video
            targetIndex = currentIndex - 1
            guard targetIndex >= 0 else {
                print("📹 [VideoPlaybackCoordinator] No previous video to play (current index: \(currentIndex))")
                stopAllVideos()
                return
            }
        }

        let nextVideo = visibleVideos[targetIndex]
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
        
        // CRITICAL: Use flag to track if user explicitly scrolled away
        // Flag is set when app enters background (if playback was active)
        // Flag is cleared only by explicit scroll (updateVisibleTweets)
        // This distinguishes between background return (preserve) vs user scroll (reset)
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
            
            // PERF FIX: Cancel visibility check debounce timer and clear caches
            visibilityCheckDebounceTimer?.invalidate()
            visibilityCheckDebounceTimer = nil
            cachedVisibilityRatios.removeAll()
            cellCache.removeAll()
            
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

