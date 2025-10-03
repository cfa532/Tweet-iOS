//
//  SimpleVideoPlayer.swift
//  Tweet
//
//  Consolidated video player with asset sharing
//

import SwiftUI
import AVKit
import AVFoundation

// MARK: - Video Player Mode
enum Mode {
    case mediaCell // Normal cell in feed/grid
    case mediaBrowser // In MediaBrowserView (fullscreen browser)
}

// MARK: - Video Player State Manager
class VideoStateCache {
    static let shared = VideoStateCache()
    private var cache: [String: (player: AVPlayer, time: CMTime, wasPlaying: Bool, originalMuteState: Bool)] = [:]
    
    private init() {}
    
    func cacheVideoState(for mid: String, player: AVPlayer, time: CMTime, wasPlaying: Bool, originalMuteState: Bool) {
        print("DEBUG: [VIDEO CACHE] Caching video state for \(mid) with original mute state: \(originalMuteState)")
        cache[mid] = (player: player, time: time, wasPlaying: wasPlaying, originalMuteState: originalMuteState)
    }
    
    func getCachedState(for mid: String) -> (player: AVPlayer, time: CMTime, wasPlaying: Bool, originalMuteState: Bool)? {
        return cache[mid]
    }
    
    func clearCache(for mid: String) {
        print("DEBUG: [VIDEO CACHE] Clearing cache for \(mid)")
        cache.removeValue(forKey: mid)
    }
    
    func clearAllCache() {
        print("DEBUG: [VIDEO CACHE] Clearing all cache")
        cache.removeAll()
    }
}

// MARK: - Unified Simple Video Player
struct SimpleVideoPlayer: View {
    // MARK: Required Parameters
    let url: URL
    let mid: String
    let isVisible: Bool
    
    // MARK: Optional Parameters
    var autoPlay: Bool = true
    var videoManager: VideoManager? = nil // Optional VideoManager for reactive playback
    var onVideoFinished: (() -> Void)? = nil
    var cellAspectRatio: CGFloat? = nil
    var videoAspectRatio: CGFloat? = nil
    var showNativeControls: Bool = true
    var isMuted: Bool = true // Mute state controlled by caller
    var onVideoTap: (() -> Void)? = nil // Callback when video is tapped
    var disableAutoRestart: Bool = false // Disable auto-restart when video finishes
    var forceRefreshTrigger: Int = 0 // External trigger to force refresh
    var cancelVideoTrigger: Int = 0 // External trigger to cancel video loading/playback
    var shouldLoadVideo: Bool = true // Whether grid-level loading is enabled
    
    // MARK: Mode
    var mode: Mode = .mediaCell
    
    // MARK: State
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var hasFinishedPlaying = false
    @State private var loadFailed = false
    @State private var retryCount = 0
    private var instanceId: String { mid }
    @State private var isLongPressing = false
    @State private var nativeControlsTimer: Timer?
    @State private var playerItem: AVPlayerItem? // Keep reference for observer cleanup
    @State private var isPlayerDetached = false // Track if player is detached for background prevention
    
    // MARK: Computed Properties
    private var isVideoPortrait: Bool {
        guard let ar = videoAspectRatio else { return false }
        return ar < 1.0
    }
    
    private var isVideoLandscape: Bool {
        guard let ar = videoAspectRatio else { return false }
        return ar > 1.0
    }
    
    // Reactive autoPlay state - use VideoManager if available, otherwise use static autoPlay
    private var currentAutoPlay: Bool {
        if let videoManager = videoManager {
            return videoManager.shouldPlayVideo(for: mid)
        }
        return autoPlay
    }
    
    var body: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            let screenHeight = geometry.size.height
            
