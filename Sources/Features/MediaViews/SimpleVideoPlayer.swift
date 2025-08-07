//
//  SimpleVideoPlayer.swift
//  Tweet
//
//  A simpler video player implementation with HLS support only
//

import SwiftUI
import AVKit
import AVFoundation

// Global mute state
class MuteState: ObservableObject {
    static let shared = MuteState()
    @Published var isMuted: Bool = true // Default to muted
    
    private init() {
        // Initialize from saved preference
        refreshFromPreferences()
    }
    
    func refreshFromPreferences() {
        // Read the current preference and update the published property
        let savedMuteState = HproseInstance.shared.preferenceHelper?.getSpeakerMute() ?? true
        if self.isMuted != savedMuteState {
            self.isMuted = savedMuteState
        }
    }
    
    func toggleMute() {
        isMuted.toggle()
        // Save to preferences immediately when mute state changes
        HproseInstance.shared.preferenceHelper?.setSpeakerMute(isMuted)
        print("DEBUG: [MUTE STATE] Mute state changed to: \(isMuted)")
    }
    
    func setMuted(_ muted: Bool) {
        if self.isMuted != muted {
            self.isMuted = muted
            // Save to preferences immediately when mute state changes
            HproseInstance.shared.preferenceHelper?.setSpeakerMute(isMuted)
            print("DEBUG: [MUTE STATE] Mute state set to: \(isMuted)")
        }
    }
}

struct SimpleVideoPlayer: View {
    let url: URL
    let mid: String
    var autoPlay: Bool = true
    var onTimeUpdate: ((Double) -> Void)? = nil
    var onMuteChanged: ((Bool) -> Void)? = nil
    var onVideoFinished: (() -> Void)? = nil
    let isVisible: Bool
    var contentType: String? = nil
    var cellAspectRatio: CGFloat? = nil
    var videoAspectRatio: CGFloat? = nil
    var showNativeControls: Bool = true
    var forceUnmuted: Bool = false // Force unmuted state (for full-screen mode)
    var onVideoTap: (() -> Void)? = nil // Callback when video is tapped
    var showCustomControls: Bool = true // Whether to show custom video controls
    var forcePlay: Bool = false // Force play regardless of video manager (for full-screen)
    var disableAutoRestart: Bool = false // Disable auto-restart when video finishes
    
    // New unified mode parameter
    enum Mode {
        case mediaCell // Normal cell in feed/grid
        case mediaBrowser // In MediaBrowserView (fullscreen browser)
        case fullscreen // Direct fullscreen mode
    }
    var mode: Mode = .mediaCell
    
    @EnvironmentObject var muteState: MuteState
    
    // Initializer with all parameters
    init(
        url: URL,
        mid: String,
        autoPlay: Bool = true,
        onTimeUpdate: ((Double) -> Void)? = nil,
        onMuteChanged: ((Bool) -> Void)? = nil,
        onVideoFinished: (() -> Void)? = nil,
        isVisible: Bool = true,
        contentType: String? = nil,
        cellAspectRatio: CGFloat? = nil,
        videoAspectRatio: CGFloat? = nil,
        showNativeControls: Bool = true,
        forceUnmuted: Bool = false,
        onVideoTap: (() -> Void)? = nil,
        showCustomControls: Bool = true,
        forcePlay: Bool = false,
        disableAutoRestart: Bool = false,
        mode: Mode = .mediaCell
    ) {
        self.url = url
        self.mid = mid
        self.autoPlay = autoPlay
        self.onTimeUpdate = onTimeUpdate
        self.onMuteChanged = onMuteChanged
        self.onVideoFinished = onVideoFinished
        self.isVisible = isVisible
        self.contentType = contentType
        self.cellAspectRatio = cellAspectRatio
        self.videoAspectRatio = videoAspectRatio
        self.showNativeControls = showNativeControls
        self.forceUnmuted = forceUnmuted
        self.onVideoTap = onVideoTap
        self.showCustomControls = showCustomControls
        self.forcePlay = forcePlay
        self.disableAutoRestart = disableAutoRestart
        self.mode = mode
    }
    
    // Use different cache key based on mode to isolate different use cases
    private var cacheKey: String {
        switch mode {
        case .mediaCell:
            return mid
        case .mediaBrowser:
            return "\(mid)_browser"
        case .fullscreen:
            return "\(mid)_fullscreen"
        }
    }
    
