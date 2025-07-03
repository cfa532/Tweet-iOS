//
//  VideoManager.swift
//  Tweet
//
//  Global video manager to handle scroll-based video stopping
//

import SwiftUI
import AVKit
import AVFoundation

// Global video manager to handle scroll-based video stopping
class VideoManager: ObservableObject {
    static let shared = VideoManager()
    @Published var currentPlayingInstanceId: String? = nil
    private var videoQueue: [String] = [] // Queue of videos waiting to play
    private var autoStartNext: Bool = true // Whether to auto-start next video
    private var visibleVideos: Set<String> = [] // Track which videos are visible (by mid)
    private var lastStartTime: [String: Date] = [:] // Track last start time for each video mid to prevent rapid cycling
    private let startThrottleInterval: TimeInterval = 1.0 // Minimum time between start attempts for same video
    
    private init() {}
    
    func startPlaying(instanceId: String) {
        // instanceId is now the video key (hash of tweet_mid + video_mid)
        let videoKey = instanceId
        
        // Check if we're trying to start the same video too quickly
        if let lastStart = lastStartTime[videoKey],
           Date().timeIntervalSince(lastStart) < startThrottleInterval {
            print("DEBUG: [VIDEO MANAGER] Throttling start for video \(videoKey) - too soon since last start")
            return
        }
        
        // Check if this video is already playing
        if currentPlayingInstanceId == instanceId {
            print("DEBUG: [VIDEO MANAGER] Video \(videoKey) is already playing, ignoring start request")
            return
        }
        
        // Pause any currently playing video
        if let currentId = currentPlayingInstanceId, currentId != instanceId {
            print("DEBUG: [VIDEO MANAGER] Pausing previous video: \(currentId)")
            NotificationCenter.default.post(name: .pauseVideo, object: currentId)
        }
        
        currentPlayingInstanceId = instanceId
        lastStartTime[videoKey] = Date()
        print("DEBUG: [VIDEO MANAGER] Now playing video: \(videoKey)")
        
        // Remove from queue if it was there
        videoQueue.removeAll { $0 == instanceId }
    }
    
    func stopPlaying(instanceId: String) {
        if currentPlayingInstanceId == instanceId {
            currentPlayingInstanceId = nil
            // print("DEBUG: [VIDEO MANAGER] Stopped playing video instance: \(instanceId)")
            
            // Auto-start next visible video if enabled
            if autoStartNext {
                startNextVisibleVideo()
            }
        }
    }
    
    func stopAllVideos() {
        if let currentId = currentPlayingInstanceId {
            // print("DEBUG: [VIDEO MANAGER] Stopping all videos due to scroll - current: \(currentId)")
            NotificationCenter.default.post(name: .pauseVideo, object: currentId)
            currentPlayingInstanceId = nil
        }
        // Clear queue when scrolling
        videoQueue.removeAll()
        // print("DEBUG: [VIDEO MANAGER] Cleared all videos from queue due to scroll")
    }
    
    // Stop all videos when a sheet is presented
    func stopAllVideosForSheet() {
        if let currentId = currentPlayingInstanceId {
            // print("DEBUG: [VIDEO MANAGER] Stopping all videos due to sheet presentation - current: \(currentId)")
            NotificationCenter.default.post(name: .pauseVideo, object: currentId)
            currentPlayingInstanceId = nil
        }
        // Clear queue when sheet is presented
        videoQueue.removeAll()
        // print("DEBUG: [VIDEO MANAGER] Cleared all videos from queue due to sheet presentation")
    }
    
    // Clean up queue and check for next visible video
    func cleanupQueueAndStartNext() {
        removeInvisibleFromQueue()
        if currentPlayingInstanceId == nil && autoStartNext {
            startNextVisibleVideo()
        }
    }
    
    // Get video position for debugging (if needed)
    func getVideoPosition(for instanceId: String) -> CGRect? {
        return nil // No longer tracking positions
    }
    
