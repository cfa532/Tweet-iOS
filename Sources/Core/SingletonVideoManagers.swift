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
            return true
        }
        
        guard let currentItem = player.currentItem else {
            return true
        }
        
        // Check if player item is in failed state
        if currentItem.status == .failed {
            return true
        }
        
        // Check if player item has an error (even if status isn't .failed yet)
        if currentItem.error != nil {
            return true
        }
        
        // Check if player has an error
        if player.error != nil {
            return true
        }
        
        // For screen lock recovery, don't check loadedTimeRanges
        // iOS might temporarily clear this data, but it will reload
        // Only check loadedTimeRanges if status is .readyToPlay AND duration is invalid
        if currentItem.status == .readyToPlay && 
           currentItem.loadedTimeRanges.isEmpty && 
           !currentItem.duration.isValid {
            return true
        }
        
        return false
    }
    
    // Default implementation - subclasses can override to store observers
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
        
        // Get duration for end-check
        let duration = player.currentItem?.duration ?? .invalid
        
        // CRITICAL: Also save to persistent storage so it survives player recreation
        if let detailManager = self as? DetailVideoManager,
           let videoMid = detailManager.currentVideoMid {
            PersistentVideoStateManager.shared.saveState(
                videoMid: videoMid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .detailView,
                duration: duration
            )
        } else if let fullscreenManager = self as? FullScreenVideoManager,
                  let videoMid = fullscreenManager.currentVideoMid {
            PersistentVideoStateManager.shared.saveState(
                videoMid: videoMid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .fullScreen,
                duration: duration
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
        print("DEBUG: [\(String(describing: type(of: self)))] App entering foreground, recovering from background")
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
            print("DEBUG: [\(managerName)] Already recovered in willEnterForeground")
            // No additional checks needed - if player is broken, the view will handle it
        }
        
        // DON'T do delayed health checks
        // If manager is active, it manages its own player directly
        // If manager is inactive, it shouldn't be running checks at all
    }
}

/// Singleton video manager for fullscreen video playback with auto-advance
/// Uses a dedicated singleton player instance independent from MediaCell players
@MainActor
class FullScreenVideoManager: ObservableObject, VideoPlayerLifecycleManager {
    static let shared = FullScreenVideoManager()
    private init() {
        // Pre-create player so it's ready when fullscreen opens (no creation delay)
        singletonPlayer = AVPlayer()
        // DON'T setup lifecycle notifications in init
        // They're registered when fullscreen becomes active
    }
    
    // MARK: - Lifecycle Management
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var isActive: Bool = false
    
    /// Activate manager when fullscreen view appears
    func activateForFullscreen() {
        // Pause any detail view videos when entering fullscreen mode
        // This ensures videos playing in TweetDetailView or CommentDetailView are paused
        // when opening attachments in fullscreen, but can resume when fullscreen closes
        if DetailVideoManager.shared.getPlayer()?.rate ?? 0 > 0 {
            DetailVideoManager.shared.pausePlayer()
            print("🎬 [FullScreenVideoManager] Paused detail view videos before activating fullscreen")
        }

        guard !isActive else { return }
        isActive = true
        registerLifecycleObservers()
        print("🎬 [FullScreenVideoManager] Activated - lifecycle observers registered")
    }
    
    /// Deactivate manager when fullscreen view disappears
    func deactivate() {
        guard isActive else { return }
        isActive = false
        teardownAppLifecycleNotifications()

        // Save playback position so the feed cell and the next fullscreen open can restore it.
        // Do NOT call clearSingletonPlayer() here — keeping the item alive means re-opening
        // the same video is instant (loadVideo() short-circuits and resumes without a network
        // round-trip). clearSingletonPlayer() is called by loadVideo() when a DIFFERENT video
        // is requested, or by recoverFromBackground() when the player becomes broken.
        if let player = singletonPlayer,
           let videoMid = currentVideoMid,
           player.currentItem != nil {
            let wasPlaying = player.rate > 0
            let currentTime = player.currentTime()
            let duration = player.currentItem?.duration ?? .invalid
            PersistentVideoStateManager.shared.saveState(
                videoMid: videoMid, currentTime: currentTime,
                wasPlaying: wasPlaying, context: .fullScreen, duration: duration)
            PersistentVideoStateManager.shared.saveState(
                videoMid: videoMid, currentTime: currentTime,
                wasPlaying: wasPlaying, context: .mediaCell, duration: duration)
        }
        singletonPlayer?.pause()
        isPlaying = false

        // Cancel all timers and observers that could wake the player back up.
        // Without this, retryWorkItem fires after 3 s, sees rate==0, and calls
        // player.play() — causing audio to bleed into the feed after dismiss.
        retryWorkItem?.cancel()
        retryWorkItem = nil
        bufferObserver?.invalidate()
        bufferObserver = nil
        cleanupObservers()         // removes timeControlStatus, buffer, loaded-ranges KVO
        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
        isBuffering = false

        // Capture a still frame from the singleton player so the feed cell has a
        // thumbnail cover while its own player layer re-initialises on return.
        // This matters most when the feed cell was still loading when fullscreen
        // opened — VideoLastFrameCache will be empty but the fullscreen played
        // the video, so we can extract a frame from its (already-buffered) asset.
        if let player = singletonPlayer,
           let asset = player.currentItem?.asset,
           let videoMid = currentVideoMid,
           VideoLastFrameCache.shared.image(for: videoMid) == nil {
            let captureTime = player.currentTime()
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)
            Task.detached(priority: .utility) {
                if let cgImage = try? generator.copyCGImage(at: captureTime, actualTime: nil) {
                    let image = UIImage(cgImage: cgImage)
                    await MainActor.run {
                        VideoLastFrameCache.shared.set(image, for: videoMid)
                    }
                }
            }
        }

