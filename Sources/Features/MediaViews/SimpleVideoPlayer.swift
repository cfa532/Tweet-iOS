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
    private var cache: [String: (player: AVPlayer, time: CMTime, wasPlaying: Bool)] = [:]
    
    private init() {}
    
    func cacheVideoState(for mid: String, player: AVPlayer, time: CMTime, wasPlaying: Bool) {
        print("DEBUG: [VIDEO CACHE] Caching video state for \(mid)")
        cache[mid] = (player: player, time: time, wasPlaying: wasPlaying)
    }
    
    func getCachedState(for mid: String) -> (player: AVPlayer, time: CMTime, wasPlaying: Bool)? {
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
    @State private var instanceId = UUID().uuidString.prefix(8)
    @State private var isLongPressing = false
    
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
            if player == nil {
                setupPlayer()
            }
        }
        .onDisappear {
            // Cache the current video state before pausing
            if let player = player {
                VideoStateCache.shared.cacheVideoState(
                    for: mid,
                    player: player,
                    time: player.currentTime(),
                    wasPlaying: player.rate > 0
                )
            }
            player?.pause()
        }
        .onChange(of: isMuted) { _, newMuteState in
            player?.isMuted = newMuteState
        }
        .onChange(of: currentAutoPlay) { _, shouldAutoPlay in
            // Handle autoPlay state changes (reactive to VideoManager)
            checkPlaybackConditions(autoPlay: shouldAutoPlay, isVisible: isVisible)
            if !shouldAutoPlay {
                player?.pause()
            }
        }
        .onChange(of: isVisible) { _, visible in
            // Handle visibility changes
            if visible {
                // If video failed to load and becomes visible again, retry
                if loadFailed && retryCount < 3 {
                    retryLoad()
                } else {
                    // Restore cached video state if available
                    restoreCachedVideoState()
                    checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: visible)
                }
            } else {
                // Cache the current video state before pausing
                if let player = player {
                    VideoStateCache.shared.cacheVideoState(
                        for: mid,
                        player: player,
                        time: player.currentTime(),
                        wasPlaying: player.rate > 0
                    )
                }
                player?.pause()
            }
        }
        .onChange(of: player) { _, newPlayer in
            // When player becomes available, check if we should autoplay
            if newPlayer != nil {
                checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // App returning from background - simple seek to refresh video layer
            print("DEBUG: [VIDEO FOREGROUND] App entering foreground for \(mid)")
            if isVisible && player != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.simpleVideoLayerRefresh()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // App going to background - pause all videos
            print("DEBUG: [VIDEO BACKGROUND] App entering background for \(mid)")
            player?.pause()
        }
        .onTapGesture {
            if let onVideoTap = onVideoTap {
                onVideoTap()
            }
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            isLongPressing = true
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
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundColor(.white)
                        Text("Failed to load video")
                            .foregroundColor(.white)
                            .font(.caption)
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
        
        // Check if we have a cached player first
        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            print("DEBUG: [VIDEO CACHE] Found cached player for \(mid)")
            restoreFromCache(cachedState)
            return
        }
        
        // Otherwise, create a new player
        Task {
            do {
                let newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(for: url)
                await MainActor.run {
                    configurePlayer(newPlayer)
                }
            } catch {
                await MainActor.run {
                    handleLoadFailure()
                }
            }
        }
    }
    
    private func restoreFromCache(_ cachedState: (player: AVPlayer, time: CMTime, wasPlaying: Bool)) {
        print("DEBUG: [VIDEO CACHE] Restoring from cache for \(mid)")
        
        // Restore the cached player
        self.player = cachedState.player
        
        // Seek to the cached position
        cachedState.player.seek(to: cachedState.time) { finished in
            if finished {
                // If it was playing before, resume playback
                if cachedState.wasPlaying && self.isVisible && self.currentAutoPlay {
                    cachedState.player.play()
                    print("DEBUG: [VIDEO CACHE] Resumed playback from cache for \(self.mid)")
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
    }
    
    private func restoreCachedVideoState() {
        // Check if we have a cached state
        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            print("DEBUG: [VIDEO CACHE] Restoring cached video state for \(mid)")
            restoreFromCache(cachedState)
        }
    }
    
    /// Simple video layer refresh - just a gentle seek to wake up the video layer
    private func simpleVideoLayerRefresh() {
        guard let player = player else { 
            print("DEBUG: [VIDEO REFRESH] No player available for \(mid)")
            return 
        }
        
        print("DEBUG: [VIDEO REFRESH] Simple refresh for \(mid)")
        
        // Just do a gentle seek to the current time to wake up the video layer
        let currentTime = player.currentTime()
        player.seek(to: currentTime) { finished in
            if finished {
                print("DEBUG: [VIDEO REFRESH] Successfully applied simple refresh for \(self.mid)")
            } else {
                print("DEBUG: [VIDEO REFRESH] Failed simple refresh for \(self.mid)")
            }
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
        
        setupPlayer()
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
