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
}

// Global video manager to handle scroll-based video stopping
class VideoManager: ObservableObject {
    static let shared = VideoManager()
    @Published var currentPlayingInstanceId: String? = nil
    private var videoQueue: [String] = [] // Queue of videos waiting to play
    private var autoStartNext: Bool = true // Whether to auto-start next video
    private var visibleVideos: Set<String> = [] // Track which videos are visible
    private var videoPositions: [String: CGRect] = [:] // Track video positions on screen
    
    private init() {}
    
    func startPlaying(instanceId: String) {
        // Pause any currently playing video
        if let currentId = currentPlayingInstanceId, currentId != instanceId {
            // print("DEBUG: [VIDEO MANAGER] Pausing previous video instance: \(currentId)")
            NotificationCenter.default.post(name: .pauseVideo, object: currentId)
        }
        
        currentPlayingInstanceId = instanceId
        // print("DEBUG: [VIDEO MANAGER] Now playing video instance: \(instanceId)")
        
        // Remove from queue if it was there
        videoQueue.removeAll { $0 == instanceId }
    }
    
    func stopPlaying(instanceId: String) {
        if currentPlayingInstanceId == instanceId {
            currentPlayingInstanceId = nil
            // print("DEBUG: [VIDEO MANAGER] Stopped playing video instance: \(instanceId)")
            
            // Auto-start next visible video if enabled
            if autoStartNext {
                startNextVisibleVideo()
            }
        }
    }
    
    func stopAllVideos() {
        if let currentId = currentPlayingInstanceId {
            // print("DEBUG: [VIDEO MANAGER] Stopping all videos due to scroll - current: \(currentId)")
            NotificationCenter.default.post(name: .pauseVideo, object: currentId)
            currentPlayingInstanceId = nil
        }
        // Clear queue when scrolling
        videoQueue.removeAll()
        // print("DEBUG: [VIDEO MANAGER] Cleared all videos from queue due to scroll")
    }
    
    // Stop all videos when a sheet is presented
    func stopAllVideosForSheet() {
        if let currentId = currentPlayingInstanceId {
            // print("DEBUG: [VIDEO MANAGER] Stopping all videos due to sheet presentation - current: \(currentId)")
            NotificationCenter.default.post(name: .pauseVideo, object: currentId)
            currentPlayingInstanceId = nil
        }
        // Clear queue when sheet is presented
        videoQueue.removeAll()
        // print("DEBUG: [VIDEO MANAGER] Cleared all videos from queue due to sheet presentation")
    }
    
    // Clean up queue and check for next visible video
    func cleanupQueueAndStartNext() {
        removeInvisibleFromQueue()
        if currentPlayingInstanceId == nil && autoStartNext {
            startNextVisibleVideo()
        }
    }
    
    // Update video position for visibility calculation
    func updateVideoPosition(instanceId: String, frame: CGRect) {
        videoPositions[instanceId] = frame
        // print("DEBUG: [VIDEO MANAGER] Updated position for \(instanceId): \(frame)")
    }
    
    // Check if video is actually visible on screen
    func isVideoActuallyVisible(instanceId: String, screenBounds: CGRect) -> Bool {
        guard let videoFrame = videoPositions[instanceId] else {
            // print("DEBUG: [VIDEO MANAGER] No position data for \(instanceId)")
            return false
        }
        
        // Calculate how much of the video is visible on screen
        let intersection = videoFrame.intersection(screenBounds)
        let visibilityRatio = intersection.width * intersection.height / (videoFrame.width * videoFrame.height)
        
        // Consider video visible if more than 30% is on screen (reduced from 50% for better detection)
        let isVisible = visibilityRatio > 0.3 && intersection.width > 0 && intersection.height > 0
        
        // print("DEBUG: [VIDEO MANAGER] Visibility check for \(instanceId): \(isVisible) (ratio: \(visibilityRatio), frame: \(videoFrame), screen: \(screenBounds), intersection: \(intersection))")
        return isVisible
    }
    
