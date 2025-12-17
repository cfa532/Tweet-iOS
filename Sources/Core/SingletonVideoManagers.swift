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

/// Global navigation state tracker
@MainActor
class NavigationStateManager {
    static let shared = NavigationStateManager()

    private init() {}

    /// Track if detail view is currently active (TweetDetailView or CommentDetailView)
    @Published var isDetailViewActive = false

    func setDetailViewActive(_ active: Bool) {
        isDetailViewActive = active
        print("DEBUG: [NAVIGATION STATE] Detail view active: \(active)")
    }
}

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
    /// Default implementation: Check if player is broken
    func isPlayerBroken() -> Bool {
        guard let player = getPlayer() else {
            let managerName = String(describing: type(of: self))
            NSLog("DEBUG: [\(managerName)] Player is nil -> BROKEN")
            return true
        }
        
        guard let currentItem = player.currentItem else {
            let managerName = String(describing: type(of: self))
            NSLog("DEBUG: [\(managerName)] Player has no currentItem -> BROKEN")
            return true
        }
        
        // Check if player item is in failed state
        if currentItem.status == .failed {
            let managerName = String(describing: type(of: self))
            NSLog("DEBUG: [\(managerName)] Player item status is failed -> BROKEN")
            return true
        }
        
        // Check if player item has an error (even if status isn't .failed yet)
        if let error = currentItem.error {
            let managerName = String(describing: type(of: self))
            NSLog("DEBUG: [\(managerName)] Player item has error: \(error.localizedDescription) -> BROKEN")
            return true
        }
        
        // Check if player has an error
        if let error = player.error {
            let managerName = String(describing: type(of: self))
            NSLog("DEBUG: [\(managerName)] Player has error: \(error.localizedDescription) -> BROKEN")
            return true
        }
        
        // For screen lock recovery, don't check loadedTimeRanges
        // iOS might temporarily clear this data, but it will reload
        // Only check loadedTimeRanges if status is .readyToPlay AND duration is invalid
        if currentItem.status == .readyToPlay && 
           currentItem.loadedTimeRanges.isEmpty && 
           !currentItem.duration.isValid {
            let managerName = String(describing: type(of: self))
            NSLog("DEBUG: [\(managerName)] Player item has no loaded data AND invalid duration -> BROKEN")
            return true
        }
        
        let managerName = String(describing: type(of: self))
        NSLog("DEBUG: [\(managerName)] Player health check passed -> HEALTHY")
        return false
    }
    
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
        
        // Save current playback state (avoid NaN times)
        let wasPlaying = player.rate > 0
        let rawTime = player.currentTime()
        let currentTime: CMTime = rawTime.seconds.isFinite ? rawTime : .zero
        savedPlaybackState = (wasPlaying: wasPlaying, time: currentTime)
        
        // CRITICAL: Also save to persistent storage so it survives player recreation
        if let detailManager = self as? DetailVideoManager,
           let videoMid = detailManager.currentVideoMid {
            PersistentVideoStateManager.shared.saveState(
                videoMid: videoMid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .detailView
            )
        } else if let fullscreenManager = self as? FullScreenVideoManager,
                  let videoMid = fullscreenManager.currentVideoMid {
            PersistentVideoStateManager.shared.saveState(
                videoMid: videoMid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .fullScreen
            )
        }
        
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
            let rawTime = player.currentTime()
            let currentTime: CMTime = rawTime.seconds.isFinite ? rawTime : .zero
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
        
        // CRITICAL: Delayed health check after recovery
        // Sometimes players appear healthy immediately after recovery but are actually broken
        // Check again after a short delay to catch these cases
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
            
            guard let self = self else { return }
            let managerName = String(describing: type(of: self))
            
            // Check if player is broken
            if self.isPlayerBroken() {
                NSLog("⚠️ [\(managerName)] Delayed health check: Player is broken after recovery, clearing")
                self.clearBrokenPlayer()
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
    private var hasRestoredPosition = false // Track if we've restored position from saved state
    private var isSeekingToRestoredPosition = false // Track if we're currently seeking to restored position

    // Prevent stale async loads from clobbering current state (fixes stuck spinner after repeated opens)
    private var loadGeneration: Int = 0
    private var loadingMid: String?

    // MARK: - Prewarm (startup UX)
    // Preload a first AVPlayerItem to reduce first-open latency.
    private var didPrewarmFirstItem: Bool = false
    private var prewarmTask: Task<Void, Never>?
    
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

    /// Prewarm the singleton by creating (and optionally attaching) a first AVPlayerItem.
    /// This should NOT start playback.
    func prewarmFirstItemIfNeeded(url: URL, mediaID: String, mediaType: MediaType) {
        guard !didPrewarmFirstItem else { return }
        didPrewarmFirstItem = true

        // Ensure the singleton player exists.
        initializePlayerEarly()

        prewarmTask?.cancel()
        prewarmTask = Task.detached(priority: .utility) { [url, mediaID, mediaType] in
            do {
                // CRITICAL FIX: Just create the asset/item to warm up the cache
                // DON'T attach it to singletonPlayer - that causes the prewarmed video
                // to flash on screen when first opening fullscreen
                let item = try await SharedAssetCache.shared.getOrCreatePlayerItem(
                    for: url,
                    mediaID: mediaID,
                    mediaType: mediaType
                )
                
                // Just accessing the item warms up the asset cache
                // The item will be cached and ready for quick loading later
                await MainActor.run {
                    // Don't attach to player - just warm up the cache
                    NSLog("✅ [FullScreenVideoManager] Prewarmed asset cache for \(mediaID) without attaching to player")
                }
            } catch {
                await MainActor.run {
                    NSLog("⚠️ [FullScreenVideoManager] Failed to prewarm first item for \(mediaID): \(error)")
                }
            }
        }
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

        // If we already have the correct item loaded, don't thrash observers / state.
        if currentVideoMid == mid,
           currentTweetId == tweetId,
           singletonPlayer?.currentItem != nil {
            // Still ensure buffering observers are attached (covers view recreation edge cases).
            setupTimeControlStatusObserver()
            return
        }
        
        // CRITICAL FIX: Clear any prewarmed item to prevent flash of wrong video
        // This ensures we start with a clean slate when loading a new video
        if singletonPlayer?.currentItem != nil && currentVideoMid != mid {
            print("DEBUG: [FullScreenVideoManager] Clearing prewarmed/old item before loading new video")
            singletonPlayer?.pause()
            singletonPlayer?.replaceCurrentItem(with: nil)
        }

        // Bump generation so any prior async completions are ignored.
        loadGeneration += 1
        let generation = loadGeneration
        loadingMid = mid
        hasRestoredPosition = false // Reset restoration flag when loading new video
        isSeekingToRestoredPosition = false // Reset seeking flag
        
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
        
        // Clean up timeControlStatus observers
        cleanupObservers()
        isBuffering = false
        
        // Store current video info
        self.currentVideoMid = mid
        self.currentTweetId = tweetId
        self.currentSourceTweetId = sourceTweetId
        self.currentVideoIndex = videoIndex
        
        // CRITICAL: Use getOrCreatePlayerItem which creates a fresh playerItem from URL
        // This works correctly for both HLS and progressive videos, even when MediaCell has a cached player
        // Creating a new playerItem from a cached asset can leave it stuck at .unknown status
        // Using getOrCreatePlayerItem ensures the playerItem is properly initialized and will become ready
        if SharedAssetCache.shared.getCachedPlayer(for: mid) != nil {
            print("DEBUG: [FullScreenVideoManager] ✅ Found cached player from MediaCell for \(mid), creating fresh playerItem from URL")
            
            // Load fresh playerItem from URL (uses cached asset internally but creates fresh item)
            Task.detached(priority: .userInitiated) {
                do {
                    // Use getOrCreatePlayerItem which creates a fresh playerItem that will properly initialize
                    let playerItem = try await SharedAssetCache.shared.getOrCreatePlayerItem(for: url, mediaID: mid, mediaType: mediaType)
                    
                    await MainActor.run {
                        // Ignore stale completions (e.g. duplicated loadVideo calls from view recreations)
                        guard self.loadGeneration == generation, self.currentVideoMid == mid else {
                            print("DEBUG: [FullScreenVideoManager] Ignoring stale playerItem completion for \(mid)")
                            return
                        }
                        self.loadingMid = nil

                        // Ensure audio session uses playback category so hardware mute switch doesn't silence fullscreen video
                        AudioSessionManager.shared.activateForVideoPlayback()
                        
                        // Create or reuse singleton player (fullscreen's unique player instance)
                        if self.singletonPlayer == nil {
                            self.singletonPlayer = AVPlayer(playerItem: playerItem)
                            print("DEBUG: [FullScreenVideoManager] Created singleton player with fresh playerItem")
                        } else {
                            print("DEBUG: [FullScreenVideoManager] Reusing singleton player with fresh playerItem")
                            self.singletonPlayer?.replaceCurrentItem(with: playerItem)
                        }
                        
                        // Configure fullscreen-specific buffering behavior
                        if mediaType == .video {
                            self.singletonPlayer?.automaticallyWaitsToMinimizeStalling = true
                            playerItem.preferredForwardBufferDuration = max(playerItem.preferredForwardBufferDuration, 30.0)
                        } else {
                            self.singletonPlayer?.automaticallyWaitsToMinimizeStalling = false
                        }
                        
                        // Always unmuted in fullscreen
                        self.singletonPlayer?.isMuted = false
                        
                        // CRITICAL: Setup fullscreen's unique functionality
                        // These observers are essential for auto-advance, retry monitoring, and buffering detection
                        self.setupVideoCompletionObserver(playerItem)
                        self.setupTimeControlStatusObserver()
                        self.startRetryMonitoring()
                        
                        // Check if player item is ready
                        if playerItem.status == .readyToPlay {
                            print("DEBUG: [FullScreenVideoManager] Player item ready immediately")
                            
                            // Check if video finished in mediaCell - if so, restart from beginning
                            let duration = playerItem.duration
                            if duration.isValid && duration.seconds > 0 {
                                if VideoStateCache.shared.hasVideoFinishedInMediaCell(for: mid, duration: duration) {
                                    print("🔄 [FullScreenVideoManager] Video \(mid) finished in mediaCell - restarting from beginning")
                                    self.singletonPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                                        guard finished, let self = self else { return }
                                        Task { @MainActor in
                                            self.singletonPlayer?.play()
                                            self.isPlaying = true
                                            print("▶️ [FullScreenVideoManager] Restarted finished video from beginning")
                                        }
                                    }
                                    return
                                }
                            }
                            
                            // Check for saved position and restore it
                            if PersistentVideoStateManager.shared.shouldRestorePlayback(videoMid: mid, context: .fullScreen),
                               let savedState = PersistentVideoStateManager.shared.getState(videoMid: mid, context: .fullScreen) {
                                print("🔄 [FullScreenVideoManager] Restoring saved position: \(savedState.currentTime.seconds)s, wasPlaying: \(savedState.wasPlaying)")
                                
                                self.singletonPlayer?.seek(to: savedState.currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                                    guard finished, let self = self else { return }
                                    
                                    Task { @MainActor in
                                        print("✅ [FullScreenVideoManager] Restored position to \(savedState.currentTime.seconds)s")
                                        
                                        if savedState.wasPlaying {
                                            self.singletonPlayer?.play()
                                            self.isPlaying = true
                                            print("▶️ [FullScreenVideoManager] Resumed playback from saved position")
                                        }
                                    }
                                }
                            } else {
                                // No saved state, check position and rewind if at end before playing
                                self.checkAndRewindIfAtEnd {
                                    self.singletonPlayer?.play()
                                    self.isPlaying = true
                                    print("DEBUG: [FullScreenVideoManager] Started playback with fresh playerItem")
                                }
                            }
                        } else {
                            print("DEBUG: [FullScreenVideoManager] Player item not ready yet (status: \(playerItem.status.rawValue)), will play when ready")
                            self.isPlaying = true // Mark as "should be playing"
                        }
                        
                        print("DEBUG: [FullScreenVideoManager] ✅ Created fresh playerItem for fullscreen - mid: \(mid)")
                    }
                } catch {
                    await MainActor.run {
                        guard self.loadGeneration == generation, self.currentVideoMid == mid else {
                            print("DEBUG: [FullScreenVideoManager] Ignoring stale load error for \(mid): \(error)")
                            return
                        }
                        self.loadingMid = nil
                        print("ERROR: [FullScreenVideoManager] Failed to create fresh playerItem: \(error), falling back to normal load")
                        // Fall through to normal load path below
                    }
                }
            }
            // Return early - we're loading asynchronously
            return
        }
        
        // No cached player - load video asynchronously
        Task.detached(priority: .userInitiated) {
            do {
                let asset = try await SharedAssetCache.shared.getAsset(for: url, tweetId: tweetId)
                let playerItem = await AVPlayerItem(asset: asset)
                
                await MainActor.run {
                    // Ignore stale completions
                    guard self.loadGeneration == generation, self.currentVideoMid == mid else {
                        print("DEBUG: [FullScreenVideoManager] Ignoring stale asset completion for \(mid)")
                        return
                    }
                    self.loadingMid = nil

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
                        print("DEBUG: [FullScreenVideoManager] Player item ready immediately, checking for saved position")
                        
                        // Check if video finished in mediaCell - if so, restart from beginning
                        let duration = playerItem.duration
                        if duration.isValid && duration.seconds > 0 {
                            if VideoStateCache.shared.hasVideoFinishedInMediaCell(for: mid, duration: duration) {
                                print("🔄 [FullScreenVideoManager] Video \(mid) finished in mediaCell - restarting from beginning")
                                self.singletonPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                                    guard finished, let self = self else { return }
                                    Task { @MainActor in
                                        self.singletonPlayer?.play()
                                        self.isPlaying = true
                                        print("▶️ [FullScreenVideoManager] Restarted finished video from beginning")
                                    }
                                }
                                return
                            }
                        }
                        
                        // Check for saved position and restore it
                        let shouldRestore = PersistentVideoStateManager.shared.shouldRestorePlayback(videoMid: mid, context: .fullScreen)
                        let savedState = PersistentVideoStateManager.shared.getState(videoMid: mid, context: .fullScreen)
                        print("🔍 [FullScreenVideoManager] Checking saved state for \(mid): shouldRestore=\(shouldRestore), savedState=\(savedState != nil ? "exists (time=\(savedState!.currentTime.seconds)s)" : "nil")")
                        
                        if shouldRestore, let savedState = savedState {
                            print("🔄 [FullScreenVideoManager] Restoring saved position: \(savedState.currentTime.seconds)s, wasPlaying: \(savedState.wasPlaying)")
                            
                            self.singletonPlayer?.seek(to: savedState.currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                                guard finished, let self = self else { return }
                                
                                Task { @MainActor in
                                    print("✅ [FullScreenVideoManager] Restored position to \(savedState.currentTime.seconds)s")
                                    
                                    if savedState.wasPlaying {
                                        self.singletonPlayer?.play()
                                        self.isPlaying = true
                                        print("▶️ [FullScreenVideoManager] Resumed playback from saved position")
                                    }
                                }
                            }
                        } else {
                            print("⚠️ [FullScreenVideoManager] No saved state to restore, starting from beginning")
                            // No saved state, check position and rewind if at end before playing
                            self.checkAndRewindIfAtEnd {
                                self.singletonPlayer?.play()
                                self.isPlaying = true
                                print("DEBUG: [FullScreenVideoManager] Started playback after position check")
                            }
                        }
                    } else {
                        print("DEBUG: [FullScreenVideoManager] Player item not ready yet (status: \(playerItem.status.rawValue)), will play when ready via AVPlayerViewController observer")
                        self.isPlaying = true // Mark as "should be playing"
                    }
                    
                    print("DEBUG: [FullScreenVideoManager] ✅ Singleton player loaded - mid: \(mid), tweetId: \(tweetId), videoIndex: \(videoIndex)")
                }
            } catch {
                await MainActor.run {
                    guard self.loadGeneration == generation, self.currentVideoMid == mid else {
                        print("DEBUG: [FullScreenVideoManager] Ignoring stale load error for \(mid): \(error)")
                        return
                    }
                    self.loadingMid = nil

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
    
    /// Clean up all observers
    private func cleanupObservers() {
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
        hasRestoredPosition = false
        isSeekingToRestoredPosition = false
    }
    
    /// Setup timeControlStatus observer for buffering detection and autoplay
    private func setupTimeControlStatusObserver() {
        cleanupObservers()
        
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
            // 1. Buffer is explicitly empty AND we don't have significant buffered data (work around AVPlayer bug), OR
            // 2. Player is explicitly waiting, OR
            // 3. Item is ready but buffer is empty or very small (< 0.5s) and not likely to keep up
            // IMPORTANT: Don't trust isPlaybackBufferEmpty alone - it can be stuck at true after backgrounding
            // even when we have plenty of buffered data. Only show spinner if buffer is truly insufficient.
            let hasSignificantBuffer = hasBufferedData && bufferedDuration >= 1.0
            let shouldShowSpinner = (isBufferEmpty && !hasSignificantBuffer) || isWaiting || (itemStatus == .readyToPlay && (!hasBufferedData || (bufferedDuration < 0.5 && !isLikelyToKeepUp)))
            
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
                
                // CRITICAL: Check for saved state and restore position BEFORE playing
                if !self.hasRestoredPosition && !self.isSeekingToRestoredPosition && isReadyToPlay && hasEnoughBuffer {
                    // First check if video finished in mediaCell - if so, restart from beginning
                    if let videoMid = self.currentVideoMid {
                        let duration = item.duration
                        if duration.isValid && duration.seconds > 0 {
                            if VideoStateCache.shared.hasVideoFinishedInMediaCell(for: videoMid, duration: duration) {
                                NSLog("🔄 [FULLSCREEN DATA READY] Video \(videoMid) finished in mediaCell - restarting from beginning")
                                self.isSeekingToRestoredPosition = true
                                
                                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                                    guard finished, let self = self else { return }
                                    Task { @MainActor in
                                        self.hasRestoredPosition = true
                                        self.isSeekingToRestoredPosition = false
                                        player.play()
                                        self.isPlaying = true
                                        self.wasPlayingBeforeWaiting = false
                                        NSLog("▶️ [FULLSCREEN DATA READY] Restarted finished video from beginning")
                                    }
                                }
                                return // CRITICAL: Don't play yet, wait for seek to complete
                            }
                        }
                    }
                    
                    if let videoMid = self.currentVideoMid,
                       PersistentVideoStateManager.shared.shouldRestorePlayback(videoMid: videoMid, context: .fullScreen),
                       let savedState = PersistentVideoStateManager.shared.getState(videoMid: videoMid, context: .fullScreen) {
                        NSLog("🔄 [FULLSCREEN DATA READY] Restoring saved position: \(savedState.currentTime.seconds)s, wasPlaying: \(savedState.wasPlaying)")
                        // Mark as seeking to prevent multiple attempts and prevent playing
                        self.isSeekingToRestoredPosition = true
                        
                        player.seek(to: savedState.currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                            guard finished, let self = self else { return }
                            Task { @MainActor in
                                NSLog("✅ [FULLSCREEN DATA READY] Restored position to \(savedState.currentTime.seconds)s")
                                
                                // Mark as restored and clear seeking flag
                                self.hasRestoredPosition = true
                                self.isSeekingToRestoredPosition = false
                                
                                // Now play if it was playing before
                                if savedState.wasPlaying {
                                    player.play()
                                    self.isPlaying = true
                                    NSLog("▶️ [FULLSCREEN DATA READY] Resumed playback from saved position")
                                }
                                self.wasPlayingBeforeWaiting = false
                            }
                        }
                        return // CRITICAL: Don't play yet, wait for seek to complete
                    } else {
                        // No saved state to restore, mark as restored so we don't check again
                        self.hasRestoredPosition = true
                        NSLog("🔍 [FULLSCREEN DATA READY] No saved state found, will play from beginning")
                    }
                }
                
                // Don't play if we're currently seeking to restored position
                if self.isSeekingToRestoredPosition {
                    return // Still waiting for seek to complete
                }
                
                // Only play if we've already restored position (or there was no saved state)
                if !self.hasRestoredPosition {
                    return // Still waiting for restoration
                }
                
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
        // Don't navigate while app is backgrounding (e.g. user swipes up to go Home).
        guard UIApplication.shared.applicationState == .active else {
            print("DEBUG: [FullScreenVideoManager] Ignoring swipe-up navigateToNext while app not active")
            return
        }

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
        // CRITICAL: Save playback state before clearing
        if let player = singletonPlayer,
           let videoMid = currentVideoMid {
            let wasPlaying = player.rate > 0
            let currentTime = player.currentTime()
            
            PersistentVideoStateManager.shared.saveState(
                videoMid: videoMid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .fullScreen
            )
            print("💾 [FULLSCREEN] Saved playback state before clearing: \(currentTime.seconds)s, wasPlaying: \(wasPlaying)")
        }
        
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
        
        // Clean up timeControlStatus observers
        cleanupObservers()
        isBuffering = false
        
        print("DEBUG: [FullScreenVideoManager] Cleared video content (player instance retained)")
        
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
            
            // CRITICAL: Save state before clearing so recreation can restore it
            if let videoMid = currentVideoMid {
                let wasPlaying = player.rate > 0
                let currentTime = player.currentTime()
                PersistentVideoStateManager.shared.saveState(
                    videoMid: videoMid,
                    currentTime: currentTime,
                    wasPlaying: wasPlaying,
                    context: .fullScreen
                )
                NSLog("💾 [FullScreenVideoManager] Saved state before clearing broken player")
            }
            
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
        
        // Try to get persistent state first, fall back to local saved state
        let wasPlaying: Bool
        let seekTime: CMTime
        
        if let videoMid = currentVideoMid,
           PersistentVideoStateManager.shared.shouldRestorePlayback(videoMid: videoMid, context: .fullScreen),
           let persistentState = PersistentVideoStateManager.shared.getState(videoMid: videoMid, context: .fullScreen) {
            // Use persistent state (survives player recreation)
            wasPlaying = persistentState.wasPlaying
            seekTime = persistentState.currentTime
            print("DEBUG: [FullScreenVideoManager] Using persistent state - wasPlaying: \(wasPlaying), time: \(seekTime.seconds)")
        } else if let savedState = savedPlaybackState {
            // Use local saved state (same session)
            wasPlaying = savedState.wasPlaying
            seekTime = savedState.time
            print("DEBUG: [FullScreenVideoManager] Using saved state - wasPlaying: \(wasPlaying), time: \(seekTime.seconds)")
            savedPlaybackState = nil
        } else {
            // No saved state, use current
            wasPlaying = isPlaying
            seekTime = player.currentTime()
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

    // MARK: - DetailView lifecycle coordination
    // When navigating DetailView -> DetailView (quoted -> original), the first view's disappearance
    // must NOT immediately clear the singleton player, otherwise the next DetailView will go black.
    // We solve this by scheduling a delayed clear that gets cancelled when another detail view appears.
    private var activeDetailViewCount: Int = 0
    private var scheduledClearTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var didPrewarmFirstItem: Bool = false
    private var prewarmPlayer: AVPlayer? // separate from currentPlayer (doesn't affect detail playback state)

    func beginDetailViewSession() {
        activeDetailViewCount += 1
        scheduledClearTask?.cancel()
        scheduledClearTask = nil
    }

    func endDetailViewSession() {
        activeDetailViewCount = max(0, activeDetailViewCount - 1)
        guard activeDetailViewCount == 0 else { return }

        // Pause immediately to prevent audio bleed when leaving detail, but don't clear yet.
        // Clearing too early causes black flashes during push transitions.
        currentPlayer?.pause()
        isPlaying = false

        scheduledClearTask?.cancel()
        scheduledClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            guard self.activeDetailViewCount == 0 else { return }
            self.clearCurrentVideo()
        }
    }

    /// Prewarm the detail video pipeline by preparing a first AVPlayerItem at startup.
    /// Uses a dedicated hidden player so it won't affect the active detail singleton state.
    func prewarmFirstItemIfNeeded(url: URL, mediaID: String, mediaType: MediaType) {
        guard !didPrewarmFirstItem else { return }
        didPrewarmFirstItem = true

        if prewarmPlayer == nil {
            prewarmPlayer = AVPlayer()
            prewarmPlayer?.isMuted = true
        }

        prewarmTask?.cancel()
        prewarmTask = Task.detached(priority: .utility) { [url, mediaID, mediaType] in
            do {
                let item = try await SharedAssetCache.shared.getOrCreatePlayerItem(
                    for: url,
                    mediaID: mediaID,
                    mediaType: mediaType
                )
                await MainActor.run {
                    guard let player = self.prewarmPlayer else { return }
                    player.replaceCurrentItem(with: item)
                    player.pause()
                    // IMPORTANT: `preroll(atRate:)` will throw an Obj-C exception unless
                    // `player.status == .readyToPlay`. Never call it during prewarm unless ready.
                    if player.status == .readyToPlay {
                        player.preroll(atRate: 0.0) { _ in }
                    }
                    NSLog("✅ [DetailVideoManager] Prewarmed first item for \(mediaID)")
                }
            } catch {
                await MainActor.run {
                    NSLog("⚠️ [DetailVideoManager] Failed to prewarm first item for \(mediaID): \(error)")
                }
            }
        }
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

    /// Check if detail view is currently active (safe for Sendable contexts)
    @MainActor
    func isDetailViewActive() -> Bool {
        return currentPlayer != nil
    }
    
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
        
        // Check if we have saved state for this video
        let hasSavedState = PersistentVideoStateManager.shared.shouldRestorePlayback(
            videoMid: mid,
            context: .detailView
        )
        
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
                            // Restore saved position if available
                            if hasSavedState,
                               let savedState = PersistentVideoStateManager.shared.getState(videoMid: mid, context: .detailView) {
                                print("🔄 [DETAIL VIDEO MANAGER] Restoring saved position: \(savedState.currentTime.seconds)s, wasPlaying: \(savedState.wasPlaying)")
                                self.currentPlayer?.seek(to: savedState.currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                                    guard finished, let self = self else { return }
                                    Task { @MainActor in
                                        if autoPlay || savedState.wasPlaying {
                                            self.currentPlayer?.play()
                                            self.isPlaying = true
                                            print("▶️ [DETAIL VIDEO MANAGER] Resumed playback from saved position")
                                        }
                                    }
                                }
                            } else if autoPlay {
                                self.currentPlayer?.play()
                                self.isPlaying = true
                            }
                        }
                    }
                    
                    // Auto-play immediately if requested and no saved state
                    if autoPlay && !hasSavedState {
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
        // CRITICAL: Save playback state before clearing
        if let player = currentPlayer,
           let videoMid = currentVideoMid {
            let wasPlaying = player.rate > 0
            let currentTime = player.currentTime()
            
            PersistentVideoStateManager.shared.saveState(
                videoMid: videoMid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .detailView
            )
            print("💾 [DETAIL VIDEO MANAGER] Saved playback state before clearing: \(currentTime.seconds)s, wasPlaying: \(wasPlaying)")
        }
        
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
            
            // CRITICAL: Save state before clearing so recreation can restore it
            if let videoMid = currentVideoMid {
                let wasPlaying = player.rate > 0
                let currentTime = player.currentTime()
                PersistentVideoStateManager.shared.saveState(
                    videoMid: videoMid,
                    currentTime: currentTime,
                    wasPlaying: wasPlaying,
                    context: .detailView
                )
                NSLog("💾 [DetailVideoManager] Saved state before clearing broken player")
            }
            
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
        
        // Try to get persistent state first, fall back to local saved state
        let wasPlaying: Bool
        let seekTime: CMTime
        
        if let videoMid = currentVideoMid,
           PersistentVideoStateManager.shared.shouldRestorePlayback(videoMid: videoMid, context: .detailView),
           let persistentState = PersistentVideoStateManager.shared.getState(videoMid: videoMid, context: .detailView) {
            // Use persistent state (survives player recreation)
            wasPlaying = persistentState.wasPlaying
            seekTime = persistentState.currentTime
            print("DEBUG: [DetailVideoManager] Using persistent state - wasPlaying: \(wasPlaying), time: \(seekTime.seconds)")
        } else if let savedState = savedPlaybackState {
            // Use local saved state (same session)
            wasPlaying = savedState.wasPlaying
            seekTime = savedState.time
            print("DEBUG: [DetailVideoManager] Using saved state - wasPlaying: \(wasPlaying), time: \(seekTime.seconds)")
            savedPlaybackState = nil
        } else {
            // No saved state, use current
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
    
}
