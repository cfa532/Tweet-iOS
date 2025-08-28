//
//  SimpleVideoPlayer.swift
//  Tweet
//
//  Consolidated video player with asset sharing
//

import SwiftUI
import AVKit
import AVFoundation

// MARK: - Global Video State Cache
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
    var shouldLoadVideo: Bool = true // Whether grid-level loading is enabled
    
    // MARK: Mode
    enum Mode {
        case mediaCell // Normal cell in feed/grid
        case mediaBrowser // In MediaBrowserView (fullscreen browser)
        case fullscreen // Direct fullscreen mode
    }
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
                    videoPlayerView()
                        .aspectRatio(videoAR, contentMode: .fit)
                        .frame(maxWidth: screenWidth, maxHeight: screenHeight)
                    
                case .fullscreen:
                    // Fullscreen mode: handle different video orientations
                    if isVideoPortrait {
                        // Portrait video: fit on full screen
                        ZStack {
                            videoPlayerView()
                                .aspectRatio(videoAR, contentMode: .fit)
                                .frame(maxWidth: screenWidth, maxHeight: screenHeight)
                        }
                        .onAppear {
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                        .onDisappear {
                            UIApplication.shared.isIdleTimerDisabled = false
                        }
                    } else if isVideoLandscape {
                        // Landscape video: rotate -90 degrees to fit on portrait device
                        ZStack {
                            videoPlayerView()
                                .aspectRatio(videoAR, contentMode: .fit)
                                .frame(maxWidth: screenWidth - 2, maxHeight: screenHeight - 2)
                                .rotationEffect(.degrees(-90))
                                .scaleEffect(screenHeight / screenWidth)
                                .background(Color.gray)
                        }
                        .onAppear {
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                        .onDisappear {
                            UIApplication.shared.isIdleTimerDisabled = false
                        }
                    } else {
                        // Square video: fit on full screen
                        ZStack {
                            videoPlayerView()
                                .aspectRatio(1.0, contentMode: .fit)
                                .frame(maxWidth: screenWidth, maxHeight: screenHeight)
                        }
                        .onAppear {
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                        .onDisappear {
                            UIApplication.shared.isIdleTimerDisabled = false
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
            // Only set up player if both conditions are met
            if player == nil && shouldLoadVideo && isVisible {
                setupPlayer()
            }
        }
        .onDisappear {
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
            player?.isMuted = newMuteState
        }
        .onReceive(MuteState.shared.$isMuted) { globalMuteState in
            // For MediaCell mode, always sync with global mute state
            if mode == .mediaCell {
                player?.isMuted = globalMuteState
                print("DEBUG: [VIDEO GLOBAL MUTE] Synced with global mute state: \(globalMuteState)")
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
        .onChange(of: shouldLoadVideo) { _, newShouldLoadVideo in
            // Grid-level loading state changed - consolidate all loading decisions here
            handleLoadingStateChange(newShouldLoadVideo: newShouldLoadVideo)
        }
        
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // App going to background - pause all videos
            print("DEBUG: [VIDEO BACKGROUND] App entering background for \(mid)")
            player?.pause()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // App became active - comprehensive recovery for videos
            print("DEBUG: [VIDEO APP ACTIVE] App became active for \(mid)")
            
            // Check if player is still valid
            if let player = player {
                // Check if player item is still valid
                if player.currentItem?.status == .failed {
                    print("DEBUG: [VIDEO APP ACTIVE] Player item failed for \(mid), attempting recovery")
                    handleBackgroundRecovery()
                } else if player.currentItem?.status == .readyToPlay {
                    print("DEBUG: [VIDEO APP ACTIVE] Player is ready for \(mid)")
                    // If video is visible and should play, resume playback
                    if isVisible && currentAutoPlay && shouldLoadVideo {
                        checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
                    }
                } else {
                    print("DEBUG: [VIDEO APP ACTIVE] Player item status: \(player.currentItem?.status.rawValue ?? -1) for \(mid)")
                    // Player item might be loading, wait for it to become ready
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if isVisible && currentAutoPlay && shouldLoadVideo {
                            checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
                        }
                    }
                }
            } else {
                // No player - check if we should recreate it
                if isVisible && shouldLoadVideo {
                    print("DEBUG: [VIDEO APP ACTIVE] No player for \(mid), recreating")
                    setupPlayer()
                }
            }
            
            // Reset error state for videos that might have been interrupted
            if loadFailed {
                print("DEBUG: [VIDEO APP ACTIVE] Resetting error state for \(mid)")
                retryCount = 0
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
                // Main video player
                VideoPlayer(player: player)
                    .disabled(showNativeControls)
                    .onTapGesture {
                        if let onVideoTap = onVideoTap {
                            onVideoTap()
                        }
                        
                        // For fullscreen mode, show native controls for 2 seconds
                        if mode == .fullscreen || mode == .mediaBrowser {
                            // Note: showNativeControls is a parameter, so we can't modify it directly
                            // The native controls will be shown by the VideoPlayer component
                            print("DEBUG: [VIDEO CONTROLS] Tap detected in fullscreen mode for \(mid)")
                        }
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
        
        // Check if we have a cached player first
        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            print("DEBUG: [VIDEO CACHE] Found cached player for \(mid)")
            restoreFromCache(cachedState)
            return
        }
        
        // Otherwise, create a new player
        Task {
            do {
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
        
        // Restore the cached player
        self.player = cachedState.player
        
        // For MediaCell mode, always use the current global mute state instead of the cached one
        // This ensures videos respect the current global mute setting when returning from full screen
        if mode == .mediaCell {
            cachedState.player.isMuted = isMuted
            print("DEBUG: [VIDEO CACHE] Applied current global mute state (\(isMuted)) for MediaCell mode")
        } else {
            // For other modes, use the cached mute state
            cachedState.player.isMuted = cachedState.originalMuteState
            print("DEBUG: [VIDEO CACHE] Applied cached mute state (\(cachedState.originalMuteState)) for non-MediaCell mode")
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
        
        // Clear the cache since we've used it
        VideoStateCache.shared.clearCache(for: mid)
        
        // Update state
        self.isLoading = false
        self.loadFailed = false
        self.retryCount = 0
        self.hasFinishedPlaying = false
    }
    
    private func configurePlayer(_ player: AVPlayer) {
        // Configure player
        player.isMuted = isMuted
        
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
        
        // Start playback if needed
        checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
    }
    
    private func setupPlayerObservers(_ player: AVPlayer) {
        guard let playerItem = player.currentItem else { return }
        
        // Video finished observer
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            if !disableAutoRestart {
                // Auto-restart for fullscreen/detail contexts
                player.seek(to: .zero) { finished in
                    if finished {
                        player.play()
                    }
                }
            } else {
                // Mark as finished for MediaCell
                self.hasFinishedPlaying = true
            }
            
            // Call external callback
            if let onVideoFinished = onVideoFinished {
                onVideoFinished()
            }
        }
        
        // Error observer
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { notification in
            self.handleLoadFailure()
        }
    }
    
    private func handleLoadFailure() {
        loadFailed = true
        isLoading = false
        player = nil
        print("DEBUG: [VIDEO ERROR] Load failed for \(mid), retry count: \(retryCount)")
    }
    
    private func restoreCachedVideoState() {
        // Check if we have a cached state
        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            print("DEBUG: [VIDEO CACHE] Restoring cached video state for \(mid)")
            restoreFromCache(cachedState)
        }
    }
    
    private func checkPlaybackConditions(autoPlay: Bool, isVisible: Bool) {
        // Check if all conditions are met for autoplay
        if autoPlay && isVisible && player != nil && !isLoading {
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
        
        // Clear asset cache to force fresh network request
        Task {
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
        
        // Clear asset cache to force fresh network request
        Task {
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
        
        Task {
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
