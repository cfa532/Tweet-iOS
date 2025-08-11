//
//  SimpleVideoPlayer.swift
//  Tweet
//
//  Consolidated video player with asset sharing
//

import SwiftUI
import AVKit
import AVFoundation

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
    var contentType: String? = nil
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
    @State private var wasPlayingBeforeBackground = false
    @State private var instanceId = UUID().uuidString.prefix(8)
    @State private var isLongPressing = false
    @State private var needsPlayerLayerRefresh = false
    
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
                    // Fullscreen mode: direct fullscreen with orientation handling
                    if isVideoPortrait {
                        // Portrait video: fit on full screen
                        ZStack {
                            videoPlayerView()
                            .aspectRatio(videoAR, contentMode: .fit)
                            .frame(maxWidth: screenWidth, maxHeight: screenHeight)
                        }
                        .onAppear {
                            // Lock screen orientation to portrait and keep screen on
                            // OrientationManager.shared.lockToPortrait()
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                        .onDisappear {
                            // Re-enable screen rotation and allow screen to sleep
                            // OrientationManager.shared.unlockOrientation()
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
                            .background(Color.black)
                        }
                        .onAppear {
                            // OrientationManager.shared.lockToPortrait()
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                        .onDisappear {
                            // OrientationManager.shared.unlockOrientation()
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
                            // OrientationManager.shared.lockToPortrait()
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                        .onDisappear {
                            // OrientationManager.shared.unlockOrientation()
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
            player?.pause()
        }
        .onChange(of: isMuted) { newMuteState in
            print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Mute state changed to: \(newMuteState)")
            player?.isMuted = newMuteState
        }
        .onChange(of: currentAutoPlay) { shouldAutoPlay in
            // Handle autoPlay state changes (reactive to VideoManager)
            print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] AutoPlay changed to: \(shouldAutoPlay), isVisible: \(isVisible), player exists: \(player != nil), isLoading: \(isLoading)")
            checkPlaybackConditions(autoPlay: shouldAutoPlay, isVisible: isVisible)
            if !shouldAutoPlay {
                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] AutoPlay changed to false - pausing playback")
                player?.pause()
            }
        }
        .onChange(of: isVisible) { visible in
            // Handle visibility changes
            print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Visibility changed to: \(visible), autoPlay: \(currentAutoPlay), player exists: \(player != nil), isLoading: \(isLoading), loadFailed: \(loadFailed)")
            
            if visible {
                // If video failed to load and becomes visible again, retry
                if loadFailed && retryCount < 3 {
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Video reappeared after failure - retrying load")
                    retryLoad()
                } else {
                    checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: visible)
                }
            } else {
                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Became invisible - pausing playback")
                player?.pause()
            }
        }
        .onChange(of: player) { newPlayer in
            // When player becomes available, check if we should autoplay
            if newPlayer != nil {
                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Player became available - checking playback conditions")
                checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // App entering background - preserve current state
            if let player = player {
                wasPlayingBeforeBackground = player.rate > 0
                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] App entering background - was playing: \(wasPlayingBeforeBackground)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // App returning from background - restore state if needed
            if wasPlayingBeforeBackground && isVisible && currentAutoPlay {
                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] App returning from background - restoring playback")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // Small delay to ensure UI is ready
                    checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Enhanced restoration when app becomes active - fix black screen issues
            print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] App became active - handling player layer refresh")
            
            // Mark that we need to refresh the player layer
            needsPlayerLayerRefresh = true
            
            // Force layout update to ensure proper frame
            DispatchQueue.main.async {
                // Trigger layout update to re-attach AVPlayerLayer
                if let player = player {
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Refreshing player layer after background")
                    
                    // Force a small seek to refresh the layer and trigger readyForDisplay
                    let currentTime = player.currentTime()
                    let seekTime = CMTimeAdd(currentTime, CMTime(seconds: 0.01, preferredTimescale: 600))
                    player.seek(to: seekTime) { finished in
                        if finished {
                            print("DEBUG: [SIMPLE VIDEO PLAYER \(self.mid):\(self.instanceId)] Player layer refreshed")
                        }
                    }
                }
            }
            
            // Start monitoring for readyForDisplay property
            startReadyForDisplayMonitoring()
            
            // Restore playback if needed
            if wasPlayingBeforeBackground && isVisible && currentAutoPlay {
                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] App became active - ensuring playback restoration")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    // Longer delay to ensure UI and player layer are ready
                    if let player = player, player.rate == 0 {
                        print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Player was paused after background - restarting")
                        checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
                    }
                }
            }
        }
        .onDisappear {
            // Clean up observers when view disappears
            if let player = player {
                NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)
                NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: player.currentItem)
                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] View disappeared - cleaned up observers")
            }
        }
    }
    
    // MARK: Private Methods
    private func checkPlaybackConditions(autoPlay: Bool, isVisible: Bool) {
        // Check if all conditions are met for autoplay
        print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Checking conditions - autoPlay: \(autoPlay), isVisible: \(isVisible), player exists: \(player != nil), isLoading: \(isLoading), hasFinished: \(hasFinishedPlaying), disableAutoRestart: \(disableAutoRestart)")
        
        if autoPlay && isVisible && player != nil && !isLoading {
            if hasFinishedPlaying {
                if !disableAutoRestart {
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Restarting finished video (auto-restart enabled)")
                    // Reset to beginning and play
                    player?.seek(to: .zero)
                    hasFinishedPlaying = false
                    player?.play()
                } else {
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Video finished but auto-restart disabled - keeping finished state")
                    // Don't restart, keep the finished state
                }
            } else {
                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] All conditions met - starting playback")
                player?.play()
            }
        } else {
            print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Conditions not met - autoPlay: \(autoPlay), isVisible: \(isVisible), player exists: \(player != nil), isLoading: \(isLoading)")
        }
    }
                    
    @ViewBuilder
    private func videoPlayerView() -> some View {
        Group {
            if let player = player {
                if showNativeControls {
                    VideoPlayer(player: player)
                        .clipped()
                        .contentShape(Rectangle())
                        .scaleEffect(isLongPressing ? 0.95 : 1.0)
                        .animation(.easeInOut(duration: 0.1), value: isLongPressing)
                        .onTapGesture {
                            onVideoTap?()
                        }
                        .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 50) {
                            print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Long press detected - reloading video")
                            retryLoad()
                        } onPressingChanged: { pressing in
                            isLongPressing = pressing
                        }
                } else {
                    VideoPlayer(player: player, videoOverlay: {
                        // Custom overlay that captures taps
                        Color.clear
                            .contentShape(Rectangle())
                            .scaleEffect(isLongPressing ? 0.95 : 1.0)
                            .animation(.easeInOut(duration: 0.1), value: isLongPressing)
                            .onTapGesture {
                                onVideoTap?()
                            }
                            .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 50) {
                                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Long press detected - reloading video")
                                retryLoad()
                            } onPressingChanged: { pressing in
                                isLongPressing = pressing
                            }
                    })
                    .clipped()
                }
            } else if isLoading {
                ProgressView("Loading video...")
                    .frame(maxWidth: .infinity, maxHeight: 200)
                    .background(Color.black.opacity(0.1))
            } else if loadFailed {
                Color.black.opacity(0.1)
                    .overlay(
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 30))
                                .foregroundColor(.white)
                            
                            Text("Failed to load video")
                                .foregroundColor(.white)
                                .font(.caption)
                            
                            if retryCount < 3 {
                                Button("Retry") {
                                    retryLoad()
                                }
                                .foregroundColor(.blue)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(8)
                            }
                        }
                    )
                    .onTapGesture {
                        if retryCount < 3 {
                            retryLoad()
                        }
                        }
                    } else {
                Color.black
                    .overlay(
                        Image(systemName: "play.circle")
                            .font(.system(size: 40))
                            .foregroundColor(.white)
                    )
            }
        }
    }
    
        private func setupPlayer() {
        Task {
            await MainActor.run {
                self.isLoading = true
                self.loadFailed = false
            }
            
            do {
                // Try to get cached player first
                if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: url) {
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Using cached player")
                    
                    // Validate cached player - only reject if explicitly failed
                    guard let playerItem = cachedPlayer.currentItem,
                          playerItem.status != .failed else {
                        print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Cached player invalid, removing")
                        SharedAssetCache.shared.removeCachedPlayer(for: url)
                        throw NSError(domain: "VideoPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid cached player"])
                    }
                    
                    await MainActor.run {
                        self.configurePlayer(cachedPlayer)
                    }
                    return
                }
                
                // Create new player
                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Creating new player")
                let newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(for: url)
                
                await MainActor.run {
                    self.configurePlayer(newPlayer)
                }
                
            } catch {
                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Setup failed: \(error)")
                await MainActor.run {
                    self.handleLoadFailure()
                }
            }
        }
    }
    
    private func configurePlayer(_ player: AVPlayer) {
        // Configure player
        print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Configuring player - setting mute to: \(isMuted)")
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
        print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Player configured - checking playback conditions")
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
            print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Video finished playing - disableAutoRestart: \(disableAutoRestart)")
            
            if !disableAutoRestart {
                // Auto-restart for fullscreen/detail contexts
                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Auto-restarting video")
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
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Video failed to play: \(error?.localizedDescription ?? "unknown error")")
            self.handleLoadFailure()
        }
    }
    

    
    private func handleLoadFailure() {
        loadFailed = true
        isLoading = false
        player = nil
        print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Load failed, retry count: \(retryCount)")
    }
    
    private func retryLoad() {
        guard retryCount < 3 else {
            print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Max retry attempts reached")
            return
        }
        
        retryCount += 1
        loadFailed = false
        isLoading = true
        hasFinishedPlaying = false
        
        print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Retrying load, attempt \(retryCount)")
        setupPlayer()
    }
    
    /// Resolve HLS URL if needed
    private func resolveHLSURL(_ url: URL) async -> URL {
        let urlString = url.absoluteString
        
        // If it's already a direct video file, return as-is
        if urlString.hasSuffix(".mp4") || urlString.hasSuffix(".m3u8") {
            return url
        }
        
        // Try to find HLS playlist files
        let masterURL = url.appendingPathComponent("master.m3u8")
        let playlistURL = url.appendingPathComponent("playlist.m3u8")
        
        // Check master.m3u8 first
        if await urlExists(masterURL) {
            return masterURL
        }
        
        // Check playlist.m3u8
        if await urlExists(playlistURL) {
            return playlistURL
        }
        
        // Fallback to original URL
        return url
    }
    
    /// Check if URL exists
    private func urlExists(_ url: URL) async -> Bool {
        do {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
            request.timeoutInterval = 15.0
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
        return false
        }
    }
    
    // MARK: - Black Screen Fix Methods
    
    /// Start monitoring for readyForDisplay property to handle black screen issues
    private func startReadyForDisplayMonitoring() {
        guard let player = player else { return }
        
        // Create a timer to check if video is displaying properly
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            // Check if we need to refresh the player layer
            if self.needsPlayerLayerRefresh {
                print("DEBUG: [SIMPLE VIDEO PLAYER \(self.mid):\(self.instanceId)] Checking for black screen issues")
                
                // If player is playing but might have black screen, try to refresh
                if player.rate > 0 && self.isVisible && self.currentAutoPlay {
                    // Force another seek to ensure the layer is properly attached
                    let currentTime = player.currentTime()
                    let seekTime = CMTimeAdd(currentTime, CMTime(seconds: 0.02, preferredTimescale: 600))
                    player.seek(to: seekTime) { finished in
                        if finished {
                            print("DEBUG: [SIMPLE VIDEO PLAYER \(self.mid):\(self.instanceId)] Additional layer refresh completed")
                        }
                    }
                }
                
                self.needsPlayerLayerRefresh = false
                timer.invalidate()
            }
        }
    }
} 
