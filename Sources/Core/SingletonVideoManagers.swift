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
    @Published private(set) var isDetailNavigationPending = false
    private var shouldPreserveFeedPlaybackForPendingDetail = false

    var shouldPreserveFeedForDetailTransition: Bool {
        isDetailNavigationPending && shouldPreserveFeedPlaybackForPendingDetail
    }

    func markDetailNavigationPending(source: String, preserveFeedPlayback: Bool) {
        isDetailNavigationPending = true
        shouldPreserveFeedPlaybackForPendingDetail = preserveFeedPlayback
        print("DEBUG: [NAVIGATION STATE] Detail navigation pending from \(source)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !self.isDetailViewActive else { return }
            self.isDetailNavigationPending = false
            self.shouldPreserveFeedPlaybackForPendingDetail = false
        }
    }

    func setDetailViewActive(_ active: Bool) {
        isDetailViewActive = active
        if !active {
            isDetailNavigationPending = false
            shouldPreserveFeedPlaybackForPendingDetail = false
        }
        print("DEBUG: [NAVIGATION STATE] Detail view active: \(active)")
    }
}

// MARK: - Shared App Lifecycle Protocol
@MainActor
protocol VideoPlayerLifecycleManager: AnyObject, Sendable {
    var savedPlaybackState: (wasPlaying: Bool, time: CMTime)? { get set }
    var hasRecoveredThisCycle: Bool { get set }
    
    func getPlayer() -> AVPlayer?
    func pausePlayer()
    func setPlaying(_ playing: Bool)
    func isPlayerBroken() -> Bool
    func clearBrokenPlayer()
    func recoverFromBackground()
}

private func feedStyleBufferedTimeAhead(for item: AVPlayerItem, player: AVPlayer) -> Double {
    let currentSeconds = CMTimeGetSeconds(player.currentTime())
    guard currentSeconds.isFinite else { return 0 }

    var bestBufferAhead: Double = 0
    for value in item.loadedTimeRanges {
        let range = value.timeRangeValue
        let start = CMTimeGetSeconds(range.start)
        let duration = CMTimeGetSeconds(range.duration)
        guard start.isFinite, duration.isFinite else { continue }

        let end = start + duration
        if currentSeconds >= start && currentSeconds <= end {
            return max(0, end - currentSeconds)
        } else if end > currentSeconds {
            bestBufferAhead = max(bestBufferAhead, end - currentSeconds)
        }
    }
    return max(0, bestBufferAhead)
}

private func feedStyleRequiredBufferAhead(for item: AVPlayerItem, player: AVPlayer) -> Double {
    if item.isPlaybackLikelyToKeepUp {
        return 0.75
    }

    let currentSeconds = CMTimeGetSeconds(player.currentTime())
    let isStartup = currentSeconds.isFinite && currentSeconds < 1.0
    return isStartup ? 2.0 : 2.5
}

private func fullscreenRequiredBufferAhead(for item: AVPlayerItem, player: AVPlayer) -> Double {
    let currentSeconds = CMTimeGetSeconds(player.currentTime())
    let isStartup = currentSeconds.isFinite && currentSeconds < 1.0
    if isStartup {
        return 2.0
    }

    return item.isPlaybackLikelyToKeepUp ? 2.0 : 8.0
}

@discardableResult
private func applyPrePlayBuffering(
    to player: AVPlayer,
    item: AVPlayerItem,
    requiredBuffer: (AVPlayerItem, AVPlayer) -> Double
) -> (bufferedAhead: Double, requiredBuffer: Double, keepUp: Bool) {
    item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
    item.preferredForwardBufferDuration = 0

    let bufferedAhead = feedStyleBufferedTimeAhead(for: item, player: player)
    let required = requiredBuffer(item, player)
    if bufferedAhead >= required {
        player.automaticallyWaitsToMinimizeStalling = false
    } else {
        player.automaticallyWaitsToMinimizeStalling = true
    }
    return (bufferedAhead, required, item.isPlaybackLikelyToKeepUp)
}

@discardableResult
private func applyFeedStylePrePlayBuffering(to player: AVPlayer, item: AVPlayerItem) -> (bufferedAhead: Double, requiredBuffer: Double, keepUp: Bool) {
    applyPrePlayBuffering(to: player, item: item, requiredBuffer: feedStyleRequiredBufferAhead)
}