    // Track video visibility based on both isVisible parameter and actual screen position
    func setVideoVisible(_ instanceId: String, isVisible: Bool, screenBounds: CGRect = UIScreen.main.bounds) {
        let actuallyVisible = isVideoActuallyVisible(instanceId: instanceId, screenBounds: screenBounds)
        
        // Video is considered visible if BOTH the isVisible parameter is true AND it's actually on screen
        let shouldBeVisible = isVisible && actuallyVisible
        
        if shouldBeVisible {
            visibleVideos.insert(instanceId)
            // print("DEBUG: [VIDEO MANAGER] Video became visible: \(instanceId) (isVisible: \(isVisible), actuallyVisible: \(actuallyVisible))")
            
            // If no video is currently playing, try to start this one
            if currentPlayingInstanceId == nil && autoStartNext {
                // print("DEBUG: [VIDEO MANAGER] No video playing, starting newly visible video: \(instanceId)")
                NotificationCenter.default.post(name: .startVideo, object: instanceId)
            }
        } else {
            visibleVideos.remove(instanceId)
            // print("DEBUG: [VIDEO MANAGER] Video became invisible: \(instanceId) (isVisible: \(isVisible), actuallyVisible: \(actuallyVisible))")
            
            // Remove invisible videos from queue to prevent them from starting
            removeInvisibleFromQueue()
            
            // If the invisible video was playing, stop it and start next
            if currentPlayingInstanceId == instanceId {
                // print("DEBUG: [VIDEO MANAGER] Stopping invisible video: \(instanceId)")
                NotificationCenter.default.post(name: .pauseVideo, object: instanceId)
                currentPlayingInstanceId = nil
                
                if autoStartNext {
                    startNextVisibleVideo()
                }
            }
        }
    }
    
    // Add video to queue for auto-play (only if visible)
    func addToQueue(instanceId: String) {
        if !videoQueue.contains(instanceId) && currentPlayingInstanceId != instanceId && visibleVideos.contains(instanceId) {
            videoQueue.append(instanceId)
            // print("DEBUG: [VIDEO MANAGER] Added actually visible video to queue: \(instanceId), queue size: \(videoQueue.count)")
        }
    }
    
    // Remove invisible videos from queue
    func removeInvisibleFromQueue() {
        videoQueue.removeAll { !visibleVideos.contains($0) }
    }
    
    // Start the next visible video in queue
    private func startNextVisibleVideo() {
        // First, clean up any invisible videos from the queue
        removeInvisibleFromQueue()
        
        // Find the first visible video in the queue
        if let nextVideoId = videoQueue.first(where: { visibleVideos.contains($0) }) {
            // print("DEBUG: [VIDEO MANAGER] Auto-starting next visible video: \(nextVideoId)")
            NotificationCenter.default.post(name: .startVideo, object: nextVideoId)
            videoQueue.removeAll { $0 == nextVideoId }
        } else {
            // print("DEBUG: [VIDEO MANAGER] No visible videos in queue to start")
        }
    }
    
    // Force check all visible videos and start one if none is playing
    func checkAndStartVisibleVideo() {
        // Clean up any invisible videos from the queue
        removeInvisibleFromQueue()
        
        // If no video is currently playing, try to start a visible one
        if currentPlayingInstanceId == nil && autoStartNext {
            // print("DEBUG: [VIDEO MANAGER] No video playing, checking for visible videos to start")
            startNextVisibleVideo()
        }
    }
    
    // Enable/disable auto-start next video
    func setAutoStartNext(_ enabled: Bool) {
        autoStartNext = enabled
        // print("DEBUG: [VIDEO MANAGER] Auto-start next video: \(enabled)")
    }
    
    // Static method to trigger scroll detection from anywhere
    static func triggerScroll() {
        // print("DEBUG: [VIDEO MANAGER] Scroll detected - stopping all videos")
        NotificationCenter.default.post(name: .scrollStarted, object: nil)
    }
    
    // Static method to trigger scroll ended detection
    static func triggerScrollEnded() {
        // print("DEBUG: [VIDEO MANAGER] Scroll ended - checking for visible videos")
        NotificationCenter.default.post(name: .scrollEnded, object: nil)
    }
    
    // Static method to trigger sheet presentation detection
    static func triggerSheetPresentation() {
        // print("DEBUG: [VIDEO MANAGER] Sheet presentation detected - stopping all videos")
        NotificationCenter.default.post(name: .sheetPresented, object: nil)
    }
}

// Notification names for video management
extension Notification.Name {
    static let pauseVideo = Notification.Name("pauseVideo")
    static let scrollStarted = Notification.Name("scrollStarted")
    static let startVideo = Notification.Name("startVideo")
    static let sheetPresented = Notification.Name("sheetPresented")
    static let scrollEnded = Notification.Name("scrollEnded")
}

struct SimpleVideoPlayer: View {
    let url: URL
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

