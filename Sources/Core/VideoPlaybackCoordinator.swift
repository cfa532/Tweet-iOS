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
    private var cellCache: [String: UITableViewCell] = [:]
    private var lastCacheClearTime: Date = Date()
    private let cellCacheClearInterval: TimeInterval = 5.0 // Clear cache every 5 seconds
    
    /// Visible tweet IDs (updated by scroll tracking)
    private var visibleTweetIds: Set<String> = []
    
    /// All videos in the app (ordered by feed, then attachmentIndex).
    private var allVideos: [VideoPlaybackInfo] = []

    /// Track seen video identifiers to prevent duplicates across list updates
    private var seenVideoIdentifiers = Set<String>()

    /// Store current tweet list for embedded tweet lookup
    private var currentTweets: [Tweet] = []
    
    /// PERF FIX: Cache for visibility ratios to avoid redundant calculations
    private var cachedVisibilityRatios: [String: CGFloat] = [:]
    private let visibilityRatioThreshold: CGFloat = 0.15 // Only update if ratio changes by 15%
    
    /// PERF FIX: Debounce timer for visibility checks to reduce expensive calculations
    private var visibilityCheckDebounceTimer: Timer?
    private let visibilityCheckDebounceInterval: TimeInterval = 0.15 // 150ms debounce
    
    /// Timer for scroll stop detection
    private var scrollStopTimer: Timer?
    
    /// Timer for survey phase (kept for compatibility)
    private var surveyTimer: Timer?
    
    /// When true, the feed is covered by an overlay (fullscreen cover/sheet/login/etc).
    /// The coordinator must not emit play commands while covered, otherwise videos can start "invisibly".
    private var isPlaybackSuppressedByOverlay: Bool = false
    
    /// Debounced restart after an overlay is dismissed.
    private var overlayUncoverPlaybackTimer: Timer?

    /// Feed-visible videos (computed from visibleTweetIds + allVideos).
    /// Only includes videos that can actually appear in `MediaGridView` (first 4 attachments).
    /// Sorted by position (topmost cell first; then attachmentIndex within the same cell).
    private var visibleVideos: [VideoPlaybackInfo] {
        let filtered = allVideos.filter { visibleTweetIds.contains($0.cellTweetId) && $0.isInVisibleMediaRange }
        
        // CRITICAL: Sort by position (Y coordinate) to ensure correct playback order
        // This ensures videos play in feed order, not array order
        guard let tableView = tableView, tableView.window != nil else {
            // No table view (or not in hierarchy): do NOT apply any position-based ordering.
            // Keep the coordinator's canonical order (the order `allVideos` was built in).
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
                return filtered
            }
        }
        
        return filtered.sorted { v1, v2 in
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
        
        // Listen for overlay coverage changes (fullscreen cover / sheet / login / share).
        // While covered, we must stop and suppress playback decisions for the feed.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOverlayCoverageChanged),
            name: .overlayCoverageChanged,
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
                guard !self.isPlaybackSuppressedByOverlay else { return }
                guard self.phase == .idle else { return }
                guard !self.visibleVideos.isEmpty else { return }
                guard let tableView = self.tableView, tableView.window != nil else { return }
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
            print("VideoPlaybackCoordinator: Added \(videosToAdd.count) embedded tweet videos, total: \(allVideos.count)")
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
                    if seenVideoIdentifiers.contains(info.identifier) { continue }
                    videosToAdd.append(info)
                    seenVideoIdentifiers.insert(info.identifier)
                }
            }
        }

        if !videosToAdd.isEmpty {
            allVideos.append(contentsOf: videosToAdd)
            print("VideoPlaybackCoordinator: Added \(videosToAdd.count) retweet videos, total: \(allVideos.count)")
        }
    }

    /// Returns true if the canonical list contains the current fullscreen item.
    /// This is used to distinguish "no next video" from "not a feed-backed fullscreen context".
    func containsFullscreenItem(sourceTweetId: String, currentAttachmentIndex: Int, currentVideoMid: String?) -> Bool {
        let mid = currentVideoMid
        return allVideos.contains { v in
            // Prefer matching by sourceTweetId+attachmentIndex; if mid is available, also require it.
            if v.cellTweetId == sourceTweetId && v.attachmentIndex == currentAttachmentIndex {
                return mid.map { v.videoMid == $0 } ?? true
            }
            // Fallback: some callers pass mediaTweetId as sourceTweetId; accept that too.
            if v.mediaTweetId == sourceTweetId && v.attachmentIndex == currentAttachmentIndex {
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
    /// Returns the tweet that owns the attachments (mediaTweet) + the attachment index + the next source tweet id (cell tweet id).
    ///
    /// IMPORTANT: `sourceTweetId` might be the feed cell id (retweet id) OR the media tweet id depending on call site,
    /// so we match both, and also optionally match by `currentVideoMid` for extra resilience.
    func findNextVideoForFullscreen(sourceTweetId: String, currentAttachmentIndex: Int, currentVideoMid: String?) -> (tweet: Tweet, videoIndex: Int, sourceTweetId: String)? {
        // Find the current position in the global list.
        let startIndex: Int?
        let mid = currentVideoMid

        // 1) Exact match on (cellTweetId, attachmentIndex, mid?)
        startIndex = allVideos.firstIndex(where: { v in
            v.cellTweetId == sourceTweetId &&
            v.attachmentIndex == currentAttachmentIndex &&
            (mid.map { v.videoMid == $0 } ?? true)
        })
        // 2) If caller passed mediaTweetId as sourceTweetId, accept that.
        ?? allVideos.firstIndex(where: { v in
            v.mediaTweetId == sourceTweetId &&
            v.attachmentIndex == currentAttachmentIndex &&
            (mid.map { v.videoMid == $0 } ?? true)
        })
        // 3) Match by mid (more stable across retweet/original id mismatches).
        ?? (mid.flatMap { m in
            allVideos.firstIndex(where: { $0.videoMid == m && $0.attachmentIndex == currentAttachmentIndex })
        })
        // 4) Fallback to first video within the source cell/media tweet.
        ?? allVideos.firstIndex(where: { $0.cellTweetId == sourceTweetId })
        ?? allVideos.firstIndex(where: { $0.mediaTweetId == sourceTweetId })

        guard let startIndex else { return nil }

        // Scan forward for the next playable entry (must have a resolvable media tweet with attachments).
        for nextIdx in (startIndex + 1)..<allVideos.count {
            let candidate = allVideos[nextIdx]

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

            return (tweet: mediaTweet, videoIndex: candidate.attachmentIndex, sourceTweetId: candidate.cellTweetId)
        }

        return nil
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
        // CRITICAL: If a pinned tweet appears as embedded elsewhere, skip its standalone videos.
        // Videos should only be indexed at their feed position (where the quoting tweet appears).
        for (_, tweet) in pinnedTweets.enumerated() {
            let shouldSkipStandaloneVideos = embeddedTweetIds.contains(tweet.mid)
            
            if !shouldSkipStandaloneVideos {
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
                        seenVideoIdentifiers.insert(videoInfo.identifier)
                        
                        print("VideoPlaybackCoordinator: Added pinned standalone tweet video - tweetId: \(videoInfo.cellTweetId.prefix(8)), videoMid: \(videoInfo.videoMid.prefix(12)), identifier: \(videoInfo.identifier.prefix(24))")
                    }
                }
            } else {
                print("VideoPlaybackCoordinator: Skipping pinned standalone videos for tweet \(tweet.mid.prefix(8)) - appears embedded elsewhere, videos indexed at quoting tweet position")
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
                // REGULAR TWEET or QUOTED TWEET
                // CRITICAL: If this tweet appears as embedded elsewhere, skip its standalone videos.
                // Videos should only be indexed at their feed position (where the quoting tweet appears),
                // not at the original tweet's standalone position. This ensures correct playback order.
                let shouldSkipStandaloneVideos = embeddedTweetIds.contains(tweet.mid)
                
                if !shouldSkipStandaloneVideos {
                    // Only add standalone videos if this tweet doesn't appear embedded elsewhere
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
                                seenVideoIdentifiers.insert(videoInfo.identifier)
                                
                                print("VideoPlaybackCoordinator: Added standalone tweet video - tweetId: \(videoInfo.cellTweetId.prefix(8)), videoMid: \(videoInfo.videoMid.prefix(12)), identifier: \(videoInfo.identifier.prefix(24))")
                            }
                        }
                    }
                } else {
                    print("VideoPlaybackCoordinator: Skipping standalone videos for tweet \(tweet.mid.prefix(8)) - appears embedded elsewhere, videos indexed at quoting tweet position")
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

                                if seenVideoIdentifiers.contains(videoInfo.identifier) {
                                    print("VideoPlaybackCoordinator: Skipping duplicate embedded video - tweetId: \(tweet.mid.prefix(8)), videoMid: \(attachment.mid.prefix(12)), identifier: \(videoInfo.identifier.prefix(24)) (already seen)")
                                    continue
                                }

                                videos.append(videoInfo)
                                seenVideoIdentifiers.insert(videoInfo.identifier)
                                print("VideoPlaybackCoordinator: Added embedded tweet video - quotingTweetId: \(tweet.mid.prefix(8)), embeddedTweetId: \(originalTweetId.prefix(8)), videoMid: \(attachment.mid.prefix(12)), identifier: \(videoInfo.identifier.prefix(24))")
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
        // IMPORTANT: Fullscreen must NOT use this feed-visible list.
        // Fullscreen builds its own list from tweet attachments (all videos), while the coordinator only tracks on-screen MediaGrid videos.
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
        // CRITICAL: Only consider feed-visible video entries (MediaGrid only shows first 4 attachments).
        // The canonical list can include attachmentIndex > 3 for fullscreen, but those must not affect feed playback.
        let tweetsWithFeedVideos = Set(allVideos.filter { $0.isInVisibleMediaRange }.map { $0.cellTweetId })
        let filteredTweetIds = tweetIds.intersection(tweetsWithFeedVideos)
        
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
        
        // If the feed is covered by an overlay (fullscreen cover/sheet/login/etc), do not start playback.
        // Keep the "previous" snapshot up to date so we don't treat uncover as a visibility change spike.
        if isPlaybackSuppressedByOverlay {
            previousVisibleVideoIds = currentVisibleVideoIds
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
        
        // CRITICAL: Cancel overlay uncover timer to prevent CPU cycles accumulation
        overlayUncoverPlaybackTimer?.invalidate()
        overlayUncoverPlaybackTimer = nil
        
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
        // Never start feed playback while the UI is covered by an overlay.
        guard !isPlaybackSuppressedByOverlay else { return }
        
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
                "tweetId": primary.cellTweetId,
                "videoMid": primary.videoMid,
                "videoIndex": primary.attachmentIndex,
                "isPrimary": true
            ]
        )
    }
    
    /// Identify the primary video based on scroll direction
    /// - Scrolling down: topmost video (lowest Y coordinate)
    /// - Scrolling up: bottommost video (highest Y coordinate)
    /// Note: visibleVideos is already sorted with index as tiebreaker, so we can use simple logic
    private func identifyPrimaryVideo() -> VideoPlaybackInfo? {
        guard let tableView = tableView,
              tableView.window != nil else {
            // Fallback: return first visible video if table view not in hierarchy
            // visibleVideos is already sorted by index within same tweet
            let firstVideo = visibleVideos.first
            if let video = firstVideo {
                print("✅ [PRIMARY SELECT] Fallback selection (no tableView): \(video.videoMid) (cellTweetId: \(video.cellTweetId), attachmentIndex: \(video.attachmentIndex))")
            }
            return firstVideo
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
        
        // CRITICAL: Cache cell visibility by tweetId
        // All videos in the same MediaGrid/cell share the SAME cell visibility
        var cellVisibilityCache: [String: CGFloat] = [:]
        
        if scrollDirection {
            // Scrolling DOWN: Find topmost video that is at least 50% visible
            // CRITICAL: Use CELL visibility for all videos in that cell, not individual video visibility
            for video in visibleVideos {
                let cellLookupTweetId = video.cellTweetId
                
                // Check if we already calculated this cell's visibility
                let visibilityRatio: CGFloat
                if let cached = cellVisibilityCache[cellLookupTweetId] {
                    // Reuse cached cell visibility
                    visibilityRatio = cached
                    print("📋 [CELL VISIBILITY] Using cached visibility for cell \(cellLookupTweetId.prefix(8)): \(String(format: "%.1f", visibilityRatio * 100))%")
                } else {
                    // Calculate cell visibility for the first time
                    let cell: UITableViewCell
                    if let cachedCell = cellCache[cellLookupTweetId] {
                        cell = cachedCell
                    } else {
                        guard let foundCell = findCell(forCellTweetId: video.cellTweetId, in: tableView) else { continue }
                        cellCache[cellLookupTweetId] = foundCell
                        cell = foundCell
                    }
                    
                    let cellFrame = tableView.convert(cell.frame, to: tableView)
                    let intersection = cellFrame.intersection(visibleRect)
                    visibilityRatio = cellFrame.height > 0 ? intersection.height / cellFrame.height : 0
                    
                    // Cache for other videos in same cell
                    cellVisibilityCache[cellLookupTweetId] = visibilityRatio
                    print("📋 [CELL VISIBILITY] Calculated visibility for cell \(cellLookupTweetId.prefix(8)): \(String(format: "%.1f", visibilityRatio * 100))%")
                }
                
                if visibilityRatio >= 0.5 {
                    print("✅ [PRIMARY SELECT] Found 50%+ visible video: \(video.videoMid) (cellTweetId: \(video.cellTweetId.prefix(8)), attachmentIndex: \(video.attachmentIndex), CELL visibility: \(String(format: "%.1f", visibilityRatio * 100))%)")
                    return video
                } else {
                    print("⏭️ [PRIMARY SELECT] Skipping <50% visible: \(video.videoMid) (CELL visibility: \(String(format: "%.1f", visibilityRatio * 100))%)")
                }
            }
            
            // No video is 50% visible, return first one anyway
            let fallback = visibleVideos.first
            if let video = fallback {
                print("⚠️ [PRIMARY SELECT] No 50% visible video, using first: \(video.videoMid) (cellTweetId: \(video.cellTweetId), attachmentIndex: \(video.attachmentIndex))")
            }
            return fallback
        } else {
            // Scrolling UP: Find bottommost video (highest Y coordinate) that is at least 50% visible
            // Iterate from end of sorted array (bottommost first)
            for video in visibleVideos.reversed() {
                let cellLookupTweetId = video.cellTweetId
                let cell: UITableViewCell
                if let cachedCell = cellCache[cellLookupTweetId] {
                    cell = cachedCell
                } else {
                    guard let foundCell = findCell(forCellTweetId: video.cellTweetId, in: tableView) else { continue }
                    cellCache[cellLookupTweetId] = foundCell
                    cell = foundCell
                }
                
                let cellFrame = tableView.convert(cell.frame, to: tableView)
                let intersection = cellFrame.intersection(visibleRect)
                let visibilityRatio = cellFrame.height > 0 ? intersection.height / cellFrame.height : 0
                
                if visibilityRatio >= 0.5 {
                    print("✅ [PRIMARY SELECT] Found 50%+ visible video (scrolling UP): \(video.videoMid) (cellTweetId: \(video.cellTweetId), attachmentIndex: \(video.attachmentIndex), Y: \(cellFrame.minY), visibility: \(String(format: "%.1f", visibilityRatio * 100))%)")
                    return video
                }
            }
            
            // No video is 50% visible, return last one anyway
            let fallback = visibleVideos.last
            if let video = fallback {
                print("⚠️ [PRIMARY SELECT] No 50% visible video (scrolling UP), using last: \(video.videoMid) (cellTweetId: \(video.cellTweetId), attachmentIndex: \(video.attachmentIndex))")
            }
            return fallback
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
        let cellLookupTweetId = currentPrimary.cellTweetId
        let cell: UITableViewCell
        if let cachedCell = cellCache[cellLookupTweetId] {
            cell = cachedCell
        } else {
            guard let foundCell = findCell(forCellTweetId: currentPrimary.cellTweetId, in: tableView) else {
                return
            }
            cellCache[cellLookupTweetId] = foundCell
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
                "tweetId": newPrimary.cellTweetId,
                "videoMid": newPrimary.videoMid,
                "videoIndex": newPrimary.attachmentIndex,
                "isPrimary": true
            ]
        )
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
        
        
        NotificationCenter.default.post(
            name: .shouldPauseVideo,
            object: nil,
            userInfo: [
                "videoMid": video.videoMid
            ]
        )
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

        let visibleRect = CGRect(
            x: 0,
            y: tableView.contentOffset.y,
            width: tableView.bounds.width,
            height: tableView.bounds.height
        )
        let cellFrame = cell.frame // already in tableView's coordinate space
        let intersection = cellFrame.intersection(visibleRect)
        let ratio = cellFrame.height > 0 ? intersection.height / cellFrame.height : 0
        return ratio >= minVisibilityRatio
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

        // IMPORTANT: `indexPathsForVisibleRows` can include rows that are barely visible.
        // When the current video finishes, we should only advance to a video whose cell is
        // sufficiently visible, otherwise it will "autoplay" while appearing invisible.
        let step = scrollDirection ? 1 : -1
        var candidateIndex = targetIndex
        var nextVideo: VideoPlaybackInfo?
        while candidateIndex >= 0 && candidateIndex < visibleVideos.count {
            let candidate = visibleVideos[candidateIndex]
            if isVideoCellVisibleEnough(candidate, minVisibilityRatio: 0.5) {
                nextVideo = candidate
                break
            }
            candidateIndex += step
        }

        guard let nextVideo else {
            print("📹 [VideoPlaybackCoordinator] No sufficiently visible next video to play; stopping")
            stopAllVideos()
            return
        }
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
                "tweetId": nextVideo.cellTweetId,
                "videoMid": nextVideo.videoMid,
                "videoIndex": nextVideo.attachmentIndex,
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
                                "tweetId": firstVideo.cellTweetId,
                                "videoMid": firstVideo.videoMid,
                                "videoIndex": firstVideo.attachmentIndex,
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
                                "tweetId": primary.cellTweetId,
                                "videoMid": primary.videoMid,
                                "videoIndex": primary.attachmentIndex,
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

