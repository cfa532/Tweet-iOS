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
    
    var isLoaded: Bool {
        if case .loaded = self { return true }
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
    private var cache: [String: (player: AVPlayer, time: CMTime, wasPlaying: Bool, originalMuteState: Bool, timestamp: Date)] = [:]
    private let cacheExpirationInterval: TimeInterval = 600 // 10 minutes
    
    private init() {}
    
    func cacheVideoState(for mid: String, player: AVPlayer, time: CMTime, wasPlaying: Bool, originalMuteState: Bool) {
        cache[mid] = (player: player, time: time, wasPlaying: wasPlaying, originalMuteState: originalMuteState, timestamp: Date())
    }
    
    func getCachedState(for mid: String) -> (player: AVPlayer, time: CMTime, wasPlaying: Bool, originalMuteState: Bool)? {
        guard let cachedState = cache[mid] else {
            return nil
        }
        
        // Check if cache is stale
        let age = Date().timeIntervalSince(cachedState.timestamp)
        if age > cacheExpirationInterval {
            print("DEBUG: [VIDEO CACHE] Cache for \(mid) is stale (age: \(age)s), clearing")
            cache.removeValue(forKey: mid)
            return nil
        }
        
        // Validate player is still valid
        if cachedState.player.currentItem == nil || cachedState.player.currentItem?.status == .failed {
            print("DEBUG: [VIDEO CACHE] Cached player for \(mid) is invalid, clearing")
            cache.removeValue(forKey: mid)
            return nil
        }
        
        return (player: cachedState.player, time: cachedState.time, wasPlaying: cachedState.wasPlaying, originalMuteState: cachedState.originalMuteState)
    }
    
    func clearCache(for mid: String) {
        print("DEBUG: [VIDEO CACHE] Clearing cache for \(mid)")
        cache.removeValue(forKey: mid)
    }
    
    func clearAllCache() {
        print("DEBUG: [VIDEO CACHE] Clearing all cache")
        cache.removeAll()
    }
    
    /// Clear stale cached states (older than expiration interval)
    func clearStaleCache() {
        let now = Date()
        let staleKeys = cache.filter { now.timeIntervalSince($0.value.timestamp) > cacheExpirationInterval }.map { $0.key }
        
        for key in staleKeys {
            cache.removeValue(forKey: key)
        }
        
        if !staleKeys.isEmpty {
            print("DEBUG: [VIDEO CACHE] Cleared \(staleKeys.count) stale cached states")
        }
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
    @State private var retryAttempts: Int = 0 // Track retry attempts separately
    @State private var isLongPressing = false
    @State private var isPlayerDetached = false  // Track background state
    @State private var hasRecoveredThisCycle = false  // Prevent double recovery (background + screen lock)
    @State private var didEnterBackground = false  // Track if we actually went to background (vs just screen lock)
    @State private var isBuffering = false // Track buffering state
    @State private var playerItem: AVPlayerItem? // Keep reference for observer cleanup
    @State private var videoCompletionObserver: NSObjectProtocol?
    @State private var videoErrorObserver: NSObjectProtocol?
    @State private var videoStallObserver: NSObjectProtocol?
    @State private var playerItemStatusObserver: NSKeyValueObservation?
    @State private var playerItemBufferObserver: NSKeyValueObservation?
    @State private var timeObserver: Any?
    @State private var timeObserverPlayer: AVPlayer?
    @State private var representableId: Int = 0 // Force VideoPlayerRepresentable recreation
    @State private var viewConfigTimestamp: TimeInterval = 0 // Timestamp when view was last configured
    @State private var progressiveBufferTargetIndex: Int = 0
    
    private let progressiveBufferTargets: [Double] = [8.0, 12.0, 18.0, 24.0, 30.0]
    /// Minimum buffered seconds required before we consider the first frame renderable.
    private var firstFrameMinimumBuffer: Double {
        mediaType == .video ? 3.0 : 0.1
    }
    
    private var isProgressiveMedia: Bool {
        mediaType == .video
    }
    
    /// Minimum buffered seconds required before we resume playback after a stall.
    private var stallRecoveryMinimumBuffer: Double {
        isProgressiveMedia ? 5.0 : 0.5
    }
    
    /// Target forward buffer (in seconds) we want AVPlayer to maintain for progressive videos.
    private var progressiveForwardBufferDuration: Double {
        progressiveBufferTargets[progressiveBufferTargetIndex]
    }
    
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
        // Use mid (mediaID) for stable caching - URLs can have query params that change
        return mid
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
        videoContentView
            .onAppear { handleOnAppear() }
            .onDisappear { handleOnDisappear() }
            .onChange(of: mode) { oldMode, newMode in handleModeChange(oldMode: oldMode, newMode: newMode) }
            .onChange(of: isMuted) { _, newMuteState in handleMuteChange(newMuteState: newMuteState) }
            .onReceive(MuteState.shared.$isMuted) { globalMuteState in handleGlobalMuteChange(globalMuteState: globalMuteState) }
            .onChange(of: currentAutoPlay) { _, shouldAutoPlay in handleAutoPlayChange(shouldAutoPlay: shouldAutoPlay) }
            .onChange(of: isVisible) { _, visible in handleVisibilityChange(visible: visible) }
            // Observe VideoManager's currentVideoIndex changes for sequential playback
            .modifier(VideoManagerObserverModifier(videoManager: videoManager, mid: mid, mode: mode) { shouldAutoPlay in
                handleAutoPlayChange(shouldAutoPlay: shouldAutoPlay)
            })
            .onChange(of: player) { _, newPlayer in handlePlayerChange(newPlayer: newPlayer) }
            .onChange(of: shouldLoadVideo) { _, newShouldLoadVideo in handleLoadingStateChange(newShouldLoadVideo: newShouldLoadVideo) }
            .onReceive(NotificationCenter.default.publisher(for: .stopAllVideos)) { _ in handleStopAllVideos() }
            .onReceive(NotificationCenter.default.publisher(for: .videoInfrastructureRestarted)) { _ in handleVideoInfrastructureRestarted() }
            .onReceive(NotificationCenter.default.publisher(for: .videoLayerRefresh)) { _ in handleVideoLayerRefresh() }
            .onReceive(NotificationCenter.default.publisher(for: .appUserReady)) { _ in handleAppUserReady() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in handleWillResignActive() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in handleDidEnterBackground() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in handleWillEnterForeground() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in handleDidBecomeActive() }
            .onTapGesture { handleTap() }
            .onLongPressGesture(minimumDuration: 0.5) { handleLongPress() } onPressingChanged: { pressing in handlePressingChanged(pressing: pressing) }
    }
    
    private var videoContentView: some View {
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
    }
    
    // MARK: - Lifecycle Handlers
    
    private func handleOnAppear() {
        
        // Handle idle timer for fullscreen modes
        if mode == .mediaBrowser {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        
        // For fullscreen and detail modes, always try to set up player regardless of shouldLoadVideo
        if mode == .mediaBrowser || mode == .tweetDetail {
            if player == nil {
                // Reset loading state if stuck
                if loadingState.isLoading {
                    print("DEBUG: [VIDEO APPEAR] loadingState stuck at .loading, resetting to .idle")
                    loadingState = .idle
                }
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
            // Reset loading state if stuck
            if loadingState.isLoading {
                print("DEBUG: [VIDEO APPEAR] loadingState stuck at .loading, resetting to .idle")
                loadingState = .idle
            }
            setupPlayer()
        }
    }
    
    private func handleOnDisappear() {
        // Handle idle timer for fullscreen modes
        if mode == .mediaBrowser {
            UIApplication.shared.isIdleTimerDisabled = false
            
            // Before exiting full screen, restore the mute state to global mute state
            // This ensures the player instance is properly muted when returning to MediaCell
            if let player = player {
                player.isMuted = MuteState.shared.isMuted
            }
        }
        
        // Remove observers to prevent memory leaks
        removePlayerObservers()

        // Cache the current video state (MediaCell only, NOT TweetDetail or MediaBrowser)
        // TweetDetail uses DetailVideoManager singleton and should not share players with MediaCell
        // MediaBrowser uses FullScreenVideoManager singleton and should not share players with MediaCell
        if mode == .mediaCell, let player = player {
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
        
        // CRITICAL: Always pause player when view disappears
        // MediaCell and MediaBrowser share the same player instance via VideoStateCache
        if mode == .mediaCell {
            player?.pause()
            // Ensure muteState is correct when pausing MediaCell
            if let player = player {
                player.isMuted = MuteState.shared.isMuted
                NSLog("🔇 [PLAYER MUTE] handleOnDisappear - Applied global mute state for MediaCell: \(MuteState.shared.isMuted) for \(mid)")
            }
        } else if mode == .mediaBrowser {
            // Exiting fullscreen - ALWAYS pause and restore mute state for MediaCell reuse
            player?.pause()
            if let player = player {
                // Restore mute state to global state before returning to MediaCell
                player.isMuted = MuteState.shared.isMuted
                NSLog("🔇 [PLAYER MUTE] handleOnDisappear - Restored global mute state after exiting fullscreen: \(MuteState.shared.isMuted) for \(mid)")
            }
        } else if mode == .tweetDetail {
            // TweetDetail: Pause singleton player when view disappears
            // The task defer in TweetDetailView also handles cleanup, but we should pause here too
            DetailVideoManager.shared.currentPlayer?.pause()
            NSLog("DEBUG: [VIDEO DISAPPEAR] TweetDetail view disappeared - paused singleton player for \(mid)")
        }
    }
    
    private func handleModeChange(oldMode: Mode, newMode: Mode) {
        NSLog("DEBUG: [VIDEO MODE CHANGE] ========== MODE TRANSITION START ==========")
        NSLog("DEBUG: [VIDEO MODE CHANGE] Transitioning \(mid) from \(oldMode) to \(newMode)")
        NSLog("DEBUG: [VIDEO MODE CHANGE] Current player: \(player != nil)")
        NSLog("DEBUG: [VIDEO MODE CHANGE] Player item: \(player?.currentItem != nil)")
        NSLog("DEBUG: [VIDEO MODE CHANGE] Player item status: \(player?.currentItem?.status.rawValue ?? -999)")
        NSLog("DEBUG: [VIDEO MODE CHANGE] Player rate: \(player?.rate ?? -1)")
        NSLog("DEBUG: [VIDEO MODE CHANGE] Current representableId: \(representableId)")
        
        // When mode changes, apply appropriate mute state
        guard let player = player else {
            NSLog("DEBUG: [VIDEO MODE CHANGE] ⚠️ No player available during mode change for \(mid)")
            return
        }
        
        if newMode == .mediaBrowser {
            // Entering full screen - force unmute
            NSLog("DEBUG: [VIDEO MODE CHANGE] Entering fullscreen")
            
            player.isMuted = false
            NSLog("DEBUG: [VIDEO MODE CHANGE] Unmuted player for fullscreen")
            
            // CRITICAL: Force layer detachment and increment representableId
            // This ensures the VideoPlayerRepresentable in MediaCell releases the layer
            // before AVPlayerViewController tries to use it, preventing black screen
            self.representableId += 1
            NSLog("DEBUG: [VIDEO MODE CHANGE] Incremented representableId to \(self.representableId) to force layer detachment from MediaCell")
            
            // Don't pause here - let AVPlayerViewController handle play/pause
            NSLog("DEBUG: [VIDEO MODE CHANGE] AVPlayerViewController will handle playback")
        } else if newMode == .mediaCell && oldMode == .mediaBrowser {
            // Exiting full screen to MediaCell - apply global mute state
            NSLog("DEBUG: [VIDEO MODE CHANGE] Exiting fullscreen to MediaCell")
            
            // Store playback state before transition
            let wasPlaying = player.rate > 0
            let currentTime = player.currentTime()
            
            // Pause player to allow clean layer detachment
            player.pause()
            NSLog("DEBUG: [VIDEO MODE CHANGE] Paused player for layer transition from fullscreen")
            
            // Apply global mute state
            player.isMuted = MuteState.shared.isMuted
            NSLog("DEBUG: [VIDEO MODE CHANGE] Applied global mute state: \(MuteState.shared.isMuted)")
            
            // Force recreation of VideoPlayerRepresentable to ensure fresh layer attachment
            self.representableId += 1
            NSLog("DEBUG: [VIDEO MODE CHANGE] Incremented representableId to \(self.representableId) for fresh MediaCell layer")
            
            // Resume playback using proper completion handler instead of arbitrary delay
            if wasPlaying {
                // CRITICAL: Always ensure muteState is correct before resuming playback in MediaCell
                player.isMuted = MuteState.shared.isMuted
                NSLog("🔇 [PLAYER MUTE] handleModeChange - Applied global mute state before resuming MediaCell: \(MuteState.shared.isMuted) for \(mid)")
                
                // Seek to current position with completion handler to ensure layer is ready
                player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    guard finished else { return }
                    NSLog("DEBUG: [VIDEO MODE CHANGE] Layer ready, resuming playback in MediaCell")
                    player.play()
                }
            }
        } else if newMode == .mediaCell {
            // Any other transition to MediaCell - apply global mute state
            player.isMuted = MuteState.shared.isMuted
            NSLog("DEBUG: [VIDEO MODE CHANGE] Transitioned to MediaCell (\(oldMode) -> \(newMode)), applied global mute state: \(MuteState.shared.isMuted)")
        }
        
        NSLog("DEBUG: [VIDEO MODE CHANGE] ========== MODE TRANSITION END ==========")
    }
    
    private func handleMuteChange(newMuteState: Bool) {
        // For full screen modes, always keep unmuted regardless of the isMuted parameter
        if mode == .mediaBrowser {
            player?.isMuted = false
            print("DEBUG: [VIDEO MUTE CHANGE] Forced unmuted for full screen mode")
        } else {
            player?.isMuted = newMuteState
        }
    }
    
    private func handleGlobalMuteChange(globalMuteState: Bool) {
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
    
    private func handleAutoPlayChange(shouldAutoPlay: Bool) {
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
    
    private func handleVisibilityChange(visible: Bool) {
        print("DEBUG: [VIDEO VISIBILITY] isVisible changed to \(visible) for \(mid)")
        print("DEBUG: [VIDEO VISIBILITY] shouldLoadVideo: \(shouldLoadVideo), player: \(player != nil), mode: \(mode)")
        
        // Handle visibility changes - simplified logic to avoid conflicts
        if visible {
            // For fullscreen and detail modes, always allow setup regardless of shouldLoadVideo
            if mode == .mediaBrowser || mode == .tweetDetail {
                NSLog("DEBUG: [VIDEO VISIBILITY] Fullscreen/Detail mode - checking state for \(mid)")
                
                // Check if video failed and needs retry
                if loadingState.hasFailed {
                    NSLog("✅ [VIDEO VISIBILITY] Fullscreen video was in failed state, retrying load for \(mid)")
                    player = nil
                    loadingState = .idle
                    playbackState = .notStarted
                    setupPlayer()
                    return
                }
                
                if player == nil {
                    // Reset loading state if stuck
                    if loadingState.isLoading {
                        NSLog("DEBUG: [VIDEO VISIBILITY] loadingState stuck at .loading, resetting to .idle")
                        loadingState = .idle
                    }
                    setupPlayer()
                } else {
                    // Check if player is ready and should play
                    if let playerItem = player?.currentItem {
                        let hasBufferedData = !playerItem.loadedTimeRanges.isEmpty
                        let isPlayerReady = playerItem.status == .readyToPlay || hasBufferedData
                        
                        if isPlayerReady {
                            NSLog("✅ [VIDEO VISIBILITY] Fullscreen player ready with data for \(mid)")
                            if loadingState.isLoading {
                                loadingState = .loaded
                            }
                            
                            // Auto-play fullscreen videos if not already playing
                            if player?.rate == 0 {
                                // For fullscreen mode, always unmute
                                player?.isMuted = false
                                NSLog("▶️ [VIDEO VISIBILITY] Starting fullscreen playback for \(mid)")
                                player?.play()
                                playbackState = .playing
                            }
                            return
                        }
                    }
                    
                    validateAndConfigureExistingPlayer()
                }
                return
            }
            
            // For MediaCell mode, respect shouldLoadVideo setting
            guard shouldLoadVideo else {
                print("DEBUG: [VIDEO VISIBILITY] Video became visible but loading is disabled for \(mid)")
                return
            }
            
            // Check if video is in failed state and needs retry
            if loadingState.hasFailed {
                print("✅ [VIDEO VISIBILITY] Video was in failed state, retrying load for \(mid)")
                player = nil
                loadingState = .idle
                playbackState = .notStarted
                setupPlayer()
                return
            }
            
            // Validate existing player state if present
            if let player = player, let playerItem = player.currentItem {
                if playerItem.status == .failed {
                    print("DEBUG: [VIDEO VISIBILITY] Player item failed, retrying for \(mid)")
                    handleError(strategy: .loadFailure)
                    return
                }
                
                // Check if player has data ready and should play
                let hasBufferedData = !playerItem.loadedTimeRanges.isEmpty
                let isPlayerReady = playerItem.status == .readyToPlay || hasBufferedData
                
                if isPlayerReady {
                    print("✅ [VIDEO VISIBILITY] Player ready with data for \(mid), checking playback conditions")
                    
                    // Update loading state to show video is ready
                    if loadingState.isLoading {
                        loadingState = .loaded
                        retryAttempts = 0  // Reset retry counter on successful load
                    }
                    
                    // Check if should auto-play
                    if currentAutoPlay && player.rate == 0 {
                        // CRITICAL: Always ensure muteState is correct before playing
                        // For MediaCell, always respect global muteState
                        if mode == .mediaCell {
                            player.isMuted = MuteState.shared.isMuted
                            NSLog("🔇 [PLAYER MUTE] handleVisibilityChange - Applied global mute state for MediaCell: \(MuteState.shared.isMuted) for \(mid)")
                        }
                        print("▶️ [VIDEO VISIBILITY] Starting playback for visible ready video: \(mid)")
                        player.play()
                        playbackState = .playing
                    }
                    return
                }
            }
            
            // If no player and loading is enabled, set up the player
            if player == nil {
                print("DEBUG: [VIDEO VISIBILITY] Video became visible with no player, setting up: \(mid)")
                // Reset loading state if stuck
                if loadingState.isLoading {
                    print("DEBUG: [VIDEO VISIBILITY] loadingState stuck at .loading, resetting to .idle")
                    loadingState = .idle
                }
                setupPlayer()
            } else {
                // SANITY CHECK: Run when becoming visible to catch broken players
                // Check if player or currentItem is missing first (common after long background)
                let playerIsMissing = player == nil || player?.currentItem == nil
                let playerIsBroken = !playerIsMissing && isPlayerBroken()
                
                if playerIsMissing || playerIsBroken {
                    print("⚠️ [VIDEO VISIBILITY] Sanity check failed - player is \(playerIsMissing ? "missing" : "broken"), recreating for \(mid)")
                    SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
                    player = nil
                    loadingState = .idle
                    playbackState = .notStarted
                    setupPlayer()
                    return
                }
                
                // Player is healthy, restore cached state
                restoreCachedVideoState()
                checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: visible)
            }
        } else {
            // When becoming invisible, cache state but don't pause here
            // (pause is handled in onDisappear to avoid conflicts)
            // TweetDetail uses DetailVideoManager singleton and should not share players with MediaCell
            // MediaBrowser uses FullScreenVideoManager singleton and should not share players with MediaCell
            if mode == .mediaCell, let player = player {
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
                resetProgressiveBufferTarget(for: player.currentItem)
            }

            if mode == .mediaCell {
                if let player = player, player.rate != 0 {
                    NSLog("DEBUG: [VIDEO VISIBILITY] MediaCell hidden - pausing playback for \(mid)")
                    player.pause()
                    playbackState = .paused
                }
            }
        }
    }
    
    private func handlePlayerChange(newPlayer: AVPlayer?) {
        // When player becomes available, check if we should autoplay
        if newPlayer != nil {
            checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
        }
    }
    
    private func handleStopAllVideos() {
        // Only pause MediaCell videos - TweetDetail and MediaBrowser are immune
        if mode == .mediaCell {
            player?.pause()
            player?.isMuted = true
        }
        // TweetDetail and MediaBrowser: DO NOTHING
    }
    
    private func handleWillResignActive() {
        // CRITICAL: This handles BOTH screen lock AND app backgrounding
        // Screen lock: willResignActive → (locked) → didBecomeActive
        // App background: willResignActive → didEnterBackground → willEnterForeground → didBecomeActive
        print("DEBUG: [VIDEO RESIGN ACTIVE] App will resign active for \(mid), mode: \(mode)")
        
        // Reset flags
        hasRecoveredThisCycle = false
        didEnterBackground = false  // Reset - will be set to true if didEnterBackground fires
        
        // Cache player state but DON'T detach yet - keep video visible
        cachePlayerStateForBackground()
    }
    
    private func handleDidEnterBackground() {
        // App actually went to background (not just screen lock)
        print("DEBUG: [VIDEO BACKGROUND] App entering background for \(mid)")
        didEnterBackground = true  // Mark that we went to background (not just screen lock)
    }
    
    private func handleWillEnterForeground() {
        print("DEBUG: [VIDEO FOREGROUND] App will enter foreground for \(mid)")
        recoverFromBackground()
    }
    
    private func handleDidBecomeActive() {
        print("DEBUG: [VIDEO APP ACTIVE] App became active for \(mid), mode: \(mode)")
        // Recover from screen lock (which triggers didBecomeActive but not willEnterForeground)
        // Only recover if we haven't already recovered in this cycle (to avoid duplicate recovery)
        if !hasRecoveredThisCycle {
            print("DEBUG: [VIDEO APP ACTIVE] Recovering from screen lock for \(mid)")
            recoverFromBackground()
            // Note: recoverFromBackground() already increments representableId, so we don't do it again here
        } else {
            print("DEBUG: [VIDEO APP ACTIVE] Already recovered in willEnterForeground, skipping for \(mid)")
            // willEnterForeground already called recoverFromBackground() which refreshed the view
            // No need to refresh again
        }
    }
    
    /// SANITY CHECK: Detects if player is broken
    private func isPlayerBroken() -> Bool {
        guard let player = player else { return true }
        guard let playerItem = player.currentItem else { return true }
        
        // Check 1: Status is failed
        if playerItem.status == .failed {
            return true
        }
        
        // Check 2: For screen lock recovery, don't check loadedTimeRanges alone
        // iOS might temporarily clear this data after screen lock, but it will reload
        // Only check loadedTimeRanges if status is .readyToPlay AND duration is invalid
        // This prevents false positives where player is healthy but temporarily has no ranges
        if playerItem.status == .readyToPlay && 
           playerItem.loadedTimeRanges.isEmpty && 
           !playerItem.duration.isValid {
            print("⚠️ [SANITY CHECK] Player ready but no loaded data AND invalid duration - likely broken")
            return true
        }
        
        if shouldForceProgressiveReload(player: player, item: playerItem) {
            NSLog("⚠️ [SANITY CHECK] Progressive player stalled, marking as broken for \(mid)")
            return true
        }
        
        return false
    }
    
    private func shouldForceProgressiveReload(player: AVPlayer, item: AVPlayerItem) -> Bool {
        guard isProgressiveMedia else { return false }
        guard loadingState.isLoaded else { return false }
        guard item.status == .readyToPlay else { return false }
        
        // Ignore intentional pauses
        if playbackState == .paused || player.timeControlStatus == .paused {
            return false
        }
        
        let waitingForData = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let bufferEmpty = item.isPlaybackBufferEmpty
        let notLikelyToKeepUp = !item.isPlaybackLikelyToKeepUp
        if !(waitingForData || bufferEmpty || notLikelyToKeepUp) {
            return false
        }
        
        let bufferedAhead = bufferedTimeAhead(for: item, player: player)
        let minimumBufferThreshold = max(0.5, stallRecoveryMinimumBuffer * 0.25)
        return bufferedAhead < minimumBufferThreshold
    }
    
    /// RECOVERY: Restore playback after background (with sanity check as safety net)
    private func recoverFromBackground() {
        print("DEBUG: [VIDEO RECOVERY] Starting recovery for \(mid), mode: \(mode), didEnterBackground: \(didEnterBackground), shouldLoadVideo: \(shouldLoadVideo)")
        
        // Mark that we've recovered (but don't reattach yet)
        hasRecoveredThisCycle = true
        
        // SMART RECOVERY STRATEGY:
        // - Screen lock (didEnterBackground=false): AGGRESSIVE - always recreate MediaCell players
        // - App background (didEnterBackground=true): GENTLE - only recreate if broken
        
        let isScreenLock = !didEnterBackground
        
        let isProgressive = (mediaType == .video)
        
        if mode == .mediaCell && isProgressive && player != nil && shouldLoadVideo && isScreenLock && isVisible {
            // SCREEN LOCK RECOVERY FOR VISIBLE VIDEOS: Force complete player recreation
            print("DEBUG: [VIDEO RECOVERY] Screen lock for VISIBLE video - forcing complete refresh")
            
            let currentTime = player?.currentTime() ?? .zero
            
            // Clean up observer
            if let observer = timeObserver, let observerPlayer = timeObserverPlayer {
                observerPlayer.removeTimeObserver(observer)
            }
            timeObserver = nil
            timeObserverPlayer = nil
            
            // CRITICAL: Remove from SharedAssetCache to force fresh creation
            SharedAssetCache.shared.removeInvalidPlayer(for: mid)
            
            player?.pause()
            player = nil
            loadingState = .idle
            playbackState = .notStarted
            
            // Recreate completely fresh player (not from cache)
            setupPlayer()
            
            // Wait for player to be ready, then restore position and autoplay
            Task { @MainActor in
                // Poll for player to be ready (setupPlayer is async internally)
                var attempts = 0
                while player == nil && !loadingState.hasFailed && attempts < 50 {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                    attempts += 1
                }
                
                // Restore position and autoplay for visible video
                if let player = player {
                    // CRITICAL: Always ensure muteState is correct before playing
                    if self.mode == .mediaCell {
                        player.isMuted = MuteState.shared.isMuted
                        NSLog("🔇 [PLAYER MUTE] recoverFromBackground - Applied global mute state for MediaCell: \(MuteState.shared.isMuted) for \(self.mid)")
                    }
                    print("DEBUG: [VIDEO RECOVERY] Player ready, restoring position and autoplaying")
                    player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                        if finished {
                            // Always autoplay visible videos after aggressive recovery
                            player.play()
                            print("DEBUG: [VIDEO RECOVERY] Autoplaying visible video after recovery")
                        }
                    }
                    
                    // Reattach player after successful recovery
                    self.isPlayerDetached = false
                    print("✅ [VIDEO RECOVERY] Player reattached after validation")
                } else {
                    print("⚠️ [VIDEO RECOVERY] Player failed to initialize after aggressive recovery")
                }
            }
            
            print("DEBUG: [VIDEO RECOVERY] Visible video recreated from scratch")
            return
        }
        
        // APP BACKGROUND or non-MediaCell: More aggressive recovery for short backgrounds
        // After clearVideoPlayersForBackgroundRecovery(), currentItem is set to nil
        // We need to be more aggressive to ensure all videos recover properly
        
        // CRITICAL: Check if player or currentItem is missing first (common after background)
        // After clearVideoPlayersForBackgroundRecovery(), currentItem is set to nil
        let playerIsMissing = player == nil || player?.currentItem == nil
        
        // For MediaCell with app background, be more aggressive - always recreate if player exists but currentItem is nil
        // This handles the case where clearVideoPlayersForBackgroundRecovery() was called
        let shouldForceRecreate = mode == .mediaCell && player != nil && player?.currentItem == nil
        
        if playerIsMissing || shouldForceRecreate {
            print("⚠️ [VIDEO RECOVERY] Player or currentItem missing after background (playerIsMissing: \(playerIsMissing), shouldForceRecreate: \(shouldForceRecreate)), recreating for \(mid)")
            
            // Clean up observers
            if let observer = timeObserver, let observerPlayer = timeObserverPlayer {
                observerPlayer.removeTimeObserver(observer)
            }
            timeObserver = nil
            timeObserverPlayer = nil
            
            // Remove from SharedAssetCache to force fresh creation
            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
            
            player?.pause()
            player = nil
            loadingState = .idle
            playbackState = .notStarted
            
            if shouldLoadVideo || mode == .tweetDetail || mode == .mediaBrowser {
                setupPlayer()
                
                // Wait for player to be ready before reattaching
                Task { @MainActor in
                    var attempts = 0
                    while player == nil && !loadingState.hasFailed && attempts < 50 {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                        attempts += 1
                    }
                    
                    if player != nil {
                        // Reattach player after successful recreation
                        self.isPlayerDetached = false
                        // Force view refresh
                        self.representableId += 1
                        print("✅ [VIDEO RECOVERY] Player recreated and reattached for \(self.mid)")
                    } else {
                        print("⚠️ [VIDEO RECOVERY] Failed to recreate player for \(self.mid)")
                    }
                }
            }
            return
        }
        
        // Gentle recovery: only recreate if actually broken
        if isPlayerBroken() {
            print("⚠️ [VIDEO RECOVERY] Player is broken, recreating for \(mid)")
            
            // Clean up observers
            if let observer = timeObserver, let observerPlayer = timeObserverPlayer {
                observerPlayer.removeTimeObserver(observer)
            }
            timeObserver = nil
            timeObserverPlayer = nil
            
            // Remove from SharedAssetCache
            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
            
            player = nil
            loadingState = .idle
            playbackState = .notStarted
            
            if shouldLoadVideo || mode == .tweetDetail || mode == .mediaBrowser {
                setupPlayer()
                
                // Wait for player to be ready before reattaching
                Task { @MainActor in
                    var attempts = 0
                    while player == nil && !loadingState.hasFailed && attempts < 50 {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                        attempts += 1
                    }
                    
                    if player != nil {
                        // Reattach player after successful recreation
                        self.isPlayerDetached = false
                        // Force view refresh
                        self.representableId += 1
                        print("✅ [VIDEO RECOVERY] Player recreated and reattached for \(self.mid)")
                    } else {
                        print("⚠️ [VIDEO RECOVERY] Failed to recreate player for \(self.mid)")
                    }
                }
            }
            return
        }
        
        // Player is healthy - validate it before reattaching
        print("✅ [VIDEO RECOVERY] Player healthy - validating before reattach")
        
        // Ensure player is in valid state
        guard let player = player, let playerItem = player.currentItem else {
            print("⚠️ [VIDEO RECOVERY] Player or item missing in healthy path, recreating")
            // This shouldn't happen if checks above are correct, but be safe and recreate
            self.player = nil
            loadingState = .idle
            playbackState = .notStarted
            if shouldLoadVideo || mode == .tweetDetail || mode == .mediaBrowser {
                setupPlayer()
            }
            return
        }
        
        // Verify player item status is valid
        if playerItem.status == .failed || playerItem.status == .unknown {
            print("⚠️ [VIDEO RECOVERY] Player item status invalid (\(playerItem.status.rawValue)), recreating")
            self.player = nil
            loadingState = .idle
            playbackState = .notStarted
            setupPlayer()
            return
        }
        
        // Player is valid - safe to reattach
        print("✅ [VIDEO RECOVERY] Player validated successfully, reattaching")
        
        if mode == .mediaCell && mediaType == .video {
            player.isMuted = MuteState.shared.isMuted
        } else {
            player.isMuted = false
        }
        
        representableId += 1
        
        // Restore playback state
        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            let currentTime = player.currentTime()
            let timeDiff = abs(CMTimeGetSeconds(cachedState.time) - CMTimeGetSeconds(currentTime))
            
            if timeDiff > 0.5 {
                player.seek(to: cachedState.time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            
            let shouldResume = cachedState.wasPlaying && (shouldLoadVideo || mode == .tweetDetail || mode == .mediaBrowser)
            if shouldResume {
                // CRITICAL: Always ensure muteState is correct before playing
                if mode == .mediaCell {
                    player.isMuted = MuteState.shared.isMuted
                    NSLog("🔇 [PLAYER MUTE] recoverFromBackground - Applied global mute state for MediaCell: \(MuteState.shared.isMuted) for \(mid)")
                }
                player.play()
                playbackState = .playing
            }
        }
        
        // Reattach player after all validation and restoration
        isPlayerDetached = false
        print("✅ [VIDEO RECOVERY] Player reattached - recovery complete for \(mid)")
    }
    
    private func handleVideoInfrastructureRestarted() {
        print("DEBUG: [VIDEO INFRA RESTART] Video infrastructure restarted for \(mid), mode: \(mode), shouldLoadVideo: \(shouldLoadVideo)")
        
        // BULLETPROOF: For MediaCell, ALWAYS recreate if player exists OR currentItem is nil
        // This handles the case where AppDelegate cleared players (currentItem set to nil) before this notification
        if mode == .mediaCell {
            // Check if player exists OR if currentItem is nil (cleared by clearVideoPlayersForBackgroundRecovery)
            let hadPlayer = player != nil
            let currentItemIsNil = player?.currentItem == nil
            let wasInCache = VideoStateCache.shared.getCachedState(for: mid) != nil
            
            // Force recreate if: player exists, OR currentItem is nil (was cleared), OR was in cache
            if hadPlayer || currentItemIsNil || wasInCache {
                print("DEBUG: [VIDEO INFRA RESTART] MediaCell - FORCE recreating player (hadPlayer: \(hadPlayer), currentItemIsNil: \(currentItemIsNil), wasInCache: \(wasInCache))")
                
                if let observer = timeObserver, let observerPlayer = timeObserverPlayer {
                    observerPlayer.removeTimeObserver(observer)
                }
                timeObserver = nil
                timeObserverPlayer = nil
                
                // Remove from SharedAssetCache to force fresh creation
                SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
                
                player?.pause()
                player = nil
                loadingState = .idle
                playbackState = .notStarted
                
                // Always recreate - even if currently offscreen, so it's ready when scrolled back
                // CRITICAL: Always call setupPlayer() for MediaCell (old working behavior)
                // Note: setupPlayer() internally checks shouldLoadVideo and returns early if false,
                // so for visible videos (shouldLoadVideo=true) it will load, for offscreen it will just reset state
                setupPlayer()
                
                // CRITICAL: Force view layer to recreate for on-screen videos
                representableId += 1
                print("DEBUG: [VIDEO INFRA RESTART] Incremented representableId to \(representableId) to refresh view layer")
                return
            }
        }
        
        // For other modes, check if broken
        let playerIsMissing = player == nil || player?.currentItem == nil
        let playerIsBroken = !playerIsMissing && isPlayerBroken()
        
        if playerIsMissing || playerIsBroken {
            print("DEBUG: [VIDEO INFRA RESTART] Player broken/missing - recreating")
            
            if player != nil && player?.currentItem == nil {
                player = nil
            }
            
            if playerIsBroken {
                player = nil
            }
            
            if playbackState.hasFinished {
                playbackState = .notStarted
            }
            
            if case .loading = loadingState {
            } else {
                loadingState = .idle
            }
            
            if shouldLoadVideo || mode == .tweetDetail {
                setupPlayer()
            }
        } else {
            // Non-MediaCell healthy player - refresh view
            print("DEBUG: [VIDEO INFRA RESTART] Non-MediaCell healthy - refresh view")
            representableId += 1
            
            if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
                let shouldResume = cachedState.wasPlaying && (shouldLoadVideo || mode == .tweetDetail || mode == .mediaBrowser)
                if shouldResume && player?.rate == 0 {
                    // CRITICAL: Always ensure muteState is correct before playing
                    if mode == .mediaCell, let player = player {
                        player.isMuted = MuteState.shared.isMuted
                        NSLog("🔇 [PLAYER MUTE] handleVideoInfrastructureRestarted - Applied global mute state for MediaCell: \(MuteState.shared.isMuted) for \(mid)")
                    }
                    player?.play()
                    playbackState = .playing
                }
            }
        }
    }
    
    private func handleVideoLayerRefresh() {
        // This is called when DetailVideoManager detects screen lock recovery
        // Force view refresh for detail/fullscreen modes to reconnect AVPlayerViewController layer
        if mode == .tweetDetail || mode == .mediaBrowser {
            print("DEBUG: [VIDEO LAYER REFRESH] Forcing view refresh for \(mode) mode, mid: \(mid)")
            representableId += 1
            
            // Ensure player is in correct state
            if let player = player {
                player.isMuted = false
                print("DEBUG: [VIDEO LAYER REFRESH] Ensured unmuted state for detail/fullscreen mode")
            }
        }
    }
    
    private func handleAppUserReady() {
        // This is called when app initialization completes
        // Force reload for any videos that were blocked waiting for initialization
        print("DEBUG: [APP USER READY] App initialized for \(mid), loadingState: \(loadingState), player: \(player != nil)")
        
        // Only force reload if:
        // 1. We have a player (meaning setup was attempted)
        // 2. We're in a loading state (stuck waiting)
        // 3. We haven't loaded any data yet
        guard let player = player, case .loading = loadingState else {
            return
        }
        
        // Check if player has any data loaded
        if let playerItem = player.currentItem,
           playerItem.status == .unknown,
           playerItem.loadedTimeRanges.isEmpty {
            print("🔄 [APP USER READY] Player stuck with no data, forcing reload for \(mid)")
            
            // Force reload by replacing the current item with a new one
            Task { @MainActor in
                player.pause()
                loadingState = .idle
                
                // Recreate the player
                do {
                    let newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(
                        for: url,
                        tweetId: mid,
                        mediaType: mediaType
                    )
                    self.player = newPlayer
                    configurePlayer(newPlayer)
                    
                    // CRITICAL: Force AVPlayer to start loading data by calling play() then pausing
                    // Without this, progressive videos won't make network requests after recovery
                    // Note: preroll() doesn't work because player status is still .unknown
                    print("DEBUG: [APP USER READY] Forcing player to start loading for \(mid)")
                    newPlayer.play()
                    // Immediately pause - we only want to trigger loading, not actual playback
                    // The KVO observers and normal visibility logic will handle playback
                    newPlayer.pause()
                    print("DEBUG: [APP USER READY] Triggered loading with play/pause for \(mid)")
                } catch {
                    print("❌ [APP USER READY] Failed to reload player: \(error)")
                }
            }
        }
    }
    
    private func handleTap() {
        if let onVideoTap = onVideoTap {
            onVideoTap()
        }
    }
    
    private func handleLongPress() {
        isLongPressing = true
        
        // Provide haptic feedback
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()
        
        // Show visual feedback
        print("🔄 [VIDEO RELOAD] Long press detected - reloading video for \(mid)")
        
        // Handle manual video reset on long press
        handleError(strategy: .manualReset)
        
        // Reset the long press state after a short delay
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
            isLongPressing = false
        }
    }
    
    private func handlePressingChanged(pressing: Bool) {
        if !pressing {
            isLongPressing = false
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
                    if mode == .mediaBrowser || mode == .tweetDetail {
                        // Use AVPlayerViewController for fullscreen and detail modes to get native controls and reliable autoplay
                        // Don't add tap gesture in these modes - it interferes with native controls (especially progress bar)
                        AVPlayerViewControllerRepresentable(
                            player: player,
                            isBuffering: $isBuffering,
                            mediaType: mediaType,
                            progressiveForwardBufferDuration: progressiveForwardBufferDuration
                        )
                            .id("\(mid)_\(representableId)") // Force recreation with representableId changes
                            .onAppear {
                            }
                    } else {
                        // MediaCell: Use custom AVPlayerLayer wrapper (no controls, respects mute state)
                        AVPlayerLayerView(player: player)
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
                
                // Show buffering spinner when buffering (fullscreen only)
                if isBuffering && mode == .mediaBrowser {
                    ZStack {
                        Color.black.opacity(0.15)
                        ProgressView()
                            .scaleEffect(1.5)
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .opacity(0.6)
                    }
                    .transition(.opacity)
                }
                
                // Loading indicator - show until video starts playing in fullscreen
                // Show spinner when: loading OR (fullscreen AND ready to play but not started yet)
                let showInitialLoadingSpinner = loadingState.isLoading || 
                    (mode == .mediaBrowser && 
                     player.rate == 0 && 
                     (player.currentItem?.currentTime().seconds ?? 0) < 0.1)
                
                if showInitialLoadingSpinner {
                    ZStack {
                        Color.black.opacity(0.3)
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                            .opacity(0.5)
                    }
                    .cornerRadius(8)
                }
            }
        } else {
            // No player yet - show visible loading placeholder
            ZStack {
                Color.black.opacity(0.9)
                
                // Always show spinner when no player (loading or retrying)
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.2)
                    .opacity(0.5)
                
                // Long press indicator with reload icon
                if isLongPressing {
                    ZStack {
                        Color.black.opacity(0.5)
                        VStack(spacing: 12) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 50))
                                .foregroundColor(.white)
                            Text("Reloading Video...")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                    }
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: isLongPressing)
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
            // Reset loading state if stuck
            if loadingState.isLoading {
                NSLog("DEBUG: [VIDEO VALIDATE] loadingState stuck at .loading, resetting to .idle")
                loadingState = .idle
            }
            setupPlayer()
        }
    }
    
    private func setupPlayer() {
        // CRITICAL: Prevent duplicate setup calls - check if already loading
        if loadingState.isLoading {
            print("DEBUG: [VIDEO SETUP] Already loading player for \(mid), skipping duplicate call")
            return
        }
        
        // Mark as loading to prevent duplicate calls (unless already loaded from tweetDetail path)
        if !loadingState.isLoaded {
            loadingState = .loading
        }
        
        // SPECIAL CASE: For TweetDetail mode, use singleton DetailVideoManager
        if mode == .tweetDetail {
            
            // Check if singleton already has this exact video playing
            if let existingPlayer = DetailVideoManager.shared.currentPlayer,
               DetailVideoManager.shared.currentVideoMid == mid {
                self.player = existingPlayer
                self.loadingState = .loaded
                
                // Resume if paused
                if existingPlayer.rate == 0 {
                    // For tweetDetail mode, always unmute
                    existingPlayer.isMuted = false
                    existingPlayer.play()
                }
                return
            }
            
            // Different video or no singleton - create new player and store in singleton
            Task.detached(priority: .userInitiated) {
                NSLog("DEBUG: [VIDEO SETUP] Task started for \(mid)")
                do {
                    NSLog("DEBUG: [VIDEO SETUP] Calling getOrCreatePlayer...")
                    let newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(for: uniquePlayerURL, tweetId: "tweetDetail_\(mid)", mediaType: mediaType)
                    NSLog("DEBUG: [VIDEO SETUP] Player created, now storing in singleton...")
                    newPlayer.isMuted = false
                    
                    await MainActor.run {
                        NSLog("DEBUG: [VIDEO SETUP] On MainActor, storing player...")
                        // Stop old singleton player if exists
                        DetailVideoManager.shared.currentPlayer?.pause()
                        
                        // Store new player in singleton
                        DetailVideoManager.shared.currentPlayer = newPlayer
                        DetailVideoManager.shared.currentVideoMid = mid
                        
                        self.player = newPlayer
                        self.loadingState = .loaded
                        self.configurePlayer(newPlayer)
                        NSLog("DEBUG: [VIDEO SETUP] ✅ Stored new player in singleton for \(mid)")
                    }
                } catch {
                    NSLog("DEBUG: [VIDEO SETUP] ❌ Failed to create singleton player: \(error.localizedDescription)")
                    await MainActor.run {
                        self.handleError(strategy: .loadFailure)
                    }
                }
            }
            return
        }
        
        // NORMAL FLOW: Check VideoStateCache for shared player (MediaCell can read/write, MediaBrowser can only read)
        // MediaBrowser can read from VideoStateCache for performance (reuse MediaCell's player), but won't write to it
        // TweetDetail has its own path above and doesn't use VideoStateCache at all
        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            NSLog("DEBUG: [VIDEO CACHE] ✅ Found shared player for \(mid) in \(mode) mode")
            
            // Apply mute state based on current mode
            if mode == .mediaCell {
                cachedState.player.isMuted = MuteState.shared.isMuted
            } else if mode == .mediaBrowser {
                cachedState.player.isMuted = false
            }
            
            restoreFromCache(cachedState)
            // loadingState will be set to .loaded in restoreFromCache
            return
        }
        
        // SECOND: Check if we have cached content for this tweet
        let hasCachedContent = SharedAssetCache.shared.hasCachedContent(for: mid)
        
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
                        NSLog("🔇 [PLAYER MUTE] Applied global mute state for MediaCell - isMuted: \(muteState) for \(mid)")
                    } else {
                        newPlayer.isMuted = false
                        NSLog("🔊 [PLAYER MUTE] Unmuted for fullscreen/detail mode - isMuted: false for \(mid)")
                    }
                    
                    await MainActor.run {
                        // Double-check and reapply mute state for safety
                        if self.mode == .mediaCell {
                            newPlayer.isMuted = MuteState.shared.isMuted
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
                loadingState = .idle  // Reset loading state since we're not loading
                return
            }
        }
        
        // No shared player found, create a new one
        // loadingState is already set to .loading at the start of this function
        Task.detached(priority: .userInitiated) {
            do {
                // Use shared cached player for all modes - simpler and more efficient
                // Use uniquePlayerURL to ensure each tweet gets its own player instance
                let newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(for: uniquePlayerURL, tweetId: mid, mediaType: mediaType)
                
                
                // Apply mute state IMMEDIATELY after player creation, before returning to MainActor
                // This prevents any brief moment where the player might start with wrong audio state
                if await MainActor.run(body: { self.mode }) == .mediaCell {
                    let muteState = await MainActor.run { MuteState.shared.isMuted }
                    newPlayer.isMuted = muteState
                } else {
                    newPlayer.isMuted = false
                    NSLog("DEBUG: [VIDEO SETUP] Unmuted immediately after player creation for fullscreen/detail")
                }
                
                await MainActor.run {
                    // Double-check and reapply mute state for safety
                    if self.mode == .mediaCell {
                        newPlayer.isMuted = MuteState.shared.isMuted
                        NSLog("🔇 [PLAYER MUTE] Re-applied mute state on MainActor for MediaCell - isMuted: \(MuteState.shared.isMuted) for \(mid)")
                    } else {
                        newPlayer.isMuted = false
                        NSLog("🔊 [PLAYER MUTE] Re-applied unmute on MainActor for fullscreen/detail - isMuted: false for \(mid)")
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
        
        // Early return if loading is disabled
        guard shouldLoadVideo else {
            NSLog("DEBUG: [VIDEO CACHE] ⚠️ Loading disabled for \(mid), skipping cache restoration")
            return
        }
        
        // Validate cached player before using it
        guard let playerItem = cachedState.player.currentItem else {
            NSLog("DEBUG: [VIDEO CACHE] ❌ Cached player has no currentItem, clearing cache and creating new player for \(mid)")
            VideoStateCache.shared.clearCache(for: mid)
            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
            loadingState = .idle  // Reset loading state before recreating
            setupPlayer()
            return
        }
        
        
        // Check if player item is in a failed state
        if playerItem.status == .failed {
            NSLog("DEBUG: [VIDEO CACHE] ❌ Cached player item is in failed state, clearing cache and creating new player for \(mid)")
            VideoStateCache.shared.clearCache(for: mid)
            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
            loadingState = .idle  // Reset loading state before recreating
            setupPlayer()
            return
        }
        
        // Check if player has buffered any data
        let hasBufferedData = !playerItem.loadedTimeRanges.isEmpty
        
        // For fullscreen/detail modes, ensure player has buffered data
        if mode == .mediaBrowser || mode == .tweetDetail {
            if playerItem.status != .readyToPlay {
                NSLog("DEBUG: [VIDEO CACHE] ⚠️ Cached player item not ready yet (status: \(playerItem.status.rawValue)) for fullscreen/detail mode - TRUSTING IT and continuing")
                NSLog("DEBUG: [VIDEO CACHE] Player was working in MediaCell, will use KVO observer in AVPlayerViewController to play when ready")
            } else if !hasBufferedData {
                NSLog("DEBUG: [VIDEO CACHE] ⚠️ Player ready but no buffered data yet for fullscreen - this may cause playback delays")
                NSLog("DEBUG: [VIDEO CACHE] Will still use player but playback may take time to start")
            }
        } else {
            // For MediaCell mode, check player readiness but trust players with buffered data
            if playerItem.status != .readyToPlay {
                // If player has buffered data, it's transitioning and will be ready soon - use it!
                if hasBufferedData {
                    NSLog("DEBUG: [VIDEO CACHE] ⚠️ Player status not ready yet (status: \(playerItem.status.rawValue)) but HAS buffered data - will use it for MediaCell")
                } else if playerItem.status == .failed {
                    // Only clear cache if player has FAILED, not if it's just loading
                    NSLog("DEBUG: [VIDEO CACHE] ❌ Cached player item FAILED for MediaCell, clearing cache and creating new player for \(mid)")
                    VideoStateCache.shared.clearCache(for: mid)
                    SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
                    loadingState = .idle  // Reset loading state before recreating
                    setupPlayer()
                    return
                } else {
                    // Status is .unknown (0) - for HLS videos with cached playlists, this is normal
                    // The player needs time to fetch segments. Let KVO handle it.
                    NSLog("DEBUG: [VIDEO CACHE] ⏳ Cached player item status: \(playerItem.status.rawValue), no buffer yet - giving it time to load segments for \(mid)")
                }
            } else {
            }
        }
        
        // CRITICAL: Set mute state BEFORE assigning to self.player
        // This prevents unmuted audio when SwiftUI re-renders
        if mode == .mediaCell {
            // Pause if playing to prevent audio bleed
            if cachedState.player.rate > 0 {
                cachedState.player.pause()
                NSLog("DEBUG: [VIDEO CACHE] Paused playing cached player before restoring for MediaCell")
            }
            cachedState.player.isMuted = MuteState.shared.isMuted
        } else {
            // For full screen modes (mediaBrowser), always unmute regardless of cached state
            cachedState.player.isMuted = false
        }
        
        // Check if player is actually changing
        let playerChanged = self.player !== cachedState.player
        
        // Restore the cached player (AFTER setting mute state)
        self.player = cachedState.player
        
        // Only increment representableId if the player actually changed (different player object)
        // This avoids unnecessary layer recreation and black flashes during normal scrolling
        // For the same player, SwiftUI will reuse the existing UIViewRepresentable without recreation
        if playerChanged && mode == .mediaCell {
            self.representableId += 1
            print("DEBUG: [VIDEO CACHE] Player changed, incremented representableId to \(representableId)")
        }
        
        // Ensure the player is also cached in SharedAssetCache for consistency
        SharedAssetCache.shared.cachePlayer(cachedState.player, for: playerCacheKey)
        
        // For fullscreen/detail modes, check if player needs repositioning
        if mode == .mediaBrowser || mode == .tweetDetail {
            
            let currentTime = cachedState.player.currentTime()
            let duration = cachedState.player.currentItem?.duration ?? .zero
            let isAtEnd = duration.isValid && currentTime.seconds >= duration.seconds - 0.5
            
            
            // CRITICAL: Disable automatic waiting to minimize stalling for cached content
            // This prevents AVPlayer from unnecessarily evaluating buffering rate when data is local
            if hasBufferedData {
                configureAutomaticWaiting(for: cachedState.player)
            }
            
            // If player is at end or has invalid position, reset to beginning
            if isAtEnd || currentTime.seconds < 0 {
                NSLog("DEBUG: [VIDEO CACHE] Player at end or invalid position - resetting to beginning")
                cachedState.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            } else if cachedState.time.seconds > 0 {
                // If we have a cached position, seek to it
                NSLog("DEBUG: [VIDEO CACHE] Seeking to cached position: \(cachedState.time.seconds)s for fullscreen")
                cachedState.player.seek(to: cachedState.time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            
            // Spinner should remain visible until the player actually has data ready
            let isReadyForDisplay = playerItem.status == .readyToPlay || hasBufferedData
            self.loadingState = isReadyForDisplay ? .loaded : .loading
            self.playbackState = .notStarted
        } else {
            // For MediaCell, seek to cached position
            
            // Use seek with tolerance for better reliability
            let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
            cachedState.player.seek(to: cachedState.time, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
                if finished {
                    // Resume playback if VideoManager approves
                    if cachedState.wasPlaying && self.isVisible && self.currentAutoPlay && self.videoManager?.shouldPlayVideo(for: self.mid) == true {
                        // CRITICAL: Always ensure muteState is correct before playing in MediaCell
                        if self.mode == .mediaCell {
                            cachedState.player.isMuted = MuteState.shared.isMuted
                            NSLog("🔇 [PLAYER MUTE] restoreFromCache - Applied global mute state for MediaCell: \(MuteState.shared.isMuted) for \(self.mid)")
                        }
                        cachedState.player.play()
                        NSLog("DEBUG: [VIDEO CACHE] ✅ Resumed playback from cache for \(self.mid) - VideoManager approved")
                    }
                } else {
                    NSLog("DEBUG: [VIDEO CACHE] ⚠️ Seek did not finish for \(self.mid)")
                }
            }
            
            // Update state
            let isReadyForDisplay = playerItem.status == .readyToPlay || hasBufferedData
            self.loadingState = isReadyForDisplay ? .loaded : .loading
            self.playbackState = .notStarted
        }
        
    }
    
    private func configureAutomaticWaiting(for player: AVPlayer) {
        if mediaType == .video {
            player.automaticallyWaitsToMinimizeStalling = true
            if let item = player.currentItem {
                applyProgressiveBufferTarget(to: item)
            }
        } else {
            player.automaticallyWaitsToMinimizeStalling = false
        }
    }

    private func applyProgressiveBufferTarget(to item: AVPlayerItem?) {
        guard mediaType == .video, let item = item else { return }
        let target = max(progressiveForwardBufferDuration, firstFrameMinimumBuffer)
        if item.preferredForwardBufferDuration < target - 0.05 {
            item.preferredForwardBufferDuration = target
            let formatted = String(format: "%.1f", target)
            NSLog("DEBUG: [BUFFER TARGET] Applied progressive buffer target \(formatted)s for \(mid)")
        }
    }

    private func bumpProgressiveBufferTarget(for item: AVPlayerItem?) {
        guard mediaType == .video else { return }
        guard progressiveBufferTargetIndex + 1 < progressiveBufferTargets.count else { return }
        progressiveBufferTargetIndex += 1
        applyProgressiveBufferTarget(to: item)
        let newTarget = progressiveForwardBufferDuration
        let formatted = String(format: "%.1f", newTarget)
        NSLog("⚙️ [BUFFER TARGET] Increased progressive buffer target to \(formatted)s for \(mid)")
    }

    private func resetProgressiveBufferTarget(for item: AVPlayerItem?) {
        guard mediaType == .video else { return }
        guard progressiveBufferTargetIndex != 0 else { return }
        progressiveBufferTargetIndex = 0
        applyProgressiveBufferTarget(to: item)
        let formatted = String(format: "%.1f", progressiveForwardBufferDuration)
        NSLog("⚙️ [BUFFER TARGET] Reset progressive buffer target to \(formatted)s for \(mid)")
    }
    
    private func configurePlayer(_ player: AVPlayer) {
        
        configureAutomaticWaiting(for: player)
        
        // CRITICAL: For MediaCell, pause playing shared players FIRST to prevent audio bleed
        if mode == .mediaCell && player.rate > 0 {
            player.pause()
        }
        
        // Configure player mute state based on mode
        if mode == .mediaCell {
            // MediaCell: Apply global mute state
            player.isMuted = MuteState.shared.isMuted
            NSLog("🔇 [PLAYER MUTE] configurePlayer() - MediaCell mode, isMuted: \(MuteState.shared.isMuted) for \(mid)")
        } else {
            // Fullscreen/Detail: Always unmute
            player.isMuted = false
            NSLog("🔊 [PLAYER MUTE] configurePlayer() - Fullscreen/Detail mode, isMuted: false for \(mid)")
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
        }
        
        // CRITICAL: Always set up observers for the new player
        // Clear existing observers first, then set up for this player
        removePlayerObservers()
        setupPlayerObservers(player)
        
        // CRITICAL: Always update state, even if same player instance
        // This ensures the view's player binding is set when reusing cached players
        self.player = player
        // DON'T set loadingState = .loaded here! Let the KVO observers handle it based on actual readiness
        // CRITICAL: Don't overwrite .loaded state (tweetDetail sets it before calling this)
        if !self.loadingState.isLoaded {
            self.loadingState = .loading  // Show spinner while video loads
        }
        self.playbackState = .notStarted
        self.representableId += 1 // Force VideoPlayerRepresentable to recreate
        self.viewConfigTimestamp = Date().timeIntervalSince1970 // Force unique view ID
        
        // Cache player state in VideoStateCache for sharing (MediaCell only, NOT TweetDetail or MediaBrowser)
        // TweetDetail uses DetailVideoManager singleton and should not share players with MediaCell
        // MediaBrowser uses FullScreenVideoManager singleton and should not share players with MediaCell
        if mode == .mediaCell {
            if let playerItem = player.currentItem, playerItem.status == .readyToPlay, !playerItem.loadedTimeRanges.isEmpty {
                let currentTime = player.currentTime()
                let wasPlaying = player.rate > 0
                VideoStateCache.shared.cacheVideoState(
                    for: mid,
                    player: player,
                    time: currentTime,
                    wasPlaying: wasPlaying,
                    originalMuteState: player.isMuted
                )
                NSLog("DEBUG: [VIDEO CONFIGURE] ✅ Cached READY player with buffered data in VideoStateCache for \(mid)")
            }
        } else {
            NSLog("DEBUG: [VIDEO CONFIGURE] Skipping VideoStateCache for TweetDetail mode (uses DetailVideoManager singleton)")
        }
        
        
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
        
        timeObserver = player.addPeriodicTimeObserver(forInterval: time, queue: .main) { [mid] time in
            // Cache/update player state periodically when ready
            if let playerItem = player.currentItem,
               playerItem.status == .readyToPlay,
               !playerItem.loadedTimeRanges.isEmpty {
                let currentTime = player.currentTime()
                let wasPlaying = player.rate > 0
                VideoStateCache.shared.cacheVideoState(
                    for: mid,
                    player: player,
                    time: currentTime,
                    wasPlaying: wasPlaying,
                    originalMuteState: player.isMuted
                )
            }
        }
        
        // Store reference to the player that added this observer
        timeObserverPlayer = player
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
        
        // CRITICAL FIX: Playback stall observer - detects when video stalls waiting for data
        // This is essential for HLS videos where data arrives asynchronously
        videoStallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: playerItem,
            queue: .main
        ) { [weak playerItem, weak player] _ in
            NSLog("⚠️ [PLAYBACK STALL] Video stalled for \(self.mid), waiting for data...")
            self.bumpProgressiveBufferTarget(for: playerItem)
            
            // UX: Show spinner when stalled
            DispatchQueue.main.async {
                self.loadingState = .loading
                NSLog("🔄 [PLAYBACK STALL] Showing spinner")
            }
            
            // Monitor when data becomes available again using KVO on loadedTimeRanges
            guard let item = playerItem, let resumePlayer = player else { return }
            
            // Set up a temporary observer to detect when new data arrives
            var resumeObserver: NSKeyValueObservation?
            resumeObserver = item.observe(\.loadedTimeRanges, options: [.new]) { observedItem, _ in
                
                let hasData = !observedItem.loadedTimeRanges.isEmpty
                let isReadyToPlay = observedItem.status == .readyToPlay
                guard hasData && isReadyToPlay else { return }
                
                let bufferedAhead = self.bufferedTimeAhead(for: observedItem, player: resumePlayer)
                let requiredBuffer = self.stallRecoveryMinimumBuffer
                
                if bufferedAhead < requiredBuffer {
                    let aheadText = String(format: "%.2f", bufferedAhead)
                    let requiredText = String(format: "%.2f", requiredBuffer)
                    NSLog("⏳ [PLAYBACK RESUME] Waiting for buffer for \(mid) - ahead: \(aheadText)s, need: \(requiredText)s")
                    return
                }
                
                let bufferedText = String(format: "%.2f", bufferedAhead)
                NSLog("✅ [PLAYBACK RESUME] Data available, resuming playback for \(mid) (buffered: \(bufferedText)s)")
                DispatchQueue.main.async {
                    if resumePlayer.rate == 0 {
                        // CRITICAL: Always ensure muteState is correct before playing in MediaCell
                        if self.mode == .mediaCell {
                            resumePlayer.isMuted = MuteState.shared.isMuted
                            NSLog("🔇 [PLAYER MUTE] Playback resume - Applied global mute state for MediaCell: \(MuteState.shared.isMuted) for \(self.mid)")
                        }
                        resumePlayer.play()
                        NSLog("🔄 [PLAYBACK RESUME] Manually triggered play() for \(mid)")
                    } else {
                        NSLog("▶️ [PLAYBACK RESUME] Player already playing at rate \(resumePlayer.rate)")
                    }
                    
                    if self.loadingState.isLoading {
                        self.loadingState = .loaded
                        NSLog("✅ [PLAYBACK RESUME] Hiding spinner")
                    }
                }
                
                // Clean up the temporary observer
                resumeObserver?.invalidate()
                resumeObserver = nil
            }
        }
        
        // Simple approach: Tell AVPlayer what to do and let IT handle the rest
        // For MediaCell mode, observe when player is ready and react accordingly
        if mode == .mediaCell {
            let shouldAutoPlay = self.currentAutoPlay && self.isVisible && self.shouldLoadVideo
            
            // Observe player status to know when it's ready
            playerItemStatusObserver = playerItem.observe(\.status, options: [.new, .initial]) { item, change in
                
                NSLog("🔍 [KVO STATUS] Fired for \(mid) - status: \(item.status.rawValue), buffered: \(!item.loadedTimeRanges.isEmpty)")
                
                // Check for failed status first
                if item.status == .failed {
                    NSLog("❌ [KVO STATUS] Player FAILED for \(mid) - error: \(item.error?.localizedDescription ?? "unknown")")
                    DispatchQueue.main.async {
                        self.handleError(strategy: .loadFailure)
                    }
                    return
                }
                
                guard item.status == .readyToPlay else { 
                    NSLog("⏳ [KVO STATUS] Not ready yet for \(mid) - status: \(item.status.rawValue)")
                    return 
                }
                
                // CRITICAL: For HLS videos, .readyToPlay fires BEFORE data is buffered
                // Check if we have buffered data before acting
                let hasBufferedData = !item.loadedTimeRanges.isEmpty
                NSLog("✅ [KVO STATUS] Player ready for \(mid) - buffered: \(hasBufferedData)")
                
                DispatchQueue.main.async {
                    // CRITICAL: Hide spinner if we have buffered data (buffer observer might have already fired)
                    if hasBufferedData && loadingState.isLoading {
                        NSLog("📦 [STATUS READY] Data already buffered, hiding spinner for \(mid)")
                        loadingState = .loaded
                        retryAttempts = 0  // Reset retry counter on successful load
                    }
                    
                    if shouldAutoPlay {
                        // CRITICAL: Always ensure muteState is correct before playing in MediaCell
                        if self.mode == .mediaCell {
                            player.isMuted = MuteState.shared.isMuted
                            NSLog("🔇 [PLAYER MUTE] KVO status ready - Applied global mute state for MediaCell: \(MuteState.shared.isMuted) for \(self.mid)")
                        }
                        // Start playing automatically
                        player.play()
                        NSLog("▶️ [VIDEO READY] Auto-playing \(mid) (buffered: \(hasBufferedData))")
                    } else {
                        // Preroll to render first frame without playing
                        player.preroll(atRate: 0.0) { finished in
                            guard finished else { 
                                NSLog("❌ [PREROLL] Failed for \(mid), keeping observers active")
                                return 
                            }
                            NSLog("🎬 [VIDEO READY] Prerolled first frame for \(mid)")
                        }
                    }
                }
            }
            
            // Observe buffered data to hide spinner when data arrives
            playerItemBufferObserver = playerItem.observe(\.loadedTimeRanges, options: [.new]) { item, change in
                
                let hasBufferedData = !item.loadedTimeRanges.isEmpty
                let bufferedDurationAhead = self.bufferedTimeAhead(for: item, player: player)
                
                NSLog("🔍 [KVO BUFFER] Fired for \(mid) - hasData: \(hasBufferedData), buffered: \(String(format: "%.1f", bufferedDurationAhead))s, loadingState: \(loadingState)")
                
                DispatchQueue.main.async {
                    // UX FIX: Hide spinner as soon as we have enough buffered data to render the first frame
                    let hasEnoughData = hasBufferedData && bufferedDurationAhead >= firstFrameMinimumBuffer
                    
                    if hasEnoughData && loadingState.isLoading {
                        NSLog("📦 [BUFFER DATA] Sufficient data arrived for \(mid) (\(String(format: "%.2f", bufferedDurationAhead))s buffered), showing first frame")
                        
                        // Force player to render first frame by calling play() then checking if we should pause
                        if player.rate == 0 {
                            // CRITICAL: Always ensure muteState is correct before playing in MediaCell
                            if self.mode == .mediaCell {
                                player.isMuted = MuteState.shared.isMuted
                                NSLog("🔇 [PLAYER MUTE] First frame render - Applied global mute state for MediaCell: \(MuteState.shared.isMuted) for \(self.mid)")
                            }
                            player.play()
                            NSLog("▶️ [FIRST FRAME] Triggered play() to render first frame for \(mid)")
                            
                            // If not in autoplay mode, pause after first frame renders
                            if !shouldAutoPlay {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    if player.rate > 0 {
                                        player.pause()
                                        NSLog("⏸️ [FIRST FRAME] Paused after rendering first frame for \(mid)")
                                    }
                                }
                            }
                        }
                        
                        loadingState = .loaded
                        retryAttempts = 0  // Reset retry counter on successful load
                        // Keep observer active to detect stalls - it will be cleaned up when view disappears
                    } else if hasBufferedData && bufferedDurationAhead < firstFrameMinimumBuffer && loadingState.isLoading {
                        NSLog("⏳ [BUFFER DATA] Waiting for more data for \(mid) (\(String(format: "%.2f", bufferedDurationAhead))s buffered)...")
                    }
                }
            }
            
            // If already ready, trigger immediately
            NSLog("🔍 [INITIAL CHECK] Player status: \(playerItem.status.rawValue), buffered: \(!playerItem.loadedTimeRanges.isEmpty) for \(mid)")
            if playerItem.status == .readyToPlay {
                let hasBufferedData = !playerItem.loadedTimeRanges.isEmpty
                NSLog("✅ [INITIAL CHECK] Already ready for \(mid) - buffered: \(hasBufferedData)")
                
                // Hide spinner if we have buffered data
                if hasBufferedData {
                    loadingState = .loaded
                    retryAttempts = 0  // Reset retry counter on successful load
                    NSLog("🎬 [INITIAL CHECK] Hiding spinner immediately for \(mid)")
                } else {
                    NSLog("⏳ [INITIAL CHECK] Ready but waiting for buffer data for \(mid)")
                }
                
                if shouldAutoPlay {
                    // CRITICAL: Always ensure muteState is correct before playing in MediaCell
                    if self.mode == .mediaCell {
                        player.isMuted = MuteState.shared.isMuted
                        NSLog("🔇 [PLAYER MUTE] Initial check ready - Applied global mute state for MediaCell: \(MuteState.shared.isMuted) for \(self.mid)")
                    }
                    player.play()
                    NSLog("▶️ [VIDEO SETUP] Already ready - auto-playing \(mid) (buffered: \(hasBufferedData))")
                } else {
                    player.preroll(atRate: 0.0) { finished in
                        guard finished else { 
                            NSLog("❌ [PREROLL] Failed for \(mid), keeping observers active for retry")
                            return 
                        }
                        NSLog("🎬 [VIDEO SETUP] Already ready - prerolled \(mid)")
                    }
                }
            } else {
                NSLog("⏳ [INITIAL CHECK] Not ready yet for \(mid), waiting for KVO")
            }
        }
    }
    
    private func cleanupFailedPlayer() {
        NSLog("DEBUG: [VIDEO CLEANUP] Cleaning up failed player for \(self.mid)")
        
        // Remove from shared cache to free memory
        SharedAssetCache.shared.clearPlayerForMediaID(self.mid)
        
        // Clear local reference
        self.player = nil
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
        
        if let observer = videoStallObserver {
            NotificationCenter.default.removeObserver(observer)
            videoStallObserver = nil
        }
        
        // Cancel KVO observers
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = nil
        playerItemBufferObserver?.invalidate()
        playerItemBufferObserver = nil
        
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
        print("DEBUG: [VIDEO ERROR] Handling error with strategy: \(strategy) for \(mid), retryCount: \(retryAttempts)")
        
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
            
            // Clean up failed player
            cleanupFailedPlayer()
            
            // Automatic retry up to 3 times
            if retryAttempts < 3 {
                let retryDelay = Double(retryAttempts + 1) * 1.0 // 1s, 2s, 3s delays
                print("DEBUG: [VIDEO ERROR] Auto-retry #\(retryAttempts + 1) in \(retryDelay)s for \(mid)")
                
                // Keep showing spinner during retry by staying in loading state
                loadingState = .loading
                player = nil
                retryAttempts += 1
                
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    
                    // Only retry if still visible and should load
                    guard self.isVisible && self.shouldLoadVideo else {
                        print("DEBUG: [VIDEO ERROR] Skipping retry - video no longer visible")
                        return
                    }
                    
                    print("DEBUG: [VIDEO ERROR] Executing auto-retry for \(self.mid)")
                    self.loadingState = .idle
                    self.playbackState = .notStarted
                    self.setupPlayer()
                }
            } else {
                // After 3 retries, still keep showing spinner (never show error)
                loadingState = .loading
                player = nil
                print("DEBUG: [VIDEO ERROR] Video failed after 3 retries for \(mid), keeping spinner visible")
            }
            
            // For fullscreen, try to restore from cache as last resort
            if mode == .mediaBrowser && retryAttempts >= 3 {
                restoreCachedVideoState()
            }
            
        case .manualReset, .networkRecovery:
            playbackState = .notStarted
            loadingState = .idle  // Reset to idle - setupPlayer() will set to .loading
            retryAttempts = 0  // Reset retry counter on manual/network recovery
            
            if shouldLoadVideo {
                setupPlayer()
            }
            
        case .backgroundRecovery:
            player = nil
            playbackState = .notStarted
            loadingState = .idle  // Reset to idle - setupPlayer() will set to .loading
            retryAttempts = 0  // Reset retry counter on background recovery
            
            if shouldLoadVideo {
                setupPlayer()
            }
        }
    }
    
    private func handleVideoFinished() {
        print("DEBUG: [SimpleVideoPlayer] Video finished playing for \(mid)")
        resetProgressiveBufferTarget(for: player?.currentItem)
        
        // For MediaCell mode, pause immediately then rewind after delay (don't auto-restart)
        if mode == .mediaCell {
            print("DEBUG: [SimpleVideoPlayer] MediaCell mode - pausing and rewinding to beginning for \(mid)")
            player?.pause()
            // Ensure mute state is correct (respect global mute state)
            player?.isMuted = MuteState.shared.isMuted
            // Delay 0.5s before rewinding to make it noticeable
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                self.player?.seek(to: .zero) { finished in
                    if finished {
                        self.playbackState = .finished
                    }
                }
            }
            onVideoFinished?()
            return
        }
        
        // For fullscreen/detail modes, delay then rewind and auto-restart
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            self.player?.seek(to: .zero) { finished in
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
        }
        
        onVideoFinished?()
    }
    
    private func bufferedTimeAhead(for item: AVPlayerItem, player: AVPlayer) -> Double {
        bufferedTimeAhead(for: item, relativeTo: player.currentTime())
    }
    
    private func bufferedTimeAhead(for item: AVPlayerItem, relativeTo currentTime: CMTime) -> Double {
        let currentSeconds = seconds(from: currentTime)
        guard currentSeconds.isFinite else { return 0 }
        
        var bestBufferAhead: Double = 0
        
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let rangeStart = seconds(from: range.start)
            let rangeDuration = seconds(from: range.duration)
            let rangeEnd = rangeStart + rangeDuration
            
            if currentSeconds >= rangeStart && currentSeconds <= rangeEnd {
                return max(0, rangeEnd - currentSeconds)
            } else if rangeEnd > currentSeconds {
                bestBufferAhead = max(bestBufferAhead, rangeEnd - currentSeconds)
            }
        }
        
        return max(0, bestBufferAhead)
    }
    
    private func seconds(from time: CMTime) -> Double {
        let seconds = CMTimeGetSeconds(time)
        if seconds.isNaN || seconds.isInfinite {
            return 0
        }
        return seconds
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
        
        if autoPlay && isVisible && player != nil && !loadingState.isLoading && shouldCheckLoading {
            
            // Activate audio session for video playback
            AudioSessionManager.shared.activateForVideoPlayback()
            
        // For MediaCell mode, don't auto-restart if video has finished
        if mode == .mediaCell && playbackState.hasFinished {
            return
        }
            
            // CRITICAL: Always ensure muteState is correct before playing
            // For MediaCell, always respect global muteState
            if mode == .mediaCell, let player = player {
                player.isMuted = MuteState.shared.isMuted
                NSLog("🔇 [PLAYER MUTE] checkPlaybackConditions - Applied global mute state for MediaCell: \(MuteState.shared.isMuted) for \(mid)")
            }
            
            // Always ensure video is reset to beginning if it has finished playing
            if playbackState.hasFinished || isVideoAtEnd(player!) {
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
                    // Set playbackState but don't call play() yet
                    playbackState = .playing
                } else {
                    player?.play()
                    playbackState = .playing
                }
            }
        } else {
            // autoPlay is false - pause this video if it's playing (for sequential playback)
            if mode == .mediaCell, let player = player, player.rate > 0 {
                print("DEBUG: [VIDEO PLAYBACK] Pausing video \(mid) because autoPlay became false (sequential playback)")
                player.pause()
                playbackState = .paused
            }
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
                // Reset loading state if stuck
                if loadingState.isLoading {
                    print("DEBUG: [VIDEO SETUP] loadingState stuck at .loading, resetting to .idle")
                    loadingState = .idle
                }
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
    
    
    /// Cache player state when going to background (but don't detach)
    private func cachePlayerStateForBackground() {
        guard let player = player else { 
            return 
        }
        
        // Store current state for later restoration
        let wasPlaying = player.rate > 0
        let currentTime = player.currentTime()
        
        print("DEBUG: [VIDEO BACKGROUND] Caching state for \(mid) - wasPlaying: \(wasPlaying), time: \(CMTimeGetSeconds(currentTime))")
        
        // Cache the state for restoration (MediaCell only, NOT TweetDetail or MediaBrowser)
        // TweetDetail uses DetailVideoManager singleton and should not share players with MediaCell
        // MediaBrowser uses FullScreenVideoManager singleton and should not share players with MediaCell
        if mode == .mediaCell {
            VideoStateCache.shared.cacheVideoState(
                for: mid,
                player: player,
                time: currentTime,
                wasPlaying: wasPlaying,
                originalMuteState: isMuted
            )
        }
        
        // Pause the player but keep it attached
        player.pause()
        print("DEBUG: [VIDEO BACKGROUND] Player paused but NOT detached for \(mid)")
    }
    
    /// Detach player (old function kept for reference but not called anymore)
    private func detachPlayerForBackground() {
        guard let player = player else { 
            return 
        }
        
        // Store current state before detaching
        let wasPlaying = player.rate > 0
        let currentTime = player.currentTime()
        
        // Cache the state for restoration (MediaCell only, NOT TweetDetail or MediaBrowser)
        // TweetDetail uses DetailVideoManager singleton and should not share players with MediaCell
        // MediaBrowser uses FullScreenVideoManager singleton and should not share players with MediaCell
        if mode == .mediaCell {
            VideoStateCache.shared.cacheVideoState(
                for: mid,
                player: player,
                time: currentTime,
                wasPlaying: wasPlaying,
                originalMuteState: isMuted
            )
        }
        
        // Pause the player first
        player.pause()
        
        // Mark as detached - this prevents the video layer from becoming invalid
        isPlayerDetached = true
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
            @Binding var isBuffering: Bool
            let mediaType: MediaType
            let progressiveForwardBufferDuration: Double
            
            func makeCoordinator() -> Coordinator {
                Coordinator(isBuffering: $isBuffering)
            }
            
            class Coordinator: NSObject {
                var statusObserver: NSKeyValueObservation?
                var timeControlObserver: NSKeyValueObservation?
                @Binding var isBuffering: Bool
                var bufferingDebounceTask: DispatchWorkItem?
                
                init(isBuffering: Binding<Bool>) {
                    self._isBuffering = isBuffering
                    super.init()
                }
                
                deinit {
                    statusObserver?.invalidate()
                    timeControlObserver?.invalidate()
                    bufferingDebounceTask?.cancel()
                }
            }
            
            private func applyAutomaticWaiting(for player: AVPlayer) {
                if mediaType == .video {
                    player.automaticallyWaitsToMinimizeStalling = true
                    if let item = player.currentItem {
                        item.preferredForwardBufferDuration = max(
                            item.preferredForwardBufferDuration,
                            progressiveForwardBufferDuration
                        )
                    }
                } else {
                    player.automaticallyWaitsToMinimizeStalling = false
                }
            }
            
            func makeUIViewController(context: Context) -> AVPlayerViewController {
                
                let controller = AVPlayerViewController()
                controller.showsPlaybackControls = true
                controller.videoGravity = .resizeAspect
                controller.view.backgroundColor = .black
                
                // Set player immediately to ensure it's attached from the start
                controller.player = player
                
                if let player = player {
                    
                    // Setup timeControlStatus observer to track buffering
                    // CRITICAL: No .initial option to prevent immediate firing and update loops
                    context.coordinator.timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { observedPlayer, _ in
                        DispatchQueue.main.async {
                            let isWaitingToPlay = observedPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
                            
                            if isWaitingToPlay {
                                // Cancel any pending hide task
                                context.coordinator.bufferingDebounceTask?.cancel()
                                
                                // Debounce: Only show spinner if buffering lasts > 0.5 seconds
                                // This prevents flashing spinner during brief buffering pauses
                                let task = DispatchWorkItem {
                                    context.coordinator.isBuffering = true
                                }
                                context.coordinator.bufferingDebounceTask = task
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
                            } else if observedPlayer.timeControlStatus == .playing {
                                // Cancel pending show task and hide spinner immediately
                                context.coordinator.bufferingDebounceTask?.cancel()
                                context.coordinator.isBuffering = false
                                NSLog("✅ [AVPlayerViewController] Video started playing")
                            } else {
                                // Paused - cancel pending show task and hide spinner
                                context.coordinator.bufferingDebounceTask?.cancel()
                                context.coordinator.isBuffering = false
                            }
                        }
                    }
                    
                    // Setup status observer to ensure playback starts when ready
                    if let playerItem = player.currentItem {
                        // Check if we have buffered data
                        let hasBufferedData = !playerItem.loadedTimeRanges.isEmpty
                        
                        if playerItem.status == .readyToPlay {
                            
                            if hasBufferedData {
                                applyAutomaticWaiting(for: player)
                            } else if mediaType == .video {
                                playerItem.preferredForwardBufferDuration = max(
                                    playerItem.preferredForwardBufferDuration,
                                    progressiveForwardBufferDuration
                                )
                            }
                            
                            // Use DispatchQueue to ensure this happens after view is fully set up
                            DispatchQueue.main.async {
                                // For fullscreen/detail modes (AVPlayerViewController), always unmute
                                player.isMuted = false
                                player.play()
                            }
                        } else if playerItem.status == .unknown {
                            // Set buffering state while waiting (defer to avoid state modification during view update)
                            DispatchQueue.main.async {
                                context.coordinator.isBuffering = true
                            }
                            if mediaType == .video {
                                playerItem.preferredForwardBufferDuration = max(
                                    playerItem.preferredForwardBufferDuration,
                                    progressiveForwardBufferDuration
                                )
                            }
                        } else {
                            NSLog("DEBUG: [AVPlayerViewController] ❌ Player item in failed state during makeUIViewController")
                        }
                    } else {
                        NSLog("DEBUG: [AVPlayerViewController] ⚠️ Player has no current item in makeUIViewController")
                    }
                } else {
                    NSLog("DEBUG: [AVPlayerViewController] ❌ Created with nil player - this shouldn't happen!")
                }
                
                return controller
            }
            
            func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
                // CRITICAL: Detach player first, then re-attach
                // This ensures the player's layer is not attached to any other view
                
                // Detach and reattach to force fresh layer connection
                uiViewController.player = nil
                uiViewController.player = player
                
                // Update timeControlStatus observer only if player changed
                if let player = player, uiViewController.player != player {
                    context.coordinator.timeControlObserver?.invalidate()
                    context.coordinator.timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { observedPlayer, _ in
                        DispatchQueue.main.async {
                            let isWaitingToPlay = observedPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
                            
                            if isWaitingToPlay {
                                context.coordinator.isBuffering = true
                            } else if observedPlayer.timeControlStatus == .playing {
                                context.coordinator.isBuffering = false
                                NSLog("✅ [AVPlayerViewController] Video started playing in updateUIViewController")
                            } else {
                                context.coordinator.isBuffering = false
                            }
                        }
                    }
                }
                
                // CRITICAL: For fullscreen/detail, always trigger play() here after layer is attached
                // This ensures the video layer is ready before playback starts
                if let player = player, let playerItem = player.currentItem {
                    // Always trigger play in update, regardless of status
                    // AVPlayerViewController will handle the player once it's ready
                    
                    // Check if player has buffered data
                    let hasBufferedData = !playerItem.loadedTimeRanges.isEmpty
                    
                    if playerItem.status == .readyToPlay {
                        
                        if hasBufferedData {
                            applyAutomaticWaiting(for: player)
                            
                            // Play immediately - for fullscreen/detail modes (AVPlayerViewController), always unmute
                            player.isMuted = false
                            player.play()
                        } else {
                            // No buffered data - need to load
                            DispatchQueue.main.async {
                                context.coordinator.isBuffering = true
                            }
                            let bufferTarget = mediaType == .video ? progressiveForwardBufferDuration : 15.0
                            playerItem.preferredForwardBufferDuration = max(playerItem.preferredForwardBufferDuration, bufferTarget)
                            player.preroll(atRate: 1.0) { success in
                                DispatchQueue.main.async {
                                    applyAutomaticWaiting(for: player)
                                    player.play()
                                    // Buffering state will be updated by timeControlStatus observer
                                }
                            }
                        }
                    } else if playerItem.status == .unknown {
                        // Show buffering while waiting (defer to avoid state modification during view update)
                        DispatchQueue.main.async {
                            context.coordinator.isBuffering = true
                        }
                        if mediaType == .video {
                            playerItem.preferredForwardBufferDuration = max(
                                playerItem.preferredForwardBufferDuration,
                                progressiveForwardBufferDuration
                            )
                        }
                        
                        // Invalidate old observer if any
                        context.coordinator.statusObserver?.invalidate()
                        
                        // Simple one-shot observer with weak capture
                        context.coordinator.statusObserver = playerItem.observe(\.status, options: [.new]) { [weak player] item, _ in
                            guard let player = player else { return }
                            DispatchQueue.main.async {
                                if item.status == .readyToPlay {
                                    applyAutomaticWaiting(for: player)
                                    player.play()
                                    context.coordinator.statusObserver?.invalidate()
                                    context.coordinator.statusObserver = nil
                                    // Buffering state will be updated by timeControlStatus observer
                                }
                            }
                        }
                    } else {
                        NSLog("DEBUG: [AVPlayerViewController] ❌ Player item in failed state")
                    }
                } else if player != nil {
                    NSLog("DEBUG: [AVPlayerViewController] ⚠️ Player provided but has no current item")
                }
                
            }
        }

