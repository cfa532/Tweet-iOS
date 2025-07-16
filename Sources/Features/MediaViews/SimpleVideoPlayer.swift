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
    let mid: String // Add mid field for caching
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
    @EnvironmentObject var muteState: MuteState
    
    // Use different cache key for fullscreen videos to isolate them
    private var cacheKey: String {
        return forceUnmuted ? "\(mid)_fullscreen" : mid
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
                if forceUnmuted {
                    // Full-screen mode: apply new display logic
                                    if isVideoPortrait {
                    // Portrait video: fit on full screen
                    ZStack {
                        HLSDirectoryVideoPlayer(
                            baseURL: url,
                            mid: cacheKey,
                            isVisible: isVisible,
                            isMuted: forceUnmuted ? false : muteState.isMuted,
                            autoPlay: autoPlay,
                            onMuteChanged: onMuteChanged,
                            onVideoFinished: onVideoFinished,
                            onVideoTap: onVideoTap,
                            showCustomControls: showCustomControls,
                            forcePlay: forcePlay,
                            forceUnmuted: forceUnmuted
                        )
                        .aspectRatio(videoAR, contentMode: .fit)
                        .frame(maxWidth: screenWidth, maxHeight: screenHeight)
                    }
                    .onAppear {
                        if forceUnmuted {
                            // Lock screen orientation to portrait and keep screen on
                            OrientationManager.shared.lockToPortrait()
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                    }
                    .onDisappear {
                        if forceUnmuted {
                            // Re-enable screen rotation and allow screen to sleep
                            OrientationManager.shared.unlockOrientation()
                            UIApplication.shared.isIdleTimerDisabled = false
                        }
                    }
                                    } else if isVideoLandscape {
                    // Landscape video: rotate -90 degrees to fit on portrait device
                    ZStack {
                        HLSDirectoryVideoPlayer(
                            baseURL: url,
                            mid: cacheKey,
                            isVisible: isVisible,
                            isMuted: forceUnmuted ? false : muteState.isMuted,
                            autoPlay: autoPlay,
                            onMuteChanged: onMuteChanged,
                            onVideoFinished: onVideoFinished,
                            onVideoTap: onVideoTap,
                            showCustomControls: showCustomControls,
                            forcePlay: forcePlay,
                            forceUnmuted: forceUnmuted
                        )
                        .aspectRatio(videoAR, contentMode: .fit)
                        .frame(maxWidth: screenWidth - 2, maxHeight: screenHeight - 2) // Reduce size by 2 points (1 point border on each side)
                        .rotationEffect(.degrees(-90))
                        .scaleEffect(screenHeight / screenWidth) // Scale to fit the rotated video
                        .background(Color.black)
                    }
                    .onAppear {
                        if forceUnmuted {
                            // Lock screen orientation to portrait and keep screen on
                            OrientationManager.shared.lockToPortrait()
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                    }
                    .onDisappear {
                        if forceUnmuted {
                            // Re-enable screen rotation and allow screen to sleep
                            OrientationManager.shared.unlockOrientation()
                            UIApplication.shared.isIdleTimerDisabled = false
                        }
                    }
                                    } else {
                    // Square video: fit on full screen
                    ZStack {
                        HLSDirectoryVideoPlayer(
                            baseURL: url,
                            mid: cacheKey,
                            isVisible: isVisible,
                            isMuted: forceUnmuted ? false : muteState.isMuted,
                            autoPlay: autoPlay,
                            onMuteChanged: onMuteChanged,
                            onVideoFinished: onVideoFinished,
                            onVideoTap: onVideoTap,
                            showCustomControls: showCustomControls,
                            forcePlay: forcePlay,
                            forceUnmuted: forceUnmuted
                        )
                        .aspectRatio(1.0, contentMode: .fit)
                        .frame(maxWidth: screenWidth, maxHeight: screenHeight)
                    }
                    .onAppear {
                        if forceUnmuted {
                            // Lock screen orientation to portrait and keep screen on
                            OrientationManager.shared.lockToPortrait()
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                    }
                    .onDisappear {
                        if forceUnmuted {
                            // Re-enable screen rotation and allow screen to sleep
                            OrientationManager.shared.unlockOrientation()
                            UIApplication.shared.isIdleTimerDisabled = false
                        }
                    }
                    }
                } else {
                    // Normal mode: use original logic with cellAspectRatio
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
                                isMuted: forceUnmuted ? false : muteState.isMuted,
                                autoPlay: autoPlay,
                                onMuteChanged: onMuteChanged,
                                onVideoFinished: onVideoFinished,
                                onVideoTap: onVideoTap,
                                showCustomControls: showCustomControls,
                                forcePlay: forcePlay,
                                forceUnmuted: forceUnmuted
                            )
                            .offset(y: -pad)    // align the video vertically in the middle
                            .aspectRatio(videoAR, contentMode: .fill)
                        }
                    } else {
                        // Fallback when no cellAspectRatio is available
                        ZStack {
                            HLSDirectoryVideoPlayer(
                                baseURL: url,
                                mid: cacheKey,
                                isVisible: isVisible,
                                isMuted: forceUnmuted ? false : muteState.isMuted,
                                autoPlay: autoPlay,
                                onMuteChanged: onMuteChanged,
                                onVideoFinished: onVideoFinished,
                                onVideoTap: onVideoTap,
                                showCustomControls: showCustomControls,
                                forcePlay: forcePlay,
                                forceUnmuted: forceUnmuted
                            )
                            .aspectRatio(videoAR, contentMode: .fit)
                            .frame(maxWidth: screenWidth, maxHeight: screenHeight)
                        }
                    }
                }
            } else {
                // Fallback when no aspect ratio is available
                ZStack {
                    HLSDirectoryVideoPlayer(
                        baseURL: url,
                        mid: cacheKey,
                        isVisible: isVisible,
                        isMuted: forceUnmuted ? false : muteState.isMuted,
                        autoPlay: autoPlay,
                        onMuteChanged: onMuteChanged,
                        onVideoFinished: onVideoFinished,
                        onVideoTap: onVideoTap,
                        showCustomControls: showCustomControls,
                        forcePlay: forcePlay,
                        forceUnmuted: forceUnmuted
                    )
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                    .frame(maxWidth: screenWidth, maxHeight: screenHeight)
                }
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
    
    init(videoURL: URL, mid: String, isVisible: Bool, isMuted: Bool, autoPlay: Bool, onMuteChanged: ((Bool) -> Void)?, onVideoFinished: (() -> Void)?, onVideoTap: (() -> Void)?, showCustomControls: Bool, forcePlay: Bool, forceUnmuted: Bool) {
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
        self._playerMuted = State(initialValue: isMuted)
        
        print("DEBUG: [VIDEO \(mid)] HLSVideoPlayerWithControls view created for URL: \(videoURL.absoluteString)")
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let player = player {
                    VideoPlayer(player: player)
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
                                                    print("DEBUG: [VIDEO \(mid)] Local mute state changed to: \(localMuted) (forceUnmuted mode)")
                                                } else {
                                                    // Use global mute state for MediaCell
                                                    muteState.toggleMute()
                                                    print("DEBUG: [VIDEO \(mid)] Global mute state toggled to: \(muteState.isMuted)")
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
                            print("DEBUG: [VIDEO \(mid)] onReceive triggered - muted: \(muted), forceUnmuted: \(forceUnmuted)")
                            
                            // Skip if we're in the middle of setting up the player
                            if isSettingUpPlayer {
                                print("DEBUG: [VIDEO \(mid)] Skipping mute state change during player setup")
                                return
                            }
                            
                            // This automatically updates when the user interacts with native controls
                            if playerMuted != muted {
                                print("DEBUG: [VIDEO \(mid)] Player mute state changed from \(playerMuted) to \(muted)")
                                playerMuted = muted
                                
                                if forceUnmuted {
                                    // Update local mute state for full-screen mode
                                    localMuted = muted
                                    print("DEBUG: [VIDEO \(mid)] Native controls changed local mute to: \(muted) (forceUnmuted mode)")
                                } else {
                                    // For MediaCell videos, sync with global mute state when user interacts with native controls
                                    // Only update if this is a user-initiated change, not a programmatic one
                                    if muteState.isMuted != muted {
                                        print("DEBUG: [VIDEO \(mid)] Native controls changed mute to: \(muted), updating global state")
                                        muteState.setMuted(muted)
                                    }
                                }
                            }
                        }
                } else if isLoading {
                    VStack {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(LocalizedStringKey("Loading HLS stream..."))
                            .font(.caption)
                            .foregroundColor(.themeSecondaryText)
                    }
                } else if let errorMessage = errorMessage {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.red)
                        Text(LocalizedStringKey("HLS Playback Error"))
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
                
                // Only toggle controls if custom controls are enabled
                if showCustomControls {
                    withAnimation {
                        showControls.toggle()
                    }
                    
                    // Start timer to auto-hide controls after 3 seconds
                    if showControls {
                        startControlsTimer()
                    } else {
                        stopControlsTimer()
                    }
                }
                
                // If player is paused and we tap, also resume playback
                if let player = player, player.rate == 0 {
                    player.play()
                    isPlaying = true
                }
                
                // Always call the onVideoTap callback if provided
                onVideoTap?()
            }
            .onLongPressGesture {
                // Manual reload on long press
                setupPlayer()
            }
            .onAppear {
                print("DEBUG: [VIDEO \(mid)] HLSVideoPlayerWithControls onAppear - isVisible: \(isVisible)")
                
                // Reset finished state when video appears in a new tweet
                // This allows the same video to be re-queued when it appears in multiple tweets
                if hasFinished {
                    print("DEBUG: [VIDEO \(mid)] Resetting finished state for video appearing in new tweet")
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
                print("DEBUG: [VIDEO \(mid)] HLSVideoPlayerWithControls onDisappear - isVisible: \(isVisible)")
                
                // Stop controls timer
                stopControlsTimer()
                
                // Pause video using cache, do not destroy instance
                videoCache.pauseVideoPlayer(for: mid)
                
                // Do NOT call cleanupObservers() - keep the instance alive
                // Only remove notification observers, keep the player instance
                NotificationCenter.default.removeObserver(self)
            }
            .onChange(of: isVisible) { newVisibility in
                print("DEBUG: [VIDEO \(mid)] Visibility changed to: \(newVisibility)")
                
                // Pause video when it becomes invisible
                if !newVisibility {
                    print("DEBUG: [VIDEO \(mid)] Video became invisible, pausing")
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
                    print("DEBUG: [VIDEO \(mid)] Global mute state changed to: \(newMuteState) for video key: \(mid)")
                } else {
                    print("DEBUG: [VIDEO \(mid)] Ignoring global mute state change (forceUnmuted mode)")
                }
            }

        }
    }
    
    private func setupPlayer() {
        print("DEBUG: [VIDEO \(mid)] Setting up HLS player for URL: \(videoURL.absoluteString), mid: \(mid)")
        
        isSettingUpPlayer = true // Prevent mute state changes during setup
        isLoading = true
        errorMessage = nil
        hasNotifiedFinished = false
        
        // Try to get cached player first
        if let cachedPlayer = videoCache.getVideoPlayer(for: mid, url: videoURL) {
            print("DEBUG: [VIDEO \(mid)] Got cached player for video mid: \(mid)")
            self.player = cachedPlayer
            
            // Set initial mute state
            if forceUnmuted {
                // For full-screen mode, start unmuted and use local state
                cachedPlayer.isMuted = false
                localMuted = false
                playerMuted = false
                print("DEBUG: [VIDEO \(mid)] Fullscreen video - muted: false")
            } else {
                // For normal mode, use global mute state
                cachedPlayer.isMuted = muteState.isMuted
                playerMuted = muteState.isMuted
                print("DEBUG: [VIDEO \(mid)] Normal video - muted: \(muteState.isMuted)")
            }
            
            // Set up observers for the player
            setupPlayerObservers(cachedPlayer)
            
            // Monitor player item status
            self.monitorPlayerStatus(cachedPlayer)
            
            // Handle auto-play logic
            handleAutoPlay(cachedPlayer)
            
            isSettingUpPlayer = false // Allow mute state changes after setup
            print("DEBUG: [VIDEO \(mid)] Player setup complete")
        } else {
            print("DEBUG: [VIDEO \(mid)] Failed to get or create player for video mid: \(mid)")
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
                print("DEBUG: [VIDEO \(mid)] Video finished in HLSVideoPlayerWithControls")
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
                    print("DEBUG: [VIDEO \(mid)] Video finished via AVPlayerItemDidPlayToEndTime notification")
                    print("DEBUG: [VIDEO \(mid)] Video URL: \(self.videoURL.absoluteString)")
                    print("DEBUG: [VIDEO \(mid)] Final duration: \(self.duration) seconds")
                    print("DEBUG: [VIDEO \(mid)] Final current time: \(self.currentTime) seconds")
                    self.resetVideoState()
                    self.onVideoFinished?()
                }
            }
        }
    }
    
    private func handleAutoPlay(_ player: AVPlayer) {
        // Only play if autoPlay is true
        if autoPlay {
            if self.forcePlay {
                // Force play mode (for full-screen) - start this video
                player.play()
                self.isPlaying = true
            } else {
                // Normal auto-play mode
                player.play()
                self.isPlaying = true
            }
        } else {
            self.isPlaying = false
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
                print("DEBUG: [VIDEO \(mid)] HLS player item is ready to play")
                self.isLoading = false
                self.duration = playerItem.duration.seconds
                
                            // If this video should auto-play, start it
            if self.autoPlay {
                if self.forcePlay {
                    // Force play mode (for full-screen) - start this video
                    player.play()
                    self.isPlaying = true
                } else {
                    // Normal auto-play mode
                    player.play()
                    self.isPlaying = true
                }
            }
                
                timer.invalidate()
            case .failed:
                print("DEBUG: HLS player item failed: \(playerItem.error?.localizedDescription ?? "Unknown error")")
                if let error = playerItem.error as NSError? {
                    print("DEBUG: Error domain: \(error.domain), code: \(error.code)")
                    print("DEBUG: Error user info: \(error.userInfo)")
                    
                    // Provide specific error messages based on error codes
                    switch (error.domain, error.code) {
                    case ("CoreMediaErrorDomain", -12642):
                        print("DEBUG: Playlist parse error - invalid HLS manifest format")
                        self.errorMessage = "Invalid HLS playlist format"
                    case ("CoreMediaErrorDomain", -12643):
                        print("DEBUG: Segment not found error")
                        self.errorMessage = "HLS segment not found"
                    case ("CoreMediaErrorDomain", -12644):
                        print("DEBUG: Segment duration error")
                        self.errorMessage = "HLS segment duration error"
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
                        print("DEBUG: HLS playlist not found (404)")
                        self.errorMessage = "HLS playlist not found"
                    case ("NSURLErrorDomain", 403):
                        print("DEBUG: HLS playlist access denied (403)")
                        self.errorMessage = "HLS playlist access denied"
                    case ("NSURLErrorDomain", 500):
                        print("DEBUG: HLS server error (500)")
                        self.errorMessage = "HLS server error"
                    default:
                        print("DEBUG: Unknown HLS error")
                        // Check for common codec compatibility issues
                        if error.localizedDescription.contains("codec") || 
                           error.localizedDescription.contains("format") ||
                           error.localizedDescription.contains("profile") ||
                           error.localizedDescription.contains("hardware") {
                            self.errorMessage = "Video codec not compatible with this device. Please try uploading a different video format."
                        } else {
                            self.errorMessage = "HLS playback error: \(error.localizedDescription)"
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
        print("DEBUG: [VIDEO \(mid)] Removed observers for mid: \(mid) (keeping instance alive)")
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
    @State private var playlistURL: URL? = nil
    @State private var error: String? = nil
    @State private var loading = true
    @State private var didRetry = false // Track if we've retried once

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
                    forceUnmuted: forceUnmuted
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
                } else if !didRetry {
                    // Retry once after a short delay
                    didRetry = true
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                    loading = true
                } else {
                    // Both attempts failed, show empty placeholder
                    playlistURL = nil
                    error = nil
                    loading = false
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

