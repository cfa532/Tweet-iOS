//
//  SingletonVideoManagers.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  Singleton video managers for detail and fullscreen contexts
//

import Foundation
import AVFoundation
import UIKit
import SwiftUI

/// Singleton video manager for fullscreen video playback with auto-advance
/// Uses a dedicated singleton player instance independent from MediaCell players
@MainActor
class FullScreenVideoManager: ObservableObject {
    static let shared = FullScreenVideoManager()
    private init() {
        setupAppLifecycleNotifications()
    }
    
    // Independent singleton player for fullscreen mode
    @Published var singletonPlayer: AVPlayer?
    @Published var currentVideoMid: String?
    @Published var currentTweetId: String?
    @Published var currentSourceTweetId: String? // The visible tweet ID in feed (for retweets)
    @Published var currentVideoIndex: Int = 0 // Track current video index within tweet
    @Published var isPlaying = false
    
    // Closures for finding and navigating to next video
    var findNextVideo: ((String, Int) async -> (tweet: Tweet, videoIndex: Int, sourceTweetId: String)?)? // Async closure to find next video
    var onNavigateToNextVideo: ((Tweet, Int, String) -> Void)? // Callback to navigate to next video (tweet, videoIndex, sourceTweetId)
    
    // Video completion observer
    private var videoCompletionObserver: NSObjectProtocol?
    
    /// Set the video search function from TweetListView
    func setVideoSearchFunction(_ findNext: @escaping (String, Int) async -> (tweet: Tweet, videoIndex: Int, sourceTweetId: String)?, onNavigate: @escaping (Tweet, Int, String) -> Void) {
        self.findNextVideo = findNext
        self.onNavigateToNextVideo = onNavigate
        print("DEBUG: [FullScreenVideoManager] Set video search function")
    }
    
    /// Load and play a video in the singleton player
    func loadVideo(url: URL, mid: String, tweetId: String, sourceTweetId: String, videoIndex: Int, mediaType: MediaType) {
        print("DEBUG: [FullScreenVideoManager] Loading video in singleton player - mid: \(mid), tweetId: \(tweetId), sourceTweetId: \(sourceTweetId), videoIndex: \(videoIndex)")
        
        // Remove old observer if exists
        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
        
        // Store current video info
        self.currentVideoMid = mid
        self.currentTweetId = tweetId
        self.currentSourceTweetId = sourceTweetId
        self.currentVideoIndex = videoIndex
        
        // Load video asynchronously
        Task.detached(priority: .userInitiated) {
            do {
                let asset = try await SharedAssetCache.shared.getAsset(for: url, tweetId: tweetId)
                let playerItem = await AVPlayerItem(asset: asset)
                
                await MainActor.run {
                    // Create or reuse singleton player
                    if self.singletonPlayer == nil {
                        self.singletonPlayer = AVPlayer(playerItem: playerItem)
                        self.singletonPlayer?.automaticallyWaitsToMinimizeStalling = false
                        print("DEBUG: [FullScreenVideoManager] Created new singleton player")
                    } else {
                        print("DEBUG: [FullScreenVideoManager] Reusing singleton player with new item")
                        self.singletonPlayer?.replaceCurrentItem(with: playerItem)
                    }
                    
                    // Always unmuted in fullscreen
                    self.singletonPlayer?.isMuted = false
                    
                    // Setup video completion observer
                    self.setupVideoCompletionObserver(playerItem)
                    
                    // Check if player item is ready
                    if playerItem.status == .readyToPlay {
                        print("DEBUG: [FullScreenVideoManager] Player item ready immediately, playing now")
                        self.singletonPlayer?.play()
                        self.isPlaying = true
                    } else {
                        print("DEBUG: [FullScreenVideoManager] Player item not ready yet (status: \(playerItem.status.rawValue)), will play when ready via AVPlayerViewController observer")
                        self.isPlaying = true // Mark as "should be playing"
                    }
                    
                    print("DEBUG: [FullScreenVideoManager] ✅ Singleton player loaded - mid: \(mid), tweetId: \(tweetId), videoIndex: \(videoIndex)")
                }
            } catch {
                await MainActor.run {
                    print("ERROR: [FullScreenVideoManager] Failed to load video: \(error)")
                }
            }
        }
    }
    