    var body: some View {
        GeometryReader { geometry in
            if let cellAR = cellAspectRatio, let videoAR = videoAspectRatio {
                let cellWidth = geometry.size.width
                let cellHeight = cellWidth / cellAR
                let needsVerticalPadding = videoAR < cellAR
                let videoHeight = cellWidth / videoAR
                let overflow = videoHeight - cellHeight
                let pad = needsVerticalPadding && overflow > 0 ? overflow / 2 : 0
                ZStack {
                    HLSDirectoryVideoPlayer(
                        baseURL: url,
                        isVisible: isVisible,
                        isMuted: forceUnmuted ? false : muteState.isMuted,
                        autoPlay: autoPlay,
                        onMuteChanged: onMuteChanged,
                        onVideoFinished: onVideoFinished,
                        onVideoTap: onVideoTap,
                        showCustomControls: showCustomControls,
                        forcePlay: forcePlay
                    )
                    .offset(y: -pad)    // align the video vertically in the middle
                    .aspectRatio(videoAR, contentMode: .fill)
                }
            } else {
                ZStack {
                    HLSDirectoryVideoPlayer(
                        baseURL: url,
                        isVisible: isVisible,
                        isMuted: forceUnmuted ? false : muteState.isMuted,
                        autoPlay: autoPlay,
                        onMuteChanged: onMuteChanged,
                        onVideoFinished: onVideoFinished,
                        onVideoTap: onVideoTap,
                        showCustomControls: showCustomControls,
                        forcePlay: forcePlay
                    )
                }
            }
        }
    }
}

/// HLSVideoPlayer with custom controls
struct HLSVideoPlayerWithControls: View {
    let videoURL: URL
    let isVisible: Bool
    let isMuted: Bool
    let autoPlay: Bool
    let onMuteChanged: ((Bool) -> Void)?
    let onVideoFinished: (() -> Void)?
    let onVideoTap: (() -> Void)?
    let showCustomControls: Bool
    let forcePlay: Bool
    
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var showControls = true
    @State private var playerMuted: Bool = false
    @State private var controlsTimer: Timer?
    @State private var hasNotifiedFinished = false
    @State private var hasFinished = false // Track if video has finished to prevent re-queuing
    @State private var playerInstanceId = UUID().uuidString.prefix(8) // Unique ID for this player instance
    @StateObject private var videoManager = VideoManager.shared
    
