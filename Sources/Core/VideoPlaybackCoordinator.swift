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
    static let videoCreationSlotsAvailable = Notification.Name("videoCreationSlotsAvailable")
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

    /// Whether the video is actually playing (healthy player with rate > 0)
    var isActuallyPlaying: Bool { get }

    /// True when the coordinator has commanded this video to play but the AVPlayerItem is still
    /// in .unknown status (item loading from network). Prevents false stall detection during
    /// legitimate loading delays (IPFS/HLS can take >3s before play() is called).
    var isLoadingForCoordinator: Bool { get }

    /// True when the player was confirmed playing within the last 5 seconds.
    /// Prevents false stall detection during HLS buffer gaps: the player briefly enters
    /// .paused when the buffer empties while IPFS segments are still downloading.
    var isRecentlyPlaying: Bool { get }
}

/// Video state during orchestration
private enum VideoPlaybackPhase {
    case idle                    // No playback
    case primaryPlaying          // Primary video is playing to completion
}

/// Canonical video tracking info.
/// A video is indexed by both the tweet (cell) id and its own id so the same video in different cells is distinct.
///
/// - `cellTweetId`: The tweet ID of the *feed cell* (retweet ID for retweets, quoting tweet ID for embedded/quoted media).
/// - `mediaTweetId`: The tweet ID that actually owns the attachments (original tweet for retweets, embedded tweet for quoted media).
/// - `videoMid`: The attachment/media id (same video content can appear in multiple cells).
/// - `attachmentIndex`: The index in `mediaTweetId.attachments` (can be > 3; fullscreen needs this).
///
/// `identifier` = cellTweetId + "_" + videoMid + "_" + attachmentIndex is the unique key for playback (one delegate per cell instance).
/// Feed playback coordination only considers `attachmentIndex < 4` because `MediaGridView` only renders the first 4 items.
struct VideoPlaybackInfo: Equatable {
    let cellTweetId: String
    let mediaTweetId: String
    let videoMid: String
    let attachmentIndex: Int

    /// Unique key for this video instance: tweet id + video id + index (same video in different cells has different identifiers).
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

    /// Truncate an identifier (tweetId_mediaId) to 20 chars for log readability.
    private func shortIdent(_ id: String) -> String { id.count > 20 ? String(id.prefix(20)) + "…" : id }
    /// Truncate a videoMid to 8 chars for log readability.
    private func shortMID(_ id: String) -> String { id.count > 8 ? String(id.prefix(8)) : id }

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

    /// Temporarily set during notifyPrimaryVideoFailed() to prevent re-picking the same video
    private var failedPrimaryIdentifier: String?

    /// Video that finished playing (including mismatch timeout) — skip in identifyPrimaryVideo
    /// until cleared by next scroll update or stopAllVideos
    private var finishedPrimaryIdentifier: String?
    
    /// Timer for debouncing video playback (0.2s delay)
    private var playbackDebounceTimer: Timer?
    /// The video identifier that the pending debounce timer was started for.
    /// If the top candidate changes, the timer resets; if it stays the same, the timer keeps running.
    private var pendingPrimaryCandidate: String?

    /// Timestamp when primary video was last switched (to prevent immediate re-switching)
    private var lastPrimarySwitchTime: Date?


    /// Visible tweet IDs (updated by scroll tracking)
    private var visibleTweetIds: Set<String> = []

    /// Video identifiers whose media cells are currently on-screen within the viewport.
    /// More granular than visibleTweetIds — tracks individual cells within multi-video tweets.
    private var onScreenMediaCells: Set<String> = []

    /// All videos in the app (ordered by feed, then attachmentIndex).
    private var allVideos: [VideoPlaybackInfo] = []

    /// Store current tweet list for embedded tweet lookup
    private var currentTweets: [Tweet] = []

    /// Cached visibility ratios for hysteresis (only tracks primary video)
    private var cachedVisibilityRatios: [String: CGFloat] = [:]
    private let visibilityRatioThreshold: CGFloat = 0.10

    /// Actively tracked preload/nearby video mids — explicitly managed on scroll stop.
    /// Preload = next 2 videos in scroll direction (full player preload).
    /// Nearby = videos in adjacent tweets (asset-only preload).
    private var activePreloadMids: Set<String> = []
    private var activeNearbyMids: Set<String> = []

    /// 2s timer: when scroll starts, gives in-flight preloads a grace period to finish.
    /// If scroll is still active after 2s, cancel all preload/nearby downloads.
    private var scrollCancelTimer: Timer?

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

    /// Whether this coordinator's feed is currently user-visible.
    /// Managed by TweetTableViewController: true in viewWillAppear, false in viewWillDisappear.
    /// Prevents inactive feeds from resuming playback after overlay dismiss.
    var isFeedVisible: Bool = false

    /// True while the overlay dismiss timer is pending. Other resume paths
    /// (viewWillAppear, updateOnScreenMediaCells) should defer during this period.
    var isOverlayDismissPending: Bool {
        overlayUncoverPlaybackTimer != nil
    }

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