@discardableResult
private func applyFullscreenPrePlayBuffering(to player: AVPlayer, item: AVPlayerItem) -> (bufferedAhead: Double, requiredBuffer: Double, keepUp: Bool) {
    applyPrePlayBuffering(to: player, item: item, requiredBuffer: fullscreenRequiredBufferAhead)
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
            MainActor.assumeIsolated {
                self?.handleAppWillResignActive()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleAppDidEnterBackground()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleAppWillEnterForeground()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
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
            SharedAssetCache.shared.protectBackgroundPoster(for: videoMid)
            PersistentVideoStateManager.shared.saveState(
                videoMid: videoMid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .detailView,
                duration: duration
            )
        } else if let fullscreenManager = self as? FullScreenVideoManager,
                  let videoMid = fullscreenManager.currentVideoMid {
            SharedAssetCache.shared.protectBackgroundPoster(for: videoMid)
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

        // Background policy: keep resume metadata/posters, but drop the actual
        // AVPlayer/AVPlayerItem memory. Foreground recovery recreates on demand.
        clearBrokenPlayer()
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

enum FullscreenVideoVisualState {
    case idle(showPoster: Bool)
    case loading(showPoster: Bool, showSpinner: Bool)
    case playing(showPoster: Bool)
    case failed

    var showsPoster: Bool {
        switch self {
        case .idle(let showPoster), .loading(let showPoster, _), .playing(let showPoster):
            return showPoster
        case .failed:
            return false
        }
    }

    var showsSpinner: Bool {
        switch self {
        case .loading(_, let showSpinner):
            return showSpinner
        case .idle, .playing, .failed:
            return false
        }
    }
}

/// Singleton video manager for fullscreen video playback with auto-advance
/// Uses a dedicated singleton player instance independent from MediaCell players
@MainActor
final class FullScreenVideoManager: ObservableObject, VideoPlayerLifecycleManager {
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
    var isFullscreenActive: Bool { isActive }
    private var feedHandoffMid: String?
    private var feedHandoffExpiresAt: Date = .distantPast
    
    /// Activate manager when fullscreen view appears
    func activateForFullscreen() {
        // Pause any detail view videos when entering fullscreen mode
        // This ensures videos playing in TweetDetailView or CommentDetailView are paused
        // when opening attachments in fullscreen, but can resume when fullscreen closes
        if let detailPlayer = DetailVideoManager.shared.getPlayer() {
            let currentTime = detailPlayer.currentTime()
            if let videoMid = DetailVideoManager.shared.currentVideoMid,
               detailPlayer.currentItem != nil,
               currentTime.isValid,
               currentTime.seconds.isFinite,
               currentTime.seconds > 0.25 {
                PersistentVideoStateManager.shared.saveState(
                    videoMid: videoMid,
                    currentTime: currentTime,
                    wasPlaying: detailPlayer.rate > 0,
                    context: .detailView,
                    duration: detailPlayer.currentItem?.duration ?? .invalid
                )
            }
            if detailPlayer.rate > 0 {
                DetailVideoManager.shared.pausePlayer()
                print("🎬 [FullScreenVideoManager] Paused detail view videos before activating fullscreen")
            }
        }

        guard !isActive else { return }
        isActive = true
        registerLifecycleObservers()
        print("🎬 [FullScreenVideoManager] Activated - lifecycle observers registered")
    }
    
    /// Deactivate manager when fullscreen view disappears
    func deactivate(transferPlaybackToUnderlyingSurface: Bool = false) {
        guard isActive else { return }
        isActive = false
        teardownAppLifecycleNotifications()
        startupAudioUnmuteTask?.cancel()
        startupAudioUnmuteTask = nil
        startupAudioMuteUntil = .distantPast

        // Save playback position so the feed cell and the next fullscreen open can restore it.
        if let player = singletonPlayer,
           let videoMid = currentVideoMid,
           player.currentItem != nil {
            let wasPlaying = player.rate > 0
            let currentTime = player.currentTime()
            let duration = player.currentItem?.duration ?? .invalid
            saveFullscreenPlaybackState(
                videoMid: videoMid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                duration: duration
            )
        }

        // CRITICAL: Set intent flags to false BEFORE optional pause().
        // AVFoundation fires KVO callbacks (timeControlStatus, loadedTimeRanges, etc.)
        // on background threads when the player pauses. Those callbacks run
        // updateBufferingState which checks isPlaying/wasPlayingBeforeWaiting to decide
        // whether to call player.play(). If we set these flags AFTER pause(), a background
        // callback can race and see isPlaying=true, then call player.play() — restarting
        // audio right after we intentionally stopped it. Setting them first prevents this.
        isPlaying = false
        wasPlayingBeforeWaiting = false
        if !transferPlaybackToUnderlyingSurface {
            singletonPlayer?.pause()
        }
        resetPlaybackSurfaceState()

        // Cancel all timers and observers that could wake the player back up.
        // Without this, retryWorkItem can fire after dismissal and mutate a
        // player now owned by feed/detail.
        retryWorkItem?.cancel()
        retryWorkItem = nil
        fullscreenLoadTask?.cancel()
        fullscreenLoadTask = nil
        loadingMid = nil
        loadingStartedAt = nil
        fullscreenStallItemRebuildCount = 0
        bufferObserver?.invalidate()
        bufferObserver = nil
        cleanupObservers()         // removes timeControlStatus, buffer, loaded-ranges KVO
        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
        hasBufferedData = false
        hasCachedMediaContent = false
        hasPlayableMediaContent = false

        let releasedBrokenBorrowedPlayer: Bool
        if isUsingBorrowedFeedPlayer,
           let player = singletonPlayer,
           let item = player.currentItem,
           let videoMid = currentVideoMid {
            releasedBrokenBorrowedPlayer = releaseCachedFeedPlayerForFocusedPlaybackIfNeeded(player, item: item, mid: videoMid, owner: "fullscreen dismiss")
        } else {
            releasedBrokenBorrowedPlayer = false
        }

        // Capture a still frame from the singleton player so the feed cell has a
        // poster while its separate AVPlayerLayer re-initialises on return.
        if !releasedBrokenBorrowedPlayer {
            captureTransitionPoster(from: singletonPlayer, mediaID: currentVideoMid)
        }

        if transferPlaybackToUnderlyingSurface && !releasedBrokenBorrowedPlayer {
            feedHandoffMid = currentVideoMid
            feedHandoffExpiresAt = Date().addingTimeInterval(2.0)
            if let player = singletonPlayer,
               let mid = currentVideoMid {
                VideoSurfaceHandoffRegistry.shared.beginTransfer(
                    mediaID: mid,
                    player: player,
                    source: "fullscreen"
                )
            }
        } else {
            feedHandoffMid = nil
            feedHandoffExpiresAt = .distantPast
        }

        currentVideoMid = nil
        currentTweetId = nil
        currentCellTweetId = nil
        currentVideoIndex = 0
        isUsingBorrowedFeedPlayer = false
        if releasedBrokenBorrowedPlayer {
            singletonPlayer = nil
        }
        LocalHTTPServer.shared.clearPrimaryRestriction()

        let cleanupResult = releasedBrokenBorrowedPlayer ? "broken borrowed player released" : "fullscreen player preserved"
        print("🎬 [FullScreenVideoManager] Deactivated - observers cancelled, \(cleanupResult)")
    }

    func isTransferringPlayerToFeed(_ player: AVPlayer, mid: String) -> Bool {
        if VideoSurfaceHandoffRegistry.shared.isActiveTransfer(mediaID: mid, player: player) {
            return true
        }
        guard singletonPlayer === player,
              feedHandoffMid == mid,
              Date() <= feedHandoffExpiresAt else {
            return false
        }
        return true
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
        if let videoMid = currentVideoMid {
            // Long-background recovery can dismiss fullscreen before the feed has a
            // chance to capture its own frame. Preserve the fullscreen frame first.
            captureTransitionPoster(from: singletonPlayer, mediaID: videoMid)
            SharedAssetCache.shared.protectBackgroundPoster(for: videoMid)
        }

        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
        loadGeneration += 1
        fullscreenLoadTask?.cancel()
        fullscreenLoadTask = nil
        loadingMid = nil
        loadingStartedAt = nil
        fullscreenStallItemRebuildCount = 0
        loadFailedVideoMid = nil
        retryWorkItem?.cancel()
        retryWorkItem = nil
        bufferObserver?.invalidate()
        bufferObserver = nil
        cleanupObservers()
        singletonPlayer?.pause()
        singletonPlayer?.replaceCurrentItem(with: nil)
        singletonPlayer = nil
        isItemReady = false
        hasBufferedData = false
        hasCachedMediaContent = false
        hasPlayableMediaContent = false
        isPlaying = false
        resetPlaybackSurfaceState()
        loadFailedVideoMid = nil
    }

    private func saveFullscreenPlaybackState(
        videoMid: String,
        currentTime: CMTime,
        wasPlaying: Bool,
        duration: CMTime
    ) {
        PersistentVideoStateManager.shared.saveState(
            videoMid: videoMid,
            currentTime: currentTime,
            wasPlaying: wasPlaying,
            context: .fullScreen,
            duration: duration
        )

        guard currentTime.isValid,
              currentTime.seconds.isFinite,
              currentTime.seconds > 0.25 else {
            return
        }

        PersistentVideoStateManager.shared.saveState(
            videoMid: videoMid,
            currentTime: currentTime,
            wasPlaying: wasPlaying,
            context: .mediaCell,
            duration: duration
        )
    }

    private func validResumeTime(_ time: CMTime?, duration: CMTime? = nil) -> CMTime? {
        guard let time,
              time.isValid,
              time.seconds.isFinite,
              time.seconds > 0.25 else { return nil }

        if let duration,
           duration.isValid,
           duration.seconds.isFinite,
           duration.seconds > 0,
           duration.seconds - time.seconds <= 0.5 {
            return .zero
        }

        return time
    }

    private func crossSurfaceResumeTime(for mid: String, duration: CMTime? = nil) -> CMTime? {
        if DetailVideoManager.shared.currentVideoMid == mid,
           let currentTime = validResumeTime(DetailVideoManager.shared.currentPlayer?.currentTime(), duration: duration) {
            return currentTime
        }

        if let feedPlayer = SharedAssetCache.shared.getCachedPlayer(for: mid),
           let currentTime = validResumeTime(feedPlayer.currentTime(), duration: duration) {
            return currentTime
        }

        if let cachedPlayback = VideoStateCache.shared.getCachedPlaybackInfo(for: mid),
           let currentTime = validResumeTime(cachedPlayback.time, duration: duration) {
            return currentTime
        }

        if let latest = PersistentVideoStateManager.shared.latestState(
            videoMid: mid,
            excluding: .fullScreen,
            duration: duration
        ) {
            return latest.currentTime
        }

        return nil
    }

    private func shouldResetCachedFeedPlayerForFocusedPlayback(_ player: AVPlayer, item: AVPlayerItem) -> Bool {
        let hasPlayerFailure = item.status == .failed || player.error != nil || item.error != nil
        if hasPlayerFailure { return true }

        let isNearEnd = timeRemaining(for: item, player: player).map { $0 <= 0.5 } ?? false
        if isNearEnd { return false }

        let hasLoadedData = item.loadedTimeRanges.contains { value in
            let duration = CMTimeGetSeconds(value.timeRangeValue.duration)
            return duration.isFinite && duration > 0
        }
        if item is CachingPlayerItem,
           item.status == .unknown,
           hasLoadedData {
            return true
        }
        return false
    }

    @discardableResult
    private func releaseCachedFeedPlayerForFocusedPlaybackIfNeeded(_ player: AVPlayer, item: AVPlayerItem, mid: String, owner: String) -> Bool {
        guard shouldResetCachedFeedPlayerForFocusedPlayback(player, item: item) else { return false }

        let deleteDiskCache = item.status == .failed || player.error != nil || item.error != nil
        print("🎬 [FullScreenVideoManager] Releasing broken shared feed player before \(owner) \(shortMID(mid)): deleteDiskCache=\(deleteDiskCache), \(playerDiagnostic(player, item: item))")
        item.cancelPendingSeeks()
        player.pause()
        SharedAssetCache.shared.clearPlayerForMediaID(mid, deleteDiskCache: deleteDiskCache)
        VideoStateCache.shared.clearCachedState(for: mid)
        LocalHTTPServer.shared.clearCancelledState(for: mid)
        return true
    }

    // Independent singleton player for fullscreen mode
    @Published var singletonPlayer: AVPlayer?
    @Published var currentVideoMid: String?
    @Published var currentTweetId: String?
    @Published var currentCellTweetId: String? // The visible cell's tweet ID in feed (retweet ID for retweets, quoting tweet ID for quotes)
    @Published var currentVideoIndex: Int = 0 // Track current video index within tweet
    @Published var isPlaying = false
    @Published private(set) var hasPlayableMediaContent = false
    /// True once the current item has status .readyToPlay (i.e. first frame decoded).
    /// Used by SingletonVideoPlayerView to show a thumbnail cover while the item loads.
    @Published var isItemReady = false
    @Published private(set) var loadFailedVideoMid: String?
    @Published private var transitionPoster: UIImage?
    private var transitionPosterMediaID: String?
    private var hasBufferedData = false
    private var hasCachedMediaContent = false

    private struct FullscreenRecoveryRequest {
        let url: URL
        let mid: String
        let tweetId: String
        let cellTweetId: String
        let videoIndex: Int
        let mediaType: MediaType
    }

    private var lastRequestedFullscreenVideo: FullscreenRecoveryRequest?
    
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
    private var fullscreenStallItemRebuildCount = 0
    private let fullscreenRetryBufferTimeout: TimeInterval = 12.0
    
    // Waiting for data observer
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var playbackBufferEmptyObserver: NSKeyValueObservation?
    private var playbackLikelyToKeepUpObserver: NSKeyValueObservation?
    private var loadedTimeRangesObserver: NSKeyValueObservation?
    private var itemStatusObserver: NSKeyValueObservation?
    private var fullscreenProgressObserver: Any?
    private var fullscreenProgressObserverPlayer: AVPlayer?
    private var wasPlayingBeforeWaiting = false
    private var hasRestoredPosition = false // Track if we've restored position from saved state
    private var isSeekingToRestoredPosition = false // Track if we're currently seeking to restored position
    private var isUsingBorrowedFeedPlayer = false
    private var prewarmedNextVideoMid: String?
    private var playbackSurfaceReadyMid: String?
    private var pendingSurfacePlayback: (player: AVPlayer, item: AVPlayerItem, log: String)?
    private var playbackSurfaceFallbackTask: Task<Void, Never>?
    
    private var nearEndAdvanceTask: DispatchWorkItem?
    private var startupAudioMuteUntil: Date = .distantPast
    private var startupAudioUnmuteTask: Task<Void, Never>?

    // Prevent stale async loads from clobbering current state (fixes stuck spinner after repeated opens)
    private var fullscreenLoadTask: Task<Void, Never>?
    private var loadGeneration: Int = 0
    private var loadingMid: String?
    private var loadingStartedAt: Date?

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

    private func resetPlaybackSurfaceState() {
        playbackSurfaceFallbackTask?.cancel()
        playbackSurfaceFallbackTask = nil
        playbackSurfaceReadyMid = nil
        pendingSurfacePlayback = nil
    }

    private func shortMID(_ mid: String?) -> String {
        guard let mid else { return "nil" }
        return mid.count > 8 ? String(mid.prefix(8)) : mid
    }

    @MainActor
    private func refreshCachedMediaContent(for mid: String?) {
        guard let mid else {
            hasCachedMediaContent = false
            hasPlayableMediaContent = hasBufferedData
            return
        }

        hasCachedMediaContent = SharedAssetCache.shared.hasCachedContent(for: mid)
        hasPlayableMediaContent = hasBufferedData
    }

    func visualState(
        for mid: String,
        hasPoster: Bool,
        layerReadyForDisplay: Bool,
        player candidatePlayer: AVPlayer?
    ) -> FullscreenVideoVisualState {
        if loadFailedVideoMid == mid {
            return .failed
        }

        guard currentVideoMid == mid else {
            if loadingMid == mid {
                return .loading(
                    showPoster: hasPoster,
                    showSpinner: shouldShowPreItemLoadingSpinner()
                )
            }
            return .idle(showPoster: hasPoster)
        }

        guard let player = candidatePlayer,
              singletonPlayer === player,
              let item = player.currentItem else {
            return .loading(
                showPoster: hasPoster,
                showSpinner: shouldShowPreItemLoadingSpinner()
            )
        }

        let hasPlayableData = hasPlayableData(player: player, item: item)
        let showPoster = shouldShowFullscreenPoster(
            hasPoster: hasPoster,
            layerReadyForDisplay: layerReadyForDisplay,
            player: player
        )

        let itemReady = isItemReady || item.status == .readyToPlay
        let isPlaybackRendering = player.timeControlStatus == .playing || player.rate > 0

        if isPlaybackRendering, itemReady {
            return .playing(showPoster: showPoster)
        }

        let shouldShowSpinner = !isFullscreenVideoAtEnd(player)
            && !isPlaybackRendering
            && !(hasCachedMediaContent && hasPlayableData)
            && !(layerReadyForDisplay && itemReady)

        return .loading(
            showPoster: showPoster,
            showSpinner: shouldShowSpinner
        )
    }

    private func shouldShowPreItemLoadingSpinner() -> Bool {
        return !hasCachedMediaContent && !hasPlayableMediaContent
    }

    private func markPlayableMediaContentIfBuffered(
        player: AVPlayer,
        item: AVPlayerItem,
        bufferedAhead: Double? = nil,
        keepUp: Bool? = nil
    ) {
        let hasBuffered = hasPlayableData(
            player: player,
            item: item,
            bufferedAhead: bufferedAhead,
            keepUp: keepUp
        )
        guard hasBuffered else { return }

        hasBufferedData = true
        hasPlayableMediaContent = true
    }

    private func hasPlayableData(
        player: AVPlayer,
        item: AVPlayerItem,
        bufferedAhead: Double? = nil,
        keepUp: Bool? = nil
    ) -> Bool {
        if player.timeControlStatus == .playing || player.rate > 0 {
            return true
        }
        if keepUp == true || item.isPlaybackLikelyToKeepUp {
            return true
        }
        if let bufferedAhead, bufferedAhead > 0.05 {
            return true
        }
        if bufferedTimeAhead(for: item, player: player) > 0.05 {
            return true
        }
        return item.loadedTimeRanges.contains { value in
            let duration = CMTimeGetSeconds(value.timeRangeValue.duration)
            return duration.isFinite && duration > 0
        }
    }

    private func shouldShowFullscreenPoster(
        hasPoster: Bool,
        layerReadyForDisplay: Bool,
        player: AVPlayer
    ) -> Bool {
        guard hasPoster, !isFullscreenVideoAtEnd(player) else { return false }

        return !layerReadyForDisplay
            || player.timeControlStatus != .playing
            || !isItemReady
            || isBeforeFirstVisibleFrame(player)
    }

    private func isBeforeFirstVisibleFrame(_ player: AVPlayer) -> Bool {
        guard player.timeControlStatus == .playing else { return false }
        let current = CMTimeGetSeconds(player.currentTime())
        guard current.isFinite else { return true }
        return current < 0.18
    }

    private func isFullscreenVideoAtEnd(_ player: AVPlayer) -> Bool {
        guard let item = player.currentItem else { return false }
        let duration = CMTimeGetSeconds(item.duration)
        let current = CMTimeGetSeconds(player.currentTime())
        guard duration.isFinite, current.isFinite, duration > 0 else { return false }
        return duration - current < 0.5
    }

    private func playerDiagnostic(_ player: AVPlayer?, item: AVPlayerItem?) -> String {
        let player = player ?? singletonPlayer
        let item = item ?? player?.currentItem
        let pos = player.map { CMTimeGetSeconds($0.currentTime()) } ?? 0
        let dur = item.map { CMTimeGetSeconds($0.duration) } ?? 0
        let buffered = {
            guard let player, let item else { return 0.0 }
            return bufferedTimeAhead(for: item, player: player)
        }()
        let ranges = item?.loadedTimeRanges.map { value in
            let range = value.timeRangeValue
            return "\(String(format: "%.1f", CMTimeGetSeconds(range.start)))-\(String(format: "%.1f", CMTimeGetSeconds(range.end)))"
        }.joined(separator: ",") ?? "none"
        let reason = player?.reasonForWaitingToPlay?.rawValue ?? "nil"
        let status = item?.status.rawValue ?? -1
        let timeControl = player?.timeControlStatus.rawValue ?? -1
        let keepUp = item?.isPlaybackLikelyToKeepUp ?? false
        let empty = item?.isPlaybackBufferEmpty ?? true
        return "pos=\(String(format: "%.2f", pos)), dur=\(String(format: "%.2f", dur)), buffered=\(String(format: "%.2f", buffered)), itemStatus=\(status), timeControl=\(timeControl), reason=\(reason), keepUp=\(keepUp), empty=\(empty), ranges=[\(ranges)]"
    }

    private func captureTransitionPoster(from player: AVPlayer?, mediaID: String?) {
        guard let mediaID else { return }
        if let cached = SharedAssetCache.shared.cachedThumbnail(for: mediaID) {
            transitionPosterMediaID = mediaID
            transitionPoster = cached
        } else {
            transitionPosterMediaID = mediaID
        }

        guard let asset = player?.currentItem?.asset else { return }
        let captureTime = player?.currentTime() ?? .zero
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        generator.generateCGImageAsynchronously(for: captureTime) { cgImage, _, error in
            guard let cgImage, error == nil else { return }
            let image = UIImage(cgImage: cgImage)
            Task { @MainActor in
                guard self.transitionPosterMediaID == mediaID else { return }
                self.transitionPoster = image
                SharedAssetCache.shared.updateCachedThumbnail(image, for: mediaID)
            }
        }
    }

    func transitionPoster(for mediaID: String) -> UIImage? {
        guard transitionPosterMediaID == mediaID else { return nil }
        return transitionPoster
    }

    /// Lazily create the fullscreen-owned player shell when fullscreen opens.
    func initializePlayerEarly() {
        guard singletonPlayer == nil else {
            return
        }
        
        singletonPlayer = AVPlayer()
        singletonPlayer?.isMuted = false
        
    }

    /// Load and play a video in the singleton player
    func loadVideo(url: URL, mid: String, tweetId: String, cellTweetId: String, videoIndex: Int, mediaType: MediaType) {
        print("🎬 [FullScreenVideoManager] loadVideo start \(shortMID(mid)): mediaType=\(mediaType), current=\(shortMID(currentVideoMid)), loading=\(shortMID(loadingMid)), hasItem=\(singletonPlayer?.currentItem != nil)")
        lastRequestedFullscreenVideo = FullscreenRecoveryRequest(
            url: url,
            mid: mid,
            tweetId: tweetId,
            cellTweetId: cellTweetId,
            videoIndex: videoIndex,
            mediaType: mediaType
        )

        // CRITICAL: If we're already loading this exact video, ignore duplicate calls.
        // TabView/container/page onAppear can all fire for the selected page. The first
        // load owns the handoff; repeating the suspend step can interrupt unrelated feed work
        // while adding no new progress for this video.
        if loadingMid == mid {
            let age = loadingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            print("♻️ [FullScreenVideoManager] Duplicate load ignored for \(String(mid.prefix(8))) (age: \(String(format: "%.1f", age))s, itemAttached: \(singletonPlayer?.currentItem != nil))")
            return
        }

        // Fullscreen is the user's active media target. Clear any stale cancellation
        // from feed scroll cleanup and let the local proxy prioritize this video.
        loadFailedVideoMid = nil
        LocalHTTPServer.shared.clearCancelledState(for: mid)
        LocalHTTPServer.shared.setPrimaryMediaID(mid)
        SharedAssetCache.shared.suspendFeedActivityForFocusedPlayback(protecting: mid, owner: "fullscreen")
        refreshCachedMediaContent(for: mid)

        // If we already have the correct item loaded (e.g. re-entering fullscreen after dismiss
        // without clearSingletonPlayer()), resume playback without thrashing observers/state.
        // Fall through if the player is broken (background stripped the pipeline) so the full
        // reload path runs and recreates a healthy AVPlayerItem.
        if currentVideoMid == mid,
           currentTweetId == tweetId,
           !isPlayerBroken() {
            print("🎬 [FullScreenVideoManager] Reusing existing player for \(shortMID(mid)): \(playerDiagnostic(singletonPlayer, item: singletonPlayer?.currentItem))")
            guard let currentItem = singletonPlayer?.currentItem else { return }
            if isSeekingToRestoredPosition {
                return
            }
            if hasRestoredPosition,
               let player = singletonPlayer,
               player.currentItem === currentItem,
               player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate || player.rate > 0 {
                isPlaying = true
                return
            }
            if currentItem.status != .readyToPlay {
                // Duplicate onAppear calls can arrive while the fresh fullscreen item is
                // still .unknown. Do not rebuild observers here: that can invalidate the
                // deferred item-status observer that will call seekOnceAndPlay() on ready.
                isPlaying = true
                currentItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
                if itemStatusObserver == nil {
                    startPlaybackWithSeekIfNeeded(playerItem: currentItem, mid: mid)
                } else {
                    startFullscreenPlayback(player: singletonPlayer, item: currentItem, log: "duplicate ready wait")
                }
                return
            }

            setupTimeControlStatusObserver()
            if isItemReady {
                // Item is ready — rewind if at end, then play.
                isPlaying = true
                let capturedPlayer = singletonPlayer
                checkAndRewindIfAtEnd {
                    capturedPlayer?.play()
                }
            } else {
                isItemReady = true
                seekOnceAndPlay(playerItem: currentItem, mid: mid)
            }
            return
        }
        
        // Preserve the old frame while preparing a new fullscreen-owned item.
        // Also save position for the old video so it can be restored later.
        if let player = singletonPlayer, player.currentItem != nil, currentVideoMid != mid {
            if let oldMid = currentVideoMid, player.currentItem != nil {
                let t = player.currentTime()
                let d = player.currentItem?.duration ?? .invalid
                captureTransitionPoster(from: player, mediaID: oldMid)
                saveFullscreenPlaybackState(
                    videoMid: oldMid,
                    currentTime: t,
                    wasPlaying: player.rate > 0,
                    duration: d
                )
            }
            player.pause()
        }

        // Bump generation so any prior async completions are ignored.
        if fullscreenLoadTask != nil, let oldLoadingMid = loadingMid ?? currentVideoMid {
            SharedAssetCache.shared.cancelTransientLoading(for: oldLoadingMid)
        }
        fullscreenLoadTask?.cancel()
        fullscreenLoadTask = nil
        loadGeneration += 1
        let generation = loadGeneration
        loadingMid = mid
        loadingStartedAt = Date()
        feedHandoffMid = nil
        feedHandoffExpiresAt = .distantPast
        isUsingBorrowedFeedPlayer = false
        hasRestoredPosition = false // Reset restoration flag when loading new video
        isSeekingToRestoredPosition = false // Reset seeking flag
        resetPlaybackSurfaceState()
        fullscreenStallItemRebuildCount = 0
        isItemReady = false // Will be set true when playerItem.status becomes .readyToPlay
        hasBufferedData = false
        hasCachedMediaContent = false
        hasPlayableMediaContent = false
        refreshCachedMediaContent(for: mid)

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

        if !hasCachedMediaContent {
            SharedAssetCache.shared.prepareUncachedFullscreenLoad(for: mid)
        }
        prewarmedNextVideoMid = nil
        print("🎬 [FullScreenVideoManager] Async asset load start for \(shortMID(mid)): url=\(url.absoluteString)")
        
        initializePlayerEarly()

        // Fullscreen owns its AVPlayer. It reuses cache/local HTTP plumbing, but not feed/detail AVPlayer instances.
        fullscreenLoadTask = Task.detached(priority: .userInitiated) {
            do {
                let playerItem = try await SharedAssetCache.shared.getOrCreatePlayerItem(for: url, mediaID: mid, mediaType: mediaType)
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    // Ignore stale completions
                    guard self.loadGeneration == generation, self.loadingMid == mid else {
                        return
                    }
                    self.initializePlayerEarly()
                    guard let player = self.singletonPlayer else {
                        self.loadingMid = nil
                        self.loadingStartedAt = nil
                        self.isPlaying = false
                        return
                    }
                    self.loadingMid = nil
                    self.loadingStartedAt = nil
                    self.fullscreenLoadTask = nil
                    print("🎬 [FullScreenVideoManager] Fullscreen item load ready for \(self.shortMID(mid)): itemStatus=\(playerItem.status.rawValue)")
                    // Ensure audio session uses playback category so hardware mute switch doesn't silence fullscreen video
                    AudioSessionManager.shared.activateForVideoPlayback()

                    player.pause()
                    player.replaceCurrentItem(with: playerItem)
                    self.currentVideoMid = mid
                    self.currentTweetId = tweetId
                    self.currentCellTweetId = cellTweetId
                    self.currentVideoIndex = videoIndex
                    self.isUsingBorrowedFeedPlayer = false
                    self.refreshCachedMediaContent(for: mid)

                    self.applyStartupAudioMuteIfNeeded()
                    
                    // Setup video completion observer
                    self.setupVideoCompletionObserver(playerItem)
                    
                    // Setup timeControlStatus observer for buffering detection and autoplay
                    self.setupTimeControlStatusObserver()
                    
                    // Start monitoring for stalls during seeking
                    self.startRetryMonitoring()
                    
                    // Start playback — same unified path as cached player
                    self.startPlaybackWithSeekIfNeeded(playerItem: playerItem, mid: mid)
                    
                }
            } catch {
                if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                await MainActor.run {
                    guard self.loadGeneration == generation, self.loadingMid == mid else {
                        return
                    }
                    self.loadingMid = nil
                    self.loadingStartedAt = nil
                    self.fullscreenLoadTask = nil

                    print("ERROR: [FullScreenVideoManager] Failed to load video: \(error)")
                    self.failFullscreenVideoLoad(failedMid: mid, reason: "async player creation failed: \(error.localizedDescription)", deleteDiskCache: true, advanceToNext: false)
                }
            }
        }
    }
    
    func setStartupAudioMuteWindow(duration: TimeInterval) {
        let safeDuration = max(0, duration)
        startupAudioMuteUntil = Date().addingTimeInterval(safeDuration)
        applyStartupAudioMuteIfNeeded()
    }

    private func applyStartupAudioMuteIfNeeded() {
        guard let player = singletonPlayer else { return }
        let now = Date()
        if now < startupAudioMuteUntil {
            player.isMuted = true
            startupAudioUnmuteTask?.cancel()
            let delay = startupAudioMuteUntil.timeIntervalSince(now)
            let nanos = UInt64(max(0, delay) * 1_000_000_000)
            startupAudioUnmuteTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: nanos)
                guard Date() >= self.startupAudioMuteUntil else { return }
                self.singletonPlayer?.isMuted = false
            }
        } else {
            player.isMuted = false
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
        if let observer = fullscreenProgressObserver,
           let player = fullscreenProgressObserverPlayer {
            player.removeTimeObserver(observer)
        }
        fullscreenProgressObserver = nil
        fullscreenProgressObserverPlayer = nil
        wasPlayingBeforeWaiting = false
        
        nearEndAdvanceTask?.cancel()
        nearEndAdvanceTask = nil
        prewarmedNextVideoMid = nil

    }
    
    /// Setup timeControlStatus observer for buffering detection and autoplay
    private func setupTimeControlStatusObserver() {
        cleanupObservers()
        
        guard let player = singletonPlayer, let playerItem = player.currentItem else {
            return
        }
        
        
        // Helper to update buffering state
        let updateBufferingState: @MainActor @Sendable () -> Void = { [weak self, weak player, weak playerItem] in
            guard let self = self,
                  let player = player,
                  let item = playerItem,
                  self.singletonPlayer === player,
                  player.currentItem === item else {
                return
            }
            
            let isBufferEmpty = item.isPlaybackBufferEmpty
            let isLikelyToKeepUp = item.isPlaybackLikelyToKeepUp
            let isWaiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            let isActivelyRendering = player.timeControlStatus == .playing
            let wasPlaying = player.rate > 0 || self.isPlaying
            // Disk-cached/local items can be ready and likely to keep up before
            // loadedTimeRanges reports a range, so treat AVPlayer's playable
            // signals as buffered for spinner purposes.
            let bufferedDuration = self.bufferedTimeAhead(for: item, player: player)
            let hasBufferedData = self.hasPlayableData(
                player: player,
                item: item,
                bufferedAhead: bufferedDuration,
                keepUp: isLikelyToKeepUp
            )
            self.hasBufferedData = hasBufferedData
            self.hasPlayableMediaContent = hasBufferedData
            let itemStatus = item.status
            let nearEnd = self.timeRemaining(for: item, player: player).map { $0 <= 1.0 } ?? false
            if nearEnd && wasPlaying && !isActivelyRendering {
                self.scheduleNearEndAutoAdvance(for: item)
            }
            
            let wantsPlayback = wasPlaying || self.wasPlayingBeforeWaiting || self.isPlaying
            let isWaitingForPlayableData = !hasBufferedData && !isActivelyRendering && wantsPlayback && (
                isWaiting
                    || isBufferEmpty
                    || (itemStatus == .readyToPlay && (!hasBufferedData || (bufferedDuration < 0.5 && !isLikelyToKeepUp)))
            )

            if isWaitingForPlayableData {
                if !self.wasPlayingBeforeWaiting && wasPlaying {
                    self.wasPlayingBeforeWaiting = true
                }
            } else {
                if isActivelyRendering && !player.automaticallyWaitsToMinimizeStalling {
                    player.automaticallyWaitsToMinimizeStalling = true
                }
                if isActivelyRendering {
                    self.transitionPosterMediaID = nil
                    self.transitionPoster = nil
                }
                // Autoplay logic: check multiple conditions to ensure we resume when data is ready
                // 2.0s minimum prevents play/pause flickering when buffer is too thin to sustain playback
                let hasEnoughBuffer = hasBufferedData && bufferedDuration >= 2.0
                let isReadyToPlay = itemStatus == .readyToPlay
                let isNotPlaying = player.rate == 0
                let isAlreadyWaiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                let wantsToPlay = self.isPlaying || self.wasPlayingBeforeWaiting
                
                // Position restoration is owned by startPlaybackWithSeekIfNeeded().
                // KVO can fire repeatedly during attachment and buffering; doing seeks
                // here creates duplicate handoff seeks and momentary freezes.
                if !self.hasRestoredPosition && !self.isSeekingToRestoredPosition && isReadyToPlay && hasEnoughBuffer {
                    self.hasRestoredPosition = true
                }
                
                // Don't play if we're currently seeking to restored position
                if self.isSeekingToRestoredPosition {
                    return // Still waiting for seek to complete
                }
                
                // Only play if we've already restored position (or there was no saved state)
                if !self.hasRestoredPosition {
                    return // Still waiting for restoration
                }
                
                // If we want to play, have data, and player is not playing, resume.
                // Skip if already in .waitingToPlayAtSpecifiedRate — player is already trying
                // to play; redundant play() calls disrupt AVPlayer's buffering state machine
                // and cause timeControlStatus oscillation (play button flickering).
                if wantsToPlay && isReadyToPlay && hasEnoughBuffer && isNotPlaying && !isAlreadyWaiting {
                    self.startFullscreenPlayback(player: player, item: item, log: "buffer recovered")
                    self.wasPlayingBeforeWaiting = false
                } else if player.timeControlStatus == .playing || player.rate > 0 || isAlreadyWaiting {
                    // Already playing or buffering — just reset flag
                    if self.wasPlayingBeforeWaiting {
                        self.wasPlayingBeforeWaiting = false
                    }
                    // Sync isPlaying if player was started externally (e.g. AVPlayerViewController controls)
                    if !self.isPlaying && (player.timeControlStatus == .playing || isAlreadyWaiting) {
                        self.isPlaying = true
                    }
                }
            }
        }
        
        // Observe playbackBufferEmpty - most reliable indicator
        playbackBufferEmptyObserver = playerItem.observe(\.isPlaybackBufferEmpty, options: [.new, .initial]) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    updateBufferingState()
                }
            }
        }
        
        // Observe playbackLikelyToKeepUp
        playbackLikelyToKeepUpObserver = playerItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new, .initial]) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    updateBufferingState()
                }
            }
        }
        
        // Observe loadedTimeRanges to catch when data arrives
        self.loadedTimeRangesObserver = playerItem.observe(\.loadedTimeRanges, options: [.new]) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    updateBufferingState()
                }
            }
        }
        
        // Observe item status changes
        self.itemStatusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    print("🎬 [FullScreenVideoManager] itemStatus \(self.shortMID(self.currentVideoMid)): \(self.playerDiagnostic(player, item: playerItem))")
                    if playerItem.status == .failed {
                        self.failFullscreenVideoLoad(reason: "item status failed", deleteDiskCache: true, advanceToNext: false)
                        return
                    }
                    updateBufferingState()
                }
            }
        }
        
        // Observe timeControlStatus as backup
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    print("🎬 [FullScreenVideoManager] timeControl \(self.shortMID(self.currentVideoMid)): \(self.playerDiagnostic(player, item: playerItem))")
                    updateBufferingState()
                }
            }
        }

        setupFullscreenProgressObserver(player: player, item: playerItem)
    }

    private func setupFullscreenProgressObserver(player: AVPlayer, item: AVPlayerItem) {
        if let observer = fullscreenProgressObserver,
           let observedPlayer = fullscreenProgressObserverPlayer {
            observedPlayer.removeTimeObserver(observer)
        }

        fullscreenProgressObserverPlayer = player
        fullscreenProgressObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player, weak item] _ in
            Task { @MainActor [weak self, weak player, weak item] in
                guard let self,
                      self.isActive,
                      let player,
                      let item,
                      self.singletonPlayer === player,
                      player.currentItem === item,
                      player.rate > 0 || self.isPlaying,
                      let remaining = self.timeRemaining(for: item, player: player),
                      remaining <= 3.0,
                      remaining > 0 else {
                    return
                }
                self.prewarmNextFullscreenVideoIfNeeded()
            }
        }
    }

    private func prewarmNextFullscreenVideoIfNeeded() {
        guard !videoList.isEmpty,
              let next = resolveNextVideo(after: videoListIndex),
              let attachments = next.tweet.attachments,
              next.videoIndex < attachments.count else {
            return
        }

        let attachment = attachments[next.videoIndex]
        guard attachment.type == .video || attachment.type == .hls_video,
              prewarmedNextVideoMid != attachment.mid else {
            return
        }

        let baseUrl = next.tweet.author?.baseUrl
            ?? HproseInstance.shared.appUser.baseUrl
            ?? HproseInstance.baseUrl
        guard let url = attachment.getUrl(baseUrl) else { return }

        prewarmedNextVideoMid = attachment.mid
        print("🔮 [FullScreenVideoManager] Prewarming next fullscreen asset \(shortMID(attachment.mid))")
        SharedAssetCache.shared.preloadAsset(
            for: url,
            mediaID: attachment.mid,
            tweetId: next.tweet.mid,
            mediaType: attachment.type
        )
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
                guard self.isActive else { return }
                let finishedItem = item
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                guard self.isActive,
                      self.singletonPlayer?.currentItem === finishedItem else {
                    return
                }
                self.handleVideoFinished()
            }
        }
    }

    private func failFullscreenVideoLoad(failedMid explicitFailedMid: String? = nil, reason: String, deleteDiskCache: Bool, advanceToNext: Bool = false) {
        guard let failedMid = explicitFailedMid ?? currentVideoMid else { return }
        let nextVideo = advanceToNext ? resolveNextVideo(after: videoListIndex) : nil

        print("❌ [FullScreenVideoManager] \(reason) - releasing fullscreen player \(shortMID(failedMid)), deleteDiskCache=\(deleteDiskCache)")

        loadGeneration += 1
        fullscreenLoadTask?.cancel()
        fullscreenLoadTask = nil
        loadingMid = nil
        loadingStartedAt = nil
        retryWorkItem?.cancel()
        retryWorkItem = nil
        bufferObserver?.invalidate()
        bufferObserver = nil
        cleanupObservers()

        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }

        if let player = singletonPlayer {
            player.pause()
            player.currentItem?.cancelPendingSeeks()
            player.currentItem?.asset.cancelLoading()
            SharedAssetCache.shared.clearPlayerForMediaID(failedMid, deleteDiskCache: deleteDiskCache)
            player.replaceCurrentItem(with: nil)
        } else {
            SharedAssetCache.shared.clearPlayerForMediaID(failedMid, deleteDiskCache: deleteDiskCache)
        }

        VideoStateCache.shared.clearCachedState(for: failedMid)
        LocalHTTPServer.shared.clearPrimaryRestriction()

        singletonPlayer = nil
        isPlaying = false
        wasPlayingBeforeWaiting = false
        hasBufferedData = false
        hasCachedMediaContent = false
        hasPlayableMediaContent = false
        isItemReady = false
        isUsingBorrowedFeedPlayer = false
        isSeekingToRestoredPosition = false
        hasRestoredPosition = false
        resetPlaybackSurfaceState()
        fullscreenStallItemRebuildCount = 0
        if let nextVideo {
            loadFailedVideoMid = nil
            videoListIndex = nextVideo.listIndex
            currentVideoMid = nil
            currentTweetId = nil
            currentCellTweetId = nil
            currentVideoIndex = 0
            onNavigateToNextVideo?(nextVideo.tweet, nextVideo.videoIndex, nextVideo.cellTweetId)
        } else {
            loadFailedVideoMid = failedMid
            currentVideoMid = nil
            currentTweetId = nil
            currentCellTweetId = nil
            currentVideoIndex = 0
        }
    }
    
    /// Start monitoring for playback stalls and auto-retry
    private func startRetryMonitoring() {
        guard !isUsingBorrowedFeedPlayer else {
            retryWorkItem?.cancel()
            retryWorkItem = nil
            return
        }

        // Cancel existing monitoring
        retryWorkItem?.cancel()
        print("🎬 [FullScreenVideoManager] retryMonitor scheduled \(shortMID(currentVideoMid)): \(playerDiagnostic(singletonPlayer, item: singletonPlayer?.currentItem))")
        
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
        guard isPlaying || wasPlayingBeforeWaiting else { return }
        print("🎬 [FullScreenVideoManager] retryCheck \(shortMID(currentVideoMid)): \(playerDiagnostic(player, item: playerItem))")

        if playerItem.status == .failed || player.error != nil || playerItem.error != nil {
            failFullscreenVideoLoad(reason: "retry detected failed item", deleteDiskCache: true, advanceToNext: false)
            return
        }

        if let remaining = timeRemaining(for: playerItem, player: player),
           remaining <= 1.0,
           player.timeControlStatus != .playing {
            print("🎬 [FullScreenVideoManager] retryCheck near end \(shortMID(currentVideoMid)): remaining=\(String(format: "%.2f", remaining))")
            scheduleNearEndAutoAdvance(for: playerItem)
            return
        }

        if playerItem.status == .readyToPlay,
           !hasRestoredPosition,
           !isSeekingToRestoredPosition,
           bufferedTimeAhead(for: playerItem, player: player) >= 2.0,
           let mid = currentVideoMid {
            print("🎬 [FullScreenVideoManager] retry recovered missed ready path \(shortMID(mid)): \(playerDiagnostic(player, item: playerItem))")
            seekOnceAndPlay(playerItem: playerItem, mid: mid)
            return
        }

        let bufferedAhead = bufferedTimeAhead(for: playerItem, player: player)
        let keepUp = playerItem.isPlaybackLikelyToKeepUp
        let requiredBuffer = fullscreenRequiredBufferAhead(for: playerItem, player: player)
        if playerItem.status == .readyToPlay,
           !isSeekingToRestoredPosition,
           player.timeControlStatus != .playing,
           bufferedAhead >= requiredBuffer {
            playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            player.automaticallyWaitsToMinimizeStalling = false
            print("🎬 [FullScreenVideoManager] retry buffer nudge \(shortMID(currentVideoMid)): buffered=\(String(format: "%.2f", bufferedAhead)), required=\(String(format: "%.2f", requiredBuffer)), keepUp=\(keepUp), \(playerDiagnostic(player, item: playerItem))")
            startFullscreenPlayback(player: player, item: playerItem, log: "retry buffer nudge")
            wasPlayingBeforeWaiting = false
            startRetryMonitoring()
            return
        }

        // If player is stuck, force a seek to trigger segment loading. AVPlayer can
        // remain at rate > 0 while waiting, so timeControlStatus is the stronger signal.
        let isWaitingWithoutBuffer = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            && bufferedAhead < 0.25
        if player.timeControlStatus != .playing && (player.rate == 0 || isWaitingWithoutBuffer) {
            let currentTime = player.currentTime()
            print("🎬 [FullScreenVideoManager] retry seek-current \(shortMID(currentVideoMid)): target=\(String(format: "%.2f", currentTime.seconds)), \(playerDiagnostic(player, item: playerItem))")
            
            // Clean up old observer
            bufferObserver?.invalidate()
            bufferObserver = nil
            
            // Force seek to current position to trigger segment download
            player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player, weak playerItem] finished in
                guard let self = self else { return }
                guard finished, let player = player, let item = playerItem else {
                    Task { @MainActor in
                        guard self.isActive else { return }
                        self.startRetryMonitoring()
                    }
                    return
                }

                Task { @MainActor in
                    // Bail if fullscreen was dismissed while seek was in flight.
                    guard self.isActive else { return }

                    // Wait for buffered data before calling play()
                    self.bufferObserver = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self, weak player] observedItem, _ in
                        guard let self, let player else { return }
                        Task { @MainActor in
                            guard self.isActive else { return }
                            let bufferedAhead = self.bufferedTimeAhead(for: observedItem, player: player)

                            let requiredBuffer = fullscreenRequiredBufferAhead(for: observedItem, player: player)
                            let remaining = self.timeRemaining(for: observedItem, player: player)
                            if let remaining, remaining <= 1.0 {
                                print("🎬 [FullScreenVideoManager] retry buffer near-end \(self.shortMID(self.currentVideoMid)): remaining=\(String(format: "%.2f", remaining))")
                                self.scheduleNearEndAutoAdvance(for: observedItem)
                            } else if bufferedAhead >= requiredBuffer {
                                // Bail if fullscreen was dismissed while waiting for buffer.
                                // deactivate() sets isActive=false + pauses the player, but the
                                // KVO callback may already be enqueued on the main actor — this
                                // guard prevents the stale play() call from re-starting audio.
                                guard self.isPlaying || self.wasPlayingBeforeWaiting else { return }

                                // Clean up observer
                                self.bufferObserver?.invalidate()
                                self.bufferObserver = nil

                                print("🎬 [FullScreenVideoManager] retry buffer ready \(self.shortMID(self.currentVideoMid)): bufferedAhead=\(String(format: "%.2f", bufferedAhead)), required=\(String(format: "%.2f", requiredBuffer)), \(self.playerDiagnostic(player, item: observedItem))")
                                self.startFullscreenPlayback(player: player, item: observedItem, log: "retry buffer ready")
                                self.wasPlayingBeforeWaiting = false

                                // Continue monitoring for future stalls
                                self.startRetryMonitoring()
                            }
                        }
                    }

                    // Safety timeout: if no data arrives, rebuild once; after that fail and release.
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.fullscreenRetryBufferTimeout) { [weak self] in
                        Task { @MainActor in
                            guard let self = self else { return }
                            guard self.isActive else { return }
                            if self.bufferObserver != nil,
                               self.singletonPlayer?.currentItem === item {
                                print("🎬 [FullScreenVideoManager] retry buffer timeout \(self.shortMID(self.currentVideoMid)): \(self.playerDiagnostic(self.singletonPlayer, item: self.singletonPlayer?.currentItem))")
                                let bufferedAhead = self.bufferedTimeAhead(for: item, player: player)
                                let requiredBuffer = fullscreenRequiredBufferAhead(for: item, player: player)
                                if item.status == .readyToPlay,
                                   bufferedAhead > 0.25,
                                   !item.isPlaybackBufferEmpty {
                                    print("🎬 [FullScreenVideoManager] retry buffer still growing \(self.shortMID(self.currentVideoMid)): buffered=\(String(format: "%.2f", bufferedAhead)), required=\(String(format: "%.2f", requiredBuffer)) - waiting")
                                    self.startRetryMonitoring()
                                    return
                                }
                                self.bufferObserver?.invalidate()
                                self.bufferObserver = nil
                                if let player = self.singletonPlayer,
                                   let item = player.currentItem,
                                   let mid = self.currentVideoMid,
                                   self.fullscreenStallItemRebuildCount < 1 {
                                    self.rebuildFullscreenItemAfterStall(player: player, item: item, mid: mid)
                                } else {
                                    self.failFullscreenVideoLoad(reason: "retry buffer timeout after rebuild", deleteDiskCache: false, advanceToNext: true)
                                }
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

    private func rebuildFullscreenItemAfterStall(player: AVPlayer, item: AVPlayerItem, mid: String) {
        guard isActive,
              singletonPlayer === player,
              player.currentItem === item,
              currentVideoMid == mid else { return }
        guard let request = lastRequestedFullscreenVideo,
              request.mid == mid else {
            failFullscreenVideoLoad(failedMid: mid, reason: "retry rebuild missing request context", deleteDiskCache: false, advanceToNext: true)
            return
        }

        fullscreenStallItemRebuildCount += 1
        let resumeTime = player.currentTime()
        let duration = item.duration
        if resumeTime.isValid, resumeTime.seconds.isFinite, resumeTime.seconds > 0.25 {
            saveFullscreenPlaybackState(
                videoMid: mid,
                currentTime: resumeTime,
                wasPlaying: true,
                duration: duration
            )
        }

        print("🎬 [FullScreenVideoManager] rebuilding stalled fullscreen item \(shortMID(mid)): resume=\(String(format: "%.2f", resumeTime.seconds)), \(playerDiagnostic(player, item: item))")
        LocalHTTPServer.shared.clearCancelledState(for: mid)
        LocalHTTPServer.shared.setPrimaryMediaID(mid)

        retryWorkItem?.cancel()
        retryWorkItem = nil
        bufferObserver?.invalidate()
        bufferObserver = nil
        hasRestoredPosition = false
        isSeekingToRestoredPosition = false
        resetPlaybackSurfaceState()
        isItemReady = false
        refreshCachedMediaContent(for: mid)
        isPlaying = true
        wasPlayingBeforeWaiting = true

        loadGeneration += 1
        let generation = loadGeneration
        loadingMid = mid
        loadingStartedAt = Date()
        fullscreenLoadTask?.cancel()
        fullscreenLoadTask = Task.detached(priority: .userInitiated) {
            do {
                let replacementItem = try await SharedAssetCache.shared.getOrCreatePlayerItem(
                    for: request.url,
                    mediaID: mid,
                    mediaType: request.mediaType
                )
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard self.isActive,
                          self.loadGeneration == generation,
                          self.loadingMid == mid,
                          self.singletonPlayer === player,
                          player.currentItem === item,
                          self.currentVideoMid == mid else { return }

                    self.loadingMid = nil
                    self.loadingStartedAt = nil
                    self.fullscreenLoadTask = nil
                    replacementItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
                    player.replaceCurrentItem(with: replacementItem)
                    NotificationCenter.default.post(
                        name: .videoPlayerItemReplaced,
                        object: nil,
                        userInfo: ["mediaID": mid]
                    )

                    self.setupVideoCompletionObserver(replacementItem)
                    self.setupTimeControlStatusObserver()
                    self.startPlaybackWithSeekIfNeeded(playerItem: replacementItem, mid: mid)
                    self.startRetryMonitoring()
                }
            } catch {
                if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                await MainActor.run {
                    guard self.isActive,
                          self.loadGeneration == generation,
                          self.loadingMid == mid,
                          self.currentVideoMid == mid else { return }
                    self.loadingMid = nil
                    self.loadingStartedAt = nil
                    self.fullscreenLoadTask = nil
                    self.failFullscreenVideoLoad(failedMid: mid, reason: "retry rebuild player item failed: \(error.localizedDescription)", deleteDiskCache: false, advanceToNext: true)
                }
            }
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
    
    /// Unified seek-then-play for all load paths. Computes the seek target once,
    /// performs a single seek (or none), then calls play(). If the item isn't ready
    /// yet, sets up a KVO observer to defer until readyToPlay.
    private func startPlaybackWithSeekIfNeeded(playerItem: AVPlayerItem, mid: String) {
        print("🎬 [FullScreenVideoManager] startPlaybackWithSeekIfNeeded \(shortMID(mid)): \(playerDiagnostic(singletonPlayer, item: playerItem))")
        guard playerItem.status == .readyToPlay else {
            // Item not ready — observe status and retry when ready
            self.isPlaying = true // Mark as "should be playing"
            playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            self.itemStatusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    print("🎬 [FullScreenVideoManager] deferred itemStatus \(self.shortMID(mid)): \(self.playerDiagnostic(self.singletonPlayer, item: item))")
                    if item.status == .readyToPlay {
                        self.isItemReady = true
                        self.seekOnceAndPlay(playerItem: item, mid: mid)
                        self.itemStatusObserver?.invalidate()
                        self.itemStatusObserver = nil
                    } else if item.status == .failed {
                        print("❌ [FullScreenVideoManager] PlayerItem failed: \(item.error?.localizedDescription ?? "unknown")")
                        self.failFullscreenVideoLoad(reason: "deferred item status failed", deleteDiskCache: true, advanceToNext: false)
                    }
                }
            }
            return
        }
        self.isItemReady = true
        seekOnceAndPlay(playerItem: playerItem, mid: mid)
    }

    /// Compute the single correct seek target and play. Called only when item is readyToPlay.
    private func seekOnceAndPlay(playerItem: AVPlayerItem, mid: String) {
        print("🎬 [FullScreenVideoManager] seekOnceAndPlay \(shortMID(mid)): \(playerDiagnostic(singletonPlayer, item: playerItem))")
        if isUsingBorrowedFeedPlayer {
            hasRestoredPosition = true
            isSeekingToRestoredPosition = false
            startFullscreenPlayback(player: singletonPlayer, item: playerItem, log: "borrowed feed player")
            print("▶️ [FullScreenVideoManager] Playing borrowed feed player without seek")
            return
        }

        // Determine where to seek (nil = no seek needed)
        let seekTarget: CMTime? = {
            let duration = playerItem.duration
            // 1) Video finished in feed cell → restart from beginning
            if duration.isValid && duration.seconds > 0,
               VideoStateCache.shared.hasVideoFinishedInMediaCell(for: mid, duration: duration) {
                print("🔄 [FullScreenVideoManager] Video \(mid) finished in mediaCell - restarting")
                return .zero
            }
            // 2) Position handed off from feed/detail or the freshest saved state
            if !isUsingBorrowedFeedPlayer,
               let handoffTime = crossSurfaceResumeTime(for: mid, duration: duration) {
                print("🔄 [FullScreenVideoManager] Restoring handoff position: \(handoffTime.seconds)s")
                return handoffTime
            }
            // 3) Saved fullscreen position to restore
            if !isUsingBorrowedFeedPlayer,
               PersistentVideoStateManager.shared.shouldRestorePlayback(videoMid: mid, context: .fullScreen),
               let saved = PersistentVideoStateManager.shared.getState(videoMid: mid, context: .fullScreen, duration: duration) {
                if saved.currentTime.isValid && saved.currentTime.seconds.isFinite {
                    print("🔄 [FullScreenVideoManager] Restoring position: \(saved.currentTime.seconds)s")
                    return saved.currentTime
                } else {
                    PersistentVideoStateManager.shared.clearState(videoMid: mid, context: .fullScreen)
                }
            }
            // 4) At/near end → rewind
            if duration.isValid && duration.seconds > 0 {
                let remaining = duration.seconds - playerItem.currentTime().seconds
                if remaining <= 0.5 { return .zero }
            }
            return nil
        }()

        if let target = seekTarget {
            if let player = singletonPlayer,
               isNear(player.currentTime(), target, tolerance: 0.35) {
                hasRestoredPosition = true
                isSeekingToRestoredPosition = false
                startFullscreenPlayback(player: player, item: playerItem, log: "near handoff target")
                return
            }
            isSeekingToRestoredPosition = true
            print("🎬 [FullScreenVideoManager] Seeking \(shortMID(mid)) to \(String(format: "%.2f", target.seconds))s before play")
            self.singletonPlayer?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.isSeekingToRestoredPosition = false
                    guard finished else { return }
                    self.hasRestoredPosition = true
                    print("🎬 [FullScreenVideoManager] Seek finished \(self.shortMID(mid)): \(self.playerDiagnostic(self.singletonPlayer, item: playerItem))")
                    self.startFullscreenPlayback(player: self.singletonPlayer, item: playerItem, log: "after seek to \(target.seconds)s")
                    print("▶️ [FullScreenVideoManager] Playing after seek to \(target.seconds)s")
                }
            }
        } else {
            hasRestoredPosition = true
            isSeekingToRestoredPosition = false
            startFullscreenPlayback(player: singletonPlayer, item: playerItem, log: "immediate")
            print("▶️ [FullScreenVideoManager] Playing immediately (no seek needed)")
        }
    }

    private func startFullscreenPlayback(player: AVPlayer?, item: AVPlayerItem, log: String) {
        guard let player else { return }
        guard isActive,
              singletonPlayer === player,
              player.currentItem === item else {
            return
        }

        guard playbackSurfaceReadyMid == currentVideoMid else {
            if let pending = pendingSurfacePlayback,
               pending.player === player,
               pending.item === item {
                isPlaying = true
                schedulePlaybackSurfaceFallbackIfNeeded(player: player, item: item)
                return
            }

            player.pause()
            pendingSurfacePlayback = (player: player, item: item, log: log)
            isPlaying = true
            schedulePlaybackSurfaceFallbackIfNeeded(player: player, item: item)
            print("🎬 [FullScreenVideoManager] deferring play(\(log)) until fullscreen surface is ready \(shortMID(currentVideoMid)): \(playerDiagnostic(player, item: item))")
            return
        }

        playbackSurfaceFallbackTask?.cancel()
        playbackSurfaceFallbackTask = nil
        pendingSurfacePlayback = nil
        let bufferPolicy = applyFullscreenPrePlayBuffering(to: player, item: item)
        markPlayableMediaContentIfBuffered(
            player: player,
            item: item,
            bufferedAhead: bufferPolicy.bufferedAhead,
            keepUp: bufferPolicy.keepUp
        )
        print("🎬 [FullScreenVideoManager] play(\(log)) \(shortMID(currentVideoMid)): autoWait=\(player.automaticallyWaitsToMinimizeStalling), buffered=\(String(format: "%.2f", bufferPolicy.bufferedAhead)), required=\(String(format: "%.2f", bufferPolicy.requiredBuffer)), keepUp=\(bufferPolicy.keepUp), \(playerDiagnostic(player, item: item))")
        player.play()
        isPlaying = true
    }

    private func schedulePlaybackSurfaceFallbackIfNeeded(player: AVPlayer, item: AVPlayerItem) {
        guard playbackSurfaceFallbackTask == nil,
              let mid = currentVideoMid else { return }

        playbackSurfaceFallbackTask = Task { @MainActor [weak self, weak player, weak item] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self else { return }
            self.playbackSurfaceFallbackTask = nil

            guard !Task.isCancelled,
                  self.isActive,
                  self.currentVideoMid == mid,
                  self.playbackSurfaceReadyMid != mid,
                  let player,
                  let item,
                  self.singletonPlayer === player,
                  player.currentItem === item else {
                return
            }

            self.playbackSurfaceReadyMid = mid
            print("🎬 [FullScreenVideoManager] playback surface ready fallback \(self.shortMID(mid)): \(self.playerDiagnostic(player, item: item))")

            guard let pending = self.pendingSurfacePlayback,
                  pending.player === player,
                  pending.item === item else {
                return
            }

            self.pendingSurfacePlayback = nil
            self.startFullscreenPlayback(player: player, item: item, log: "\(pending.log), surface fallback")
        }
    }

    private func isNear(_ lhs: CMTime, _ rhs: CMTime, tolerance: Double) -> Bool {
        let left = CMTimeGetSeconds(lhs)
        let right = CMTimeGetSeconds(rhs)
        guard left.isFinite, right.isFinite else { return false }
        return abs(left - right) <= tolerance
    }

    private func bufferedTimeAhead(for item: AVPlayerItem, player: AVPlayer) -> Double {
        let currentSeconds = CMTimeGetSeconds(player.currentTime())
        guard currentSeconds.isFinite else { return 0 }
        var bestBufferAhead: Double = 0
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = CMTimeGetSeconds(range.start)
            let duration = CMTimeGetSeconds(range.duration)
            guard start.isFinite, duration.isFinite else { continue }
            let end = start + duration
            if currentSeconds >= start && currentSeconds <= end {
                return max(0, end - currentSeconds)
            } else if end > currentSeconds {
                bestBufferAhead = max(bestBufferAhead, end - currentSeconds)
            }
        }
        return max(0, bestBufferAhead)
    }

    nonisolated private func timeRemaining(for item: AVPlayerItem, player: AVPlayer) -> Double? {
        let duration = item.duration
        guard duration.isValid, duration.seconds.isFinite, duration.seconds > 0 else { return nil }
        let current = player.currentTime()
        guard current.isValid, current.seconds.isFinite else { return nil }
        return duration.seconds - current.seconds
    }

    private func scheduleNearEndAutoAdvance(for item: AVPlayerItem) {
        guard isActive, nearEndAdvanceTask == nil else { return }
        let task = DispatchWorkItem { [weak self, weak item] in
            Task { @MainActor [weak self, weak item] in
                guard let self,
                      self.isActive,
                      let item,
                      self.singletonPlayer?.currentItem === item,
                      let player = self.singletonPlayer,
                      let remaining = self.timeRemaining(for: item, player: player),
                      remaining <= 1.0,
                      player.timeControlStatus != .playing else {
                    self?.nearEndAdvanceTask = nil
                    return
                }
                print("✅ [FullScreenVideoManager] Treating near-end stall as finished - remaining: \(remaining)s")
                self.nearEndAdvanceTask = nil
                self.handleVideoFinished()
            }
        }
        nearEndAdvanceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: task)
    }

    /// Check if video is at the end and rewind if needed before playing
    private func checkAndRewindIfAtEnd(completion: @escaping @MainActor @Sendable () -> Void) {
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
                    Task { @MainActor in
                        guard finished, let _ = self else {
                            completion()
                            return
                        }
                        completion()
                    }
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
        let pendingLoadMid = loadingMid ?? currentVideoMid

        // Only save playback state if player actually loaded (has a currentItem).
        // If currentItem is nil (video never finished loading due to IPFS latency),
        // saving would write 0.0s and overwrite the valid position saved by the feed cell.
        if let player = singletonPlayer,
           let videoMid = currentVideoMid,
           player.currentItem != nil {
            let wasPlaying = player.rate > 0
            let currentTime = player.currentTime()
            let duration = player.currentItem?.duration ?? .invalid

            saveFullscreenPlaybackState(
                videoMid: videoMid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                duration: duration
            )
        }

        // Keep the fullscreen-owned player item alive so reopening fullscreen can
        // reuse the warm player shell and recent buffer.
        singletonPlayer?.pause()
        LocalHTTPServer.shared.clearPrimaryRestriction()
        fullscreenStallItemRebuildCount = 0

        isItemReady = false
        currentVideoMid = nil
        currentTweetId = nil
        currentCellTweetId = nil
        currentVideoIndex = 0
        isUsingBorrowedFeedPlayer = false
        isPlaying = false
        resetPlaybackSurfaceState()
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
        if fullscreenLoadTask != nil, let pendingLoadMid {
            SharedAssetCache.shared.cancelTransientLoading(for: pendingLoadMid)
        }
        fullscreenLoadTask?.cancel()
        fullscreenLoadTask = nil
        
        // Clean up buffer observer
        bufferObserver?.invalidate()
        bufferObserver = nil
        
        // Clean up timeControlStatus observers
        cleanupObservers()
        hasCachedMediaContent = false
        hasBufferedData = false
        hasPlayableMediaContent = false
        
        
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
            guard let item = player.currentItem else { return }
            self.startFullscreenPlayback(player: player, item: item, log: "manual play")
        }
    }

    func markPlaybackSurfaceReady(player: AVPlayer, mid: String) {
        guard isActive,
              currentVideoMid == mid,
              singletonPlayer === player else {
            return
        }

        playbackSurfaceReadyMid = mid
        playbackSurfaceFallbackTask?.cancel()
        playbackSurfaceFallbackTask = nil
        if let item = player.currentItem {
            markPlayableMediaContentIfBuffered(player: player, item: item)
        }

        guard let pending = pendingSurfacePlayback,
              pending.player === player,
              player.currentItem === pending.item else {
            return
        }

        pendingSurfacePlayback = nil
        startFullscreenPlayback(player: pending.player, item: pending.item, log: "\(pending.log), surface ready")
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
                || PersistentVideoStateManager.shared.latestState(videoMid: videoMid, excluding: .fullScreen) != nil
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
                    self.startFullscreenPlayback(player: player, item: playerItem, log: "post-recovery")
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
        let playerBroken = playerMissing ? false : isPlayerBroken()
        let playerEmptyAfterRestart = shouldReloadFullscreenPlayerAfterInfrastructureRestart()

        guard playerMissing || itemMissing || playerBroken || playerEmptyAfterRestart else {
            // Player is healthy, nothing to do
            print("✅ [FullScreenVideoManager] handleReloadVisibleVideosOnly - player healthy")
            return
        }

        print("🔄 [FullScreenVideoManager] handleReloadVisibleVideosOnly - player needs reload (playerMissing:\(playerMissing), itemMissing:\(itemMissing), playerBroken:\(playerBroken), emptyAfterRestart:\(playerEmptyAfterRestart))")

        guard let request = lastRequestedFullscreenVideo,
              request.mid == currentVideoMid || currentVideoMid == nil || request.mid == loadingMid else {
            print("⚠️ [FullScreenVideoManager] handleReloadVisibleVideosOnly - no video info to reload")
            return
        }

        if let player = singletonPlayer,
           let videoMid = currentVideoMid {
            captureTransitionPoster(from: player, mediaID: videoMid)
            let t = player.currentTime()
            if t.isValid, t.seconds.isFinite, t.seconds > 0.25 {
                saveFullscreenPlaybackState(
                    videoMid: videoMid,
                    currentTime: t,
                    wasPlaying: isPlaying || player.rate > 0,
                    duration: player.currentItem?.duration ?? .invalid
                )
            }
        }

        clearBrokenPlayer()

        print("🔔 [FullScreenVideoManager] Reloading fullscreen video after infrastructure restart \(shortMID(request.mid))")
        loadVideo(
            url: request.url,
            mid: request.mid,
            tweetId: request.tweetId,
            cellTweetId: request.cellTweetId,
            videoIndex: request.videoIndex,
            mediaType: request.mediaType
        )
    }

    private func shouldReloadFullscreenPlayerAfterInfrastructureRestart() -> Bool {
        guard let player = singletonPlayer,
              let item = player.currentItem,
              currentVideoMid != nil else {
            return false
        }

        if item.status == .failed || item.error != nil || player.error != nil {
            return true
        }

        let hasLoadedData = item.loadedTimeRanges.contains { value in
            let duration = CMTimeGetSeconds(value.timeRangeValue.duration)
            return duration.isFinite && duration > 0
        }

        if item.status == .readyToPlay,
           !hasLoadedData,
           player.timeControlStatus != .playing {
            return true
        }

        return false
    }

    // No "search function" anymore; the coordinator is canonical.
}