    /// Setup video completion observer
    private func setupVideoCompletionObserver(_ playerItem: AVPlayerItem) {
        // Remove old observer
        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        // Add new observer
        videoCompletionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                print("DEBUG: [FullScreenVideoManager] Video finished in singleton player")
                self.isPlaying = false
                
                // Trigger auto-advance after delay
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                self.handleVideoFinished()
            }
        }
    }
    
    /// Handle video completion and auto-advance to next video
    func handleVideoFinished() {
        guard let currentSourceTweetId = currentSourceTweetId,
              let findNextVideo = findNextVideo else {
            print("DEBUG: [FullScreenVideoManager] No source tweet ID or search function, cannot advance")
            return
        }
        
        print("DEBUG: [FullScreenVideoManager] Video finished for sourceTweet: \(currentSourceTweetId), videoIndex: \(currentVideoIndex)")
        
        // Use TweetListView's async search function to find next video
        // Pass sourceTweetId (visible tweet position in feed) not currentTweetId (could be original tweet)
        Task {
            if let nextVideo = await findNextVideo(currentSourceTweetId, currentVideoIndex) {
                await MainActor.run {
                    print("DEBUG: [FullScreenVideoManager] ✅ Found next video - mediaTweet: \(nextVideo.tweet.mid), videoIndex: \(nextVideo.videoIndex), sourceTweetId: \(nextVideo.sourceTweetId)")
                    onNavigateToNextVideo?(nextVideo.tweet, nextVideo.videoIndex, nextVideo.sourceTweetId)
                }
            } else {
                await MainActor.run {
                    print("DEBUG: [FullScreenVideoManager] ❌ No more videos found in feed")
                }
            }
        }
    }
    
    /// Clear singleton player
    func clearSingletonPlayer() {
        singletonPlayer?.pause()
        singletonPlayer = nil
        currentVideoMid = nil
        currentTweetId = nil
        currentSourceTweetId = nil
        currentVideoIndex = 0
        isPlaying = false
        
        // Remove observer
        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
        
        print("DEBUG: [FullScreenVideoManager] Cleared singleton player")
    }
    
    /// Pause current playback
    func pause() {
        singletonPlayer?.pause()
        isPlaying = false
    }
    
    /// Resume playback
    func play() {
        singletonPlayer?.play()
        isPlaying = true
    }
    
    // MARK: - App Lifecycle
    
    private func setupAppLifecycleNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppDidEnterBackground()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppWillEnterForeground()
            }
        }
    }
    
    private func handleAppDidEnterBackground() {
        print("DEBUG: [FullScreenVideoManager] App entering background, pausing")
        pause()
    }
    
    private func handleAppWillEnterForeground() {
        print("DEBUG: [FullScreenVideoManager] App entering foreground")
        // Don't auto-resume, let user control
    }
    
    /// Clear search function
    func clearSearchFunction() {
        findNextVideo = nil
        onNavigateToNextVideo = nil
        print("DEBUG: [FullScreenVideoManager] Cleared search function")
    }
}

/// Singleton video manager for detail view context
@MainActor
class DetailVideoManager: NSObject, ObservableObject {
    static let shared = DetailVideoManager()
    private override init() {
        super.init()
        setupAppLifecycleNotifications()
        setupAudioInterruptionNotifications()
    }
    
    @Published var currentPlayer: AVPlayer?
    @Published var currentVideoMid: String?
    @Published var isPlaying = false
    
    private var videoCompletionObserver: NSObjectProtocol?
    
    /// Setup audio interruption notifications to handle incoming calls
    private func setupAudioInterruptionNotifications() {
        AudioSessionManager.shared.setupInterruptionNotifications()
    }
    