        print("🎬 [FullScreenVideoManager] Deactivated - observers cancelled, player preserved for re-entry")
    }

    /// Set the feed's video list for fullscreen browsing (called before presenting MediaBrowserView)
    func setVideoList(_ list: [VideoPlaybackInfo], startIndex: Int) {
        videoList = list
        videoListIndex = list.isEmpty ? 0 : max(0, min(startIndex, list.count - 1))
        print("🎬 [FullScreenVideoManager] Video list set: \(list.count) videos, startIndex: \(videoListIndex)")
    }

    private func teardownAppLifecycleNotifications() {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
    }

    // Register lifecycle observers and store tokens for later removal
    private func registerLifecycleObservers() {
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleAppWillResignActive()
                }
            }
        )
        
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleAppDidEnterBackground()
                }
            }
        )
        
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleAppWillEnterForeground()
                }
            }
        )
        
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleAppDidBecomeActive()
                }
            }
        )

        // CRITICAL: Listen for reloadVisibleVideosOnly to recover from long background
        // AppDelegate posts this after infrastructure restart completes
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: .reloadVisibleVideosOnly,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleReloadVisibleVideosOnly()
                }
            }
        )
    }

    // MARK: - VideoPlayerLifecycleManager Protocol
    var savedPlaybackState: (wasPlaying: Bool, time: CMTime)?
    var hasRecoveredThisCycle = false
    
    func getPlayer() -> AVPlayer? {
        ensurePlayerInitialized()
        return singletonPlayer
    }

    /// Ensure singleton player is initialized (called lazily)
    private func ensurePlayerInitialized() {
        guard singletonPlayer == nil else { return }
        singletonPlayer = AVPlayer()
        singletonPlayer?.isMuted = false
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
        // Don't nil out the player - keep it for reuse
        isPlaying = false
    }
    
    // Independent singleton player for fullscreen mode
    @Published var singletonPlayer: AVPlayer?
    @Published var currentVideoMid: String?
    @Published var currentTweetId: String?
    @Published var currentCellTweetId: String? // The visible cell's tweet ID in feed (retweet ID for retweets, quoting tweet ID for quotes)
    @Published var currentVideoIndex: Int = 0 // Track current video index within tweet
    @Published var isPlaying = false
    @Published var isBuffering = false // Track buffering state for spinner
    /// True once the current item has status .readyToPlay (i.e. first frame decoded).
    /// Used by SingletonVideoPlayerView to show a thumbnail cover while the item loads.
    @Published var isItemReady = false
    
    // Callback to navigate to next video (tweet, videoIndex, sourceTweetId)
    var onNavigateToNextVideo: ((Tweet, Int, String) -> Void)?
    var onExitFullScreen: (() -> Void)?

    // Feed video list for fullscreen browsing (set by MediaCellUIView on open)
    private var videoList: [VideoPlaybackInfo] = []
    private var videoListIndex: Int = 0

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
    
    // Debouncing for buffering state to prevent rapid spinner blinking during seeks
    private var bufferingDebounceTask: DispatchWorkItem?

    // Prevent stale async loads from clobbering current state (fixes stuck spinner after repeated opens)
    private var loadGeneration: Int = 0
    private var loadingMid: String?

    // MARK: - Navigation Debounce
    /// Prevent multiple rapid swipe-ups (or duplicate gesture endings) from racing navigation.
    /// Without this, a second swipe can execute before `currentVideoMid/currentVideoIndex/currentCellTweetId`
    /// are updated for the first navigation, leading to spurious "no next" and fullscreen dismissal.
    private var nextNavigationAllowedAt: Date = .distantPast
    private let navigationDebounceInterval: TimeInterval = 0.6
    
    private func canNavigateNow() -> Bool {
        let now = Date()
        if now < nextNavigationAllowedAt { return false }
        nextNavigationAllowedAt = now.addingTimeInterval(navigationDebounceInterval)
        return true
    }

    // MARK: - Prewarm (startup UX)
    // Preload a first AVPlayerItem to reduce first-open latency.
    private var didPrewarmFirstItem: Bool = false
    private var prewarmTask: Task<Void, Never>?
    
    /// Initialize singleton player early (called during app startup)
    func initializePlayerEarly() {
        guard singletonPlayer == nil else {
            return
        }
        
        // Create empty player instance to warm up AVFoundation infrastructure
        singletonPlayer = AVPlayer()
        singletonPlayer?.isMuted = false
        
    }

    /// Prewarm the singleton by creating (and optionally attaching) a first AVPlayerItem.
    /// This should NOT start playback.
    func prewarmFirstItemIfNeeded(url: URL, mediaID: String, mediaType: MediaType) {
        guard !didPrewarmFirstItem else { return }
        didPrewarmFirstItem = true

        // Ensure the singleton player exists.
        initializePlayerEarly()

        prewarmTask?.cancel()
        prewarmTask = Task.detached(priority: .utility) {
            // Just accessing the item warms up the asset cache
            // The item will be cached and ready for quick loading later
            await MainActor.run {
                // Don't attach to player - just warm up the cache
            }
        }
    }
    
    /// Load and play a video in the singleton player
    func loadVideo(url: URL, mid: String, tweetId: String, cellTweetId: String, videoIndex: Int, mediaType: MediaType) {

        // If we already have the correct item loaded (e.g. re-entering fullscreen after dismiss
        // without clearSingletonPlayer()), resume playback without thrashing observers/state.
        // Fall through if the player is broken (background stripped the pipeline) so the full
        // reload path runs and recreates a healthy AVPlayerItem.
        if currentVideoMid == mid,
           currentTweetId == tweetId,
           !isPlayerBroken() {
            setupTimeControlStatusObserver()
            if isItemReady {
                // Item is ready — rewind if at end, then play.
                isPlaying = true
                let capturedPlayer = singletonPlayer
                checkAndRewindIfAtEnd {
                    capturedPlayer?.play()
                }
            } else {
                // Item exists but not yet ready — mark intent; itemStatusObserver will play when ready.
                isPlaying = true
            }
            return
        }
        
        // CRITICAL: If we're already loading this exact video, ignore duplicate calls
        // This prevents race conditions from multiple onAppear handlers calling loadVideo
        if loadingMid == mid && currentVideoMid == mid {
            return
        }
        
        // Clear any previously preserved item before loading a new video.
        // Also save position for the old video so it can be restored later.
        if let player = singletonPlayer, player.currentItem != nil, currentVideoMid != mid {
            if let oldMid = currentVideoMid, player.currentItem != nil {
                let t = player.currentTime()
                let d = player.currentItem?.duration ?? .invalid
                PersistentVideoStateManager.shared.saveState(
                    videoMid: oldMid, currentTime: t, wasPlaying: player.rate > 0,
                    context: .fullScreen, duration: d)
                PersistentVideoStateManager.shared.saveState(
                    videoMid: oldMid, currentTime: t, wasPlaying: player.rate > 0,
                    context: .mediaCell, duration: d)
            }
            player.pause()
            player.replaceCurrentItem(with: nil)
        }

        // Bump generation so any prior async completions are ignored.
        loadGeneration += 1
        let generation = loadGeneration
        loadingMid = mid
        hasRestoredPosition = false // Reset restoration flag when loading new video
        isSeekingToRestoredPosition = false // Reset seeking flag
        isItemReady = false // Will be set true when playerItem.status becomes .readyToPlay
        
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
        self.currentCellTweetId = cellTweetId
        self.currentVideoIndex = videoIndex
        
        // CRITICAL: Create new playerItem from cached asset to avoid network timeout
        // The cached player already has the asset loaded, so we create a new playerItem from that asset
        // This avoids network requests while allowing the new playerItem to be associated with our player
        if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: mid),
           let cachedPlayerItem = cachedPlayer.currentItem {

            // Create new playerItem from cached asset (fast, no network request).
            // NOTE: Reusing cachedPlayerItem directly was attempted (loan path) but
            // AVFoundation's XPC renderer doesn't process replaceCurrentItem(nil) before
            // the subsequent replaceCurrentItem(item) on singletonPlayer even when both
            // calls are in the same synchronous Task body, causing a reliable crash:
            // "AVPlayerItem cannot be associated with more than one instance of AVPlayer"
            // Using AVPlayerItem(asset:) gives us a fresh item that avoids this constraint
            // while still sharing the same underlying AVURLAsset (local HTTP proxy URL).
            let playerItem = AVPlayerItem(asset: cachedPlayerItem.asset)

            Task { @MainActor in
                // Ignore stale completions (e.g. duplicated loadVideo calls from view recreations)
                guard self.loadGeneration == generation, self.currentVideoMid == mid else {
                    return
                }
                self.loadingMid = nil

                // Ensure audio session uses playback category so hardware mute switch doesn't silence fullscreen video
                AudioSessionManager.shared.activateForVideoPlayback()

                // Create or reuse singleton player (fullscreen's unique player instance)
                if self.singletonPlayer == nil {
                    self.singletonPlayer = AVPlayer(playerItem: playerItem)
                } else {
                    self.singletonPlayer?.replaceCurrentItem(with: playerItem)
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
                    self.isItemReady = true
                    
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
                        // CRITICAL: Validate saved time before seeking to prevent crash
                        guard savedState.currentTime.isValid && savedState.currentTime.seconds.isFinite else {
                            print("⚠️ [FullScreenVideoManager] Invalid saved time (\(savedState.currentTime.seconds)s) - clearing and starting normally")
                            PersistentVideoStateManager.shared.clearState(videoMid: mid, context: .fullScreen)
                            self.checkAndRewindIfAtEnd {
                                self.singletonPlayer?.play()
                                self.isPlaying = true
                            }
                            return
                        }
                        
                        print("🔄 [FullScreenVideoManager] Restoring saved position: \(savedState.currentTime.seconds)s")
                        
                        self.singletonPlayer?.seek(to: savedState.currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                            guard finished, let self = self else { return }
                            
                            Task { @MainActor in
                                print("✅ [FullScreenVideoManager] Restored position to \(savedState.currentTime.seconds)s")
                                
                                // CRITICAL: Fullscreen should always auto-play, regardless of wasPlaying state
                                self.singletonPlayer?.play()
                                self.isPlaying = true
                                print("▶️ [FullScreenVideoManager] Started playback from saved position")
                            }
                        }
                    } else {
                        // No saved state, check position and rewind if at end before playing
                        self.checkAndRewindIfAtEnd {
                            self.singletonPlayer?.play()
                            self.isPlaying = true
                        }
                    }
                } else {
                    self.isPlaying = true // Mark as "should be playing"
                    
                    // CRITICAL: Observe playerItem status to start playback when it becomes ready
                    self.itemStatusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                        guard let self = self else { return }
                        
                        DispatchQueue.main.async {
                            guard item.status == .readyToPlay else {
                                if item.status == .failed {
                                    print("❌ [FullScreenVideoManager] PlayerItem failed to load: \(item.error?.localizedDescription ?? "unknown")")
                                }
                                return
                            }
                            
                            print("✅ [FullScreenVideoManager] Cached playerItem became ready, starting playback")
                            self.isItemReady = true
                            
                            // Check if video finished in mediaCell - if so, restart from beginning
                            let duration = item.duration
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
                                // CRITICAL: Validate saved time before seeking to prevent crash
                                guard savedState.currentTime.isValid && savedState.currentTime.seconds.isFinite else {
                                    print("⚠️ [FullScreenVideoManager] Invalid saved time (\(savedState.currentTime.seconds)s) - clearing and starting normally")
                                    PersistentVideoStateManager.shared.clearState(videoMid: mid, context: .fullScreen)
                                    self.checkAndRewindIfAtEnd {
                                        self.singletonPlayer?.play()
                                        self.isPlaying = true
                                        print("▶️ [FullScreenVideoManager] Started playback after invalid state cleared")
                                    }
                                    return
                                }
                                
                                print("🔄 [FullScreenVideoManager] Restoring saved position: \(savedState.currentTime.seconds)s (deferred)")
                                
                                self.singletonPlayer?.seek(to: savedState.currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                                    guard finished, let self = self else { return }
                                    
                                    Task { @MainActor in
                                        print("✅ [FullScreenVideoManager] Restored position to \(savedState.currentTime.seconds)s (deferred)")
                                        
                                        // CRITICAL: Fullscreen should always auto-play, regardless of wasPlaying state
                                        self.singletonPlayer?.play()
                                        self.isPlaying = true
                                        print("▶️ [FullScreenVideoManager] Started playback from saved position (deferred)")
                                    }
                                }
                            } else {
                                // No saved state, check position and rewind if at end before playing
                                self.checkAndRewindIfAtEnd {
                                    self.singletonPlayer?.play()
                                    self.isPlaying = true
                                    print("▶️ [FullScreenVideoManager] Started playback with cached playerItem (deferred)")
                                }
                            }
                            
                            // Clean up observer after handling
                            self.itemStatusObserver?.invalidate()
                            self.itemStatusObserver = nil
                        }
                    }
                }
                
            }
            return
        }
        
        // No cached player - load video asynchronously
        Task.detached(priority: .userInitiated) {
            do {
                let asset = try await SharedAssetCache.shared.getAsset(for: url, tweetId: tweetId, mediaType: mediaType)
                let playerItem = await AVPlayerItem(asset: asset)
                
                await MainActor.run {
                    // Ignore stale completions
                    guard self.loadGeneration == generation, self.currentVideoMid == mid else {
                        return
                    }
                    self.loadingMid = nil

                    // Ensure audio session uses playback category so hardware mute switch doesn't silence fullscreen video
                    AudioSessionManager.shared.activateForVideoPlayback()
                    
                    // Create or reuse singleton player
                    if self.singletonPlayer == nil {
                        self.singletonPlayer = AVPlayer(playerItem: playerItem)
                    } else {
                        self.singletonPlayer?.replaceCurrentItem(with: playerItem)
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
                            // CRITICAL: Validate saved time before seeking to prevent crash
                            guard savedState.currentTime.isValid && savedState.currentTime.seconds.isFinite else {
                                print("⚠️ [FullScreenVideoManager] Invalid saved time (\(savedState.currentTime.seconds)s) - clearing and starting from beginning")
                                PersistentVideoStateManager.shared.clearState(videoMid: mid, context: .fullScreen)
                                // Start from beginning - fullscreen should always auto-play
                                self.checkAndRewindIfAtEnd {
                                    self.singletonPlayer?.play()
                                    self.isPlaying = true
                                    print("▶️ [FullScreenVideoManager] Started playback from beginning (after clearing invalid state)")
                                }
                                return
                            }
                            
                            print("🔄 [FullScreenVideoManager] Restoring saved position: \(savedState.currentTime.seconds)s, wasPlaying: \(savedState.wasPlaying)")
                            
                            self.singletonPlayer?.seek(to: savedState.currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                                guard finished, let self = self else { return }
                                
                                Task { @MainActor in
                                    print("✅ [FullScreenVideoManager] Restored position to \(savedState.currentTime.seconds)s")
                                    
                                    // CRITICAL: Fullscreen should always auto-play, regardless of wasPlaying state
                                    self.singletonPlayer?.play()
                                    self.isPlaying = true
                                    print("▶️ [FullScreenVideoManager] Started playback from saved position")
                                }
                            }
                        } else {
                            print("⚠️ [FullScreenVideoManager] No saved state to restore, starting from beginning")
                            // No saved state, check position and rewind if at end before playing
                            self.checkAndRewindIfAtEnd {
                                self.singletonPlayer?.play()
                                self.isPlaying = true
                            }
                        }
                    } else {
                        self.isPlaying = true // Mark as "should be playing"
                    }
                    
                }
            } catch {
                await MainActor.run {
                    guard self.loadGeneration == generation, self.currentVideoMid == mid else {
                        return
                    }
                    self.loadingMid = nil

                    print("ERROR: [FullScreenVideoManager] Failed to load video: \(error)")
                    // Clear state but keep the pre-created player alive
                    self.singletonPlayer?.replaceCurrentItem(with: nil)
                    self.currentVideoMid = nil
                    self.currentTweetId = nil
                    self.currentCellTweetId = nil
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
        
        // Cancel any pending buffering debounce task
        bufferingDebounceTask?.cancel()
        bufferingDebounceTask = nil
    }
    
    /// Setup timeControlStatus observer for buffering detection and autoplay
    private func setupTimeControlStatusObserver() {
        cleanupObservers()
        
        guard let player = singletonPlayer, let playerItem = player.currentItem else {
            return
        }
        
        
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
                }
                
                // Debounce: Only show spinner if buffering lasts > 0.5 seconds
                // This prevents flashing spinner during brief buffering pauses (e.g., during seeking)
                if !self.isBuffering {
                    // Cancel any pending hide task
                    self.bufferingDebounceTask?.cancel()
                    
                    let task = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        self.isBuffering = true
                    }
                    self.bufferingDebounceTask = task
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
                }
            } else {
                // Player has enough data - hide spinner immediately (no debounce for hiding)
                // Cancel any pending show task
                self.bufferingDebounceTask?.cancel()
                
                if self.isBuffering {
                    self.isBuffering = false
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
                                self.isSeekingToRestoredPosition = true
                                
                                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                                    guard finished, let self = self else { return }
                                    Task { @MainActor in
                                        self.hasRestoredPosition = true
                                        self.isSeekingToRestoredPosition = false
                                        player.play()
                                        self.isPlaying = true
                                        self.wasPlayingBeforeWaiting = false
                                    }
                                }
                                return // CRITICAL: Don't play yet, wait for seek to complete
                            }
                        }
                    }
                    
                    if let videoMid = self.currentVideoMid,
                       PersistentVideoStateManager.shared.shouldRestorePlayback(videoMid: videoMid, context: .fullScreen),
                       let savedState = PersistentVideoStateManager.shared.getState(videoMid: videoMid, context: .fullScreen) {
                        // CRITICAL: Validate saved time before seeking to prevent crash
                        guard savedState.currentTime.isValid && savedState.currentTime.seconds.isFinite else {
                            PersistentVideoStateManager.shared.clearState(videoMid: videoMid, context: .fullScreen)
                            self.hasRestoredPosition = true
                            self.isSeekingToRestoredPosition = false
                            player.play()
                            self.isPlaying = true
                            self.wasPlayingBeforeWaiting = false
                            return
                        }
                        
                        // Mark as seeking to prevent multiple attempts and prevent playing
                        self.isSeekingToRestoredPosition = true
                        
                        player.seek(to: savedState.currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                            guard finished, let self = self else { return }
                            Task { @MainActor in
                                
                                // Mark as restored and clear seeking flag
                                self.hasRestoredPosition = true
                                self.isSeekingToRestoredPosition = false
                                
                                // CRITICAL: Fullscreen should always auto-play, regardless of wasPlaying state
                                player.play()
                                self.isPlaying = true
                                self.wasPlayingBeforeWaiting = false
                            }
                        }
                        return // CRITICAL: Don't play yet, wait for seek to complete
                    } else {
                        // No saved state to restore, mark as restored so we don't check again
                        self.hasRestoredPosition = true
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
                    player.play()
                    self.isPlaying = true
                    self.wasPlayingBeforeWaiting = false
                } else if player.timeControlStatus == .playing || player.rate > 0 {
                    // Already playing - just reset flag
                    if self.wasPlayingBeforeWaiting {
                        self.wasPlayingBeforeWaiting = false
                    }
                } else if wantsToPlay && isReadyToPlay && hasEnoughBuffer {
                    // Fallback: try to play even if rate check didn't catch it
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
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                // CRITICAL FIX: Validate that video actually finished
                // Check that current time is near the end of duration
                guard let player = self.singletonPlayer,
                      let item = player.currentItem else {
                    print("⚠️ [FullScreenVideoManager] Video finished notification but no player/item")
                    return
                }
                
                let currentTime = player.currentTime()
                let duration = item.duration
                
                // Validate duration is valid
                guard duration.isValid, duration.seconds > 0 else {
                    print("⚠️ [FullScreenVideoManager] Video finished notification but duration is invalid (\(duration.seconds)s)")
                    return
                }
                
                // Check if we're actually at the end (within 0.5 seconds of duration)
                let timeUntilEnd = duration.seconds - currentTime.seconds
                guard timeUntilEnd < 0.5 else {
                    print("⚠️ [FullScreenVideoManager] Ignoring premature finish notification - current: \(currentTime.seconds)s, duration: \(duration.seconds)s, remaining: \(timeUntilEnd)s")
                    return
                }
                
                print("✅ [FullScreenVideoManager] Video legitimately finished - current: \(currentTime.seconds)s, duration: \(duration.seconds)s")
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
        // Don't retry if fullscreen is no longer active — player was intentionally paused.
        guard isActive else { return }
        guard let player = singletonPlayer, let playerItem = player.currentItem else { return }
        
        // If player is stuck (not playing and rate is 0), force a seek to trigger reload
        if player.rate == 0 && player.timeControlStatus != .playing {
            let currentTime = player.currentTime()
            
            // Clean up old observer
            bufferObserver?.invalidate()
            bufferObserver = nil
            
            // Force seek to current position to trigger segment download
            player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player, weak playerItem] finished in
                guard finished, let self = self, let player = player, let item = playerItem else { return }
                
                Task { @MainActor in
                    
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
                                
                                // Clean up observer
                                self.bufferObserver?.invalidate()
                                self.bufferObserver = nil
                                
                                // Resume playback
                                if player.rate == 0 {
                                    player.play()
                                }
                                
                                // Continue monitoring for future stalls
                                self.startRetryMonitoring()
                            }
                        } else if hasData {
                        }
                    }
                    
                    // Safety timeout: if no data after 20 seconds, give up this retry and continue monitoring
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20.0) { [weak self] in
                        Task { @MainActor in
                            guard let self = self else { return }
                            if self.bufferObserver != nil {
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
    
    /// Resolve the next playable video in the list, scanning forward from the given index.
    /// Skips entries whose Tweet/attachment can't be resolved or are no longer videos.
    private func resolveNextVideo(after index: Int) -> (tweet: Tweet, videoIndex: Int, cellTweetId: String, listIndex: Int)? {
        for i in (index + 1)..<videoList.count {
            let entry = videoList[i]
            guard let tweet = TweetCacheManager.shared.fetchTweetSync(mid: entry.mediaTweetId)
                    ?? Tweet.getInstance(for: entry.mediaTweetId),
                  let attachments = tweet.attachments,
                  entry.attachmentIndex < attachments.count else {
                continue
            }
            let attachment = attachments[entry.attachmentIndex]
            guard attachment.type == .video || attachment.type == .hls_video else { continue }
            return (tweet: tweet, videoIndex: entry.attachmentIndex, cellTweetId: entry.cellTweetId, listIndex: i)
        }
        return nil
    }

    /// Handle video completion and auto-advance to next video
    func handleVideoFinished() {
        // Guard against re-entrancy (finish event can fire twice during transitions / item swaps)
        guard canNavigateNow() else { return }
        isPlaying = false

        // Non-feed context (opened from detail view) — no auto-advance
        guard !videoList.isEmpty else { return }

        if let next = resolveNextVideo(after: videoListIndex) {
            videoListIndex = next.listIndex
            onNavigateToNextVideo?(next.tweet, next.videoIndex, next.cellTweetId)
            return
        }

        // End of list: keep last frame (user can swipe down to dismiss; don't auto-dismiss).
    }
    
    /// Check if video is at the end and rewind if needed before playing
    private func checkAndRewindIfAtEnd(completion: @escaping () -> Void) {
        guard let player = singletonPlayer, let playerItem = player.currentItem else {
            completion()
            return
        }
        
        // Check if player is broken - if so, clear item so view can reload
        if isPlayerBroken() {
            singletonPlayer?.pause()
            singletonPlayer?.replaceCurrentItem(with: nil)
            isPlaying = false
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
                player.seek(to: .zero) { [weak self] finished in
                    guard finished, let _ = self else {
                        completion()
                        return
                    }
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
        guard UIApplication.shared.applicationState == .active else { return }
        // Ignore rapid repeated swipe-ups.
        guard canNavigateNow() else { return }
        // Non-feed context — ignore swipe
        guard !videoList.isEmpty else { return }

        if let next = resolveNextVideo(after: videoListIndex) {
            videoListIndex = next.listIndex
            onNavigateToNextVideo?(next.tweet, next.videoIndex, next.cellTweetId)
            return
        }

        // End of list — dismiss fullscreen
        onExitFullScreen?()
    }
    
    /// Clear singleton player content (keeps player instance for reuse)
    func clearSingletonPlayer() {
        // Only save playback state if player actually loaded (has a currentItem).
        // If currentItem is nil (video never finished loading due to IPFS latency),
        // saving would write 0.0s and overwrite the valid position saved by the feed cell.
        if let player = singletonPlayer,
           let videoMid = currentVideoMid,
           player.currentItem != nil {
            let wasPlaying = player.rate > 0
            let currentTime = player.currentTime()
            let duration = player.currentItem?.duration ?? .invalid

            // Save to fullScreen context
            PersistentVideoStateManager.shared.saveState(
                videoMid: videoMid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .fullScreen,
                duration: duration
            )

            // ALSO save to mediaCell context so MediaCell can resume from this position
            PersistentVideoStateManager.shared.saveState(
                videoMid: videoMid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .mediaCell,
                duration: duration
            )
        }

        // Keep the pre-created player alive — just remove the current item
        singletonPlayer?.pause()
        singletonPlayer?.replaceCurrentItem(with: nil)

        isItemReady = false
        currentVideoMid = nil
        currentTweetId = nil
        currentCellTweetId = nil
        currentVideoIndex = 0
        isPlaying = false
        videoList = []
        videoListIndex = 0

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
        
        
    }
    
    /// Pause current playback
    func pause() {
        singletonPlayer?.pause()
        isPlaying = false
    }
    
    /// Resume playback (checks position and rewinds if at end)
    func play() {
        guard singletonPlayer != nil else {
            return
        }
        
        // Check if video is at end and rewind if needed
        checkAndRewindIfAtEnd { [weak self] in
            guard let self = self, let player = self.singletonPlayer else { return }
            player.play()
            self.isPlaying = true
        }
    }
    
    // MARK: - App Lifecycle (via VideoPlayerLifecycleManager protocol)
    
    /// Two-layer recovery from background
    func recoverFromBackground() {
        guard let player = singletonPlayer else {
            hasRecoveredThisCycle = true
            return
        }
        
        // Mark that we've recovered in this cycle
        hasRecoveredThisCycle = true
        
        // Layer 2 (Security): Check if player is broken
        if isPlayerBroken() {
            
            // CRITICAL: Save state before clearing so recreation can restore it
            if let videoMid = currentVideoMid {
                let wasPlaying = player.rate > 0
                let currentTime = player.currentTime()
                let duration = player.currentItem?.duration ?? .invalid
                PersistentVideoStateManager.shared.saveState(
                    videoMid: videoMid,
                    currentTime: currentTime,
                    wasPlaying: wasPlaying,
                    context: .fullScreen,
                    duration: duration
                )
            }
            
            // Clear broken player
            clearBrokenPlayer()
            currentVideoMid = nil
            currentTweetId = nil
            currentCellTweetId = nil
            
            // For fullscreen, the view should recreate when it sees nil player
            // Unlike DetailView, fullscreen typically closes when backgrounded
            
            savedPlaybackState = nil
            return
        }
        
        // Layer 1 (Basic Restoration): Player is healthy, let buffering observer handle position restoration
        
        // CRITICAL FIX: Don't seek here to avoid race condition with buffering observer
        // The buffering observer (setupTimeControlStatusObserver) will handle position restoration
        // when the player has enough buffer. Seeking here causes duplicate seeks and stuck loading state.
        
        // Ensure mute state is correct
        player.isMuted = false
        
        // Check if we have saved state to restore
        let shouldRestore = currentVideoMid.map { videoMid in
            PersistentVideoStateManager.shared.shouldRestorePlayback(videoMid: videoMid, context: .fullScreen)
        } ?? false
        
        if shouldRestore {
            // Mark as not restored yet so buffering observer will restore when ready
            hasRestoredPosition = false
            isSeekingToRestoredPosition = false
        } else {
            // No saved state, mark as restored
            hasRestoredPosition = true
            isSeekingToRestoredPosition = false
        }
        
        // Get wasPlaying state to decide if we should auto-play
        let wasPlaying: Bool
        if let videoMid = currentVideoMid,
           let persistentState = PersistentVideoStateManager.shared.getState(videoMid: videoMid, context: .fullScreen) {
            wasPlaying = persistentState.wasPlaying
        } else if let savedState = savedPlaybackState {
            wasPlaying = savedState.wasPlaying
            savedPlaybackState = nil
        } else {
            wasPlaying = isPlaying
        }
        
        // Set playing state so buffering observer knows to auto-play
        isPlaying = wasPlaying
        wasPlayingBeforeWaiting = wasPlaying
        
        // CRITICAL: Manually trigger buffering state check after recovery
        // After lock screen, iOS player state can be inconsistent and KVO observers might not fire
        // We need to actively check and recover the playback state
        Task { @MainActor in
            // Small delay to let iOS settle the player state after unlock
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            guard let player = self.singletonPlayer, let playerItem = player.currentItem else {
                print("⚠️ [FullScreenVideoManager] Player or item nil after recovery")
                return
            }
            
            let loadedRanges = playerItem.loadedTimeRanges
            let hasBuffer = !loadedRanges.isEmpty
            var bufferedDuration: Double = 0
            if hasBuffer {
                bufferedDuration = loadedRanges.reduce(0.0) { max($0, CMTimeGetSeconds($1.timeRangeValue.duration)) }
            }
            let isReadyToPlay = playerItem.status == .readyToPlay
            let isNotPlaying = player.rate == 0
            
            
            // WORKAROUND: After lock screen, isPlaybackBufferEmpty can be stuck at true
            // even when we have buffered data. Trust loadedTimeRanges over isPlaybackBufferEmpty.
            let hasSignificantBuffer = hasBuffer && bufferedDuration >= 0.5
            
            if hasSignificantBuffer && self.isPlaying && isNotPlaying && isReadyToPlay {
                // Player has data and should be playing, but isn't
                // This handles the case where buffering observer didn't trigger
                
                // If position needs restoration, buffering observer will handle it
                // Otherwise just play
                if !self.hasRestoredPosition && shouldRestore {
                } else {
                    player.play()
                }
            } else if !hasSignificantBuffer {
                print("⏳ [FullScreenVideoManager] Post-recovery: Waiting for buffer (buffered: \(String(format: "%.1f", bufferedDuration))s)")
            } else if !self.isPlaying {
            }
        }

    }

    /// Handle reload notification from AppDelegate after long background / infrastructure restart
    /// CRITICAL: This is needed because recoverFromBackground() may have cleared the player
    /// or the player may have become broken during the background period.
    /// AppDelegate posts .reloadVisibleVideosOnly AFTER infrastructure is fully ready.
    private func handleReloadVisibleVideosOnly() {
        guard isActive else {
            // Not active, skip recovery
            return
        }

        // Check if player needs recreation
        let playerMissing = (singletonPlayer == nil)
        let itemMissing = (singletonPlayer?.currentItem == nil)
        let playerBroken = isPlayerBroken()

        guard playerMissing || itemMissing || playerBroken else {
            // Player is healthy, nothing to do
            print("✅ [FullScreenVideoManager] handleReloadVisibleVideosOnly - player healthy")
            return
        }

        print("🔄 [FullScreenVideoManager] handleReloadVisibleVideosOnly - player needs reload (playerMissing:\(playerMissing), itemMissing:\(itemMissing), playerBroken:\(playerBroken))")

        // Check if we have saved video info to reload
        guard let videoMid = currentVideoMid else {
            print("⚠️ [FullScreenVideoManager] handleReloadVisibleVideosOnly - no video info to reload")
            return
        }

        // Get the video URL from SharedAssetCache or reconstruct it
        // We need to reload the video - the view's onAppear should handle this
        // Clear state to trigger reload in SingletonVideoPlayerView
        clearBrokenPlayer()

        // Post notification so the fullscreen view knows to reload
        // SingletonVideoPlayerView checks player state in onAppear and will call loadVideo
        print("🔔 [FullScreenVideoManager] Cleared broken player - view should reload video \(videoMid)")
    }

    // No "search function" anymore; the coordinator is canonical.
}

/// Singleton video manager for detail view context
@MainActor
class DetailVideoManager: NSObject, ObservableObject, VideoPlayerLifecycleManager {
    static let shared = DetailVideoManager()
    private override init() {
        super.init()
        // DON'T setup lifecycle notifications in init
        // They're registered when detail view becomes active
        setupAudioInterruptionNotifications()
    }
    
    // MARK: - Lifecycle Management
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var isActive: Bool = false
    
    /// Activate manager when detail view appears
    func activateForDetail() {
        // Completely stop and clear any currently playing video when a new detail view becomes active
        // This ensures videos from previous detail views (like TweetDetailView) are completely stopped
        // when navigating to another detail view (like CommentDetailView)
        if getPlayer() != nil {
            print("📱 [DetailVideoManager] Completely stopping video from previous detail view")
            clearCurrentVideo()
        }

        // CRITICAL: Always call beginDetailViewSession() to increment count
        // even if manager is already active (multiple detail views can be active during transitions)
        beginDetailViewSession()

        // Only register lifecycle observers once
        guard !isActive else {
            print("📱 [DetailVideoManager] Already active - incremented session count to \(activeDetailViewCount)")
            return
        }
        isActive = true
        registerLifecycleObservers()
        print("📱 [DetailVideoManager] Activated - lifecycle observers registered")
    }
    
    /// Deactivate manager when all detail views disappear
    func deactivate() {
        // CRITICAL: Always call endDetailViewSession() to decrement count
        // Only teardown lifecycle observers when count reaches 0
        endDetailViewSession()

        guard isActive && activeDetailViewCount == 0 else {
            print("📱 [DetailVideoManager] Session ended - count now \(activeDetailViewCount)")
            return
        }
        isActive = false
        teardownAppLifecycleNotifications()

        // CRITICAL: Clear the current video player so isDetailViewActive() returns false
        // This allows feed videos to resume playback when returning from detail view
        clearCurrentVideo()

        print("📱 [DetailVideoManager] Deactivated - lifecycle observers removed, player cleared")
    }
    
    private func teardownAppLifecycleNotifications() {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
    }
    
    // Register lifecycle observers and store tokens for later removal
    private func registerLifecycleObservers() {
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleAppWillResignActive()
                }
            }
        )
        
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleAppDidEnterBackground()
                }
            }
        )
        
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleAppWillEnterForeground()
                }
            }
        )
        
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleAppDidBecomeActive()
                }
            }
        )
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
                }
            } catch {
                await MainActor.run {
                    print("⚠️ [DetailVideoManager] Failed to prewarm first item for \(mediaID): \(error)")
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

    /// When true, the current player was borrowed from the feed cell's SharedAssetCache.
    /// clearCurrentVideo() must NOT call replaceCurrentItem(with: nil) on a loaned player,
    /// otherwise the feed cell's AVPlayer would be destroyed and need full recreation.
    var isPlayerLoaned = false

    /// Called by the feed cell when it reclaims a loaned player.
    /// Nils references and cancels pending cleanup so deactivate() won't pause the reclaimed player.
    func disownLoanedPlayer() {
        scheduledClearTask?.cancel()
        scheduledClearTask = nil
        currentPlayer = nil
        currentVideoMid = nil
        isPlaying = false
        isPlayerLoaned = false
    }

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
            let duration = player.currentItem?.duration ?? .invalid
            
            PersistentVideoStateManager.shared.saveState(
                videoMid: videoMid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .detailView,
                duration: duration
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
        
        if isPlayerLoaned {
            // Loaned player: just pause and restore mute — do NOT destroy the playerItem.
            // The feed cell still references this AVPlayer and will resume on return.
            currentPlayer?.pause()
            currentPlayer?.isMuted = MuteState.shared.isMuted
            print("DEBUG: [DetailVideoManager] Returned loaned player (paused, mute restored)")
        } else {
            // Owned player: destroy completely so AVPlayerViewController cannot restart it.
            let rawMediaID = currentVideoMid
            let cacheKey = rawMediaID.map { "tweetDetail_\($0)" }

            currentPlayer?.pause()
            currentPlayer?.replaceCurrentItem(with: nil)
            print("DEBUG: [DetailVideoManager] Replaced player item with nil to stop playback")

            if let key = cacheKey {
                Task { @MainActor in
                    SharedAssetCache.shared.removeInvalidPlayer(for: key)
                }
            }
        }

        currentPlayer = nil
        currentVideoMid = nil
        isPlaying = false
        isPlayerLoaned = false
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
                
                // CRITICAL FIX: Validate that video actually finished
                // Check that current time is near the end of duration
                let currentTime = player.currentTime()
                guard let item = player.currentItem else {
                    print("⚠️ [DETAIL VIDEO MANAGER] No player item when video finished")
                    return
                }
                
                let duration = item.duration
                let currentMid = self.currentVideoMid
                
                // Validate duration is valid
                guard duration.isValid, duration.seconds > 0 else {
                    print("⚠️ [DETAIL VIDEO MANAGER] Video finished notification but duration is invalid (\(duration.seconds)s) for \(currentMid ?? "unknown")")
                    return
                }
                
                // Check if we're actually at the end (within 0.5 seconds of duration)
                let timeUntilEnd = duration.seconds - currentTime.seconds
                guard timeUntilEnd < 0.5 else {
                    print("⚠️ [DETAIL VIDEO MANAGER] Ignoring premature finish notification for \(currentMid ?? "unknown") - current: \(currentTime.seconds)s, duration: \(duration.seconds)s, remaining: \(timeUntilEnd)s")
                    return
                }
                
                print("✅ [DETAIL VIDEO MANAGER] Video legitimately finished for \(currentMid ?? "unknown") - current: \(currentTime.seconds)s, duration: \(duration.seconds)s")
                print("DEBUG: [DETAIL VIDEO MANAGER] Notification object: \(notification.object ?? "nil")")
                print("DEBUG: [DETAIL VIDEO MANAGER] Player current item: \(player.currentItem?.description ?? "nil")")
                
                // Just pause - no automatic rewind
                // Will rewind when user tries to play
                print("DEBUG: [DETAIL VIDEO MANAGER] Video finished for \(currentMid ?? "unknown") - paused, ready to replay")
                self.isPlaying = false
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
            hasRecoveredThisCycle = true
            return
        }
        
        // Mark that we've recovered in this cycle
        hasRecoveredThisCycle = true
        
        // Layer 2 (Security): Check if player is broken
        if isPlayerBroken() {
            
            // CRITICAL: Save state before clearing so recreation can restore it
            if let videoMid = currentVideoMid {
                let wasPlaying = player.rate > 0
                let currentTime = player.currentTime()
                let duration = player.currentItem?.duration ?? .invalid
                PersistentVideoStateManager.shared.saveState(
                    videoMid: videoMid,
                    currentTime: currentTime,
                    wasPlaying: wasPlaying,
                    context: .detailView,
                    duration: duration
                )
            }
            
            // Clear broken player completely
            clearBrokenPlayer()
            
            // Post notification to tell SimpleVideoPlayer to reload
            // This will trigger SimpleVideoPlayer's handleVideoInfrastructureRestarted
            NotificationCenter.default.post(name: .videoInfrastructureRestarted, object: nil)
            
            savedPlaybackState = nil
            return
        }
        
        // Layer 1 (Basic Restoration): Player is healthy, restore state
        
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

/// Chat Video Manager for managing video playback within chat sessions
/// Handles visibility-based autoplay and pause for chat videos
@MainActor
class ChatVideoManager: ObservableObject {
    static let shared = ChatVideoManager()

    private init() {}

    // Track active chat sessions and their video states
    @Published var activeChatSessions: [String: ChatSessionVideoState] = [:] // Key: receiptId

    // Current visible videos per chat session
    private var visibleVideos: [String: Set<String>] = [:] // Key: receiptId, Value: Set of video mids

    // Global video player storage for chat videos - store AVPlayer directly
    private var chatVideoPlayers: [String: AVPlayer] = [:] // Key: messageId, Value: AVPlayer instance

    // Track which messageIds belong to which chat session (receiptId)
    private var chatSessionMessages: [String: Set<String>] = [:] // Key: receiptId, Value: Set of messageIds

    /// State for a specific chat session's videos
    struct ChatSessionVideoState {
        var playingVideos: Set<String> = [] // mids of videos currently playing
        var pausedVideos: Set<String> = [] // mids of videos paused due to visibility
        var isChatVisible: Bool = true // whether the chat screen is currently visible
    }

    /// Register a chat session for video management
    func registerChatSession(receiptId: String) {
        if activeChatSessions[receiptId] == nil {
            activeChatSessions[receiptId] = ChatSessionVideoState()
            visibleVideos[receiptId] = Set<String>()
            chatSessionMessages[receiptId] = Set<String>()
            // Release ALL feed players to free decode sessions for chat videos
            SharedAssetCache.shared.releaseAllFeedPlayers()
            print("DEBUG: [ChatVideoManager] Registered chat session: \(receiptId)")
        }
    }

    /// Unregister a chat session (cleanup when leaving chat)
    func unregisterChatSession(receiptId: String) {
        // Pause and remove all AVPlayers for this session
        if let messageIds = chatSessionMessages[receiptId] {
            for messageId in messageIds {
                if let player = chatVideoPlayers.removeValue(forKey: messageId) {
                    player.pause()
                }
            }
            print("DEBUG: [ChatVideoManager] Removed \(messageIds.count) players for session: \(receiptId)")
        }

        activeChatSessions.removeValue(forKey: receiptId)
        visibleVideos.removeValue(forKey: receiptId)
        chatSessionMessages.removeValue(forKey: receiptId)
        print("DEBUG: [ChatVideoManager] Unregistered chat session: \(receiptId)")
    }

    /// Update chat screen visibility (called when ChatScreen appears/disappears)
    func setChatVisibility(receiptId: String, isVisible: Bool) {
        guard var sessionState = activeChatSessions[receiptId] else {
            print("WARNING: [ChatVideoManager] Trying to set visibility for unregistered session: \(receiptId)")
            return
        }

        sessionState.isChatVisible = isVisible
        activeChatSessions[receiptId] = sessionState

        if !isVisible {
            // Chat screen is not visible - pause all playing videos
            pauseAllVideosInSession(receiptId: receiptId)
            print("DEBUG: [ChatVideoManager] Chat screen hidden for \(receiptId) - paused all videos")
        } else {
            // Chat screen became visible - resume visible videos
            resumeVisibleVideosInSession(receiptId: receiptId)
            print("DEBUG: [ChatVideoManager] Chat screen visible for \(receiptId) - resumed visible videos")
        }
    }

    /// Update which videos are currently visible in the scroll view
    func updateVisibleVideos(receiptId: String, visibleMids: Set<String>) {
        guard let sessionState = activeChatSessions[receiptId] else {
            print("WARNING: [ChatVideoManager] Trying to update visibility for unregistered session: \(receiptId)")
            return
        }

        let previousVisible = visibleVideos[receiptId] ?? Set<String>()
        visibleVideos[receiptId] = visibleMids

        // Early return if no changes
        guard previousVisible != visibleMids else {
            return
        }

        // Find videos that became visible
        let newlyVisible = visibleMids.subtracting(previousVisible)

        // Find videos that became invisible
        let newlyInvisible = previousVisible.subtracting(visibleMids)

        // Handle newly visible videos
        if sessionState.isChatVisible && !newlyVisible.isEmpty {
            for videoMid in newlyVisible {
                startVideo(mid: videoMid, receiptId: receiptId)
            }
        }

        // Handle newly invisible videos
        if !newlyInvisible.isEmpty {
            for videoMid in newlyInvisible {
                pauseVideo(mid: videoMid, receiptId: receiptId)
            }
        }

        print("DEBUG: [ChatVideoManager] Updated visibility for \(receiptId): +\(newlyVisible.count) visible, -\(newlyInvisible.count) invisible")
    }

    /// Check if a video should be playing (visible and chat screen active)
    func shouldPlayVideo(mid: String, receiptId: String) -> Bool {
        guard let sessionState = activeChatSessions[receiptId],
              sessionState.isChatVisible else {
            return false
        }

        let visibleMids = visibleVideos[receiptId] ?? Set<String>()
        return visibleMids.contains(mid)
    }

    /// Get current playing state for a video
    func isVideoPlaying(mid: String, receiptId: String) -> Bool {
        guard let sessionState = activeChatSessions[receiptId] else {
            return false
        }
        return sessionState.playingVideos.contains(mid)
    }

    /// Get or create a video player for a chat message
    func getOrCreateVideoPlayer(
        messageId: String,
        attachment: MimeiFileType,
        isFromCurrentUser: Bool,
        senderUser: User?,
        isChatScreenVisible: Bool,
        receiptId: String
    ) async -> AVPlayer? {
        if let existingPlayer = chatVideoPlayers[messageId] {
            return existingPlayer
        }

        // Get the base URL for the video
        let baseUrl: URL = {
            if isFromCurrentUser {
                return HproseInstance.shared.appUser.baseUrl ?? HproseInstance.baseUrl
            } else {
                return senderUser?.baseUrl ?? HproseInstance.baseUrl
            }
        }()

        // Get the video URL
        guard let url = attachment.getUrl(baseUrl) else {
            return nil
        }

        do {
            let player = try await SharedAssetCache.shared.getOrCreatePlayer(for: url, mediaType: attachment.type)
            chatVideoPlayers[messageId] = player
            chatSessionMessages[receiptId, default: Set<String>()].insert(messageId)
            return player
        } catch {
            print("DEBUG: [ChatVideoManager] Failed to create player for \(messageId): \(error)")
            return nil
        }
    }

    /// Remove a video player for a message
    func removeVideoPlayer(messageId: String) {
        chatVideoPlayers.removeValue(forKey: messageId)
    }

    /// Clean up all video players for a chat session
    func cleanupChatSession(receiptId: String) {
        guard let messageIds = chatSessionMessages[receiptId] else { return }
        for messageId in messageIds {
            if let player = chatVideoPlayers.removeValue(forKey: messageId) {
                player.pause()
            }
        }
        chatSessionMessages.removeValue(forKey: receiptId)
        print("DEBUG: [ChatVideoManager] Cleaned up \(messageIds.count) players for session: \(receiptId)")
    }

    // MARK: - Private Methods

    private func startVideo(mid: String, receiptId: String) {
        guard var sessionState = activeChatSessions[receiptId] else { return }

        // Check if already playing
        guard !sessionState.playingVideos.contains(mid) else { return }

        // Add to playing videos
        sessionState.playingVideos.insert(mid)
        sessionState.pausedVideos.remove(mid)
        activeChatSessions[receiptId] = sessionState

        // Notify CachingVideoPlayer to start playing
        NotificationCenter.default.post(
            name: NSNotification.Name("ChatVideoShouldPlay"),
            object: nil,
            userInfo: [
                "videoMid": mid,
                "receiptId": receiptId,
                "shouldPlay": true
            ]
        )

        print("DEBUG: [ChatVideoManager] Started video: \(mid) in session: \(receiptId)")
    }

    private func pauseVideo(mid: String, receiptId: String) {
        guard var sessionState = activeChatSessions[receiptId] else { return }

        // Check if already paused
        guard !sessionState.pausedVideos.contains(mid) else { return }

        // Remove from playing videos, add to paused
        sessionState.playingVideos.remove(mid)
        sessionState.pausedVideos.insert(mid)
        activeChatSessions[receiptId] = sessionState

        // Notify CachingVideoPlayer to pause
        NotificationCenter.default.post(
            name: NSNotification.Name("ChatVideoShouldPlay"),
            object: nil,
            userInfo: [
                "videoMid": mid,
                "receiptId": receiptId,
                "shouldPlay": false
            ]
        )

        print("DEBUG: [ChatVideoManager] Paused video: \(mid) in session: \(receiptId)")
    }

    private func stopVideo(mid: String, receiptId: String) {
        guard var sessionState = activeChatSessions[receiptId] else { return }

        // Remove from both playing and paused
        sessionState.playingVideos.remove(mid)
        sessionState.pausedVideos.remove(mid)
        activeChatSessions[receiptId] = sessionState

        // Notify CachingVideoPlayer to stop
        NotificationCenter.default.post(
            name: NSNotification.Name("ChatVideoShouldStop"),
            object: nil,
            userInfo: [
                "videoMid": mid,
                "receiptId": receiptId
            ]
        )

        print("DEBUG: [ChatVideoManager] Stopped video: \(mid) in session: \(receiptId)")
    }

    private func pauseAllVideosInSession(receiptId: String) {
        guard var sessionState = activeChatSessions[receiptId] else { return }

        let videosToPause = sessionState.playingVideos
        sessionState.playingVideos.removeAll()
        sessionState.pausedVideos.formUnion(videosToPause)
        activeChatSessions[receiptId] = sessionState

        // Directly pause all AVPlayers for this session
        if let messageIds = chatSessionMessages[receiptId] {
            for messageId in messageIds {
                chatVideoPlayers[messageId]?.pause()
            }
        }

        print("DEBUG: [ChatVideoManager] Paused all \(videosToPause.count) videos in session: \(receiptId)")
    }

    private func resumeVisibleVideosInSession(receiptId: String) {
        guard let sessionState = activeChatSessions[receiptId] else { return }

        let visibleMids = visibleVideos[receiptId] ?? Set<String>()

        // Resume videos that are visible and were previously playing
        for videoMid in visibleMids {
            if sessionState.pausedVideos.contains(videoMid) {
                startVideo(mid: videoMid, receiptId: receiptId)
            }
        }

        print("DEBUG: [ChatVideoManager] Resumed visible videos in session: \(receiptId)")
    }
}