    // Determine if video is portrait or landscape
    private var isVideoPortrait: Bool {
        guard let videoAR = videoAspectRatio, videoAR > 0 else { return false }
        return videoAR < 1.0
    }
    
    // Determine if video is landscape
    private var isVideoLandscape: Bool {
        guard let videoAR = videoAspectRatio, videoAR > 0 else { return false }
        return videoAR > 1.0
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
                            HLSDirectoryVideoPlayer(
                                baseURL: url,
                                mid: cacheKey,
                                isVisible: isVisible,
                                isMuted: muteState.isMuted, // Use global mute state
                                autoPlay: autoPlay,
                                onMuteChanged: onMuteChanged,
                                onVideoFinished: onVideoFinished,
                                onVideoTap: onVideoTap,
                                showCustomControls: false, // No custom controls in cells
                                forcePlay: false, // Don't force play in cells
                                forceUnmuted: false, // Use global mute state
                                disableAutoRestart: disableAutoRestart
                            )
                            .offset(y: -pad)    // align the video vertically in the middle
                            .aspectRatio(videoAR, contentMode: .fill)
                        }
                    } else {
                        // Fallback when no cellAspectRatio is available
                        HLSDirectoryVideoPlayer(
                            baseURL: url,
                            mid: cacheKey,
                            isVisible: isVisible,
                            isMuted: muteState.isMuted,
                            autoPlay: autoPlay,
                            onMuteChanged: onMuteChanged,
                            onVideoFinished: onVideoFinished,
                            onVideoTap: onVideoTap,
                            showCustomControls: false,
                            forcePlay: false,
                            forceUnmuted: false,
                            disableAutoRestart: disableAutoRestart
                        )
                        .aspectRatio(videoAR, contentMode: .fit)
                    }
                    
                case .mediaBrowser:
                    // MediaBrowser mode: fullscreen browser with custom controls
                    HLSDirectoryVideoPlayer(
                        baseURL: url,
                        mid: cacheKey,
                        isVisible: isVisible,
                        isMuted: false, // Always unmuted in browser
                        autoPlay: autoPlay,
                        onMuteChanged: onMuteChanged,
                        onVideoFinished: onVideoFinished,
                        onVideoTap: onVideoTap,
                        showCustomControls: true, // Show custom controls
                        forcePlay: forcePlay, // Use forcePlay parameter
                        forceUnmuted: true, // Force unmuted in browser
                        disableAutoRestart: disableAutoRestart
                    )
                    .aspectRatio(videoAR, contentMode: .fit)
                    .frame(maxWidth: screenWidth, maxHeight: screenHeight)
                    
                case .fullscreen:
                    // Fullscreen mode: direct fullscreen with orientation handling
                    if isVideoPortrait {
                        // Portrait video: fit on full screen
                        ZStack {
                            HLSDirectoryVideoPlayer(
                                baseURL: url,
                                mid: cacheKey,
                                isVisible: isVisible,
                                isMuted: false, // Always unmuted in fullscreen
                                autoPlay: autoPlay,
                                onMuteChanged: onMuteChanged,
                                onVideoFinished: onVideoFinished,
                                onVideoTap: onVideoTap,
                                showCustomControls: true,
                                forcePlay: true, // Always force play in fullscreen
                                forceUnmuted: true,
                                disableAutoRestart: disableAutoRestart
                            )
                            .aspectRatio(videoAR, contentMode: .fit)
                            .frame(maxWidth: screenWidth, maxHeight: screenHeight)
                        }
                        .onAppear {
                            // Lock screen orientation to portrait and keep screen on
                            OrientationManager.shared.lockToPortrait()
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                        .onDisappear {
                            // Re-enable screen rotation and allow screen to sleep
                            OrientationManager.shared.unlockOrientation()
                            UIApplication.shared.isIdleTimerDisabled = false
                        }
                    } else if isVideoLandscape {
                        // Landscape video: rotate -90 degrees to fit on portrait device
                        ZStack {
                            HLSDirectoryVideoPlayer(
                                baseURL: url,
                                mid: cacheKey,
                                isVisible: isVisible,
                                isMuted: false,
                                autoPlay: autoPlay,
                                onMuteChanged: onMuteChanged,
                                onVideoFinished: onVideoFinished,
                                onVideoTap: onVideoTap,
                                showCustomControls: true,
                                forcePlay: true,
                                forceUnmuted: true,
                                disableAutoRestart: disableAutoRestart
                            )
                            .aspectRatio(videoAR, contentMode: .fit)
                            .frame(maxWidth: screenWidth - 2, maxHeight: screenHeight - 2)
                            .rotationEffect(.degrees(-90))
                            .scaleEffect(screenHeight / screenWidth)
                            .background(Color.black)
                        }
                        .onAppear {
                            OrientationManager.shared.lockToPortrait()
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                        .onDisappear {
                            OrientationManager.shared.unlockOrientation()
                            UIApplication.shared.isIdleTimerDisabled = false
                        }
                    } else {
                        // Square video: fit on full screen
                        ZStack {
                            HLSDirectoryVideoPlayer(
                                baseURL: url,
                                mid: cacheKey,
                                isVisible: isVisible,
                                isMuted: false,
                                autoPlay: autoPlay,
                                onMuteChanged: onMuteChanged,
                                onVideoFinished: onVideoFinished,
                                onVideoTap: onVideoTap,
                                showCustomControls: true,
                                forcePlay: true,
                                forceUnmuted: true,
                                disableAutoRestart: disableAutoRestart
                            )
                            .aspectRatio(1.0, contentMode: .fit)
                            .frame(maxWidth: screenWidth, maxHeight: screenHeight)
                        }
                        .onAppear {
                            OrientationManager.shared.lockToPortrait()
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                        .onDisappear {
                            OrientationManager.shared.unlockOrientation()
                            UIApplication.shared.isIdleTimerDisabled = false
                        }
                    }
                }
            } else {
                // Fallback when no aspect ratio is available
                HLSDirectoryVideoPlayer(
                    baseURL: url,
                    mid: cacheKey,
                    isVisible: isVisible,
                    isMuted: mode == .mediaCell ? muteState.isMuted : false,
                    autoPlay: autoPlay,
                    onMuteChanged: onMuteChanged,
                    onVideoFinished: onVideoFinished,
                    onVideoTap: onVideoTap,
                    showCustomControls: mode != .mediaCell,
                    forcePlay: mode == .fullscreen,
                    forceUnmuted: mode != .mediaCell,
                    disableAutoRestart: disableAutoRestart
                )
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .frame(maxWidth: screenWidth, maxHeight: screenHeight)
            }
        }
    }
}

