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
    private var visibleVideos: Set<String> = [] // Track which videos are visible
    private var videoPositions: [String: CGRect] = [:] // Track video positions on screen
    
    private init() {}
    
    func startPlaying(instanceId: String) {
        // Pause any currently playing video
        if let currentId = currentPlayingInstanceId, currentId != instanceId {
            // print("DEBUG: [VIDEO MANAGER] Pausing previous video instance: \(currentId)")
            NotificationCenter.default.post(name: .pauseVideo, object: currentId)
        }
        
        currentPlayingInstanceId = instanceId
        // print("DEBUG: [VIDEO MANAGER] Now playing video instance: \(instanceId)")
        
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
    
    // Update video position for visibility calculation
    func updateVideoPosition(instanceId: String, frame: CGRect) {
        videoPositions[instanceId] = frame
        // print("DEBUG: [VIDEO MANAGER] Updated position for \(instanceId): \(frame)")
    }
    
    // Check if video is actually visible on screen
    func isVideoActuallyVisible(instanceId: String, screenBounds: CGRect) -> Bool {
        guard let videoFrame = videoPositions[instanceId] else {
            // print("DEBUG: [VIDEO MANAGER] No position data for \(instanceId)")
            return false
        }
        
        // Calculate how much of the video is visible on screen
        let intersection = videoFrame.intersection(screenBounds)
        let visibilityRatio = intersection.width * intersection.height / (videoFrame.width * videoFrame.height)
        
        // Consider video visible if more than 30% is on screen (reduced from 50% for better detection)
        let isVisible = visibilityRatio > 0.3 && intersection.width > 0 && intersection.height > 0
        
        // print("DEBUG: [VIDEO MANAGER] Visibility check for \(instanceId): \(isVisible) (ratio: \(visibilityRatio), frame: \(videoFrame), screen: \(screenBounds), intersection: \(intersection))")
        return isVisible
    }
    
    // Track video visibility based on both isVisible parameter and actual screen position
    func setVideoVisible(_ instanceId: String, isVisible: Bool, screenBounds: CGRect = UIScreen.main.bounds) {
        let actuallyVisible = isVideoActuallyVisible(instanceId: instanceId, screenBounds: screenBounds)
        
        // Video is considered visible if BOTH the isVisible parameter is true AND it's actually on screen
        let shouldBeVisible = isVisible && actuallyVisible
        
        if shouldBeVisible {
            visibleVideos.insert(instanceId)
            // print("DEBUG: [VIDEO MANAGER] Video became visible: \(instanceId) (isVisible: \(isVisible), actuallyVisible: \(actuallyVisible))")
            
            // If no video is currently playing, try to start this one
            if currentPlayingInstanceId == nil && autoStartNext {
                // print("DEBUG: [VIDEO MANAGER] No video playing, starting newly visible video: \(instanceId)")
                NotificationCenter.default.post(name: .startVideo, object: instanceId)
            }
        } else {
            visibleVideos.remove(instanceId)
            // print("DEBUG: [VIDEO MANAGER] Video became invisible: \(instanceId) (isVisible: \(isVisible), actuallyVisible: \(actuallyVisible))")
            
            // Remove invisible videos from queue to prevent them from starting
            removeInvisibleFromQueue()
            
            // If the invisible video was playing, stop it and start next
            if currentPlayingInstanceId == instanceId {
                // print("DEBUG: [VIDEO MANAGER] Stopping invisible video: \(instanceId)")
                NotificationCenter.default.post(name: .pauseVideo, object: instanceId)
                currentPlayingInstanceId = nil
                
                if autoStartNext {
                    startNextVisibleVideo()
                }
            }
        }
    }
    
    // Add video to queue for auto-play (only if visible)
    func addToQueue(instanceId: String) {
        if !videoQueue.contains(instanceId) && currentPlayingInstanceId != instanceId && visibleVideos.contains(instanceId) {
            videoQueue.append(instanceId)
            // print("DEBUG: [VIDEO MANAGER] Added actually visible video to queue: \(instanceId), queue size: \(videoQueue.count)")
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
