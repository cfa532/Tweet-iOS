//
//  VideoPlaybackCoordinator.swift
//  Tweet
//
//  Coordinates video playback across the app
//  Ensures only one video plays at a time
//
import Foundation
import SwiftUI

/// Notification names for video playback coordination
extension Notification.Name {
    static let shouldPlayVideo = Notification.Name("shouldPlayVideo")
    static let shouldStopAllVideos = Notification.Name("shouldStopAllVideos")
    static let videoDidFinishPlaying = Notification.Name("videoDidFinishPlaying")
}

/// Coordinates video playback to ensure only one video plays at a time
@MainActor
class VideoPlaybackCoordinator: ObservableObject {
    static let shared = VideoPlaybackCoordinator()
    
    /// Currently playing video identifier (tweetId + videoMid)
    @Published private(set) var currentPlayingVideoId: String?
    
    /// Timer for detecting scroll stop
    private var scrollStopTimer: Timer?
    
    /// Visible tweet IDs (updated by scroll tracking)
    private var visibleTweetIds: Set<String> = []
    
    /// All videos in the feed
    private var allVideos: [(tweetId: String, videoMid: String, index: Int)] = []
    
    private init() {
        print("DEBUG: [VideoPlaybackCoordinator] Initialized")
        
        // Listen for video finished notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVideoFinished),
            name: .videoDidFinishPlaying,
            object: nil
        )
    }
    
    /// Build video list from tweets
    func buildVideoList(from tweets: [Tweet]) {
        var videos: [(tweetId: String, videoMid: String, index: Int)] = []
        
        for tweet in tweets {
            guard let attachments = tweet.attachments else { continue }
            
            for (index, attachment) in attachments.enumerated() {
                if attachment.type == .video || attachment.type == .hls_video {
                    videos.append((tweetId: tweet.mid, videoMid: attachment.mid, index: index))
                }
            }
        }
        
        self.allVideos = videos
        print("DEBUG: [VideoPlaybackCoordinator] Built video list: \(videos.count) videos from \(tweets.count) tweets")
    }
    
    /// Update visible tweets (called during scrolling)
    func updateVisibleTweets(_ tweetIds: Set<String>) {
        self.visibleTweetIds = tweetIds
        
        // Stop current video when scrolling starts
        if currentPlayingVideoId != nil {
            stopAllVideos()
        }
        
        // Reset scroll stop timer (0.3s delay before video starts playing)
        scrollStopTimer?.invalidate()
        scrollStopTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.onScrollStopped()
            }
        }
    }
    
    /// Called when scrolling stops
    private func onScrollStopped() {
        print("DEBUG: [VideoPlaybackCoordinator] Scroll stopped, visible tweets: \(visibleTweetIds.count)")
        
        // Find first visible video
        guard let firstVisibleVideo = findFirstVisibleVideo() else {
            print("DEBUG: [VideoPlaybackCoordinator] No visible videos")
            return
        }
        
        // Play the first visible video
        playVideo(tweetId: firstVisibleVideo.tweetId, videoMid: firstVisibleVideo.videoMid, videoIndex: firstVisibleVideo.index)
    }
    
    /// Find first visible video
    private func findFirstVisibleVideo() -> (tweetId: String, videoMid: String, index: Int)? {
        for video in allVideos {
            if visibleTweetIds.contains(video.tweetId) {
                return video
            }
        }
        return nil
    }
    
    /// Play a specific video
    func playVideo(tweetId: String, videoMid: String, videoIndex: Int) {
        let videoId = "\(tweetId)_\(videoMid)"
        
        // Stop current video if different
        if let current = currentPlayingVideoId, current != videoId {
            stopAllVideos()
        }
        
        currentPlayingVideoId = videoId
        
        print("DEBUG: [VideoPlaybackCoordinator] Playing video \(videoMid) in tweet \(tweetId)")
        
        // Notify the video to start playing
        NotificationCenter.default.post(
            name: .shouldPlayVideo,
            object: nil,
            userInfo: [
                "tweetId": tweetId,
                "videoMid": videoMid,
                "videoIndex": videoIndex
            ]
        )
    }
    
    /// Stop all videos
    func stopAllVideos() {
        currentPlayingVideoId = nil
        
        print("DEBUG: [VideoPlaybackCoordinator] Stopping all videos")
        
        NotificationCenter.default.post(name: .shouldStopAllVideos, object: nil)
    }
    
    /// Handle video finished notification
    @objc private func handleVideoFinished(_ notification: Notification) {
        guard let videoMid = notification.userInfo?["videoMid"] as? String else { return }
        
        print("DEBUG: [VideoPlaybackCoordinator] Video finished: \(videoMid)")
        
        // Clear current playing video
        if let current = currentPlayingVideoId, current.contains(videoMid) {
            currentPlayingVideoId = nil
        }
        
        // Don't auto-play next video - wait for user to scroll
    }
}

