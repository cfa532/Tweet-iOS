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
    case tweetDetail // In TweetDetailView (single tweet view)
}

// MARK: - Consolidated State Enums
enum LoadingState {
    case idle
    case loading
    case loaded
    case failed(retryCount: Int)
    
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
    
    var hasFailed: Bool {
        if case .failed = self { return true }
        return false
    }
    
    var retryCount: Int {
        if case .failed(let count) = self { return count }
        return 0
    }
}

enum PlaybackState {
    case notStarted
    case playing
    case paused
    case finished
    
    var hasFinished: Bool {
        return self == .finished
    }
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
    /// Extract mediaID from URL
    private func extractMediaID(from url: URL) -> String? {
        let urlString = url.absoluteString
        // Look for IPFS hash pattern (Qm...)
        if let range = urlString.range(of: "Qm[A-Za-z0-9]{44}") {
            return String(urlString[range])
        }
        return nil
    }
    // MARK: Required Parameters
    let url: URL
    let mid: String
    let parentTweetId: String? // Optional parent tweet ID for unique identification
    let isVisible: Bool
    let mediaType: MediaType // Add MediaType parameter
    
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
    var shouldLoadVideo: Bool = true // Whether grid-level loading is enabled
    
    // MARK: Mode
    var mode: Mode = .mediaCell
    
    // MARK: State
    @State private var player: AVPlayer?
    @State private var loadingState: LoadingState = .idle
    @State private var playbackState: PlaybackState = .notStarted
    @State private var isLongPressing = false
    @State private var isPlayerDetached = false  // Track background state
    @State private var playerItem: AVPlayerItem? // Keep reference for observer cleanup
    @State private var videoCompletionObserver: NSObjectProtocol?
    @State private var videoErrorObserver: NSObjectProtocol?
    @State private var timeObserver: Any?
    @State private var timeObserverPlayer: AVPlayer?
    @State private var representableId: Int = 0 // Force VideoPlayerRepresentable recreation
    @State private var viewConfigTimestamp: TimeInterval = 0 // Timestamp when view was last configured
    
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
    // For fullscreen and detail modes, always use static autoPlay (bypass VideoManager)
    private var currentAutoPlay: Bool {
        if mode == .mediaBrowser || mode == .tweetDetail {
            return autoPlay
        }
        if let videoManager = videoManager {
            return videoManager.shouldPlayVideo(for: mid)
        }
        return autoPlay
    }
    
    // Create unique URL by appending tweet ID as query parameter
    // This ensures each tweet gets its own player instance, even for duo videos
    // Server ignores the query param and returns the same video content
    // Cache key that includes mode to prevent MediaCell and TweetDetailView from sharing players
    private var playerCacheKey: String {
        return "\(uniquePlayerURL.absoluteString)_\(mode)"
    }
    
