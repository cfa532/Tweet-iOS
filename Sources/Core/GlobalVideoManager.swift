import Foundation
import SwiftUI
import AVKit

/// Global Video Manager for managing all videos in a TweetListView
/// Handles sequential playback across all MediaGrids and provides centralized video control
class GlobalVideoManager: ObservableObject {
    // MARK: - Published Properties
    @Published var currentPlayingMid: String?
    @Published var isLoading = false
    @Published var loadFailed = false
    
    // MARK: - Private Properties
    private var allVideos: [VideoInfo] = []
    private var currentVideoIndex = 0
    private var isSequentialMode = false
    private var playbackTimer: Timer?
    private var visibilityTimer: Timer?
    
    // MARK: - Video Info Structure
    struct VideoInfo {
        let mid: String
        let url: URL
        let contentType: String
        let gridId: String // Unique identifier for the MediaGrid
        let indexInGrid: Int
        var isVisible = false
        var isLoaded = false
    }
    
    // MARK: - Initialization
    init() {
        print("DEBUG: [GlobalVideoManager] Initialized")
    }
    
    deinit {
        stopAllPlayback()
        print("DEBUG: [GlobalVideoManager] Deinitialized")
    }
    
    // MARK: - Public Methods
    
    /// Register all videos from a MediaGrid
    func registerVideos(from gridId: String, attachments: [MimeiFileType], baseUrl: URL) {
        let videoAttachments = attachments.enumerated().compactMap { index, attachment in
            if attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video" {
                return (index, attachment)
            }
            return nil
        }
        
        for (index, attachment) in videoAttachments {
            if let url = attachment.getUrl(baseUrl) {
                let videoInfo = VideoInfo(
                    mid: attachment.mid,
                    url: url,
                    contentType: attachment.type,
                    gridId: gridId,
                    indexInGrid: index
                )
                
                // Remove any existing video with same MID to avoid duplicates
                allVideos.removeAll { $0.mid == attachment.mid }
                allVideos.append(videoInfo)
                
                print("DEBUG: [GlobalVideoManager] Registered video \(attachment.mid) from grid \(gridId)")
            }
        }
        
        print("DEBUG: [GlobalVideoManager] Total videos registered: \(allVideos.count)")
        
        // Auto-start sequential playback if this is the first set of videos
        if !isSequentialMode && !allVideos.isEmpty {
            startSequentialPlayback()
        }
    }
    
    /// Unregister all videos from a MediaGrid
    func unregisterVideos(from gridId: String) {
        let beforeCount = allVideos.count
        allVideos.removeAll { $0.gridId == gridId }
        let afterCount = allVideos.count
        
        if beforeCount != afterCount {
            print("DEBUG: [GlobalVideoManager] Unregistered \(beforeCount - afterCount) videos from grid \(gridId)")
            print("DEBUG: [GlobalVideoManager] Remaining videos: \(allVideos.count)")
        }
        
        // If current playing video was removed, stop playback
        if let currentMid = currentPlayingMid, !allVideos.contains(where: { $0.mid == currentMid }) {
            stopCurrentPlayback()
        }
    }
    
    /// Set visibility for a specific video
    func setVideoVisibility(mid: String, isVisible: Bool) {
        if let index = allVideos.firstIndex(where: { $0.mid == mid }) {
            allVideos[index].isVisible = isVisible
            
            if isVisible {
                print("DEBUG: [GlobalVideoManager] Video \(mid) became visible")
                handleVideoBecameVisible(mid: mid)
            } else {
                print("DEBUG: [GlobalVideoManager] Video \(mid) became invisible")
                handleVideoBecameInvisible(mid: mid)
            }
        }
    }
    
    /// Check if a video should play
    func shouldPlayVideo(mid: String) -> Bool {
        return currentPlayingMid == mid
    }
    
    /// Check if a video is currently playing
    func isVideoPlaying(mid: String) -> Bool {
        return currentPlayingMid == mid
    }
    
    /// Get the next video to play
    func getNextVideo() -> VideoInfo? {
        guard !allVideos.isEmpty else { return nil }
        
        // Find the next visible video
        let visibleVideos = allVideos.filter { $0.isVisible }
        guard !visibleVideos.isEmpty else { return nil }
        
        if let currentMid = currentPlayingMid,
           let currentIndex = visibleVideos.firstIndex(where: { $0.mid == currentMid }) {
            let nextIndex = (currentIndex + 1) % visibleVideos.count
            return visibleVideos[nextIndex]
        } else {
            // No current video playing, start with the first visible one
            return visibleVideos.first
        }
    }
    
    /// Start sequential playback
    func startSequentialPlayback() {
        guard !allVideos.isEmpty else {
            print("DEBUG: [GlobalVideoManager] No videos to play")
            return
        }
        
        isSequentialMode = true
        print("DEBUG: [GlobalVideoManager] Starting sequential playback")
        
        // Start with the first visible video
        if let nextVideo = getNextVideo() {
            playVideo(mid: nextVideo.mid)
        }
    }
    
    /// Stop all playback
    func stopAllPlayback() {
        print("DEBUG: [GlobalVideoManager] Stopping all playback")
        
        isSequentialMode = false
        currentPlayingMid = nil
        isLoading = false
        loadFailed = false
        
        playbackTimer?.invalidate()
        playbackTimer = nil
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        
        // Notify all videos to stop
        NotificationCenter.default.post(name: .stopAllVideoPlayback, object: nil)
    }
    
    /// Handle video finished playing
    func onVideoFinished(mid: String) {
        print("DEBUG: [GlobalVideoManager] Video \(mid) finished playing")
        
        if isSequentialMode {
            // Schedule next video
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let nextVideo = self.getNextVideo() {
                    self.playVideo(mid: nextVideo.mid)
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func playVideo(mid: String) {
        guard allVideos.first(where: { $0.mid == mid }) != nil else {
            print("DEBUG: [GlobalVideoManager] Video \(mid) not found")
            return
        }
        
        print("DEBUG: [GlobalVideoManager] Playing video \(mid)")
        currentPlayingMid = mid
        isLoading = true
        loadFailed = false
        
        // Notify the specific video to start playing
        NotificationCenter.default.post(
            name: .playSpecificVideo,
            object: nil,
            userInfo: ["mid": mid]
        )
    }
    
    private func stopCurrentPlayback() {
        print("DEBUG: [GlobalVideoManager] Stopping current playback")
        currentPlayingMid = nil
        isLoading = false
        loadFailed = false
    }
    
    private func handleVideoBecameVisible(mid: String) {
        // If no video is currently playing, start playing this one
        if currentPlayingMid == nil {
            print("DEBUG: [GlobalVideoManager] No video currently playing, starting \(mid)")
            playVideo(mid: mid)
        } else {
            print("DEBUG: [GlobalVideoManager] Video \(currentPlayingMid ?? "unknown") already playing, not starting \(mid)")
        }
    }
    
    private func handleVideoBecameInvisible(mid: String) {
        // If this video was playing, stop it and try to start the next visible one
        if currentPlayingMid == mid {
            print("DEBUG: [GlobalVideoManager] Currently playing video \(mid) became invisible")
            stopCurrentPlayback()
            
            // Try to start the next visible video
            if let nextVideo = getNextVideo() {
                print("DEBUG: [GlobalVideoManager] Starting next visible video: \(nextVideo.mid)")
                playVideo(mid: nextVideo.mid)
            } else {
                print("DEBUG: [GlobalVideoManager] No other visible videos to play")
            }
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let playSpecificVideo = Notification.Name("playSpecificVideo")
    static let stopAllVideoPlayback = Notification.Name("stopAllVideoPlayback")
}
