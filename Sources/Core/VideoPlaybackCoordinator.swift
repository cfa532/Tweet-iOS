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

// MARK: - Delegate-Based Communication (Phase 3)

/// Protocol for video control communication between VideoPlaybackCoordinator and MediaCell
protocol MediaCellDelegate {
    /// Called when a video should start/resume playing
    func shouldPlayVideo(withMid mid: String)

    /// Called when a video should pause
    func shouldPauseVideo(withMid mid: String)

    /// Called when a video should stop and reset
    func shouldStopVideo(withMid mid: String)

    /// Called when all videos should stop
    func shouldStopAllVideos()

    /// Called when video timer should update
    func updateVideoTimer(withMid mid: String, timeRemaining: String)

    /// Called when app becomes active (for base URL updates)
    func appDidBecomeActive()

    /// Called when user data is updated
    func userDidUpdate(userId: String)
}

/// Video state during orchestration
private enum VideoPlaybackPhase {
    case idle                    // No playback
    case primaryPlaying          // Primary video is playing to completion
}

/// Canonical video tracking info.
///
/// - `cellTweetId`: The tweet ID of the *feed cell* (retweet ID for retweets, quoting tweet ID for embedded/quoted media).
/// - `mediaTweetId`: The tweet ID that actually owns the attachments (original tweet for retweets, embedded tweet for quoted media).
/// - `attachmentIndex`: The index in `mediaTweetId.attachments` (can be > 3; fullscreen needs this).
///
/// Feed playback coordination only considers `attachmentIndex < 4` because `MediaGridView` only renders the first 4 items.
struct VideoPlaybackInfo: Equatable {
    let cellTweetId: String
    let mediaTweetId: String
    let videoMid: String
    let attachmentIndex: Int
    
    var identifier: String {
        "\(cellTweetId)_\(videoMid)_\(attachmentIndex)"
    }
    
    var isInVisibleMediaRange: Bool {
        attachmentIndex < 4
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
    
    /// Timer for debouncing video playback (0.2s delay)
    private var playbackDebounceTimer: Timer?

    /// Timestamp when primary video was last switched (to prevent immediate re-switching)
    private var lastPrimarySwitchTime: Date?

    /// Visible tweet IDs (updated by scroll tracking)
    private var visibleTweetIds: Set<String> = []

    /// All videos in the app (ordered by feed, then attachmentIndex).
    private var allVideos: [VideoPlaybackInfo] = []

    /// Store current tweet list for embedded tweet lookup
    private var currentTweets: [Tweet] = []

    /// Cached visibility ratios for hysteresis (only tracks primary video)
    private var cachedVisibilityRatios: [String: CGFloat] = [:]
    private let visibilityRatioThreshold: CGFloat = 0.10

    /// Single debounce timer for batched visibility updates during scroll
    private var visibilityUpdateDebounceTimer: Timer?

    /// Last time we preloaded videos during scroll (for throttling)
    private var lastScrollPreloadTime: Date?
    private let scrollPreloadThrottleInterval: TimeInterval = 0.3

    /// Track which videos have been preloaded to avoid duplicate preloads
    private var preloadedVideoMids: Set<String> = []

    /// Track async tasks to prevent leaks
    /// MEMORY FIX: Use UUID-based tracking so tasks can remove themselves on completion
    /// Since this class is @MainActor, all access is serialized on the main actor
    /// Uses nonisolated(unsafe) for deinit access - safe because deinit runs once
    private nonisolated(unsafe) var activeAsyncTaskIds: Set<UUID> = []
    private let maxConcurrentTasks = 10  // Increased limit since we properly clean up now

    // MARK: - Delegate-Based Communication (Phase 3)

    /// Registered MediaCell delegates for direct communication (keyed by video identifier:
    /// cellTweetId_videoMid_attachmentIndex). This allows the same videoMid to have separate
    /// delegates when it appears in both a tweet and its retweet.
    private var mediaCellDelegates: [String: MediaCellDelegate] = [:]

    /// When true, the feed is covered by an overlay (fullscreen cover/sheet/login/etc).
    /// The coordinator must not emit play commands while covered, otherwise videos can start "invisibly".
    private var isPlaybackSuppressedByOverlay: Bool = false

    /// Track an async task for proper cleanup
    /// MEMORY FIX: Tasks now self-remove on completion via UUID tracking
    /// Runs on MainActor to avoid lock requirements
    private func trackAsyncTask(_ task: Task<Void, Never>) {
        let taskId = UUID()

        // If we're at the limit, don't add more (let natural completion clean up)
        if activeAsyncTaskIds.count >= maxConcurrentTasks {
            print("⚠️ [TASK LIMIT] Hit max \(maxConcurrentTasks) tasks, skipping new task")
            return
        }

        activeAsyncTaskIds.insert(taskId)

        // Self-cleaning wrapper: remove taskId when original task completes
        Task { @MainActor [weak self] in
            // Wait for the tracked task to complete
            _ = await task.value

            // Remove from tracking set (on MainActor, so no lock needed)
            self?.activeAsyncTaskIds.remove(taskId)
        }
    }

    /// Cancel all active async tasks (clears tracking set)
    /// Nonisolated to allow calling from deinit
    private nonisolated func cancelActiveAsyncTasks() {
        // We can only clear our tracking - actual task cancellation happens via other mechanisms
        // Safe to access nonisolated(unsafe) var directly since deinit runs once
        activeAsyncTaskIds.removeAll()
    }
    
    /// Debounced restart after an overlay is dismissed.
    private var overlayUncoverPlaybackTimer: Timer?

    /// Cached feed-visible videos (computed from visibleTweetIds + allVideos).
    /// Only includes videos that can actually appear in `MediaGridView` (first 4 attachments).
    /// Sorted by position (topmost cell first; then attachmentIndex within the same cell).
    private var _cachedVisibleVideos: [VideoPlaybackInfo] = []
    private var _visibleVideoCacheKey: String = ""

    /// PERF FIX: Cached visibleVideos to avoid expensive filtering/sorting on every access
    private var visibleVideos: [VideoPlaybackInfo] {
        let cacheKey = "\(visibleTweetIds.sorted().joined(separator: ","))_\(allVideos.count)"

        // Return cached result if inputs haven't changed
        if cacheKey == _visibleVideoCacheKey && !_cachedVisibleVideos.isEmpty {
            return _cachedVisibleVideos
        }

        let filtered = allVideos.filter { visibleTweetIds.contains($0.cellTweetId) && $0.isInVisibleMediaRange }

        // CRITICAL: Sort by position (Y coordinate) to ensure correct playback order
        // This ensures videos play in feed order, not array order
        guard let tableView = tableView, tableView.window != nil else {
            // No table view (or not in hierarchy): do NOT apply any position-based ordering.
            // Keep the coordinator's canonical order (the order `allVideos` was built in).
            _cachedVisibleVideos = filtered
            _visibleVideoCacheKey = cacheKey
            return filtered
        }

        // Build a fast map of visible cell tweetId -> minY.
        // If any visible video cannot be mapped to a visible cell, do NOT apply position-based sorting
        // (no stable-order fallback).
        var yByCellTweetId: [String: CGFloat] = [:]
        for cell in tableView.visibleCells {
            guard let tweetCell = cell as? TweetTableViewCell else { continue }
            guard let tweetId = tweetCell.tweetId else { continue }
            yByCellTweetId[tweetId] = cell.frame.minY
        }
        for video in filtered {
            if yByCellTweetId[video.cellTweetId] == nil {
                _cachedVisibleVideos = filtered
                _visibleVideoCacheKey = cacheKey
                return filtered
            }
        }

        let sorted = filtered.sorted { v1, v2 in
            let y1 = yByCellTweetId[v1.cellTweetId] ?? 0
            let y2 = yByCellTweetId[v2.cellTweetId] ?? 0
            if y1 != y2 { return y1 < y2 }
            // Same cell: order by attachment index.
            if v1.cellTweetId == v2.cellTweetId {
                return v1.attachmentIndex < v2.attachmentIndex
            }
            // If equal Y for different cells, keep existing order by returning false.
            return false
        }

        _cachedVisibleVideos = sorted
        _visibleVideoCacheKey = cacheKey
        return sorted
    }

    /// Invalidate visible videos cache when table view or video list changes
    private func invalidateVisibleVideoCache() {
        _visibleVideoCacheKey = ""
        _cachedVisibleVideos.removeAll()
    }

    /// Compute the user-visible rect using adjustedContentInset (accounts for nav bar, toolbar, tab bar).
    /// This is the single source of truth for visibility calculations across the coordinator.
    private func computeVisibleRect() -> CGRect? {
        guard let tableView = tableView, tableView.window != nil else { return nil }
        let insets = tableView.adjustedContentInset
        let top = tableView.contentOffset.y + insets.top
        let bottom = tableView.contentOffset.y + tableView.bounds.height - insets.bottom
        return CGRect(x: 0, y: top, width: tableView.bounds.width, height: max(0, bottom - top))
    }

    /// Synchronous cell visibility calculation.
    /// With pure UIKit cells, iterating visibleCells and computing CGRect intersection
    /// for ~5-8 cells is trivial (nanosecond-level) — no need for background dispatch.
    private func calculateCellVisibility() -> [String: CGFloat] {
        guard let tableView = tableView, tableView.window != nil,
              let visibleRect = computeVisibleRect() else { return [:] }

        var ratios: [String: CGFloat] = [:]
        for cell in tableView.visibleCells {
            guard let tweetCell = cell as? TweetTableViewCell,
                  let tweetId = tweetCell.tweetId else { continue }
            let intersection = cell.frame.intersection(visibleRect)
            ratios[tweetId] = cell.frame.height > 0 ? intersection.height / cell.frame.height : 0
        }
        return ratios
    }
    
    /// Stored observer tokens for proper cleanup
    private var notificationObservers: [NSObjectProtocol] = []
    
    /// Is currently scrolling
    private var isScrolling: Bool = false
    
    /// Scroll direction (true = scrolling down, false = scrolling up)
    private(set) var scrollDirection: Bool = true // Default to scrolling down
    
    /// Previous content offset to track scroll direction
    private var previousContentOffset: CGFloat = 0
    
    /// Table view reference for viewport calculations
    private weak var tableView: UITableView?
    
    // MARK: - Initialization
    
    private init() {
        // Listen for video finished notifications and store observer token
        let videoFinishedObserver = NotificationCenter.default.addObserver(
            forName: .videoDidFinishPlaying,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleVideoFinished(notification)
            }
        }
        notificationObservers.append(videoFinishedObserver)

        // Listen for foreground recovery and intelligently decide whether to preserve state
        let foregroundRecoveryObserver = NotificationCenter.default.addObserver(
            forName: .reloadVisibleVideosOnly,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleForegroundRecovery(notification)
            }
        }
        notificationObservers.append(foregroundRecoveryObserver)
        
