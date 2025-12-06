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

// MARK: - Shared App Lifecycle Protocol
@MainActor
protocol VideoPlayerLifecycleManager: AnyObject {
    var savedPlaybackState: (wasPlaying: Bool, time: CMTime)? { get set }
    var hasRecoveredThisCycle: Bool { get set }
    
    func getPlayer() -> AVPlayer?
    func pausePlayer()
    func setPlaying(_ playing: Bool)
    func isPlayerBroken() -> Bool
    func clearBrokenPlayer()
    func recoverFromBackground()
}

extension VideoPlayerLifecycleManager {
    func setupAppLifecycleNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppWillResignActive()
            }
        }
        
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
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppDidBecomeActive()
            }
        }
    }
    
    func handleAppWillResignActive() {
        guard let player = getPlayer() else { return }
        
        let managerName = String(describing: type(of: self))
        print("DEBUG: [\(managerName)] App resigning active (screen lock), saving state")
        
        // Save current playback state
        let wasPlaying = player.rate > 0
        let currentTime = player.currentTime()
        savedPlaybackState = (wasPlaying: wasPlaying, time: currentTime)
        
        // Pause the player
        pausePlayer()
        setPlaying(false)
        
        // Reset recovery flag
        hasRecoveredThisCycle = false
        
        print("DEBUG: [\(managerName)] Saved state - wasPlaying: \(wasPlaying), time: \(currentTime.seconds)")
    }
    
    func handleAppDidEnterBackground() {
        guard let player = getPlayer() else { return }
        
        let managerName = String(describing: type(of: self))
        print("DEBUG: [\(managerName)] App entering background, saving state")
        
        // Save current playback state (if not already saved by willResignActive)
        if savedPlaybackState == nil {
            let wasPlaying = player.rate > 0
            let currentTime = player.currentTime()
            savedPlaybackState = (wasPlaying: wasPlaying, time: currentTime)
            
            // Pause the player
            pausePlayer()
            setPlaying(false)
            
            print("DEBUG: [\(managerName)] Saved state - wasPlaying: \(wasPlaying), time: \(currentTime.seconds)")
        } else {
            print("DEBUG: [\(managerName)] State already saved by willResignActive")
        }
    }
    
    func handleAppWillEnterForeground() {
        let managerName = String(describing: type(of: self))
        print("DEBUG: [\(managerName)] App entering foreground, recovering from background")
        recoverFromBackground()
    }
    
    func handleAppDidBecomeActive() {
        let managerName = String(describing: type(of: self))
        print("DEBUG: [\(managerName)] App became active")
        // Recover from screen lock (which triggers didBecomeActive but not willEnterForeground)
        // Only recover if we haven't already recovered in this cycle (to avoid duplicate recovery)
        if !hasRecoveredThisCycle {
            print("DEBUG: [\(managerName)] Recovering from screen lock in didBecomeActive")
            recoverFromBackground()
        } else {
            print("DEBUG: [\(managerName)] Already recovered in willEnterForeground, checking for broken player")
            // Even if we already recovered, check if player is broken (e.g., after video finished)
            if isPlayerBroken() {
                clearBrokenPlayer()
            }
        }
    }
}

/// Singleton video manager for fullscreen video playback with auto-advance
/// Uses a dedicated singleton player instance independent from MediaCell players
@MainActor
class FullScreenVideoManager: ObservableObject, VideoPlayerLifecycleManager {
    static let shared = FullScreenVideoManager()
    private init() {
        setupAppLifecycleNotifications()
    }
    
    // MARK: - VideoPlayerLifecycleManager Protocol
    var savedPlaybackState: (wasPlaying: Bool, time: CMTime)?
    var hasRecoveredThisCycle = false
    
    func getPlayer() -> AVPlayer? {
        return singletonPlayer
    }
    
    func pausePlayer() {
        pause()
    }
    
    func setPlaying(_ playing: Bool) {
        isPlaying = playing
    }
    
    func clearBrokenPlayer() {
        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
        singletonPlayer?.pause()
        singletonPlayer = nil
        isPlaying = false
    }
    
    // Independent singleton player for fullscreen mode
    @Published var singletonPlayer: AVPlayer?
    @Published var currentVideoMid: String?
    @Published var currentTweetId: String?
    @Published var currentSourceTweetId: String? // The visible tweet ID in feed (for retweets)
    @Published var currentVideoIndex: Int = 0 // Track current video index within tweet
    @Published var isPlaying = false
    @Published var isBuffering = false // Track buffering state for spinner
    
