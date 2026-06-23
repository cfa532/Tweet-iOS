//
//  VideoPlaybackCoordinator.swift
//  Tweet
//
//  Coordinates video playback across the app
//  Behavior: Start a video once it is 50% visible; stop the current video once it drops below 70% visible.
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

private final class MediaCellDelegateStorage {
    private weak var weakObject: AnyObject?
    private var strongValue: MediaCellDelegate?

    init(_ delegate: MediaCellDelegate) {
        if Mirror(reflecting: delegate).displayStyle == .class {
            self.weakObject = delegate as AnyObject
        } else {
            self.strongValue = delegate
        }
    }

    var delegate: MediaCellDelegate? {
        if let weakObject {
            return weakObject as? MediaCellDelegate
        }
        return strongValue
    }
}

/// Video state during orchestration
private enum VideoPlaybackPhase {
    case idle                    // No playback
    case primaryPlaying          // Primary video is playing to completion
}

/// Canonical video tracking info.
/// A video is indexed by both the outermost visible tweet id and its own media id so
/// the same video in different feed/detail contexts is distinct.
///
/// - `outerTweetId`: The outermost tweet ID that owns the visible context (feed row/detail tweet).
/// - `cellTweetId`: The tweet ID of the visible media cell/comment (retweet ID for retweets, quoting tweet ID for embedded/quoted media).
/// - `mediaTweetId`: The tweet ID that actually owns the attachments (original tweet for retweets, embedded tweet for quoted media).
/// - `videoMid`: The attachment/media id (same video content can appear in multiple cells).
/// - `attachmentIndex`: The index in `mediaTweetId.attachments` (can be > 3; fullscreen needs this).
///
/// `identifier` = outerTweetId + "_" + mediaTweetId + "_" + videoMid + "_" + attachmentIndex
/// is the unique key for playback (one delegate per rendered media instance).
/// Feed playback coordination only considers `attachmentIndex < 4` because `MediaGridView` only renders the first 4 items.
struct VideoPlaybackInfo: Equatable {
    let outerTweetId: String?
    let cellTweetId: String
    let mediaTweetId: String
    let videoMid: String
    let attachmentIndex: Int

    init(
        outerTweetId: String? = nil,
        cellTweetId: String,
        mediaTweetId: String,
        videoMid: String,
        attachmentIndex: Int
    ) {
        self.outerTweetId = outerTweetId
        self.cellTweetId = cellTweetId
        self.mediaTweetId = mediaTweetId
        self.videoMid = videoMid
        self.attachmentIndex = attachmentIndex
    }

    var contextTweetId: String {
        outerTweetId ?? cellTweetId
    }

