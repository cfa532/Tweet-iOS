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
//  1. COORDINATED (This coordinator): Regular tweets, retweets
//  2. INDEPENDENT (MediaCell): Embedded/quoted tweets
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
        context == .regular || context == .retweet
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
        
        // Share with fullscreen manager
        FullScreenVideoManager.shared.updateVideoList(videos: allVideos, tweets: tweets)
    }
    
    /// Process videos from a tweet
    private func processVideos(from tweet: Tweet, into videos: inout [VideoPlaybackInfo], seen: inout Set<String>) {
        let hasContent = tweet.attachments != nil && !(tweet.attachments?.isEmpty ?? true)
        let hasOriginal = tweet.originalTweetId != nil
        
        if hasOriginal && !hasContent {
            // Pure retweet - get original videos
            if let originalId = tweet.originalTweetId,
               let original = Tweet.getInstance(for: originalId) ?? TweetCacheManager.shared.fetchTweetSync(mid: originalId),
               let attachments = original.attachments {
                addVideos(attachments, tweetId: tweet.mid, context: .retweet, to: &videos, seen: &seen)
            }
        } else if hasOriginal && hasContent {
            // Quoted tweet - ONLY main body videos (skip embedded)
            if let attachments = tweet.attachments {
                addVideos(attachments, tweetId: tweet.mid, context: .regular, to: &videos, seen: &seen)
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
                }
            }
        }
    }
    
    /// Update visible tweets
    func updateVisibleTweets(_ tweetIds: Set<String>) {
        self.visibleTweetIds = tweetIds
        
        // Debounce (0.3s)
        debounceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
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
    
    /// Check visibility and play topmost fully visible video
    private func checkAndPlayTopmost() {
        guard !visibleVideos.isEmpty else {
            stopAllVideos()
            return
        }
        
        guard let topVideo = findTopmostFullyVisibleVideo() else {
            return
        }
        
        // Already playing this video?
        if currentlyPlayingVideoId == topVideo.identifier {
            return
        }
        
        playVideo(topVideo)
    }
    
    /// Find topmost FULLY visible video
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
        
        var topmostVideo: VideoPlaybackInfo?
        var topmostY: CGFloat = .infinity
        
        for video in visibleVideos {
            guard let cell = findCell(for: video.tweetId) else { continue }
            let cellFrame = tableView.convert(cell.frame, to: tableView)
            
            // Check if FULLY visible
            let isFullyVisible = visibleRect.contains(cellFrame)
            
            if isFullyVisible && cellFrame.minY < topmostY {
                topmostY = cellFrame.minY
                topmostVideo = video
            }
        }
        
        // No fully visible? Pick most visible
        if topmostVideo == nil {
            var bestVideo: VideoPlaybackInfo?
            var bestRatio: CGFloat = 0
            
            for video in visibleVideos {
                guard let cell = findCell(for: video.tweetId) else { continue }
                let cellFrame = tableView.convert(cell.frame, to: tableView)
                let intersection = cellFrame.intersection(visibleRect)
                let ratio = intersection.height / cellFrame.height
                
                if ratio > bestRatio {
                    bestRatio = ratio
                    bestVideo = video
                }
            }
            
            topmostVideo = bestVideo
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
        // Stop all others
        for other in visibleVideos where other != video {
            NotificationCenter.default.post(
                name: .shouldStopVideo,
                object: nil,
                userInfo: ["videoMid": other.videoMid]
            )
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
        
        print("▶️ [VideoCoordinator] Playing: \(video.videoMid)")
    }
    
    /// Play next video in list
    private func playNextVideo() {
        guard let currentId = currentlyPlayingVideoId,
              let currentIndex = visibleVideos.firstIndex(where: { $0.identifier == currentId }) else {
            checkAndPlayTopmost()
            return
        }
        
        let nextIndex = currentIndex + 1
        
        guard nextIndex < visibleVideos.count else {
            stopAllVideos()
            return
        }
        
        playVideo(visibleVideos[nextIndex])
    }
    
    /// Handle video finished
    @objc private func handleVideoFinished(_ notification: Notification) {
        guard let videoMid = notification.userInfo?["videoMid"] as? String,
              let mode = notification.userInfo?["mode"] as? String,
              mode == "mediaCell" else {
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