        // Listen for overlay coverage changes (fullscreen cover / sheet / login / share).
        // While covered, we must stop and suppress playback decisions for the feed.
        let overlayCoverageObserver = NotificationCenter.default.addObserver(
            forName: .overlayCoverageChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleOverlayCoverageChanged(notification)
            }
        }
        notificationObservers.append(overlayCoverageObserver)
        
        // Listen for app background to set preservation flag
        let backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppDidEnterBackground()
            }
        }
        notificationObservers.append(backgroundObserver)
    }
    
    deinit {
        // Cancel all active async tasks
        cancelActiveAsyncTasks()

        // Clean up all notification observers
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()

        // Invalidate all timers
        playbackDebounceTimer?.invalidate()
        visibilityUpdateDebounceTimer?.invalidate()
        overlayUncoverPlaybackTimer?.invalidate()
    }
    
    @objc private func handleOverlayCoverageChanged(_ notification: Notification) {
        guard let isCovered = notification.userInfo?["isCovered"] as? Bool else { return }
                
        isPlaybackSuppressedByOverlay = isCovered
        
        // Cancel any pending "resume after overlay" timer.
        overlayUncoverPlaybackTimer?.invalidate()
        overlayUncoverPlaybackTimer = nil
        
        if isCovered {
            // Hard stop so no audio bleeds under the overlay, and so we don't preserve stale primary state.
            stopAllVideos()
            return
        }
        
        
        // Overlay dismissed: give UIKit/SwiftUI a beat to reattach layers, then restart if needed.
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                guard !self.isPlaybackSuppressedByOverlay,
                      self.phase == .idle,
                      !self.visibleVideos.isEmpty,
                      let tableView = self.tableView,
                      tableView.window != nil else {
                    return
                }
                self.startPrimaryVideoPlayback()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        overlayUncoverPlaybackTimer = timer
    }
    
    /// Handle app entering background - set flag to preserve state on foreground
    @objc private func handleAppDidEnterBackground() {
        // If we have active playback state, preserve it on foreground
        // This flag will be cleared if user explicitly scrolls
        if phase != .idle {
            shouldPreserveStateOnForeground = true
        }
    }
    
    // MARK: - Cache Management

    /// Clear stale visibility ratio cache to prevent unbounded growth
    private func clearStaleCache() {
        // Only keep ratios for currently visible videos
        if cachedVisibilityRatios.count > 50 {
            let visibleVideoIds = Set(visibleVideos.map { $0.identifier })
            cachedVisibilityRatios = cachedVisibilityRatios.filter { visibleVideoIds.contains($0.key) }
        }
    }

    // MARK: - Delegate Management (Phase 3)

    /// Register a MediaCell delegate for video control (keyed by video identifier)
    func registerDelegate(_ delegate: MediaCellDelegate, forIdentifier identifier: String) {
        mediaCellDelegates[identifier] = delegate
    }

    /// Unregister a MediaCell delegate (keyed by video identifier)
    func unregisterDelegate(forIdentifier identifier: String) {
        mediaCellDelegates.removeValue(forKey: identifier)
    }

    // MARK: - Public API
    
    /// Set table view reference for viewport calculations
    func setTableView(_ tableView: UITableView) {
        self.tableView = tableView
    }
    
    func addEmbeddedTweetVideos(quotingTweetId: String, embeddedTweet: Tweet) {
        var videosToAdd: [VideoPlaybackInfo] = []

        if let embeddedAttachments = embeddedTweet.attachments {
            for (attachmentIndex, attachment) in embeddedAttachments.enumerated() {
                if attachment.type == .video || attachment.type == .hls_video {
                    let videoInfo = VideoPlaybackInfo(
                        cellTweetId: quotingTweetId,          // visible cell in feed
                        mediaTweetId: embeddedTweet.mid,      // owns attachments
                        videoMid: attachment.mid,
                        attachmentIndex: attachmentIndex
                    )

                    videosToAdd.append(videoInfo)
                    // Allow duplicates like Android - videos appear as many times as they appear in feed
                }
            }
        }

        if !videosToAdd.isEmpty {
            // Rebuild the video list to ensure correct feed ordering
            // This is necessary because embedded videos may be loaded after initial list building
            Task {
                let newVideos = await self.buildVideoListAsync(tweets: self.currentTweets, pinnedTweets: [])
                await MainActor.run {
                    self.allVideos = newVideos
                }
            }

        }
    }

    /// Add videos for a pure retweet once the original tweet (media owner) is available.
    ///
    /// This keeps a single canonical list owned by the coordinator while still allowing fullscreen
    /// navigation to work for retweets whose attachments arrive later.
    func addRetweetVideos(retweetId: String, originalTweet: Tweet) {
        var videosToAdd: [VideoPlaybackInfo] = []

        if let attachments = originalTweet.attachments {
            for (attachmentIndex, attachment) in attachments.enumerated() {
                if attachment.type == .video || attachment.type == .hls_video {
                    let info = VideoPlaybackInfo(
                        cellTweetId: retweetId,
                        mediaTweetId: originalTweet.mid,
                        videoMid: attachment.mid,
                        attachmentIndex: attachmentIndex
                    )
                    videosToAdd.append(info)
                    // Allow duplicates like Android - videos appear as many times as they appear in feed
                }
            }
        }

        if !videosToAdd.isEmpty {
            // Rebuild the video list to ensure correct feed ordering
            Task {
                let newVideos = await self.buildVideoListAsync(tweets: self.currentTweets, pinnedTweets: [])
                await MainActor.run {
                    self.allVideos = newVideos
                }
            }
        }
    }

    /// Returns true if the canonical list contains the current fullscreen item.
    /// This is used to distinguish "no next video" from "not a feed-backed fullscreen context".
    func containsFullscreenItem(cellTweetId: String, currentAttachmentIndex: Int, currentVideoMid: String?) -> Bool {
        let mid = currentVideoMid
        return allVideos.contains { v in
            // Prefer matching by cellTweetId+attachmentIndex; if mid is available, also require it.
            if v.cellTweetId == cellTweetId && v.attachmentIndex == currentAttachmentIndex {
                return mid.map { v.videoMid == $0 } ?? true
            }
            // Fallback: some callers pass mediaTweetId as cellTweetId; accept that too.
            if v.mediaTweetId == cellTweetId && v.attachmentIndex == currentAttachmentIndex {
                return mid.map { v.videoMid == $0 } ?? true
            }
            // Last resort: if only mid is reliable, match by mid (+ attachmentIndex when provided).
            if let mid, v.videoMid == mid {
                return v.attachmentIndex == currentAttachmentIndex
            }
            return false
        }
    }

    /// Canonical "next video" lookup for fullscreen browsing.
    /// Returns the tweet that owns the attachments (mediaTweet) + the attachment index + the next cell tweet id.
    ///
    /// IMPORTANT: `cellTweetId` is the feed cell id (retweet id for retweets, quoting tweet id for quotes).
    /// We match by cellTweetId, but also try mediaTweetId and videoMid for resilience.
    func findNextVideoForFullscreen(cellTweetId: String, currentAttachmentIndex: Int, currentVideoMid: String?) -> (tweet: Tweet, videoIndex: Int, cellTweetId: String)? {
        // Use allVideos in its current order (approximately feed order)
        let feedOrderedVideos = allVideos

        // Find the current position in the list.
        let startIndex: Int?
        let mid = currentVideoMid

        // 1) Exact match on (cellTweetId, attachmentIndex, mid?)
        startIndex = feedOrderedVideos.firstIndex(where: { v in
            v.cellTweetId == cellTweetId &&
            v.attachmentIndex == currentAttachmentIndex &&
            (mid.map { v.videoMid == $0 } ?? true)
        })
        // 2) If caller passed mediaTweetId as cellTweetId, accept that.
        ?? feedOrderedVideos.firstIndex(where: { v in
            v.mediaTweetId == cellTweetId &&
            v.attachmentIndex == currentAttachmentIndex &&
            (mid.map { v.videoMid == $0 } ?? true)
        })
        // 3) Match by mid (more stable across retweet/original id mismatches).
        ?? (mid.flatMap { m in
            feedOrderedVideos.firstIndex(where: { $0.videoMid == m && $0.attachmentIndex == currentAttachmentIndex })
        })
        // 4) Fallback to first video within the cell/media tweet.
        ?? feedOrderedVideos.firstIndex(where: { $0.cellTweetId == cellTweetId })
        ?? feedOrderedVideos.firstIndex(where: { $0.mediaTweetId == cellTweetId })

        guard let startIndex else { return nil }

        // Scan forward for the next playable entry
        for nextIdx in (startIndex + 1)..<feedOrderedVideos.count {
            let candidate = feedOrderedVideos[nextIdx]

            // Resolve the tweet that owns attachments.
            let mediaTweet = currentTweets.first(where: { $0.mid == candidate.mediaTweetId })
                ?? TweetCacheManager.shared.fetchTweetSync(mid: candidate.mediaTweetId)
                ?? Tweet.getInstance(for: candidate.mediaTweetId)

            guard let mediaTweet,
                  let attachments = mediaTweet.attachments,
                  candidate.attachmentIndex >= 0,
                  candidate.attachmentIndex < attachments.count else {
                continue
            }

            // Ensure the attachment is still a video.
            let attachment = attachments[candidate.attachmentIndex]
            guard attachment.type == .video || attachment.type == .hls_video else { continue }

            return (tweet: mediaTweet, videoIndex: candidate.attachmentIndex, cellTweetId: candidate.cellTweetId)
        }

        return nil
    }

    /// Build video list from tweets (including pinned tweets)
    /// Now runs asynchronously to avoid blocking UI
    func buildVideoList(from tweets: [Tweet], pinnedTweets: [Tweet] = [], completion: (() -> Void)? = nil) {
        // Run expensive operation in background
        Task.detached(priority: .userInitiated) {
            let videos = await self.buildVideoListAsync(tweets: tweets, pinnedTweets: pinnedTweets)

            // Update state on main actor
            await MainActor.run {
                self.allVideos = videos

                // Clear caches when video list is rebuilt
                self.cachedVisibilityRatios.removeAll()
                self.invalidateVisibleVideoCache()
                self.clearPreloadedTracking()

                // Store tweet list for embedded tweet lookup
                self.currentTweets = pinnedTweets + tweets

                // Call completion handler BEFORE auto-playback check
                // This allows caller to update visibleTweetIds first
                completion?()

                // Trigger playback update after video list is rebuilt if in idle phase and videos are visible
                if self.phase == .idle && !self.visibleVideos.isEmpty && !self.isPlaybackSuppressedByOverlay {
                    self.startPrimaryVideoPlayback()
                }
            }
        }
    }
    
    /// Async implementation of video list building (runs on background thread)
    private func buildVideoListAsync(tweets: [Tweet], pinnedTweets: [Tweet]) async -> [VideoPlaybackInfo] {
        var videos: [VideoPlaybackInfo] = []


        // Store tweet list for embedded tweet lookup (temporarily, will be set on main actor)
        // let currentTweets = pinnedTweets + tweets

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
        
        // Process pinned tweets first (they appear at the top)
        // Allow both embedded and standalone instances of the same video to be tracked
        // Both should be able to autoplay when visible
        for (_, tweet) in pinnedTweets.enumerated() {
            guard let attachments = tweet.attachments else { continue }

            for (attachmentIndex, attachment) in attachments.enumerated() {
                if attachment.type == .video || attachment.type == .hls_video {
                    let videoInfo = VideoPlaybackInfo(
                        cellTweetId: tweet.mid,
                        mediaTweetId: tweet.mid,
                        videoMid: attachment.mid,
                        attachmentIndex: attachmentIndex
                    )

                        videos.append(videoInfo)
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

                        for (attachmentIndex, attachment) in originalAttachments.enumerated() {
                            if attachment.type == .video || attachment.type == .hls_video {
                                let videoInfo = VideoPlaybackInfo(
                                    cellTweetId: tweet.mid,
                                    mediaTweetId: originalTweet.mid,
                                    videoMid: attachment.mid,
                                    attachmentIndex: attachmentIndex
                                )

                                videos.append(videoInfo)
                                // Don't deduplicate - allow videos to appear multiple times like Android
                            }
                        }
                    }
                }
            } else {
                // REGULAR TWEET or QUOTED TWEET
                // Allow both embedded and standalone instances to be tracked
                // Both should be able to autoplay when visible
                if let attachments = tweet.attachments {
                    for (attachmentIndex, attachment) in attachments.enumerated() {
                        if attachment.type == .video || attachment.type == .hls_video {
                            let videoInfo = VideoPlaybackInfo(
                                cellTweetId: tweet.mid,
                                mediaTweetId: tweet.mid,
                                videoMid: attachment.mid,
                                attachmentIndex: attachmentIndex
                            )

                        videos.append(videoInfo)
                        }
                    }
                }
                
                if isQuotedTweet, let originalTweetId = tweet.originalTweetId {
                    let embeddedTweet = Tweet.getInstance(for: originalTweetId)

                    if let embeddedTweet = embeddedTweet,
                       let embeddedAttachments = embeddedTweet.attachments {
                        for (attachmentIndex, attachment) in embeddedAttachments.enumerated() {
                            if attachment.type == .video || attachment.type == .hls_video {
                                let videoInfo = VideoPlaybackInfo(
                                    cellTweetId: tweet.mid,           // visible cell in feed
                                    mediaTweetId: embeddedTweet.mid,  // owns attachments
                                    videoMid: attachment.mid,
                                    attachmentIndex: attachmentIndex
                                )

                                videos.append(videoInfo)
                                // Don't deduplicate - allow videos to appear multiple times like Android
                            }
                        }
                    }
                }
            }
        }
        
        // Return the built video list (async function)
        return videos
    }
    
    /// Previously visible video identifiers (cellTweetId_videoMid_attachmentIndex).
    /// Using full identifiers (not bare videoMids) ensures the same video in a tweet
    /// and its retweet are tracked independently.
    private var previousVisibleIdentifiers: Set<String> = []
    
    /// Update visible tweets (called during scrolling)
    func updateVisibleTweets(_ tweetIds: Set<String>) {
        OverlayVisibilityCoordinator.shared.verifyConsistency(source: "VideoPlaybackCoordinator.updateVisibleTweets")

        // Track scroll direction based on content offset
        if let tableView = tableView, tableView.window != nil {
            let currentOffset = tableView.contentOffset.y
            if previousContentOffset != 0 {
                let newDirection = currentOffset > previousContentOffset
                let directionChanged = newDirection != scrollDirection
                scrollDirection = newDirection

                if directionChanged || shouldTriggerScrollPreload() {
                    preloadVideosInScrollDirection()
                }
            }
            previousContentOffset = currentOffset
        }

        // Only consider feed-visible video entries (MediaGrid only shows first 4 attachments)
        let tweetsWithFeedVideos = Set(allVideos.filter { $0.isInVisibleMediaRange }.map { $0.cellTweetId })
        let filteredTweetIds = tweetIds.intersection(tweetsWithFeedVideos)

        self.visibleTweetIds = filteredTweetIds
        self.invalidateVisibleVideoCache()
        self.isScrolling = true

        // Track by full identifier (cellTweetId_videoMid_attachmentIndex) so the same
        // video appearing in both a tweet and its retweet is handled independently.
        let currentVisibleIdentifiers = Set(visibleVideos.map { $0.identifier })
        let visibilityChanged = previousVisibleIdentifiers != currentVisibleIdentifiers

        // Stop all videos if none are visible
        if currentVisibleIdentifiers.isEmpty {
            previousVisibleIdentifiers.removeAll()
            stopAllVideos()
            return
        }

        // If the feed is covered by an overlay, do not start playback
        if isPlaybackSuppressedByOverlay {
            previousVisibleIdentifiers = currentVisibleIdentifiers
            return
        }

        // Stop videos whose cell left the visible area
        if visibilityChanged {
            let identifiersToStop = previousVisibleIdentifiers.subtracting(currentVisibleIdentifiers)
            if !identifiersToStop.isEmpty {
                if identifiersToStop.count >= 3 || scrollDirection == false {
                    SharedAssetCache.shared.forceMemoryCleanup()
                }

                // Collect videoMids that still have at least one visible instance
                // (same video may appear in tweet + retweet — don't stop if another cell is showing it)
                let stillVisibleMids = Set(visibleVideos.map { $0.videoMid })

                for identifier in identifiersToStop {
                    cachedVisibilityRatios.removeValue(forKey: identifier)

                    guard let video = allVideos.first(where: { $0.identifier == identifier }) else { continue }

                    // Only stop the actual player if no other visible cell shows the same videoMid
                    if !stillVisibleMids.contains(video.videoMid) {
                        if SharedVideoPlayerManager.shared.currentVideoMid == video.videoMid {
                            SharedVideoPlayerManager.shared.stopCurrentVideo()
                        }
                    }
                }
            }
        }

        // Decide whether to start/switch playback — act immediately to avoid black screens.
        // State is set synchronously in startPrimaryVideoPlayback/checkAndSwitchVideoIfNeeded
        // (only the actual play command is delayed by 50ms), so rapid calls are safe.
        if visibilityChanged && !currentVisibleIdentifiers.isEmpty {
            if phase == .primaryPlaying,
               let primaryId = primaryVideoId,
               currentVisibleIdentifiers.contains(primaryId) {
                // Primary's cell still visible — check if we should switch based on position
                checkAndSwitchVideoIfNeeded()
                previousVisibleIdentifiers = currentVisibleIdentifiers
            } else {
                // Primary's cell gone or idle — reset and start new primary immediately
                phase = .idle
                currentlyPlayingVideoIds.removeAll()
                primaryVideoId = nil
                playbackDebounceTimer?.invalidate()
                playbackDebounceTimer = nil
                startPrimaryVideoPlayback()
                previousVisibleIdentifiers = currentVisibleIdentifiers
            }
        } else if phase == .idle && !currentVisibleIdentifiers.isEmpty {
            startPrimaryVideoPlayback()
            previousVisibleIdentifiers = currentVisibleIdentifiers
        } else {
            previousVisibleIdentifiers = currentVisibleIdentifiers
        }

        // Clear preserve flag when user explicitly scrolls
        shouldPreserveStateOnForeground = false
    }

    /// Schedule a single debounced visibility update (150ms).
    /// Replaces multiple overlapping timers with one consolidated timer.
    private func scheduleBatchedVisibilityUpdate() {
        visibilityUpdateDebounceTimer?.invalidate()
        visibilityUpdateDebounceTimer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.performBatchedVisibilityUpdate()
            }
        }
        RunLoop.main.add(visibilityUpdateDebounceTimer!, forMode: .common)
    }

    /// Batched visibility update — runs synchronously on main thread.
    /// With pure UIKit cells, all visibility calculations are cheap enough to run inline.
    private func performBatchedVisibilityUpdate() {
        guard !isPlaybackSuppressedByOverlay else { return }

        if phase == .idle && !visibleVideos.isEmpty {
            startPrimaryVideoPlayback()
        } else if phase == .primaryPlaying {
            checkAndSwitchVideoIfNeeded()
        }
    }

    /// Stop all videos and reset state
    func stopAllVideos() {
        // Cancel all timers
        playbackDebounceTimer?.invalidate()
        playbackDebounceTimer = nil
        visibilityUpdateDebounceTimer?.invalidate()
        visibilityUpdateDebounceTimer = nil
        overlayUncoverPlaybackTimer?.invalidate()
        overlayUncoverPlaybackTimer = nil

        cachedVisibilityRatios.removeAll()

        // Cancel all active async tasks
        cancelActiveAsyncTasks()

        // Clear state
        currentlyPlayingVideoIds.removeAll()
        primaryVideoId = nil
        phase = .idle
        // Clear previous visible identifiers so next updateVisibleTweets sees a change
        previousVisibleIdentifiers.removeAll()

        // PHASE 2: Use SharedVideoPlayerManager to stop all videos
        SharedVideoPlayerManager.shared.stopCurrentVideo()
    }

    // MARK: - Background/Foreground Video Memory Management

    /// Release all video players when entering background to free memory
    /// Called by TweetTableViewController when app enters background
    func releaseAllPlayersForBackground() {
        print("🌙 [VIDEO MEMORY] Releasing all video players for background")

        // Stop all videos first
        stopAllVideos()

        // Release all players via SharedAssetCache
        SharedAssetCache.shared.releaseAllPlayers()

        // Clear video state cache to free memory (playback positions are preserved in PersistentVideoStateManager)
        VideoStateCache.shared.clearAllCache()

        print("✅ [VIDEO MEMORY] All video players released for background")
    }

    /// Validate cached players after returning from background
    /// Health checks will automatically detect and remove broken players
    @MainActor func validatePlayersAfterBackground() {
        print("🔍 [VIDEO MEMORY] Validating cached players after background")

        // Validate all cached players and remove unhealthy ones
        let removedCount = SharedAssetCache.shared.validateAndCleanupPlayers()

        if removedCount > 0 {
            print("✅ [VIDEO MEMORY] Removed \(removedCount) broken players - fresh players will be created as needed")
        } else {
            print("✅ [VIDEO MEMORY] All cached players are healthy")
        }
    }

    /// Get videos to preload based on visible tweets and scroll direction
    private func getVideosToPreload(visibleTweetIds: Set<String>, preloadCount: Int) -> [VideoPlaybackInfo] {
        // Find visible videos first
        let visibleVideoSet = Set(visibleTweetIds)
        let visibleVideoInfos = allVideos.filter { visibleVideoSet.contains($0.cellTweetId) && $0.isInVisibleMediaRange }

        guard !visibleVideoInfos.isEmpty else { return [] }

        // Find the indices of visible videos in allVideos
        let visibleIndices = visibleVideoInfos.compactMap { video in
            allVideos.firstIndex(where: { $0.identifier == video.identifier })
        }.sorted()

        guard !visibleIndices.isEmpty else { return [] }

        var videosToPreload: [VideoPlaybackInfo] = []

        // Add visible videos first
        videosToPreload.append(contentsOf: visibleVideoInfos)

        // Based on scroll direction, preload additional videos
        if scrollDirection {
            // Scrolling DOWN: preload videos AFTER the visible ones
            let lastVisibleIndex = visibleIndices.max() ?? 0
            for i in 1...preloadCount {
                let nextIndex = lastVisibleIndex + i
                if nextIndex < allVideos.count {
                    let video = allVideos[nextIndex]
                    if video.isInVisibleMediaRange && !videosToPreload.contains(where: { $0.identifier == video.identifier }) {
                        videosToPreload.append(video)
                    }
                }
            }
        } else {
            // Scrolling UP: preload videos BEFORE the visible ones
            let firstVisibleIndex = visibleIndices.min() ?? 0
            for i in 1...preloadCount {
                let prevIndex = firstVisibleIndex - i
                if prevIndex >= 0 {
                    let video = allVideos[prevIndex]
                    if video.isInVisibleMediaRange && !videosToPreload.contains(where: { $0.identifier == video.identifier }) {
                        videosToPreload.append(video)
                    }
                }
            }
        }

        return videosToPreload
    }

    /// Preload video asset without starting playback
    private func preloadVideoAsset(_ video: VideoPlaybackInfo) {
        // Get the tweet to find the attachment URL
        guard let tweet = currentTweets.first(where: { $0.mid == video.mediaTweetId }) ?? Tweet.getInstance(for: video.mediaTweetId),
              let attachments = tweet.attachments,
              video.attachmentIndex < attachments.count else {
            print("⚠️ [PRELOAD] Could not find tweet or attachment for video: \(video.videoMid.prefix(8))")
            return
        }

        let attachment = attachments[video.attachmentIndex]
        guard attachment.type == .video || attachment.type == .hls_video else { return }

        // Get the URL for the video
        // For HLS videos, use the cached url property
        // For regular videos, construct URL from author's baseUrl
        var videoURL: URL?

        if let urlString = attachment.url, let url = URL(string: urlString) {
            videoURL = url
        } else if let author = tweet.author, let baseUrl = author.baseUrl {
            videoURL = attachment.getUrl(baseUrl)
        }

        guard let url = videoURL else {
            print("⚠️ [PRELOAD] Could not construct URL for video: \(video.videoMid.prefix(8))")
            return
        }

        // Request preload via SharedAssetCache (it handles caching and player creation)
        print("⏳ [PRELOAD] Preloading video asset: \(video.videoMid.prefix(8))...")
        SharedAssetCache.shared.preloadAsset(for: url, tweetId: tweet.mid)

        // Track that this video has been preloaded
        preloadedVideoMids.insert(video.videoMid)
    }

    // MARK: - Scroll Preloading

    /// Check if we should trigger preloading during scroll (throttled)
    private func shouldTriggerScrollPreload() -> Bool {
        guard let lastPreload = lastScrollPreloadTime else {
            return true // First preload
        }
        return Date().timeIntervalSince(lastPreload) >= scrollPreloadThrottleInterval
    }

    /// Preload videos ahead in the scroll direction during scrolling
    private func preloadVideosInScrollDirection() {
        // Update throttle timestamp
        lastScrollPreloadTime = Date()

        // Find the next 2 videos in scroll direction that haven't been preloaded
        let videosToPreload = getNextVideosInScrollDirection(count: 4)

        guard !videosToPreload.isEmpty else { return }

        print("🔮 [SCROLL PRELOAD] Preloading \(videosToPreload.count) videos ahead (\(scrollDirection ? "down" : "up"))")

        for video in videosToPreload {
            // Skip if already preloaded
            guard !preloadedVideoMids.contains(video.videoMid) else { continue }
            preloadVideoAsset(video)
        }
    }

    /// Get the next videos in scroll direction that are not currently visible
    private func getNextVideosInScrollDirection(count: Int) -> [VideoPlaybackInfo] {
        // Get indices of currently visible videos
        let visibleVideoSet = visibleTweetIds
        let visibleIndices = allVideos.enumerated()
            .filter { visibleVideoSet.contains($0.element.cellTweetId) && $0.element.isInVisibleMediaRange }
            .map { $0.offset }
            .sorted()

        guard !visibleIndices.isEmpty else { return [] }

        var result: [VideoPlaybackInfo] = []

        if scrollDirection {
            // Scrolling DOWN: get videos AFTER the last visible one
            let lastVisibleIndex = visibleIndices.max() ?? 0
            for i in 1...count {
                let nextIndex = lastVisibleIndex + i
                if nextIndex < allVideos.count {
                    let video = allVideos[nextIndex]
                    if video.isInVisibleMediaRange && !preloadedVideoMids.contains(video.videoMid) {
                        result.append(video)
                    }
                }
            }
        } else {
            // Scrolling UP: get videos BEFORE the first visible one
            let firstVisibleIndex = visibleIndices.min() ?? 0
            for i in 1...count {
                let prevIndex = firstVisibleIndex - i
                if prevIndex >= 0 {
                    let video = allVideos[prevIndex]
                    if video.isInVisibleMediaRange && !preloadedVideoMids.contains(video.videoMid) {
                        result.append(video)
                    }
                }
            }
        }

        return result
    }

    /// Preload videos for nearby (but not yet visible) tweets.
    /// Called by the table view controller with spatially adjacent tweet IDs
    /// that are just outside the visible area, providing better preloading than
    /// index-based adjacency in the allVideos array.
    func updateNearbyTweetsForPreloading(_ nearbyTweetIds: Set<String>) {
        let videosToPreload = allVideos.filter {
            nearbyTweetIds.contains($0.cellTweetId)
                && $0.isInVisibleMediaRange
                && !preloadedVideoMids.contains($0.videoMid)
        }
        for video in videosToPreload {
            preloadVideoAsset(video)
        }
    }

    /// Clear preloaded video tracking (called when video list is rebuilt)
    private func clearPreloadedTracking() {
        preloadedVideoMids.removeAll()
        lastScrollPreloadTime = nil
    }

    // MARK: - Private Methods

    /// Called when scrolling stops
    private func onScrollStopped() {
        isScrolling = false
    }
    
    /// Start primary video playback — play topmost video immediately.
    /// Fully synchronous: visibility calculations use direct UITableView access.
    /// State (phase, primaryVideoId) is set **immediately** to prevent duplicate calls;
    /// only the actual play command is delayed by 50ms to let stop/pause propagate.
    private func startPrimaryVideoPlayback() {
        guard !isPlaybackSuppressedByOverlay else { return }
        guard phase == .idle else { return }

        guard let primary = identifyPrimaryVideo() else {
            stopAllVideos()
            return
        }

        // Stop the previous primary video if different
        if let previousPrimaryId = primaryVideoId, previousPrimaryId != primary.identifier,
           let previousPrimary = allVideos.first(where: { $0.identifier == previousPrimaryId }) {
            if SharedVideoPlayerManager.shared.currentVideoMid == previousPrimary.videoMid {
                SharedVideoPlayerManager.shared.stopCurrentVideo()
            }
        }

        // Pause all visible videos except the new primary
        for video in visibleVideos where video != primary {
            pauseVideo(video)
        }

        // Set state immediately to prevent duplicate calls from rapid scroll updates
        phase = .primaryPlaying
        primaryVideoId = primary.identifier
        currentlyPlayingVideoIds = [primary.identifier]
        cachedVisibilityRatios[primary.identifier] = 0.7
        lastPrimarySwitchTime = Date()

        // Small delay to ensure pause/stop commands are processed before starting new video
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            SharedVideoPlayerManager.shared.playVideo(
                videoId: primary.identifier,
                videoMid: primary.videoMid,
                cellTweetId: primary.cellTweetId
            )
        }
    }

    /// Identify the primary video based on scroll direction.
    /// Scrolling down: topmost video (lowest Y) that is ≥50% visible.
    /// Scrolling up: bottommost video (highest Y) that is ≥50% visible.
    private func identifyPrimaryVideo() -> VideoPlaybackInfo? {
        guard tableView?.window != nil else {
            return visibleVideos.first
        }

        let ratios = calculateCellVisibility()
        let candidates = scrollDirection ? visibleVideos : visibleVideos.reversed()

        for video in candidates {
            if (ratios[video.cellTweetId] ?? 0) >= 0.5 {
                return video
            }
        }
        return scrollDirection ? visibleVideos.first : visibleVideos.last
    }

    /// Check if current primary video is less than 30% visible and switch to next video if needed.
    /// Fully synchronous — uses computeVisibleRect() for consistent inset calculation.
    private func checkAndSwitchVideoIfNeeded() {
        clearStaleCache()

        guard phase == .primaryPlaying,
              let primaryId = primaryVideoId,
              let tableView = tableView,
              tableView.window != nil else { return }

        // Prevent immediate re-switching (0.2s cooldown)
        if let lastSwitchTime = lastPrimarySwitchTime,
           Date().timeIntervalSince(lastSwitchTime) < 0.2 { return }

        guard let currentPrimary = visibleVideos.first(where: { $0.identifier == primaryId }) else { return }

        // Calculate visibility using unified visibleRect
        guard let visibleRect = computeVisibleRect(),
              let cell = findCell(forCellTweetId: currentPrimary.cellTweetId, in: tableView) else { return }

        let intersection = cell.frame.intersection(visibleRect)
        let visibilityRatio = cell.frame.height > 0 ? intersection.height / cell.frame.height : 0

        let previousRatio = cachedVisibilityRatios[primaryId] ?? 0.7
        let ratioChange = abs(visibilityRatio - previousRatio)
        cachedVisibilityRatios[primaryId] = visibilityRatio

        // Only act if ratio changed significantly or crossed the 30% hysteresis threshold
        let crossedThreshold = (previousRatio > 0.30 && visibilityRatio <= 0.30) || (previousRatio <= 0.30 && visibilityRatio > 0.30)
        guard crossedThreshold || ratioChange >= visibilityRatioThreshold else { return }

        // Switch away if primary drops below 30%
        if visibilityRatio < 0.30 {
            guard let newPrimary = identifyPrimaryVideo() else {
                stopAllVideos()
                return
            }

            if newPrimary.identifier == primaryId {
                stopAllVideos()
                return
            }

            // Stop current primary
            if SharedVideoPlayerManager.shared.currentVideoMid == currentPrimary.videoMid {
                SharedVideoPlayerManager.shared.stopCurrentVideo()
            }

            // Pause all other visible videos
            for video in visibleVideos where video.identifier != newPrimary.identifier {
                if let delegate = mediaCellDelegates[video.identifier] {
                    delegate.shouldPauseVideo(withMid: video.videoMid)
                }
            }

            // Set state immediately to prevent duplicate calls
            primaryVideoId = newPrimary.identifier
            currentlyPlayingVideoIds = [newPrimary.identifier]
            cachedVisibilityRatios[newPrimary.identifier] = 0.7
            lastPrimarySwitchTime = Date()

            // Small delay to let stop/pause propagate before starting new video
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                SharedVideoPlayerManager.shared.playVideo(
                    videoId: newPrimary.identifier,
                    videoMid: newPrimary.videoMid,
                    cellTweetId: newPrimary.cellTweetId
                )
            }
        }
    }

    /// Find table view cell for a given feed cell tweet ID.
    private func findCell(forCellTweetId tweetId: String, in tableView: UITableView) -> UITableViewCell? {
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
        
        // PHASE 2: Use SharedVideoPlayerManager for coordinated pause
        // Only pause if this is the currently playing video
        if SharedVideoPlayerManager.shared.currentVideoMid == video.videoMid {
            SharedVideoPlayerManager.shared.pauseCurrentVideo()
        } else {
            // For non-current videos, send direct delegate call
            if let delegate = mediaCellDelegates[video.identifier] {
                delegate.shouldPauseVideo(withMid: video.videoMid)
            }
        }
    }

    /// Returns true if the table cell hosting this video is actually visible enough.
    ///
    /// `UITableView.indexPathsForVisibleRows` can include rows that are only a few pixels on-screen.
    /// If we auto-advance into those, the next video will "play" but appear invisible to the user.
    private func isVideoCellVisibleEnough(_ video: VideoPlaybackInfo, minVisibilityRatio: CGFloat = 0.5) -> Bool {
        guard let tableView = tableView, tableView.window != nil,
              let visibleRect = computeVisibleRect(),
              let cell = findCell(forCellTweetId: video.cellTweetId, in: tableView) else { return false }

        let intersection = cell.frame.intersection(visibleRect)
        let ratio = cell.frame.height > 0 ? intersection.height / cell.frame.height : 0
        return ratio >= minVisibilityRatio
    }
    
    /// Play next visible video after primary finishes
    private func playNextVisibleVideo() {
        guard let currentPrimary = primaryVideoId else {
            print("⚠️ [VIDEO ADVANCE] Cannot advance - no current primary video")
            return
        }

        // CRITICAL: visibleVideos is sorted by position, so advancing by index is correct
        // But we need to ensure we're advancing to the next video in feed order (by Y position)
        // Find current primary in visible videos list (sorted by position)
        guard let currentIndex = visibleVideos.firstIndex(where: { $0.identifier == currentPrimary }) else {
            print("⚠️ [VIDEO ADVANCE] Current primary not in visible videos - stopping all")
            stopAllVideos()
            return
        }

        print("📹 [VIDEO ADVANCE] Current video finished at index \(currentIndex)/\(visibleVideos.count), scrolling \(scrollDirection ? "down" : "up")")

        // Find next video based on scroll direction
        // Scrolling down: next video (index + 1)
        // Scrolling up: previous video (index - 1)
        let targetIndex: Int
        if scrollDirection {
            // Scrolling DOWN: advance to next video
            targetIndex = currentIndex + 1
            guard targetIndex < visibleVideos.count else {
                print("⚠️ [VIDEO ADVANCE] No next video (reached end of list) - stopping all")
                stopAllVideos()
                return
            }
        } else {
            // Scrolling UP: go back to previous video
            targetIndex = currentIndex - 1
            guard targetIndex >= 0 else {
                print("⚠️ [VIDEO ADVANCE] No previous video (at start of list) - stopping all")
                stopAllVideos()
                return
            }
        }

        // IMPORTANT: `indexPathsForVisibleRows` can include rows that are barely visible.
        // When the current video finishes, we should only advance to a video whose cell is
        // sufficiently visible, otherwise it will "autoplay" while appearing invisible.
        // Use 25% threshold for sequential playback (lower than 50% for initial selection)
        // to allow advancing to videos that are partially visible at screen edges
        let step = scrollDirection ? 1 : -1
        var candidateIndex = targetIndex
        var nextVideo: VideoPlaybackInfo?
        print("🔍 [VIDEO ADVANCE] Searching for next visible video starting at index \(targetIndex)")
        while candidateIndex >= 0 && candidateIndex < visibleVideos.count {
            let candidate = visibleVideos[candidateIndex]
            let isVisible = isVideoCellVisibleEnough(candidate, minVisibilityRatio: 0.33)
            print("🔍 [VIDEO ADVANCE] Checking candidate at index \(candidateIndex): \(candidate.videoMid.prefix(10))... - visible enough: \(isVisible)")
            if isVisible {
                nextVideo = candidate
                break
            }
            candidateIndex += step
        }

        guard let nextVideo else {
            print("⚠️ [VIDEO ADVANCE] No sufficiently visible next video found - stopping all")
            stopAllVideos()
            return
        }
        print("✅ [VIDEO ADVANCE] Found next video: \(nextVideo.videoMid.prefix(10))... at index \(candidateIndex)")
        let currentVideo = visibleVideos[currentIndex]
        

        // CRITICAL: Clear coordinatorWantsToPlay flag for finished video
        if let delegate = mediaCellDelegates[currentVideo.identifier] {
            delegate.shouldPauseVideo(withMid: currentVideo.videoMid)
        }

        // Set new primary and start playing
        primaryVideoId = nextVideo.identifier
        currentlyPlayingVideoIds = [nextVideo.identifier]

        // PHASE 2: Use SharedVideoPlayerManager for coordinated playback
        SharedVideoPlayerManager.shared.playVideo(
            videoId: nextVideo.identifier,
            videoMid: nextVideo.videoMid,
            cellTweetId: nextVideo.cellTweetId
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
                // Resume primary video - prefer identifier match (stable across rebuilds).
                if let primary = visibleVideos.first(where: { $0.identifier == primaryId })
                    ?? visibleVideos.first(where: { primaryId.contains($0.videoMid) }) {
                    
                    // CRITICAL: If primary is not the first visible video, restart from first
                    // This ensures playback always starts from top when multiple videos are visible
                    let primaryIndex = visibleVideos.firstIndex(where: { $0.identifier == primary.identifier }) ?? 0
                    
                    if primaryIndex > 0 && visibleVideos.count > 1 {
                        // Primary is not first - restart from first video
                        
                        // CRITICAL: Clear stale coordinatorWantsToPlay flags from other videos
                        // Send pause commands to all videos except the first one
                        // PHASE 2: Pause non-primary videos directly (not managed by SharedVideoPlayerManager)
                        for (index, video) in visibleVideos.enumerated() where index > 0 {
                            if let delegate = mediaCellDelegates[video.identifier] {
                                delegate.shouldPauseVideo(withMid: video.videoMid)
                            }
                        }
                        
                        let firstVideo = visibleVideos[0]
                        primaryVideoId = firstVideo.identifier
                        currentlyPlayingVideoIds = [firstVideo.identifier]
                        
                        // PHASE 2: Use SharedVideoPlayerManager for coordinated playback
                        SharedVideoPlayerManager.shared.playVideo(
                            videoId: firstVideo.identifier,
                            videoMid: firstVideo.videoMid,
                            cellTweetId: firstVideo.cellTweetId
                        )
                    } else {
                        // Primary is first or only video - resume it
                        primaryVideoId = primary.identifier
                        currentlyPlayingVideoIds = [primary.identifier]

                        // PHASE 2: Use SharedVideoPlayerManager for coordinated playback
                        SharedVideoPlayerManager.shared.playVideo(
                            videoId: primary.identifier,
                            videoMid: primary.videoMid,
                            cellTweetId: primary.cellTweetId
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
            playbackDebounceTimer?.invalidate()
            playbackDebounceTimer = nil
            visibilityUpdateDebounceTimer?.invalidate()
            visibilityUpdateDebounceTimer = nil

            cachedVisibilityRatios.removeAll()
            
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
