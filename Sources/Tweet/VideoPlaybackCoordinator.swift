//
//  VideoPlaybackCoordinator.swift
//  Tweet
//
//  SIMPLE STRATEGY: Play topmost fully visible video, stop all others, advance when finished
//
//  ARCHITECTURE:
//  - Find topmost FULLY visible video
//  - Play it, stop all others
//  - When it finishes, play next visible video
//  - Repeat
//
//  TWO PLAYBACK SYSTEMS:
//  1. COORDINATED (This coordinator): Regular tweets, retweets, embedded videos in quoted tweets
//  2. INDEPENDENT (MediaCell): Reserved for future use (e.g., picture-in-picture)
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

/// Video context type
enum VideoContext {
    case regular        // Main tweet video - coordinated
    case retweet       // Retweet video - coordinated
    case quoted        // Quoted embed - independent
    case embedded      // Detail embed - independent
}

/// Video tracking info
struct VideoPlaybackInfo: Equatable {
    let tweetId: String
    let videoMid: String
    let index: Int
    let context: VideoContext
    
    var identifier: String {
        "\(tweetId)_\(videoMid)"
    }
    
    var shouldCoordinate: Bool {
        context == .regular || context == .retweet || context == .embedded
    }
    
    static func == (lhs: VideoPlaybackInfo, rhs: VideoPlaybackInfo) -> Bool {
        lhs.identifier == rhs.identifier
    }
}

/// Simple video coordinator: Play topmost fully visible video
@MainActor
class VideoPlaybackCoordinator: ObservableObject {
    static let shared = VideoPlaybackCoordinator()
    
    // MARK: - State
    
    /// Currently playing video (only one at a time)
    @Published private(set) var currentlyPlayingVideoId: String?
    
    /// Visible tweet IDs
    private var visibleTweetIds: Set<String> = []
    
    /// All coordinated videos
    private var allVideos: [VideoPlaybackInfo] = []
    
    /// Visible coordinated videos
    private var visibleVideos: [VideoPlaybackInfo] {
        allVideos.filter { visibleTweetIds.contains($0.tweetId) }
    }
    
    /// Table view for calculations
    private weak var tableView: UITableView?
    
    /// Scroll to tweet callback (set by TweetTableViewController)
    var scrollToTweetCallback: ((String) -> Bool)?
    
    /// Debounce timer
    private var debounceTimer: Timer?
    