    /// Visible videos for playback: derived from video (media cell) visibility only, not tweet cell.
    /// When onScreenMediaCells is set, only videos in that set are considered visible; sorted by position.
    /// PERF FIX: Cached to avoid expensive filtering/sorting on every access.
    private var visibleVideos: [VideoPlaybackInfo] {
        // Video visibility depends on video (media cell) alone — use onScreenMediaCells as source of truth
        let cacheKey = "\(onScreenMediaCells.sorted().joined(separator: ","))_\(allVideos.count)"

        if cacheKey == _visibleVideoCacheKey && !_cachedVisibleVideos.isEmpty {
            return _cachedVisibleVideos
        }

        // allVideos is built in feed display order (top to bottom), so filtering
        // preserves the correct Y-position ordering without accessing tableView.visibleCells
        // (which is not allowed during table view updates like reloadData/performBatchUpdates).
        let filtered = allVideos.filter { onScreenMediaCells.contains($0.identifier) && $0.isInVisibleMediaRange }

        _cachedVisibleVideos = filtered
        _visibleVideoCacheKey = cacheKey
        return filtered
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

    /// Stored observer tokens for proper cleanup
    private var notificationObservers: [NSObjectProtocol] = []
    
    /// Is currently scrolling
    private var isScrolling: Bool = false
    
    /// Scroll direction (true = scrolling down, false = scrolling up)
    private(set) var scrollDirection: Bool = true // Default to scrolling down
    
    /// Previous content offset to track scroll direction
    private var previousContentOffset: CGFloat = 0

    /// Whether the initial (non-scroll) preload has been triggered after first visibility update
    private var initialPreloadDone: Bool = false
    
    /// Table view reference for viewport calculations
    private weak var tableView: UITableView?
    
    // MARK: - Initialization
    
    init() {
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
        
        
        // Overlay dismissed: wait for layout to settle before restarting.
        // 0.35s lets view transitions and cell layout complete. While this timer
        // is pending (overlayUncoverPlaybackTimer != nil), other resume paths
        // (viewWillAppear, updateOnScreenMediaCells) defer to avoid double-evaluation.
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.overlayUncoverPlaybackTimer = nil  // Settling period is over

                guard !self.isPlaybackSuppressedByOverlay,
                      self.isFeedVisible,
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

        // Do NOT insert into onScreenMediaCells here. didMoveToWindow fires for cells that
        // UITableView prefetches below the viewport — they are in the window but NOT visible.
        // Only updateOnScreenMediaCells (which does geometric 50% visibility checks) should
        // manage onScreenMediaCells. Otherwise off-screen cells get selected as primary.
        //
        // At app start, cells register AFTER the initial updateVisibleTweetsForVideoPlayback().
        // Use scheduleStartPrimary (0.3s debounce) to give updateOnScreenMediaCells time to
        // populate the correct visible set before we attempt primary selection.
        if phase == .idle {
            print("🎬 [COORD] registerDelegate: \(shortIdent(identifier)) registered (phase=idle, kicking playback)")
            scheduleStartPrimary()
        }
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
            // This is necessary because embedded videos may be loaded after initial list building.
            // Do NOT call performPreloadOnScrollStop here — video list rebuilds triggered by
            // pagination would create preloads for newly-loaded tweets the user hasn't scrolled to.
            Task {
                let newVideos = await self.buildVideoListAsync(tweets: self.currentTweets, pinnedTweets: [])
                await MainActor.run {
                    self.allVideos = newVideos
                    self.invalidateVisibleVideoCache()
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
            // Rebuild the video list to ensure correct feed ordering.
            // Do NOT call performPreloadOnScrollStop — same reason as addEmbeddedTweetVideos.
            Task {
                let newVideos = await self.buildVideoListAsync(tweets: self.currentTweets, pinnedTweets: [])
                await MainActor.run {
                    self.allVideos = newVideos
                    self.invalidateVisibleVideoCache()
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

    /// Returns a snapshot of the ordered video list for fullscreen browsing.
    func getVideoListForFullscreen() -> [VideoPlaybackInfo] {
        return allVideos
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
                self.initialPreloadDone = false

                // Store tweet list for embedded tweet lookup
                self.currentTweets = pinnedTweets + tweets

                // Call completion handler BEFORE auto-playback check
                // This allows caller to update visibleTweetIds first
                completion?()

                // Trigger playback update after video list is rebuilt if in idle phase and videos are visible
                if self.phase == .idle && !self.visibleVideos.isEmpty && !self.isPlaybackSuppressedByOverlay {
                    self.startPrimaryVideoPlayback()
                }

                // NOTE: Preloading is NOT triggered here because visibleTweetIds
                // hasn't been set yet. performPreloadOnScrollStop() is called from
                // updateVisibleTweets() on the first visibility update (initialPreloadDone).
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
    
    /// Update which specific media cells are on-screen within the viewport.
    /// Called by TweetTableViewController alongside updateVisibleTweets, with per-cell granularity.
    /// Triggers primary video switch if the current primary went off-screen.
    func updateOnScreenMediaCells(_ identifiers: Set<String>) {
        guard onScreenMediaCells != identifiers else { return }
        onScreenMediaCells = identifiers
        invalidateVisibleVideoCache()

        // If primary video went off-screen at the media-cell level, force switch
        if phase == .primaryPlaying,
           let primaryId = primaryVideoId,
           !identifiers.contains(primaryId) {
            // During overlay dismiss settling, layout transients can temporarily
            // report the primary as off-screen. Don't switch — let the overlay
            // timer handle it with stable layout.
            if overlayUncoverPlaybackTimer != nil { return }

            if identifiers.isEmpty {
                // All media cells left the screen — stop the primary so audio doesn't leak.
                if let primary = allVideos.first(where: { $0.identifier == primaryId }) {
                    if let delegate = mediaCellDelegates[primary.identifier] {
                        delegate.shouldStopVideo(withMid: primary.videoMid)
                    } else {
                        SharedAssetCache.shared.getCachedPlayer(for: primary.videoMid)?.pause()
                    }
                }
                print("🎬 [COORD] onScreenUpdate: 0 cells on-screen, going idle")
                phase = .idle
                currentlyPlayingVideoIds.removeAll()
                primaryVideoId = nil
                scheduleStartPrimary()
                return
            }

            print("🎬 [COORD] onScreenUpdate: primary \(shortIdent(primaryId)) left screen (\(identifiers.count) cells on-screen), switching")

            // Stop current primary (immediate pause, no fade)
            if let primary = allVideos.first(where: { $0.identifier == primaryId }) {
                if let delegate = mediaCellDelegates[primary.identifier] {
                    delegate.shouldStopVideo(withMid: primary.videoMid)
                } else {
                    // Cell may have been reused — delegate unregistered; stop cached player so it doesn't keep playing
                    SharedAssetCache.shared.getCachedPlayer(for: primary.videoMid)?.pause()
                }
            }
            // Reset and schedule new primary after debounce (avoids rapid switching during fast scroll)
            phase = .idle
            currentlyPlayingVideoIds.removeAll()
            primaryVideoId = nil
            scheduleStartPrimary()
        }
    }

    /// Update visible tweets (called during scrolling)
    func updateVisibleTweets(_ tweetIds: Set<String>) {
        OverlayVisibilityCoordinator.shared.verifyConsistency(source: "VideoPlaybackCoordinator.updateVisibleTweets")

        // Track scroll direction based on content offset (no preloading during scroll)
        if let tableView = tableView, tableView.window != nil {
            let currentOffset = tableView.contentOffset.y
            if previousContentOffset != 0 {
                scrollDirection = currentOffset > previousContentOffset
            }
            previousContentOffset = currentOffset
        }

        // Only consider feed-visible video entries (MediaGrid only shows first 4 attachments)
        let tweetsWithFeedVideos = Set(allVideos.filter { $0.isInVisibleMediaRange }.map { $0.cellTweetId })
        let filteredTweetIds = tweetIds.intersection(tweetsWithFeedVideos)

        self.visibleTweetIds = filteredTweetIds
        self.isScrolling = true

        // On initial feed load (no scroll), trigger preload once as if scroll stopped.
        if !initialPreloadDone && !filteredTweetIds.isEmpty && !allVideos.isEmpty {
            initialPreloadDone = true
            performPreloadOnScrollStop()
        }

        // Video visibility depends on video (media cell) only — use onScreenMediaCells as source of truth
        let currentVisibleIdentifiers = onScreenMediaCells
        let visibilityChanged = previousVisibleIdentifiers != currentVisibleIdentifiers

        // Stop all videos if none are visible
        if currentVisibleIdentifiers.isEmpty {
            if phase == .primaryPlaying, let primaryId = primaryVideoId {
                // Stop the primary so audio doesn't leak off-screen.
                if let primary = allVideos.first(where: { $0.identifier == primaryId }) {
                    if let delegate = mediaCellDelegates[primary.identifier] {
                        delegate.shouldStopVideo(withMid: primary.videoMid)
                    } else {
                        SharedAssetCache.shared.getCachedPlayer(for: primary.videoMid)?.pause()
                    }
                }
                phase = .idle
                currentlyPlayingVideoIds.removeAll()
                primaryVideoId = nil
                previousVisibleIdentifiers.removeAll()
                scheduleStartPrimary()
                return
            }
            previousVisibleIdentifiers.removeAll()
            stopAllVideos()
            return
        }

        // If the feed is covered by an overlay, do not start playback
        if isPlaybackSuppressedByOverlay {
            previousVisibleIdentifiers = currentVisibleIdentifiers
            return
        }

        // User scrolled — clear finished exclusion so the video can be re-selected if scrolled back
        if visibilityChanged {
            finishedPrimaryIdentifier = nil
        }

        // Stop videos whose cell left the visible area
        if visibilityChanged {
            let identifiersToStop = previousVisibleIdentifiers.subtracting(currentVisibleIdentifiers)
            if !identifiersToStop.isEmpty {
                if identifiersToStop.count >= 3 || scrollDirection == false {
                    SharedAssetCache.shared.forceMemoryCleanup()
                }

                let stillVisibleMids = Set(visibleVideos.map { $0.videoMid })

                for identifier in identifiersToStop {
                    cachedVisibilityRatios.removeValue(forKey: identifier)

                    guard let video = allVideos.first(where: { $0.identifier == identifier }) else { continue }

                    if !stillVisibleMids.contains(video.videoMid) {
                        if let delegate = mediaCellDelegates[video.identifier] {
                            delegate.shouldStopVideo(withMid: video.videoMid)
                        } else {
                            SharedAssetCache.shared.getCachedPlayer(for: video.videoMid)?.pause()
                        }
                    }
                }
            }
        }

        // Primary selection: keep current primary as long as it's visible.
        // Only select new primary when current one leaves screen or phase is idle.
        if visibilityChanged && !currentVisibleIdentifiers.isEmpty {
            if phase == .primaryPlaying,
               let primaryId = primaryVideoId,
               currentVisibleIdentifiers.contains(primaryId) {
                // Primary still visible — health check delegate only, no switching
                if mediaCellDelegates[primaryId] == nil {
                    phase = .idle
                    currentlyPlayingVideoIds.removeAll()
                    primaryVideoId = nil
                    scheduleStartPrimary()
                }
                // else: primary still healthy and visible — do nothing
                previousVisibleIdentifiers = currentVisibleIdentifiers
            } else {
                // Primary's cell gone or phase is idle — select new primary
                phase = .idle
                currentlyPlayingVideoIds.removeAll()
                primaryVideoId = nil
                scheduleStartPrimary()
                previousVisibleIdentifiers = currentVisibleIdentifiers
            }
        } else if phase == .idle && !currentVisibleIdentifiers.isEmpty {
            scheduleStartPrimary()
            previousVisibleIdentifiers = currentVisibleIdentifiers
        } else {
            previousVisibleIdentifiers = currentVisibleIdentifiers
        }

        // Clear preserve flag when user explicitly scrolls
        shouldPreserveStateOnForeground = false
    }

    /// Stop all videos and reset state
    func stopAllVideos() {
        // Cancel all timers
        playbackDebounceTimer?.invalidate()
        playbackDebounceTimer = nil
        pendingPrimaryCandidate = nil
        overlayUncoverPlaybackTimer?.invalidate()
        overlayUncoverPlaybackTimer = nil

        cachedVisibilityRatios.removeAll()

        // Cancel all active async tasks
        cancelActiveAsyncTasks()

        // Clear state
        currentlyPlayingVideoIds.removeAll()
        primaryVideoId = nil
        finishedPrimaryIdentifier = nil
        phase = .idle
        LocalHTTPServer.shared.clearPrimaryRestriction()
        // Clear previous visible identifiers so next updateVisibleTweets sees a change.
        // Do NOT clear onScreenMediaCells here: the overlay-dismiss 0.15s timer reads
        // visibleVideos (filtered by onScreenMediaCells) to decide whether to resume.
        // Clearing it would leave visibleVideos empty and break the resume path.
        // onScreenMediaCells is managed exclusively by updateOnScreenMediaCells().
        previousVisibleIdentifiers.removeAll()

        // Direct delegate calls to stop all registered cells in this coordinator
        for (_, delegate) in mediaCellDelegates {
            delegate.shouldStopAllVideos()
        }
    }

    /// Notify coordinator that the primary video has failed (buffering timeout or retries exhausted).
    /// Resets phase to idle and picks a new primary from remaining visible videos.
    /// Won't re-pick the same failed video — prevents infinite retry loops.
    func notifyPrimaryVideoFailed(identifier: String) {
        guard phase == .primaryPlaying, primaryVideoId == identifier else { return }

        phase = .idle
        currentlyPlayingVideoIds.remove(identifier)
        primaryVideoId = nil

        // Temporarily exclude the failed video so identifyPrimaryVideo() doesn't re-pick it.
        // This prevents: fail → coordinator picks same video → retry → fail → infinite loop.
        // The exclusion is cleared on next scroll (updateVisibleTweets) or when the cell
        // becomes visible again after scrolling out.
        failedPrimaryIdentifier = identifier

        // Pick a new primary from remaining visible videos
        startPrimaryVideoPlayback()

        failedPrimaryIdentifier = nil
    }

    /// Called by media cells when a video becomes ready to play (item readyToPlay or first frame).
    /// If the coordinator is idle (no primary), triggers primary selection.
    /// This covers the case where the previous primary was stopped/failed and no scroll event
    /// fires to re-evaluate — the newly-ready video can now become the primary.
    func requestStartPlaybackIfIdle() {
        guard phase == .idle else { return }
        startPrimaryVideoPlayback()
    }

    /// Called by media cells when ready. If coordinator is idle, starts playback.
    /// If coordinator thinks primary is playing but it's actually stuck, resets and restarts.
    func requestStartPlaybackIfStalled() {
        if phase == .idle {
            print("🎬 [COORD] stallCheck: phase is idle, starting primary")
            startPrimaryVideoPlayback()
            return
        }
        guard phase == .primaryPlaying, let primaryId = primaryVideoId else { return }

        // Grace period: don't consider primary stuck if recently selected — it may still be loading
        if let switchTime = lastPrimarySwitchTime, Date().timeIntervalSince(switchTime) < 3.0 {
            return
        }

        guard let delegate = mediaCellDelegates[primaryId] else {
            // Delegate gone — reset and restart
            print("🎬 [COORD] stallCheck: delegate gone for \(shortIdent(primaryId)), restarting")
            phase = .idle
            currentlyPlayingVideoIds.removeAll()
            primaryVideoId = nil
            startPrimaryVideoPlayback()
            return
        }
        if delegate.isActuallyPlaying { return }  // Primary is healthy — nothing to do
        // Primary has been commanded to play but AVPlayerItem is still loading (status=.unknown).
        // This is not a stall — it's normal IPFS/HLS latency. Let it load; durationMismatchTimer
        // and loadingTimeoutTask will handle genuine failures.
        if delegate.isLoadingForCoordinator { return }
        // Grace period after recent playback: give the primary time to recover from a brief
        // non-playing state (e.g. mid-startup, buffering). AVPlayer self-manages stall recovery
        // via automaticallyWaitsToMinimizeStalling=true (always set), surfacing gaps as
        // .waitingToPlayAtSpecifiedRate (caught by isActuallyPlaying), not .paused.
        if delegate.isRecentlyPlaying { return }
        // Primary is stuck — reset and restart. identifyPrimaryVideo naturally prefers a
        // different candidate when one exists (direction fix picks bottommost when scrolling down).
        // Do NOT set failedPrimaryIdentifier: if this is the only visible video it would block
        // it permanently; if another video is available the direction fix picks it anyway.
        print("🎬 [COORD] stallCheck: primary \(shortIdent(primaryId)) is stuck (isActuallyPlaying=false, notLoading, notRecent), restarting")
        phase = .idle
        currentlyPlayingVideoIds.removeAll()
        primaryVideoId = nil
        startPrimaryVideoPlayback()
    }

    /// Re-issue play to the current primary video if it is still visible.
    /// Used when returning to the feed (e.g. from user profile) so the video resumes instead of stopping.
    /// Does nothing if there is no primary, primary is no longer visible, or delegate is missing.
    func requestResumePrimaryPlaybackIfVisible() {
        guard phase == .primaryPlaying,
              let primaryId = primaryVideoId,
              let primary = visibleVideos.first(where: { $0.identifier == primaryId }),
              isVideoOnScreen(primary),
              let delegate = mediaCellDelegates[primaryId] else {
            return
        }
        // When granular on-screen tracking is used, only resume if primary is actually on-screen.
        if !onScreenMediaCells.isEmpty, !onScreenMediaCells.contains(primaryId) {
            return
        }
        delegate.shouldPlayVideo(withMid: primary.videoMid)
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

    /// Resolve the video URL and tweet ID for a VideoPlaybackInfo entry.
    private func resolveVideoURL(_ video: VideoPlaybackInfo) -> (url: URL, tweetId: String, mediaType: MediaType)? {
        guard let tweet = currentTweets.first(where: { $0.mid == video.mediaTweetId }) ?? Tweet.getInstance(for: video.mediaTweetId),
              let attachments = tweet.attachments,
              video.attachmentIndex < attachments.count else {
            return nil
        }

        let attachment = attachments[video.attachmentIndex]
        guard attachment.type == .video || attachment.type == .hls_video else { return nil }

        var videoURL: URL?
        if let urlString = attachment.url, let url = URL(string: urlString) {
            videoURL = url
        } else if let author = tweet.author, let baseUrl = author.baseUrl {
            videoURL = attachment.getUrl(baseUrl)
        }

        guard let url = videoURL else { return nil }
        return (url, tweet.mid, attachment.type)
    }

    /// Preload video asset without starting playback
    private func preloadVideoAsset(_ video: VideoPlaybackInfo) {
        guard let resolved = resolveVideoURL(video) else { return }
        SharedAssetCache.shared.preloadAsset(for: resolved.url, tweetId: resolved.tweetId, mediaType: resolved.mediaType)
    }

    /// Preload video player (asset + AVPlayer) for upcoming video in scroll direction.
    /// The pre-created player will be instantly available when the cell becomes visible.
    private func preloadVideoPlayer(_ video: VideoPlaybackInfo) {
        guard let resolved = resolveVideoURL(video) else { return }
        SharedAssetCache.shared.preloadPlayer(for: resolved.url, tweetId: resolved.tweetId, mediaType: resolved.mediaType)
    }

    /// Get the next `count` videos in scroll direction that are not currently on-screen.
    private func getNextVideosInScrollDirection(count: Int) -> [VideoPlaybackInfo] {
        // Use media-cell level visibility (onScreenMediaCells) instead of tweet-level.
        // Fall back to tweet-level at app start before onScreenMediaCells is populated.
        let visibleIndices: [Int]
        if !onScreenMediaCells.isEmpty {
            visibleIndices = allVideos.enumerated()
                .filter { onScreenMediaCells.contains($0.element.identifier) && $0.element.isInVisibleMediaRange }
                .map { $0.offset }
                .sorted()
        } else {
            let visibleVideoSet = visibleTweetIds
            visibleIndices = allVideos.enumerated()
                .filter { visibleVideoSet.contains($0.element.cellTweetId) && $0.element.isInVisibleMediaRange }
                .map { $0.offset }
                .sorted()
        }

        guard !visibleIndices.isEmpty else { return [] }

        var result: [VideoPlaybackInfo] = []

        if scrollDirection {
            let lastVisibleIndex = visibleIndices.max() ?? 0
            for i in 1...count {
                let nextIndex = lastVisibleIndex + i
                if nextIndex < allVideos.count {
                    let video = allVideos[nextIndex]
                    if video.isInVisibleMediaRange { result.append(video) }
                }
            }
        } else {
            let firstVisibleIndex = visibleIndices.min() ?? 0
            for i in 1...count {
                let prevIndex = firstVisibleIndex - i
                if prevIndex >= 0 {
                    let video = allVideos[prevIndex]
                    if video.isInVisibleMediaRange { result.append(video) }
                }
            }
        }

        return result
    }

    /// Preload videos for nearby (but not yet visible) tweets.
    /// Called by the table view controller with spatially adjacent tweet IDs
    /// that are just outside the visible area, providing better preloading than
    /// index-based adjacency in the allVideos array.
    /// Clear preloaded video tracking (called when video list is rebuilt)
    private func clearPreloadedTracking() {
        activePreloadMids.removeAll()
        activeNearbyMids.removeAll()
        scrollCancelTimer?.invalidate()
        scrollCancelTimer = nil
    }

    // MARK: - Private Methods

    /// Called when scrolling stops
    private func onScrollStopped() {
        isScrolling = false
    }

    /// Called when scroll starts (scrollViewWillBeginDragging).
    /// NodeConnectionPool manages bandwidth during scroll — no download cancellation needed here.
    func onScrollStarted() {
        scrollCancelTimer?.invalidate()
        scrollCancelTimer = nil
    }
    
    /// Called on scroll stop and initial load. Replaces preloadVideosInScrollDirection +
    /// updateNearbyTweetsForPreloading with explicit set management and stale cleanup.
    func performPreloadOnScrollStop(nearbyTweetIds: Set<String> = []) {
        scrollCancelTimer?.invalidate()
        scrollCancelTimer = nil

        // 1. New preload set: next 2 videos in scroll direction
        let nextVideos = getNextVideosInScrollDirection(count: 2)
        let newPreloadMids = Set(nextVideos.map { $0.videoMid })

        // 2. New nearby set: videos in adjacent tweets, excluding preload duplicates
        let newNearbyMids: Set<String> = {
            let nearbyVideos = allVideos.filter {
                nearbyTweetIds.contains($0.cellTweetId)
                    && $0.isInVisibleMediaRange
                    && !newPreloadMids.contains($0.videoMid)
            }
            return Set(nearbyVideos.map { $0.videoMid })
        }()

        // 3. Cancel stale preloads (not in new sets, not on-screen)
        let onScreenMids = Set(allVideos.filter { onScreenMediaCells.contains($0.identifier) }.map { $0.videoMid })
        let newAll = newPreloadMids.union(newNearbyMids).union(onScreenMids)
        let staleMids = activePreloadMids.union(activeNearbyMids).subtracting(newAll)
        for mid in staleMids {
            SharedAssetCache.shared.cancelPreloadTask(for: mid)
        }
        if !staleMids.isEmpty {
            print("🎬 [COORD] Scroll stop: cancelled \(staleMids.count) stale preloads")
        }

        // 4. Update tracking
        activePreloadMids = newPreloadMids
        activeNearbyMids = newNearbyMids
        SharedAssetCache.shared.updatePreloadedPlayerMids(newPreloadMids)

        // 5. Start new preloads — preload players first (get download slots), then nearby assets
        for video in nextVideos where SharedAssetCache.shared.getCachedPlayer(for: video.videoMid) == nil {
            preloadVideoPlayer(video)
        }
        let nearbyVideos = allVideos.filter { newNearbyMids.contains($0.videoMid) }
        for video in nearbyVideos where SharedAssetCache.shared.getCachedPlayer(for: video.videoMid) == nil {
            preloadVideoAsset(video)
        }

        if !newPreloadMids.isEmpty || !newNearbyMids.isEmpty {
            print("🎬 [COORD] Scroll stop: preloading \(newPreloadMids.count) players + \(newNearbyMids.count) nearby assets")
        }
    }

    /// Schedule primary video playback after a short debounce (0.3s).
    /// Fast path: if the top candidate has a cached ready player, play immediately (no debounce).
    /// Slow path: start 0.3s timer. Per-candidate: the timer is NOT reset as long as the same
    /// video remains the top candidate. Only resets when the candidate changes.
    private func scheduleStartPrimary() {
        guard let candidate = identifyPrimaryVideo() else { return }
        let topCandidate = candidate.identifier

        // Fast path: cached ready player → play immediately, skip debounce.
        if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: candidate.videoMid),
           cachedPlayer.currentItem?.status == .readyToPlay {
            playbackDebounceTimer?.invalidate()
            playbackDebounceTimer = nil
            pendingPrimaryCandidate = nil
            if phase == .idle {
                startPrimaryVideoPlayback()
            }
            return
        }

        // If the timer is already running for this exact candidate, let it keep ticking.
        if playbackDebounceTimer != nil && topCandidate == pendingPrimaryCandidate {
            return
        }

        // Candidate changed (or no timer running) — restart the clock for the new candidate.
        playbackDebounceTimer?.invalidate()
        pendingPrimaryCandidate = topCandidate
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.playbackDebounceTimer = nil
                self.pendingPrimaryCandidate = nil
                if self.phase == .idle && !self.visibleVideos.isEmpty {
                    self.startPrimaryVideoPlayback()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackDebounceTimer = timer
    }

    /// Start primary video playback — play topmost video immediately.
    /// Fully synchronous: visibility calculations use direct UITableView access.
    /// Delegate existence is validated before committing state to prevent stuck `primaryPlaying`.
    private func startPrimaryVideoPlayback() {
        // Cancel any pending debounced start — immediate caller wins
        playbackDebounceTimer?.invalidate()
        playbackDebounceTimer = nil
        pendingPrimaryCandidate = nil

        guard !isPlaybackSuppressedByOverlay else {
            print("🎬 [COORD] startPrimary: blocked by overlay")
            return
        }
        guard isFeedVisible else {
            print("🎬 [COORD] startPrimary: feed not visible")
            return
        }
        guard phase == .idle else {
            print("🎬 [COORD] startPrimary: skipped (phase=\(phase), current primary=\(primaryVideoId.map { shortIdent($0) } ?? "nil"))")
            return
        }

        let onScreenCount = onScreenMediaCells.count
        let visibleCount = visibleVideos.count
        let delegateCount = mediaCellDelegates.count

        guard let primary = identifyPrimaryVideo() else {
            print("🎬 [COORD] startPrimary: no candidate (onScreen=\(onScreenCount), visible=\(visibleCount), delegates=\(delegateCount))")
            // Only stop all videos when there ARE videos but none are visible (all scrolled off).
            // When allVideos is empty (feed not loaded yet), don't stop — cells may be mid-load
            // and buildVideoList will kick playback once the video list is populated.
            if !allVideos.isEmpty {
                stopAllVideos()
            }
            return
        }

        // When we have granular on-screen tracking, never start playback for a video that isn't on-screen.
        // Prevents off-screen videos from resuming after updateOnScreenMediaCells stopped them.
        if !onScreenMediaCells.isEmpty, !onScreenMediaCells.contains(primary.identifier) {
            print("🎬 [COORD] startPrimary: \(shortMID(primary.videoMid)) not in onScreenMediaCells (\(onScreenCount) cells)")
            return
        }

        // Validate delegate exists before committing to primaryPlaying.
        // If the cell was reused or visibility changed, the delegate may be gone.
        // Stay idle so next updateVisibleTweets will retry.
        guard let delegate = mediaCellDelegates[primary.identifier] else {
            print("🎬 [COORD] startPrimary: \(shortMID(primary.videoMid)) has no delegate")
            return
        }

        print("🎬 [COORD] startPrimary: selected \(shortMID(primary.videoMid)) (onScreen=\(onScreenCount), visible=\(visibleCount), scrollDown=\(scrollDirection))")

        // Stop the previous primary video if different
        if let previousPrimaryId = primaryVideoId, previousPrimaryId != primary.identifier {
            if let prevDelegate = mediaCellDelegates[previousPrimaryId],
               let previousPrimary = allVideos.first(where: { $0.identifier == previousPrimaryId }) {
                prevDelegate.shouldStopVideo(withMid: previousPrimary.videoMid)
            }
        }

        // Pause all visible videos except the new primary
        for video in visibleVideos where video != primary {
            pauseVideo(video)
        }

        // Set state and play synchronously — no asyncAfter race condition
        phase = .primaryPlaying
        primaryVideoId = primary.identifier
        currentlyPlayingVideoIds = [primary.identifier]
        cachedVisibilityRatios[primary.identifier] = 0.7
        lastPrimarySwitchTime = Date()

        // Set primary immediately so its segment requests bypass the concurrent download limit.
        let primaryMid = primary.videoMid
        LocalHTTPServer.shared.setPrimaryMediaID(primaryMid)

        // NodeConnectionPool now manages bandwidth: primary gets priority,
        // preloads wait between segment/chunk requests when primary is starved.
        // No need to cancel preload downloads here.

        delegate.shouldPlayVideo(withMid: primary.videoMid)
    }

    /// Identify the primary video based on scroll direction.
    /// visibleVideos is in feed order (index 0 = topmost on screen, last = bottommost).
    /// Scrolling down: pick topmost (already in view, user is reading it).
    /// Scrolling up: pick bottommost (just scrolled into view from below).
    private func identifyPrimaryVideo() -> VideoPlaybackInfo? {
        guard tableView?.window != nil else {
            return visibleVideos.first
        }

        let candidates = scrollDirection ? visibleVideos : visibleVideos.reversed()

        // visibleVideos is derived from onScreenMediaCells only; pick first candidate with a delegate.
        // Skip failedPrimaryIdentifier and finishedPrimaryIdentifier to avoid re-selecting.
        for video in candidates {
            guard mediaCellDelegates[video.identifier] != nil else { continue }
            if video.identifier == failedPrimaryIdentifier { continue }
            if video.identifier == finishedPrimaryIdentifier { continue }
            return video
        }

        return nil
    }

    /// Pause a specific video
    private func pauseVideo(_ video: VideoPlaybackInfo) {
        let videoId = video.identifier
        currentlyPlayingVideoIds.remove(videoId)

        // Direct delegate call — no broadcast notification
        if let delegate = mediaCellDelegates[video.identifier] {
            delegate.shouldPauseVideo(withMid: video.videoMid)
        }
    }

    /// Returns true if this video is on-screen (visibility depends on video/media cell only).
    private func isVideoOnScreen(_ video: VideoPlaybackInfo) -> Bool {
        onScreenMediaCells.contains(video.identifier)
    }
    
    /// Soft idle after primary finishes — preserve preloaded state and finishedPrimaryIdentifier.
    /// Unlike stopAllVideos(), does NOT broadcast shouldStopAllVideos or clear visibility tracking.
    /// The finished video was already paused by the finish handler; we just reset coordinator state
    /// and let scheduleStartPrimary pick up the next candidate when one appears.
    private func goIdleAfterPrimaryFinished() {
        // Pause the finished primary's coordinatorWantsToPlay flag
        if let primaryId = primaryVideoId,
           let video = allVideos.first(where: { $0.identifier == primaryId }),
           let delegate = mediaCellDelegates[primaryId] {
            delegate.shouldPauseVideo(withMid: video.videoMid)
        }

        let finishedMid = primaryVideoId.flatMap { id in allVideos.first(where: { $0.identifier == id })?.videoMid } ?? "?"
        print("🎬 [COORD] goIdleAfterPrimaryFinished: \(shortMID(finishedMid)) done, onScreen=\(onScreenMediaCells.count), visible=\(visibleVideos.count)")

        currentlyPlayingVideoIds.removeAll()
        primaryVideoId = nil
        phase = .idle
        LocalHTTPServer.shared.clearPrimaryRestriction()
        // Do NOT clear finishedPrimaryIdentifier — it prevents re-selecting the just-finished video
        // Do NOT clear previousVisibleIdentifiers — preserve visibility tracking
        // Do NOT broadcast shouldStopAllVideos — cells keep their players/state

        // Let the debounce timer check for a new visible candidate (e.g. preloaded video appears on scroll)
        scheduleStartPrimary()
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
            goIdleAfterPrimaryFinished()
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
                goIdleAfterPrimaryFinished()
                return
            }
        } else {
            // Scrolling UP: go back to previous video
            targetIndex = currentIndex - 1
            guard targetIndex >= 0 else {
                goIdleAfterPrimaryFinished()
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
        while candidateIndex >= 0 && candidateIndex < visibleVideos.count {
            let candidate = visibleVideos[candidateIndex]
            let isVisible = isVideoOnScreen(candidate)
            if isVisible {
                nextVideo = candidate
                break
            }
            candidateIndex += step
        }

        guard let nextVideo else {
            goIdleAfterPrimaryFinished()
            return
        }
        let currentVideo = visibleVideos[currentIndex]

        // CRITICAL: Clear coordinatorWantsToPlay flag for finished video
        if let delegate = mediaCellDelegates[currentVideo.identifier] {
            delegate.shouldPauseVideo(withMid: currentVideo.videoMid)
        }

        // Set new primary and start playing
        primaryVideoId = nextVideo.identifier
        currentlyPlayingVideoIds = [nextVideo.identifier]
        // Mirror startPrimaryVideoPlayback: clear cancelledMediaID so a preloaded-then-cancelled
        // player can resume downloading immediately without waiting for a new CachingPlayerItem.
        LocalHTTPServer.shared.setPrimaryMediaID(nextVideo.videoMid)

        // Direct delegate call — no broadcast notification
        if let delegate = mediaCellDelegates[nextVideo.identifier] {
            delegate.shouldPlayVideo(withMid: nextVideo.videoMid)
        }
    }
    
    /// Handle video finished notification.
    /// Match by full identifier (cellTweetId_videoMid_attachmentIndex) so the same video in different cells is distinct.
    @objc private func handleVideoFinished(_ notification: Notification) {
        guard let videoMid = notification.userInfo?["videoMid"] as? String else {
            return
        }

        let videoIdentifier = notification.userInfo?["videoIdentifier"] as? String

        if phase == .primaryPlaying,
           let primaryId = primaryVideoId {
            let isPrimaryFinished: Bool
            if let vid = videoIdentifier {
                isPrimaryFinished = (primaryId == vid)
            } else {
                isPrimaryFinished = primaryId.contains(videoMid)
            }
            if isPrimaryFinished {
                finishedPrimaryIdentifier = primaryId
                playNextVisibleVideo()
            }
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
                // Resume primary video — match by full identifier (tweet id + video id + index) only.
                if let primary = visibleVideos.first(where: { $0.identifier == primaryId }) {
                    
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

                        // Direct delegate call — no broadcast notification
                        if let delegate = mediaCellDelegates[firstVideo.identifier] {
                            delegate.shouldPlayVideo(withMid: firstVideo.videoMid)
                        }
                    } else {
                        // Primary is first or only video - resume it
                        primaryVideoId = primary.identifier
                        currentlyPlayingVideoIds = [primary.identifier]

                        // Direct delegate call — no broadcast notification
                        if let delegate = mediaCellDelegates[primary.identifier] {
                            delegate.shouldPlayVideo(withMid: primary.videoMid)
                        }
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