    private var uniquePlayerURL: URL {
        guard let parentTweetId = parentTweetId else {
            return url // Fallback to original URL if no parent tweet ID
        }
        
        // Create a short hash from the parent tweet ID to append as query param
        let tweetHash = abs(parentTweetId.hashValue) % 10000
        
        // Append query parameter: http://ip/ipfs/QmXXX?dig=1234
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "dig", value: String(tweetHash))]
            return components.url ?? url
        }
        
        return url
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
                    
                case .tweetDetail:
                    // TweetDetail mode: single video view with fit aspect ratio
                    videoPlayerView()
                        .aspectRatio(videoAR, contentMode: .fit)
                }
            } else {
                // Fallback when no aspect ratio is available
                videoPlayerView()
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                    .frame(maxWidth: screenWidth, maxHeight: screenHeight)
            }
        }
        .onAppear {
            NSLog("DEBUG: [VIDEO APPEAR] onAppear called for \(mid)")
            NSLog("DEBUG: [VIDEO APPEAR] player: \(player != nil), shouldLoadVideo: \(shouldLoadVideo), isVisible: \(isVisible), mode: \(mode)")
            
            // Handle idle timer for fullscreen modes
            if mode == .mediaBrowser {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            
            // For fullscreen and detail modes, always try to set up player regardless of shouldLoadVideo
            if mode == .mediaBrowser || mode == .tweetDetail {
                NSLog("DEBUG: [VIDEO APPEAR] Fullscreen/Detail mode - forcing player setup for \(mid)")
                if player == nil {
                    setupPlayer()
                } else {
                    // Player exists, validate and configure it
                    validateAndConfigureExistingPlayer()
                }
                return
            }
            
            // For MediaCell mode, use existing logic but be less aggressive about failure detection
            if let player = player, let playerItem = player.currentItem {
                if playerItem.status == .failed && loadingState.hasFailed {
                    // Only trigger recovery if we've already marked this as failed
                    print("DEBUG: [VIDEO APPEAR] Player item is in failed state and already marked as failed for \(mid), triggering recovery")
                    handleError(strategy: .loadFailure)
                    return
                } else if playerItem.status == .failed {
                    // Player item is failed but not marked as failed yet - just log and continue
                    print("DEBUG: [VIDEO APPEAR] Player item is in failed state for \(mid), but not marked as failed yet - continuing")
                }
            }
            
            // Set up player if needed
            if player == nil && shouldLoadVideo && isVisible {
                NSLog("DEBUG: [VIDEO APPEAR] Setting up player for \(mid)")
                setupPlayer()
            }
        }
        .onDisappear {
            // Handle idle timer for fullscreen modes
            if mode == .mediaBrowser {
                UIApplication.shared.isIdleTimerDisabled = false
                
                // Before exiting full screen, restore the mute state to global mute state
                // This ensures the player instance is properly muted when returning to MediaCell
                if let player = player {
                    player.isMuted = MuteState.shared.isMuted
                    NSLog("DEBUG: [VIDEO DISAPPEAR] Restored mute state to global state (\(MuteState.shared.isMuted)) before exiting full screen")
                }
            }
            
            // Remove observers to prevent memory leaks
            removePlayerObservers()

            // Cache the current video state
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
            
            // For MediaCell and TweetDetail modes, release player to force fresh creation on next appearance
            // This avoids AVPlayerLayer corruption from reusing the same AVPlayer instance
            // TweetDetail uses a separate player instance that should be stopped when exiting
            if mode == .mediaCell {
                player?.pause()
                player = nil
                NSLog("DEBUG: [VIDEO DISAPPEAR] MediaCell - released player for \(mid), will create fresh on next appearance")
            } else if mode == .tweetDetail {
                player?.pause()
                player = nil
                NSLog("DEBUG: [VIDEO DISAPPEAR] TweetDetail - stopped and released player for \(mid)")
            }
            
            // For mediaBrowser mode, don't release - it shares the player with MediaCell
            // VideoManager and stopAllVideos handle pausing for shared players
        }
        .onChange(of: mode) { oldMode, newMode in
            // When mode changes, apply appropriate mute state
            guard let player = player else { return }
            
            if newMode == .mediaBrowser {
                // Entering full screen - force unmute
                player.isMuted = false
                NSLog("DEBUG: [VIDEO MODE CHANGE] Entered full screen (\(oldMode) -> \(newMode)), forced unmuted")
                
                // CRITICAL: Force layer detachment and increment representableId
                // This ensures the VideoPlayerRepresentable in MediaCell releases the layer
                // before AVPlayerViewController tries to use it, preventing black screen
                self.representableId += 1
                NSLog("DEBUG: [VIDEO MODE CHANGE] Incremented representableId to \(self.representableId) to force layer detachment from MediaCell")
                
                // Small delay to ensure layer detachment completes before AVPlayerViewController attaches
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NSLog("DEBUG: [VIDEO MODE CHANGE] Layer detachment complete, AVPlayerViewController can now attach")
                }
            } else if newMode == .mediaCell && oldMode == .mediaBrowser {
                // Exiting full screen to MediaCell - apply global mute state
                player.isMuted = MuteState.shared.isMuted
                NSLog("DEBUG: [VIDEO MODE CHANGE] Exited full screen to MediaCell (\(oldMode) -> \(newMode)), applied global mute state: \(MuteState.shared.isMuted)")
                
                // Force recreation of VideoPlayerRepresentable to ensure fresh layer attachment
                self.representableId += 1
                NSLog("DEBUG: [VIDEO MODE CHANGE] Incremented representableId to \(self.representableId) for fresh MediaCell layer")
            } else if newMode == .mediaCell {
                // Any other transition to MediaCell - apply global mute state
                player.isMuted = MuteState.shared.isMuted
                NSLog("DEBUG: [VIDEO MODE CHANGE] Transitioned to MediaCell (\(oldMode) -> \(newMode)), applied global mute state: \(MuteState.shared.isMuted)")
            }
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
            // DON'T pause here - shared players might be in use by fullscreen/detail
            // Let visibility changes and VideoManager's sequential playback handle pausing
            if mode == .mediaCell {
                NSLog("DEBUG: [VIDEO AUTOPLAY CHANGE] MediaCell autoPlay changed to \(shouldAutoPlay) for \(mid)")
                // Only check playback conditions, don't pause
                // Pausing here interferes with shared players used by fullscreen/detail
                checkPlaybackConditions(autoPlay: shouldAutoPlay, isVisible: isVisible)
            } else {
                NSLog("DEBUG: [VIDEO AUTOPLAY CHANGE] Ignoring VideoManager state change for \(mode) mode \(mid)")
            }
        }
        .onChange(of: isVisible) { _, visible in
            print("DEBUG: [VIDEO VISIBILITY] isVisible changed to \(visible) for \(mid)")
            print("DEBUG: [VIDEO VISIBILITY] shouldLoadVideo: \(shouldLoadVideo), player: \(player != nil), mode: \(mode)")
            
            // Handle visibility changes - simplified logic to avoid conflicts
            if visible {
                // For fullscreen and detail modes, always allow setup regardless of shouldLoadVideo
                if mode == .mediaBrowser || mode == .tweetDetail {
                    NSLog("DEBUG: [VIDEO VISIBILITY] Fullscreen/Detail mode - forcing player setup for \(mid)")
                    if player == nil {
                        setupPlayer()
                    } else {
                        validateAndConfigureExistingPlayer()
                    }
                    return
                }
                
                // For MediaCell mode, respect shouldLoadVideo setting
                guard shouldLoadVideo else {
                    print("DEBUG: [VIDEO VISIBILITY] Video became visible but loading is disabled for \(mid)")
                    return
                }
                
                // Validate existing player state if present - but be less aggressive about failure detection
                if let player = player, let playerItem = player.currentItem {
                    if playerItem.status == .failed && loadingState.hasFailed {
                        // Only trigger recovery if we've already marked this as failed
                        print("DEBUG: [VIDEO VISIBILITY] Player item is in failed state and already marked as failed for \(mid), triggering recovery")
                        handleError(strategy: .loadFailure)
                        return
                    } else if playerItem.status == .failed {
                        // Player item is failed but not marked as failed yet - just log and continue
                        print("DEBUG: [VIDEO VISIBILITY] Player item is in failed state for \(mid), but not marked as failed yet - continuing")
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
        .onChange(of: shouldLoadVideo) { _, newShouldLoadVideo in
            // Grid-level loading state changed - consolidate all loading decisions here
            handleLoadingStateChange(newShouldLoadVideo: newShouldLoadVideo)
        }
        
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // App going to background - mark player as detached
            NSLog("DEBUG: [VIDEO BACKGROUND] App going to background for \(mid)")
            isPlayerDetached = true
            
            // Pause all players to save battery
            if let player = player {
                player.pause()
                NSLog("DEBUG: [VIDEO BACKGROUND] Paused player for \(mid)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // App returning to foreground - restore player rendering
            NSLog("DEBUG: [VIDEO FOREGROUND] App returning to foreground for \(mid)")
            isPlayerDetached = false
            
            // Force player view recreation to fix black screen
            if let player = player {
                representableId += 1 // Increment to force VideoPlayer recreation
                
                // Give iOS a moment to restore rendering pipeline, then check playback
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    // Only resume if video should be playing based on conditions
                    if isVisible && currentAutoPlay && mode == .mediaCell {
                        player.play()
                        NSLog("DEBUG: [VIDEO FOREGROUND] Resumed playback for \(mid)")
                    }
                }
                
                NSLog("DEBUG: [VIDEO FOREGROUND] Recreated player view for \(mid)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopAllVideos)) { _ in
            // Direct handler for stopAllVideos notification
            NSLog("DEBUG: [SimpleVideoPlayer] Received stopAllVideos notification for \(mid), mode: \(mode)")
            
            // Only pause and mute MediaCell videos
            // Fullscreen and detail modes ignore this notification
            if mode == .mediaCell {
                player?.pause()
                // Also mute the player to stop audio
                player?.isMuted = true
                NSLog("DEBUG: [SimpleVideoPlayer] Paused MediaCell video \(mid)")
            } else {
                NSLog("DEBUG: [SimpleVideoPlayer] Ignoring stopAllVideos for \(mode) mode video \(mid)")
            }
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
            
            // Only restore cached state if no player exists and we're not already detached
            if player == nil && shouldLoadVideo && !isPlayerDetached {
                print("DEBUG: [VIDEO APP ACTIVE] No player found, attempting to restore cached state for \(mid)")
                restoreCachedVideoState()
            }
            
            // If still no player after cache restoration, try to get from SharedAssetCache
            if player == nil && shouldLoadVideo && !isPlayerDetached {
                if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: playerCacheKey) {
                    print("DEBUG: [VIDEO APP ACTIVE] Found cached player in SharedAssetCache for \(mid) with key: \(playerCacheKey)")
                    configurePlayer(cachedPlayer)
                }
            }
            
            // Ensure player is reattached if it was detached (but don't duplicate reattach calls)
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
            if loadingState.hasFailed {
                print("DEBUG: [VIDEO APP ACTIVE] Resetting error state for \(mid)")
                loadingState = .idle
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
            handleError(strategy: .manualReset)
        } onPressingChanged: { pressing in
            if !pressing {
                isLongPressing = false
            }
        }
    }
    
    // MARK: - Unique ID for view identity
    private var uniqueViewId: String {
        // Combine URL with timestamp and representableId to force recreation
        // Timestamp: scrolling back prevention
        // RepresentableId: foreground/background transition handling
        return "\(uniquePlayerURL.absoluteString)_\(viewConfigTimestamp)_\(representableId)"
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
                            .id("\(mid)_\(representableId)") // Force recreation with representableId changes
                            .onAppear {
                                NSLog("DEBUG: [AVPlayerViewController] View appeared for \(mid)")
                            }
                            .onTapGesture {
                                if let onVideoTap = onVideoTap {
                                    onVideoTap()
                                }
                            }
                    } else {
                        // Use native SwiftUI VideoPlayer - let iOS handle everything
                        VideoPlayer(player: player)
                            .id(uniqueViewId) // Hash of tweet+video+state for unique identity
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
                if loadingState.isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(8)
                }
            }
        } else {
            // No player yet - show subtle loading placeholder to avoid black flicker
            ZStack {
                Color.gray.opacity(0.2)
                
                if loadingState.isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.2)
                }
                
                // Error state
                if loadingState.hasFailed {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundColor(.white)
                        Text("Failed to load video")
                            .foregroundColor(.white)
                            .font(.caption)
                        Button(action: {
                            handleError(strategy: .manualReset)
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
        }
    }
    
    // MARK: - Player Setup
    private func validateAndConfigureExistingPlayer() {
        guard let player = player else {
            NSLog("DEBUG: [VIDEO VALIDATE] No player to validate for \(mid)")
            return
        }
        
        NSLog("DEBUG: [VIDEO VALIDATE] Validating existing player for \(mid), mode: \(mode)")
        
        // Check if player item exists and is valid
        if let playerItem = player.currentItem {
            NSLog("DEBUG: [VIDEO VALIDATE] Player item status: \(playerItem.status.rawValue) for \(mid)")
            switch playerItem.status {
            case .readyToPlay:
                NSLog("DEBUG: [VIDEO VALIDATE] Player item is ready to play for \(mid)")
                configurePlayer(player)
            case .failed:
                NSLog("DEBUG: [VIDEO VALIDATE] Player item failed for \(mid), attempting recovery")
                handleError(strategy: .loadFailure)
            case .unknown:
                NSLog("DEBUG: [VIDEO VALIDATE] Player item status unknown for \(mid), configuring anyway (KVO will play when ready)")
                // Configure the player anyway - KVO in AVPlayerViewControllerRepresentable will trigger play when ready
                configurePlayer(player)
            @unknown default:
                NSLog("DEBUG: [VIDEO VALIDATE] Unknown player item status for \(mid)")
                configurePlayer(player)
            }
        } else {
            NSLog("DEBUG: [VIDEO VALIDATE] No player item for \(mid), setting up new player")
            setupPlayer()
        }
    }
    
    private func setupPlayer() {
        NSLog("DEBUG: [VIDEO SETUP] Setting up player for \(mid)")
        NSLog("DEBUG: [VIDEO SETUP] isVisible: \(isVisible), shouldLoadVideo: \(shouldLoadVideo), mode: \(mode)")
        NSLog("DEBUG: [VIDEO SETUP] URL: \(url)")
        
        // FIRST: Check SharedAssetCache for existing player instance
        // Use playerCacheKey (includes mode) to prevent MediaCell/TweetDetailView sharing
        NSLog("DEBUG: [VIDEO SETUP] Looking up cache with key: \(playerCacheKey)")
        
        // For MediaCell mode: DON'T reuse cached player (causes AVPlayerLayer corruption)
        // Create fresh player each time; disk cache makes it fast
        if mode == .mediaCell {
            NSLog("DEBUG: [VIDEO SETUP] MediaCell mode - will create fresh player (disk cache makes it fast)")
            // Skip player cache, create fresh player below
        } else {
            // For other modes: reuse cached AVPlayer (no layer corruption issues in fullscreen)
            if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: playerCacheKey) {
                NSLog("DEBUG: [VIDEO SETUP] ✅ Found EXISTING cached player for \(mid)")
                
                // Apply proper mute state based on mode BEFORE configuring
                // This ensures the player starts with the correct audio state
                if mode == .mediaCell {
                    cachedPlayer.isMuted = MuteState.shared.isMuted
                    NSLog("DEBUG: [VIDEO SETUP] Applied global mute state (\(MuteState.shared.isMuted)) to cached player for MediaCell")
                } else {
                    cachedPlayer.isMuted = false
                    NSLog("DEBUG: [VIDEO SETUP] Unmuted cached player for fullscreen/detail mode")
                }
                
                // Update state FIRST before configuring
                self.player = cachedPlayer
                self.loadingState = .loaded
                self.playbackState = .notStarted
                NSLog("DEBUG: [VIDEO SETUP] State updated, about to call configurePlayer for \(mid)")
                
                // Then configure
                configurePlayer(cachedPlayer)
                NSLog("DEBUG: [VIDEO SETUP] Returned from configurePlayer for \(mid)")
                return
            }
        }
        
        // SECOND: Check if we have cached content for this tweet
        let hasCachedContent = SharedAssetCache.shared.hasCachedContent(for: mid)
        NSLog("DEBUG: [VIDEO SETUP] hasCachedContent: \(hasCachedContent) for \(mid) in mode \(mode)")
        
        if hasCachedContent {
            NSLog("DEBUG: [VIDEO SETUP] Tweet \(mid) has cached content, loading from cache in mode \(mode)")
            
            // Try async loading from cache
            Task.detached(priority: .userInitiated) {
                NSLog("DEBUG: [VIDEO SETUP] Starting async Task to load player from cache for \(mid) in mode \(mode)")
                do {
                    NSLog("DEBUG: [VIDEO SETUP] Calling getOrCreatePlayer for \(mid)")
                    // Use uniquePlayerURL to ensure each tweet gets its own player instance
                    let newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(for: uniquePlayerURL, tweetId: mid, mediaType: mediaType)
                    NSLog("DEBUG: [VIDEO SETUP] getOrCreatePlayer returned successfully for \(mid)")
                    
                    // Apply mute state IMMEDIATELY after player creation, before returning to MainActor
                    // This prevents any brief moment where the player might start with wrong audio state
                    if await MainActor.run(body: { self.mode }) == .mediaCell {
                        let muteState = await MainActor.run { MuteState.shared.isMuted }
                        newPlayer.isMuted = muteState
                        NSLog("DEBUG: [VIDEO SETUP] Applied mute state (\(muteState)) immediately after player creation for MediaCell")
                    } else {
                        newPlayer.isMuted = false
                        NSLog("DEBUG: [VIDEO SETUP] Unmuted immediately after player creation for fullscreen/detail")
                    }
                    
                    await MainActor.run {
                        // Double-check and reapply mute state for safety
                        if self.mode == .mediaCell {
                            newPlayer.isMuted = MuteState.shared.isMuted
                            NSLog("DEBUG: [VIDEO SETUP] Reconfirmed mute state (\(MuteState.shared.isMuted)) before configuring MediaCell player")
                        } else {
                            newPlayer.isMuted = false
                        }
                        self.configurePlayer(newPlayer)
                    }
                } catch {
                    await MainActor.run {
                        print("DEBUG: [VIDEO SETUP] Failed to load from cache for \(mid): \(error)")
                        self.handleError(strategy: .loadFailure)
                    }
                }
            }
            return
        }
        
        // For fullscreen mode, always allow setup regardless of shouldLoadVideo
        if mode == .mediaBrowser {
            print("DEBUG: [VIDEO SETUP] Fullscreen mode - forcing player setup regardless of shouldLoadVideo for \(mid)")
        } else {
            // For MediaCell mode, respect shouldLoadVideo setting
            guard shouldLoadVideo else {
                print("DEBUG: [VIDEO SETUP] Loading disabled for \(mid) and no cache available, skipping setup")
                return
            }
        }
        
        // Reset error state when starting setup
        if loadingState.hasFailed {
            print("DEBUG: [VIDEO SETUP] Resetting error state for \(mid)")
            loadingState = .idle
        }
        
        // Check if we have a cached player first - prioritize for fullscreen modes
        NSLog("DEBUG: [VIDEO SETUP] Checking VideoStateCache for \(mid)")
        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            NSLog("DEBUG: [VIDEO CACHE] Found cached player for \(mid) in \(mode) mode")
            restoreFromCache(cachedState)
            return
        }
        NSLog("DEBUG: [VIDEO SETUP] No VideoStateCache found for \(mid)")
        
        // For fullscreen modes, if no cached state and no player, try to restore from cache again
        // This handles cases where the cache was cleared but we still need the video
        if mode == .mediaBrowser && player == nil && !loadingState.isLoading {
            NSLog("DEBUG: [VIDEO CACHE] Fullscreen mode with no player, attempting to restore cached state for \(mid)")
            restoreCachedVideoState()
            
            // If restoration found a player, we're done
            if player != nil {
                NSLog("DEBUG: [VIDEO CACHE] Successfully restored player from cache for \(mid), exiting setup")
                return
            }
            // Otherwise, continue to create new player
            NSLog("DEBUG: [VIDEO CACHE] No cached player found, will create new player for \(mid)")
        }
        
        // Otherwise, create a new player with performance considerations
        NSLog("DEBUG: [VIDEO SETUP] Creating new player for \(mid) in mode \(mode)")
        Task.detached(priority: .userInitiated) {
            NSLog("DEBUG: [VIDEO SETUP] Async Task started for \(mid)")
            do {
                // Use shared cached player for all modes - simpler and more efficient
                NSLog("DEBUG: [SimpleVideoPlayer] Getting shared player for \(mid)")
                // Use uniquePlayerURL to ensure each tweet gets its own player instance
                let newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(for: uniquePlayerURL, tweetId: mid, mediaType: mediaType)
                
                NSLog("DEBUG: [SimpleVideoPlayer] Player creation completed for \(mid)")
                
                // Apply mute state IMMEDIATELY after player creation, before returning to MainActor
                // This prevents any brief moment where the player might start with wrong audio state
                if await MainActor.run(body: { self.mode }) == .mediaCell {
                    let muteState = await MainActor.run { MuteState.shared.isMuted }
                    newPlayer.isMuted = muteState
                    NSLog("DEBUG: [VIDEO SETUP] Applied mute state (\(muteState)) immediately after player creation for MediaCell")
                } else {
                    newPlayer.isMuted = false
                    NSLog("DEBUG: [VIDEO SETUP] Unmuted immediately after player creation for fullscreen/detail")
                }
                
                await MainActor.run {
                    // Double-check and reapply mute state for safety
                    if self.mode == .mediaCell {
                        newPlayer.isMuted = MuteState.shared.isMuted
                        NSLog("DEBUG: [VIDEO SETUP] Reconfirmed mute state (\(MuteState.shared.isMuted)) before configuring MediaCell player")
                    } else {
                        newPlayer.isMuted = false
                    }
                    self.configurePlayer(newPlayer)
                }
            } catch {
                await MainActor.run {
                    print("DEBUG: [VIDEO SETUP] Failed to setup player for \(mid): \(error)")
                    NSLog("ERROR: [SimpleVideoPlayer] Failed to setup player for \(mid): \(error)")
                    self.handleError(strategy: .loadFailure)
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
            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
            setupPlayer()
            return
        }
        
        // Check if player item is in a valid state
        if playerItem.status == .failed {
            print("DEBUG: [VIDEO CACHE] Cached player item is in failed state, clearing cache and creating new player for \(mid)")
            VideoStateCache.shared.clearCache(for: mid)
            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
            setupPlayer()
            return
        }
        
        // Check if player item is ready to play
        if playerItem.status != .readyToPlay {
            print("DEBUG: [VIDEO CACHE] Cached player item not ready (status: \(playerItem.status.rawValue)), clearing cache and creating new player for \(mid)")
            VideoStateCache.shared.clearCache(for: mid)
            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
            setupPlayer()
            return
        }
        
        // CRITICAL: Set mute state BEFORE assigning to self.player
        // This prevents unmuted audio when SwiftUI re-renders
        if mode == .mediaCell {
            // Pause if playing to prevent audio bleed
            if cachedState.player.rate > 0 {
                cachedState.player.pause()
                print("DEBUG: [VIDEO CACHE] Paused playing cached player before restoring for MediaCell")
            }
            cachedState.player.isMuted = MuteState.shared.isMuted
            print("DEBUG: [VIDEO CACHE] Applied current global mute state (\(MuteState.shared.isMuted)) for MediaCell mode")
        } else {
            // For full screen modes (mediaBrowser), always unmute regardless of cached state
            cachedState.player.isMuted = false
            print("DEBUG: [VIDEO CACHE] Forced unmuted for full screen mode")
        }
        
        // Restore the cached player (AFTER setting mute state)
        self.player = cachedState.player
        
        // Ensure the player is also cached in SharedAssetCache for consistency
        SharedAssetCache.shared.cachePlayer(cachedState.player, for: playerCacheKey)
        
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
        self.loadingState = .loaded
        self.playbackState = .notStarted
    }
    
    private func configurePlayer(_ player: AVPlayer) {
        NSLog("DEBUG: [VIDEO CONFIGURE] Configuring player for \(mid)")
        NSLog("DEBUG: [VIDEO CONFIGURE] Mode: \(mode), isVisible: \(isVisible), currentAutoPlay: \(currentAutoPlay)")
        NSLog("DEBUG: [VIDEO CONFIGURE] Player item status: \(player.currentItem?.status.rawValue ?? -1)")
        NSLog("DEBUG: [VIDEO CONFIGURE] Player rate: \(player.rate), isMuted: \(player.isMuted)")
        
        // CRITICAL: For MediaCell, pause playing shared players FIRST to prevent audio bleed
        if mode == .mediaCell && player.rate > 0 {
            player.pause()
            NSLog("DEBUG: [VIDEO CONFIGURE] Paused playing shared player before configuration for MediaCell")
        }
        
        // Configure player mute state based on mode
        if mode == .mediaCell {
            // MediaCell: Apply global mute state
            player.isMuted = MuteState.shared.isMuted
            NSLog("DEBUG: [VIDEO CONFIGURE] Applied mute state for MediaCell: \(MuteState.shared.isMuted)")
        } else {
            // Fullscreen/Detail: Always unmute
            player.isMuted = false
            NSLog("DEBUG: [VIDEO CONFIGURE] Unmuted for fullscreen/detail mode")
        }
        
        // Setup time observer only if not already set up for this player
        if timeObserverPlayer !== player {
            setupTimeObserver(for: player)
        }
        
        // Only reset player position to beginning for new players, not cached ones
        // This prevents cached videos from losing their buffered segments
        if !SharedAssetCache.shared.hasCachedContent(for: mid) {
            player.seek(to: .zero)
            NSLog("DEBUG: [VIDEO CONFIGURE] Reset player position to beginning for new player")
        } else {
            NSLog("DEBUG: [VIDEO CONFIGURE] Preserving player position for cached player")
        }
        
        // Set up observers only if not already set up
        if videoCompletionObserver == nil {
            setupPlayerObservers(player)
        }
        
        // CRITICAL: Always update state, even if same player instance
        // This ensures the view's player binding is set when reusing cached players
        self.player = player
        self.loadingState = .loaded
        self.playbackState = .notStarted
        self.representableId += 1 // Force VideoPlayerRepresentable to recreate
        self.viewConfigTimestamp = Date().timeIntervalSince1970 // Force unique view ID
        NSLog("DEBUG: [VIDEO CONFIGURE] Incremented representableId to \(representableId), timestamp: \(viewConfigTimestamp) for \(mid)")
        
        // Cache the player for non-MediaCell modes only
        // MediaCell creates fresh AVPlayer from cached CachingPlayerItem each time
        if mode != .mediaCell {
            SharedAssetCache.shared.cachePlayer(player, for: playerCacheKey)
            NSLog("DEBUG: [VIDEO CONFIGURE] Cached AVPlayer with key: \(playerCacheKey) (mode: \(mode))")
        } else {
            NSLog("DEBUG: [VIDEO CONFIGURE] MediaCell mode - not caching AVPlayer (will create fresh from CachingPlayerItem each time)")
        }
        
        NSLog("DEBUG: [VIDEO CONFIGURE] About to call checkPlaybackConditions - autoPlay: \(currentAutoPlay), isVisible: \(isVisible)")
        
        // Start playback if needed
        checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
    }
    
    private func setupTimeObserver(for player: AVPlayer) {
        // Remove existing time observer if any (only from the player that added it)
        if let existingObserver = timeObserver, let observerPlayer = timeObserverPlayer {
            observerPlayer.removeTimeObserver(existingObserver)
            timeObserver = nil
            timeObserverPlayer = nil
        }
        
        // Create time observer for memory-efficient segment management
        let timeScale = CMTimeScale(NSEC_PER_SEC)
        let time = CMTime(seconds: 2.0, preferredTimescale: timeScale)
        
        timeObserver = player.addPeriodicTimeObserver(forInterval: time, queue: .main) { time in
            // AVPlayer handles its own memory management
        }
        
        // Store reference to the player that added this observer
        timeObserverPlayer = player
        
        print("DEBUG: [VIDEO TIME OBSERVER] Setup time observer for memory management for \(mid)")
    }
    
    private func setupPlayerObservers(_ player: AVPlayer) {
        guard let playerItem = player.currentItem else { return }
        
        // Store reference for cleanup
        self.playerItem = playerItem
        
        // Remove existing observers if any
        removePlayerObservers()
        
        // Video finished observer
        videoCompletionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            self.handleVideoFinished()
        }
        
        // Error observer
        videoErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { notification in
            self.handleError(strategy: .loadFailure)
        }
        
        // Note: KVO observers are not available in SwiftUI structs
        // Player status monitoring is handled through notification observers and periodic checks
    }
    
    private func removePlayerObservers() {
        // Remove observers to prevent memory leaks
        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
        
        if let observer = videoErrorObserver {
            NotificationCenter.default.removeObserver(observer)
            videoErrorObserver = nil
        }
        
        playerItem = nil
    }
    
    // MARK: - Unified Error/Recovery Handling
    
    enum RecoveryStrategy {
        case loadFailure    // Initial load failure - retry with backoff
        case manualReset    // User triggered reset - clear everything and restart
        case networkRecovery // Network came back - fresh attempt
        case backgroundRecovery // App backgrounded - clear player
    }
    
    private func handleError(strategy: RecoveryStrategy = .loadFailure) {
        let currentRetryCount = loadingState.retryCount
        print("DEBUG: [VIDEO ERROR] Handling error with strategy: \(strategy) for \(mid), retryCount: \(currentRetryCount)")
        
        // Clear caches using uniquePlayerURL to match caching key
        VideoStateCache.shared.clearCache(for: mid)
        SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
        
        Task.detached {
            await MainActor.run {
                SharedAssetCache.shared.clearAssetCache(for: self.mid)
            }
        }
        
        // Apply strategy
        switch strategy {
        case .loadFailure:
            removePlayerObservers()
            
            // Clear player if max retries reached
            if currentRetryCount >= 3 {
                player = nil
                loadingState = .failed(retryCount: 3)
            } else {
                loadingState = .failed(retryCount: currentRetryCount)
            }
            
            // For fullscreen, try to restore from cache
            if mode == .mediaBrowser {
                restoreCachedVideoState()
            } else if currentRetryCount < 3 {
                // For MediaCell, retry immediately
                loadingState = .failed(retryCount: currentRetryCount + 1)
                setupPlayer()
            }
            
        case .manualReset, .networkRecovery:
            loadingState = .loading
            playbackState = .notStarted
            
            if shouldLoadVideo {
                setupPlayer()
            }
            
        case .backgroundRecovery:
            player = nil
            loadingState = .loading
            
            if shouldLoadVideo {
                setupPlayer()
            }
        }
    }
    
    private func handleVideoFinished() {
        print("DEBUG: [SimpleVideoPlayer] Video finished playing for \(mid)")
        
        // For MediaCell mode, pause immediately then rewind (don't auto-restart)
        if mode == .mediaCell {
            print("DEBUG: [SimpleVideoPlayer] MediaCell mode - pausing and rewinding to beginning for \(mid)")
            player?.pause()
            // Ensure mute state is correct (respect global mute state)
            player?.isMuted = MuteState.shared.isMuted
            playbackState = .finished
            player?.seek(to: .zero)
            onVideoFinished?()
            return
        }
        
        // For fullscreen/detail modes, rewind and auto-restart
        player?.seek(to: .zero) { finished in
            guard finished else { return }
            
            if !self.disableAutoRestart {
                print("DEBUG: [SimpleVideoPlayer] Auto-restarting video for \(self.mid)")
                self.player?.play()
                self.playbackState = .playing
            } else {
                print("DEBUG: [SimpleVideoPlayer] Video ready to replay for \(self.mid)")
                self.playbackState = .finished
            }
        }
        
        onVideoFinished?()
    }
    
    private func restoreCachedVideoState() {
        // Check if we have a cached state
        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            print("DEBUG: [VIDEO CACHE] Restoring cached video state for \(mid)")
            restoreFromCache(cachedState)
        } else {
            // Fallback: check SharedAssetCache for cached player (app restart scenarios)
            // Use uniquePlayerURL (with query params) to match caching key
            if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: playerCacheKey) {
                print("DEBUG: [VIDEO CACHE] No VideoStateCache found, but found cached player in SharedAssetCache for \(mid) with key: \(playerCacheKey)")
                
                // CRITICAL: Prepare player state before using it
                if mode == .mediaCell {
                    // Pause if playing to prevent audio bleed
                    if cachedPlayer.rate > 0 {
                        cachedPlayer.pause()
                        print("DEBUG: [VIDEO CACHE] Paused playing SharedAssetCache player before restoring for MediaCell")
                    }
                    cachedPlayer.isMuted = MuteState.shared.isMuted
                    print("DEBUG: [VIDEO CACHE] Applied mute state for MediaCell from SharedAssetCache: \(MuteState.shared.isMuted)")
                } else if mode == .mediaBrowser || mode == .tweetDetail {
                    cachedPlayer.isMuted = false
                    print("DEBUG: [VIDEO CACHE] Forced unmuted for fullscreen/detail from SharedAssetCache")
                }
                
                configurePlayer(cachedPlayer)
            }
        }
    }
    
    private func checkPlaybackConditions(autoPlay: Bool, isVisible: Bool) {
        NSLog("DEBUG: [VIDEO PLAYBACK] Checking playback conditions for \(mid)")
        NSLog("DEBUG: [VIDEO PLAYBACK] autoPlay: \(autoPlay), isVisible: \(isVisible), mode: \(mode)")
        NSLog("DEBUG: [VIDEO PLAYBACK] player: \(player != nil), loadingState: \(loadingState), shouldLoadVideo: \(shouldLoadVideo)")
        
        // Validate player state before attempting playback
        if let player = player, let playerItem = player.currentItem {
            if playerItem.status == .failed {
                NSLog("DEBUG: [VIDEO VALIDATION] Player item is in failed state for \(mid), triggering recovery")
                handleError(strategy: .loadFailure)
                return
            }
        }
        
        // Check if all conditions are met for autoplay
        // For fullscreen and detail modes, bypass shouldLoadVideo check
        let shouldCheckLoading = mode == .mediaCell ? shouldLoadVideo : true
        NSLog("DEBUG: [VIDEO PLAYBACK] shouldCheckLoading: \(shouldCheckLoading)")
        
        if autoPlay && isVisible && player != nil && !loadingState.isLoading && shouldCheckLoading {
            NSLog("DEBUG: [VIDEO PLAYBACK] ✅ All conditions met, starting playback for \(mid)")
            
            // Activate audio session for video playback
            AudioSessionManager.shared.activateForVideoPlayback()
            
        // For MediaCell mode, don't auto-restart if video has finished
        if mode == .mediaCell && playbackState.hasFinished {
            NSLog("DEBUG: [VIDEO PLAYBACK] MediaCell mode - video has finished, not auto-restarting for \(mid)")
            return
        }
            
            // Always ensure video is reset to beginning if it has finished playing
            if playbackState.hasFinished || isVideoAtEnd(player!) {
                NSLog("DEBUG: [VIDEO PLAYBACK] Video is at end, restarting from beginning for \(mid)")
                player?.seek(to: .zero) { finished in
                    if finished {
                        self.playbackState = .notStarted
                        // Only auto-play if not in MediaCell mode or if explicitly allowed
                        if self.mode != .mediaCell {
                            player?.play()
                            self.playbackState = .playing
                        }
                    }
                }
            } else {
                // For mediaBrowser (fullscreen), don't call play() here
                // Let AVPlayerViewController's updateUIViewController handle it after layer is ready
                // For mediaCell and tweetDetail, call play() immediately (they use VideoPlayer, not AVPlayerViewController)
                if mode == .mediaBrowser {
                    NSLog("DEBUG: [VIDEO PLAYBACK] Fullscreen mode - will play() in AVPlayerViewController update")
                    // Set playbackState but don't call play() yet
                    playbackState = .playing
                } else {
                    NSLog("DEBUG: [VIDEO PLAYBACK] Calling player.play() for \(mid)")
                    player?.play()
                    playbackState = .playing
                }
            }
        } else {
            NSLog("DEBUG: [VIDEO PLAYBACK] ❌ Conditions NOT met for \(mid) - autoPlay:\(autoPlay), isVisible:\(isVisible), player:\(player != nil), loading:\(loadingState.isLoading), shouldCheck:\(shouldCheckLoading)")
        }
    }
    
    private func isVideoAtEnd(_ player: AVPlayer) -> Bool {
        guard let playerItem = player.currentItem else { return false }
        
        let currentTime = player.currentTime()
        let duration = playerItem.duration
        
        // Check if current time is very close to the end (within 0.1 seconds)
        if duration.isValid && !duration.isIndefinite {
            let timeDifference = CMTimeSubtract(duration, currentTime)
            return CMTimeCompare(timeDifference, CMTime(seconds: 0.1, preferredTimescale: duration.timescale)) <= 0
        }
        
        return false
    }
    
    
    private func handleLoadingStateChange(newShouldLoadVideo: Bool) {
        print("DEBUG: [VIDEO LOADING STATE] Loading state changed to \(newShouldLoadVideo) for \(mid)")
        print("DEBUG: [VIDEO LOADING STATE] Current state - player: \(player != nil), isVisible: \(isVisible)")
        
        if newShouldLoadVideo {
            // Loading enabled - set up player if needed
            if player == nil {
                print("DEBUG: [VIDEO SETUP] Loading enabled, setting up player for \(mid)")
                setupPlayer()
            } else {
                // Player exists, validate and reconfigure it
                print("DEBUG: [VIDEO SETUP] Loading enabled, player exists, validating for \(mid)")
                validateAndConfigureExistingPlayer()
                checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
            }
        } else {
            // Loading disabled - pause player
            print("DEBUG: [VIDEO SETUP] Loading disabled, pausing player for \(mid)")
            player?.pause()
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
                        NSLog("DEBUG: [VIDEO REATTACH] Resuming playback for \(self.mid)")
                        player.play()
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
            
            func makeCoordinator() -> Coordinator {
                Coordinator()
            }
            
            class Coordinator: NSObject {
                var statusObserver: NSKeyValueObservation?
                
                override init() {
                    super.init()
                }
                
                deinit {
                    statusObserver?.invalidate()
                }
            }
            
            func makeUIViewController(context: Context) -> AVPlayerViewController {
                NSLog("DEBUG: [AVPlayerViewController] makeUIViewController CALLED - creating new controller")
                let controller = AVPlayerViewController()
                controller.showsPlaybackControls = true
                controller.videoGravity = .resizeAspect
                controller.view.backgroundColor = .black
                
                // Set player immediately to ensure it's attached from the start
                controller.player = player
                NSLog("DEBUG: [AVPlayerViewController] Set player in makeUIViewController")
                
                if let player = player {
                    NSLog("DEBUG: [AVPlayerViewController] Created controller with player")
                    NSLog("DEBUG: [AVPlayerViewController] Player item status: \(player.currentItem?.status.rawValue ?? -1)")
                    NSLog("DEBUG: [AVPlayerViewController] Player rate: \(player.rate)")
                } else {
                    NSLog("DEBUG: [AVPlayerViewController] Created with nil player - this shouldn't happen!")
                }
                
                return controller
            }
            
            func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
                NSLog("DEBUG: [AVPlayerViewController] Updating with player: \(player != nil)")
                NSLog("DEBUG: [AVPlayerViewController] Previous player: \(uiViewController.player != nil)")
                NSLog("DEBUG: [AVPlayerViewController] Same player instance: \(uiViewController.player === player)")
                
                if let player = player {
                    NSLog("DEBUG: [AVPlayerViewController] New player item status: \(player.currentItem?.status.rawValue ?? -1)")
                    NSLog("DEBUG: [AVPlayerViewController] New player rate: \(player.rate)")
                }
                
                // CRITICAL: Detach player first, then re-attach
                // This ensures the player's layer is not attached to any other view
                let isSameInstance = uiViewController.player === player
                if !isSameInstance {
                    NSLog("DEBUG: [AVPlayerViewController] Setting NEW player instance")
                } else {
                    NSLog("DEBUG: [AVPlayerViewController] Re-setting SAME player instance to refresh layer")
                }
                
                // Detach and reattach to force fresh layer connection
                uiViewController.player = nil
                uiViewController.player = player
                
                // CRITICAL: For fullscreen/detail, always trigger play() here after layer is attached
                // This ensures the video layer is ready before playback starts
                if let player = player {
                    if player.currentItem?.status == .readyToPlay {
                        NSLog("DEBUG: [AVPlayerViewController] Player ready, triggering play() now that layer is attached")
                        player.play()
                    } else if player.currentItem?.status == .unknown {
                        NSLog("DEBUG: [AVPlayerViewController] Player item not ready yet, observing status")
                        // Observe when it becomes ready - store in coordinator to keep it alive
                        context.coordinator.statusObserver = player.currentItem?.observe(\.status, options: [.new]) { item, change in
                            if item.status == .readyToPlay {
                                NSLog("DEBUG: [AVPlayerViewController] Player item NOW ready, triggering play")
                                player.play()
                            }
                        }
                    }
                }
            }
        }