    // Simple visibility tracking based on onAppear/onDisappear
    // Now handles multiple instances of the same video properly
    func setVideoVisible(_ instanceId: String, isVisible: Bool) {
        // instanceId is the video key (hash of tweet_mid + video_mid)
        let videoKey = instanceId
        
        if isVisible {
            let wasVisible = visibleVideos.contains(videoKey)
            visibleVideos.insert(videoKey)
            
            if !wasVisible {
                print("DEBUG: [VIDEO MANAGER] Video became visible: \(videoKey)")
                
                // If no video is currently playing, try to start this one
                if currentPlayingInstanceId == nil && autoStartNext {
                    print("DEBUG: [VIDEO MANAGER] No video playing, starting newly visible video: \(videoKey)")
                    NotificationCenter.default.post(name: .startVideo, object: videoKey)
                } else if currentPlayingInstanceId == videoKey {
                    print("DEBUG: [VIDEO MANAGER] Video \(videoKey) is already playing, no need to start again")
                } else if currentPlayingInstanceId != nil {
                    print("DEBUG: [VIDEO MANAGER] Another video (\(currentPlayingInstanceId!)) is already playing, adding \(videoKey) to queue")
                    addToQueue(instanceId: videoKey)
                }
            }
        } else {
            let wasVisible = visibleVideos.contains(videoKey)
            visibleVideos.remove(videoKey)
            
            if wasVisible {
                print("DEBUG: [VIDEO MANAGER] Video became invisible: \(videoKey)")
                
                // Remove invisible videos from queue to prevent them from starting
                removeInvisibleFromQueue()
                
                // If the invisible video was playing, stop it and start next
                if currentPlayingInstanceId == videoKey {
                    print("DEBUG: [VIDEO MANAGER] Stopping invisible video: \(videoKey)")
                    NotificationCenter.default.post(name: .pauseVideo, object: videoKey)
                    currentPlayingInstanceId = nil
                    
                    if autoStartNext {
                        startNextVisibleVideo()
                    }
                } else {
                    print("DEBUG: [VIDEO MANAGER] Video \(videoKey) became invisible but was not playing")
                }
            }
        }
    }
    
    // Add video to queue for auto-play (only if visible)
    func addToQueue(instanceId: String) {
        // instanceId is the video key (hash of tweet_mid + video_mid)
        let videoKey = instanceId
        if !videoQueue.contains(videoKey) && currentPlayingInstanceId != videoKey && visibleVideos.contains(videoKey) {
            videoQueue.append(videoKey)
            // print("DEBUG: [VIDEO MANAGER] Added visible video to queue: \(videoKey), queue size: \(videoQueue.count)")
        }
    }
    
    // Remove invisible videos from queue
    func removeInvisibleFromQueue() {
        videoQueue.removeAll { !visibleVideos.contains($0) }
    }
    
    // Start the next visible video in queue
    private func startNextVisibleVideo() {
        // First, clean up any invisible videos from the queue
        removeInvisibleFromQueue()
        
        // Find the first visible video in the queue
        if let nextVideoId = videoQueue.first(where: { visibleVideos.contains($0) }) {
            // Check if this video is already playing
            if currentPlayingInstanceId == nextVideoId {
                print("DEBUG: [VIDEO MANAGER] Video \(nextVideoId) is already playing, skipping start")
                videoQueue.removeAll { $0 == nextVideoId }
                return
            }
            
            // print("DEBUG: [VIDEO MANAGER] Auto-starting next visible video: \(nextVideoId)")
            NotificationCenter.default.post(name: .startVideo, object: nextVideoId)
            videoQueue.removeAll { $0 == nextVideoId }
        } else {
            // print("DEBUG: [VIDEO MANAGER] No visible videos in queue to start")
        }
    }
    
    // Force check all visible videos and start one if none is playing
    func checkAndStartVisibleVideo() {
        // Clean up any invisible videos from the queue
        removeInvisibleFromQueue()
        
        // If no video is currently playing, try to start a visible one
        if currentPlayingInstanceId == nil && autoStartNext {
            // print("DEBUG: [VIDEO MANAGER] No video playing, checking for visible videos to start")
            startNextVisibleVideo()
        }
    }
    
    // Enable/disable auto-start next video
    func setAutoStartNext(_ enabled: Bool) {
        autoStartNext = enabled
        // print("DEBUG: [VIDEO MANAGER] Auto-start next video: \(enabled)")
    }
    
    // Static method to trigger scroll detection from anywhere
    static func triggerScroll() {
        // print("DEBUG: [VIDEO MANAGER] Scroll detected - stopping all videos")
        NotificationCenter.default.post(name: .scrollStarted, object: nil)
    }
    
    // Static method to trigger scroll ended detection
    static func triggerScrollEnded() {
        // print("DEBUG: [VIDEO MANAGER] Scroll ended - checking for visible videos")
        NotificationCenter.default.post(name: .scrollEnded, object: nil)
    }
    
    // Static method to trigger sheet presentation detection
    static func triggerSheetPresentation() {
        // print("DEBUG: [VIDEO MANAGER] Sheet presentation detected - stopping all videos")
        NotificationCenter.default.post(name: .sheetPresented, object: nil)
    }
}