    /// Unique key for this video instance: outer tweet + media owner + video id + index.
    var identifier: String {
        "\(contextTweetId)_\(mediaTweetId)_\(videoMid)_\(attachmentIndex)"
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
/// 3. When current video drops below 70% visible, switch to the next 50% visible video if available
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

    /// Media cells with any visible pixels. These must load, but are not necessarily
    /// eligible for autoplay until they reach the stricter onScreenMediaCells threshold.
    private var loadVisibleMediaCells: Set<String> = []

    /// Media cells visible enough for the current primary video to keep playing.
    /// New primary candidates still use onScreenMediaCells, which is the 50% start threshold.
    private var continuePlaybackMediaCells: Set<String> = []

    /// Current primary excluded after it drops below the continue threshold.
    /// Prevents the 50% start threshold from immediately reselecting the same outgoing video.
    private var primaryBelowContinueIdentifier: String?

    /// All videos in the app (ordered by feed, then attachmentIndex).
    private var allVideos: [VideoPlaybackInfo] = []
    /// Tweet IDs that have feed-visible videos. Rebuilt with allVideos so scroll
    /// visibility updates do not scan the full feed on every geometry pass.
    private var feedVisibleVideoTweetIds: Set<String> = []

    /// Store current tweet list for embedded tweet lookup
    private var currentTweets: [Tweet] = []

    /// Cached visibility ratios for hysteresis (only tracks primary video)
    private var cachedVisibilityRatios: [String: CGFloat] = [:]
    private let visibilityRatioThreshold: CGFloat = 0.10

    /// Actively tracked directional video preloads — explicitly managed on scroll stop.
    private var activePreloadMids: Set<String> = []
    private var lastDirectionalPreloadRefreshTime: CFTimeInterval = 0
    private let directionalPreloadRefreshInterval = FeedPlaybackTuning.directionalVideoPreloadRefreshInterval
    var directionalPlayerPreloadCount: Int = FeedPlaybackTuning.directionalVideoPreloadCount {
        didSet {
            if directionalPlayerPreloadCount <= 0 {
                clearPreloadedTracking()
            }
        }
    }

    /// Track async tasks to prevent leaks
    /// MEMORY FIX: Use UUID-based tracking so tasks can remove themselves on completion
    /// Since this class is @MainActor, all access is serialized on the main actor
    /// Uses nonisolated(unsafe) for deinit access - safe because deinit runs once
    private nonisolated(unsafe) var activeAsyncTaskIds: Set<UUID> = []
    private let maxConcurrentTasks = 10  // Increased limit since we properly clean up now

    // MARK: - Delegate-Based Communication (Phase 3)

    /// Registered MediaCell delegates for direct communication (keyed by video identifier:
    /// outerTweetId_mediaTweetId_videoMid_attachmentIndex). This allows the same videoMid to have separate
    /// delegates when it appears in both a tweet and its retweet.
    private var mediaCellDelegates: [String: MediaCellDelegateStorage] = [:]

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

    private func setVideoList(_ videos: [VideoPlaybackInfo]) {
        allVideos = videos
        feedVisibleVideoTweetIds = Set(videos.filter { $0.isInVisibleMediaRange }.map { $0.cellTweetId })
        invalidateVisibleVideoCache()
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

        // NOTE: .reloadVisibleVideosOnly is intentionally NOT observed here.
        // The owning TweetTableViewController observes it, refreshes viewport
        // visibility first, and then calls recoverVisiblePlaybackAfterInterruption.
        // Subscribing here too made the coordinator recover off stale visibility
        // (its observer ran before the controller's visibility refresh), racing
        // the foreground feed refresh and leaving the on-screen video unplayed.

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
        let source = notification.userInfo?["source"] as? String
                
        isPlaybackSuppressedByOverlay = isCovered
        
        // Cancel any pending "resume after overlay" timer.
        overlayUncoverPlaybackTimer?.invalidate()
        overlayUncoverPlaybackTimer = nil
        
        if isCovered {
            // Fullscreen media browser borrows the same shared AVPlayer as the feed.
            // Do not pause it during coverage; ownership is transferring, not stopping.
            if source != "MediaCellUIView.handleVideoTap" && source != "MediaBrowserView" {
                // Hard stop so no audio bleeds under non-media overlays, and so we
                // don't preserve stale primary state.
                stopAllVideos()
            }
            return
        }
        
        
        // Overlay dismissed: wait for layout to settle before restarting.
        // The settling delay lets view transitions and cell layout complete. While this timer
        // is pending (overlayUncoverPlaybackTimer != nil), other resume paths
        // (viewWillAppear, updateOnScreenMediaCells) defer to avoid double-evaluation.
        let settleDelay: TimeInterval = source == "MediaBrowserView"
            ? 0.05
            : FeedPlaybackTuning.overlayDismissSettleDelay
        let timer = Timer(timeInterval: settleDelay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.overlayUncoverPlaybackTimer = nil  // Settling period is over

                guard !self.isPlaybackSuppressedByOverlay,
                      self.isFeedVisible,
                      !self.visibleVideos.isEmpty,
                      let tableView = self.tableView,
                      tableView.window != nil else {
                    return
                }
                self.recoverVisiblePlaybackAfterInterruption(
                    reason: "overlayDismiss",
                    isForegroundRecovery: false
                )
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
        mediaCellDelegates[identifier] = MediaCellDelegateStorage(delegate)

        // Do NOT insert into onScreenMediaCells here. didMoveToWindow fires for cells that
        // UITableView prefetches below the viewport — they are in the window but NOT visible.
        // Only updateOnScreenMediaCells (which does geometric 50% visibility checks) should
        // manage onScreenMediaCells. Otherwise off-screen cells get selected as primary.
        //
        // At app start, cells register AFTER the initial updateVisibleTweetsForVideoPlayback().
        // Use scheduleStartPrimary so active scrolling still debounces, while idle feeds can
        // start as soon as the visible delegate is available.
        if phase == .idle {
            scheduleStartPrimary()
        }
    }

    /// Unregister a MediaCell delegate (keyed by video identifier)
    func unregisterDelegate(forIdentifier identifier: String) {
        mediaCellDelegates.removeValue(forKey: identifier)
    }

    private func delegate(forIdentifier identifier: String) -> MediaCellDelegate? {
        guard let wrapper = mediaCellDelegates[identifier] else { return nil }
        guard let delegate = wrapper.delegate else {
            mediaCellDelegates.removeValue(forKey: identifier)
            return nil
        }
        return delegate
    }

    private var liveDelegateCount: Int {
        pruneReleasedDelegates()
        return mediaCellDelegates.count
    }

    private func liveDelegates() -> [MediaCellDelegate] {
        pruneReleasedDelegates()
        return mediaCellDelegates.compactMap { $0.value.delegate }
    }

    private func pruneReleasedDelegates() {
        mediaCellDelegates = mediaCellDelegates.filter { $0.value.delegate != nil }
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
                    self.setVideoList(newVideos)
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
                    self.setVideoList(newVideos)
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
                self.setVideoList(videos)

                // Clear caches when video list is rebuilt
                self.cachedVisibilityRatios.removeAll()
                self.clearPreloadedTracking()
                self.initialPreloadDone = false
                self.primaryBelowContinueIdentifier = nil

                // Store tweet list for embedded tweet lookup
                self.currentTweets = pinnedTweets + tweets

                // Call completion handler BEFORE auto-playback check
                // This allows caller to update visibleTweetIds first
                completion?()

                // Trigger playback update after video list is rebuilt if in idle phase and videos are visible.
                // Clear finished/skipped gates first so a video that played to completion before backgrounding
                // is not permanently excluded from autoplay selection when the feed returns to foreground.
                if self.phase == .idle && !self.visibleVideos.isEmpty && !self.isPlaybackSuppressedByOverlay {
                    self.clearFinishedAutoplayGateForForeground()
                    self.startPrimaryVideoPlayback()
                }

                // NOTE: Preloading is NOT triggered here because visibleTweetIds
                // hasn't been set yet. performPreloadOnScrollStop() is called from
                // updateViewportVisibility() on the first visibility update (initialPreloadDone).
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
                    let originalTweet = resolveMediaTweet(originalTweetId)

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
                    let embeddedTweet = resolveMediaTweet(originalTweetId)

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
    
    /// Previously visible video identifiers (outerTweetId_mediaTweetId_videoMid_attachmentIndex).
    /// Using full identifiers (not bare videoMids) ensures the same video in a tweet
    /// and its retweet are tracked independently.
    private var previousVisibleIdentifiers: Set<String> = []

    /// Update media cells that are physically visible and therefore should load.
    /// This is intentionally broader than updateOnScreenMediaCells(_:), which is
    /// the autoplay set and requires a media cell to be at least 50% visible.
    func updateLoadVisibleMediaCells(_ identifiers: Set<String>) {
        guard loadVisibleMediaCells != identifiers else { return }
        loadVisibleMediaCells = identifiers
    }

    /// Atomic viewport update from the table view. Keeps scroll direction, visible
    /// loading cells, autoplay candidates, and tweet visibility in sync so playback
    /// is reconciled exactly once per geometry pass.
    func updateViewportVisibility(
        loadVisibleIdentifiers: Set<String>,
        continuePlaybackIdentifiers: Set<String>,
        playableIdentifiers: Set<String>,
        visibleTweetIds tweetIds: Set<String>
    ) {
        OverlayVisibilityCoordinator.shared.verifyConsistency(source: "VideoPlaybackCoordinator.updateViewportVisibility")
        updateScrollDirectionFromTableView()

        loadVisibleMediaCells = loadVisibleIdentifiers
        promoteForegroundVisibleMedia(reason: "viewport")
        updateFeedVisibleTweets(tweetIds)
        updatePlayableMediaCells(
            playableIdentifiers,
            continuePlaybackIdentifiers: continuePlaybackIdentifiers
        )
        reconcilePlaybackForCurrentVisibility()
    }
    
    /// Update which specific media cells are on-screen within the viewport.
    /// Called by TweetTableViewController alongside updateVisibleTweets, with per-cell granularity.
    /// Triggers primary video switch if the current primary went off-screen.
    func updateOnScreenMediaCells(_ identifiers: Set<String>) {
        updateScrollDirectionFromTableView()
        updatePlayableMediaCells(
            identifiers,
            continuePlaybackIdentifiers: continuePlaybackMediaCells.intersection(identifiers)
        )
        reconcilePlaybackForCurrentVisibility()
    }

    /// Update visible tweets (called during scrolling)
    func updateVisibleTweets(_ tweetIds: Set<String>) {
        OverlayVisibilityCoordinator.shared.verifyConsistency(source: "VideoPlaybackCoordinator.updateVisibleTweets")
        updateScrollDirectionFromTableView()
        updateFeedVisibleTweets(tweetIds)
        reconcilePlaybackForCurrentVisibility()
    }

    private func updateScrollDirectionFromTableView() {
        // Track scroll direction based on content offset (no preloading during scroll)
        if let tableView = tableView, tableView.window != nil {
            let currentOffset = tableView.contentOffset.y
            if previousContentOffset != 0 {
                scrollDirection = currentOffset > previousContentOffset
            }
            previousContentOffset = currentOffset
        }
    }

    private func updateFeedVisibleTweets(_ tweetIds: Set<String>) {
        // Only consider feed-visible video entries (MediaGrid only shows first 4 attachments)
        let filteredTweetIds = tweetIds.intersection(feedVisibleVideoTweetIds)

        self.visibleTweetIds = filteredTweetIds
        // On initial feed load (no scroll), trigger preload once as if scroll stopped.
        if !initialPreloadDone && !filteredTweetIds.isEmpty && !allVideos.isEmpty {
            initialPreloadDone = true
            performPreloadOnScrollStop()
        }
    }

    private func updatePlayableMediaCells(
        _ identifiers: Set<String>,
        continuePlaybackIdentifiers: Set<String>
    ) {
        // During fullscreen/detail dismissal, UIKit can briefly report no visible
        // cells while the presenting table view is reattaching. Keep the last
        // known playable set through the overlay settling timer so the resume
        // path still has a primary candidate.
        if overlayUncoverPlaybackTimer != nil,
           identifiers.isEmpty,
           !onScreenMediaCells.isEmpty {
            return
        }

        guard onScreenMediaCells != identifiers ||
              continuePlaybackMediaCells != continuePlaybackIdentifiers else { return }
        onScreenMediaCells = identifiers
        continuePlaybackMediaCells = continuePlaybackIdentifiers
        if let excluded = primaryBelowContinueIdentifier,
           continuePlaybackIdentifiers.contains(excluded) || !identifiers.contains(excluded) {
            primaryBelowContinueIdentifier = nil
        }
        invalidateVisibleVideoCache()
    }

    private func reconcilePlaybackForCurrentVisibility() {
        // Video visibility depends on video (media cell) only — use onScreenMediaCells as source of truth
        let currentVisibleIdentifiers = onScreenMediaCells
        let primaryDroppedBelowContinueThreshold: Bool = {
            guard phase == .primaryPlaying,
                  let primaryId = primaryVideoId,
                  currentVisibleIdentifiers.contains(primaryId) else {
                return false
            }
            return !continuePlaybackMediaCells.contains(primaryId)
        }()
        let visibilityChanged = previousVisibleIdentifiers != currentVisibleIdentifiers ||
            primaryDroppedBelowContinueThreshold

        // The overlay dismiss timer owns playback restart while layout settles.
        // Do not stop/switch/schedule here, or a transient viewport sample can
        // cancel the timer via stopAllVideos() and leave the feed blank.
        if overlayUncoverPlaybackTimer != nil {
            previousVisibleIdentifiers = currentVisibleIdentifiers
            return
        }

        // Stop all videos if none are visible
        if currentVisibleIdentifiers.isEmpty {
            if phase == .primaryPlaying, let primaryId = primaryVideoId {
                // Stop the primary so audio doesn't leak off-screen.
                if let primary = allVideos.first(where: { $0.identifier == primaryId }) {
                    if let delegate = delegate(forIdentifier: primary.identifier) {
                        delegate.shouldStopVideo(withMid: primary.videoMid)
                    } else {
                        SharedAssetCache.shared.getCachedPlayer(for: primary.videoMid)?.pause()
                    }
                }
                phase = .idle
                currentlyPlayingVideoIds.removeAll()
                primaryVideoId = nil
                previousVisibleIdentifiers.removeAll()
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

        // Keep the just-finished video excluded while it remains visible. Clear the
        // exclusion only after that specific cell leaves the viewport.
        if let finishedId = finishedPrimaryIdentifier,
           !currentVisibleIdentifiers.contains(finishedId) {
            VideoStateCache.shared.clearVideoFinished(finishedId)
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
                        if let delegate = delegate(forIdentifier: video.identifier) {
                            delegate.shouldStopVideo(withMid: video.videoMid)
                        } else {
                            SharedAssetCache.shared.getCachedPlayer(for: video.videoMid)?.pause()
                        }
                    }
                }
            }
        }

        // Primary selection: new videos can start at 50%, but the active primary
        // must remain 70% visible to keep playing.
        if visibilityChanged && !currentVisibleIdentifiers.isEmpty {
            if phase == .primaryPlaying,
               let primaryId = primaryVideoId,
               continuePlaybackMediaCells.contains(primaryId) {
                // Primary still visible — health check delegate only, no switching
                if delegate(forIdentifier: primaryId) == nil {
                    phase = .idle
                    currentlyPlayingVideoIds.removeAll()
                    primaryVideoId = nil
                    scheduleStartPrimary()
                }
                // else: primary still healthy and visible — do nothing
                previousVisibleIdentifiers = currentVisibleIdentifiers
            } else {
                if phase == .primaryPlaying,
                   let primaryId = primaryVideoId {
                    stopPrimaryVideo(identifier: primaryId)
                    if currentVisibleIdentifiers.contains(primaryId),
                       !continuePlaybackMediaCells.contains(primaryId) {
                        primaryBelowContinueIdentifier = primaryId
                    }
                }
                // Primary's cell dropped below continuation threshold, disappeared, or phase is idle.
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

    private func stopPrimaryVideo(identifier: String) {
        guard let primary = allVideos.first(where: { $0.identifier == identifier }) else { return }
        if let delegate = delegate(forIdentifier: primary.identifier) {
            delegate.shouldStopVideo(withMid: primary.videoMid)
        } else {
            SharedAssetCache.shared.getCachedPlayer(for: primary.videoMid)?.pause()
        }
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
        primaryBelowContinueIdentifier = nil
        phase = .idle
        LocalHTTPServer.shared.clearPrimaryRestriction()
        // Clear previous visible identifiers so next updateVisibleTweets sees a change.
        // Do NOT clear onScreenMediaCells here: the overlay-dismiss 0.15s timer reads
        // visibleVideos (filtered by onScreenMediaCells) to decide whether to resume.
        // Clearing it would leave visibleVideos empty and break the resume path.
        // onScreenMediaCells is managed exclusively by viewport/media visibility updates.
        previousVisibleIdentifiers.removeAll()

        // Direct delegate calls to stop all registered cells in this coordinator
        for delegate in liveDelegates() {
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

    /// Clear the temporary finished gate when the same video is actively playing again.
    func clearFinishedPlaybackState(identifier: String) {
        VideoStateCache.shared.clearVideoFinished(identifier)
        if finishedPrimaryIdentifier == identifier {
            finishedPrimaryIdentifier = nil
        }
    }

    /// User-initiated replay for a video that previously reached the end.
    /// This clears the finished gate and makes the replayed video the active primary.
    @discardableResult
    func replayFinishedVideo(identifier: String) -> Bool {
        guard let video = allVideos.first(where: { $0.identifier == identifier }),
              let delegate = delegate(forIdentifier: identifier) else {
            return false
        }

        stopAllVideos()
        VideoStateCache.shared.clearVideoFinished(identifier)
        failedPrimaryIdentifier = nil
        finishedPrimaryIdentifier = nil

        phase = .primaryPlaying
        primaryVideoId = identifier
        currentlyPlayingVideoIds = [identifier]
        cachedVisibilityRatios[identifier] = 0.7
        lastPrimarySwitchTime = Date()
        LocalHTTPServer.shared.setPrimaryMediaID(video.videoMid)

        delegate.shouldPlayVideo(withMid: video.videoMid)
        refreshDirectionalPreloads(reason: "manual replay", throttle: false)
        return true
    }

    /// Called by media cells when ready. If coordinator is idle, starts playback.
    /// If coordinator thinks primary is playing but it's actually stuck, resets and restarts.
    func requestStartPlaybackIfStalled() {
        if phase == .idle {
            print("🎬 [COORD] stallCheck: phase is idle, scheduling primary")
            scheduleStartPrimary()
            return
        }
        guard phase == .primaryPlaying, let primaryId = primaryVideoId else { return }

        guard onScreenMediaCells.contains(primaryId),
              continuePlaybackMediaCells.contains(primaryId) else {
            return
        }

        // Grace period: don't consider primary stuck if recently selected — it may still be loading
        if let switchTime = lastPrimarySwitchTime, Date().timeIntervalSince(switchTime) < 3.0 {
            return
        }

        guard let delegate = delegate(forIdentifier: primaryId) else {
            // Delegate gone — reset and restart
            print("🎬 [COORD] stallCheck: delegate gone for \(shortIdent(primaryId)), restarting")
            phase = .idle
            currentlyPlayingVideoIds.removeAll()
            primaryVideoId = nil
            startPrimaryVideoPlayback()
            return
        }
        if delegate.isActuallyPlaying {
            refreshDirectionalPreloads(reason: "primary healthy", throttle: true)
            return
        }  // Primary is healthy — nothing to do
        // Primary has been commanded to play but AVPlayerItem is still loading (status=.unknown).
        // This is not a stall — it's normal IPFS/HLS latency. Let it load; once the item
        // reaches readyToPlay and play() is called, the buffering timeout in
        // isActuallyPlaying will handle genuine stuck-buffering failures.
        if delegate.isLoadingForCoordinator { return }
        // Grace period after recent playback: give the primary time to recover from a brief
        // non-playing state (e.g. mid-startup, buffering). AVPlayer self-manages stall recovery
        // via automaticallyWaitsToMinimizeStalling=true (default), surfacing gaps as
        // .waitingToPlayAtSpecifiedRate (caught by isActuallyPlaying), not .paused.
        if delegate.isRecentlyPlaying {
            refreshDirectionalPreloads(reason: "primary recently playing", throttle: true)
            return
        }
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

    /// Re-issue or rebuild playback for the visible primary when returning to the feed.
    /// This is a navigation/feed visibility recovery, not an app foreground recovery.
    func requestResumePrimaryPlaybackIfVisible() {
        recoverVisiblePlaybackAfterInterruption(reason: "feedResume", isForegroundRecovery: false)
    }

    /// Foreground recovery can restore the visible player/layer before playback has
    /// actually resumed. Re-send the coordinator-owned play command without waiting
    /// for a scroll event to trigger the normal stall path.
    func requestForegroundAutoplayRetry(reason: String) {
        guard AppDelegate.isVideoInfrastructureReady else {
            print("🎬 [COORD] foreground autoplay retry \(reason): video infrastructure not ready")
            return
        }
        guard !isPlaybackSuppressedByOverlay, isFeedVisible else { return }

        clearFinishedAutoplayGateForForeground()

        guard !visibleVideos.isEmpty else {
            phase = .idle
            primaryVideoId = nil
            currentlyPlayingVideoIds.removeAll()
            return
        }

        if phase == .primaryPlaying,
           let primaryId = primaryVideoId,
           let primary = visibleVideos.first(where: { $0.identifier == primaryId }) {
            guard onScreenMediaCells.isEmpty || onScreenMediaCells.contains(primary.identifier) else {
                phase = .idle
                primaryVideoId = nil
                currentlyPlayingVideoIds.removeAll()
                startPrimaryVideoPlayback()
                return
            }

            guard let delegate = delegate(forIdentifier: primary.identifier) else {
                phase = .idle
                primaryVideoId = nil
                currentlyPlayingVideoIds.removeAll()
                startPrimaryVideoPlayback()
                return
            }

            if delegate.isActuallyPlaying {
                refreshDirectionalPreloads(reason: "foreground autoplay healthy", throttle: true)
                return
            }

            print("🎬 [COORD] foreground autoplay retry \(reason): reissuing play for \(shortMID(primary.videoMid))")
            lastPrimarySwitchTime = Date()
            LocalHTTPServer.shared.setPrimaryMediaID(primary.videoMid)
            delegate.shouldPlayVideo(withMid: primary.videoMid)
            refreshDirectionalPreloads(reason: "foreground autoplay retry \(reason)", throttle: false)
            return
        }

        phase = .idle
        primaryVideoId = nil
        currentlyPlayingVideoIds.removeAll()
        startPrimaryVideoPlayback()
    }

    /// Outcome query for the foreground-recovery watchdog in TweetTableViewController.
    /// Measures the *actual* result of recovery (is a visible video really playing?), not
    /// whether a play command was merely issued. This is what makes the watchdog robust
    /// against the long-background races that command-only retries can't detect.
    enum ForegroundRecoveryStatus {
        case playing      // a visible on-screen video is actually playing — recovery done
        case loading      // play commanded and still loading / recently played — be patient
        case needsRetry   // on-screen but not playing/loading — genuinely stuck, needs a nudge
        case noCandidates // no on-screen videos (geometry likely stale after a long background)
    }

    func foregroundRecoveryStatus() -> ForegroundRecoveryStatus {
        guard !visibleVideos.isEmpty else { return .noCandidates }
        guard let primaryId = primaryVideoId,
              let activeDelegate = delegate(forIdentifier: primaryId) else { return .needsRetry }
        if activeDelegate.isActuallyPlaying { return .playing }
        if activeDelegate.isLoadingForCoordinator || activeDelegate.isRecentlyPlaying { return .loading }
        return .needsRetry
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

        // Clear player/time references to free memory while preserving finished-video gates.
        // Playback positions are preserved in PersistentVideoStateManager.
        VideoStateCache.shared.clearPlaybackCacheForMemoryPressure()

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

    /// Resolve the video URL, media ID, and tweet ID for a VideoPlaybackInfo entry.
    private func resolveVideoURL(_ video: VideoPlaybackInfo) -> (url: URL, mediaID: String, tweetId: String, mediaType: MediaType)? {
        guard let tweet = resolveMediaTweet(video.mediaTweetId),
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
        return (url, attachment.mid, tweet.mid, attachment.type)
    }

    private func resolveMediaTweet(_ tweetId: String) -> Tweet? {
        currentTweets.first(where: { $0.mid == tweetId })
            ?? TweetCacheManager.shared.fetchTweetSync(mid: tweetId)
            ?? Tweet.getInstance(for: tweetId)
    }

    /// Preload video asset without starting playback
    private func preloadVideoAsset(_ video: VideoPlaybackInfo) {
        guard let resolved = resolveVideoURL(video) else { return }
        SharedAssetCache.shared.preloadAsset(for: resolved.url, mediaID: resolved.mediaID, tweetId: resolved.tweetId, mediaType: resolved.mediaType)
    }

    /// Preload video player (asset + AVPlayer) for upcoming video in scroll direction.
    /// The pre-created player will be instantly available when the cell becomes visible.
    private func preloadVideoPlayer(_ video: VideoPlaybackInfo) {
        guard let resolved = resolveVideoURL(video) else { return }
        SharedAssetCache.shared.preloadPlayer(for: resolved.url, mediaID: resolved.mediaID, tweetId: resolved.tweetId, mediaType: resolved.mediaType)
    }

    /// Get up to `count` preloadable videos in the scroll direction that are not currently visible.
    private func getNextVideosInScrollDirection(count: Int) -> [VideoPlaybackInfo] {
        // Use the low-threshold load-visible set so any media already on screen is
        // treated as foreground work. Preload starts after the farthest visible media,
        // so the target may be beyond the adjacent tweet if that tweet is still visible.
        let visibleIndices: [Int]
        if !loadVisibleMediaCells.isEmpty {
            visibleIndices = allVideos.enumerated()
                .filter { loadVisibleMediaCells.contains($0.element.identifier) && $0.element.isInVisibleMediaRange }
                .map { $0.offset }
                .sorted()
        } else if !onScreenMediaCells.isEmpty {
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
        var seenMids = Set<String>()

        func appendIfPreloadable(_ video: VideoPlaybackInfo) {
            guard video.isInVisibleMediaRange,
                  !loadVisibleMediaCells.contains(video.identifier),
                  !onScreenMediaCells.contains(video.identifier),
                  !seenMids.contains(video.videoMid) else { return }
            result.append(video)
            seenMids.insert(video.videoMid)
        }

        if scrollDirection {
            var nextIndex = (visibleIndices.max() ?? 0) + 1
            while nextIndex < allVideos.count && result.count < count {
                appendIfPreloadable(allVideos[nextIndex])
                nextIndex += 1
            }
        } else {
            var prevIndex = (visibleIndices.min() ?? 0) - 1
            while prevIndex >= 0 && result.count < count {
                appendIfPreloadable(allVideos[prevIndex])
                prevIndex -= 1
            }
        }

        return result
    }

    /// Clear preloaded video tracking (called when video list is rebuilt)
    private func clearPreloadedTracking() {
        activePreloadMids.removeAll()
        lastDirectionalPreloadRefreshTime = 0
        SharedAssetCache.shared.updateProtectedPreloadMids([])
    }

    // MARK: - Private Methods

    /// Called when scrolling stops
    private func onScrollStopped() {
        isScrolling = false
    }

    /// Called when scroll starts (scrollViewWillBeginDragging).
    /// Directional preloads are started only after scrolling stops, so cancel stale
    /// off-screen preload work as soon as the user starts moving again.
    func onScrollStarted() {
        isScrolling = true
        let onScreenMids = currentOnScreenVideoMids()
        SharedAssetCache.shared.cancelDirectionalPreloadsForScrollStart(except: onScreenMids)
        activePreloadMids.formIntersection(onScreenMids)
        SharedAssetCache.shared.updateProtectedPreloadMids(activePreloadMids)
    }
    
    /// Called on scroll stop and initial load.
    /// Tracks only the next videos in the scroll direction so stale preloads are easy to cancel.
    func performPreloadOnScrollStop() {
        onScrollStopped()
        promoteForegroundVisibleMedia(reason: "scroll stop")
        if phase == .idle && !visibleVideos.isEmpty {
            scheduleStartPrimary()
        }
        refreshDirectionalPreloads(reason: "scroll stop", throttle: false)
    }

    func canRunDirectionalPreloads() -> Bool {
        guard AppDelegate.isVideoInfrastructureReady,
              isTableViewScrollIdle,
              !isPlaybackSuppressedByOverlay,
              isFeedVisible else { return false }

        guard !visibleVideos.isEmpty else { return true }

        guard phase == .primaryPlaying,
              let primaryId = primaryVideoId,
              let delegate = delegate(forIdentifier: primaryId) else {
            return false
        }

        return delegate.isActuallyPlaying
    }

    private var isTableViewScrollIdle: Bool {
        guard !isScrolling else { return false }
        guard let tableView else { return true }
        return !tableView.isTracking && !tableView.isDragging && !tableView.isDecelerating
    }

    var isFeedScrollIdle: Bool {
        isTableViewScrollIdle
    }

    private func refreshDirectionalPreloads(reason: String, throttle: Bool) {
        guard AppDelegate.isVideoInfrastructureReady else { return }
        guard isTableViewScrollIdle else { return }
        promoteForegroundVisibleMedia(reason: reason)

        guard canRunDirectionalPreloads() else {
            cancelTrackedPreloads(except: currentOnScreenVideoMids(), reason: reason)
            activePreloadMids.removeAll()
            SharedAssetCache.shared.updateProtectedPreloadMids([])
            return
        }

        if throttle {
            let now = CACurrentMediaTime()
            guard now - lastDirectionalPreloadRefreshTime >= directionalPreloadRefreshInterval else { return }
            lastDirectionalPreloadRefreshTime = now
        }

        let preloadCount = max(0, directionalPlayerPreloadCount)
        guard preloadCount > 0 else {
            cancelTrackedPreloads(except: currentOnScreenVideoMids(), reason: reason)
            activePreloadMids.removeAll()
            SharedAssetCache.shared.updateProtectedPreloadMids([])
            return
        }

        let nextVideos = getNextVideosInScrollDirection(count: preloadCount)
        let newPreloadMids = Set(nextVideos.map { $0.videoMid })

        // Keep on-screen work alive, then cancel any older directional preloads.
        let onScreenMids = currentOnScreenVideoMids()
        let newAll = newPreloadMids.union(onScreenMids)
        cancelTrackedPreloads(except: newAll, reason: reason)

        activePreloadMids = newPreloadMids
        SharedAssetCache.shared.updateProtectedPreloadMids(newPreloadMids)

        for video in nextVideos where SharedAssetCache.shared.getCachedPlayer(for: video.videoMid) == nil {
            preloadVideoPlayer(video)
        }

        if !newPreloadMids.isEmpty {
            print("🎬 [COORD] \(reason): preloading \(newPreloadMids.count) directional players")
        }
    }

    private func currentOnScreenVideoMids() -> Set<String> {
        let visibleIdentifiers = loadVisibleMediaCells.isEmpty ? onScreenMediaCells : loadVisibleMediaCells
        return Set(allVideos.filter { visibleIdentifiers.contains($0.identifier) }.map { $0.videoMid })
    }

    private func promoteForegroundVisibleMedia(reason: String) {
        guard !loadVisibleMediaCells.isEmpty else { return }

        let foregroundMids = Set(allVideos.filter {
            loadVisibleMediaCells.contains($0.identifier) && $0.isInVisibleMediaRange
        }.map { $0.videoMid })
        guard !foregroundMids.isEmpty else { return }

        activePreloadMids.subtract(foregroundMids)
        SharedAssetCache.shared.updateProtectedPreloadMids(activePreloadMids)

        for mediaID in foregroundMids {
            SharedAssetCache.shared.promoteForegroundVisibleMedia(mediaID)
        }
    }

    private func cancelTrackedPreloads(except keepMids: Set<String>, reason: String) {
        let staleMids = activePreloadMids.subtracting(keepMids)
        guard !staleMids.isEmpty else { return }

        for mid in staleMids {
            SharedAssetCache.shared.cancelPreloadTask(for: mid)
        }
        activePreloadMids.subtract(staleMids)
        SharedAssetCache.shared.updateProtectedPreloadMids(activePreloadMids)
        print("🎬 [COORD] \(reason): cancelled \(staleMids.count) stale preloads")
    }

    /// Schedule primary video playback.
    /// Fast paths: idle table or cached-ready player → play immediately.
    /// Scroll path for cold players: start a 0.3s timer, then promote the current
    /// visible candidate even if the table is still moving.
    /// Per-candidate: the timer is NOT reset as long as the same video remains the top
    /// candidate. Only resets when the candidate changes.
    private func scheduleStartPrimary() {
        guard let candidate = identifyPrimaryVideo() else { return }
        let topCandidate = candidate.identifier

        // If the table is not moving, there is no visibility churn to absorb.
        // Start immediately so scroll-stop autoplay feels responsive.
        if isTableViewScrollIdle {
            playbackDebounceTimer?.invalidate()
            playbackDebounceTimer = nil
            pendingPrimaryCandidate = nil
            if phase == .idle {
                startPrimaryVideoPlayback()
            }
            return
        }

        // Preserve old UX for already-warmed videos: they can start immediately
        // without showing a blank poster while the user scrolls slowly.
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

        guard AppDelegate.isVideoInfrastructureReady else {
            print("🎬 [COORD] startPrimary: video infrastructure not ready")
            return
        }
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
        let delegateCount = liveDelegateCount

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
        guard let delegate = delegate(forIdentifier: primary.identifier) else {
            print("🎬 [COORD] startPrimary: \(shortMID(primary.videoMid)) has no delegate")
            return
        }

        print("🎬 [COORD] startPrimary: selected \(shortMID(primary.videoMid)) (onScreen=\(onScreenCount), visible=\(visibleCount), scrollDown=\(scrollDirection))")

        // Stop the previous primary video if different
        if let previousPrimaryId = primaryVideoId, previousPrimaryId != primary.identifier {
            if let prevDelegate = self.delegate(forIdentifier: previousPrimaryId),
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
        refreshDirectionalPreloads(reason: "primary selected", throttle: false)
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
            guard delegate(forIdentifier: video.identifier) != nil else { continue }
            if video.identifier == failedPrimaryIdentifier { continue }
            if video.identifier == finishedPrimaryIdentifier { continue }
            if VideoStateCache.shared.isVideoFinished(video.identifier) { continue }
            if video.identifier == primaryBelowContinueIdentifier { continue }
            return video
        }

        return nil
    }

    /// Pause a specific video
    private func pauseVideo(_ video: VideoPlaybackInfo) {
        let videoId = video.identifier
        currentlyPlayingVideoIds.remove(videoId)

        // Direct delegate call — no broadcast notification
        if let delegate = delegate(forIdentifier: video.identifier) {
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
           let delegate = delegate(forIdentifier: primaryId) {
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
            if isVisible,
               candidate.identifier != finishedPrimaryIdentifier,
               !VideoStateCache.shared.isVideoFinished(candidate.identifier) {
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
        if let delegate = delegate(forIdentifier: currentVideo.identifier) {
            delegate.shouldPauseVideo(withMid: currentVideo.videoMid)
        }

        // Set new primary and start playing
        primaryVideoId = nextVideo.identifier
        currentlyPlayingVideoIds = [nextVideo.identifier]
        // Mirror startPrimaryVideoPlayback: clear cancelledMediaID so a preloaded-then-cancelled
        // player can resume downloading immediately without waiting for a new CachingPlayerItem.
        LocalHTTPServer.shared.setPrimaryMediaID(nextVideo.videoMid)

        // Direct delegate call — no broadcast notification
        if let delegate = delegate(forIdentifier: nextVideo.identifier) {
            delegate.shouldPlayVideo(withMid: nextVideo.videoMid)
        }
    }
    
    /// Handle video finished notification.
    /// Match by full identifier (outerTweetId_mediaTweetId_videoMid_attachmentIndex) so the same video in different cells is distinct.
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
                VideoStateCache.shared.markVideoFinished(identifier: primaryId)
                playNextVisibleVideo()
            }
        }
    }
    
    /// Recover visible playback after an interruption (foreground return, overlay
    /// dismiss, programmatic list change). The feed may return from detail/fullscreen
    /// with unchanged visibility but a destroyed AVPlayer, so recovery must re-issue
    /// play even when phase says the old primary is already playing.
    ///
    /// For foreground return this is driven by the owning TweetTableViewController
    /// AFTER it refreshes viewport visibility, so the target selection below sees a
    /// fresh visibleVideos / onScreenMediaCells snapshot.
    func recoverVisiblePlaybackAfterInterruption(reason: String, isForegroundRecovery: Bool) {
        guard !isForegroundRecovery || AppDelegate.isVideoInfrastructureReady else {
            print("🎬 [COORD] foreground recovery \(reason): video infrastructure not ready")
            return
        }

        if isForegroundRecovery {
            clearFinishedAutoplayGateForForeground()
        }

        guard !isPlaybackSuppressedByOverlay,
              isFeedVisible else {
            return
        }

        playbackDebounceTimer?.invalidate()
        playbackDebounceTimer = nil
        pendingPrimaryCandidate = nil

        guard !visibleVideos.isEmpty else {
            currentlyPlayingVideoIds.removeAll()
            primaryVideoId = nil
            phase = .idle
            return
        }

        let currentPrimary = primaryVideoId.flatMap { primaryId in
            visibleVideos.first(where: { $0.identifier == primaryId })
        }
        let target: VideoPlaybackInfo
        if let currentPrimary,
           let currentIndex = visibleVideos.firstIndex(where: { $0.identifier == currentPrimary.identifier }),
           currentIndex == 0 || visibleVideos.count == 1 {
            target = currentPrimary
        } else {
            target = visibleVideos[0]
        }

        if !onScreenMediaCells.isEmpty, !onScreenMediaCells.contains(target.identifier) {
            phase = .idle
            primaryVideoId = nil
            currentlyPlayingVideoIds.removeAll()
            startPrimaryVideoPlayback()
            return
        }

        guard let delegate = delegate(forIdentifier: target.identifier) else {
            phase = .idle
            primaryVideoId = nil
            currentlyPlayingVideoIds.removeAll()
            startPrimaryVideoPlayback()
            return
        }

        for video in visibleVideos where video.identifier != target.identifier {
            pauseVideo(video)
        }

        phase = .primaryPlaying
        primaryVideoId = target.identifier
        currentlyPlayingVideoIds = [target.identifier]
        cachedVisibilityRatios[target.identifier] = 0.7
        lastPrimarySwitchTime = Date()
        LocalHTTPServer.shared.setPrimaryMediaID(target.videoMid)
        delegate.shouldPlayVideo(withMid: target.videoMid)
        let preloadReason = isForegroundRecovery ? "foreground recovery \(reason)" : reason
        refreshDirectionalPreloads(reason: preloadReason, throttle: false)
    }

    /// Foreground return is a fresh autoplay decision for whatever is onscreen.
    /// Normal finish handling still advances to the next video; this only removes
    /// the finished gate when the app itself comes back and recomputes visibility.
    private func clearFinishedAutoplayGateForForeground() {
        let candidates = visibleVideos.filter { video in
            onScreenMediaCells.isEmpty || onScreenMediaCells.contains(video.identifier)
        }
        guard !candidates.isEmpty else { return }

        for video in candidates {
            VideoStateCache.shared.clearVideoFinished(video.identifier)
        }

        if let finishedId = finishedPrimaryIdentifier,
           candidates.contains(where: { $0.identifier == finishedId }) {
            finishedPrimaryIdentifier = nil
        }
    }
}