// MARK: - AVPlayerLayer Wrapper for MediaCell
struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    
    func makeUIView(context: Context) -> UIView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        guard let playerView = uiView as? PlayerView else { return }
        
        // CRITICAL: Detach player first, then re-attach
        // This ensures the player's layer is not attached to any other view
        // Without this, cached/reused players can show black screen in MediaCell
        playerView.playerLayer.player = nil
        playerView.playerLayer.player = player
    }
    
    class PlayerView: UIView {
        override class var layerClass: AnyClass {
            return AVPlayerLayer.self
        }
        
        var playerLayer: AVPlayerLayer {
            return layer as! AVPlayerLayer
        }
    }
}

// MARK: - VideoManager Observer Modifier
struct VideoManagerObserverModifier: ViewModifier {
    let videoManager: VideoManager?
    let mid: String
    let mode: Mode
    let onVideoIndexChanged: (Bool) -> Void
    
    func body(content: Content) -> some View {
        if let videoManager = videoManager {
            content
                .onReceive(videoManager.$currentVideoIndex) { _ in
                    // When currentVideoIndex changes, re-evaluate autoPlay state
                    if mode == .mediaCell {
                        let shouldAutoPlay = videoManager.shouldPlayVideo(for: mid)
                        onVideoIndexChanged(shouldAutoPlay)
                    }
                }
        } else {
            content
        }
    }
}
