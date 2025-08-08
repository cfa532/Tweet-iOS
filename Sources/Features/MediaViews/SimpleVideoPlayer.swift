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
        self.disableAutoRestart = disableAutoRestart
        self.mode = mode
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
                            mid: mid,
                            isVisible: isVisible,
                            isMuted: muteState.isMuted, // Use global mute state
                            autoPlay: autoPlay,
                            onMuteChanged: onMuteChanged,
                            onVideoFinished: onVideoFinished,
                            onVideoTap: onVideoTap,
                            showCustomControls: false, // No custom controls in cells

                            forceUnmuted: false, // Use global mute state
                            disableAutoRestart: disableAutoRestart,
                            mode: mode
                        )
                            .offset(y: -pad)    // align the video vertically in the middle
                            .aspectRatio(videoAR, contentMode: .fill)
                        }
                    } else {
                        // Fallback when no cellAspectRatio is available
                        HLSDirectoryVideoPlayer(
                            baseURL: url,
                            mid: mid,
                            isVisible: isVisible,
                            isMuted: muteState.isMuted,
                            autoPlay: autoPlay,
                            onMuteChanged: onMuteChanged,
                            onVideoFinished: onVideoFinished,
                            onVideoTap: onVideoTap,
                            showCustomControls: false,

                            forceUnmuted: false,
                            disableAutoRestart: disableAutoRestart,
                            mode: mode
                        )
                        .aspectRatio(videoAR, contentMode: .fit)
                    }
                    
                case .mediaBrowser:
                    // MediaBrowser mode: fullscreen browser with native controls only
                    HLSDirectoryVideoPlayer(
                        baseURL: url,
                        mid: mid,
                        isVisible: isVisible,
                        isMuted: false, // Always unmuted in browser
                        autoPlay: autoPlay,
                        onMuteChanged: onMuteChanged,
                        onVideoFinished: onVideoFinished,
                        onVideoTap: onVideoTap,
                        showCustomControls: false, // Use native controls only

                        forceUnmuted: true, // Force unmuted in browser
                        disableAutoRestart: false, // Enable auto-replay in full screen
                        mode: mode
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
                                mid: mid,
                                isVisible: isVisible,
                                isMuted: false, // Always unmuted in fullscreen
                                autoPlay: autoPlay,
                                onMuteChanged: onMuteChanged,
                                onVideoFinished: onVideoFinished,
                                onVideoTap: onVideoTap,
                                showCustomControls: true,

                                forceUnmuted: true,
                                disableAutoRestart: disableAutoRestart,
                                mode: mode
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
                                mid: mid,
                                isVisible: isVisible,
                                isMuted: false,
                                autoPlay: autoPlay,
                                onMuteChanged: onMuteChanged,
                                onVideoFinished: onVideoFinished,
                                onVideoTap: onVideoTap,
                                showCustomControls: true,

                                forceUnmuted: true,
                                disableAutoRestart: disableAutoRestart,
                                mode: mode
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
                                mid: mid,
                                isVisible: isVisible,
                                isMuted: false,
                                autoPlay: autoPlay,
                                onMuteChanged: onMuteChanged,
                                onVideoFinished: onVideoFinished,
                                onVideoTap: onVideoTap,
                                showCustomControls: true,

                                forceUnmuted: true,
                                disableAutoRestart: disableAutoRestart,
                                mode: mode
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
                    mid: mid,
                    isVisible: isVisible,
                    isMuted: mode == .mediaCell ? muteState.isMuted : false,
                    autoPlay: autoPlay,
                    onMuteChanged: onMuteChanged,
                    onVideoFinished: onVideoFinished,
                    onVideoTap: onVideoTap,
                    showCustomControls: mode != .mediaCell,

                    forceUnmuted: mode != .mediaCell,
                    disableAutoRestart: disableAutoRestart,
                    mode: mode
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

    let forceUnmuted: Bool
    let disableAutoRestart: Bool
    let isHLS: Bool // Whether this is an HLS video or regular video
    let mode: SimpleVideoPlayer.Mode
    
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var showControls = true
    @State private var hasNotifiedFinished = false
    @State private var hasFinished = false // Track if video has finished to prevent re-queuing
    @State private var localMuted: Bool = false // Local mute state for forceUnmuted mode
    @State private var isSettingUpPlayer = false // Flag to prevent mute state changes during setup
    @State private var playerMuted: Bool = false
    @State private var hasKVOObserver: Bool = false
    @State private var statusObserver: PlayerStatusObserver?

    @StateObject private var muteState = MuteState.shared
    @StateObject private var videoCache = VideoCacheManager.shared
    
    init(videoURL: URL, mid: String, isVisible: Bool, isMuted: Bool, autoPlay: Bool, onMuteChanged: ((Bool) -> Void)?, onVideoFinished: (() -> Void)?, onVideoTap: (() -> Void)?, showCustomControls: Bool, forceUnmuted: Bool, disableAutoRestart: Bool = false, isHLS: Bool = true, mode: SimpleVideoPlayer.Mode) {
        self.videoURL = videoURL
        self.mid = mid
        self.isVisible = isVisible
        self.isMuted = isMuted
        self.autoPlay = autoPlay
        self.onMuteChanged = onMuteChanged
        self.onVideoFinished = onVideoFinished
        self.onVideoTap = onVideoTap
        self.showCustomControls = showCustomControls
        self.forceUnmuted = forceUnmuted
        self.disableAutoRestart = disableAutoRestart
        self.isHLS = isHLS
        self.mode = mode
        self._playerMuted = State(initialValue: isMuted)
        

    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let player = player {
                    VideoPlayer(player: player)
                        .overlay(
                            // Transparent overlay to capture taps - but only when we need custom tap handling
                            Group {
                                if !showCustomControls && mode != .mediaBrowser {
                                    // For MediaCell and other modes, capture taps for custom behavior
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            onVideoTap?()
                                        }
                                }
                                // For MediaBrowserView (.mediaBrowser), no overlay - let native controls handle taps
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
                                    // Update local mute state for full-screen mode only
                                    // Don't sync with global mute state in fullscreen
                                    localMuted = muted
                                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Fullscreen mute state changed to: \(muted) (local only)")
                                } else {
                                    // For MediaCell videos, sync with global mute state when user interacts with native controls
                                    // Only update if this is a user-initiated change, not a programmatic one
                                    if muteState.isMuted != muted {
                                        muteState.setMuted(muted)
                                        print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Global mute state synced to: \(muted)")
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
                    
                    // Handle tap to show/hide controls
                    if showCustomControls {
                        withAnimation {
                            showControls.toggle()
                        }
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
                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] View appeared - autoPlay: \(autoPlay), isVisible: \(isVisible), player exists: \(player != nil)")
                
                // Reset finished state when video appears in a new tweet
                // This allows the same video to be re-queued when it appears in multiple tweets
                if hasFinished {
                    hasFinished = false
                    hasNotifiedFinished = false
                }
                
                if player == nil {
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Player is nil, calling setupPlayer()")
                    setupPlayer()
                } else {
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Player already exists")
                }
                
                // Start controls timer when video loads if custom controls are enabled
                if showCustomControls && showControls {
                    // Controls will stay visible until user taps
                }
                
                // Do not resume or start playback here; let parent control via autoPlay
            }
            .onDisappear {
                // Pause video using cache, do not destroy instance
                videoCache.pauseVideoPlayer(for: mid)
                
                // Remove KVO observer for player item status
                if hasKVOObserver, let observer = statusObserver, let player = player, let playerItem = player.currentItem {
                    playerItem.removeObserver(observer, forKeyPath: "status")
                    statusObserver = nil
                    hasKVOObserver = false
                }
                
                // Do NOT call cleanupObservers() - keep the instance alive
                // Only remove notification observers, keep the player instance
                NotificationCenter.default.removeObserver(self)
            }
            .onChange(of: isVisible) { newVisibility in
                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] isVisible changed to: \(newVisibility), autoPlay: \(autoPlay), isPlaying: \(isPlaying)")
                if newVisibility {
                    // Video became visible - reload video layer to fix black screen issues
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Video became visible - reloading video layer")
                    VideoCacheManager.shared.forceRefreshVideoLayer(for: mid)
                    
                    // Video became visible - start playback if autoPlay is enabled
                    if autoPlay && !isPlaying {
                        if let player = player {
                            print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Video became visible - starting playback")
                            player.play()
                            isPlaying = true
                        } else {
                            print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Video became visible but player is nil")
                        }
                    }
                } else {
                    // Video became invisible - pause playback
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Video became invisible - pausing playback")
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
                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] autoPlay changed to: \(newAutoPlay), isVisible: \(isVisible), isPlaying: \(isPlaying), player exists: \(player != nil)")
                if newAutoPlay && !isPlaying {
                    // AutoPlay was enabled and video is not playing - start playback
                    if let player = player {
                        print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Starting playback - autoPlay: \(newAutoPlay), isVisible: \(isVisible)")
                        player.play()
                        isPlaying = true
                    } else {
                        print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Cannot start playback - player is nil, will try setupPlayer()")
                        setupPlayer()
                    }
                } else if !newAutoPlay && isPlaying {
                    // AutoPlay was disabled and video is playing - pause playback
                    if let player = player {
                        print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Pausing playback - autoPlay: \(newAutoPlay)")
                        player.pause()
                        isPlaying = false
                    }
                } else {
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Not starting playback - newAutoPlay: \(newAutoPlay), isPlaying: \(isPlaying)")
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
            } else {
                // For normal mode, use global mute state
                cachedPlayer.isMuted = muteState.isMuted
            }
            
            // Set up observers for the player
            setupPlayerObservers(cachedPlayer)
            
            // Check if player is ready and start playback if conditions are met
            if let playerItem = cachedPlayer.currentItem, playerItem.status == .readyToPlay {
                self.isLoading = false
                self.duration = playerItem.duration.seconds
                
                // Player is ready - check if we should start playback
                if autoPlay && !isPlaying {
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Player ready - starting playback (autoPlay: \(autoPlay), isVisible: \(isVisible))")
                    cachedPlayer.play()
                    self.isPlaying = true
                } else {
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Player ready but not starting playback - autoPlay: \(autoPlay), isPlaying: \(isPlaying), isVisible: \(isVisible)")
                }
            } else {
                // Player not ready yet, set loading state
                self.isLoading = true
            }
            
            isSettingUpPlayer = false // Allow mute state changes after setup
        } else {
            // Failed to get or create player
            errorMessage = "Failed to create video player"
            isLoading = false
            isSettingUpPlayer = false // Clear flag on error
        }
    }
    
    private func setupPlayerObservers(_ player: AVPlayer) {
        // Add notification observer for video finished
        if let playerItem = player.currentItem {
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { _ in
                print("DEBUG: [SIMPLE VIDEO PLAYER \(self.mid)] AVPlayerItemDidPlayToEndTime notification received - hasNotifiedFinished: \(self.hasNotifiedFinished)")
                if !self.hasNotifiedFinished {
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(self.mid)] Processing AVPlayerItemDidPlayToEndTime - marking as finished")
                    self.hasNotifiedFinished = true
                    self.hasFinished = true // Mark video as finished
                    self.resetVideoState()
                    self.onVideoFinished?()
                } else {
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(self.mid)] Ignoring AVPlayerItemDidPlayToEndTime - already notified")
                }
            }
            
            // Add KVO observer for player item status to handle autoplay when ready
            if !hasKVOObserver {
                let observer = PlayerStatusObserver(mid: mid) { status in
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Player item status changed to: \(status.rawValue) - autoPlay: \(self.autoPlay), isPlaying: \(self.isPlaying)")
                    
                    if status == .readyToPlay {
                        self.isLoading = false
                        self.duration = playerItem.duration.seconds
                        
                        // Player is now ready - check if we should start autoplay
                        if self.autoPlay && !self.isPlaying {
                            if let player = self.player {
                                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Player ready via KVO - starting playback")
                                player.play()
                                self.isPlaying = true
                            }
                        } else {
                            print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Player ready via KVO but not starting playback - autoPlay: \(self.autoPlay), isPlaying: \(self.isPlaying)")
                        }
                    } else if status == .failed {
                        print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Player item failed to load: \(playerItem.error?.localizedDescription ?? "Unknown error")")
                        self.errorMessage = "Failed to load video"
                        self.isLoading = false
                    }
                }
                
                playerItem.addObserver(observer, forKeyPath: "status", options: [.new], context: nil)
                statusObserver = observer
                hasKVOObserver = true
            }
        }
    }
    
    /// Player status observer class for KVO
    private class PlayerStatusObserver: NSObject {
        private let mid: String
        private let onStatusChanged: (AVPlayerItem.Status) -> Void
        
        init(mid: String, onStatusChanged: @escaping (AVPlayerItem.Status) -> Void) {
            self.mid = mid
            self.onStatusChanged = onStatusChanged
            super.init()
        }
        
        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
            if keyPath == "status", let playerItem = object as? AVPlayerItem {
                DispatchQueue.main.async {
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(self.mid)] Player item status changed to: \(playerItem.status.rawValue)")
                    self.onStatusChanged(playerItem.status)
                }
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
    
    private func resetVideoState() {
        // Reset all video state when video finishes
        isPlaying = false
        currentTime = 0
        hasNotifiedFinished = false
        hasFinished = false // Reset finished flag when video is restarted
        showControls = true // Show controls when video finishes
        
        // Always reset player to beginning to ensure it can play again
        // This ensures the video is ready when the sequence restarts
        videoCache.resetVideoPlayer(for: mid)
        print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Video finished - reset to beginning")
        
        // Update local player reference if needed
        if let player = player {
            // Preserve the mute state when resetting
            if forceUnmuted {
                player.isMuted = localMuted
            } else {
                player.isMuted = muteState.isMuted
            }
            
            // Ensure player is paused after reset
            player.pause()
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

    let forceUnmuted: Bool
    let disableAutoRestart: Bool
    let mode: SimpleVideoPlayer.Mode
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

                    forceUnmuted: forceUnmuted,
                    disableAutoRestart: disableAutoRestart,
                    isHLS: isHLSMode,
                    mode: mode
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