/// Singleton video manager for detail view context
@MainActor
final class DetailVideoManager: NSObject, ObservableObject, VideoPlayerLifecycleManager {
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
    private var feedHandoffMid: String?
    private var feedHandoffExpiresAt: Date = .distantPast
    
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
        registerCoordinatorNotificationObservers()
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
        teardownCoordinatorNotificationObservers()
        startupAudioUnmuteTask?.cancel()
        startupAudioUnmuteTask = nil
        startupAudioMuteUntil = .distantPast
        mainTweetAttachmentMids.removeAll()
        mainTweetAttachments.removeAll()
        mainTweetBaseUrl = nil

        // Cancel the delayed clear from endDetailViewSession() — we're about to clear immediately.
        scheduledClearTask?.cancel()
        scheduledClearTask = nil

        // CRITICAL: Clear the current video player so isDetailViewActive() returns false
        // This allows feed videos to resume playback when returning from detail view
        clearCurrentVideo(preserveSharedFeedPlayback: true)

        print("📱 [DetailVideoManager] Deactivated - lifecycle observers removed, player cleared")
    }

    private func teardownAppLifecycleNotifications() {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
    }

    private func registerCoordinatorNotificationObservers() {
        coordinatorPlayObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("shouldPlayVideo"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let videoMid = notification.userInfo?["videoMid"] as? String,
                  let source = notification.userInfo?["source"] as? String else { return }

            Task { @MainActor [weak self] in
                guard let self,
                      source == "commentsCoordinator",
                      self.mainTweetAttachmentMids.contains(videoMid) else { return }
                if self.currentVideoMid == videoMid,
                   let player = self.currentPlayer,
                   let item = player.currentItem {
                    if self.isPlaybackRendering,
                       (player.timeControlStatus == .playing || player.rate > 0) {
                        print("📱 [DetailVideoManager] Coordinator play ignored (already active): \(videoMid)")
                        return
                    }
                    print("📱 [DetailVideoManager] Coordinator resume: \(videoMid)")
                    self.startDetailPlayback(player: player, item: item, log: "coordinator resume same-video")
                    return
                }
                if let baseUrl = self.mainTweetBaseUrl,
                   let entry = self.mainTweetAttachments.first(where: { $0.mid == videoMid }),
                   let url = entry.getUrl(baseUrl) {
                    print("📱 [DetailVideoManager] Coordinator play: \(videoMid)")
                    self.loadVideo(url: url, mid: videoMid, mediaType: entry.type)
                }
            }
        }

        coordinatorPauseObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("shouldPauseVideo"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let videoMid = notification.userInfo?["videoMid"] as? String else { return }

            Task { @MainActor [weak self] in
                guard let self,
                      self.mainTweetAttachmentMids.contains(videoMid),
                      self.currentVideoMid == videoMid else { return }
                print("📱 [DetailVideoManager] Coordinator pause: \(videoMid)")
                self.pause()
            }
        }
    }

    private func teardownCoordinatorNotificationObservers() {
        if let obs = coordinatorPlayObserver {
            NotificationCenter.default.removeObserver(obs)
            coordinatorPlayObserver = nil
        }
        if let obs = coordinatorPauseObserver {
            NotificationCenter.default.removeObserver(obs)
            coordinatorPauseObserver = nil
        }
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

    // MARK: - DetailView lifecycle coordination
    // When navigating DetailView -> DetailView (quoted -> original), the first view's disappearance
    // must NOT immediately clear the singleton player, otherwise the next DetailView will go black.
    // We solve this by scheduling a delayed clear that gets cancelled when another detail view appears.
    private var activeDetailViewCount: Int = 0
    private var scheduledClearTask: Task<Void, Never>?

    func beginDetailViewSession() {
        activeDetailViewCount += 1
        scheduledClearTask?.cancel()
        scheduledClearTask = nil
    }

    func endDetailViewSession() {
        activeDetailViewCount = max(0, activeDetailViewCount - 1)
        guard activeDetailViewCount == 0 else { return }

        // If detail borrowed the feed player, leaving detail is an ownership transfer.
        // Do not pause the player here; the feed will reattach and resume ownership.
        if let player = currentPlayer,
           let mid = currentVideoMid,
           isSharedFeedPlayer(player, mid: mid) {
            if let item = player.currentItem,
               releaseCachedFeedPlayerForFocusedPlaybackIfNeeded(player, item: item, mid: mid, owner: "detail session end") {
                currentPlayer = nil
                isPlaying = false
                feedHandoffMid = nil
                feedHandoffExpiresAt = .distantPast
            } else {
                player.currentItem?.cancelPendingSeeks()
                markFeedHandoff(mid: mid)
            }
        } else {
            currentPlayer?.pause()
            isPlaying = false
        }

        scheduledClearTask?.cancel()
        scheduledClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            guard self.activeDetailViewCount == 0 else { return }
            self.clearCurrentVideo(preserveSharedFeedPlayback: true)
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
        if let player = currentPlayer,
           let videoMid = currentVideoMid {
            preserveDetailFrameToCache(player: player, mediaID: videoMid)
            SharedAssetCache.shared.protectBackgroundPoster(for: videoMid)
        }
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        detailLoadedTimeRangesObserver?.invalidate()
        detailLoadedTimeRangesObserver = nil
        removeDetailRenderingObservers()
        detailLoadTask?.cancel()
        detailLoadTask = nil
        detailStartupRecoveryTask?.cancel()
        detailStartupRecoveryTask = nil
        detailStartupRecoveryItem = nil
        detailStartupRecoveryAttemptCount = 0
        detailStartupUnknownAttemptCount = 0
        if hasKVOObserver, let playerItem = currentPlayer?.currentItem {
            playerItem.removeObserver(self, forKeyPath: "status")
            hasKVOObserver = false
        }
        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
        currentPlayer?.pause()
        currentPlayer?.replaceCurrentItem(with: nil)
        currentPlayer = nil
        currentVideoMid = nil
        isPlaying = false
        isBuffering = false
        isPlaybackRendering = false
        didFinishPlayback = false
        isItemReady = false
        hasBufferedData = false
        hasCachedMediaContent = false
        hasPlayableMediaContent = false
        loadFailedVideoMid = nil
        detailStallItemRebuildCount = 0
        pendingFeedResumeTime = nil
        activeFeedHandoffTime = nil
    }
    
    @Published var currentPlayer: AVPlayer?
    @Published var currentVideoMid: String?
    @Published var isPlaying = false
    @Published var isBuffering = false
    @Published private(set) var hasPlayableMediaContent = false
    @Published private(set) var isPlaybackRendering = false
    @Published private(set) var didFinishPlayback = false
    private var hasBufferedData = false
    private var hasCachedMediaContent = false

    // MARK: - Attachment Video Tracking (coordinator-driven autoplay)
    /// Mids of the main tweet's video attachments — coordinator play/pause notifications are
    /// filtered to only these mids so comment video notifications are ignored.
    private var mainTweetAttachmentMids: Set<String> = []
    private var mainTweetAttachments: [MimeiFileType] = []
    private var mainTweetBaseUrl: URL? = nil
    private var coordinatorPlayObserver: NSObjectProtocol?
    private var coordinatorPauseObserver: NSObjectProtocol?

    /// Register the main tweet's video attachments so coordinator notifications can drive playback.
    /// Call this before activateForDetail() or immediately after.
    @MainActor
    func setMainTweetAttachments(_ attachments: [MimeiFileType], baseUrl: URL?) {
        mainTweetAttachments = attachments
        mainTweetBaseUrl = baseUrl
        mainTweetAttachmentMids = Set(
            attachments
                .filter { $0.type == .video || $0.type == .hls_video }
                .map { $0.mid }
        )
        print("📱 [DetailVideoManager] Registered \(mainTweetAttachmentMids.count) attachment video mid(s)")
    }

    private var loadGeneration: Int = 0
    @Published private(set) var isItemReady = false
    @Published private(set) var loadFailedVideoMid: String?
    private var detailLoadTask: Task<Void, Never>?
    private var itemStatusObserver: NSKeyValueObservation?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var detailLoadedTimeRangesObserver: NSKeyValueObservation?
    private var detailPlaybackProgressObserver: Any?
    private weak var detailPlaybackProgressPlayer: AVPlayer?
    private var detailVideoOutput: AVPlayerItemVideoOutput?
    private weak var detailVideoOutputItem: AVPlayerItem?
    private weak var detailStartupRecoveryItem: AVPlayerItem?
    private var detailPlaybackStartSeconds: Double = 0
    private var detailStartupRecoveryTask: Task<Void, Never>?
    private var detailStartupRecoveryAttemptCount = 0
    private var detailStartupUnknownAttemptCount = 0
    private var detailStallItemRebuildCount = 0
    private let detailStartupRecoveryDelay: UInt64 = 1_500_000_000
    private let detailStartupRecoveryMaxAttempts = 4
    private let detailStartupUnknownMaxAttempts = 12
    private var pendingFeedResumeTime: CMTime?
    private var activeFeedHandoffTime: CMTime?
    private var isUsingBorrowedFeedPlayer = false
    private var isSeekingToStartupPosition = false
    private var startupAudioMuteUntil: Date = .distantPast
    private var startupAudioUnmuteTask: Task<Void, Never>?

    private struct DetailRecoveryRequest {
        let url: URL
        let mid: String
        let mediaType: MediaType
    }

    private var lastRequestedDetailVideo: DetailRecoveryRequest?

    private func shortMID(_ mid: String?) -> String {
        guard let mid else { return "nil" }
        return mid.count > 8 ? String(mid.prefix(8)) : mid
    }

    @MainActor
    private func refreshDetailCachedMediaContent(for mid: String?) {
        guard let mid else {
            hasCachedMediaContent = false
            hasPlayableMediaContent = hasBufferedData || isPlaybackRendering
            return
        }

        hasCachedMediaContent = SharedAssetCache.shared.hasCachedContent(for: mid)
        hasPlayableMediaContent = hasBufferedData || isPlaybackRendering
    }

    private func detailDiagnostic(_ player: AVPlayer?, item: AVPlayerItem?) -> String {
        let player = player ?? currentPlayer
        let item = item ?? player?.currentItem
        let pos = player.map { CMTimeGetSeconds($0.currentTime()) } ?? 0
        let dur = item.map { CMTimeGetSeconds($0.duration) } ?? 0
        let buffered = {
            guard let player, let item else { return 0.0 }
            return bufferedTimeAhead(for: item, player: player)
        }()
        let ranges = item?.loadedTimeRanges.map { value in
            let range = value.timeRangeValue
            return "\(String(format: "%.1f", CMTimeGetSeconds(range.start)))-\(String(format: "%.1f", CMTimeGetSeconds(range.end)))"
        }.joined(separator: ",") ?? "none"
        let reason = player?.reasonForWaitingToPlay?.rawValue ?? "nil"
        let status = item?.status.rawValue ?? -1
        let timeControl = player?.timeControlStatus.rawValue ?? -1
        let keepUp = item?.isPlaybackLikelyToKeepUp ?? false
        let empty = item?.isPlaybackBufferEmpty ?? true
        return "pos=\(String(format: "%.2f", pos)), dur=\(String(format: "%.2f", dur)), buffered=\(String(format: "%.2f", buffered)), itemStatus=\(status), timeControl=\(timeControl), reason=\(reason), keepUp=\(keepUp), empty=\(empty), ranges=[\(ranges)]"
    }

    /// Check if detail view is currently active (safe for Sendable contexts)
    @MainActor
    func isDetailViewActive() -> Bool {
        return currentPlayer != nil
    }

    private var videoCompletionObserver: NSObjectProtocol?
    private var hasKVOObserver = false // Track if KVO observer was added

    private func isSharedFeedPlayer(_ player: AVPlayer, mid: String) -> Bool {
        SharedAssetCache.shared.getCachedPlayer(for: mid) === player
    }

    private func markFeedHandoff(mid: String, player: AVPlayer? = nil) {
        feedHandoffMid = mid
        feedHandoffExpiresAt = Date().addingTimeInterval(2.0)
        if let player = player ?? currentPlayer {
            VideoSurfaceHandoffRegistry.shared.beginTransfer(
                mediaID: mid,
                player: player,
                source: "detail"
            )
        }
    }

    func isTransferringPlayerToFeed(_ player: AVPlayer, mid: String) -> Bool {
        if VideoSurfaceHandoffRegistry.shared.isActiveTransfer(mediaID: mid, player: player) {
            return true
        }
        guard isSharedFeedPlayer(player, mid: mid),
              feedHandoffMid == mid,
              Date() <= feedHandoffExpiresAt else {
            return false
        }
        return true
    }
    
    /// Setup audio interruption notifications to handle incoming calls
    private func setupAudioInterruptionNotifications() {
        AudioSessionManager.shared.setupInterruptionNotifications()
    }
    
    // MARK: - Singleton Video Loading (like FullScreenVideoManager)

    /// Load and play a video in the detail view's singleton player.
    /// Only ONE video plays at a time — the selected page in the detail TabView.
    func loadVideo(url: URL, mid: String, mediaType: MediaType) {
        print("📱 [DetailVideoManager] loadVideo start \(shortMID(mid)): mediaType=\(mediaType), current=\(shortMID(currentVideoMid)), hasItem=\(currentPlayer?.currentItem != nil)")
        lastRequestedDetailVideo = DetailRecoveryRequest(url: url, mid: mid, mediaType: mediaType)
        Task { @MainActor [weak self] in
            guard let self,
                  self.currentVideoMid == mid || self.lastRequestedDetailVideo?.mid == mid else { return }
            self.refreshDetailCachedMediaContent(for: mid)
        }

        // Fast path: same video already loaded and healthy
        if currentVideoMid == mid, currentPlayer?.currentItem != nil, !isPlayerBroken() {
            print("📱 [DetailVideoManager] Reusing existing player \(shortMID(mid)): \(detailDiagnostic(currentPlayer, item: currentPlayer?.currentItem))")
            if isSeekingToStartupPosition {
                return
            }
            loadFailedVideoMid = nil
            applyStartupAudioMuteIfNeeded()
            if let player = currentPlayer,
               let item = player.currentItem,
               item.status == .readyToPlay {
                isItemReady = true
                if didFinishPlayback {
                    isPlaying = false
                    isBuffering = false
                    isPlaybackRendering = false
                    return
                }
                didFinishPlayback = false
                updateDetailBufferedData(for: item)
                isBuffering = shouldKeepDetailBuffering(player: player, item: item)
                isPlaying = true

                if !isUsingBorrowedFeedPlayer,
                   let pendingFeedResumeTime,
                   !isNear(player.currentTime(), pendingFeedResumeTime, tolerance: 0.35),
                   seekPendingFeedResumeIfNeeded(playerItem: item, mid: mid, log: "same-video feed handoff") {
                    return
                }
                pendingFeedResumeTime = nil

                if player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate || player.rate > 0 {
                    isBuffering = shouldKeepDetailBuffering(player: player, item: item)
                    return
                }

                // Rewind if at end, then play
                if item.duration.isValid && item.duration.seconds > 0,
                   (item.duration.seconds - item.currentTime().seconds) < 0.5 {
                    currentPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
                        Task { @MainActor [weak self, weak player] in
                            self?.startDetailPlayback(player: player, item: item, log: "same-video rewind")
                        }
                    }
                } else {
                    startDetailPlayback(player: currentPlayer, item: item, log: "same-video resume")
                }
            } else {
                isPlaying = true // intent — KVO will play when ready
            }
            return
        }

        // Detail is the active video target. Clear stale proxy cancellation from
        // feed scrolling and give this media primary priority without borrowing
        // the feed's live AVPlayer.
        LocalHTTPServer.shared.clearCancelledState(for: mid)
        LocalHTTPServer.shared.setPrimaryMediaID(mid)
        SharedAssetCache.shared.suspendFeedActivityForFocusedPlayback(protecting: mid, owner: "detail")

        // Save old video position before switching
        if let player = currentPlayer,
           let oldMid = currentVideoMid,
           player.currentItem != nil,
           oldMid != mid {
            let t = player.currentTime()
            if t.isValid && t.seconds.isFinite && t.seconds > 0.25 {
                let d = player.currentItem?.duration ?? .invalid
                PersistentVideoStateManager.shared.saveState(
                    videoMid: oldMid, currentTime: t,
                    wasPlaying: player.rate > 0, context: .detailView, duration: d)
            }
            player.pause()
            currentPlayer = nil
        }

        // Bump generation to ignore stale async completions
        if detailLoadTask != nil, let oldLoadingMid = currentVideoMid {
            SharedAssetCache.shared.cancelTransientLoading(for: oldLoadingMid)
        }
        detailLoadTask?.cancel()
        detailLoadTask = nil
        loadGeneration += 1
        let generation = loadGeneration
        isItemReady = false
        isBuffering = true
        isPlaybackRendering = false
        didFinishPlayback = false
        isSeekingToStartupPosition = false
        isUsingBorrowedFeedPlayer = false
        loadFailedVideoMid = nil

        // Clean up old observers
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        detailLoadedTimeRangesObserver?.invalidate()
        detailLoadedTimeRangesObserver = nil
        removeDetailRenderingObservers()
        detailStartupRecoveryTask?.cancel()
        detailStartupRecoveryTask = nil
        detailStartupRecoveryItem = nil
        detailStartupRecoveryAttemptCount = 0
        detailStartupUnknownAttemptCount = 0
        detailStallItemRebuildCount = 0
        if let obs = videoCompletionObserver {
            NotificationCenter.default.removeObserver(obs)
            videoCompletionObserver = nil
        }
        if hasKVOObserver, let pi = currentPlayer?.currentItem {
            pi.removeObserver(self, forKeyPath: "status")
            hasKVOObserver = false
        }

        currentVideoMid = mid
        pendingFeedResumeTime = nil
        activeFeedHandoffTime = nil

        // Borrow the canonical feed player when available. This keeps one AVPlayer
        // moving across feed/detail/fullscreen instead of restarting decode/buffer
        // state on every surface switch.
        if borrowCachedFeedPlayerIfAvailable(mid: mid) {
            return
        }

        pendingFeedResumeTime = activeFeedHandoffTime(for: mid)
        activeFeedHandoffTime = pendingFeedResumeTime
        if let pendingFeedResumeTime {
            print("📱 [DetailVideoManager] Pending cold-player handoff \(shortMID(mid)): \(String(format: "%.2f", pendingFeedResumeTime.seconds))s")
        }

        SharedAssetCache.shared.prepareUncachedFocusedLoad(for: mid, owner: "detail")
        print("📱 [DetailVideoManager] Async asset load start \(shortMID(mid)): url=\(url.absoluteString)")
        detailLoadTask = Task.detached(priority: .userInitiated) {
            do {
                let sharedPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(for: url, mediaID: mid, tweetId: mid, mediaType: mediaType)
                guard !Task.isCancelled else {
                    await MainActor.run {
                        if self.currentVideoMid != mid, self.currentPlayer !== sharedPlayer {
                            sharedPlayer.pause()
                            sharedPlayer.replaceCurrentItem(with: nil)
                        }
                    }
                    return
                }
                await MainActor.run {
                    guard self.loadGeneration == generation, self.currentVideoMid == mid else {
                        if self.currentVideoMid != mid, self.currentPlayer !== sharedPlayer {
                            sharedPlayer.pause()
                            sharedPlayer.replaceCurrentItem(with: nil)
                        }
                        return
                    }
                    self.detailLoadTask = nil
                    guard let playerItem = sharedPlayer.currentItem else {
                        self.isBuffering = false
                        self.isPlaying = false
                        self.isPlaybackRendering = false
                        return
                    }
                    print("📱 [DetailVideoManager] Shared player available \(self.shortMID(mid)): itemStatus=\(playerItem.status.rawValue)")
                    playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
                    AudioSessionManager.shared.activateForVideoPlayback()
                    self.currentPlayer = sharedPlayer
                    self.refreshDetailCachedMediaContent(for: mid)
                    self.resetDetailRenderingProgress(to: self.currentPlayer?.currentTime() ?? .zero)
                    self.setupDetailVideoOutput(for: playerItem)
                    self.applyStartupAudioMuteIfNeeded()
                    self.setupDetailCompletionObserver(playerItem)
                    self.setupDetailTimeControlObserver()
                    self.startDetailPlayback(playerItem: playerItem, mid: mid)
                }
            } catch {
                if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.detailLoadTask = nil
                    print("❌ [DetailVideoManager] Failed to load video: \(error)")
                    self.failDetailVideoLoad(reason: "async player creation failed: \(error.localizedDescription)", mid: mid, deleteDiskCache: true)
                }
            }
        }
    }

    @discardableResult
    private func borrowCachedFeedPlayerIfAvailable(mid: String) -> Bool {
        var candidates: [(player: AVPlayer, source: String)] = []

        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            candidates.append((cachedState.player, "VideoStateCache"))
        }

        if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: mid),
           !candidates.contains(where: { $0.player === cachedPlayer }) {
            candidates.append((cachedPlayer, "SharedAssetCache"))
        }

        for candidate in candidates {
            guard let cachedItem = candidate.player.currentItem else { continue }

            if releaseCachedFeedPlayerForFocusedPlaybackIfNeeded(candidate.player, item: cachedItem, mid: mid, owner: "detail borrow from \(candidate.source)") {
                pendingFeedResumeTime = nil
                activeFeedHandoffTime = nil
                return false
            }

            if candidate.source == "VideoStateCache" {
                SharedAssetCache.shared.cachePlayer(candidate.player, for: mid)
            }

            print("📱 [DetailVideoManager] Borrowing \(candidate.source) feed player \(shortMID(mid)): cached=\(detailDiagnostic(candidate.player, item: cachedItem))")
            cachedItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            AudioSessionManager.shared.activateForVideoPlayback()
            currentPlayer = candidate.player
            isUsingBorrowedFeedPlayer = true
            isItemReady = cachedItem.status == .readyToPlay
            isPlaybackRendering = false
            isPlaying = true
            Task { @MainActor [weak self] in
                guard let self, self.currentVideoMid == mid else { return }
                self.refreshDetailCachedMediaContent(for: mid)
            }
            updateDetailBufferedData(for: cachedItem)
            isBuffering = shouldKeepDetailBuffering(player: candidate.player, item: cachedItem)
            pendingFeedResumeTime = nil
            activeFeedHandoffTime = nil
            if isVideoAtEnd(candidate.player) {
                // A feed player can be handed to detail while it is within the
                // finish threshold. Pause before installing completion observers
                // so detail gets a controlled rewind instead of an immediate
                // finish event followed by a spinner-only resume.
                candidate.player.pause()
            }
            resetDetailRenderingProgress(to: currentPlayer?.currentTime() ?? .zero)
            setupDetailVideoOutput(for: cachedItem)
            applyStartupAudioMuteIfNeeded()
            setupDetailCompletionObserver(cachedItem)
            setupDetailTimeControlObserver()
            startDetailPlayback(playerItem: cachedItem, mid: mid)
            return true
        }

        return false
    }
    
    func setStartupAudioMuteWindow(duration: TimeInterval) {
        let safeDuration = max(0, duration)
        startupAudioMuteUntil = Date().addingTimeInterval(safeDuration)
        applyStartupAudioMuteIfNeeded()
    }

    private func applyStartupAudioMuteIfNeeded() {
        guard let player = currentPlayer else { return }
        let now = Date()
        if now < startupAudioMuteUntil {
            player.isMuted = true
            startupAudioUnmuteTask?.cancel()
            let delay = startupAudioMuteUntil.timeIntervalSince(now)
            let nanos = UInt64(max(0, delay) * 1_000_000_000)
            startupAudioUnmuteTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: nanos)
                guard Date() >= self.startupAudioMuteUntil else { return }
                self.currentPlayer?.isMuted = false
            }
        } else {
            player.isMuted = false
        }
    }

    /// Pause the current video (e.g. when swiping away)
    func pause() {
        currentPlayer?.pause()
        isPlaying = false
        isPlaybackRendering = false
    }

    private func startDetailPlayback(playerItem: AVPlayerItem, mid: String) {
        print("📱 [DetailVideoManager] startDetailPlayback item observer \(shortMID(mid)): \(detailDiagnostic(currentPlayer, item: playerItem))")
        isPlaying = true
        updateDetailBufferedData(for: playerItem)
        if let player = currentPlayer {
            isBuffering = shouldKeepDetailBuffering(player: player, item: playerItem)
        } else {
            isBuffering = !hasBufferedData
        }
        detailLoadedTimeRangesObserver?.invalidate()
        detailLoadedTimeRangesObserver = playerItem.observe(\.loadedTimeRanges, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self,
                      let player = self.currentPlayer,
                      player.currentItem === item else { return }
                self.updateDetailBufferedData(for: item)
                self.isBuffering = self.shouldKeepDetailBuffering(player: player, item: item)
            }
        }
        itemStatusObserver = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                print("📱 [DetailVideoManager] itemStatus \(self.shortMID(mid)): \(self.detailDiagnostic(self.currentPlayer, item: item))")
                guard !self.isItemReady else { return }
                if item.status == .readyToPlay {
                    self.isItemReady = true
                    self.updateDetailBufferedData(for: item)
                    self.isBuffering = self.currentPlayer.map { self.shouldKeepDetailBuffering(player: $0, item: item) } ?? !self.hasBufferedData
                    self.loadFailedVideoMid = nil
                    self.detailStartupUnknownAttemptCount = 0
                    self.itemStatusObserver?.invalidate()
                    self.itemStatusObserver = nil
                    self.seekAndPlay(playerItem: item, mid: mid)
                } else if item.status == .failed {
                    print("❌ [DetailVideoManager] PlayerItem failed: \(item.error?.localizedDescription ?? "unknown")")
                    self.failDetailVideoLoad(reason: "item status failed", mid: mid, deleteDiskCache: true)
                }
            }
        }
        scheduleDetailStartupRecovery(for: playerItem, mid: mid)
    }

    private func activeFeedHandoffTime(for mid: String) -> CMTime? {
        if FullScreenVideoManager.shared.currentVideoMid == mid,
           let currentTime = FullScreenVideoManager.shared.singletonPlayer?.currentTime(),
           currentTime.isValid,
           currentTime.seconds.isFinite,
           currentTime.seconds > 0.25 {
            return currentTime
        }

        if let player = SharedAssetCache.shared.getCachedPlayer(for: mid) {
            if let decodedTime = VideoPlaybackSessionStore.shared.trustedVisibleTime(for: mid, beforeOrAt: player.currentTime()) {
                return decodedTime
            }

            let currentTime = player.currentTime()
            if currentTime.isValid, currentTime.seconds.isFinite, currentTime.seconds > 0.25 {
                return currentTime
            }
        }

        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            let player = cachedState.player
            if let decodedTime = VideoPlaybackSessionStore.shared.trustedVisibleTime(for: mid, beforeOrAt: player.currentTime()) {
                return decodedTime
            }

            let currentTime = player.currentTime()
            if currentTime.isValid, currentTime.seconds.isFinite, currentTime.seconds > 0.25 {
                return currentTime
            }
        }

        return nil
    }

    private func markWaitingForStartupSeek() {
        isSeekingToStartupPosition = true
        if let player = currentPlayer, let item = player.currentItem {
            updateDetailBufferedData(for: item)
            isBuffering = shouldKeepDetailBuffering(player: player, item: item)
        } else {
            isBuffering = !hasBufferedData
        }
        isPlaybackRendering = false
    }

    @discardableResult
    private func seekPendingFeedResumeIfNeeded(playerItem: AVPlayerItem, mid: String, log: String) -> Bool {
        guard !isUsingBorrowedFeedPlayer else {
            pendingFeedResumeTime = nil
            activeFeedHandoffTime = nil
            return false
        }
        guard let feedResumeTime = pendingFeedResumeTime else { return false }
        pendingFeedResumeTime = nil
        activeFeedHandoffTime = feedResumeTime

        let adjustedFeedResumeTime = bufferedLiveHandoffSeekTime(feedResumeTime, item: playerItem)
        let savedSec = adjustedFeedResumeTime.seconds
        guard savedSec.isFinite && savedSec > 0.25 else {
            let originalSec = feedResumeTime.seconds
            if originalSec.isFinite {
                print("📱 [DetailVideoManager] Skipping live handoff \(shortMID(mid)): target=\(String(format: "%.2f", originalSec)) has no buffered seek point")
            }
            activeFeedHandoffTime = nil
            return false
        }

        let duration = playerItem.duration
        if duration.isValid && duration.seconds > 0 && savedSec >= duration.seconds - 0.5 {
            let player = currentPlayer
            markWaitingForStartupSeek()
            print("📱 [DetailVideoManager] Seek live handoff at end \(shortMID(mid)): saved=\(String(format: "%.2f", savedSec))")
            currentPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.currentPlayer === player,
                          player?.currentItem === playerItem,
                          self.currentVideoMid == mid else { return }
                    self.isSeekingToStartupPosition = false
                    self.resetDetailRenderingProgress(to: .zero)
                    self.applyStartupAudioMuteIfNeeded()
                    self.startDetailPlayback(player: player, item: playerItem, log: "\(log) at end")
                    print("▶️ [DetailVideoManager] Continued from live handoff at end - rewound")
                }
            }
            return true
        }

        let player = currentPlayer
        markWaitingForStartupSeek()
        let originalSec = feedResumeTime.seconds
        if originalSec.isFinite, abs(originalSec - savedSec) > 0.05 {
            print("📱 [DetailVideoManager] Seek live handoff \(shortMID(mid)): target=\(String(format: "%.2f", savedSec)) adjusted from \(String(format: "%.2f", originalSec))")
        } else {
            print("📱 [DetailVideoManager] Seek live handoff \(shortMID(mid)): target=\(String(format: "%.2f", savedSec))")
        }
        if let player,
           isNear(player.currentTime(), adjustedFeedResumeTime, tolerance: 0.35) {
            isSeekingToStartupPosition = false
            resetDetailRenderingProgress(to: player.currentTime())
            applyStartupAudioMuteIfNeeded()
            startDetailPlayback(player: player, item: playerItem, log: "\(log) near target")
            print("▶️ [DetailVideoManager] Continued from live handoff near position \(savedSec)s")
            return true
        }

        currentPlayer?.seek(to: adjustedFeedResumeTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self,
                      self.currentPlayer === player,
                      player?.currentItem === playerItem,
                      self.currentVideoMid == mid else { return }
                self.isSeekingToStartupPosition = false
                guard finished else { return }
                self.resetDetailRenderingProgress(to: adjustedFeedResumeTime)
                self.applyStartupAudioMuteIfNeeded()
                self.startDetailPlayback(player: player, item: playerItem, log: log)
                print("▶️ [DetailVideoManager] Continued from live handoff position \(savedSec)s")
            }
        }
        return true
    }

    private func bufferedLiveHandoffSeekTime(_ requestedTime: CMTime, item: AVPlayerItem) -> CMTime {
        let requestedSeconds = seconds(from: requestedTime)
        guard requestedSeconds.isFinite else { return requestedTime }

        let minimumBufferAhead = 1.5
        var bestFallback: Double?
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = seconds(from: range.start)
            let duration = seconds(from: range.duration)
            guard start.isFinite, duration.isFinite, duration > 0 else { continue }

            let end = start + duration
            let safeEnd = max(start, end - minimumBufferAhead)
            if requestedSeconds >= start, requestedSeconds <= end {
                let adjustedSeconds = min(requestedSeconds, safeEnd)
                return CMTime(seconds: adjustedSeconds, preferredTimescale: 600)
            }

            if end < requestedSeconds {
                bestFallback = max(bestFallback ?? start, safeEnd)
            }
        }

        if let bestFallback {
            return CMTime(seconds: bestFallback, preferredTimescale: 600)
        }

        return .zero
    }

    private func shouldResetCachedFeedPlayerForFocusedPlayback(_ player: AVPlayer, item: AVPlayerItem) -> Bool {
        let hasPlayerFailure = item.status == .failed || player.error != nil || item.error != nil
        return hasPlayerFailure
    }

    @discardableResult
    private func releaseCachedFeedPlayerForFocusedPlaybackIfNeeded(_ player: AVPlayer, item: AVPlayerItem, mid: String, owner: String) -> Bool {
        guard shouldResetCachedFeedPlayerForFocusedPlayback(player, item: item) else { return false }

        let deleteDiskCache = item.status == .failed || player.error != nil || item.error != nil
        print("📱 [DetailVideoManager] Releasing broken shared feed player before \(owner) \(shortMID(mid)): deleteDiskCache=\(deleteDiskCache), \(detailDiagnostic(player, item: item))")
        item.cancelPendingSeeks()
        player.pause()
        SharedAssetCache.shared.clearPlayerForMediaID(mid, deleteDiskCache: deleteDiskCache)
        VideoStateCache.shared.clearCachedState(for: mid)
        LocalHTTPServer.shared.clearCancelledState(for: mid)
        return true
    }

    private func failDetailVideoLoad(reason: String, mid: String, deleteDiskCache: Bool) {
        guard currentVideoMid == mid || loadFailedVideoMid == mid else { return }
        print("❌ [DetailVideoManager] \(reason) - releasing detail player \(shortMID(mid)), deleteDiskCache=\(deleteDiskCache)")

        loadGeneration += 1
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        detailLoadedTimeRangesObserver?.invalidate()
        detailLoadedTimeRangesObserver = nil
        removeDetailRenderingObservers()
        detailLoadTask?.cancel()
        detailLoadTask = nil
        detailStartupRecoveryTask?.cancel()
        detailStartupRecoveryTask = nil
        detailStartupRecoveryItem = nil
        detailStartupRecoveryAttemptCount = 0
        detailStartupUnknownAttemptCount = 0
        detailStallItemRebuildCount = 0

        if hasKVOObserver, let playerItem = currentPlayer?.currentItem {
            playerItem.removeObserver(self, forKeyPath: "status")
            hasKVOObserver = false
        }

        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }

        if let player = currentPlayer {
            player.pause()
            player.currentItem?.cancelPendingSeeks()
            player.currentItem?.asset.cancelLoading()
            SharedAssetCache.shared.clearPlayerForMediaID(mid, deleteDiskCache: deleteDiskCache)
            player.replaceCurrentItem(with: nil)
        } else {
            SharedAssetCache.shared.clearPlayerForMediaID(mid, deleteDiskCache: deleteDiskCache)
        }

        VideoStateCache.shared.clearCachedState(for: mid)
        LocalHTTPServer.shared.clearPrimaryRestriction()

        currentPlayer = nil
        currentVideoMid = nil
        isPlaying = false
        isBuffering = false
        isPlaybackRendering = false
        didFinishPlayback = false
        isSeekingToStartupPosition = false
        isUsingBorrowedFeedPlayer = false
        isItemReady = false
        pendingFeedResumeTime = nil
        activeFeedHandoffTime = nil
        feedHandoffMid = nil
        feedHandoffExpiresAt = .distantPast
        loadFailedVideoMid = mid
    }

    private func seekAndPlay(playerItem: AVPlayerItem, mid: String) {
        print("📱 [DetailVideoManager] seekAndPlay \(shortMID(mid)): \(detailDiagnostic(currentPlayer, item: playerItem))")
        let duration = playerItem.duration

        if seekPendingFeedResumeIfNeeded(playerItem: playerItem, mid: mid, log: "continued from live handoff") {
            return
        }

        if isUsingBorrowedFeedPlayer {
            if duration.isValid && duration.seconds > 0 {
                let remaining = duration.seconds - playerItem.currentTime().seconds
                if remaining <= 0.5 {
                    let player = currentPlayer
                    markWaitingForStartupSeek()
                    print("📱 [DetailVideoManager] Seek borrowed feed player at end \(shortMID(mid)): remaining=\(String(format: "%.2f", remaining))")
                    currentPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.isSeekingToStartupPosition = false
                            self?.applyStartupAudioMuteIfNeeded()
                            self?.startDetailPlayback(player: player, item: playerItem, log: "borrowed feed player at end")
                            print("▶️ [DetailVideoManager] Playing borrowed feed player from beginning")
                        }
                    }
                    return
                }
            }
            applyStartupAudioMuteIfNeeded()
            startDetailPlayback(player: currentPlayer, item: playerItem, log: "borrowed feed player")
            print("▶️ [DetailVideoManager] Playing borrowed feed player without seek")
            return
        }

        // Check PersistentVideoStateManager for saved position
        if PersistentVideoStateManager.shared.shouldRestorePlayback(videoMid: mid, context: .detailView),
           let saved = PersistentVideoStateManager.shared.getState(videoMid: mid, context: .detailView) {
            let savedSec = saved.currentTime.seconds
            if savedSec.isFinite && savedSec > 0.25 {
                // If near end, restart from beginning
                if duration.isValid && duration.seconds > 0 && savedSec >= duration.seconds - 0.5 {
                    let player = currentPlayer
                    markWaitingForStartupSeek()
                    print("📱 [DetailVideoManager] Seek saved position at end \(shortMID(mid)): saved=\(String(format: "%.2f", savedSec))")
                    currentPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.isSeekingToStartupPosition = false
                            self?.applyStartupAudioMuteIfNeeded()
                            self?.startDetailPlayback(player: player, item: playerItem, log: "saved position at end")
                            print("▶️ [DetailVideoManager] Playing from beginning (was at end)")
                        }
                    }
                    return
                }
                let adjustedSavedTime = bufferedLiveHandoffSeekTime(saved.currentTime, item: playerItem)
                let adjustedSavedSec = adjustedSavedTime.seconds
                if !(adjustedSavedSec.isFinite && adjustedSavedSec > 0.25) {
                    print("📱 [DetailVideoManager] Skipping saved position \(shortMID(mid)): target=\(String(format: "%.2f", savedSec)) has no buffered seek point")
                } else {
                    let player = currentPlayer
                    markWaitingForStartupSeek()
                    if abs(adjustedSavedSec - savedSec) > 0.05 {
                        print("📱 [DetailVideoManager] Seek saved position \(shortMID(mid)): target=\(String(format: "%.2f", adjustedSavedSec)) adjusted from \(String(format: "%.2f", savedSec))")
                    } else {
                        print("📱 [DetailVideoManager] Seek saved position \(shortMID(mid)): target=\(String(format: "%.2f", savedSec))")
                    }
                    currentPlayer?.seek(to: adjustedSavedTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                        Task { @MainActor [weak self] in
                            self?.isSeekingToStartupPosition = false
                            guard finished else { return }
                            self?.applyStartupAudioMuteIfNeeded()
                            self?.startDetailPlayback(player: player, item: playerItem, log: "saved position")
                            print("▶️ [DetailVideoManager] Playing from saved position \(adjustedSavedSec)s")
                        }
                    }
                    return
                }
            }
        }
        // At/near end → rewind
        if duration.isValid && duration.seconds > 0 {
            let remaining = duration.seconds - playerItem.currentTime().seconds
            if remaining <= 0.5 {
                let player = currentPlayer
                markWaitingForStartupSeek()
                print("📱 [DetailVideoManager] Seek rewind \(shortMID(mid)): remaining=\(String(format: "%.2f", remaining))")
                currentPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.isSeekingToStartupPosition = false
                        self?.applyStartupAudioMuteIfNeeded()
                        self?.startDetailPlayback(player: player, item: playerItem, log: "rewind")
                        print("▶️ [DetailVideoManager] Playing from beginning (rewind)")
                    }
                }
                return
            }
        }
        applyStartupAudioMuteIfNeeded()
        startDetailPlayback(player: currentPlayer, item: playerItem, log: "immediate")
        print("▶️ [DetailVideoManager] Playing immediately")
    }

    private func setupDetailCompletionObserver(_ playerItem: AVPlayerItem) {
        if let obs = videoCompletionObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        videoCompletionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      let player = self.currentPlayer,
                      player.currentItem === playerItem else { return }
                let finishedMid = self.currentVideoMid
                self.isPlaying = false
                self.isBuffering = false
                self.isPlaybackRendering = false
                self.didFinishPlayback = true
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player, weak playerItem] finished in
                    Task { @MainActor [weak self, weak player, weak playerItem] in
                        guard let self,
                              let player,
                              let playerItem,
                              self.currentPlayer === player,
                              player.currentItem === playerItem else { return }
                        if finished {
                            self.resetDetailRenderingProgress(to: .zero)
                            self.isBuffering = false
                        }
                    }
                }
                print("🏁 [DetailVideoManager] Video finished for \(finishedMid ?? "?") - rewinding")
            }
        }
    }

    private func setupDetailTimeControlObserver() {
        timeControlStatusObserver?.invalidate()
        guard let player = currentPlayer else { return }
        if let item = player.currentItem {
            setupDetailVideoOutput(for: item)
            startDetailRenderingObserver(player: player, item: item)
            _ = markDetailRenderingIfDecoded(player: player, item: item)
            updateDetailBufferedData(for: item)
        }
        isBuffering = shouldKeepDetailBuffering(player: player, item: player.currentItem)
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.currentPlayer === player,
                      self.currentVideoMid != nil,
                      player.currentItem != nil else { return }
                print("📱 [DetailVideoManager] timeControl \(self.shortMID(self.currentVideoMid)): \(self.detailDiagnostic(player, item: player.currentItem))")
                let isWaiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                let isPlayingNow = player.timeControlStatus == .playing
                if let item = player.currentItem {
                    self.setupDetailVideoOutput(for: item)
                    self.startDetailRenderingObserver(player: player, item: item)
                    _ = self.markDetailRenderingIfDecoded(player: player, item: item)
                    self.updateDetailBufferedData(for: item)
                }
                let isBufferEdge = player.currentItem.map { self.isPlaybackAtBufferEdge(player: player, item: $0) } ?? false
                self.isBuffering = self.shouldKeepDetailBuffering(player: player, item: player.currentItem)
                if !self.isUsingBorrowedFeedPlayer,
                   isWaiting,
                   let item = player.currentItem {
                    self.scheduleDetailStartupRecovery(for: item, mid: self.currentVideoMid)
                }
                if isPlayingNow {
                    self.isSeekingToStartupPosition = false
                    self.isItemReady = true
                    if self.isPlaybackRendering {
                        if isBufferEdge {
                            self.isBuffering = self.shouldKeepDetailBuffering(player: player, item: player.currentItem)
                            if !self.isUsingBorrowedFeedPlayer,
                               let item = player.currentItem {
                                self.scheduleDetailStartupRecovery(for: item, mid: self.currentVideoMid)
                            }
                        } else {
                            self.isBuffering = false
                            self.detailStartupRecoveryTask?.cancel()
                            self.detailStartupRecoveryTask = nil
                            self.detailStartupRecoveryItem = nil
                        }
                    } else if !self.isUsingBorrowedFeedPlayer,
                              let item = player.currentItem {
                        self.scheduleDetailStartupRecovery(for: item, mid: self.currentVideoMid)
                    }
                }
                if player.timeControlStatus == .playing && !player.automaticallyWaitsToMinimizeStalling {
                    player.automaticallyWaitsToMinimizeStalling = true
                }
            }
        }
    }

    private func startDetailPlayback(player: AVPlayer?, item: AVPlayerItem, log: String) {
        guard let player else { return }
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        setupDetailVideoOutput(for: item)
        startDetailRenderingObserver(player: player, item: item)
        resetDetailRenderingProgress(to: player.currentTime())
        let bufferPolicy = applyFeedStylePrePlayBuffering(to: player, item: item)
        print("📱 [DetailVideoManager] play(\(log)) \(shortMID(currentVideoMid)): autoWait=\(player.automaticallyWaitsToMinimizeStalling), buffered=\(String(format: "%.2f", bufferPolicy.bufferedAhead)), required=\(String(format: "%.2f", bufferPolicy.requiredBuffer)), keepUp=\(bufferPolicy.keepUp), \(detailDiagnostic(player, item: item))")
        player.play()
        isPlaying = true
        didFinishPlayback = false
        isBuffering = shouldKeepDetailBuffering(player: player, item: item)
        if item.status == .readyToPlay {
            isItemReady = true
        }
        if !isUsingBorrowedFeedPlayer {
            scheduleDetailStartupRecovery(for: item, mid: currentVideoMid)
        }
    }

    private func shouldKeepDetailBuffering(player: AVPlayer, item: AVPlayerItem?) -> Bool {
        guard !isVideoAtEnd(player) else { return false }
        guard let item else { return true }

        updateDetailBufferedData(for: item)
        if isSeekingToStartupPosition { return true }
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { return true }
        if isPlaying && player.timeControlStatus != .playing { return true }
        if !isPlaybackRendering { return true }
        if isPlaybackAtBufferEdge(player: player, item: item) { return true }
        return false
    }

    private func updateDetailBufferedData(for item: AVPlayerItem?) {
        guard let item else {
            hasBufferedData = false
            hasPlayableMediaContent = isPlaybackRendering
            return
        }
        hasBufferedData = item.loadedTimeRanges.contains { value in
            let duration = CMTimeGetSeconds(value.timeRangeValue.duration)
            return duration.isFinite && duration > 0
        }
        hasPlayableMediaContent = hasBufferedData || isPlaybackRendering
    }

    private func isPlaybackAtBufferEdge(player: AVPlayer, item: AVPlayerItem) -> Bool {
        guard item.status == .readyToPlay,
              !isVideoAtEnd(player) else { return false }

        let bufferedAhead = bufferedTimeAhead(for: item, player: player)
        return bufferedAhead < 0.35 || (item.isPlaybackBufferEmpty && bufferedAhead < 1.0)
    }

    @discardableResult
    private func rebuildDetailItemAfterStall(player: AVPlayer, item: AVPlayerItem, mid: String?, reason: String) -> Bool {
        guard currentPlayer === player,
              player.currentItem === item,
              currentVideoMid == mid,
              detailStallItemRebuildCount < 1 else { return false }

        if item is CachingPlayerItem {
            if let mid {
                LocalHTTPServer.shared.clearCancelledState(for: mid)
                LocalHTTPServer.shared.setPrimaryMediaID(mid)
            }
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            item.preferredForwardBufferDuration = 0
            player.automaticallyWaitsToMinimizeStalling = true
            player.play()
            updateDetailBufferedData(for: item)
            isBuffering = shouldKeepDetailBuffering(player: player, item: item)
            detailStartupRecoveryTask = nil
            detailStartupRecoveryItem = nil
            detailStartupRecoveryAttemptCount = 0
            detailStartupUnknownAttemptCount = 0
            print("📱 [DetailVideoManager] preserving caching-backed detail item during recovery \(shortMID(mid)) (\(reason)): \(detailDiagnostic(player, item: item))")
            return true
        }

        detailStallItemRebuildCount += 1
        let currentTime = player.currentTime()
        let visibleResumeTime = mid.flatMap {
            VideoPlaybackSessionStore.shared.trustedVisibleTime(for: $0, beforeOrAt: currentTime)
        }
        let durableHandoffTime = activeFeedHandoffTime ?? pendingFeedResumeTime
        let resumeTime = visibleResumeTime ?? durableHandoffTime ?? (currentTime.isValid && currentTime.seconds.isFinite && currentTime.seconds > 0.25 ? currentTime : .invalid)
        let duration = item.duration
        if let mid,
           resumeTime.isValid,
           resumeTime.seconds.isFinite,
           resumeTime.seconds > 0.25 {
            pendingFeedResumeTime = resumeTime
            PersistentVideoStateManager.shared.saveState(
                videoMid: mid,
                currentTime: resumeTime,
                wasPlaying: true,
                context: .detailView,
                duration: duration
            )
        }

        let resumeDescription = resumeTime.isValid ? String(format: "%.2f", resumeTime.seconds) : "nil"
        print("📱 [DetailVideoManager] rebuilding stalled detail item \(shortMID(mid)) (\(reason)): resume=\(resumeDescription), \(detailDiagnostic(player, item: item))")
        if let mid {
            LocalHTTPServer.shared.clearCancelledState(for: mid)
            LocalHTTPServer.shared.setPrimaryMediaID(mid)
        }

        let replacementItem = AVPlayerItem(asset: item.asset)
        replacementItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true

        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        detailLoadedTimeRangesObserver?.invalidate()
        detailLoadedTimeRangesObserver = nil
        removeDetailRenderingObservers()
        detailLoadTask?.cancel()
        detailLoadTask = nil
        detailStartupRecoveryTask?.cancel()
        detailStartupRecoveryTask = nil
        detailStartupRecoveryItem = nil
        detailStartupRecoveryAttemptCount = 0
        detailStartupUnknownAttemptCount = 0

        player.pause()
        player.replaceCurrentItem(with: replacementItem)
        if let mid {
            NotificationCenter.default.post(
                name: .videoPlayerItemReplaced,
                object: nil,
                userInfo: ["mediaID": mid]
            )
        }
        resetDetailRenderingProgress(to: .zero)
        isPlaying = true
        updateDetailBufferedData(for: replacementItem)
        isBuffering = shouldKeepDetailBuffering(player: player, item: replacementItem)
        isItemReady = false
        isPlaybackRendering = false
        loadFailedVideoMid = nil

        applyStartupAudioMuteIfNeeded()
        setupDetailCompletionObserver(replacementItem)
        setupDetailTimeControlObserver()
        if let mid {
            startDetailPlayback(playerItem: replacementItem, mid: mid)
        } else {
            startDetailPlayback(player: player, item: replacementItem, log: "rebuilt after stall")
        }
        return true
    }

    private func scheduleDetailStartupRecovery(for item: AVPlayerItem, mid: String?) {
        guard !isUsingBorrowedFeedPlayer else { return }
        guard let mid,
              currentVideoMid == mid,
              currentPlayer?.currentItem === item else { return }
        if detailStartupRecoveryTask != nil,
           detailStartupRecoveryItem === item {
            return
        }

        detailStartupRecoveryTask?.cancel()
        detailStartupRecoveryItem = item
        print("📱 [DetailVideoManager] recovery scheduled \(shortMID(mid)): \(detailDiagnostic(currentPlayer, item: item))")
        let recoveryDelay = detailStartupRecoveryDelay
        detailStartupRecoveryTask = Task { @MainActor [weak self, weak item] in
            try? await Task.sleep(nanoseconds: recoveryDelay)
            guard let self,
                  let item,
                  let player = self.currentPlayer,
                  self.currentPlayer?.currentItem === item,
                  self.currentVideoMid == mid,
                  self.isPlaying,
                  !self.isVideoAtEnd(player) else {
                self?.detailStartupRecoveryTask = nil
                self?.detailStartupRecoveryItem = nil
                return
            }

            if item.status == .readyToPlay {
                self.isItemReady = true
                self.detailStartupUnknownAttemptCount = 0
                self.isBuffering = self.currentPlayer?.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
            print("📱 [DetailVideoManager] recovery check \(self.shortMID(mid)): \(self.detailDiagnostic(player, item: item))")

            if self.markDetailRenderingIfDecoded(player: player, item: item) {
                self.isItemReady = true
                self.detailStartupRecoveryAttemptCount = 0
                self.detailStartupUnknownAttemptCount = 0
                self.detailStartupRecoveryTask = nil
                self.detailStartupRecoveryItem = nil
                return
            }

            if item.status == .failed {
                self.failDetailVideoLoad(reason: "recovery observed item status failed", mid: mid, deleteDiskCache: true)
                return
            }

            if item.status == .unknown {
                self.detailStartupUnknownAttemptCount += 1
                self.updateDetailBufferedData(for: item)
                self.isBuffering = self.shouldKeepDetailBuffering(player: player, item: item)
                player.play()

                guard self.detailStartupUnknownAttemptCount < self.detailStartupUnknownMaxAttempts else {
                    print("📱 [DetailVideoManager] recovery startup timeout \(self.shortMID(mid)): unknownAttempts=\(self.detailStartupUnknownAttemptCount), \(self.detailDiagnostic(player, item: item))")
                    self.failDetailVideoLoad(reason: "startup timed out while item status stayed unknown", mid: mid, deleteDiskCache: false)
                    return
                }

                self.detailStartupRecoveryTask = nil
                self.detailStartupRecoveryItem = nil
                print("📱 [DetailVideoManager] recovery waiting for item readiness \(self.shortMID(mid)): unknownAttempts=\(self.detailStartupUnknownAttemptCount), \(self.detailDiagnostic(player, item: item))")
                self.scheduleDetailStartupRecovery(for: item, mid: mid)
                return
            }

            self.detailStartupRecoveryAttemptCount += 1
            let bufferedAhead = self.bufferedTimeAhead(for: item, player: player)
            let keepUp = item.isPlaybackLikelyToKeepUp
            let requiredBuffer = feedStyleRequiredBufferAhead(for: item, player: player)
            guard bufferedAhead >= requiredBuffer else {
                guard self.detailStartupRecoveryAttemptCount < self.detailStartupRecoveryMaxAttempts else {
                    if self.rebuildDetailItemAfterStall(player: player, item: item, mid: mid, reason: "no buffer after recovery attempts") {
                        return
                    }
                    print("📱 [DetailVideoManager] recovery gave up \(self.shortMID(mid)): attempts=\(self.detailStartupRecoveryAttemptCount), \(self.detailDiagnostic(player, item: item))")
                    self.failDetailVideoLoad(reason: "recovery gave up with no buffer", mid: mid, deleteDiskCache: false)
                    return
                }
                self.updateDetailBufferedData(for: item)
                self.isBuffering = self.shouldKeepDetailBuffering(player: player, item: item)
                self.detailStartupRecoveryTask = nil
                self.detailStartupRecoveryItem = nil
                print("📱 [DetailVideoManager] recovery waiting for buffer \(self.shortMID(mid)): buffered=\(String(format: "%.2f", bufferedAhead)), required=\(String(format: "%.2f", requiredBuffer)), keepUp=\(keepUp), \(self.detailDiagnostic(player, item: item))")
                self.scheduleDetailStartupRecovery(for: item, mid: mid)
                return
            }

            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            _ = self.currentPlayer.map { applyFeedStylePrePlayBuffering(to: $0, item: item) }
            print("📱 [DetailVideoManager] recovery play nudge \(self.shortMID(mid)): buffered=\(String(format: "%.2f", bufferedAhead)), required=\(String(format: "%.2f", requiredBuffer)), keepUp=\(keepUp), \(self.detailDiagnostic(player, item: item))")
            self.currentPlayer?.play()

            try? await Task.sleep(nanoseconds: self.detailStartupRecoveryDelay)
            guard !Task.isCancelled,
                  self.currentPlayer?.currentItem === item,
                  self.currentVideoMid == mid else {
                self.detailStartupRecoveryTask = nil
                self.detailStartupRecoveryItem = nil
                return
            }

            if self.markDetailRenderingIfDecoded(player: player, item: item) {
                self.isItemReady = true
                self.detailStartupRecoveryAttemptCount = 0
                self.detailStartupUnknownAttemptCount = 0
            } else if item.status == .readyToPlay {
                if self.rebuildDetailItemAfterStall(player: player, item: item, mid: mid, reason: "no decoded frame after play nudge") {
                    return
                }
                // Ready does not guarantee a visible frame. Keep the loading affordance
                // while playback is still waiting/paused so DetailView does not show a
                // black player with no feedback.
                self.isItemReady = true
                self.isBuffering = !self.isPlaybackRendering && !self.isVideoAtEnd(player)
                self.detailStartupRecoveryTask = nil
                self.detailStartupRecoveryItem = nil
                self.scheduleDetailStartupRecovery(for: item, mid: mid)
                return
            }
            print("📱 [DetailVideoManager] recovery result \(self.shortMID(mid)): \(self.detailDiagnostic(self.currentPlayer, item: item)), isBuffering=\(self.isBuffering), isRendering=\(self.isPlaybackRendering)")
            self.detailStartupRecoveryTask = nil
            self.detailStartupRecoveryItem = nil
        }
    }

    private func bufferedTimeAhead(for item: AVPlayerItem, player: AVPlayer) -> Double {
        let currentSeconds = CMTimeGetSeconds(player.currentTime())
        guard currentSeconds.isFinite else { return 0 }
        var bestBufferAhead: Double = 0
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = CMTimeGetSeconds(range.start)
            let duration = CMTimeGetSeconds(range.duration)
            guard start.isFinite, duration.isFinite else { continue }
            let end = start + duration
            if currentSeconds >= start && currentSeconds <= end {
                return max(0, end - currentSeconds)
            } else if end > currentSeconds {
                bestBufferAhead = max(bestBufferAhead, end - currentSeconds)
            }
        }
        return max(0, bestBufferAhead)
    }

    private func isNear(_ lhs: CMTime, _ rhs: CMTime, tolerance: Double) -> Bool {
        let left = CMTimeGetSeconds(lhs)
        let right = CMTimeGetSeconds(rhs)
        guard left.isFinite, right.isFinite else { return false }
        return abs(left - right) <= tolerance
    }

    private func seconds(from time: CMTime) -> Double {
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite ? seconds : 0
    }

    private func setupDetailVideoOutput(for item: AVPlayerItem) {
        if detailVideoOutputItem === item, detailVideoOutput != nil { return }
        if let previousItem = detailVideoOutputItem, let output = detailVideoOutput {
            previousItem.remove(output)
        }

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        item.add(output)
        detailVideoOutput = output
        detailVideoOutputItem = item
    }

    private func removeDetailRenderingObservers() {
        if let observer = detailPlaybackProgressObserver,
           let player = detailPlaybackProgressPlayer {
            player.removeTimeObserver(observer)
        }
        detailPlaybackProgressObserver = nil
        detailPlaybackProgressPlayer = nil

        if let item = detailVideoOutputItem,
           let output = detailVideoOutput {
            item.remove(output)
        }
        detailVideoOutput = nil
        detailVideoOutputItem = nil
    }

    private func resetDetailRenderingProgress(to time: CMTime = .zero) {
        detailPlaybackStartSeconds = seconds(from: time)
        isPlaybackRendering = false
    }

    private func detailDecodedFrameTime(for player: AVPlayer, item: AVPlayerItem) -> CMTime? {
        guard detailVideoOutputItem === item,
              let output = detailVideoOutput else { return nil }
        let hostItemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        if hostItemTime.isValid, output.hasNewPixelBuffer(forItemTime: hostItemTime) {
            return hostItemTime
        }
        let currentTime = player.currentTime()
        if currentTime.isValid, output.hasNewPixelBuffer(forItemTime: currentTime) {
            return currentTime
        }
        return nil
    }

    private func markDetailRenderingIfDecoded(player: AVPlayer, item: AVPlayerItem) -> Bool {
        if let decodedTime = detailDecodedFrameTime(for: player, item: item) {
            let decodedSeconds = seconds(from: decodedTime)
            guard decodedSeconds + 0.25 >= detailPlaybackStartSeconds else { return false }
            markDetailPlaybackRendering(player: player, item: item, visibleTime: decodedTime)
            return true
        }

        let currentTime = player.currentTime()
        let currentSeconds = seconds(from: currentTime)
        let hasAdvanced = currentSeconds >= detailPlaybackStartSeconds + 0.25
        let hasHealthyBuffer = item.status == .readyToPlay
            && bufferedTimeAhead(for: item, player: player) >= 0.75

        if player.timeControlStatus == .playing,
           hasAdvanced,
           hasHealthyBuffer {
            markDetailPlaybackRendering(player: player, item: item, visibleTime: currentTime)
            return true
        }

        return false
    }

    private func markDetailPlaybackRendering(player: AVPlayer, item: AVPlayerItem, visibleTime: CMTime) {
        if let mediaID = currentVideoMid {
            VideoPlaybackSessionStore.shared.noteDecodedFrame(mediaID: mediaID, time: visibleTime)
        }
        isPlaybackRendering = true
        hasPlayableMediaContent = true
        isItemReady = true
        detailStartupRecoveryAttemptCount = 0
        detailStartupUnknownAttemptCount = 0
        isBuffering = shouldKeepDetailBuffering(player: player, item: item)
        if !isBuffering {
            activeFeedHandoffTime = nil
        }
    }

    private func preserveDetailFrameToCache(player: AVPlayer, mediaID: String) {
        if let item = player.currentItem,
           detailVideoOutputItem === item,
           let output = detailVideoOutput {
            let currentTime = player.currentTime()
            let hostItemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            var candidateTimes: [CMTime] = [currentTime]
            if hostItemTime.isValid {
                candidateTimes.append(hostItemTime)
            }
            candidateTimes.append(contentsOf: [0.08, 0.2, 0.4].compactMap { backoff in
                let seconds = max(0, self.seconds(from: currentTime) - backoff)
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                return time.isValid ? time : nil
            })

            var displayTime = CMTime.zero
            for time in candidateTimes where time.isValid {
                guard let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayTime) else {
                    continue
                }
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                guard width > 0, height > 0, width < 10000, height < 10000,
                      let image = VideoFrameExtractor.makeDownscaledUIImage(from: pixelBuffer, maxDimension: 720),
                      !VideoFrameExtractor.isMostlyBlack(image) else {
                    continue
                }
                let frameTime = displayTime.isValid ? displayTime : time
                VideoPlaybackSessionStore.shared.noteDecodedFrame(mediaID: mediaID, time: frameTime)
                SharedAssetCache.shared.updateCachedThumbnail(image, for: mediaID)
                return
            }
        }

        guard let asset = player.currentItem?.asset else { return }
        let captureTime = player.currentTime()
        guard captureTime.isValid, self.seconds(from: captureTime).isFinite else { return }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: captureTime)]) { _, cgImage, _, result, _ in
            guard result == .succeeded, let cgImage else { return }
            let image = UIImage(cgImage: cgImage)
            Task { @MainActor in
                guard !VideoFrameExtractor.isMostlyBlack(image) else { return }
                VideoPlaybackSessionStore.shared.noteDecodedFrame(mediaID: mediaID, time: captureTime)
                SharedAssetCache.shared.updateCachedThumbnail(image, for: mediaID)
            }
        }
    }

    private func startDetailRenderingObserver(player: AVPlayer, item: AVPlayerItem) {
        if detailPlaybackProgressPlayer !== player || detailPlaybackProgressObserver == nil {
            if let observer = detailPlaybackProgressObserver,
               let oldPlayer = detailPlaybackProgressPlayer {
                oldPlayer.removeTimeObserver(observer)
            }
            detailPlaybackProgressPlayer = player
            detailPlaybackProgressObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                queue: .main
            ) { [weak self, weak player, weak item] _ in
                Task { @MainActor [weak self, weak player, weak item] in
                    guard let self,
                          let player,
                          let item,
                          self.currentPlayer === player,
                          player.currentItem === item,
                          !self.isVideoAtEnd(player) else { return }

                    if self.markDetailRenderingIfDecoded(player: player, item: item) {
                        self.detailStartupRecoveryTask?.cancel()
                        self.detailStartupRecoveryTask = nil
                        self.detailStartupRecoveryItem = nil
                    } else if self.isPlaying {
                        self.updateDetailBufferedData(for: item)
                        self.isBuffering = self.shouldKeepDetailBuffering(player: player, item: item)
                    }
                }
            }
        }
    }

    private func isVideoAtEnd(_ player: AVPlayer) -> Bool {
        guard let item = player.currentItem else { return false }
        let duration = CMTimeGetSeconds(item.duration)
        let current = CMTimeGetSeconds(player.currentTime())
        guard duration.isFinite, duration > 0, current.isFinite else { return false }
        return duration - current <= 0.5
    }

    /// Set current video for detail view (LEGACY — used by SimpleVideoPlayer tweetDetail mode)
    func setCurrentVideo(url: URL, mid: String, autoPlay: Bool = true) {
        if detailLoadTask != nil, let oldMid = currentVideoMid {
            SharedAssetCache.shared.cancelTransientLoading(for: oldMid)
        }
        detailLoadTask?.cancel()
        detailLoadTask = nil
        loadGeneration += 1
        let generation = loadGeneration

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
        Task { @MainActor [weak self] in
            guard let self, self.currentVideoMid == mid else { return }
            self.refreshDetailCachedMediaContent(for: mid)
        }
        
        // Check if we have saved state for this video
        let hasSavedState = PersistentVideoStateManager.shared.shouldRestorePlayback(
            videoMid: mid,
            context: .detailView
        )
        
        // Activate audio session for video playback
        AudioSessionManager.shared.activateForVideoPlayback()
        
        detailLoadTask = Task(priority: .userInitiated) { @MainActor in
            do {
                try Task.checkCancellation()
                
                // Create independent player with disk caching support
                // Get the asset from SharedAssetCache (which uses CachingPlayerItem for HLS)
                // but create our own independent player instance
                let asset = try await SharedAssetCache.shared.getAsset(for: url, mediaID: mid, tweetId: mid)
                try Task.checkCancellation()
                let playerItem = AVPlayerItem(asset: asset)
                let newPlayer = AVPlayer(playerItem: playerItem)
                
                guard !Task.isCancelled,
                      self.loadGeneration == generation,
                      self.currentVideoMid == mid else {
                    newPlayer.pause()
                    newPlayer.replaceCurrentItem(with: nil)
                    return
                }
                self.detailLoadTask = nil
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
            } catch {
                if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                guard self.loadGeneration == generation,
                      self.currentVideoMid == mid else { return }
                self.detailLoadTask = nil
                print("ERROR: [DETAIL VIDEO MANAGER] Failed to load video: \(error)")
            }
        }
    }
    
    /// Clear current video
    func clearCurrentVideo(preserveSharedFeedPlayback: Bool = false) {
        let pendingLoadMid = currentVideoMid

        // Save playback state before clearing — but only if time is valid.
        if let player = currentPlayer,
           let videoMid = currentVideoMid {
            preserveDetailFrameToCache(player: player, mediaID: videoMid)

            let currentTime = player.currentTime()
            if currentTime.isValid && currentTime.seconds.isFinite && currentTime.seconds > 0.25 {
                let wasPlaying = player.rate > 0
                let duration = player.currentItem?.duration ?? .invalid
                PersistentVideoStateManager.shared.saveState(
                    videoMid: videoMid,
                    currentTime: currentTime,
                    wasPlaying: wasPlaying,
                    context: .detailView,
                    duration: duration
                )
            }
        }

        // Clean up new-style observers
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        removeDetailRenderingObservers()
        if detailLoadTask != nil, let pendingLoadMid {
            SharedAssetCache.shared.cancelTransientLoading(for: pendingLoadMid)
        }
        detailLoadTask?.cancel()
        detailLoadTask = nil
        detailStartupRecoveryTask?.cancel()
        detailStartupRecoveryTask = nil
        detailStartupRecoveryItem = nil
        detailStartupRecoveryAttemptCount = 0
        detailStartupUnknownAttemptCount = 0
        detailStallItemRebuildCount = 0
        isItemReady = false
        isBuffering = false
        hasBufferedData = false
        hasCachedMediaContent = false
        hasPlayableMediaContent = false
        isPlaybackRendering = false
        isSeekingToStartupPosition = false
        didFinishPlayback = false
        loadFailedVideoMid = nil
        pendingFeedResumeTime = nil
        activeFeedHandoffTime = nil

        // Remove legacy KVO observer before clearing (only if it was added)
        if hasKVOObserver, let player = currentPlayer, let playerItem = player.currentItem {
            playerItem.removeObserver(self, forKeyPath: "status")
            hasKVOObserver = false
        }

        // Remove video completion observer
        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
        
        if preserveSharedFeedPlayback,
           let player = currentPlayer,
           let mid = currentVideoMid,
           isSharedFeedPlayer(player, mid: mid) {
            if let item = player.currentItem,
               releaseCachedFeedPlayerForFocusedPlaybackIfNeeded(player, item: item, mid: mid, owner: "detail clear") {
                currentPlayer = nil
                feedHandoffMid = nil
                feedHandoffExpiresAt = .distantPast
            } else {
                player.currentItem?.cancelPendingSeeks()
                markFeedHandoff(mid: mid)
            }
        } else {
            currentPlayer?.pause()
            feedHandoffMid = nil
            feedHandoffExpiresAt = .distantPast
        }

        currentPlayer = nil
        currentVideoMid = nil
        isPlaying = false
        isBuffering = false
        hasBufferedData = false
        hasCachedMediaContent = false
        hasPlayableMediaContent = false
        isPlaybackRendering = false
        didFinishPlayback = false
        isUsingBorrowedFeedPlayer = false
        loadFailedVideoMid = nil
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
            let notificationObjectDescription = String(describing: notification.object ?? "nil")
            MainActor.assumeIsolated {
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
                print("DEBUG: [DETAIL VIDEO MANAGER] Notification object: \(notificationObjectDescription)")
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
        guard keyPath == "status",
              let playerItem = object as? AVPlayerItem else { return }
        let observedItemID = ObjectIdentifier(playerItem)
        let observedStatus = playerItem.status
        Task { @MainActor [weak self] in
            guard let self else { return }
            if observedStatus == .readyToPlay {
                if let player = currentPlayer,
                   let currentItem = player.currentItem,
                   ObjectIdentifier(currentItem) == observedItemID {
                        player.play()
                        isPlaying = true
                }
            } else if observedStatus == .failed {
                print("ERROR: [DETAIL VIDEO MANAGER] Player item failed to load")
            }
        }
    }

    private func handleReloadVisibleVideosOnly() {
        guard isActive else { return }

        let playerMissing = currentPlayer == nil
        let itemMissing = currentPlayer?.currentItem == nil
        let playerBroken = playerMissing ? false : isPlayerBroken()
        let playerEmptyAfterRestart = shouldReloadDetailPlayerAfterInfrastructureRestart()

        guard playerMissing || itemMissing || playerBroken || playerEmptyAfterRestart else {
            print("✅ [DetailVideoManager] handleReloadVisibleVideosOnly - player healthy")
            return
        }

        guard let request = lastRequestedDetailVideo,
              request.mid == currentVideoMid || currentVideoMid == nil else {
            print("⚠️ [DetailVideoManager] handleReloadVisibleVideosOnly - no video info to reload")
            return
        }

        if let player = currentPlayer,
           let videoMid = currentVideoMid {
            let currentTime = player.currentTime()
            if currentTime.isValid, currentTime.seconds.isFinite, currentTime.seconds > 0.25 {
                PersistentVideoStateManager.shared.saveState(
                    videoMid: videoMid,
                    currentTime: currentTime,
                    wasPlaying: isPlaying || player.rate > 0,
                    context: .detailView,
                    duration: player.currentItem?.duration ?? .invalid
                )
            }
        }

        print("🔄 [DetailVideoManager] Reloading detail video after infrastructure restart \(shortMID(request.mid)) (playerMissing:\(playerMissing), itemMissing:\(itemMissing), playerBroken:\(playerBroken), emptyAfterRestart:\(playerEmptyAfterRestart))")
        clearBrokenPlayer()
        loadVideo(url: request.url, mid: request.mid, mediaType: request.mediaType)
    }

    private func shouldReloadDetailPlayerAfterInfrastructureRestart() -> Bool {
        guard let player = currentPlayer,
              let item = player.currentItem,
              currentVideoMid != nil else {
            return false
        }

        if item.status == .failed || item.error != nil || player.error != nil {
            return true
        }

        let hasLoadedData = item.loadedTimeRanges.contains { value in
            let duration = CMTimeGetSeconds(value.timeRangeValue.duration)
            return duration.isFinite && duration > 0
        }

        if item.status == .readyToPlay,
           !hasLoadedData,
           player.timeControlStatus != .playing {
            return true
        }

        return false
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

    private var lifecycleObservers: [NSObjectProtocol] = []

    private init() {
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.releaseChatVideoMemoryForBackground()
                }
            }
        )
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: .reloadVisibleVideosOnly,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.recoverVisibleVideosAfterInfrastructureReady(reason: "reloadVisibleVideosOnly")
                }
            }
        )
    }

    deinit {
        MainActor.assumeIsolated {
            lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
            lifecycleObservers.removeAll()
        }
    }

    // Track active chat sessions and their video states
    @Published var activeChatSessions: [String: ChatSessionVideoState] = [:] // Key: receiptId

    // Current visible videos per chat session
    private var visibleVideos: [String: Set<String>] = [:] // Key: receiptId, Value: Set of video mids

    /// State for a specific chat session's videos
    struct ChatSessionVideoState {
        var playingVideos: Set<String> = [] // mids of videos currently playing
        var pausedVideos: Set<String> = [] // mids of videos paused due to visibility
        var isChatVisible: Bool = true // whether the chat screen is currently visible
    }

    /// Chat inline players are owned by SharedAssetCache. Background memory release
    /// happens through the shared inline video path; chat only clears playback intent.
    private func releaseChatVideoMemoryForBackground() {
        for receiptId in activeChatSessions.keys {
            pauseAllVideosInSession(receiptId: receiptId)
        }
    }

    /// Register a chat session for video management
    func registerChatSession(receiptId: String) {
        if activeChatSessions[receiptId] == nil {
            activeChatSessions[receiptId] = ChatSessionVideoState()
            visibleVideos[receiptId] = Set<String>()
            print("DEBUG: [ChatVideoManager] Registered chat session: \(receiptId)")
        }
    }

    /// Unregister a chat session (cleanup when leaving chat)
    func unregisterChatSession(receiptId: String) {
        if let mids = visibleVideos.removeValue(forKey: receiptId) {
            for mid in mids {
                SharedAssetCache.shared.markAsNotVisible(mid)
            }
        }

        activeChatSessions.removeValue(forKey: receiptId)
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
                SharedAssetCache.shared.markAsVisible(videoMid)
                startVideo(mid: videoMid, receiptId: receiptId)
            }
        }

        // Handle newly invisible videos
        if !newlyInvisible.isEmpty {
            for videoMid in newlyInvisible {
                SharedAssetCache.shared.markAsNotVisible(videoMid)
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
        senderBaseUrl: URL? = nil,
        isChatScreenVisible: Bool,
        receiptId: String
    ) async -> AVPlayer? {
        if let existingPlayer = SharedAssetCache.shared.getCachedPlayer(for: attachment.mid),
           !isPlayerBroken(existingPlayer) {
            return existingPlayer
        }

        // Get the base URL for the video
        let baseUrl: URL = {
            if isFromCurrentUser {
                return HproseInstance.shared.appUser.baseUrl ?? HproseInstance.baseUrl
            } else {
                return senderBaseUrl ?? senderUser?.baseUrl ?? HproseInstance.baseUrl
            }
        }()

        // Get the video URL
        guard let url = attachment.getUrl(baseUrl) else {
            return nil
        }

        do {
            return try await SharedAssetCache.shared.getOrCreatePlayer(for: url, mediaID: attachment.mid, mediaType: attachment.type)
        } catch {
            print("DEBUG: [ChatVideoManager] Failed to create player for \(messageId): \(error)")
            return nil
        }
    }

    /// Remove a shared inline player when a chat video needs a fresh URL/item.
    func removeVideoPlayer(mediaID: String) {
        SharedAssetCache.shared.releaseCachedPlayer(for: mediaID, force: true)
    }

    /// Clean up all video players for a chat session
    func cleanupChatSession(receiptId: String) {
        if let mids = visibleVideos.removeValue(forKey: receiptId) {
            for mid in mids {
                SharedAssetCache.shared.markAsNotVisible(mid)
                SharedAssetCache.shared.releaseCachedPlayer(for: mid, force: false)
            }
        }
        print("DEBUG: [ChatVideoManager] Cleaned up chat session: \(receiptId)")
    }

    // MARK: - Private Methods

    private func isPlayerBroken(_ player: AVPlayer) -> Bool {
        guard let item = player.currentItem else { return true }
        if item.status == .failed || item.error != nil || player.error != nil {
            return true
        }
        let seconds = player.currentTime().seconds
        return seconds.isNaN || seconds == .infinity || seconds == -.infinity
    }

    private func recoverVisibleVideosAfterInfrastructureReady(reason: String) {
        guard AppDelegate.isVideoInfrastructureReady else { return }

        var recoveredCount = 0
        for (receiptId, sessionState) in activeChatSessions where sessionState.isChatVisible {
            let mids = visibleVideos[receiptId] ?? []
            guard !mids.isEmpty else { continue }

            var updatedState = sessionState
            updatedState.playingVideos.formUnion(mids)
            updatedState.pausedVideos.subtract(mids)
            activeChatSessions[receiptId] = updatedState

            for mid in mids {
                recoveredCount += 1
                NotificationCenter.default.post(
                    name: .chatVideoShouldRecover,
                    object: nil,
                    userInfo: [
                        "videoMid": mid,
                        "receiptId": receiptId,
                        "reason": reason
                    ]
                )
            }
        }

        if recoveredCount > 0 {
            print("DEBUG: [ChatVideoManager] Requested recovery for \(recoveredCount) visible chat video(s) after \(reason)")
        }
    }

    private func startVideo(mid: String, receiptId: String) {
        guard var sessionState = activeChatSessions[receiptId] else { return }

        // Check if already playing
        guard !sessionState.playingVideos.contains(mid) else { return }

        // Add to playing videos
        sessionState.playingVideos.insert(mid)
        sessionState.pausedVideos.remove(mid)
        activeChatSessions[receiptId] = sessionState

        // Notify chat video views to start playing
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

        // Notify chat video views to pause
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

        // Notify chat video views to stop
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

        // Directly pause cached shared players for this session.
        if let mids = visibleVideos[receiptId] {
            for mid in mids {
                SharedAssetCache.shared.getCachedPlayer(for: mid)?.pause()
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