@available(iOS 16.0, *)
struct HLSVideoPlayerWithControls: View {
    let videoURL: URL
    let mid: String // Add mid field for caching
    let isVisible: Bool
    let isMuted: Bool
    let autoPlay: Bool
    let onMuteChanged: ((Bool) -> Void)?
    let onVideoFinished: (() -> Void)?
    let onVideoTap: (() -> Void)?
    let showCustomControls: Bool
    let forcePlay: Bool
    let forceUnmuted: Bool
    let disableAutoRestart: Bool
    let isHLS: Bool // Whether this is an HLS video or regular video
    
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var showControls = true
    @State private var playerMuted: Bool = false
    @State private var controlsTimer: Timer?
    @State private var hasNotifiedFinished = false
    @State private var hasFinished = false // Track if video has finished to prevent re-queuing
    @State private var localMuted: Bool = false // Local mute state for forceUnmuted mode
    @State private var isSettingUpPlayer = false // Flag to prevent mute state changes during setup

    @StateObject private var muteState = MuteState.shared
    @StateObject private var videoCache = VideoCacheManager.shared
    
    init(videoURL: URL, mid: String, isVisible: Bool, isMuted: Bool, autoPlay: Bool, onMuteChanged: ((Bool) -> Void)?, onVideoFinished: (() -> Void)?, onVideoTap: (() -> Void)?, showCustomControls: Bool, forcePlay: Bool, forceUnmuted: Bool, disableAutoRestart: Bool = false, isHLS: Bool = true) {
        self.videoURL = videoURL
        self.mid = mid
        self.isVisible = isVisible
        self.isMuted = isMuted
        self.autoPlay = autoPlay
        self.onMuteChanged = onMuteChanged
        self.onVideoFinished = onVideoFinished
        self.onVideoTap = onVideoTap
        self.showCustomControls = showCustomControls
        self.forcePlay = forcePlay
        self.forceUnmuted = forceUnmuted
        self.disableAutoRestart = disableAutoRestart
        self.isHLS = isHLS
        self._playerMuted = State(initialValue: isMuted)
        

    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let player = player {
                    VideoPlayer(player: player)
                        .overlay(
                            // Transparent overlay to capture taps when custom controls are disabled
                            Group {
                                if !showCustomControls {
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            onVideoTap?()
                                        }
                                }
                            }
                        )
                        .overlay(
                            // Custom controls overlay - only show if showCustomControls is true
                            Group {
                                if showControls && showCustomControls {
                                    VStack {
                                        Spacer()
                                        HStack {
                                            Button(action: togglePlayPause) {
                                                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                                    .font(.title)
                                                    .foregroundColor(.white)
                                                    .background(Circle().fill(Color.black.opacity(0.5)))
                                            }
                                            
                                            Spacer()
                                            
                                            // Mute/Unmute button
                                            Button(action: {
                                                if forceUnmuted {
                                                    // Use local mute state for full-screen mode
                                                    localMuted.toggle()
                                                    videoCache.setMuteState(for: mid, isMuted: localMuted)
                                                    playerMuted = localMuted
                                                    // Local mute state changed (forceUnmuted mode)
                                                } else {
                                                    // Use global mute state for MediaCell
                                                    muteState.toggleMute()
                                                }
                                            }) {
                                                Image(systemName: (forceUnmuted ? localMuted : muteState.isMuted) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                                    .font(.title2)
                                                    .foregroundColor(.white)
                                                    .background(Circle().fill(Color.black.opacity(0.5)))
                                            }
                                            
                                            Spacer()
                                            
                                            Text(formatTime(currentTime))
                                                .foregroundColor(.white)
                                                .font(.caption)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.black.opacity(0.5))
                                                .cornerRadius(4)
                                            
                                            Text("/")
                                                .foregroundColor(.white)
                                                .font(.caption)
                                            
                                            Text(formatTime(duration))
                                                .foregroundColor(.white)
                                                .font(.caption)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.black.opacity(0.5))
                                                .cornerRadius(4)
                                        }
                                        .padding()
                                    }
                                    .background(
                                        LinearGradient(
                                            gradient: Gradient(colors: [Color.black.opacity(0.7), Color.clear]),
                                            startPoint: .bottom,
                                            endPoint: .top
                                        )
                                    )
                                }
                            }
                        )
                        .onReceive(player.publisher(for: \.isMuted)) { muted in
                            // Skip if we're in the middle of setting up the player
                            if isSettingUpPlayer {
                                return
                            }
                            
                            // This automatically updates when the user interacts with native controls
                            if playerMuted != muted {
                                playerMuted = muted
                                
                                if forceUnmuted {
                                    // Update local mute state for full-screen mode
                                    localMuted = muted
                                } else {
                                    // For MediaCell videos, sync with global mute state when user interacts with native controls
                                    // Only update if this is a user-initiated change, not a programmatic one
                                    if muteState.isMuted != muted {
                                        muteState.setMuted(muted)
                                    }
                                }
                            }
                        }
                } else if isLoading {
                    VStack {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(LocalizedStringKey(isHLS ? "Loading HLS stream..." : "Loading video..."))
                            .font(.caption)
                            .foregroundColor(.themeSecondaryText)
                    }
                } else if let errorMessage = errorMessage {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.red)
                        Text(LocalizedStringKey(isHLS ? "HLS Playback Error" : "Video Playback Error"))
                            .font(.headline)
                        Text(errorMessage)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .padding()
                        Button("Reload") {
                            setupPlayer()
                        }
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }
            }
            .contentShape(Rectangle()) // Make entire area tappable
            .onTapGesture {
                // Only handle tap if custom controls are enabled
                if showCustomControls {
                    // Check if video is at the end and restart if needed
                    if duration > 0 && currentTime >= duration - 0.5 {
                        resetVideoState()
                        // Start playing again
                        if let player = player {
                            player.play()
                            isPlaying = true
                        }
                        return
                    }
                    
                    // Toggle controls
                    withAnimation {
                        showControls.toggle()
                    }
                    
                    // Start timer to auto-hide controls after 3 seconds
                    if showControls {
                        startControlsTimer()
                    } else {
                        stopControlsTimer()
                    }
                    
                    // If player is paused and we tap, also resume playback
                    if let player = player, player.rate == 0 {
                        player.play()
                        isPlaying = true
                    }
                }
                // Note: onVideoTap is now handled by the transparent overlay when custom controls are disabled
            }
            .onLongPressGesture {
                // Manual reload on long press
                setupPlayer()
            }
            .onAppear {
        
                
                // Reset finished state when video appears in a new tweet
                // This allows the same video to be re-queued when it appears in multiple tweets
                if hasFinished {
            
                    hasFinished = false
                    hasNotifiedFinished = false
                }
                
                if player == nil {
                    setupPlayer()
                }
                
                // Start controls timer when video loads if custom controls are enabled
                if showCustomControls && showControls {
                    startControlsTimer()
                }
                
                // Do not resume or start playback here; let parent control via autoPlay
            }
            .onDisappear {
        
                
                // Stop controls timer
                stopControlsTimer()
                
                // Pause video using cache, do not destroy instance
                videoCache.pauseVideoPlayer(for: mid)
                
                // Do NOT call cleanupObservers() - keep the instance alive
                // Only remove notification observers, keep the player instance
                NotificationCenter.default.removeObserver(self)
            }
            .onChange(of: isVisible) { newVisibility in
                // Pause video when it becomes invisible
                if !newVisibility {
                    videoCache.pauseVideoPlayer(for: mid)
                    isPlaying = false
                }
            }
            .onChange(of: muteState.isMuted) { newMuteState in
                // Update player mute state when global mute state changes
                // Only update if not in forceUnmuted mode
                if !forceUnmuted {
                    videoCache.setMuteState(for: mid, isMuted: newMuteState)
                    playerMuted = newMuteState
                }
            }
            .onChange(of: autoPlay) { newAutoPlay in
                // Handle autoPlay parameter changes
                if newAutoPlay && isVisible && !isPlaying {
                    // AutoPlay was enabled and video is visible but not playing - start playback
                    if let player = player {
                        player.play()
                        isPlaying = true
                    }
                } else if !newAutoPlay && isPlaying {
                    // AutoPlay was disabled and video is playing - pause playback
                    if let player = player {
                        player.pause()
                        isPlaying = false
                    }
                }
            }
        }
    }
    
    private func setupPlayer() {

        
        isSettingUpPlayer = true // Prevent mute state changes during setup
        isLoading = true
        errorMessage = nil
        hasNotifiedFinished = false
        
        // Try to get cached player first
        if let cachedPlayer = videoCache.getVideoPlayer(for: mid, url: videoURL, isHLS: isHLS) {

            self.player = cachedPlayer
            
            // Set initial mute state
            if forceUnmuted {
                // For full-screen mode, start unmuted and use local state
                cachedPlayer.isMuted = false
                localMuted = false
                playerMuted = false
                // Fullscreen video - muted: false
            } else {
                // For normal mode, use global mute state
                cachedPlayer.isMuted = muteState.isMuted
                playerMuted = muteState.isMuted
            }
            
            // Set up observers for the player
            setupPlayerObservers(cachedPlayer)
            
            // Monitor player item status
            self.monitorPlayerStatus(cachedPlayer)
            
            // Handle auto-play logic
            handleAutoPlay(cachedPlayer)
            
            isSettingUpPlayer = false // Allow mute state changes after setup
            // Player setup complete
        } else {
            // Failed to get or create player for video mid: \(mid)
            errorMessage = "Failed to create video player"
            isLoading = false
            isSettingUpPlayer = false // Clear flag on error
        }
    }
    
    private func setupPlayerObservers(_ player: AVPlayer) {
        // Add periodic time observer for progress updates
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { time in
            currentTime = time.seconds
            
            // Check if video has finished
            if duration > 0 && currentTime >= duration - 0.5 && !hasNotifiedFinished {
                hasNotifiedFinished = true
                hasFinished = true // Mark video as finished
                self.resetVideoState()
                self.onVideoFinished?()
            }
        }
        
        // Add notification observer for video finished
        if let playerItem = player.currentItem {
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { _ in
                if !self.hasNotifiedFinished {
                    self.hasNotifiedFinished = true
                    self.hasFinished = true // Mark video as finished
                    self.resetVideoState()
                    self.onVideoFinished?()
                }
            }
        }
    }
    
    private func handleAutoPlay(_ player: AVPlayer) {
        // Only play if autoPlay is true and video is visible
        if autoPlay && isVisible {
            if self.forcePlay {
                // Force play mode (for full-screen) - start this video and stop others
                player.play()
                self.isPlaying = true
                
                // Pause all other videos when force play is enabled
                pauseAllOtherVideos()
            } else {
                // Normal auto-play mode - only play if visible
                player.play()
                self.isPlaying = true
            }
        } else {
            self.isPlaying = false
        }
    }
    
    /// Pause all other videos when force play is enabled
    private func pauseAllOtherVideos() {
        if forcePlay {
            // Pause all other videos except this one when force play is enabled
            VideoCacheManager.shared.pauseAllVideosExcept(for: mid)
        }
    }
    
    private func monitorPlayerStatus(_ player: AVPlayer) {
        // Monitor player item status using a timer
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            guard let playerItem = player.currentItem else {
                print("DEBUG: No player item available")
                timer.invalidate()
                return
            }
            
            switch playerItem.status {
            case .readyToPlay:
                self.isLoading = false
                self.duration = playerItem.duration.seconds
                
                // Handle auto-play when player is ready
                self.handleAutoPlay(player)
                
                timer.invalidate()
            case .failed:
                print("DEBUG: \(isHLS ? "HLS" : "Regular") player item failed: \(playerItem.error?.localizedDescription ?? "Unknown error")")
                if let error = playerItem.error as NSError? {
                    print("DEBUG: Error domain: \(error.domain), code: \(error.code)")
                    print("DEBUG: Error user info: \(error.userInfo)")
                    
                    // Provide specific error messages based on error codes
                    switch (error.domain, error.code) {
                    case ("CoreMediaErrorDomain", -12642):
                        print("DEBUG: Playlist parse error - invalid HLS manifest format")
                        self.errorMessage = isHLS ? "Invalid HLS playlist format" : "Invalid video format"
                    case ("CoreMediaErrorDomain", -12643):
                        print("DEBUG: Segment not found error")
                        self.errorMessage = isHLS ? "HLS segment not found" : "Video segment not found"
                    case ("CoreMediaErrorDomain", -12644):
                        print("DEBUG: Segment duration error")
                        self.errorMessage = isHLS ? "HLS segment duration error" : "Video duration error"
                    case ("CoreMediaErrorDomain", -12645):
                        print("DEBUG: Codec not supported error")
                        self.errorMessage = "Video codec not supported by this device"
                    case ("CoreMediaErrorDomain", -12646):
                        print("DEBUG: Format not supported error")
                        self.errorMessage = "Video format not supported by this device"
                    case ("CoreMediaErrorDomain", -12647):
                        print("DEBUG: Profile not supported error")
                        self.errorMessage = "Video profile not supported by this device"
                    case ("NSURLErrorDomain", 404):
                        print("DEBUG: \(isHLS ? "HLS playlist" : "Video file") not found (404)")
                        self.errorMessage = isHLS ? "HLS playlist not found" : "Video file not found"
                    case ("NSURLErrorDomain", 403):
                        print("DEBUG: \(isHLS ? "HLS playlist" : "Video file") access denied (403)")
                        self.errorMessage = isHLS ? "HLS playlist access denied" : "Video file access denied"
                    case ("NSURLErrorDomain", 500):
                        print("DEBUG: \(isHLS ? "HLS server" : "Video server") error (500)")
                        self.errorMessage = isHLS ? "HLS server error" : "Video server error"
                    default:
                        print("DEBUG: Unknown \(isHLS ? "HLS" : "video") error")
                        // Check for common codec compatibility issues
                        if error.localizedDescription.contains("codec") || 
                           error.localizedDescription.contains("format") ||
                           error.localizedDescription.contains("profile") ||
                           error.localizedDescription.contains("hardware") {
                            self.errorMessage = "Video codec not compatible with this device. Please try uploading a different video format."
                        } else {
                            self.errorMessage = "\(isHLS ? "HLS" : "Video") playback error: \(error.localizedDescription)"
                        }
                    }
                }
                self.isLoading = false
                timer.invalidate()
            case .unknown:
//                print("DEBUG: HLS player item status is unknown")
                break
            @unknown default:
                break
            }
        }
    }
    
    private func togglePlayPause() {
        guard let player = player else { return }
        
        // Check if video is at the end and reset if needed
        if duration > 0 && currentTime >= duration - 0.5 {
            resetVideoState()
            return
        }
        
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }
    
    private func seekTo(_ time: Double) {
        guard let player = player else { return }
        let cmTime = CMTime(seconds: time, preferredTimescale: 1)
        player.seek(to: cmTime)
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func startControlsTimer() {
        stopControlsTimer() // Cancel any existing timer
        
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            withAnimation {
                showControls = false
            }
        }
    }
    
    private func stopControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = nil
    }
    
    private func resetVideoState() {
        // Reset all video state when video finishes
        isPlaying = false
        currentTime = 0
        hasNotifiedFinished = false
        hasFinished = false // Reset finished flag when video is restarted
        showControls = true // Show controls when video finishes
        
        // Only reset player to beginning if auto-restart is not disabled
        if !disableAutoRestart {
            // Reset player to beginning using cache
            videoCache.resetVideoPlayer(for: mid)
            
            // Update local player reference if needed
            if let player = player {
                // Preserve the mute state when resetting
                if forceUnmuted {
                    player.isMuted = localMuted
                } else {
                    player.isMuted = muteState.isMuted
                }
            }
        }
        
        // Start controls timer to auto-hide controls
        if showCustomControls {
            startControlsTimer()
        }
    }
    
    private func cleanupObservers() {
        // Remove all observers
        NotificationCenter.default.removeObserver(self)
        
        // Do NOT track instance destruction - we want to keep instances alive
        // Only remove notification observers, keep the player instance
    }
    
    // Static method to get active instance count for debugging
    static func getActiveInstanceCount() -> Int {
        // This method is no longer needed as instance management is handled by VideoCacheManager
        return 0
    }
    
    // Static method to check if an instance exists for a given mid
    static func hasActiveInstance(for mid: String) -> Bool {
        // This method is no longer needed as instance management is handled by VideoCacheManager
        return false
    }
}