    // Closures for finding and navigating to next video
    var findNextVideo: ((String, Int) async -> (tweet: Tweet, videoIndex: Int, sourceTweetId: String)?)? // Async closure to find next video
    var onNavigateToNextVideo: ((Tweet, Int, String) -> Void)? // Callback to navigate to next video (tweet, videoIndex, sourceTweetId)
    var onExitFullScreen: (() -> Void)? // Callback to exit fullscreen
    
    // Video completion observer
    private var videoCompletionObserver: NSObjectProtocol?
    
    // Retry mechanism for seeking
    private var retryWorkItem: DispatchWorkItem?
    private var bufferObserver: NSKeyValueObservation?
    
    // Waiting for data observer
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var playbackBufferEmptyObserver: NSKeyValueObservation?
    private var playbackLikelyToKeepUpObserver: NSKeyValueObservation?
    private var loadedTimeRangesObserver: NSKeyValueObservation?
    private var itemStatusObserver: NSKeyValueObservation?
    private var wasPlayingBeforeWaiting = false
    
    /// Initialize singleton player early (called during app startup)
    func initializePlayerEarly() {
        guard singletonPlayer == nil else {
            print("DEBUG: [FullScreenVideoManager] Player already initialized, skipping early init")
            return
        }
        
        // Create empty player instance to warm up AVFoundation infrastructure
        singletonPlayer = AVPlayer()
        singletonPlayer?.automaticallyWaitsToMinimizeStalling = false
        singletonPlayer?.isMuted = false
        
        print("DEBUG: [FullScreenVideoManager] ✅ Initialized singleton player early during app startup")
    }
    
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
        
        // Cancel any retry work
        retryWorkItem?.cancel()
        retryWorkItem = nil
        
        // Clean up buffer observer
        bufferObserver?.invalidate()
        bufferObserver = nil
        
        // Clean up timeControlStatus observer
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        playbackBufferEmptyObserver?.invalidate()
        playbackBufferEmptyObserver = nil
        playbackLikelyToKeepUpObserver?.invalidate()
        playbackLikelyToKeepUpObserver = nil
        loadedTimeRangesObserver?.invalidate()
        loadedTimeRangesObserver = nil
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        wasPlayingBeforeWaiting = false
        isBuffering = false
        
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
                    // Ensure audio session uses playback category so hardware mute switch doesn't silence fullscreen video
                    AudioSessionManager.shared.activateForVideoPlayback()
                    
                    // Create or reuse singleton player
                    if self.singletonPlayer == nil {
                        self.singletonPlayer = AVPlayer(playerItem: playerItem)
                        print("DEBUG: [FullScreenVideoManager] Created new singleton player")
                    } else {
                        print("DEBUG: [FullScreenVideoManager] Reusing singleton player with new item")
                        self.singletonPlayer?.replaceCurrentItem(with: playerItem)
                    }
                    
                    // Configure buffering behavior based on media type
                    if mediaType == .video {
                        self.singletonPlayer?.automaticallyWaitsToMinimizeStalling = true
                        playerItem.preferredForwardBufferDuration = max(playerItem.preferredForwardBufferDuration, 30.0)
                    } else {
                        self.singletonPlayer?.automaticallyWaitsToMinimizeStalling = false
                    }
                    
                    // Always unmuted in fullscreen
                    self.singletonPlayer?.isMuted = false
                    
                    // Setup video completion observer
                    self.setupVideoCompletionObserver(playerItem)
                    
                    // Setup timeControlStatus observer for buffering detection and autoplay
                    self.setupTimeControlStatusObserver()
                    
                    // Start monitoring for stalls during seeking
                    self.startRetryMonitoring()
                    
                    // Check if player item is ready
                    if playerItem.status == .readyToPlay {
                        print("DEBUG: [FullScreenVideoManager] Player item ready immediately, checking position before playing")
                        // Check position and rewind if at end before playing
                        self.checkAndRewindIfAtEnd {
                            self.singletonPlayer?.play()
                            self.isPlaying = true
                            print("DEBUG: [FullScreenVideoManager] Started playback after position check")
                        }
                    } else {
                        print("DEBUG: [FullScreenVideoManager] Player item not ready yet (status: \(playerItem.status.rawValue)), will play when ready via AVPlayerViewController observer")
                        self.isPlaying = true // Mark as "should be playing"
                    }
                    