    /// Set current video for detail view
    func setCurrentVideo(url: URL, mid: String, autoPlay: Bool = true) {
        // If switching to a different video, stop the current one
        if currentVideoMid != mid {
            currentPlayer?.pause()
            
            // Remove KVO observer from previous player item
            if let player = currentPlayer, let playerItem = player.currentItem {
                playerItem.removeObserver(self, forKeyPath: "status")
            }
            
            // Remove video completion observer from previous video
            if let observer = videoCompletionObserver {
                NotificationCenter.default.removeObserver(observer)
                videoCompletionObserver = nil
            }
        }
        
        currentVideoMid = mid
        
        // Activate audio session for video playback
        AudioSessionManager.shared.activateForVideoPlayback()
        
        Task.detached(priority: .userInitiated) {
            do {
                
                // Create independent player with disk caching support
                // Get the asset from SharedAssetCache (which uses CachingPlayerItem for HLS)
                // but create our own independent player instance
                let asset = try await SharedAssetCache.shared.getAsset(for: url, tweetId: mid)
                let playerItem = await AVPlayerItem(asset: asset)
                let newPlayer = AVPlayer(playerItem: playerItem)
                
                await MainActor.run {
                    // Store the new player (independent from MediaCell)
                    self.currentPlayer = newPlayer
                    
                    // Configure the player
                    self.currentPlayer?.isMuted = false // Always unmuted in detail
                    
                    // Add observers for the player item
                    if let playerItem = self.currentPlayer?.currentItem {
                        // Add KVO observer for player item status
                        playerItem.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
                        
                        // Add video completion observer
                        self.setupVideoCompletionObserver(playerItem)
                        
                        // Check if player item is ready immediately
                        if playerItem.status == .readyToPlay {
                            if autoPlay {
                                self.currentPlayer?.play()
                                self.isPlaying = true
                            }
                        }
                    }
                    
                    // Auto-play immediately if requested
                    if autoPlay {
                        self.currentPlayer?.play()
                        self.isPlaying = true
                        print("DEBUG: [DETAIL VIDEO MANAGER] Auto-playing player for mediaID: \(mid)")
                    }
                }
            } catch {
                await MainActor.run {
                    print("ERROR: [DETAIL VIDEO MANAGER] Failed to load video: \(error)")
                }
            }
        }
    }
    
    /// Clear current video
    func clearCurrentVideo() {
        // Remove KVO observer before clearing
        if let player = currentPlayer, let playerItem = player.currentItem {
            playerItem.removeObserver(self, forKeyPath: "status")
        }
        
        // Remove video completion observer
        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
        
        currentPlayer?.pause()
        currentPlayer = nil
        currentVideoMid = nil
        isPlaying = false
        
        // Deactivate audio session when video is cleared
        AudioSessionManager.shared.deactivateForVideoPlayback()
        
    }
    