            if let videoAR = videoAspectRatio, videoAR > 0 {
                switch mode {
                case .mediaCell:
                    // MediaCell mode: use cell aspect ratio and normal behavior
                    if let cellAR = cellAspectRatio {
                        let cellWidth = geometry.size.width
                        let cellHeight = cellWidth / cellAR
                        let needsVerticalPadding = videoAR < cellAR
                        let videoHeight = cellWidth / videoAR
                        let overflow = videoHeight - cellHeight
                        let pad = needsVerticalPadding && overflow > 0 ? overflow / 2 : 0
                        ZStack {
                            videoPlayerView()
                                .offset(y: -pad)    // align the video vertically in the middle
                                .aspectRatio(videoAR, contentMode: .fill)
                        }
                    } else {
                        // Fallback when no cellAspectRatio is available
                        videoPlayerView()
                            .aspectRatio(videoAR, contentMode: .fit)
                        }
                    
                case .mediaBrowser:
                    // MediaBrowser mode: fullscreen browser with native controls only
                    if isVideoPortrait {
                        // Portrait video: fit on full screen
                        videoPlayerView()
                            .aspectRatio(videoAR, contentMode: .fit)
                            .frame(maxWidth: screenWidth, maxHeight: screenHeight)
                    } else {
                        // Landscape video: rotate 90 degrees clockwise to fit on portrait device
                        ZStack {
                            videoPlayerView()
                                .aspectRatio(videoAR, contentMode: .fit)
                                .frame(maxWidth: screenWidth - 2, maxHeight: screenHeight - 2)
                                .rotationEffect(.degrees(-90))
                                .scaleEffect(screenHeight / screenWidth)
                                .background(Color.black)
                        }
                    }
                    
                    
                }
            } else {
                // Fallback when no aspect ratio is available
                videoPlayerView()
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                    .frame(maxWidth: screenWidth, maxHeight: screenHeight)
            }
        }
        .onAppear {
            // Handle idle timer for fullscreen modes
            if mode == .mediaBrowser {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            
            // Validate existing player state if present
            if let player = player, let playerItem = player.currentItem {
                if playerItem.status == .failed {
                    print("DEBUG: [VIDEO APPEAR] Player item is in failed state for \(mid), triggering recovery")
                    handleLoadFailure()
                    return
                }
            }
            
            // Only set up player if both conditions are met
            if player == nil && shouldLoadVideo && isVisible {
                setupPlayer()
            }
        }
        .onDisappear {
            // Handle idle timer for fullscreen modes
            if mode == .mediaBrowser {
                UIApplication.shared.isIdleTimerDisabled = false
            }
            
            // Remove observers to prevent memory leaks
            removePlayerObservers()
            
            // Cache the current video state before pausing
            if let player = player {
                // For MediaCell mode, save the current global mute state
                // For detail/fullscreen modes, we need to track the original global mute state
                let originalMuteState = mode == .mediaCell ? isMuted : MuteState.shared.isMuted
                VideoStateCache.shared.cacheVideoState(
                    for: mid,
                    player: player,
                    time: player.currentTime(),
                    wasPlaying: player.rate > 0,
                    originalMuteState: originalMuteState
                )
            }
            // Always pause when view disappears
            player?.pause()
        }
        .onChange(of: isMuted) { _, newMuteState in
            // For full screen modes, always keep unmuted regardless of the isMuted parameter
            if mode == .mediaBrowser {
                player?.isMuted = false
                print("DEBUG: [VIDEO MUTE CHANGE] Forced unmuted for full screen mode")
            } else {
                player?.isMuted = newMuteState
            }
        }
        .onReceive(MuteState.shared.$isMuted) { globalMuteState in
            // For MediaCell mode, always sync with global mute state
            if mode == .mediaCell {
                player?.isMuted = globalMuteState
                print("DEBUG: [VIDEO GLOBAL MUTE] Synced with global mute state: \(globalMuteState)")
            }
            // For full screen modes, ignore global mute state and always keep unmuted
            else if mode == .mediaBrowser {
                player?.isMuted = false
                print("DEBUG: [VIDEO GLOBAL MUTE] Ignored global mute state for full screen mode")
            }
        }
        .onChange(of: currentAutoPlay) { _, shouldAutoPlay in
            // Handle autoPlay state changes (reactive to VideoManager)
            checkPlaybackConditions(autoPlay: shouldAutoPlay, isVisible: isVisible)
            if !shouldAutoPlay {
                player?.pause()
            }
        }
        .onChange(of: isVisible) { _, visible in
            // Handle visibility changes - simplified logic to avoid conflicts
            if visible {
                // Only proceed if loading is enabled
                guard shouldLoadVideo else {
                    print("DEBUG: [VIDEO VISIBILITY] Video became visible but loading is disabled for \(mid)")
                    return
                }
                
                // Validate existing player state if present
                if let player = player, let playerItem = player.currentItem {
                    if playerItem.status == .failed {
                        print("DEBUG: [VIDEO VISIBILITY] Player item is in failed state for \(mid), triggering recovery")
                        handleLoadFailure()
                        return
                    }
                }
                
                // If no player and loading is enabled, set up the player
                if player == nil {
                    print("DEBUG: [VIDEO VISIBILITY] Video became visible with no player, setting up: \(mid)")
                    setupPlayer()
                } else {
                    // Restore cached video state if available
                    restoreCachedVideoState()
                    checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: visible)
                }
            } else {
                // When becoming invisible, cache state but don't pause here
                // (pause is handled in onDisappear to avoid conflicts)
                if let player = player {
                    // For MediaCell mode, save the current global mute state
                    // For detail/fullscreen modes, we need to track the original global mute state
                    let originalMuteState = mode == .mediaCell ? isMuted : MuteState.shared.isMuted
                    VideoStateCache.shared.cacheVideoState(
                        for: mid,
                        player: player,
                        time: player.currentTime(),
                        wasPlaying: player.rate > 0,
                        originalMuteState: originalMuteState
                    )
                }
            }
        }
        .onChange(of: player) { _, newPlayer in
            // When player becomes available, check if we should autoplay
            if newPlayer != nil {
                checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
            }
        }
        .onChange(of: forceRefreshTrigger) { _, _ in
            // External trigger to force refresh (e.g., from MediaCell long press)
            if loadFailed {
                print("DEBUG: [VIDEO FORCE REFRESH] External refresh triggered for \(mid)")
                handleManualReset()
            }
        }
        .onChange(of: cancelVideoTrigger) { _, _ in
            // External trigger to cancel video loading/playback
            print("DEBUG: [VIDEO CANCELLATION] External cancellation triggered for \(mid)")
            cancelVideoLoading()
        }
        .onChange(of: shouldLoadVideo) { _, newShouldLoadVideo in
            // Grid-level loading state changed - consolidate all loading decisions here
            handleLoadingStateChange(newShouldLoadVideo: newShouldLoadVideo)
        }
        
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // App going to background - detach player to prevent black screens
            print("DEBUG: [VIDEO BACKGROUND] App entering background for \(mid)")
            detachPlayerForBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // App will enter foreground - reattach player to prevent black screens
            print("DEBUG: [VIDEO FOREGROUND] App will enter foreground for \(mid)")
            reattachPlayerForForeground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // App became active - ensure player is properly reattached and configured
            print("DEBUG: [VIDEO APP ACTIVE] App became active for \(mid)")
            
            // Always try to restore cached state first when app becomes active
            if player == nil && shouldLoadVideo {
                print("DEBUG: [VIDEO APP ACTIVE] No player found, attempting to restore cached state for \(mid)")
                restoreCachedVideoState()
            }
            
            // Ensure player is reattached if it was detached
            if isPlayerDetached {
                print("DEBUG: [VIDEO APP ACTIVE] Player was detached, reattaching for \(mid)")
                reattachPlayerForForeground()
            }
            
            // Ensure mute state is properly applied when app becomes active
            // This handles cases where MuteState was refreshed after video was created
            if let player = player {
                if mode == .mediaCell {
                    player.isMuted = MuteState.shared.isMuted
                    print("DEBUG: [VIDEO APP ACTIVE] Applied current global mute state (\(MuteState.shared.isMuted)) for MediaCell mode")
                } else if mode == .mediaBrowser {
                    player.isMuted = false
                    print("DEBUG: [VIDEO APP ACTIVE] Forced unmuted for full screen mode")
                }
            }
            
            // If video is visible and should play, resume playback
            if isVisible && currentAutoPlay && shouldLoadVideo {
                print("DEBUG: [VIDEO APP ACTIVE] Resuming playback for \(mid)")
                checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
            }
            
            // Reset error state for videos that might have been interrupted
            if loadFailed {
                print("DEBUG: [VIDEO APP ACTIVE] Resetting error state for \(mid)")
                retryCount = 0
                loadFailed = false
            }
        }
        .onTapGesture {
            if let onVideoTap = onVideoTap {
                onVideoTap()
            }
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            isLongPressing = true
            // Handle manual video reset on long press
            handleManualReset()
        } onPressingChanged: { pressing in
            if !pressing {
                isLongPressing = false
            }
        }
    }
    
    // MARK: - Video Player View
    @ViewBuilder
    private func videoPlayerView() -> some View {
        if let player = player {
            ZStack {
                // Main video player - only show if not detached
                if !isPlayerDetached {
                    if mode == .mediaBrowser {
                        // Use AVPlayerViewController for fullscreen modes to get native controls
                        AVPlayerViewControllerRepresentable(player: player)
                            .onTapGesture {
                                if let onVideoTap = onVideoTap {
                                    onVideoTap()
                                }
                            }
                    } else {
                        // Use SwiftUI VideoPlayer for normal modes
                        VideoPlayer(player: player)
                            .onTapGesture {
                                if let onVideoTap = onVideoTap {
                                    onVideoTap()
                                }
                            }
                    }
                } else {
                    // Show placeholder when player is detached (background state)
                    Rectangle()
                        .fill(Color.black.opacity(0.8))
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "pause.circle")
                                    .font(.title)
                                    .foregroundColor(.white.opacity(0.7))
                                Text("Video paused")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        )
                }
                
                // Loading indicator
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(8)
                }
                
                // Error state
                if loadFailed {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundColor(.white)
                        Text("Failed to load video")
                            .foregroundColor(.white)
                            .font(.caption)
                        Button(action: {
                            handleManualReset()
                        }) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Retry")
                            }
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.8))
                            .cornerRadius(4)
                        }
                    }
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
                }
                
                // Long press indicator
                if isLongPressing {
                    Color.black.opacity(0.3)
                        .onTapGesture {
                            isLongPressing = false
                        }
                }
            }
        } else {
            // Placeholder while loading
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .overlay(
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                )
        }
    }
    
    // MARK: - Player Setup
    private func setupPlayer() {
        print("DEBUG: [VIDEO SETUP] Setting up player for \(mid)")
        
        // Early return if loading is disabled
        guard shouldLoadVideo else {
            print("DEBUG: [VIDEO SETUP] Loading disabled for \(mid), skipping setup")
            return
        }
        
        // Reset error state when starting setup
        if loadFailed {
            print("DEBUG: [VIDEO SETUP] Resetting error state for \(mid)")
            loadFailed = false
            retryCount = 0
        }
        
        // Check if we have a cached player first - prioritize for fullscreen modes
        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            print("DEBUG: [VIDEO CACHE] Found cached player for \(mid) in \(mode) mode")
            restoreFromCache(cachedState)
            return
        }
        
        // For fullscreen modes, if no cached state and no player, try to restore from cache again
        // This handles cases where the cache was cleared but we still need the video
        if mode == .mediaBrowser && player == nil && !isLoading {
            print("DEBUG: [VIDEO CACHE] Fullscreen mode with no player, attempting to restore cached state for \(mid)")
            restoreCachedVideoState()
            return
        }
        
        // Otherwise, create a new player with performance considerations
        Task.detached(priority: .userInitiated) {
            do {
                // Add a small delay to prevent overwhelming the system when multiple videos load simultaneously
                let currentRetryCount = await retryCount
                if currentRetryCount == 0 {
                    try await Task.sleep(nanoseconds: UInt64(currentRetryCount * 50_000_000)) // 0.05s delay per retry
                }
                
                let newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(for: url, tweetId: mid)
                await MainActor.run {
                    configurePlayer(newPlayer)
                }
            } catch {
                await MainActor.run {
                    print("DEBUG: [VIDEO SETUP] Failed to setup player for \(mid): \(error)")
                    handleLoadFailure()
                }
            }
        }
    }
    
    private func restoreFromCache(_ cachedState: (player: AVPlayer, time: CMTime, wasPlaying: Bool, originalMuteState: Bool)) {
        print("DEBUG: [VIDEO CACHE] Restoring from cache for \(mid) with original mute state: \(cachedState.originalMuteState)")
        
        // Early return if loading is disabled
        guard shouldLoadVideo else {
            print("DEBUG: [VIDEO CACHE] Loading disabled for \(mid), skipping cache restoration")
            return
        }
        
        // Validate cached player before using it
        guard let playerItem = cachedState.player.currentItem else {
            print("DEBUG: [VIDEO CACHE] Cached player has no currentItem, clearing cache and creating new player for \(mid)")
            VideoStateCache.shared.clearCache(for: mid)
            SharedAssetCache.shared.removeInvalidPlayer(for: url)
            setupPlayer()
            return
        }
        
        // Check if player item is in a valid state
        if playerItem.status == .failed {
            print("DEBUG: [VIDEO CACHE] Cached player item is in failed state, clearing cache and creating new player for \(mid)")
            VideoStateCache.shared.clearCache(for: mid)
            SharedAssetCache.shared.removeInvalidPlayer(for: url)
            setupPlayer()
            return
        }
        
        // Check if player item is ready to play
        if playerItem.status != .readyToPlay {
            print("DEBUG: [VIDEO CACHE] Cached player item not ready (status: \(playerItem.status.rawValue)), clearing cache and creating new player for \(mid)")
            VideoStateCache.shared.clearCache(for: mid)
            SharedAssetCache.shared.removeInvalidPlayer(for: url)
            setupPlayer()
            return
        }
        
        // Restore the cached player
        self.player = cachedState.player
        
        // Ensure the player is also cached in SharedAssetCache for consistency
        SharedAssetCache.shared.cachePlayer(cachedState.player, for: url)
        
        // For MediaCell mode, always use the current global mute state instead of the cached one
        // This ensures videos respect the current global mute setting when returning from full screen
        if mode == .mediaCell {
            cachedState.player.isMuted = MuteState.shared.isMuted
            print("DEBUG: [VIDEO CACHE] Applied current global mute state (\(MuteState.shared.isMuted)) for MediaCell mode")
        } else {
            // For full screen modes (mediaBrowser), always unmute regardless of cached state
            // This ensures full screen videos are never muted
            cachedState.player.isMuted = false
            print("DEBUG: [VIDEO CACHE] Forced unmuted for full screen mode")
        }
        
        // Seek to the cached position
        cachedState.player.seek(to: cachedState.time) { finished in
            if finished {
                // If it was playing before, resume playback ONLY if VideoManager says it should play
                if cachedState.wasPlaying && self.isVisible && self.currentAutoPlay && self.videoManager?.shouldPlayVideo(for: self.mid) == true {
                    cachedState.player.play()
                    print("DEBUG: [VIDEO CACHE] Resumed playback from cache for \(self.mid) - VideoManager approved")
                } else if cachedState.wasPlaying {
                    print("DEBUG: [VIDEO CACHE] Skipped playback restoration for \(self.mid) - VideoManager did not approve")
                }
                print("DEBUG: [VIDEO CACHE] Successfully restored from cache for \(self.mid)")
            }
        }
        
        // Don't clear cache immediately - let it persist for fullscreen transitions
        // Cache will be cleared by the system cleanup or when explicitly needed
        
        // Update state
        self.isLoading = false
        self.loadFailed = false
        self.retryCount = 0
        self.hasFinishedPlaying = false
    }
    
    private func configurePlayer(_ player: AVPlayer) {
        // Configure player
        // For full screen modes, always unmute regardless of the isMuted parameter
        if mode == .mediaBrowser {
            player.isMuted = false
            print("DEBUG: [VIDEO CONFIGURE] Forced unmuted for full screen mode")
        } else {
            // For MediaCell mode, always use the current global mute state to ensure
            // videos respect the current mute setting even if MuteState was refreshed after initialization
            player.isMuted = MuteState.shared.isMuted
            print("DEBUG: [VIDEO CONFIGURE] Applied current global mute state (\(MuteState.shared.isMuted)) for MediaCell mode")
        }
        
        // Reset player position to beginning (in case it was cached at the end)
        player.seek(to: .zero)
        
        // Set up observers
        setupPlayerObservers(player)
        
        // Update state
        self.player = player
        self.isLoading = false
        self.loadFailed = false
        self.retryCount = 0
        self.hasFinishedPlaying = false // Reset finished state
        
        // Cache the player in SharedAssetCache for reuse
        SharedAssetCache.shared.cachePlayer(player, for: url)
        
        // Start playback if needed
        checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
    }
    
    private func setupPlayerObservers(_ player: AVPlayer) {
        guard let playerItem = player.currentItem else { return }
        
        // Store reference for cleanup
        self.playerItem = playerItem
        
        // Video finished observer
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            self.handleVideoFinished()
        }
        
        // Error observer
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { notification in
            self.handleLoadFailure()
        }
        
        // Note: KVO observers are not available in SwiftUI structs
        // Player status monitoring is handled through notification observers and periodic checks
    }
    
    private func removePlayerObservers() {
        // Remove observers to prevent memory leaks
        if let playerItem = playerItem {
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
        }
        playerItem = nil
    }
    
    private func handleLoadFailure() {
        loadFailed = true
        isLoading = false
        print("DEBUG: [VIDEO ERROR] Load failed for \(mid), retry count: \(retryCount)")
        
        // Remove observers to prevent memory leaks
        removePlayerObservers()
        
        // Clear the current player since it's in an invalid state
        player = nil
        
        // Clear all caches to force a fresh load
        VideoStateCache.shared.clearCache(for: mid)
        SharedAssetCache.shared.removeInvalidPlayer(for: url)
        
        // For fullscreen modes, try to restore from cache even on failure
        if mode == .mediaBrowser {
            print("DEBUG: [VIDEO ERROR] Fullscreen mode, attempting to restore from cache for \(mid)")
            restoreCachedVideoState()
        } else {
            // For MediaCell mode, attempt retry if we haven't exceeded max retries
            if retryCount < 3 {
                print("DEBUG: [VIDEO ERROR] MediaCell mode, attempting retry for \(mid)")
                retryLoad()
            } else {
                print("DEBUG: [VIDEO ERROR] Max retries exceeded for \(mid), video will remain in failed state")
            }
        }
    }
    
    private func handleVideoFinished() {
        if !disableAutoRestart {
            player?.seek(to: .zero)
            player?.play()
        } else {
            hasFinishedPlaying = true
        }
        
        onVideoFinished?()
    }
    
    private func restoreCachedVideoState() {
        // Check if we have a cached state
        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            print("DEBUG: [VIDEO CACHE] Restoring cached video state for \(mid)")
            restoreFromCache(cachedState)
        }
    }
    
    private func checkPlaybackConditions(autoPlay: Bool, isVisible: Bool) {
        // Validate player state before attempting playback
        if let player = player, let playerItem = player.currentItem {
            if playerItem.status == .failed {
                print("DEBUG: [VIDEO VALIDATION] Player item is in failed state for \(mid), triggering recovery")
                handleLoadFailure()
                return
            }
        }
        
        // Check if all conditions are met for autoplay
        if autoPlay && isVisible && player != nil && !isLoading && shouldLoadVideo {
            // Activate audio session for video playback
            AudioSessionManager.shared.activateForVideoPlayback()
            
            if hasFinishedPlaying {
                if !disableAutoRestart {
                    // Reset to beginning and play
                    player?.seek(to: .zero)
                    hasFinishedPlaying = false
                    player?.play()
                } else {
                    // Don't restart, keep the finished state
                }
            } else {
                player?.play()
            }
        }
    }
    
    private func retryLoad() {
        guard retryCount < 3 else {
            print("DEBUG: [VIDEO RETRY] Max retry count reached for \(mid)")
            return
        }
        
        print("DEBUG: [VIDEO RETRY] Attempting retry \(retryCount + 1) for \(mid)")
        
        // FIRST: Clear all caches immediately
        SharedAssetCache.shared.removeInvalidPlayer(for: url)
        VideoStateCache.shared.clearCache(for: mid)
        
        // Clear asset cache to force fresh network request - do this asynchronously
        Task.detached {
            await MainActor.run {
                SharedAssetCache.shared.clearAssetCache(for: url)
                print("DEBUG: [VIDEO RETRY] Cleared all caches for \(mid)")
            }
        }
        
        // THEN: Reset state and retry
        retryCount += 1
        loadFailed = false
        isLoading = true
        hasFinishedPlaying = false
        
        // Only setup player if loading is enabled
        if shouldLoadVideo {
            setupPlayer()
        }
    }
    
    private func handleManualReset() {
        print("DEBUG: [VIDEO MANUAL RESET] Manual reset triggered for \(mid)")
        
        // Clear all caches immediately
        SharedAssetCache.shared.removeInvalidPlayer(for: url)
        VideoStateCache.shared.clearCache(for: mid)
        
        // Clear asset cache to force fresh network request - do this asynchronously
        Task.detached {
            await MainActor.run {
                SharedAssetCache.shared.clearAssetCache(for: url)
                print("DEBUG: [VIDEO MANUAL RESET] Cleared all caches for \(mid)")
            }
        }
        
        // Reset all state and retry
        retryCount = 0
        loadFailed = false
        isLoading = true
        hasFinishedPlaying = false
        
        // Only setup player if loading is enabled
        if shouldLoadVideo {
            setupPlayer()
        }
    }
    
    private func handleNetworkRecovery() {
        print("DEBUG: [VIDEO NETWORK RECOVERY] Network recovered, attempting to reload video: \(mid)")
        
        // Reset retry count to allow fresh attempts
        retryCount = 0
        loadFailed = false
        isLoading = true
        
        // Clear caches to force fresh network request
        SharedAssetCache.shared.removeInvalidPlayer(for: url)
        VideoStateCache.shared.clearCache(for: mid)
        
        // Clear asset cache asynchronously
        Task.detached {
            await MainActor.run {
                SharedAssetCache.shared.clearAssetCache(for: url)
                print("DEBUG: [VIDEO NETWORK RECOVERY] Cleared all caches for \(mid)")
            }
        }
        
        // Attempt to reload the video
        if shouldLoadVideo {
            setupPlayer()
        }
    }
    
    private func handleLoadingStateChange(newShouldLoadVideo: Bool) {
        print("DEBUG: [VIDEO LOADING STATE] Loading state changed to \(newShouldLoadVideo) for \(mid)")
        
        if newShouldLoadVideo {
            // Loading enabled - set up player if conditions are met
            if player == nil && isVisible {
                print("DEBUG: [VIDEO SETUP] Loading enabled, setting up player for \(mid)")
                setupPlayer()
            }
        } else {
            // Loading disabled - cancel any ongoing setup and pause player
            print("DEBUG: [VIDEO SETUP] Loading disabled, cancelling setup for \(mid)")
            player?.pause()
        }
    }
    
    private func cancelVideoLoading() {
        print("DEBUG: [VIDEO CANCELLATION] Cancelling video loading for \(mid)")
        
        // Pause the player immediately
        player?.pause()
        
        // Cancel any ongoing loading tasks in SharedAssetCache
        SharedAssetCache.shared.cancelLoadingForTweet(mid)
        
        // Clear loading state
        isLoading = false
        loadFailed = false
        
        // Reset retry count
        retryCount = 0
        
        // Clear cached state
        VideoStateCache.shared.clearCache(for: mid)
        
        print("DEBUG: [VIDEO CANCELLATION] Video cancellation completed for \(mid)")
    }
    
    private func handleBackgroundRecovery() {
        print("DEBUG: [VIDEO BACKGROUND RECOVERY] Attempting background recovery for \(mid)")
        
        // Reset retry count to allow fresh attempts
        retryCount = 0
        loadFailed = false
        isLoading = true
        
        // Clear the current player since it's invalid
        player = nil
        
        // Clear caches to force fresh network request
        SharedAssetCache.shared.removeInvalidPlayer(for: url)
        VideoStateCache.shared.clearCache(for: mid)
        
        Task {
            await MainActor.run {
                SharedAssetCache.shared.clearAssetCache(for: url)
                print("DEBUG: [VIDEO BACKGROUND RECOVERY] Cleared all caches for \(mid)")
            }
        }
        
        // Attempt to reload the video
        if shouldLoadVideo {
            setupPlayer()
        }
    }
    
    private func detachPlayerForBackground() {
        guard let player = player else { 
            print("DEBUG: [VIDEO DETACH] No player available for \(mid)")
            return 
        }
        
        print("DEBUG: [VIDEO DETACH] Detaching player for background for \(mid)")
        
        // Store current state before detaching
        let wasPlaying = player.rate > 0
        let currentTime = player.currentTime()
        
        // Cache the state for restoration
        VideoStateCache.shared.cacheVideoState(
            for: mid,
            player: player,
            time: currentTime,
            wasPlaying: wasPlaying,
            originalMuteState: mode == .mediaCell ? isMuted : MuteState.shared.isMuted
        )
        
        // Pause the player first
        player.pause()
        
        // Mark as detached - this prevents the video layer from becoming invalid
        isPlayerDetached = true
        
        print("DEBUG: [VIDEO DETACH] Player detached for \(mid), wasPlaying: \(wasPlaying)")
    }
    
    private func reattachPlayerForForeground() {
        guard let player = player else { 
            print("DEBUG: [VIDEO REATTACH] No player available for \(mid)")
            return 
        }
        
        print("DEBUG: [VIDEO REATTACH] Reattaching player for foreground for \(mid)")
        
        // Mark as reattached
        isPlayerDetached = false
        
        // Get cached state if available
        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            print("DEBUG: [VIDEO REATTACH] Restoring cached state for \(mid)")
            
            // Restore mute state
            if mode == .mediaCell {
                player.isMuted = MuteState.shared.isMuted
            } else if mode == .mediaBrowser {
                player.isMuted = false
            }
            
            // Seek to cached position
            player.seek(to: cachedState.time) { finished in
                if finished {
                    print("DEBUG: [VIDEO REATTACH] Seek completed for \(self.mid)")
                    
                    // Resume playback if it was playing and conditions are met
                    if cachedState.wasPlaying && self.isVisible && self.currentAutoPlay && self.shouldLoadVideo {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            print("DEBUG: [VIDEO REATTACH] Resuming playback for \(self.mid)")
                            player.play()
                        }
                    }
                }
            }
        } else {
            print("DEBUG: [VIDEO REATTACH] No cached state found for \(mid)")
        }
        
        print("DEBUG: [VIDEO REATTACH] Player reattached for \(mid)")
    }
}

// MARK: - Video Layer Refresh View
struct VideoLayerRefreshView: UIViewRepresentable {
    let player: AVPlayer
    let mid: String
    let instanceId: String
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        
        // Set up notification observer for app foreground
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Note: refreshVideoLayer is not called here to avoid retain cycles
            // The main refresh logic is handled in the parent SimpleVideoPlayer
        }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // This view is used to access the underlying video layer for refresh
    }
    
    func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        // Clean up observers when view is dismantled
        NotificationCenter.default.removeObserver(uiView)
    }
}

// MARK: - AVPlayerViewController Wrapper for Full Screen
struct AVPlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer?
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .black
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
    }
}