    init(videoURL: URL, isVisible: Bool, isMuted: Bool, autoPlay: Bool, onMuteChanged: ((Bool) -> Void)?, onVideoFinished: (() -> Void)?, onVideoTap: (() -> Void)?, showCustomControls: Bool, forcePlay: Bool) {
        self.videoURL = videoURL
        self.isVisible = isVisible
        self.isMuted = isMuted
        self.autoPlay = autoPlay
        self.onMuteChanged = onMuteChanged
        self.onVideoFinished = onVideoFinished
        self.onVideoTap = onVideoTap
        self.showCustomControls = showCustomControls
        self.forcePlay = forcePlay
        self._playerMuted = State(initialValue: isMuted)
        print("DEBUG: [INSTANCE] Creating new HLSVideoPlayerWithControls instance: \(UUID().uuidString.prefix(8)) for URL: \(videoURL.absoluteString)")
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
                            // This automatically updates when the user interacts with native controls
                            if playerMuted != muted {
                                playerMuted = muted
                            }
                        }
                } else if isLoading {
                    VStack {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Loading HLS stream...")
                            .font(.caption)
                            .foregroundColor(.themeSecondaryText)
                    }
                } else if let errorMessage = errorMessage {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.red)
                        Text("HLS Playback Error")
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
                        videoManager.startPlaying(instanceId: String(playerInstanceId))
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
                print("DEBUG: [INSTANCE \(playerInstanceId)] HLSVideoPlayerWithControls onAppear - isVisible: \(isVisible)")
                
                // Update video position and check actual visibility
                let frame = geometry.frame(in: .global)
                videoManager.updateVideoPosition(instanceId: String(playerInstanceId), frame: frame)
                
                // Only update visibility if video hasn't finished to prevent re-queuing
                if !hasFinished {
                    videoManager.setVideoVisible(String(playerInstanceId), isVisible: isVisible)
                }
                
                // Listen for pause notifications from video manager
                NotificationCenter.default.addObserver(
                    forName: .pauseVideo,
                    object: nil,
                    queue: .main
                ) { notification in
                    if let pauseInstanceId = notification.object as? String, pauseInstanceId == self.playerInstanceId {
                        print("DEBUG: [INSTANCE \(self.playerInstanceId)] Received pause notification from video manager")
                        self.player?.pause()
                        self.isPlaying = false
                    }
                }
                
                // Listen for start notifications from video manager
                NotificationCenter.default.addObserver(
                    forName: .startVideo,
                    object: nil,
                    queue: .main
                ) { notification in
                    if let startInstanceId = notification.object as? String, startInstanceId == self.playerInstanceId {
                        print("DEBUG: [INSTANCE \(self.playerInstanceId)] Received start notification from video manager")
                        if let player = self.player, !self.isPlaying {
                            player.play()
                            self.isPlaying = true
                        }
                    }
                }
                
                // Listen for scroll ended notifications to check visibility
                NotificationCenter.default.addObserver(
                    forName: .scrollEnded,
                    object: nil,
                    queue: .main
                ) { _ in
                    // Force check visibility when scroll ends
                    let frame = geometry.frame(in: .global)
                    self.videoManager.updateVideoPosition(instanceId: String(self.playerInstanceId), frame: frame)
                    if !self.hasFinished {
                        self.videoManager.setVideoVisible(String(self.playerInstanceId), isVisible: self.isVisible)
                    }
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
                print("DEBUG: [INSTANCE \(playerInstanceId)] HLSVideoPlayerWithControls onDisappear - isVisible: \(isVisible)")
                
                // Stop controls timer
                stopControlsTimer()
                
                // Notify video manager about visibility change
                videoManager.setVideoVisible(String(playerInstanceId), isVisible: false)
                
                // Only pause, do not destroy or reload
                player?.pause()
                videoManager.stopPlaying(instanceId: String(playerInstanceId))
                cleanupObservers()
            }
            .onChange(of: isVisible) { newVisibility in
                print("DEBUG: [INSTANCE \(playerInstanceId)] Visibility changed to: \(newVisibility)")
                let frame = geometry.frame(in: .global)
                videoManager.updateVideoPosition(instanceId: String(playerInstanceId), frame: frame)
                
                // Only update visibility if video hasn't finished to prevent re-queuing
                if !hasFinished {
                    videoManager.setVideoVisible(String(playerInstanceId), isVisible: newVisibility)
                }
            }
            .onChange(of: geometry.frame(in: .global)) { newFrame in
                // Update position when frame changes (e.g., during scroll)
                videoManager.updateVideoPosition(instanceId: String(playerInstanceId), frame: newFrame)
                
                // Only update visibility if video hasn't finished to prevent re-queuing
                if !hasFinished {
                    // Recalculate visibility based on new frame position
                    videoManager.setVideoVisible(String(playerInstanceId), isVisible: isVisible)
                }
            }
        }
    }
    
    private func setupPlayer() {
        print("DEBUG: Setting up HLS player for URL: \(videoURL.absoluteString)")
        
        isLoading = true
        errorMessage = nil
        hasNotifiedFinished = false
        
        // Create asset with hardware acceleration support
        let asset = AVURLAsset(url: videoURL, options: [
            "AVURLAssetOutOfBandMIMETypeKey": "application/x-mpegURL",
            "AVURLAssetHTTPHeaderFieldsKey": ["Accept": "*/*"]
        ])
        
        // Create player item with asset
        let playerItem = AVPlayerItem(asset: asset)
        
        // Configure player item for better performance
        playerItem.preferredForwardBufferDuration = 10.0
        playerItem.preferredPeakBitRate = 0 // Let system decide
        
        // Create AVPlayer with the player item
        let avPlayer = AVPlayer(playerItem: playerItem)
        
        // Enable hardware acceleration
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        
        // Set initial mute state
        avPlayer.isMuted = isMuted
        
        // Add periodic time observer for progress updates
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { time in
            currentTime = time.seconds
            
            // Check if video has finished
            if duration > 0 && currentTime >= duration - 0.5 && !hasNotifiedFinished {
                hasNotifiedFinished = true
                hasFinished = true // Mark video as finished
                self.videoManager.stopPlaying(instanceId: String(self.playerInstanceId))
                print("DEBUG: [INSTANCE \(self.playerInstanceId)] Video finished in HLSVideoPlayerWithControls")
                self.resetVideoState()
                self.onVideoFinished?()
            }
        }
        
        // Add notification observer for video finished
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            if !self.hasNotifiedFinished {
                self.hasNotifiedFinished = true
                self.hasFinished = true // Mark video as finished
                self.videoManager.stopPlaying(instanceId: String(self.playerInstanceId))
                print("DEBUG: [INSTANCE \(self.playerInstanceId)] Video finished via AVPlayerItemDidPlayToEndTime notification")
                print("DEBUG: [INSTANCE \(self.playerInstanceId)] Video URL: \(self.videoURL.absoluteString)")
                print("DEBUG: [INSTANCE \(self.playerInstanceId)] Final duration: \(self.duration) seconds")
                print("DEBUG: [INSTANCE \(self.playerInstanceId)] Final current time: \(self.currentTime) seconds")
                self.resetVideoState()
                self.onVideoFinished?()
            }
        }
        
        // Set up the player
        self.player = avPlayer
        
        // Monitor player item status
        self.monitorPlayerStatus(avPlayer)
        
        // Only play if autoPlay is true
        if autoPlay {
            if self.forcePlay {
                // Force play mode (for full-screen) - stop all other videos and start this one
                self.videoManager.stopAllVideosForSheet()
                self.videoManager.startPlaying(instanceId: String(self.playerInstanceId))
                avPlayer.play()
                self.isPlaying = true
            } else if self.videoManager.currentPlayingInstanceId == nil {
                self.videoManager.startPlaying(instanceId: String(self.playerInstanceId))
                avPlayer.play()
                self.isPlaying = true
            } else {
                // Add to queue if another video is playing
                self.videoManager.addToQueue(instanceId: String(self.playerInstanceId))
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
                print("DEBUG: [INSTANCE \(self.playerInstanceId)] HLS player item is ready to play")
                self.isLoading = false
                self.duration = playerItem.duration.seconds
                
                // If this video should auto-play and no video is currently playing, start it
                if self.autoPlay {
                    if self.forcePlay {
                        // Force play mode (for full-screen) - stop all other videos and start this one
                        self.videoManager.stopAllVideosForSheet()
                        self.videoManager.startPlaying(instanceId: String(self.playerInstanceId))
                        player.play()
                        self.isPlaying = true
                    } else if self.videoManager.currentPlayingInstanceId == nil {
                        self.videoManager.startPlaying(instanceId: String(self.playerInstanceId))
                        player.play()
                        self.isPlaying = true
                    } else {
                        // Add to queue if another video is playing
                        self.videoManager.addToQueue(instanceId: String(self.playerInstanceId))
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
            videoManager.stopPlaying(instanceId: String(playerInstanceId))
        } else {
            videoManager.startPlaying(instanceId: String(playerInstanceId))
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
        
        // Reset player to beginning
        if let player = player {
            player.seek(to: CMTime.zero)
        }
        
        // Start controls timer to auto-hide controls
        if showCustomControls {
            startControlsTimer()
        }
    }
    
    private func cleanupObservers() {
        // Remove all observers
        NotificationCenter.default.removeObserver(self)
    }
}

// Scroll detector for stopping videos during scroll
struct ScrollDetector: ViewModifier {
    @StateObject private var videoManager = VideoManager.shared
    @State private var lastScrollTime = Date()
    
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .scrollStarted)) { _ in
                // Stop all videos when scroll is detected
                videoManager.stopAllVideos()
            }
            .onReceive(NotificationCenter.default.publisher(for: .sheetPresented)) { _ in
                // Stop all videos when sheet is presented
                videoManager.stopAllVideosForSheet()
            }
    }
}

// Extension to easily add scroll detection to any view
extension View {
    func detectScroll() -> some View {
        self.modifier(ScrollDetector())
    }
}

struct HLSDirectoryVideoPlayer: View {
    let baseURL: URL
    let isVisible: Bool
    let isMuted: Bool
    let autoPlay: Bool
    let onMuteChanged: ((Bool) -> Void)?
    let onVideoFinished: (() -> Void)?
    let onVideoTap: (() -> Void)?
    let showCustomControls: Bool
    let forcePlay: Bool
    @State private var playlistURL: URL? = nil
    @State private var error: String? = nil
    @State private var loading = true
    @State private var didRetry = false // Track if we've retried once

    var body: some View {
        Group {
            if let playlistURL = playlistURL {
                HLSVideoPlayerWithControls(
                    videoURL: playlistURL,
                    isVisible: isVisible,
                    isMuted: isMuted,
                    autoPlay: autoPlay,
                    onMuteChanged: onMuteChanged,
                    onVideoFinished: onVideoFinished,
                    onVideoTap: onVideoTap,
                    showCustomControls: showCustomControls,
                    forcePlay: forcePlay
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

