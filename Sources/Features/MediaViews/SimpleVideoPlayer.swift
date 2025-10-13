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
    @State private var isLongPressing = false
    @State private var isPlayerDetached = false  // Track background state
    @State private var isBuffering = false // Track buffering state
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
            .onChange(of: player) { _, newPlayer in handlePlayerChange(newPlayer: newPlayer) }
            .onChange(of: shouldLoadVideo) { _, newShouldLoadVideo in handleLoadingStateChange(newShouldLoadVideo: newShouldLoadVideo) }
            .onReceive(NotificationCenter.default.publisher(for: .stopAllVideos)) { _ in handleStopAllVideos() }
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
        
        // Pause player when view disappears, but keep it alive in VideoStateCache for sharing
        // MediaCell and MediaBrowser share the same player instance via VideoStateCache
        if mode == .mediaCell {
            player?.pause()
        } else if mode == .mediaBrowser {
            // Exiting fullscreen - pause but keep player alive for MediaCell to reuse
            player?.pause()
        } else if mode == .tweetDetail {
            // TweetDetail: DO ABSOLUTELY NOTHING
            // Singleton player lives in DetailVideoManager, view recreation shouldn't affect it
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
            NSLog("DEBUG: [SimpleVideoPlayer] stopAllVideos - paused MediaCell \(mid)")
        }
        // TweetDetail and MediaBrowser: DO NOTHING
    }
    
    private func handleDidEnterBackground() {
        // App going to background - detach player to prevent black screens
        print("DEBUG: [VIDEO BACKGROUND] App entering background for \(mid)")
        detachPlayerForBackground()
    }
    
    private func handleWillEnterForeground() {
        // App will enter foreground - reattach player to prevent black screens
        print("DEBUG: [VIDEO FOREGROUND] App will enter foreground for \(mid)")
        reattachPlayerForForeground()
    }
    
    private func handleDidBecomeActive() {
        // App became active - ensure player is properly reattached and configured
        print("DEBUG: [VIDEO APP ACTIVE] App became active for \(mid)")
        
        // Validate player health first
        if let player = player {
            // Check if player item is still valid
            if player.currentItem == nil || player.currentItem?.status == .failed {
                print("DEBUG: [VIDEO APP ACTIVE] Player is invalid, clearing and will recreate for \(mid)")
                self.player = nil
                // Reset error state
                loadingState = .idle
            }
        }
        
        // CRITICAL: Force view recreation to fix black screen for ALL modes
        if player != nil {
            // Increment representableId to force view recreation for ALL modes
            // This works for both AVPlayerViewController (mediaBrowser/tweetDetail) and native VideoPlayer (mediaCell)
            // since uniqueViewId is computed from representableId
            representableId += 1
            print("DEBUG: [VIDEO APP ACTIVE] Forced view recreation for \(mid), new representableId: \(representableId)")
        }
        
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
        
        // If still no player, force reload by calling setupPlayer
        if player == nil && shouldLoadVideo && !isPlayerDetached && isVisible {
            print("DEBUG: [VIDEO APP ACTIVE] No valid player found, forcing reload for \(mid)")
            setupPlayer()
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
    
    private func handleTap() {
        if let onVideoTap = onVideoTap {
            onVideoTap()
        }
    }
    
    private func handleLongPress() {
        isLongPressing = true
        // Handle manual video reset on long press
        handleError(strategy: .manualReset)
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
                        AVPlayerViewControllerRepresentable(player: player, isBuffering: $isBuffering)
                            .id("\(mid)_\(representableId)") // Force recreation with representableId changes
                            .onAppear {
                            }
                            .onTapGesture {
                                if let onVideoTap = onVideoTap {
                                    onVideoTap()
                                }
                            }
                    } else {
                        // MediaCell: Use native SwiftUI VideoPlayer
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
        
        // SPECIAL CASE: For TweetDetail mode, use singleton DetailVideoManager
        if mode == .tweetDetail {
            
            // Check if singleton already has this exact video playing
            if let existingPlayer = DetailVideoManager.shared.currentPlayer,
               DetailVideoManager.shared.currentVideoMid == mid {
                self.player = existingPlayer
                self.loadingState = .loaded
                
                // Resume if paused
                if existingPlayer.rate == 0 {
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
        
        // NORMAL FLOW: Check VideoStateCache for shared player (MediaCell/MediaBrowser)
        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            NSLog("DEBUG: [VIDEO CACHE] ✅ Found shared player for \(mid) in \(mode) mode")
            
            // Apply mute state based on current mode
            if mode == .mediaCell {
                cachedState.player.isMuted = MuteState.shared.isMuted
            } else if mode == .mediaBrowser {
                cachedState.player.isMuted = false
            }
            
            restoreFromCache(cachedState)
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
                    } else {
                        newPlayer.isMuted = false
                        NSLog("DEBUG: [VIDEO SETUP] Unmuted immediately after player creation for fullscreen/detail")
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
                return
            }
        }
        
        // Reset error state when starting setup
        if loadingState.hasFailed {
            print("DEBUG: [VIDEO SETUP] Resetting error state for \(mid)")
            loadingState = .idle
        }
        
        // No shared player found, create a new one
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
            setupPlayer()
            return
        }
        
        
        // Check if player item is in a failed state
        if playerItem.status == .failed {
            NSLog("DEBUG: [VIDEO CACHE] ❌ Cached player item is in failed state, clearing cache and creating new player for \(mid)")
            VideoStateCache.shared.clearCache(for: mid)
            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
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
            } else {
            }
        } else {
            // For MediaCell mode, check player readiness but trust players with buffered data
            if playerItem.status != .readyToPlay {
                // If player has buffered data, it's transitioning and will be ready soon - use it!
                if hasBufferedData {
                    NSLog("DEBUG: [VIDEO CACHE] ⚠️ Player status not ready yet (status: \(playerItem.status.rawValue)) but HAS buffered data - will use it for MediaCell")
                } else {
                    // No data and not ready - reject it
                    NSLog("DEBUG: [VIDEO CACHE] ❌ Cached player item not ready (status: \(playerItem.status.rawValue)) and no buffered data for MediaCell, clearing cache and creating new player for \(mid)")
                    VideoStateCache.shared.clearCache(for: mid)
                    SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
                    setupPlayer()
                    return
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
        
        // Restore the cached player (AFTER setting mute state)
        self.player = cachedState.player
        
        // CRITICAL: Increment representableId to force VideoPlayer layer recreation
        // This fixes black screen issues when scrolling in MediaCell
        if mode == .mediaCell {
            self.representableId += 1
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
                cachedState.player.automaticallyWaitsToMinimizeStalling = false
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
            
            // Update state immediately - no waiting for seek
            self.loadingState = .loaded
            self.playbackState = .notStarted
        } else {
            // For MediaCell, seek to cached position
            
            // Use seek with tolerance for better reliability
            let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
            cachedState.player.seek(to: cachedState.time, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
                if finished {
                    // Resume playback if VideoManager approves
                    if cachedState.wasPlaying && self.isVisible && self.currentAutoPlay && self.videoManager?.shouldPlayVideo(for: self.mid) == true {
                        cachedState.player.play()
                        NSLog("DEBUG: [VIDEO CACHE] ✅ Resumed playback from cache for \(self.mid) - VideoManager approved")
                    } else {
                    }
                } else {
                    NSLog("DEBUG: [VIDEO CACHE] ⚠️ Seek did not finish for \(self.mid)")
                }
            }
            
            // Update state
            self.loadingState = .loaded
            self.playbackState = .notStarted
        }
        
    }
    
    private func configurePlayer(_ player: AVPlayer) {
        
        // CRITICAL: Always disable automatic waiting for HLS videos
        // This prevents AVPlayer from evaluating buffering rate which adds 5-10 second delays
        // Our videos are locally cached so we don't need network buffering evaluation
        player.automaticallyWaitsToMinimizeStalling = false
        
        // CRITICAL: For MediaCell, pause playing shared players FIRST to prevent audio bleed
        if mode == .mediaCell && player.rate > 0 {
            player.pause()
        }
        
        // Configure player mute state based on mode
        if mode == .mediaCell {
            // MediaCell: Apply global mute state
            player.isMuted = MuteState.shared.isMuted
        } else {
            // Fullscreen/Detail: Always unmute
            player.isMuted = false
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
        
        // Cache player state in VideoStateCache for sharing (using time observer for deferred caching when ready)
        // For now, just note if player is ready
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
        } else {
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
            @Binding var isBuffering: Bool
            
            func makeCoordinator() -> Coordinator {
                Coordinator(isBuffering: $isBuffering)
            }
            
            class Coordinator: NSObject {
                var statusObserver: NSKeyValueObservation?
                var timeControlObserver: NSKeyValueObservation?
                @Binding var isBuffering: Bool
                
                init(isBuffering: Binding<Bool>) {
                    self._isBuffering = isBuffering
                    super.init()
                }
                
                deinit {
                    statusObserver?.invalidate()
                    timeControlObserver?.invalidate()
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
                                context.coordinator.isBuffering = true
                            } else if observedPlayer.timeControlStatus == .playing {
                                context.coordinator.isBuffering = false
                            } else {
                                // Paused
                                context.coordinator.isBuffering = false
                            }
                        }
                    }
                    
                    // Setup status observer to ensure playback starts when ready
                    if let playerItem = player.currentItem {
                        // Check if we have buffered data
                        let hasBufferedData = !playerItem.loadedTimeRanges.isEmpty
                        
                        if playerItem.status == .readyToPlay {
                            
                            // CRITICAL: For cached content, disable automatic waiting
                            if hasBufferedData {
                                player.automaticallyWaitsToMinimizeStalling = false
                            }
                            
                            // Use DispatchQueue to ensure this happens after view is fully set up
                            DispatchQueue.main.async {
                                player.play()
                            }
                        } else if playerItem.status == .unknown {
                            // Set buffering state while waiting
                            context.coordinator.isBuffering = true
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
                        
                        // CRITICAL: For cached content, disable automatic waiting
                        if hasBufferedData {
                            player.automaticallyWaitsToMinimizeStalling = false
                            
                            // Play immediately
                            player.play()
                        } else {
                            // No buffered data - need to load
                            context.coordinator.isBuffering = true
                            playerItem.preferredForwardBufferDuration = 2.0
                            player.preroll(atRate: 1.0) { success in
                                DispatchQueue.main.async {
                                    player.play()
                                    // Buffering state will be updated by timeControlStatus observer
                                }
                            }
                        }
                    } else if playerItem.status == .unknown {
                        // Show buffering while waiting
                        context.coordinator.isBuffering = true
                        
                        // Invalidate old observer if any
                        context.coordinator.statusObserver?.invalidate()
                        
                        // Simple one-shot observer with weak capture
                        context.coordinator.statusObserver = playerItem.observe(\.status, options: [.new]) { [weak player] item, _ in
                            guard let player = player else { return }
                            DispatchQueue.main.async {
                                if item.status == .readyToPlay {
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