// Extension to easily add scroll detection to any view
extension View {
    func detectScroll() -> some View {
        self
    }
}

struct HLSDirectoryVideoPlayer: View {
    let baseURL: URL
    let mid: String // Add mid field for caching
    let isVisible: Bool
    let isMuted: Bool
    let autoPlay: Bool
    let onMuteChanged: ((Bool) -> Void)?
    let onVideoFinished: (() -> Void)?
    let onVideoTap: (() -> Void)?
    let showCustomControls: Bool
    let forcePlay: Bool
    let forceUnmuted: Bool
    let disableAutoRestart: Bool
    @State private var playlistURL: URL? = nil
    @State private var error: String? = nil
    @State private var loading = true
    @State private var didRetry = false // Track if we've retried once
    @State private var isHLSMode = true // Track if we're in HLS mode or fallback mode

    var body: some View {
        Group {
            if let playlistURL = playlistURL {
                HLSVideoPlayerWithControls(
                    videoURL: playlistURL,
                    mid: mid,
                    isVisible: isVisible,
                    isMuted: isMuted,
                    autoPlay: autoPlay,
                    onMuteChanged: onMuteChanged,
                    onVideoFinished: onVideoFinished,
                    onVideoTap: onVideoTap,
                    showCustomControls: showCustomControls,
                    forcePlay: forcePlay,
                    forceUnmuted: forceUnmuted,
                    disableAutoRestart: disableAutoRestart,
                    isHLS: isHLSMode
                )
            } else if loading {
                ProgressView("Loading video...")
            } else {
                // If loading failed after retry, show empty placeholder
                Color.clear
            }
        }
        .task {
            if playlistURL == nil && loading {
                loading = false
                if let url = await getHLSPlaylistURL(baseURL: baseURL) {
                    playlistURL = url
                    isHLSMode = true
                } else if !didRetry {
                    // Retry once after a short delay
                    didRetry = true
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                    loading = true
                } else {
                    // HLS failed, try as regular video
                    print("DEBUG: [VIDEO \(mid)] HLS playlist not found, trying as regular video")
                    playlistURL = baseURL
                    isHLSMode = false
                }
            }
        }
    }

    private func getHLSPlaylistURL(baseURL: URL) async -> URL? {
        let master = baseURL.appendingPathComponent("master.m3u8")
        let playlist = baseURL.appendingPathComponent("playlist.m3u8")
        if await urlExists(master) {
            return master
        } else if await urlExists(playlist) {
            return playlist
        } else {
            return nil
        }
    }

    private func urlExists(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
        } catch {}
        return false
    }
} 

