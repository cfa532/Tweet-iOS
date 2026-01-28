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
    
    /// PERF FIX: Cache for cell lookups to avoid repeated expensive operations
    /// Memory: ~200 bytes per cell reference × 200 = ~40KB (negligible)
    private var cellCache: [String: UITableViewCell] = [:]
    private var lastCacheClearTime: Date = Date()
    private let cellCacheClearInterval: TimeInterval = 15.0 // Clear cache every 15 seconds (increased for better performance)
    private let maxCellCacheSize = 200 // Limit cache to 200 entries (~40KB, allows caching ~2-3 screens of cells)
    
    /// Visible tweet IDs (updated by scroll tracking)
    private var visibleTweetIds: Set<String> = []
    
    /// All videos in the app (ordered by feed, then attachmentIndex).
    private var allVideos: [VideoPlaybackInfo] = []


    /// Store current tweet list for embedded tweet lookup
    private var currentTweets: [Tweet] = []
    
    /// PERF FIX: Cache for visibility ratios to avoid redundant calculations
    /// Memory: ~100 bytes per ratio × 500 = ~50KB (negligible)
    private var cachedVisibilityRatios: [String: CGFloat] = [:]
    private let visibilityRatioThreshold: CGFloat = 0.10 // Only update if ratio changes by 10% (more responsive, reduced from 15%)
    private let maxVisibilityRatioCacheSize = 500 // Limit cache to 500 entries (~50KB, allows tracking many videos during long scrolls)
    
    /// PERF FIX: Debounce timer for visibility checks to reduce expensive calculations
    private var visibilityCheckDebounceTimer: Timer?
    private let visibilityCheckDebounceInterval: TimeInterval = 0.10 // 100ms debounce (reduced from 150ms for better responsiveness)

    /// PERF FIX: Batch visibility updates to reduce expensive filtering/sorting operations
    /// Reduced to 150ms for more responsive playback during scrolling
    private var visibilityUpdateDebounceTimer: Timer?
    private let visibilityUpdateDebounceInterval: TimeInterval = 0.05 // Reduced from 150ms for faster video starts
    
    /// Timer for scroll stop detection
    private var scrollStopTimer: Timer?
    
    /// Timer for survey phase (kept for compatibility)
    private var surveyTimer: Timer?

    /// Throttle timer for immediate primary video checks during scroll (50ms throttle)
    private var immediateCheckThrottleTimer: Timer?

    /// Last time we preloaded videos during scroll (for throttling)
    private var lastScrollPreloadTime: Date?
    private let scrollPreloadThrottleInterval: TimeInterval = 0.3 // Preload at most every 300ms during scroll

    /// Track which videos have been preloaded to avoid duplicate preloads
    private var preloadedVideoMids: Set<String> = []

    /// Background queue for expensive visibility calculations to avoid blocking main thread
    private let visibilityCalculationQueue = DispatchQueue(label: "com.tweet.VideoPlaybackCoordinator.visibility", qos: .userInitiated)

    /// Track async tasks to prevent leaks
    /// MEMORY FIX: Use UUID-based tracking so tasks can remove themselves on completion
    private nonisolated(unsafe) var activeAsyncTaskIds: Set<UUID> = []
    private let taskCleanupLock = NSLock()
    private let maxConcurrentTasks = 10  // Increased limit since we properly clean up now

    // MARK: - Delegate-Based Communication (Phase 3)

    /// Registered MediaCell delegates for direct communication (keyed by videoMid)
    private var mediaCellDelegates: [String: MediaCellDelegate] = [:]

    /// When true, the feed is covered by an overlay (fullscreen cover/sheet/login/etc).
    /// The coordinator must not emit play commands while covered, otherwise videos can start "invisibly".
    private var isPlaybackSuppressedByOverlay: Bool = false

    /// Track an async task for proper cleanup
    /// MEMORY FIX: Tasks now self-remove on completion via UUID tracking
    private nonisolated func trackAsyncTask(_ task: Task<Void, Never>) {
        let taskId = UUID()

        taskCleanupLock.lock()

        // If we're at the limit, don't add more (let natural completion clean up)
        if activeAsyncTaskIds.count >= maxConcurrentTasks {
            taskCleanupLock.unlock()
            print("⚠️ [TASK LIMIT] Hit max \(maxConcurrentTasks) tasks, skipping new task")
            return
        }

        activeAsyncTaskIds.insert(taskId)
        taskCleanupLock.unlock()

        // Self-cleaning wrapper: remove taskId when original task completes
        Task { [weak self] in
            // Wait for the tracked task to complete
            _ = await task.value

            // Remove from tracking set
            self?.taskCleanupLock.lock()
            self?.activeAsyncTaskIds.remove(taskId)
            self?.taskCleanupLock.unlock()
        }
    }

    /// Cancel all active async tasks (clears tracking set)
    private nonisolated func cancelActiveAsyncTasks() {
        taskCleanupLock.lock()
        defer { taskCleanupLock.unlock() }

        // We can only clear our tracking - actual task cancellation happens via other mechanisms
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

    /// PERF FIX: Async cell visibility calculation to avoid blocking main thread
    /// Captures UI state on main thread, then calculates visibility ratios in background
    private func calculateCellVisibilityAsync() async -> [String: CGFloat] {
        guard let tableView = tableView, tableView.window != nil else {
            return [:]
        }

        // Capture UI state on main thread to avoid Main Thread Checker violations
        let uiState = await MainActor.run {
            // Update cell cache with fresh cell references
            for cell in tableView.visibleCells {
                guard let tweetCell = cell as? TweetTableViewCell,
                      let tweetId = tweetCell.tweetId else { continue }
                self.cellCache[tweetId] = cell
            }

            // Use safeAreaInsets (not adjustedContentInset) to get actual visible area
            // adjustedContentInset includes custom contentInset which would be wrong
            let topInset = tableView.safeAreaInsets.top
            let bottomInset = tableView.safeAreaInsets.bottom

            return (
                visibleRect: CGRect(
                    x: 0,
                    y: tableView.contentOffset.y + topInset,
                    width: tableView.bounds.width,
                    height: tableView.bounds.height - topInset - bottomInset
                ),
                cellFrames: tableView.visibleCells.compactMap { cell -> (tweetId: String, frame: CGRect)? in
                    guard let tweetCell = cell as? TweetTableViewCell,
                          let tweetId = tweetCell.tweetId else { return nil }
                    return (tweetId: tweetId, frame: cell.frame)
                }
            )
        }

        // Perform calculations on background thread
        return await withCheckedContinuation { continuation in
            visibilityCalculationQueue.async {
                var visibilityRatios: [String: CGFloat] = [:]

                // Calculate visibility for all captured cells
                for (tweetId, cellFrame) in uiState.cellFrames {
                    let intersection = cellFrame.intersection(uiState.visibleRect)
                    let ratio = cellFrame.height > 0 ? intersection.height / cellFrame.height : 0
                    visibilityRatios[tweetId] = ratio
                }

                continuation.resume(returning: visibilityRatios)
            }
        }
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
        scrollStopTimer?.invalidate()
        surveyTimer?.invalidate()
        visibilityCheckDebounceTimer?.invalidate()
        visibilityUpdateDebounceTimer?.invalidate()
        overlayUncoverPlaybackTimer?.invalidate()
        immediateCheckThrottleTimer?.invalidate()
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
    
    /// Clear stale caches to prevent unbounded growth during fast scrolling
    /// 
    /// Memory targets (for 1GB normal usage, 2GB max):
    /// - cellCache: ~40KB (200 entries × 200 bytes)
    /// - cachedVisibilityRatios: ~50KB (500 entries × 100 bytes)
    /// - Total coordinator cache overhead: ~90KB (negligible)
    ///
    /// The real memory usage comes from:
    /// - Video player buffers: ~50-100MB per active video
    /// - Image caches: ~200-500MB
    /// - Tweet data: ~50-100MB
    /// Total typical: ~400-700MB, leaves comfortable headroom under 1GB target
    private func clearStaleCache() {
        let now = Date()
        
        // Time-based clearing: Every 15 seconds to allow better caching during normal scrolling
        // This balances memory vs performance - cells stay cached longer for smoother re-renders
        if now.timeIntervalSince(lastCacheClearTime) > cellCacheClearInterval {
            cellCache.removeAll()
            lastCacheClearTime = now
        }
        
        // Size-based clearing for cell cache
        // At 200 entries, we're only using ~40KB - this is a safety limit, not a memory concern
        if cellCache.count > maxCellCacheSize {
            // Remove oldest entries (simple approach: clear all when limit exceeded)
            // This rarely happens in practice since time-based clearing occurs first
            cellCache.removeAll()
            lastCacheClearTime = now
        }
        
        // Smart clearing for visibility ratios (keep only visible videos)
        // At 500 entries (~50KB), this is still negligible memory
        // But we prune to keep the cache relevant and lookup performance fast
        if cachedVisibilityRatios.count > maxVisibilityRatioCacheSize {
            // Keep only entries for currently visible videos
            let visibleVideoIds = Set(visibleVideos.map { $0.identifier })
            cachedVisibilityRatios = cachedVisibilityRatios.filter { visibleVideoIds.contains($0.key) }
        }
    }

    // MARK: - Delegate Management (Phase 3)

    /// Register a MediaCell delegate for video control
    func registerDelegate(_ delegate: MediaCellDelegate, forVideoMid videoMid: String) {
        mediaCellDelegates[videoMid] = delegate
    }

    /// Unregister a MediaCell delegate
    func unregisterDelegate(forVideoMid videoMid: String) {
        mediaCellDelegates.removeValue(forKey: videoMid)
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
    func buildVideoList(from tweets: [Tweet], pinnedTweets: [Tweet] = []) {
        // Run expensive operation in background
        Task.detached(priority: .userInitiated) {
            let videos = await self.buildVideoListAsync(tweets: tweets, pinnedTweets: pinnedTweets)
            
            // Update state on main actor
            await MainActor.run {
                self.allVideos = videos

                // PERF FIX: Clear caches when video list is rebuilt to prevent stale data
                self.cellCache.removeAll()
                self.cachedVisibilityRatios.removeAll()
                self.invalidateVisibleVideoCache() // Clear visible videos cache
                self.clearPreloadedTracking() // Clear preload tracking for fresh list
                self.lastCacheClearTime = Date()

                // Store tweet list for embedded tweet lookup
                self.currentTweets = pinnedTweets + tweets

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
    
    /// Previously visible video IDs (to detect actual video changes, not just tweet changes)
    private var previousVisibleVideoIds: Set<String> = []
    
    /// Update visible tweets (called during scrolling)
    func updateVisibleTweets(_ tweetIds: Set<String>) {
        // Safety check: Verify overlay coordinator consistency
        // This helps detect and fix stuck overlay state
        OverlayVisibilityCoordinator.shared.verifyConsistency(source: "VideoPlaybackCoordinator.updateVisibleTweets")
        
        // Track scroll direction based on content offset
        if let tableView = tableView, tableView.window != nil {
            let currentOffset = tableView.contentOffset.y
            if previousContentOffset != 0 {
                // Determine scroll direction: true = scrolling down, false = scrolling up
                let newDirection = currentOffset > previousContentOffset
                let directionChanged = newDirection != scrollDirection
                scrollDirection = newDirection

                // Preload videos in scroll direction when direction changes or periodically
                if directionChanged || shouldTriggerScrollPreload() {
                    preloadVideosInScrollDirection()
                }
            }
            previousContentOffset = currentOffset
        }
        // CRITICAL: Only consider feed-visible video entries (MediaGrid only shows first 4 attachments).
        // The canonical list can include attachmentIndex > 3 for fullscreen, but those must not affect feed playback.
        let tweetsWithFeedVideos = Set(allVideos.filter { $0.isInVisibleMediaRange }.map { $0.cellTweetId })
        let filteredTweetIds = tweetIds.intersection(tweetsWithFeedVideos)
        
        self.visibleTweetIds = filteredTweetIds
        self.invalidateVisibleVideoCache() // Invalidate cache when visible tweets change
        self.isScrolling = true
        
        // Get current visible video IDs
        let currentVisibleVideoIds = Set(visibleVideos.map { $0.videoMid })
        let videoVisibilityChanged = previousVisibleVideoIds != currentVisibleVideoIds

        // Check for visibility threshold crossings to trigger immediate primary video checks
        // This makes playback responsive even during scrolling
        var thresholdCrossed = false
        for video in visibleVideos {
            let currentRatio = cachedVisibilityRatios[video.identifier] ?? 1.0
            let previousRatio = previousVisibleVideoIds.contains(video.videoMid) ? (cachedVisibilityRatios[video.identifier] ?? 0.0) : 0.0

            // Check if this video crossed the 50% threshold
            let crossedThreshold = (previousRatio < 0.5 && currentRatio >= 0.5) ||
                                   (previousRatio >= 0.5 && currentRatio < 0.5)
            if crossedThreshold {
                thresholdCrossed = true
                break
            }
        }

        // Android-style immediate scroll responses (50ms throttle)
        if thresholdCrossed {
            // Throttle immediate checks to avoid expensive operations on every update during fast scrolling
            // This keeps scrolling smooth while still being responsive
            immediateCheckThrottleTimer?.invalidate()
            immediateCheckThrottleTimer = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.checkPrimaryVideoDuringScroll()
                }
            }
            RunLoop.main.add(immediateCheckThrottleTimer!, forMode: .common)
        }
        
        // Stop all videos if none are visible
        if currentVisibleVideoIds.isEmpty {
            previousVisibleVideoIds.removeAll()
            stopAllVideos()
            return
        }
        
        // If the feed is covered by an overlay (fullscreen cover/sheet/login/etc), do not start playback.
        // Keep the "previous" snapshot up to date so we don't treat uncover as a visibility change spike.
        if isPlaybackSuppressedByOverlay {
            previousVisibleVideoIds = currentVisibleVideoIds
            return
        }
        
        // Stop videos that are no longer visible
        if videoVisibilityChanged {
            let videosToStop = previousVisibleVideoIds.subtracting(currentVisibleVideoIds)
            if !videosToStop.isEmpty {
                // MEMORY MONITOR: Log when videos are stopped (scrolled out of view)

                // SMART CLEANUP: Only trigger cleanup if we've stopped several videos
                // This prevents excessive cleanup during normal scrolling while still
                // preventing memory accumulation during fast scrolling
                if videosToStop.count >= 3 || scrollDirection == false {
                    // Trigger cleanup when: 3+ videos stopped, or scrolling up (reappearing videos)
                    SharedAssetCache.shared.forceMemoryCleanup()
                }
            }

            for videoMid in videosToStop {
                // PHASE 2: Use SharedVideoPlayerManager for coordinated video control
                if allVideos.first(where: { $0.videoMid == videoMid }) != nil {
                    // Only stop if this video instance is currently managed by SharedVideoPlayerManager
                    if SharedVideoPlayerManager.shared.currentVideoMid == videoMid {
                        SharedVideoPlayerManager.shared.stopCurrentVideo()
                    }
                }
            }

            // PERF FIX: Clear caches for videos that are no longer visible
            // This prevents stale cell references and visibility ratios
            let cellsToRemove = Set(allVideos.filter { videosToStop.contains($0.videoMid) }.map { $0.cellTweetId })
            for cellTweetId in cellsToRemove {
                cellCache.removeValue(forKey: cellTweetId)
                // Clear visibility ratios for all videos in this cell
                for video in allVideos where video.cellTweetId == cellTweetId {
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
                
                // MEMORY FIX: Cancel ALL existing timers before creating new ones
                surveyTimer?.invalidate()
                surveyTimer = nil
                playbackDebounceTimer?.invalidate()
                playbackDebounceTimer = nil
                scrollStopTimer?.invalidate()
                scrollStopTimer = nil
                
                // Android-style deferred batching: Use 150ms intervals for performance
                // Cancel existing debounce timer
                visibilityUpdateDebounceTimer?.invalidate()

                // Start new debounce timer (150ms for Android-style batching)
                visibilityUpdateDebounceTimer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        // Perform batched visibility update (Android-style)
                        self.performBatchedVisibilityUpdate()
                    }
                }
                RunLoop.main.add(visibilityUpdateDebounceTimer!, forMode: .common)

                // Update previous state
                previousVisibleVideoIds = currentVisibleVideoIds
            }
        } else if phase == .idle && !currentVisibleVideoIds.isEmpty {
            // Handle case where videos are visible but we're in idle (initial load or after reset)
            // Use Android-style deferred batching
            visibilityUpdateDebounceTimer?.invalidate()
            visibilityUpdateDebounceTimer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.performBatchedVisibilityUpdate()
                }
            }
            RunLoop.main.add(visibilityUpdateDebounceTimer!, forMode: .common)

            // Update previous state
            previousVisibleVideoIds = currentVisibleVideoIds
        } else {
            // Update previous state for all other cases
            previousVisibleVideoIds = currentVisibleVideoIds
        }
        
        // CRITICAL: Clear preserve flag when user explicitly scrolls
        // This ensures foreground recovery knows user changed context
        shouldPreserveStateOnForeground = false
        
        // MEMORY FIX: REMOVED DUPLICATE timer creation - already handled above
        // The duplicate visibilityUpdateDebounceTimer was causing timer accumulation
    }

    /// Android-style deferred batching for visibility updates (150ms intervals)
    /// This method handles batched visibility updates for performance optimization
    private func performBatchedVisibilityUpdate() {
        // Android-style: Check if primary video needs switching or if playback should start
        guard !isPlaybackSuppressedByOverlay else {
            return
        }

        // MEMORY FIX: Cancel any pending tasks before creating new ones
        // This prevents task accumulation during rapid scroll updates
        cancelActiveAsyncTasks()

        // If we have visible videos but no primary video playing, start playback
        if phase == .idle && !visibleVideos.isEmpty {
            let task = Task { await startPrimaryVideoPlaybackAsync() }
            trackAsyncTask(task)
        }
        // If primary video is playing but might need switching, check it
        else if phase == .primaryPlaying {
            let task = Task { await checkAndSwitchVideoIfNeededAsync() }
            trackAsyncTask(task)
        }
    }

    /// Stop all videos and reset state
    func stopAllVideos() {
        // Cancel all timers to prevent resource accumulation
        surveyTimer?.invalidate()
        surveyTimer = nil

        playbackDebounceTimer?.invalidate()
        playbackDebounceTimer = nil

        scrollStopTimer?.invalidate()
        scrollStopTimer = nil

        // PERF FIX: Cancel visibility check debounce timer
        visibilityCheckDebounceTimer?.invalidate()
        visibilityCheckDebounceTimer = nil

        // Cancel visibility update debounce timer
        visibilityUpdateDebounceTimer?.invalidate()
        visibilityUpdateDebounceTimer = nil

        // Cancel immediate check throttle timer
        immediateCheckThrottleTimer?.invalidate()
        immediateCheckThrottleTimer = nil

        // CRITICAL: Cancel overlay uncover timer to prevent CPU cycles accumulation
        overlayUncoverPlaybackTimer?.invalidate()
        overlayUncoverPlaybackTimer = nil
        
        // PERF FIX: Clear caches to free memory
        cachedVisibilityRatios.removeAll()
        cellCache.removeAll()
        lastCacheClearTime = Date()
        
        // Cancel all active async tasks
        cancelActiveAsyncTasks()

        // Clear state
        currentlyPlayingVideoIds.removeAll()
        primaryVideoId = nil
        phase = .idle

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

    /// Restore visible videos and preload additional videos in scroll direction
    /// Called by TweetTableViewController when app returns to foreground
    /// - Parameters:
    ///   - visibleTweetIds: Currently visible tweet IDs
    ///   - preloadCount: Number of additional videos to preload in scroll direction (default: 4)
    func restoreVisibleAndPreload(visibleTweetIds: Set<String>, preloadCount: Int = 4) {
        print("☀️ [VIDEO MEMORY] Restoring visible videos and preloading \(preloadCount) more")

        // Update visible tweets
        self.visibleTweetIds = visibleTweetIds
        invalidateVisibleVideoCache()

        // Get videos to preload based on scroll direction
        let videosToPreload = getVideosToPreload(visibleTweetIds: visibleTweetIds, preloadCount: preloadCount)

        print("☀️ [VIDEO MEMORY] Will preload \(videosToPreload.count) videos: \(videosToPreload.map { $0.videoMid.prefix(8) })")

        // Preload the videos (just load assets, don't start playback)
        for video in videosToPreload {
            preloadVideoAsset(video)
        }

        // Start playback for visible videos (coordinator will pick the topmost)
        if !visibleVideos.isEmpty && !isPlaybackSuppressedByOverlay {
            // Small delay to allow assets to start loading
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                if self.phase == .idle && !self.visibleVideos.isEmpty {
                    self.startPrimaryVideoPlayback()
                }
            }
        }

        print("✅ [VIDEO MEMORY] Foreground video restoration complete")
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

    /// Clear preloaded video tracking (called when video list is rebuilt)
    private func clearPreloadedTracking() {
        preloadedVideoMids.removeAll()
        lastScrollPreloadTime = nil
    }

    // MARK: - Private Methods

    /// Called when scrolling stops (after 2s delay)
    private func onScrollStopped() {
        isScrolling = false
        // Scroll stop handler is now a no-op since we handle everything via debounce during scroll
        // Videos continue playing through scroll and beyond
    }
    
    /// Synchronous wrapper for startPrimaryVideoPlaybackAsync
    private func startPrimaryVideoPlayback() {
        let task = Task { await startPrimaryVideoPlaybackAsync() }
        trackAsyncTask(task)
    }

    /// Start primary video playback - play topmost video immediately
    /// Start primary video playback
    /// Identifies the most appropriate video based on visibility and scroll direction
    private func startPrimaryVideoPlaybackAsync() async {
        // Never start feed playback while the UI is covered by an overlay.
        guard !isPlaybackSuppressedByOverlay else { return }

        // Guard against starting if not in idle phase
        guard phase == .idle else {
            return
        }

        // Identify topmost video
        guard let primary = await identifyPrimaryVideoAsync() else {
            stopAllVideos()
            return
        }

        // First, stop the previous primary video (use Stop instead of Pause for immediate effect)
        if let previousPrimaryId = primaryVideoId, previousPrimaryId != primary.identifier,
           let previousPrimary = allVideos.first(where: { $0.identifier == previousPrimaryId }) {
            // PHASE 2: Use SharedVideoPlayerManager for coordinated stop
            if SharedVideoPlayerManager.shared.currentVideoMid == previousPrimary.videoMid {
                SharedVideoPlayerManager.shared.stopCurrentVideo()
            }
        }

        // Pause all visible videos except the new primary
        for video in visibleVideos where video != primary {
            // PHASE 2: Use SharedVideoPlayerManager for coordinated pause
            pauseVideo(video)
        }

        // Add a small delay to ensure pause/stop commands are processed before starting new video
        // This prevents multiple videos from playing simultaneously
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Update state to primary phase BEFORE sending play command
            self.phase = .primaryPlaying
            self.primaryVideoId = primary.identifier
            self.currentlyPlayingVideoIds = [primary.identifier]

            // Initialize visibility ratio cache for new primary video to prevent immediate re-switching
            // Use 0.7 (70%) instead of 1.0 to be more realistic and prevent false threshold crossing
            // This prevents the check from thinking visibility "dropped" from 1.0 to actual measured value
            self.cachedVisibilityRatios[primary.identifier] = 0.7

            // Record switch time to prevent immediate re-checking
            self.lastPrimarySwitchTime = Date()

            // PHASE 1: Use SharedVideoPlayerManager for coordinated playback
            // The coordinator identifies which video should play, SharedVideoPlayerManager coordinates the playback
            // Pass full identifier (cellTweetId_videoMid_attachmentIndex) so manager can distinguish instances
            SharedVideoPlayerManager.shared.playVideo(
                videoId: primary.identifier,
                videoMid: primary.videoMid,
                cellTweetId: primary.cellTweetId
            )
        }
    }
    
    /// Async version: Identify the primary video based on scroll direction (Android behavior)
    /// - Scrolling down: topmost video (lowest Y coordinate)
    /// - Scrolling up: bottommost video (highest Y coordinate)
    /// Uses cell visibility (≥50% threshold) for primary selection
    private func identifyPrimaryVideoAsync() async -> VideoPlaybackInfo? {
        guard let tableView = tableView,
              tableView.window != nil else {
            // Fallback: return first visible video if table view not in hierarchy
            return visibleVideos.first
        }

        // Get cell visibility ratios from background thread (also updates cell cache)
        let cellVisibilityRatios = await calculateCellVisibilityAsync()

        if scrollDirection {
            // Scrolling DOWN: Find topmost video that is at least 50% visible
            for video in visibleVideos {
                let visibilityRatio = cellVisibilityRatios[video.cellTweetId] ?? 0
                if visibilityRatio >= 0.5 {
                    return video
                }
            }
            // No video is 50% visible, return first one anyway
            return visibleVideos.first
        } else {
            // Scrolling UP: Find bottommost video (highest Y coordinate) that is at least 50% visible
            for video in visibleVideos.reversed() {
                let visibilityRatio = cellVisibilityRatios[video.cellTweetId] ?? 0
                if visibilityRatio >= 0.5 {
                    return video
                }
            }
            // No video is 50% visible, return last one anyway
            return visibleVideos.last
        }
    }
    
    /// Immediately check and set primary video during scroll when visibility threshold is crossed
    /// This makes playback start immediately even while scrolling, not waiting for debounce
    /// Optimized to avoid expensive operations during fast scrolling
    private func checkPrimaryVideoDuringScroll() {
        // MEMORY FIX: Track this task to prevent accumulation during rapid scrolling
        let task = Task {
            guard let correctPrimary = await identifyPrimaryVideoAsync(), correctPrimary.identifier != primaryVideoId else {
                return
            }

            // Immediately start playback for the new primary video
            let previousPrimaryId = primaryVideoId
            primaryVideoId = correctPrimary.identifier

            // Use DispatchQueue.main.async for immediate response during scroll
            DispatchQueue.main.async {
                // Stop previous primary if different
                if let previousPrimaryId = previousPrimaryId, previousPrimaryId != correctPrimary.identifier,
                   let previousPrimary = self.allVideos.first(where: { $0.identifier == previousPrimaryId }) {
                    // PHASE 2: Use SharedVideoPlayerManager for coordinated stop
                    if SharedVideoPlayerManager.shared.currentVideoMid == previousPrimary.videoMid {
                        SharedVideoPlayerManager.shared.stopCurrentVideo()
                    }
                }

                // Start new primary video immediately
                // PHASE 2: Use SharedVideoPlayerManager for coordinated playback
                SharedVideoPlayerManager.shared.playVideo(
                    videoId: correctPrimary.identifier,
                    videoMid: correctPrimary.videoMid,
                    cellTweetId: correctPrimary.cellTweetId
                )
            }
        }
        trackAsyncTask(task)
    }

    /// Synchronous wrapper for checkAndSwitchVideoIfNeededAsync
    private func checkAndSwitchVideoIfNeeded() {
        let task = Task { await checkAndSwitchVideoIfNeededAsync() }
        trackAsyncTask(task)
    }

    /// Check if current primary video is less than 50% visible and switch to next video if needed
    private func checkAndSwitchVideoIfNeededAsync() async {
        // Enforce cache size limits to prevent unbounded growth
        clearStaleCache()
        
        // Only check during primary playing phase
        guard phase == .primaryPlaying,
              let primaryId = primaryVideoId,
              let tableView = tableView,
              tableView.window != nil else {
            // Skip check if table view not in view hierarchy
            return
        }
        
        // Prevent immediate re-switching after a video becomes primary (prevents glitch when scrolling up)
        // Wait at least 0.2 seconds after a switch before allowing another switch
        // (Reduced from 0.3s for more responsive video switching during fast scrolling)
        if let lastSwitchTime = lastPrimarySwitchTime {
            let timeSinceSwitch = Date().timeIntervalSince(lastSwitchTime)
            if timeSinceSwitch < 0.2 {
                // Too soon after switch - skip check to prevent glitch
                return
            }
        }
        
        // Find current primary video
        guard let currentPrimary = visibleVideos.first(where: { $0.identifier == primaryId }) else {
            return
        }

        // Capture UI state on main thread to avoid Main Thread Checker violations
        let uiState: (visibilityRatio: CGFloat, cellLookupTweetId: String)? = await MainActor.run {
            // PERF FIX: Use cached cell if available, otherwise find and cache it
            let cellLookupTweetId = currentPrimary.cellTweetId
            let cell: UITableViewCell
            if let cachedCell = self.cellCache[cellLookupTweetId] {
                cell = cachedCell
            } else {
                guard let foundCell = self.findCell(forCellTweetId: currentPrimary.cellTweetId, in: tableView) else {
                    // Return early if cell not found - we need to capture this state
                    return nil
                }
                self.cellCache[cellLookupTweetId] = foundCell
                cell = foundCell
            }

            // PERF FIX: Clear cell cache periodically to prevent stale references
            let now = Date()
            if now.timeIntervalSince(self.lastCacheClearTime) > self.cellCacheClearInterval {
                self.cellCache.removeAll()
                self.lastCacheClearTime = now
            }

            // Use safeAreaInsets (not adjustedContentInset) to get actual visible area
            let topInset = tableView.safeAreaInsets.top
            let bottomInset = tableView.safeAreaInsets.bottom

            let visibleRect = CGRect(
                x: 0,
                y: tableView.contentOffset.y + topInset,
                width: tableView.bounds.width,
                height: tableView.bounds.height - topInset - bottomInset
            )

            let cellFrame = tableView.convert(cell.frame, to: tableView)
            let intersection = cellFrame.intersection(visibleRect)

            // Calculate visibility ratio (0.0 = completely out of view, 1.0 = fully visible)
            let visibilityRatio = cellFrame.height > 0 ? intersection.height / cellFrame.height : 0

            return (visibilityRatio: visibilityRatio, cellLookupTweetId: cellLookupTweetId)
        }

        guard let uiState = uiState else { return }

        let visibilityRatio = uiState.visibilityRatio
        
        // PERF FIX: Only proceed if visibility ratio changed significantly or crossed threshold
        let previousRatio = cachedVisibilityRatios[primaryId] ?? 0.7  // Use realistic default, not 1.0
        let ratioChange = abs(visibilityRatio - previousRatio)

        // Update cache
        cachedVisibilityRatios[primaryId] = visibilityRatio
        
        // Only check threshold if ratio changed significantly or crossed the 30% threshold (hysteresis)
        // Changed from 50% to 30% to match the new stopping threshold
        let crossedThreshold = (previousRatio > 0.30 && visibilityRatio <= 0.30) || (previousRatio <= 0.30 && visibilityRatio > 0.30)
        
        guard crossedThreshold || ratioChange >= visibilityRatioThreshold else {
            // No significant change, skip expensive operations
            return
        }
        
        // CRITICAL FIX: Add hysteresis to prevent rapid switching
        // Only switch away from primary if visibility drops below 30% (not 50%)
        // This prevents videos from stopping when they're still quite visible (e.g., 45% visible)
        // The 50% threshold is used for SELECTING primary, but 30% for KEEPING primary
        if visibilityRatio < 0.30 {
            // Re-identify primary video based on current scroll direction
            // This handles both scrolling down (switch to next) and scrolling up (switch to previous)
            let newPrimary = await identifyPrimaryVideoAsync()

            // If no suitable new primary found, or the new primary is the same as current (but current is < 50% visible),
            // stop all playback - don't keep playing a mostly-off-screen video
            guard let newPrimary = newPrimary else {
                stopAllVideos()
                return
            }

            // If the "best" video is still the current one but it's < 50% visible, stop playback
            if newPrimary.identifier == primaryId {
                stopAllVideos()
                return
            }

            // Stop current primary video and pause all other visible videos
            // Also pause the new primary temporarily, then we'll play it after a delay
            DispatchQueue.main.async {
                // Stop the current primary video (use Stop for immediate effect)
                // PHASE 2: Use SharedVideoPlayerManager for coordinated stop
                if SharedVideoPlayerManager.shared.currentVideoMid == currentPrimary.videoMid {
                    SharedVideoPlayerManager.shared.stopCurrentVideo()
                }

                // Pause all other visible videos (including the new primary temporarily)
                self.visibleVideos.forEach { video in
                    if video.identifier != newPrimary.identifier {
                        // PHASE 2: Pause non-primary videos directly (not managed by SharedVideoPlayerManager)
                        // Phase 3: Use delegate instead of notification
                        if let delegate = self.mediaCellDelegates[video.videoMid] {
                            delegate.shouldPauseVideo(withMid: video.videoMid)
                        }
                    }
                }

                // Add a small delay to ensure stop/pause commands are processed before starting new video
                // This prevents multiple videos from playing simultaneously
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    // Switch to new primary video based on scroll direction
                    self.primaryVideoId = newPrimary.identifier
                    self.currentlyPlayingVideoIds = [newPrimary.identifier]

                    // Initialize visibility ratio cache for new primary video to prevent immediate re-switching
                    // Use 0.7 (70%) instead of 1.0 to be more realistic and prevent false threshold crossing
                    self.cachedVisibilityRatios[newPrimary.identifier] = 0.7

                    // Record switch time to prevent immediate re-checking
                    self.lastPrimarySwitchTime = Date()

                    // PHASE 2: Use SharedVideoPlayerManager for coordinated playback
                    SharedVideoPlayerManager.shared.playVideo(
                        videoId: newPrimary.identifier,
                        videoMid: newPrimary.videoMid,
                        cellTweetId: newPrimary.cellTweetId
                    )
                }
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
            // For non-current videos, send direct notification (they're not managed by SharedVideoPlayerManager)
            // Phase 3: Use delegate instead of notification
            if let delegate = mediaCellDelegates[video.videoMid] {
                delegate.shouldPauseVideo(withMid: video.videoMid)
            }
        }
    }

    /// Returns true if the table cell hosting this video is actually visible enough.
    ///
    /// `UITableView.indexPathsForVisibleRows` can include rows that are only a few pixels on-screen.
    /// If we auto-advance into those, the next video will "play" but appear invisible to the user.
    private func isVideoCellVisibleEnough(_ video: VideoPlaybackInfo, minVisibilityRatio: CGFloat = 0.5) -> Bool {
        guard let tableView = tableView, tableView.window != nil else { return false }

        let cellLookupTweetId = video.cellTweetId
        let cell: UITableViewCell
        if let cached = cellCache[cellLookupTweetId] {
            cell = cached
        } else {
            guard let found = findCell(forCellTweetId: video.cellTweetId, in: tableView) else { return false }
            cellCache[cellLookupTweetId] = found
            cell = found
        }

        // Use safeAreaInsets (not adjustedContentInset) to get actual visible area
        let topInset = tableView.safeAreaInsets.top
        let bottomInset = tableView.safeAreaInsets.bottom

        let visibleRect = CGRect(
            x: 0,
            y: tableView.contentOffset.y + topInset,
            width: tableView.bounds.width,
            height: tableView.bounds.height - topInset - bottomInset
        )
        let cellFrame = cell.frame // already in tableView's coordinate space
        let intersection = cellFrame.intersection(visibleRect)
        let ratio = cellFrame.height > 0 ? intersection.height / cellFrame.height : 0
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
        // This prevents it from auto-playing on next foreground recovery
        // PHASE 2: Pause finished video (not managed by SharedVideoPlayerManager anymore)
        // Phase 3: Use delegate instead of notification
        if let delegate = mediaCellDelegates[currentVideo.videoMid] {
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
                            // Phase 3: Use delegate instead of notification
                            if let delegate = mediaCellDelegates[video.videoMid] {
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
            surveyTimer?.invalidate()
            surveyTimer = nil
            playbackDebounceTimer?.invalidate()
            playbackDebounceTimer = nil
            scrollStopTimer?.invalidate()
            scrollStopTimer = nil
            visibilityCheckDebounceTimer?.invalidate()
            visibilityCheckDebounceTimer = nil
            visibilityUpdateDebounceTimer?.invalidate()
            visibilityUpdateDebounceTimer = nil
            immediateCheckThrottleTimer?.invalidate()
            immediateCheckThrottleTimer = nil
            
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