    /// Setup video completion observer
    private func setupVideoCompletionObserver(_ playerItem: AVPlayerItem) {
        print("DEBUG: [DETAIL VIDEO MANAGER] Setting up video completion observer for \(currentVideoMid ?? "unknown")")
        
        // Remove existing observer if any
        if let observer = videoCompletionObserver {
            print("DEBUG: [DETAIL VIDEO MANAGER] Removing existing video completion observer for \(currentVideoMid ?? "unknown")")
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
        
        // Add new observer for video completion
        videoCompletionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard let player = self.currentPlayer else { 
                    print("DEBUG: [DETAIL VIDEO MANAGER] No current player when video finished")
                    return 
                }
                let currentMid = self.currentVideoMid
                print("DEBUG: [DETAIL VIDEO MANAGER] Video completion notification received for \(currentMid ?? "unknown")")
                print("DEBUG: [DETAIL VIDEO MANAGER] Notification object: \(notification.object ?? "nil")")
                print("DEBUG: [DETAIL VIDEO MANAGER] Player current item: \(player.currentItem?.description ?? "nil")")
                
                // Reset video to beginning (but don't auto-restart)
                player.seek(to: .zero) { finished in
                    guard finished else { 
                        print("DEBUG: [DETAIL VIDEO MANAGER] Seek to zero failed for \(currentMid ?? "unknown")")
                        return 
                    }
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        print("DEBUG: [DETAIL VIDEO MANAGER] Successfully seeked to zero for \(currentMid ?? "unknown")")
                        print("DEBUG: [DETAIL VIDEO MANAGER] Video reset to beginning, ready to replay for \(currentMid ?? "unknown")")
                        self.isPlaying = false
                    }
                }
            }
        }
        
        print("DEBUG: [DETAIL VIDEO MANAGER] Video completion observer setup complete for \(currentVideoMid ?? "unknown")")
    }
    
    /// Toggle play/pause
    func togglePlayback() {
        guard let player = currentPlayer else { return }
        
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }
    
    // MARK: - KVO Observer
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "status" {
            if let playerItem = object as? AVPlayerItem {
                if playerItem.status == .readyToPlay {
                    if let player = currentPlayer, player.currentItem == playerItem {
                        player.play()
                        isPlaying = true
                    }
                } else if playerItem.status == .failed {
                    print("ERROR: [DETAIL VIDEO MANAGER] Player item failed to load")
                }
            }
        }
    }
    
    // MARK: - App Lifecycle Handling
    
    private var savedPlaybackState: (wasPlaying: Bool, time: CMTime)?
    
    private func setupAppLifecycleNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppDidEnterBackground()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppWillEnterForeground()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppDidBecomeActive()
            }
        }
    }
    
    private func handleAppDidEnterBackground() {
        guard let player = currentPlayer else { return }
        
        print("DEBUG: [DetailVideoManager] App entering background, saving state")
        
        // Save current playback state
        let wasPlaying = player.rate > 0
        let currentTime = player.currentTime()
        savedPlaybackState = (wasPlaying: wasPlaying, time: currentTime)
        
        // Pause the player to prevent black screen
        player.pause()
        isPlaying = false
        
        print("DEBUG: [DetailVideoManager] Saved state - wasPlaying: \(wasPlaying), time: \(currentTime.seconds)")
    }
    
    private func handleAppWillEnterForeground() {
        refreshVideoLayer()
    }
    
    private func handleAppDidBecomeActive() {
        // Refresh immediately when app becomes active
        refreshVideoLayer()
    }
    
    private func refreshVideoLayer() {
        guard let player = currentPlayer else {
            print("DEBUG: [DetailVideoManager] No player to refresh")
            return
        }
        
        // Check if player is still valid (has a current item)
        guard player.currentItem != nil else {
            print("DEBUG: [DetailVideoManager] Player has no current item - needs recreation")
            // Player was cleared by background recovery, need to recreate
            // Clear our reference so it can be recreated when view appears
            currentPlayer = nil
            currentVideoMid = nil
            isPlaying = false
            savedPlaybackState = nil
            return
        }
        
        print("DEBUG: [DetailVideoManager] Refreshing video layer after background/foreground transition")
        
        // Use saved state if available, otherwise use current state
        let wasPlaying: Bool
        let seekTime: CMTime
        
        if let savedState = savedPlaybackState {
            wasPlaying = savedState.wasPlaying
            seekTime = savedState.time
            print("DEBUG: [DetailVideoManager] Using saved state - wasPlaying: \(wasPlaying), time: \(seekTime.seconds)")
            savedPlaybackState = nil // Clear after using
        } else {
            wasPlaying = isPlaying
            seekTime = player.currentTime()
            print("DEBUG: [DetailVideoManager] No saved state, using current - wasPlaying: \(wasPlaying), time: \(seekTime.seconds)")
        }
        
        // Pause first to ensure clean state
        player.pause()
        
        // Force a seek with zero tolerance to refresh the video layer
        // This triggers the AVPlayerLayer to redraw its contents
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            if finished {
                print("DEBUG: [DetailVideoManager] Seek completed after layer refresh")
                if wasPlaying {
                    // Resume playback if it was playing before
                    print("DEBUG: [DetailVideoManager] Resuming playback")
                    player.play()
                    Task { @MainActor [weak self] in
                        self?.isPlaying = true
                    }
                } else {
                    print("DEBUG: [DetailVideoManager] Not resuming playback (was paused)")
                }
            } else {
                print("DEBUG: [DetailVideoManager] Seek failed after layer refresh - clearing invalid player")
                // Seek failed, player is invalid, clear it
                Task { @MainActor [weak self] in
                    self?.currentPlayer = nil
                    self?.currentVideoMid = nil
                    self?.isPlaying = false
                }
            }
        }
    }
}
