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
    @Published var currentPlayingMid: String? = nil // Track which video mid is currently playing
    private var videoQueue: [String] = [] // Queue of videos waiting to play (by mid)
    private var autoStartNext: Bool = true // Whether to auto-start next video
    private var visibleVideos: Set<String> = [] // Track which videos are visible (by mid)
    private var lastStartTime: [String: Date] = [:] // Track last start time for each video mid to prevent rapid cycling
    private let startThrottleInterval: TimeInterval = 1.0 // Minimum time between start attempts for same video
    
    private init() {}
    
    func startPlaying(videoMid: String) {
        // Check if we're trying to start the same video too quickly
        if let lastStart = lastStartTime[videoMid],
           Date().timeIntervalSince(lastStart) < startThrottleInterval {
            print("DEBUG: [VIDEO MANAGER] Throttling start for video mid \(videoMid) - too soon since last start")
            return
        }
        
        // Check if this video is already playing (singleton pattern by mid)
        if currentPlayingMid == videoMid {
            print("DEBUG: [VIDEO MANAGER] Video mid \(videoMid) is already playing, ignoring start request")
            return
        }
        
        // Pause any currently playing video
        if let currentMid = currentPlayingMid, currentMid != videoMid {
            print("DEBUG: [VIDEO MANAGER] Pausing previous video mid: \(currentMid)")
            NotificationCenter.default.post(name: .pauseVideo, object: currentMid)
        }
        
        currentPlayingMid = videoMid
        lastStartTime[videoMid] = Date()
        print("DEBUG: [VIDEO MANAGER] Now playing video mid: \(videoMid)")
        
        // Remove from queue if it was there
        videoQueue.removeAll { $0 == videoMid }
    }
    
    func stopPlaying(videoMid: String) {
        if currentPlayingMid == videoMid {
            currentPlayingMid = nil
            print("DEBUG: [VIDEO MANAGER] Stopped playing video mid: \(videoMid)")
            
            // Auto-start next visible video if enabled
            if autoStartNext {
                startNextVisibleVideo()
            }
        }
    }
    
    func stopAllVideos() {
        if let currentMid = currentPlayingMid {
            print("DEBUG: [VIDEO MANAGER] Stopping all videos due to scroll - current mid: \(currentMid)")
            NotificationCenter.default.post(name: .pauseVideo, object: currentMid)
            currentPlayingMid = nil
        }
        // Clear queue when scrolling
        videoQueue.removeAll()
        print("DEBUG: [VIDEO MANAGER] Cleared all videos from queue due to scroll")
    }
    
    // Stop all videos when a sheet is presented
    func stopAllVideosForSheet() {
        if let currentMid = currentPlayingMid {
            print("DEBUG: [VIDEO MANAGER] Stopping all videos due to sheet presentation - current mid: \(currentMid)")
            NotificationCenter.default.post(name: .pauseVideo, object: currentMid)
            currentPlayingMid = nil
        }
        // Clear queue when sheet is presented
        videoQueue.removeAll()
        print("DEBUG: [VIDEO MANAGER] Cleared all videos from queue due to sheet presentation")
    }
    
    // Clean up queue and check for next visible video
    func cleanupQueueAndStartNext() {
        removeInvisibleFromQueue()
        if currentPlayingMid == nil && autoStartNext {
            startNextVisibleVideo()
        }
    }
    
    // Get video position for debugging (if needed)
    func getVideoPosition(for videoMid: String) -> CGRect? {
        return nil // No longer tracking positions
    }
    
    // Simple visibility tracking based on onAppear/onDisappear
    // Now handles multiple instances of the same video properly using mid as key
    func setVideoVisible(_ videoMid: String, isVisible: Bool) {
        if isVisible {
            let wasVisible = visibleVideos.contains(videoMid)
            visibleVideos.insert(videoMid)
            
            if !wasVisible {
                print("DEBUG: [VIDEO MANAGER] Video mid \(videoMid) became visible")
                
                // If no video is currently playing, try to start this one
                if currentPlayingMid == nil && autoStartNext {
                    print("DEBUG: [VIDEO MANAGER] No video playing, starting newly visible video mid: \(videoMid)")
                    NotificationCenter.default.post(name: .startVideo, object: videoMid)
                } else if currentPlayingMid == videoMid {
                    print("DEBUG: [VIDEO MANAGER] Video mid \(videoMid) is already playing, no need to start again")
                } else if currentPlayingMid != nil {
                    print("DEBUG: [VIDEO MANAGER] Another video mid (\(currentPlayingMid!)) is already playing, adding \(videoMid) to queue")
                    addToQueue(videoMid: videoMid)
                }
            }
        } else {
            let wasVisible = visibleVideos.contains(videoMid)
            
            if wasVisible {
                print("DEBUG: [VIDEO MANAGER] Video mid \(videoMid) became invisible")
                
                // Remove this instance from visible videos
                visibleVideos.remove(videoMid)
                
                // Remove invisible videos from queue to prevent them from starting
                removeInvisibleFromQueue()
                
                // If the invisible video was playing, check if there are other visible videos
                if currentPlayingMid == videoMid {
                    // Check if there are other visible videos to play instead
                    if !visibleVideos.isEmpty {
                        print("DEBUG: [VIDEO MANAGER] Stopping invisible video mid: \(videoMid) and starting next visible video")
                        NotificationCenter.default.post(name: .pauseVideo, object: videoMid)
                        currentPlayingMid = nil
                        
                        if autoStartNext {
                            startNextVisibleVideo()
                        }
                    } else {
                        print("DEBUG: [VIDEO MANAGER] Video mid \(videoMid) became invisible but no other videos are visible, keeping it playing")
                        // Keep the video playing if no other videos are visible
                    }
                } else {
                    print("DEBUG: [VIDEO MANAGER] Video mid \(videoMid) became invisible but was not playing")
                }
            }
        }
    }
    
    // Add video to queue for auto-play (only if visible)
    func addToQueue(videoMid: String) {
        if !videoQueue.contains(videoMid) && currentPlayingMid != videoMid && visibleVideos.contains(videoMid) {
            videoQueue.append(videoMid)
            print("DEBUG: [VIDEO MANAGER] Added visible video mid to queue: \(videoMid), queue size: \(videoQueue.count)")
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
        if let nextVideoMid = videoQueue.first(where: { visibleVideos.contains($0) }) {
            // Check if this video is already playing
            if currentPlayingMid == nextVideoMid {
                print("DEBUG: [VIDEO MANAGER] Video mid \(nextVideoMid) is already playing, skipping start")
                videoQueue.removeAll { $0 == nextVideoMid }
                return
            }
            
            print("DEBUG: [VIDEO MANAGER] Auto-starting next visible video mid: \(nextVideoMid)")
            NotificationCenter.default.post(name: .startVideo, object: nextVideoMid)
            videoQueue.removeAll { $0 == nextVideoMid }
            
            // Set this as the current playing video
            currentPlayingMid = nextVideoMid
        } else {
            print("DEBUG: [VIDEO MANAGER] No visible videos in queue to start")
        }
    }
    
    // Force check all visible videos and start one if none is playing
    func checkAndStartVisibleVideo() {
        // Clean up any invisible videos from the queue
        removeInvisibleFromQueue()
        
        // If no video is currently playing, try to start a visible one
        if currentPlayingMid == nil && autoStartNext {
            print("DEBUG: [VIDEO MANAGER] No video playing, checking for visible videos to start")
            startNextVisibleVideo()
        }
    }
    
    // Enable/disable auto-start next video
    func setAutoStartNext(_ enabled: Bool) {
        autoStartNext = enabled
        print("DEBUG: [VIDEO MANAGER] Auto-start next video: \(enabled)")
    }
    
    // Static method to trigger scroll detection from anywhere
    static func triggerScroll() {
        print("DEBUG: [VIDEO MANAGER] Scroll detected - stopping all videos")
        NotificationCenter.default.post(name: .scrollStarted, object: nil)
    }
    
    // Static method to trigger scroll ended detection
    static func triggerScrollEnded() {
        print("DEBUG: [VIDEO MANAGER] Scroll ended - checking for visible videos")
        NotificationCenter.default.post(name: .scrollEnded, object: nil)
    }
    
    // Static method to trigger sheet presentation detection
    static func triggerSheetPresentation() {
        print("DEBUG: [VIDEO MANAGER] Sheet presentation detected - stopping all videos")
        NotificationCenter.default.post(name: .sheetPresented, object: nil)
    }
}