                                print("DEBUG: [FullScreenVideoManager] ✅ Singleton player loaded - mid: \(mid), tweetId: \(tweetId), videoIndex: \(videoIndex)")
                }
            } catch {
                await MainActor.run {
                    print("ERROR: [FullScreenVideoManager] Failed to load video: \(error)")
                    // Clear broken player state to show loading placeholder instead of broken icon
                    // CRITICAL: Clear ALL state variables consistently with recovery cleanup (lines 488-490)
                    self.singletonPlayer = nil
                    self.currentVideoMid = nil
                    self.currentTweetId = nil
                    self.currentSourceTweetId = nil
                    self.currentVideoIndex = 0
                    self.isPlaying = false
                }
            }
        }
    }
    
    /// Setup timeControlStatus observer for buffering detection and autoplay
    private func setupTimeControlStatusObserver() {
        // Remove old observers
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        playbackBufferEmptyObserver?.invalidate()
        playbackBufferEmptyObserver = nil
        playbackLikelyToKeepUpObserver?.invalidate()
        playbackLikelyToKeepUpObserver = nil
        loadedTimeRangesObserver?.invalidate()
        loadedTimeRangesObserver = nil
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        wasPlayingBeforeWaiting = false
        
        guard let player = singletonPlayer, let playerItem = player.currentItem else {
            NSLog("⚠️ [FULLSCREEN WAITING] Cannot setup observer - no player or playerItem")
            return
        }
        
        NSLog("✅ [FULLSCREEN WAITING] Setting up buffering observers for \(currentVideoMid ?? "unknown")")
        
        // Helper to update buffering state
        let updateBufferingState = { [weak self, weak player, weak playerItem] () in
            guard let self = self, let player = player, let item = playerItem else { return }
            
            let isBufferEmpty = item.isPlaybackBufferEmpty
            let isLikelyToKeepUp = item.isPlaybackLikelyToKeepUp
            let isWaiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            let wasPlaying = player.rate > 0 || self.isPlaying
            let hasBufferedData = !item.loadedTimeRanges.isEmpty
            let itemStatus = item.status
            
            // Calculate buffered duration
            var bufferedDuration: Double = 0
            if hasBufferedData {
                bufferedDuration = item.loadedTimeRanges.reduce(0.0) { max($0, CMTimeGetSeconds($1.timeRangeValue.duration)) }
            }
            
            // Show spinner if:
            // 1. Buffer is explicitly empty, OR
            // 2. Player is explicitly waiting, OR
            // 3. Item is ready but buffer is empty or very small (< 0.5s) and not likely to keep up
            let shouldShowSpinner = isBufferEmpty || isWaiting || (itemStatus == .readyToPlay && (!hasBufferedData || (bufferedDuration < 0.5 && !isLikelyToKeepUp)))
            
            NSLog("🔍 [FULLSCREEN WAITING] bufferEmpty: \(isBufferEmpty), likelyToKeepUp: \(isLikelyToKeepUp), waiting: \(isWaiting), hasData: \(hasBufferedData), buffered: \(String(format: "%.1f", bufferedDuration))s, status: \(itemStatus.rawValue), shouldShow: \(shouldShowSpinner)")
            
            if shouldShowSpinner {
                // Video is waiting for data - track if it was playing
                if !self.wasPlayingBeforeWaiting && wasPlaying {
                    self.wasPlayingBeforeWaiting = true
                    NSLog("🔄 [FULLSCREEN WAITING] Video was playing, will autoplay when ready")
                }
                
                // Show spinner
                if !self.isBuffering {
                    self.isBuffering = true
                    NSLog("🔄 [FULLSCREEN WAITING] Showing spinner")
                }
            } else {
                // Player has enough data - hide spinner
                if self.isBuffering {
                    self.isBuffering = false
                    NSLog("✅ [FULLSCREEN DATA READY] Hiding spinner (buffered: \(String(format: "%.1f", bufferedDuration))s)")
                }
                
                // Autoplay logic: check multiple conditions to ensure we resume when data is ready
                let hasEnoughBuffer = hasBufferedData && bufferedDuration >= 0.5
                let isReadyToPlay = itemStatus == .readyToPlay
                let isNotPlaying = player.rate == 0
                let wantsToPlay = self.isPlaying || self.wasPlayingBeforeWaiting
                
                // If we want to play, have data, and player is not playing, resume
                if wantsToPlay && isReadyToPlay && hasEnoughBuffer && isNotPlaying {
                    NSLog("✅ [FULLSCREEN DATA READY] Data ready (buffered: \(String(format: "%.1f", bufferedDuration))s), resuming playback (isPlaying: \(self.isPlaying), wasPlayingBefore: \(self.wasPlayingBeforeWaiting))")
                    player.play()
                    self.isPlaying = true
                    self.wasPlayingBeforeWaiting = false
                } else if player.timeControlStatus == .playing || player.rate > 0 {
                    // Already playing - just reset flag
                    if self.wasPlayingBeforeWaiting {
                        NSLog("✅ [FULLSCREEN DATA READY] Video already playing, resetting flag")
                        self.wasPlayingBeforeWaiting = false
                    }
                } else if wantsToPlay && isReadyToPlay && hasEnoughBuffer {
                    // Fallback: try to play even if rate check didn't catch it
                    NSLog("✅ [FULLSCREEN DATA READY] Fallback: attempting to resume (wantsToPlay: \(wantsToPlay), ready: \(isReadyToPlay), buffer: \(hasEnoughBuffer))")
                    player.play()
                    self.isPlaying = true
                    self.wasPlayingBeforeWaiting = false
                }
            }
        }
        
        // Observe playbackBufferEmpty - most reliable indicator
        playbackBufferEmptyObserver = playerItem.observe(\.isPlaybackBufferEmpty, options: [.new, .initial]) { _, _ in
            DispatchQueue.main.async {
                updateBufferingState()
            }
        }
        
        // Observe playbackLikelyToKeepUp
        playbackLikelyToKeepUpObserver = playerItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new, .initial]) { _, _ in
            DispatchQueue.main.async {
                updateBufferingState()
            }
        }
        
        // Observe loadedTimeRanges to catch when data arrives
        self.loadedTimeRangesObserver = playerItem.observe(\.loadedTimeRanges, options: [.new]) { _, _ in
            DispatchQueue.main.async {
                updateBufferingState()
            }
        }
        
        // Observe item status changes
        self.itemStatusObserver = playerItem.observe(\.status, options: [.new]) { _, _ in
            DispatchQueue.main.async {
                updateBufferingState()
            }
        }
        
        // Observe timeControlStatus as backup
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new, .initial]) { _, _ in
            DispatchQueue.main.async {
                updateBufferingState()
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
    
    /// Start monitoring for playback stalls and auto-retry
    private func startRetryMonitoring() {
        // Cancel existing monitoring
        retryWorkItem?.cancel()
        
        // Create new retry work item
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.checkAndRetryIfStalled()
            }
        }
        
        retryWorkItem = workItem
        
        // Schedule first check after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }
    
    /// Check if player is stalled and retry
    private func checkAndRetryIfStalled() {
        guard let player = singletonPlayer, let playerItem = player.currentItem else { return }
        
        // If player is stuck (not playing and rate is 0), force a seek to trigger reload
        if player.rate == 0 && player.timeControlStatus != .playing {
            let currentTime = player.currentTime()
            NSLog("🔄 [FULLSCREEN RETRY] Player stuck at \(String(format: "%.1f", currentTime.seconds))s, seeking to trigger segment load")
            
            // Clean up old observer
            bufferObserver?.invalidate()
            bufferObserver = nil
            
            // Force seek to current position to trigger segment download
            player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player, weak playerItem] finished in
                guard finished, let self = self, let player = player, let item = playerItem else { return }
                
                Task { @MainActor in
                    NSLog("🔍 [FULLSCREEN RETRY] Seek completed, waiting for buffered data before resuming")
                    
                    // Wait for buffered data before calling play()
                    self.bufferObserver = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self, weak player] observedItem, _ in
                        let hasData = !observedItem.loadedTimeRanges.isEmpty
                        var bufferedDuration: Double = 0
                        if !observedItem.loadedTimeRanges.isEmpty {
                            let timeRange = observedItem.loadedTimeRanges[0].timeRangeValue
                            bufferedDuration = CMTimeGetSeconds(timeRange.duration)
                        }
                        
                        // Only resume when we have at least 1 second of buffer
                        if hasData && bufferedDuration >= 1.0 {
                            Task { @MainActor in
                                guard let self = self, let player = player else { return }
                                NSLog("✅ [FULLSCREEN RETRY] Data loaded (\(String(format: "%.1f", bufferedDuration))s buffered), resuming playback")
                                
                                // Clean up observer
                                self.bufferObserver?.invalidate()
                                self.bufferObserver = nil
                                
                                // Resume playback
                                if player.rate == 0 {
                                    player.play()
                                    NSLog("▶️ [FULLSCREEN RETRY] Called play() after data ready")
                                }
                                
                                // Continue monitoring for future stalls
                                self.startRetryMonitoring()
                            }
                        } else if hasData {
                            NSLog("⏳ [FULLSCREEN RETRY] Partial data (\(String(format: "%.1f", bufferedDuration))s), waiting for more...")
                        }
                    }
                    
                    // Safety timeout: if no data after 20 seconds, give up this retry and continue monitoring
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20.0) { [weak self] in
                        Task { @MainActor in
                            guard let self = self else { return }
                            if self.bufferObserver != nil {
                                NSLog("⚠️ [FULLSCREEN RETRY] Timeout waiting for data, will retry on next cycle")
                                self.bufferObserver?.invalidate()
                                self.bufferObserver = nil
                                self.startRetryMonitoring()
                            }
                        }
                    }
                }
            }
        } else {
            // Player is playing, continue monitoring
            startRetryMonitoring()
        }
    }
    
    /// Handle video completion and auto-advance to next video
    func handleVideoFinished() {
        guard let currentSourceTweetId = currentSourceTweetId,
              let findNextVideo = findNextVideo else {
            print("DEBUG: [FullScreenVideoManager] No source tweet ID or search function, cannot advance")
            // Don't rewind here - will check position when user tries to play
            isPlaying = false
            return
        }
        
        print("DEBUG: [FullScreenVideoManager] Video finished for sourceTweet: \(currentSourceTweetId), videoIndex: \(currentVideoIndex)")
        isPlaying = false
        
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
                    print("DEBUG: [FullScreenVideoManager] ❌ No more videos found in feed - video will rewind when user tries to play")
                    // Don't rewind here - will check position when user tries to play
                }
            }
        }
    }
    
    /// Check if video is at the end and rewind if needed before playing
    private func checkAndRewindIfAtEnd(completion: @escaping () -> Void) {
        guard let player = singletonPlayer, let playerItem = player.currentItem else {
            completion()
            return
        }
        
        // Check if player is broken - if so, reload the video
        if isPlayerBroken() {
            print("DEBUG: [FullScreenVideoManager] Player is broken - clearing for recreation")
            // Clear broken player so view can recreate it
            singletonPlayer?.pause()
            singletonPlayer = nil
            isPlaying = false
            // The view should detect nil player and reload
            print("DEBUG: [FullScreenVideoManager] Cleared broken player - view should reload")
            completion()
            return
        }
        
        // Check if video is at or near the end
        let currentTime = player.currentTime()
        let duration = playerItem.duration
        
        if duration.isValid && duration.seconds > 0 {
            let timeRemaining = duration.seconds - currentTime.seconds
            // If within 0.5 seconds of end, rewind to beginning
            if timeRemaining <= 0.5 {
                print("DEBUG: [FullScreenVideoManager] Video at end (\(String(format: "%.1f", timeRemaining))s remaining) - rewinding to beginning")
                player.seek(to: .zero) { [weak self] finished in
                    guard finished, let _ = self else {
                        completion()
                        return
                    }
                    print("DEBUG: [FullScreenVideoManager] Video rewound to beginning")
                    completion()
                }
                return
            }
        }
        
        // Video is not at end, proceed with play
        completion()
    }
    
    /// Navigate to next video (triggered by swipe up)
    func navigateToNext() {
        guard let currentSourceTweetId = currentSourceTweetId,
              let findNextVideo = findNextVideo else {
            print("DEBUG: [FullScreenVideoManager] No source tweet ID or search function")
            return
        }
        
        print("DEBUG: [FullScreenVideoManager] Swipe up - navigating to next video from sourceTweet: \(currentSourceTweetId)")
        
        Task {
            if let nextVideo = await findNextVideo(currentSourceTweetId, currentVideoIndex) {
                await MainActor.run {
                    print("DEBUG: [FullScreenVideoManager] ✅ Found next video - navigating")
                    onNavigateToNextVideo?(nextVideo.tweet, nextVideo.videoIndex, nextVideo.sourceTweetId)
                }
            } else {
                await MainActor.run {
                    print("DEBUG: [FullScreenVideoManager] ❌ No more videos - exiting fullscreen")
                    onExitFullScreen?()
                }
            }
        }
    }
    
    /// Clear singleton player content (keeps player instance for reuse)
    func clearSingletonPlayer() {
        // Pause and clear the current item, but keep the player instance
        singletonPlayer?.pause()
        singletonPlayer?.replaceCurrentItem(with: nil)
        
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
        
        // Cancel retry monitoring
        retryWorkItem?.cancel()
        retryWorkItem = nil
        
        // Clean up buffer observer
        bufferObserver?.invalidate()
        bufferObserver = nil
        
        // Clean up timeControlStatus observer
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        playbackBufferEmptyObserver?.invalidate()
        playbackBufferEmptyObserver = nil
        playbackLikelyToKeepUpObserver?.invalidate()
        playbackLikelyToKeepUpObserver = nil
        loadedTimeRangesObserver?.invalidate()
        loadedTimeRangesObserver = nil
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        wasPlayingBeforeWaiting = false
        isBuffering = false
        
        print("DEBUG: [FullScreenVideoManager] Cleared video content (player instance retained)")
        
        // Do NOT deactivate audio session here
        // Deactivating (setting to .ambient) can interrupt MediaCell playback if it has already resumed
        // Let the next video player or the system handle audio session state
        // AudioSessionManager.shared.deactivateForVideoPlayback()
    }
    
    /// Pause current playback
    func pause() {
        singletonPlayer?.pause()
        isPlaying = false
    }
    
    /// Resume playback (checks position and rewinds if at end)
    func play() {
        guard singletonPlayer != nil else {
            print("DEBUG: [FullScreenVideoManager] No player to play")
            return
        }
        
        // Check if video is at end and rewind if needed
        checkAndRewindIfAtEnd { [weak self] in
            guard let self = self, let player = self.singletonPlayer else { return }
            player.play()
            self.isPlaying = true
            print("DEBUG: [FullScreenVideoManager] Started playback")
        }
    }
    
    // MARK: - App Lifecycle (via VideoPlayerLifecycleManager protocol)
    
    /// Two-layer recovery from background
    func recoverFromBackground() {
        guard let player = singletonPlayer else {
            print("DEBUG: [FullScreenVideoManager] No player to recover")
            hasRecoveredThisCycle = true
            return
        }
        
        // Mark that we've recovered in this cycle
        hasRecoveredThisCycle = true
        
        // Layer 2 (Security): Check if player is broken
        if isPlayerBroken() {
            NSLog("DEBUG: [FullScreenVideoManager] Layer 2 (Security): Player is broken - clearing to force recreation")
            
            // Clear broken player
            clearBrokenPlayer()
            currentVideoMid = nil
            currentTweetId = nil
            currentSourceTweetId = nil
            
            // For fullscreen, the view should recreate when it sees nil player
            // Unlike DetailView, fullscreen typically closes when backgrounded
            NSLog("DEBUG: [FullScreenVideoManager] Player cleared - view should recreate")
            
            savedPlaybackState = nil
            return
        }
        
        // Layer 1 (Basic Restoration): Player is healthy, restore state
        print("DEBUG: [FullScreenVideoManager] Layer 1 (Basic Restoration): Restoring playback state")
        
        // Ensure mute state is correct
        player.isMuted = false
        
        // Force view refresh by seeking to current position
        // This is critical to fix black screen issues
        let currentTime = player.currentTime()
        let seekTime: CMTime
        let wasPlaying: Bool
        
        if let savedState = savedPlaybackState {
            wasPlaying = savedState.wasPlaying
            seekTime = savedState.time
            print("DEBUG: [FullScreenVideoManager] Using saved state - wasPlaying: \(wasPlaying), time: \(seekTime.seconds)")
            savedPlaybackState = nil
        } else {
            wasPlaying = isPlaying
            seekTime = currentTime
            print("DEBUG: [FullScreenVideoManager] No saved state, using current - wasPlaying: \(wasPlaying), time: \(seekTime.seconds)")
        }
        
        // Pause first to ensure clean state
        player.pause()
        isPlaying = false
        
        // Force a seek to refresh the video layer
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished, let self = self else { return }
            
            Task { @MainActor in
                print("DEBUG: [FullScreenVideoManager] Seek completed, layer refreshed")
                
                // Resume playback if it was playing before
                if wasPlaying {
                    print("DEBUG: [FullScreenVideoManager] Resuming playback - checking position first")
                    // Check position and rewind if at end before resuming
                    self.checkAndRewindIfAtEnd {
                        self.singletonPlayer?.play()
                        self.isPlaying = true
                        print("DEBUG: [FullScreenVideoManager] Resumed playback after position check")
                    }
                } else {
                    print("DEBUG: [FullScreenVideoManager] Not resuming (was paused)")
                }
            }
        }
    }
    
    /// Check if player is broken (Layer 2 security check)
    func isPlayerBroken() -> Bool {
        guard let player = singletonPlayer else {
            NSLog("DEBUG: [FullScreenVideoManager] Player is nil -> BROKEN")
            return true
        }
        
        guard let currentItem = player.currentItem else {
            NSLog("DEBUG: [FullScreenVideoManager] Player has no currentItem -> BROKEN")
            return true
        }
        
        // Check if player item is in failed state
        if currentItem.status == .failed {
            NSLog("DEBUG: [FullScreenVideoManager] Player item status is failed -> BROKEN")
            return true
        }
        
        // For screen lock recovery, don't check loadedTimeRanges
        // iOS might temporarily clear this data, but it will reload
        // Only check loadedTimeRanges if status is .readyToPlay AND duration is invalid
        if currentItem.status == .readyToPlay && 
           currentItem.loadedTimeRanges.isEmpty && 
           !currentItem.duration.isValid {
            NSLog("DEBUG: [FullScreenVideoManager] Player item has no loaded data AND invalid duration -> BROKEN")
            return true
        }
        
        NSLog("DEBUG: [FullScreenVideoManager] Player health check passed -> HEALTHY")
        return false
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
class DetailVideoManager: NSObject, ObservableObject, VideoPlayerLifecycleManager {
    static let shared = DetailVideoManager()
    private override init() {
        super.init()
        setupAppLifecycleNotifications()
        setupAudioInterruptionNotifications()
    }
    
    // MARK: - VideoPlayerLifecycleManager Protocol
    var savedPlaybackState: (wasPlaying: Bool, time: CMTime)?
    var hasRecoveredThisCycle = false
    
    func getPlayer() -> AVPlayer? {
        return currentPlayer
    }
    
    func pausePlayer() {
        currentPlayer?.pause()
    }
    
    func setPlaying(_ playing: Bool) {
        isPlaying = playing
    }
    
    func clearBrokenPlayer() {
        if hasKVOObserver, let playerItem = currentPlayer?.currentItem {
            playerItem.removeObserver(self, forKeyPath: "status")
            hasKVOObserver = false
        }
        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
        currentPlayer?.pause()
        currentPlayer = nil
        currentVideoMid = nil
        isPlaying = false
    }
    
    @Published var currentPlayer: AVPlayer?
    @Published var currentVideoMid: String?
    @Published var isPlaying = false
    
    private var videoCompletionObserver: NSObjectProtocol?
    private var hasKVOObserver = false // Track if KVO observer was added
    
    /// Setup audio interruption notifications to handle incoming calls
    private func setupAudioInterruptionNotifications() {
        AudioSessionManager.shared.setupInterruptionNotifications()
    }
    
    /// Set current video for detail view
    func setCurrentVideo(url: URL, mid: String, autoPlay: Bool = true) {
        // If switching to a different video, stop the current one
        if currentVideoMid != mid {
            currentPlayer?.pause()
            
            // Remove KVO observer from previous player item (only if it was added)
            if hasKVOObserver, let player = currentPlayer, let playerItem = player.currentItem {
                playerItem.removeObserver(self, forKeyPath: "status")
                hasKVOObserver = false
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
                        self.hasKVOObserver = true
                        
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
        // Remove KVO observer before clearing (only if it was added)
        if hasKVOObserver, let player = currentPlayer, let playerItem = player.currentItem {
            playerItem.removeObserver(self, forKeyPath: "status")
            hasKVOObserver = false
        }
        
        // Remove video completion observer
        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
        
        // Get the cache key before clearing the reference
        let cacheKey = currentVideoMid.map { "tweetDetail_\($0)" }
        
        // CRITICAL: Replace currentItem with nil to completely stop playback
        // Just calling pause() is not enough - AVPlayerViewController can restart it
        currentPlayer?.pause()
        currentPlayer?.replaceCurrentItem(with: nil)
        print("DEBUG: [DetailVideoManager] Replaced player item with nil to stop playback")
        currentPlayer = nil
        currentVideoMid = nil
        isPlaying = false
        
        // CRITICAL FIX: Remove the player from SharedAssetCache
        // This ensures complete isolation. Since MediaCell uses a different cache key,
        // removing the "tweetDetail_" prefixed key won't affect MediaCell.
        if let key = cacheKey {
            Task { @MainActor in
                SharedAssetCache.shared.removeInvalidPlayer(for: key)
                print("DEBUG: [DetailVideoManager] Removed player from SharedAssetCache with key: \(key)")
            }
        }
        // AudioSessionManager.shared.deactivateForVideoPlayback()
        // Do NOT deactivate audio session here
        // Deactivating (setting to .ambient) can interrupt MediaCell playback if it has already resumed
        // Let the next video player or the system handle audio session state
        // AudioSessionManager.shared.deactivateForVideoPlayback()
        
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
                
                // Just pause - no automatic rewind
                // Will rewind when user tries to play
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    print("DEBUG: [DETAIL VIDEO MANAGER] Video finished for \(currentMid ?? "unknown") - paused, ready to replay")
                    self.isPlaying = false
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
    
    // MARK: - App Lifecycle (via VideoPlayerLifecycleManager protocol)
    
    /// Two-layer recovery from background
    func recoverFromBackground() {
        guard let player = currentPlayer else {
            NSLog("DEBUG: [DetailVideoManager] No player to recover")
            hasRecoveredThisCycle = true
            return
        }
        
        // Mark that we've recovered in this cycle
        hasRecoveredThisCycle = true
        
        // Layer 2 (Security): Check if player is broken
        if isPlayerBroken() {
            NSLog("DEBUG: [DetailVideoManager] Layer 2 (Security): Player is broken - clearing to force recreation")
            
            // Clear broken player completely
            clearBrokenPlayer()
            
            // Post notification to tell SimpleVideoPlayer to reload
            // This will trigger SimpleVideoPlayer's handleVideoInfrastructureRestarted
            NSLog("DEBUG: [DetailVideoManager] Posting videoInfrastructureRestarted to trigger view reload")
            NotificationCenter.default.post(name: .videoInfrastructureRestarted, object: nil)
            
            savedPlaybackState = nil
            return
        }
        
        // Layer 1 (Basic Restoration): Player is healthy, restore state
        NSLog("DEBUG: [DetailVideoManager] Layer 1 (Basic Restoration): Restoring playback state")
        
        // Ensure mute state is correct
        player.isMuted = false
        
        // Use saved state if available, otherwise use current state
        let wasPlaying: Bool
        let seekTime: CMTime
        
        if let savedState = savedPlaybackState {
            wasPlaying = savedState.wasPlaying
            seekTime = savedState.time
            print("DEBUG: [DetailVideoManager] Using saved state - wasPlaying: \(wasPlaying), time: \(seekTime.seconds)")
            savedPlaybackState = nil
        } else {
            wasPlaying = isPlaying
            seekTime = player.currentTime()
            print("DEBUG: [DetailVideoManager] No saved state, using current - wasPlaying: \(wasPlaying), time: \(seekTime.seconds)")
        }
        
        // Pause first to ensure clean state
        player.pause()
        isPlaying = false
        
        // CRITICAL: Post notification to force SimpleVideoPlayer view refresh
        // This ensures AVPlayerViewController layer is properly reconnected after screen lock
        NSLog("DEBUG: [DetailVideoManager] Posting videoLayerRefresh to force view update")
        NotificationCenter.default.post(name: .videoLayerRefresh, object: nil)
        
        // Force a seek to refresh the video layer
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else {
                print("DEBUG: [DetailVideoManager] Seek failed, clearing invalid player")
                Task { @MainActor [weak self] in
                    self?.currentPlayer = nil
                    self?.currentVideoMid = nil
                    self?.isPlaying = false
                }
                return
            }
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                print("DEBUG: [DetailVideoManager] Seek completed, layer refreshed")
                
                if wasPlaying {
                    print("DEBUG: [DetailVideoManager] Resuming playback")
                    self.currentPlayer?.play()
                    self.isPlaying = true
                } else {
                    print("DEBUG: [DetailVideoManager] Not resuming (was paused)")
                }
            }
        }
    }
    
    /// Check if player is broken (Layer 2 security check)
    func isPlayerBroken() -> Bool {
        guard let player = currentPlayer else {
            NSLog("DEBUG: [DetailVideoManager] Player is nil -> BROKEN")
            return true
        }
        
        guard let currentItem = player.currentItem else {
            NSLog("DEBUG: [DetailVideoManager] Player has no currentItem -> BROKEN")
            return true
        }
        
        // Check if player item is in failed state
        if currentItem.status == .failed {
            NSLog("DEBUG: [DetailVideoManager] Player item status is failed -> BROKEN")
            return true
        }
        
        // For screen lock recovery, don't check loadedTimeRanges
        // iOS might temporarily clear this data, but it will reload
        // Only check loadedTimeRanges if status is .readyToPlay AND duration is invalid
        if currentItem.status == .readyToPlay && 
           currentItem.loadedTimeRanges.isEmpty && 
           !currentItem.duration.isValid {
            NSLog("DEBUG: [DetailVideoManager] Player item has no loaded data AND invalid duration -> BROKEN")
            return true
        }
        
        NSLog("DEBUG: [DetailVideoManager] Player health check passed -> HEALTHY")
        return false
    }
}