    // MARK: - Init
    
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVideoFinished),
            name: .videoDidFinishPlaying,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInfrastructureChanged),
            name: NSNotification.Name("VideoInfrastructureReadinessChanged"),
            object: nil
        )
    }
    
    @objc private func handleAppDidEnterBackground() {
        stopAllVideos()
    }
    
    @objc private func handleInfrastructureChanged(_ notification: Notification) {
        guard let isReady = notification.userInfo?["isReady"] as? Bool else { return }
        
        if !isReady {
            stopAllVideos()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.checkAndPlayTopmost()
            }
        }
    }
    
    // MARK: - Public API
    
    func setTableView(_ tableView: UITableView) {
        self.tableView = tableView
    }
    
    /// Build coordinated video list (filters out embedded videos)
    func buildVideoList(from tweets: [Tweet], pinnedTweets: [Tweet] = []) {
        var videos: [VideoPlaybackInfo] = []
        var seen = Set<String>()
        
        // Process pinned tweets
        for tweet in pinnedTweets {
            processVideos(from: tweet, into: &videos, seen: &seen)
        }
        
        // Process regular tweets
        for tweet in tweets {
            processVideos(from: tweet, into: &videos, seen: &seen)
        }
        
        self.allVideos = videos.filter { $0.shouldCoordinate }
        
        print("🎬 [VideoCoordinator] Built list: \(allVideos.count) coordinated videos")
        for (index, video) in allVideos.enumerated() {
            print("🎬 [VideoCoordinator]   [\(index)] \(video.videoMid) - context: \(video.context)")
        }
        
        // Share with fullscreen manager
        FullScreenVideoManager.shared.updateVideoList(videos: allVideos, tweets: tweets)
    }
    
    /// Process videos from a tweet
    private func processVideos(from tweet: Tweet, into videos: inout [VideoPlaybackInfo], seen: inout Set<String>) {
        let hasContent = tweet.attachments != nil && !(tweet.attachments?.isEmpty ?? true)
        let hasOriginal = tweet.originalTweetId != nil
        
        if hasOriginal && !hasContent {
            // Pure retweet - get original videos
            print("🔍 [VideoCoordinator] Processing pure retweet: \(tweet.mid)")
            if let originalId = tweet.originalTweetId,
               let original = Tweet.getInstance(for: originalId) ?? TweetCacheManager.shared.fetchTweetSync(mid: originalId),
               let attachments = original.attachments {
                print("🔍 [VideoCoordinator]   Found \(attachments.count) attachments in original tweet")
                addVideos(attachments, tweetId: tweet.mid, context: .retweet, to: &videos, seen: &seen)
            }
        } else if hasOriginal && hasContent {
            // Quoted tweet - add BOTH main body AND embedded videos
            print("🔍 [VideoCoordinator] Processing quoted tweet: \(tweet.mid)")
            if let attachments = tweet.attachments {
                print("🔍 [VideoCoordinator]   Found \(attachments.count) main body attachments")
                addVideos(attachments, tweetId: tweet.mid, context: .regular, to: &videos, seen: &seen)
            }
            // Also add embedded quoted video
            if let originalId = tweet.originalTweetId,
               let original = Tweet.getInstance(for: originalId) ?? TweetCacheManager.shared.fetchTweetSync(mid: originalId),
               let attachments = original.attachments {
                print("🔍 [VideoCoordinator]   Found \(attachments.count) embedded attachments in quoted original")
                addVideos(attachments, tweetId: tweet.mid, context: .embedded, to: &videos, seen: &seen)
            }
        } else {
            // Regular tweet - all videos
            if let attachments = tweet.attachments {
                addVideos(attachments, tweetId: tweet.mid, context: .regular, to: &videos, seen: &seen)
            }
        }
    }
    
    /// Add videos from attachments
    private func addVideos(_ attachments: [MimeiFileType], tweetId: String, context: VideoContext, to videos: inout [VideoPlaybackInfo], seen: inout Set<String>) {
        for (index, attachment) in attachments.enumerated() {
            if attachment.type == .video || attachment.type == .hls_video {
                let info = VideoPlaybackInfo(
                    tweetId: tweetId,
                    videoMid: attachment.mid,
                    index: index,
                    context: context
                )
                
                if !seen.contains(info.identifier) {
                    videos.append(info)
                    seen.insert(info.identifier)
                    print("🔍 [VideoCoordinator]     ✅ Added video: \(attachment.mid) (context: \(context))")
                } else {
                    print("🔍 [VideoCoordinator]     ⏭️ Skipped duplicate: \(attachment.mid) (context: \(context))")
                }
            }
        }
    }
    
    /// Update visible tweets
    func updateVisibleTweets(_ tweetIds: Set<String>) {
        self.visibleTweetIds = tweetIds
        
        // Debounce (0.1s)
        debounceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.checkAndPlayTopmost()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        debounceTimer = timer
    }
    
    /// Stop all videos
    func stopAllVideos() {
        debounceTimer?.invalidate()
        currentlyPlayingVideoId = nil
        NotificationCenter.default.post(name: .shouldStopAllVideos, object: nil)
    }
    
    // MARK: - Private Logic
    
    /// Check visibility and play topmost sufficiently visible video
    private func checkAndPlayTopmost() {
        guard !visibleVideos.isEmpty else {
            stopAllVideos()
            return
        }
        
        guard let topVideo = findTopmostFullyVisibleVideo() else {
            // No video meets visibility threshold - stop playing
            if currentlyPlayingVideoId != nil {
                print("⏹️ [VideoCoordinator] No video meets visibility threshold - stopping")
                stopAllVideos()
            }
            return
        }
        
        // Already playing this video?
        if currentlyPlayingVideoId == topVideo.identifier {
            return
        }
        
        // CRITICAL: If we're currently playing ANY video and it's still sufficiently visible,
        // don't switch videos. Let playNextVideo() handle sequencing.
        if let currentId = currentlyPlayingVideoId {
            // Check if current video still meets visibility threshold
            if isVideoSufficientlyVisible(videoId: currentId) {
                print("⏭️ [VideoCoordinator] Video \(currentId) still playing and sufficiently visible - not switching")
                return
            } else {
                print("⏹️ [VideoCoordinator] Current video \(currentId) no longer sufficiently visible")
            }
        }
        
        playVideo(topVideo)
    }
    
    /// Check if a specific video meets the visibility threshold (at least 60% visible)
    private func isVideoSufficientlyVisible(videoId: String) -> Bool {
        guard let tableView = tableView else { return false }
        
        // Find the video in our list
        guard let video = visibleVideos.first(where: { $0.identifier == videoId }) else {
            return false
        }
        
        // Find the cell
        guard let cell = findCell(for: video.tweetId) else {
            return false
        }
        
        let visibleRect = CGRect(
            x: 0,
            y: tableView.contentOffset.y,
            width: tableView.bounds.width,
            height: tableView.bounds.height
        )
        
        let cellFrame = tableView.convert(cell.frame, to: tableView)
        let intersection = cellFrame.intersection(visibleRect)
        let visibleRatio = intersection.height / cellFrame.height
        
        // Must be at least 60% visible
        return visibleRatio >= 0.60
    }
    
    /// Find topmost sufficiently visible video
    /// A video is considered "visible enough" if at least 60% of its cell is visible
    private func findTopmostFullyVisibleVideo() -> VideoPlaybackInfo? {
        guard let tableView = tableView else {
            return visibleVideos.first
        }
        
        let visibleRect = CGRect(
            x: 0,
            y: tableView.contentOffset.y,
            width: tableView.bounds.width,
            height: tableView.bounds.height
        )
        
        // CRITICAL: Use visibility threshold to prevent premature video switching
        // Video must be at least 60% visible to be considered "ready to play"
        let visibilityThreshold: CGFloat = 0.60
        
        var topmostVideo: VideoPlaybackInfo?
        var topmostY: CGFloat = .infinity
        var topmostRatio: CGFloat = 0
        
        var debugInfo: [(String, CGFloat, CGFloat)] = []
        
        for video in visibleVideos {
            guard let cell = findCell(for: video.tweetId) else { continue }
            let cellFrame = tableView.convert(cell.frame, to: tableView)
            
            // Calculate visible ratio
            let intersection = cellFrame.intersection(visibleRect)
            let visibleRatio = intersection.height / cellFrame.height
            
            debugInfo.append((video.videoMid.prefix(12) + "...", visibleRatio, cellFrame.minY))
            
            // Video must meet visibility threshold
            guard visibleRatio >= visibilityThreshold else { continue }
            
            // Among videos meeting threshold, pick topmost
            // If two videos have similar Y positions (within 50pt), prefer the more visible one
            if cellFrame.minY < topmostY - 50 {
                // This video is clearly higher on screen
                topmostY = cellFrame.minY
                topmostRatio = visibleRatio
                topmostVideo = video
            } else if abs(cellFrame.minY - topmostY) <= 50 && visibleRatio > topmostRatio {
                // Similar position but more visible
                topmostY = cellFrame.minY
                topmostRatio = visibleRatio
                topmostVideo = video
            }
        }
        
        // Debug log (only when finding a new video or no video found)
        if topmostVideo?.identifier != currentlyPlayingVideoId || topmostVideo == nil {
            print("👁️ [VISIBILITY] Checking \(visibleVideos.count) videos:")
            for (mid, ratio, y) in debugInfo.prefix(5) {
                let status = ratio >= visibilityThreshold ? "✅" : "❌"
                print("👁️   \(status) \(mid) - \(Int(ratio * 100))% visible, Y:\(Int(y))")
            }
            if let top = topmostVideo {
                print("👁️ [VISIBILITY] Selected: \(top.videoMid.prefix(12))... (\(Int(topmostRatio * 100))% visible)")
            } else {
                print("👁️ [VISIBILITY] No video meets \(Int(visibilityThreshold * 100))% threshold")
            }
        }
        
        return topmostVideo
    }
    
    /// Find cell for tweet
    private func findCell(for tweetId: String) -> UITableViewCell? {
        guard let tableView = tableView else { return nil }
        
        for cell in tableView.visibleCells {
            if let tweetCell = cell as? TweetTableViewCell,
               tweetCell.tweetId == tweetId {
                return cell
            }
        }
        return nil
    }
    
    /// Play a video (stops all others)
    private func playVideo(_ video: VideoPlaybackInfo) {
        // Stop all others first
        let othersToStop = visibleVideos.filter { $0 != video }
        if !othersToStop.isEmpty {
            print("⏹️ [VideoCoordinator] Stopping \(othersToStop.count) other videos")
            for other in othersToStop {
                print("⏹️ [VideoCoordinator] Stop command sent to: \(other.videoMid)")
                NotificationCenter.default.post(
                    name: .shouldStopVideo,
                    object: nil,
                    userInfo: ["videoMid": other.videoMid]
                )
            }
        }
        
        // Play this one
        currentlyPlayingVideoId = video.identifier
        
        NotificationCenter.default.post(
            name: .shouldPlayVideo,
            object: nil,
            userInfo: [
                "tweetId": video.tweetId,
                "videoMid": video.videoMid,
                "videoIndex": video.index,
                "isMuted": MuteState.shared.isMuted
            ]
        )
        
        print("▶️ [VideoCoordinator] Playing: \(video.videoMid) (context: \(video.context))")
    }
    
    /// Play next video in list
    private func playNextVideo() {
        guard let currentId = currentlyPlayingVideoId else {
            print("⚠️ [VideoCoordinator] playNextVideo() called but no current video - checking topmost")
            checkAndPlayTopmost()
            return
        }
        
        // CRITICAL: Use allVideos index, not visibleVideos
        // visibleVideos can change between calls and cause sequencing issues
        guard let currentIndexInAll = allVideos.firstIndex(where: { $0.identifier == currentId }) else {
            print("⚠️ [VideoCoordinator] Current video not found in allVideos - checking topmost")
            checkAndPlayTopmost()
            return
        }
        
        print("⏭️ [VideoCoordinator] playNextVideo() - current video at index \(currentIndexInAll)/\(allVideos.count)")
        
        let nextIndexInAll = currentIndexInAll + 1
        
        // Check if there's a next video in the list
        guard nextIndexInAll < allVideos.count else {
            print("🏁 [VideoCoordinator] Reached end of all videos - stopping")
            stopAllVideos()
            return
        }
        
        let nextVideo = allVideos[nextIndexInAll]
        
        // CRITICAL: Capture visible videos at this exact moment to avoid race conditions
        let currentVisibleVideos = visibleVideos
        
        print("⏭️ [VideoCoordinator] Next video: \(nextVideo.videoMid) (index \(nextIndexInAll))")
        print("⏭️ [VideoCoordinator] Currently visible: \(currentVisibleVideos.count) videos")
        
        // Only play next video if it's already visible
        if currentVisibleVideos.contains(where: { $0.identifier == nextVideo.identifier }) {
            print("⏭️ [VideoCoordinator] Playing next video - already visible")
            playVideo(nextVideo)
            return
        }

        // Next video not visible - stop all videos (don't force scroll)
        print("⏹️ [VideoCoordinator] Next video not visible - stopping playback")
        stopAllVideos()
    }
    
    /// Scroll to a specific tweet by ID
    /// Returns true if scroll was attempted, false if tweet not found
    private func scrollToTweet(_ tweetId: String) -> Bool {
        guard let tableView = tableView else {
            print("⚠️ [VideoCoordinator] Cannot scroll - no tableView reference")
            return false
        }
        
        // Use the callback if available
        if let callback = scrollToTweetCallback {
            return callback(tweetId)
        }
        
        // Fallback: Check if tweet is already visible
        for cell in tableView.visibleCells {
            if let tweetCell = cell as? TweetTableViewCell,
               tweetCell.tweetId == tweetId,
               let indexPath = tableView.indexPath(for: cell) {
                print("📜 [VideoCoordinator] Tweet already visible, scrolling to center it")
                tableView.scrollToRow(at: indexPath, at: .middle, animated: true)
                return true
            }
        }
        
        print("⚠️ [VideoCoordinator] Tweet not in visible cells and no scroll callback available")
        return false
    }
    
    /// Handle video finished
    @objc private func handleVideoFinished(_ notification: Notification) {
        guard let videoMid = notification.userInfo?["videoMid"] as? String,
              let mode = notification.userInfo?["mode"] as? String,
              mode == "mediaCell" || mode == "embeddedDetail" else {
            return
        }
        
        // Only handle coordinated videos
        guard allVideos.contains(where: { $0.videoMid == videoMid }) else { return }
        
        // Check if it's our current video
        guard let currentId = currentlyPlayingVideoId,
              currentId.contains(videoMid) else { return }
        
        print("✅ [VideoCoordinator] Video finished, playing next")
        playNextVideo()
    }
}
