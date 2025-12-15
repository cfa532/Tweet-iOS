//
//  SimpleVideoPlayer.swift
//  Tweet
//
//  Consolidated video player with asset sharing
//

import SwiftUI
import AVKit
import AVFoundation
import UIKit
import CoreImage
import CoreVideo
import QuartzCore

// MARK: - Video Player Mode
enum Mode {
    case mediaCell // Normal cell in feed/grid
    case mediaBrowser // In MediaBrowserView (fullscreen browser)
    case tweetDetail // In TweetDetailView (single tweet view)
}

// MARK: - Consolidated State Enums
enum LoadingState: Equatable {
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

// MARK: - Last Frame Cache (for flicker-free placeholders)
/// Stores a downscaled last-rendered frame per `mid` for fast placeholder rendering.
/// Uses an in-memory cache with a short TTL to avoid unbounded memory growth.
final class VideoLastFrameCache {
    static let shared = VideoLastFrameCache()
    
    private let cache = NSCache<NSString, UIImage>()
    private var timestamps: [String: Date] = [:]
    private let ttl: TimeInterval = 10 * 60 // 10 minutes
    
    private init() {
        // Rough bound: keep only a small number of frames in memory.
        cache.countLimit = 48
    }
    
    func set(_ image: UIImage, for mid: String) {
        cache.setObject(image, forKey: mid as NSString)
        timestamps[mid] = Date()
    }
    
    func image(for mid: String) -> UIImage? {
        guard let ts = timestamps[mid] else { return nil }
        if Date().timeIntervalSince(ts) > ttl {
            clear(for: mid)
            return nil
        }
        return cache.object(forKey: mid as NSString)
    }
    
    func clear(for mid: String) {
        cache.removeObject(forKey: mid as NSString)
        timestamps.removeValue(forKey: mid)
    }
    
    func clearAll() {
        cache.removeAllObjects()
        timestamps.removeAll()
    }
}

// MARK: - Frame Extraction Utilities (AVPlayerItemVideoOutput)
enum VideoFrameExtractor {
    static let ciContext = CIContext(options: [
        // Keep it lightweight; we only need fast, small frame extraction.
        CIContextOption.useSoftwareRenderer: false
    ])
    
    /// Convert a pixel buffer to a downscaled UIImage (for feed placeholders).
    static func makeDownscaledUIImage(from pixelBuffer: CVPixelBuffer, maxDimension: CGFloat = 720) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let image = UIImage(cgImage: cgImage)
        return downscale(image, maxDimension: maxDimension)
    }
    
    /// Downscale without changing aspect ratio.
    static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension, maxSide > 0 else { return image }
        
        let scale = maxDimension / maxSide
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    /// Heuristic guard: treat near-black frames as invalid placeholders.
    /// This prevents overwriting a good cached last frame with a black capture that can happen during app transitions.
    static func isMostlyBlack(_ image: UIImage, luminanceThreshold: Float = 0.05) -> Bool {
        // If we can't analyze, don't block caching.
        guard let cgImage = image.cgImage else { return false }

        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return false }
        guard let filter = CIFilter(name: "CIAreaAverage") else { return false }

        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        guard let outputImage = filter.outputImage else { return false }

        var pixel: [UInt8] = [0, 0, 0, 0] // RGBA
        ciContext.render(
            outputImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let a = Float(pixel[3]) / 255.0
        if a < 0.1 { return false }

        let r = Float(pixel[0]) / 255.0
        let g = Float(pixel[1]) / 255.0
        let b = Float(pixel[2]) / 255.0
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance < luminanceThreshold
    }
}

// MARK: - Unified Simple Video Player
struct SimpleVideoPlayer: View {
    // Cache screen dimensions to avoid repeated UIScreen.main calls
    // Account for TweetListView horizontal padding (16pt on each side = 32pt total)
    private static let cachedScreenWidth: CGFloat = UIScreen.main.bounds.width
    private static let cachedGridWidth: CGFloat = max(10, cachedScreenWidth - 32 - 32) // 32 for original spacing + 32 for TweetListView padding
    
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
    @State private var isCoveredByOverlay: Bool = false
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
    @State private var hasInitialized = false // Track if player has been initialized to prevent recomposition when scrolling
    
    // Last-frame placeholder support (MediaCell/HLS): keep a decoded frame to avoid black flicker.
    @State private var videoOutput: AVPlayerItemVideoOutput?
    @State private var videoOutputAttachedItem: AVPlayerItem?
    @State private var lastFrameCaptureAt: Date = .distantPast
    @State private var lastFrameVersion: Int = 0 // bumps when we store a new frame (forces view update)
    
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
    private var isAnyVideoMedia: Bool {
        mediaType == .video || mediaType == .hls_video
    }
    
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
    
    // Track actual visibility (whether video is covered by overlay/modal)
    private var isActuallyVisible: Bool {
        // Only gate MediaCell playback by overlay coverage.
        // Fullscreen/detail contexts manage their own visibility and should not be paused by feed overlays.
        mode != .mediaCell || !isCoveredByOverlay
    }
    
    var body: some View {
        videoContentView
            .onAppear {
                handleOnAppear()
                // Initialize overlay coverage state when view appears (no polling).
                isCoveredByOverlay = OverlayVisibilityCoordinator.shared.isCovered
            }
            .onDisappear { handleOnDisappear() }
            .onChange(of: mode) { oldMode, newMode in handleModeChange(oldMode: oldMode, newMode: newMode) }
            .onChange(of: isMuted) { _, newMuteState in handleMuteChange(newMuteState: newMuteState) }
            .onReceive(MuteState.shared.$isMuted) { globalMuteState in handleGlobalMuteChange(globalMuteState: globalMuteState) }
            .onChange(of: currentAutoPlay) { _, shouldAutoPlay in handleAutoPlayChange(shouldAutoPlay: shouldAutoPlay) }
            .onChange(of: isVisible) { _, visible in handleVisibilityChange(visible: visible) }
            .onChange(of: isActuallyVisible) { _, actuallyVisible in handleActualVisibilityChange(actuallyVisible: actuallyVisible) }
            .onReceive(NotificationCenter.default.publisher(for: .overlayCoverageChanged)) { notification in
                guard mode == .mediaCell else { return }
                if let isCovered = notification.userInfo?["isCovered"] as? Bool {
                    isCoveredByOverlay = isCovered
                }
            }
            // Observe VideoManager's currentVideoIndex changes for sequential playback
            .modifier(VideoManagerObserverModifier(videoManager: videoManager, mid: mid, mode: mode) { shouldAutoPlay in
                handleAutoPlayChange(shouldAutoPlay: shouldAutoPlay)
            })
            .onChange(of: player) { _, newPlayer in handlePlayerChange(newPlayer: newPlayer) }
            .onChange(of: shouldLoadVideo) { _, newShouldLoadVideo in handleLoadingStateChange(newShouldLoadVideo: newShouldLoadVideo) }
            .onReceive(NotificationCenter.default.publisher(for: .stopAllVideos)) { _ in handleStopAllVideos() }
            .onReceive(NotificationCenter.default.publisher(for: .videoInfrastructureRestarted)) { _ in handleVideoInfrastructureRestarted() }
            .onReceive(NotificationCenter.default.publisher(for: .videoLayerRefresh)) { _ in handleVideoLayerRefresh() }
            .onReceive(NotificationCenter.default.publisher(for: .reloadVisibleVideosOnly)) { _ in
                handleReloadVisibleVideosOnly()
            }
            .onReceive(NotificationCenter.default.publisher(for: .appUserReady)) { _ in handleAppUserReady() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in handleWillResignActive() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in handleDidEnterBackground() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in handleWillEnterForeground() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in handleDidBecomeActive() }
            .onTapGesture { handleTap() }
            .onLongPressGesture(minimumDuration: 0.5) { handleLongPress() } onPressingChanged: { pressing in handlePressingChanged(pressing: pressing) }
            .task(id: loadingState) { await performPeriodicHealthCheck() }
    }
    
    @ViewBuilder
    private var videoContentView: some View {
        if let videoAR = videoAspectRatio, videoAR > 0 {
            switch mode {
            case .mediaCell:
                // MediaCell mode: fill the MediaCell's frame (no GeometryReader, no fixed frame)
                // MediaGridView sets explicit frames on MediaCells, so the video should fill that frame
                // Use .fill contentMode to fill the lesser dimension and clip overflow (same as images)
                // No clipping here - MediaCell ZStack handles layering, MediaGridView clips the grid
                videoPlayerView()
                    .aspectRatio(videoAR, contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .mediaBrowser:
                // MediaBrowser mode: fullscreen browser - use GeometryReader for dynamic sizing
                GeometryReader { geometry in
                    let screenWidth = geometry.size.width
                    let screenHeight = geometry.size.height
                    
                    if isVideoPortrait {
                        // Portrait video: fit on full screen
                        videoPlayerView()
                            .aspectRatio(videoAR, contentMode: .fit)
                            .frame(width: screenWidth, height: screenHeight, alignment: .center)
                    } else {
                        // Landscape video: rotate 90 degrees clockwise to fit on portrait device
                        ZStack {
                            videoPlayerView()
                                .aspectRatio(videoAR, contentMode: .fit)
                                .frame(maxWidth: screenWidth - 2, maxHeight: screenHeight - 2)
                                .rotationEffect(.degrees(-90))
                                .scaleEffect(screenHeight / screenWidth)
                                // Force-center after background/foreground; transforms don't affect layout.
                                .position(x: screenWidth / 2, y: screenHeight / 2)
                                .background(Color.black)
                        }
                        .frame(width: screenWidth, height: screenHeight, alignment: .center)
                    }
                }
                
            case .tweetDetail:
                // TweetDetail mode: single video view with fit aspect ratio - use GeometryReader for dynamic sizing
                GeometryReader { geometry in
                    let screenWidth = geometry.size.width
                    let screenHeight = geometry.size.height
                    videoPlayerView()
                        .aspectRatio(videoAR, contentMode: .fit)
                        .frame(maxWidth: screenWidth, maxHeight: screenHeight)
                }
            }
        } else {
            // Fallback when no aspect ratio is available
            GeometryReader { geometry in
                let screenWidth = geometry.size.width
                let screenHeight = geometry.size.height
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
            
            // CRITICAL: If player is already loaded, mark as initialized to prevent recomposition
            // This is key for smooth scrolling - once initialized, skip unnecessary work
            if loadingState.isLoaded && !hasInitialized {
                hasInitialized = true
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
        } else if player != nil && loadingState.isLoaded && !hasInitialized {
            // Player exists and is loaded - mark as initialized
            hasInitialized = true
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
        
        // CRITICAL: For MediaCell mode, KEEP video completion observer active
        // Videos can finish while off-screen, and we need to catch that for sequential playback
        // Only remove KVO observers to prevent crashes if player item changes
        if mode == .mediaCell {
            NSLog("DEBUG: [OBSERVER LIFECYCLE] Keeping videoCompletionObserver active for off-screen playback: \(mid)")
            // Remove KVO observers only (these can cause crashes if playerItem changes)
            playerItemStatusObserver?.invalidate()
            playerItemStatusObserver = nil
            playerItemBufferObserver?.invalidate()
            playerItemBufferObserver = nil
            
            // Remove time observer to save resources
            if let timeObserver = timeObserver {
                player?.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
            
            // KEEP videoCompletionObserver, videoErrorObserver, and playerItem reference active!
            // These are needed to handle videos finishing/failing while off-screen
            // playerItem reference is kept so setupPlayerObservers() can detect if already set up
        } else {
            // For other modes (mediaBrowser, tweetDetail), remove all observers
            removePlayerObservers()
        }

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
            // Capture last visible frame to use as placeholder next time (prevents black flicker).
            captureLastFrameIfPossible(reason: "onDisappear")
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
            // Check if this video should play according to VideoManager
            let shouldPlayAccordingToManager = videoManager?.shouldPlayVideo(for: mid) ?? false
            
            // CRITICAL: If video just finished and is no longer approved, immediately pause and stop
            // This prevents flicker by ensuring finished videos don't try to restart or cause view updates
            if !shouldPlayAccordingToManager && playbackState == .finished {
                // Video finished and is no longer the active video - ensure it's paused
                // Don't do ANYTHING else - no state changes, no view updates, just keep it paused
                // This prevents flicker during sequential video transitions
                if (player?.rate ?? 0) > 0 {
                    player?.pause()
                }
                return
            }
            
            // CRITICAL: Also skip if video is finished and shouldAutoPlay is false
            // This handles the case where VideoManager updates but the finished video shouldn't react
            if playbackState == .finished && !shouldAutoPlay {
                return
            }
            
            // CRITICAL: If already initialized and player is set up, skip work to prevent recomposition
            // This is key for smooth scrolling - once a video is initialized, don't recompose it
            // BUT: Always allow state changes for sequential playback transitions
            let isSequentialTransition = shouldPlayAccordingToManager && shouldAutoPlay
            let shouldSkip = hasInitialized && player != nil && loadingState.isLoaded && !isSequentialTransition
            
            if shouldSkip {
                // Only update if the playback state actually needs to change
                let currentShouldPlay = shouldAutoPlay && isVisible
                let isCurrentlyPlaying = (player?.rate ?? 0) > 0
                
                // If state matches, do nothing to prevent recomposition
                if currentShouldPlay == isCurrentlyPlaying {
                    return
                }
            }
            
            // CRITICAL: For sequential playback transitions, ensure player is ready before playing
            // This prevents flicker and ensures smooth transitions
            if shouldAutoPlay && isVisible && isSequentialTransition {
                // Ensure player is loaded and ready
                if player == nil || !loadingState.isLoaded {
                    print("⏳ [VIDEO TRANSITION] Next video not ready yet, waiting for load: \(mid)")
                    // Player will start automatically when ready via checkPlaybackConditions
                    return
                }
                
                // If player exists but item is not ready, wait a bit
                if let playerItem = player?.currentItem, playerItem.status != .readyToPlay {
                    print("⏳ [VIDEO TRANSITION] Player item not ready, status: \(playerItem.status.rawValue) for \(mid)")
                    // Will retry when status changes
                    return
                }
            }
            
            // Only check playback conditions, don't pause
            // Pausing here interferes with shared players used by fullscreen/detail
            checkPlaybackConditions(autoPlay: shouldAutoPlay, isVisible: isVisible)
        } else {
            // Ignore for other modes
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
                        // Mark as initialized to prevent recomposition when scrolling
                        if mode == .mediaCell {
                            hasInitialized = true
                        }
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
                // CRITICAL: After background recovery, video layers may be stale even if player exists
                // Always validate player can actually play, not just that it exists
                let playerIsMissing = player == nil || player?.currentItem == nil
                let playerIsBroken = !playerIsMissing && isPlayerBroken()
                
                if playerIsMissing || playerIsBroken {
                    let reason = playerIsMissing ? "missing" : "broken"
                    print("⚠️ [VIDEO VISIBILITY] Sanity check failed - player is \(reason), recreating for \(mid)")
                    SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
                    player = nil
                    loadingState = .idle
                    playbackState = .notStarted
                    setupPlayer()
                    return
                }
                
                // CRITICAL FIX: For MediaCell videos becoming visible after background,
                // only force view refresh if we actually went to background (not just screen lock/share sheet)
                // This prevents unnecessary refreshes during normal scrolling that cause black flicker
                if mode == .mediaCell && didEnterBackground && !hasRecoveredThisCycle {
                    print("✅ [VIDEO VISIBILITY] MediaCell becoming visible after background - forcing view refresh")
                    representableId += 1
                    hasRecoveredThisCycle = true  // Mark as recovered to avoid repeated refreshes
                }
                
                // Player is healthy, restore cached state
                // CRITICAL: Don't call checkPlaybackConditions here - let the normal flow handle it
                // Just like the first time, KVO handlers will fire when ready and check VideoManager
                restoreCachedVideoState()
                // checkPlaybackConditions will be called by KVO handlers or handleAutoPlayChange
            }
        } else {
            // About to become invisible: capture the last rendered frame for a smooth return.
            captureLastFrameIfPossible(reason: "becameInvisible")
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
            
            // NOTE: Pausing is handled in handleOnDisappear() to avoid conflicts
            // Do NOT pause here - let onDisappear handle it when the view actually disappears
        }
    }
    
    private func handleActualVisibilityChange(actuallyVisible: Bool) {
        print("🔍 [ACTUAL VISIBILITY] Changed to \(actuallyVisible) for \(mid)")
        
        // Only handle for MediaCell mode
        guard mode == .mediaCell else { return }
        
        if !actuallyVisible {
            // Video is covered by sheet/modal - pause it
            if let player = player {
                let wasPlaying = player.rate > 0 || playbackState == .playing
                if wasPlaying {
                    // Cache state so we can resume later
                    VideoStateCache.shared.cacheVideoState(
                        for: mid,
                        player: player,
                        time: player.currentTime(),
                        wasPlaying: true,
                        originalMuteState: player.isMuted
                    )
                    player.pause()
                    print("⏸️ [ACTUAL VISIBILITY] Paused video \(mid) because it's covered by overlay")
                }
            }
        } else {
            // Video is no longer covered.
            // If it was playing before it got covered (fullscreen/login/sheet), resume immediately
            // (don't depend on VideoManager approval here, since sequential state can be stale/cleared).
            if isVisible, let player = player {
                let wasPlayingBeforeCover = VideoStateCache.shared.getCachedState(for: mid)?.wasPlaying ?? false
                let shouldResume = wasPlayingBeforeCover || playbackState == .playing
                let noDetailViewActive = !DetailVideoManager.shared.isDetailViewActive()

                if shouldResume && noDetailViewActive {
                    if player.rate == 0 {
                        print("▶️ [ACTUAL VISIBILITY] Resuming video \(mid) after overlay dismissed")
                        player.isMuted = MuteState.shared.isMuted
                        player.play()
                    }
                    playbackState = .playing
                } else {
                    // Otherwise, re-check playback conditions on uncover (VideoManager decides).
                    if player.rate == 0 {
                        checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
                    }
                }
            }
        }
    }
    
    // MARK: - Overlay Visibility Callbacks

    private func handlePlayerChange(newPlayer: AVPlayer?) {
        // When player becomes available, check if we should autoplay
        if newPlayer != nil {
            checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
        }
    }
    
    private func handleStopAllVideos() {
        // Only pause MediaCell videos - TweetDetail and MediaBrowser are immune
        if mode == .mediaCell {
            // Store playback state before pausing so we can resume later
            if let player = player {
                let wasPlaying = player.rate > 0
                if wasPlaying {
                    // CRITICAL: Keep playbackState as .playing so we know it was playing
                    // Don't change to .paused - we'll use .playing to determine if we should resume
                    // Only pause the player, not the state
                    NSLog("DEBUG: [STOP ALL VIDEOS] Paused \(mid) - was playing (keeping playbackState: .playing), will resume when fullscreen closes")
                }
                player.pause()
                player.isMuted = true
            }
        }
        // TweetDetail and MediaBrowser: DO NOTHING
    }
    
    private func handleWillResignActive() {
        // CRITICAL: This handles BOTH screen lock AND app backgrounding AND share sheet
        // Screen lock: willResignActive → (locked) → didBecomeActive
        // App background: willResignActive → didEnterBackground → willEnterForeground → didBecomeActive
        // Share sheet: willResignActive → (sheet shown) → didBecomeActive (when dismissed)
        print("DEBUG: [VIDEO RESIGN ACTIVE] App will resign active for \(mid), mode: \(mode)")
        
        // Reset flags to ensure recovery will run when app becomes active again
        // This is critical for share sheet case where didEnterBackground might not fire
        hasRecoveredThisCycle = false
        didEnterBackground = false  // Reset - will be set to true if didEnterBackground fires
        
        // Cache player state but DON'T detach yet - keep video visible
        captureLastFrameIfPossible(reason: "willResignActive")
        cachePlayerStateForBackground()
    }
    
    private func handleDidEnterBackground() {
        // App actually went to background (not just screen lock)
        print("DEBUG: [VIDEO BACKGROUND] App entering background for \(mid)")
        didEnterBackground = true  // Mark that we went to background (not just screen lock)
    }
    
    private func handleWillEnterForeground() {
        print("DEBUG: [VIDEO FOREGROUND] App will enter foreground for \(mid)")
        // For MediaCell, AppDelegate always clears players and then posts `.reloadVisibleVideosOnly`
        // (short background, long background, and some screen-lock recoveries).
        // Running `recoverFromBackground()` here causes duplicate recreations (double getOrCreatePlayer)
        // and extra churn; instead defer to `.reloadVisibleVideosOnly` for visible MediaCell videos.
        if mode == .mediaCell, didEnterBackground {
            print("DEBUG: [VIDEO FOREGROUND] MediaCell background cycle; deferring recovery to reloadVisibleVideosOnly for \(mid)")
            // Don't detach here. Detaching shows the explicit "Video paused" overlay, which is confusing.
            // We already have a last-frame + spinner placeholder for MediaCell while the player reloads.
            isPlayerDetached = false
            // Prevent didBecomeActive from running recovery again in the same cycle.
            hasRecoveredThisCycle = true
            return
        }

        // For non-MediaCell contexts (detail/fullscreen) and screen-lock cycles (no didEnterBackground),
        // recover immediately.
        if !AppDelegate.isVideoInfrastructureReady {
            print("DEBUG: [VIDEO FOREGROUND] Infrastructure not ready yet; deferring recovery for \(mid)")
            // Same reasoning: rely on last-frame/spinner placeholders instead of "paused" overlay.
            isPlayerDetached = false
            return
        }

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
        
        // CRITICAL: Delayed health check after recovery
        // Sometimes players appear healthy immediately after recovery but are actually broken
        // Check again after a short delay to catch these cases
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
            
            // Check if player is broken or stuck in loading
            if let player = self.player, let playerItem = player.currentItem {
                let isBroken = self.isPlayerBroken()
                let isStuckLoading = self.loadingState.isLoading && playerItem.status == .readyToPlay
                let hasError = playerItem.error != nil || player.error != nil
                
                if isBroken || isStuckLoading || hasError {
                    print("⚠️ [VIDEO HEALTH CHECK] Player is broken/stuck after recovery for \(self.mid), recreating")
                    
                    // Clean up observers
                    if let observer = self.timeObserver, let observerPlayer = self.timeObserverPlayer {
                        observerPlayer.removeTimeObserver(observer)
                    }
                    self.timeObserver = nil
                    self.timeObserverPlayer = nil
                    
                    // Remove from SharedAssetCache
                    SharedAssetCache.shared.removeInvalidPlayer(for: self.playerCacheKey)
                    
                    let wasPlaying = VideoStateCache.shared.getCachedState(for: self.mid)?.wasPlaying ?? false
                    
                    player.pause()
                    self.player = nil
                    self.loadingState = .idle
                    self.playbackState = .notStarted
                    
                    // Recreate if needed
                    let shouldRecreate = (self.shouldLoadVideo || wasPlaying || self.mode == .tweetDetail || self.mode == .mediaBrowser)
                    if shouldRecreate {
                        self.setupPlayer()
                    }
                } else if self.loadingState.isLoading && playerItem.status == .readyToPlay {
                    // Player is ready but loadingState is stuck - fix it
                    // CRITICAL: Also check if there's buffered data before declaring it loaded
                    let hasBufferedData = !playerItem.loadedTimeRanges.isEmpty
                    let bufferedDuration = self.bufferedTimeAhead(for: playerItem, player: player)
                    
                    if hasBufferedData && bufferedDuration >= self.firstFrameMinimumBuffer {
                        print("⚠️ [VIDEO HEALTH CHECK] LoadingState stuck at .loading but player is ready with sufficient buffer (\(String(format: "%.2f", bufferedDuration))s), fixing for \(self.mid)")
                        self.loadingState = .loaded
                        self.retryAttempts = 0
                        if self.mode == .mediaCell {
                            self.hasInitialized = true
                        }
                    } else {
                        print("⏳ [VIDEO HEALTH CHECK] LoadingState at .loading, player ready but waiting for more buffer data (\(String(format: "%.2f", bufferedDuration))s < \(String(format: "%.2f", self.firstFrameMinimumBuffer))s required)")
                    }
                }
            }
        }
    }
    
    /// SANITY CHECK: Detects if player is broken
    private func isPlayerBroken() -> Bool {
        // Check 1: Player or item is missing
        guard let player = player else {
            print("⚠️ [SANITY CHECK] Player is nil for \(mid)")
            return true
        }
        guard let playerItem = player.currentItem else {
            print("⚠️ [SANITY CHECK] Player item is nil for \(mid)")
            return true
        }
        
        // Check 2: Status is failed
        if playerItem.status == .failed {
            print("⚠️ [SANITY CHECK] Player item status is failed for \(mid)")
            return true
        }
        
        // Check 3: Player item has an error (even if status isn't .failed yet)
        if let error = playerItem.error {
            print("⚠️ [SANITY CHECK] Player item has error: \(error.localizedDescription) for \(mid)")
            return true
        }
        
        // Check 4: Player has an error
        if let error = player.error {
            print("⚠️ [SANITY CHECK] Player has error: \(error.localizedDescription) for \(mid)")
            return true
        }
        
        // Check 5: Status is unknown (might be broken, but give it a chance)
        // Only consider unknown as broken if it's been a while since recovery
        if playerItem.status == .unknown {
            // Unknown status might be temporary - don't immediately mark as broken
            // Let it transition to readyToPlay or failed
            print("⚠️ [SANITY CHECK] Player item status is unknown for \(mid) - will check again")
            return false // Give it a chance
        }
        
        // Check 6: For screen lock recovery, don't check loadedTimeRanges alone
        // iOS might temporarily clear this data after screen lock, but it will reload
        // Only check loadedTimeRanges if status is .readyToPlay AND duration is invalid
        // This prevents false positives where player is healthy but temporarily has no ranges
        if playerItem.status == .readyToPlay && 
           playerItem.loadedTimeRanges.isEmpty && 
           !playerItem.duration.isValid {
            print("⚠️ [SANITY CHECK] Player ready but no loaded data AND invalid duration - likely broken for \(mid)")
            return true
        }
        
        // Check 7: Progressive player is stalled
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
    @MainActor
    private func recoverFromBackground() {
        print("DEBUG: [VIDEO RECOVERY] Starting recovery for \(mid), mode: \(mode), didEnterBackground: \(didEnterBackground), shouldLoadVideo: \(shouldLoadVideo)")
        let backgroundedThisCycle = didEnterBackground
        
        // Mark that we've recovered (but don't reattach yet)
        hasRecoveredThisCycle = true
        
        // CONSERVATIVE RECOVERY STRATEGY:
        // Only recreate players that are actually broken, leave healthy ones alone
        // This prevents unnecessary work and potential issues with working players
        
        // Check if player is broken first - this handles missing player/item, failed status, etc.
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
            
            let wasPlaying = VideoStateCache.shared.getCachedState(for: mid)?.wasPlaying ?? false
            let currentTime = player?.currentTime() ?? .zero
            
            player?.pause()
            player = nil
            loadingState = .idle
            playbackState = .notStarted
            
            // Only recreate if video should be loaded or was playing
            let shouldRecreate = (shouldLoadVideo || wasPlaying || mode == .tweetDetail || mode == .mediaBrowser)
            
            if shouldRecreate {
                setupPlayer()
                
                // Wait for player to be ready before reattaching
                Task { @MainActor in
                    var attempts = 0
                    while player == nil && !loadingState.hasFailed && attempts < 50 {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                        attempts += 1
                    }
                    
                    if let player = self.player {
                        // Reattach player after successful recreation
                        self.isPlayerDetached = false
                        // Force view refresh
                        self.representableId += 1
                        print("✅ [VIDEO RECOVERY] Player recreated and reattached for \(self.mid)")
                        
                        // Restore position and resume if was playing
                        if wasPlaying && CMTimeGetSeconds(currentTime) > 0 {
                            player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                                guard finished else { return }
                                Task { @MainActor in
                                    // Resume playback if was playing
                                    // For MediaCell, check VideoManager approval AND no overlays/detail active
                                    if self.mode == .mediaCell {
                                        player.isMuted = MuteState.shared.isMuted
                                        let approved = self.videoManager?.shouldPlayVideo(for: self.mid) ?? false
                                        let noOverlaysActive = !self.isCoveredByOverlay
                                        let noDetailViewActive = !DetailVideoManager.shared.isDetailViewActive()
                                        if approved && self.isVisible && noOverlaysActive && noDetailViewActive {
                                            player.play()
                                            self.playbackState = .playing
                                            print("✅ [VIDEO RECOVERY] Resumed playback after recreation for \(self.mid) (MediaCell, approved)")
                                        } else {
                                            print("⏳ [VIDEO RECOVERY] Video was playing but not approved yet or not visible - will resume when approved")
                                        }
                                    } else {
                                        // For other modes, resume if visible
                                        if self.isVisible {
                                            player.play()
                                            self.playbackState = .playing
                                            print("✅ [VIDEO RECOVERY] Resumed playback after recreation for \(self.mid)")
                                        }
                                    }
                                }
                            }
                        } else if wasPlaying {
                            // Video was playing but no time to restore - just resume
                            if self.mode == .mediaCell {
                                player.isMuted = MuteState.shared.isMuted
                                let approved = self.videoManager?.shouldPlayVideo(for: self.mid) ?? false
                                let noOverlaysActive = !self.isCoveredByOverlay
                                let noDetailViewActive = !DetailVideoManager.shared.isDetailViewActive()
                                if approved && self.isVisible && noOverlaysActive && noDetailViewActive {
                                    player.play()
                                    self.playbackState = .playing
                                    print("✅ [VIDEO RECOVERY] Resumed playback after recreation for \(self.mid) (MediaCell, approved, no seek)")
                                }
                            } else if self.isVisible {
                                player.play()
                                self.playbackState = .playing
                                print("✅ [VIDEO RECOVERY] Resumed playback after recreation for \(self.mid) (no seek)")
                            }
                        }
                    } else {
                        print("⚠️ [VIDEO RECOVERY] Failed to recreate player for \(self.mid)")
                    }
                }
            }
            return
        }
        
        // Player appears healthy - validate it can actually play before reattaching
        // CRITICAL: For MediaCell after short backgrounds, iOS may invalidate video layers
        // even if player object is intact. Force view refresh to ensure video layer is fresh.
        print("✅ [VIDEO RECOVERY] Player appears healthy - validating and reattaching")
        
        // Ensure player is in valid state (should always pass here since isPlayerBroken() checked)
        guard let player = player, let playerItem = player.currentItem else {
            print("⚠️ [VIDEO RECOVERY] Unexpected: Player or item missing in healthy path for \(mid)")
            return
        }
        
        // CRITICAL: Double-check player is actually ready after short backgrounds
        // Sometimes players pass isPlayerBroken() but are still not ready to play
        // This can happen if currentItem was cleared by AppDelegate but player object still exists
        if playerItem.status == .unknown {
            print("⚠️ [VIDEO RECOVERY] Player item status is unknown - treating as potentially broken, recreating for \(mid)")
            // Unknown status after background usually means player was cleared - recreate it
            if let observer = timeObserver, let observerPlayer = timeObserverPlayer {
                observerPlayer.removeTimeObserver(observer)
            }
            timeObserver = nil
            timeObserverPlayer = nil
            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
            let wasPlaying = VideoStateCache.shared.getCachedState(for: mid)?.wasPlaying ?? false
            player.pause()
            self.player = nil
            loadingState = .idle
            playbackState = .notStarted
            let shouldRecreate = (shouldLoadVideo || wasPlaying || mode == .tweetDetail || mode == .mediaBrowser)
            if shouldRecreate {
                setupPlayer()
            }
            return
        }
        
        // CRITICAL: Final safety check before reattaching - currentItem might have been cleared
        // by AppDelegate's clearVideoPlayersForBackgroundRecovery() after isPlayerBroken() check
        guard player.currentItem != nil else {
            print("⚠️ [VIDEO RECOVERY] Player currentItem became nil after health check - recreating for \(mid)")
            // Player was cleared by AppDelegate - recreate it
            if let observer = timeObserver, let observerPlayer = timeObserverPlayer {
                observerPlayer.removeTimeObserver(observer)
            }
            timeObserver = nil
            timeObserverPlayer = nil
            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
            let wasPlaying = VideoStateCache.shared.getCachedState(for: mid)?.wasPlaying ?? false
            player.pause()
            self.player = nil
            loadingState = .idle
            playbackState = .notStarted
            let shouldRecreate = (shouldLoadVideo || wasPlaying || mode == .tweetDetail || mode == .mediaBrowser)
            if shouldRecreate {
                setupPlayer()
            }
            return
        }
        
        // For MediaCell, DO NOT force a layer refresh unconditionally.
        // Unconditional refresh recreates the representable and causes a visible "flicker" on every foreground.
        // Instead, do a delayed health check and only refresh the view if the player appears "stuck"
        // (common symptom of stale AVPlayerLayer after background).
        if mode == .mediaCell && backgroundedThisCycle {
            let wasPlayingBeforeBackground = VideoStateCache.shared.getCachedState(for: mid)?.wasPlaying ?? false
            
            Task { @MainActor in
                // Give iOS a moment to re-wire the underlying layer pipeline after foregrounding.
                try? await Task.sleep(nanoseconds: 250_000_000) // 0.25s
                
                // Only relevant for currently visible feed videos.
                guard self.mode == .mediaCell, self.isVisible, self.isActuallyVisible else { return }
                guard let player = self.player, let item = player.currentItem else { return }
                
                // If player is actually broken, the normal recovery path / delayed health check will recreate it.
                if self.isPlayerBroken() { return }
                
                let statusReady = item.status == .readyToPlay
                let hasBufferedData = !item.loadedTimeRanges.isEmpty
                let bufferedAhead = self.bufferedTimeAhead(for: item, player: player)
                
                // Heuristic: refresh only if we're "ready" but have no frames buffered,
                // or if we were previously playing and are stuck waiting with insufficient buffer.
                let stuckWaiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate || item.isPlaybackBufferEmpty
                let shouldRefresh =
                    (statusReady && !hasBufferedData) ||
                    (wasPlayingBeforeBackground && stuckWaiting && bufferedAhead < self.firstFrameMinimumBuffer)
                
                if shouldRefresh {
                    print("✅ [VIDEO RECOVERY] MediaCell - delayed check indicates stale layer, refreshing view for \(self.mid)")
                    self.representableId += 1
                } else {
                    print("DEBUG: [VIDEO RECOVERY] MediaCell - delayed check: no refresh needed for \(self.mid)")
                }
            }
        }
        
        // Restore mute state
        if mode == .mediaCell && mediaType == .video {
            player.isMuted = MuteState.shared.isMuted
        } else {
            player.isMuted = false
        }
        
        // Reattach player first (before seeking/playing)
        isPlayerDetached = false
        
        // Restore playback state
        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            let currentTime = player.currentTime()
            let timeDiff = abs(CMTimeGetSeconds(cachedState.time) - CMTimeGetSeconds(currentTime))
            
            // Only seek if player is ready and time difference is significant
            if timeDiff > 0.5 && playerItem.status == .readyToPlay {
                // Use tolerance for better reliability after background recovery
                let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
                player.seek(to: cachedState.time, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
                    if finished {
                        print("✅ [VIDEO RECOVERY] Seek completed for \(self.mid)")
                    } else {
                        print("⚠️ [VIDEO RECOVERY] Seek did not finish for \(self.mid) - player may not be ready")
                    }
                }
            } else if timeDiff > 0.5 {
                // Player not ready yet - wait for it to become ready before seeking
                print("⏳ [VIDEO RECOVERY] Player not ready for seek (status: \(playerItem.status.rawValue)), will seek when ready")
                Task { @MainActor in
                    var attempts = 0
                    while playerItem.status != .readyToPlay && attempts < 50 {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                        attempts += 1
                    }
                    if playerItem.status == .readyToPlay {
                        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
                        player.seek(to: cachedState.time, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
                            if finished {
                                print("✅ [VIDEO RECOVERY] Seek completed after waiting for \(self.mid)")
                            } else {
                                print("⚠️ [VIDEO RECOVERY] Seek did not finish after waiting for \(self.mid)")
                            }
                        }
                    }
                }
            }
            
            // CRITICAL: Resume video if it was playing before backgrounding
            // For MediaCell, check VideoManager approval AND no overlays (fullscreen/detail view)
            // For other modes, resume if was playing and should load
            if cachedState.wasPlaying {
                if mode == .mediaCell {
                    // For MediaCell, check VideoManager approval AND that no overlays/detail views are active
                    let approved = videoManager?.shouldPlayVideo(for: mid) ?? false
                    let noOverlaysActive = !isCoveredByOverlay
                    let noDetailViewActive = !DetailVideoManager.shared.isDetailViewActive()
                    if approved && isVisible && noOverlaysActive && noDetailViewActive {
                        // CRITICAL: Always ensure muteState is correct before playing
                        player.isMuted = MuteState.shared.isMuted
                        NSLog("🔇 [PLAYER MUTE] recoverFromBackground - Applied global mute state for MediaCell: \(MuteState.shared.isMuted) for \(mid)")
                        
                        // Validate player is ready before playing
                        if playerItem.status == .readyToPlay {
                            player.play()
                            playbackState = .playing
                            print("✅ [VIDEO RECOVERY] Resumed playback for \(mid) (MediaCell, approved)")
                        } else {
                            // Player not ready yet - wait for it to become ready
                            print("⏳ [VIDEO RECOVERY] Player not ready yet (status: \(playerItem.status.rawValue)), will resume when ready")
                            Task { @MainActor in
                                let noOverlaysActive = !self.isCoveredByOverlay
                                let noDetailViewActive = !DetailVideoManager.shared.isDetailViewActive()
                                let approved = self.videoManager?.shouldPlayVideo(for: self.mid) ?? false
                                var attempts = 0
                                while self.playerItem?.status != .readyToPlay && attempts < 50 {
                                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                                    attempts += 1
                                }
                                if self.playerItem?.status == .readyToPlay && self.isVisible && approved && noOverlaysActive && noDetailViewActive {
                                    player.isMuted = MuteState.shared.isMuted
                                    player.play()
                                    self.playbackState = .playing
                                    print("✅ [VIDEO RECOVERY] Resumed playback after waiting for ready state for \(self.mid)")
                                }
                            }
                        }
                    } else {
                        print("⏳ [VIDEO RECOVERY] Video was playing but not approved yet or not visible - will resume when approved")
                    }
                } else {
                    // For other modes, resume if was playing
                    let shouldResume = (shouldLoadVideo || mode == .tweetDetail || mode == .mediaBrowser)
                    if shouldResume {
                        // Validate player is ready before playing
                        if playerItem.status == .readyToPlay {
                            player.play()
                            playbackState = .playing
                            print("✅ [VIDEO RECOVERY] Resumed playback for \(mid)")
                        } else {
                            // Player not ready yet - wait for it to become ready
                            print("⏳ [VIDEO RECOVERY] Player not ready yet (status: \(playerItem.status.rawValue)), will resume when ready")
                            Task { @MainActor in
                                var attempts = 0
                                while playerItem.status != .readyToPlay && attempts < 50 {
                                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                                    attempts += 1
                                }
                                if playerItem.status == .readyToPlay {
                                    player.play()
                                    self.playbackState = .playing
                                    print("✅ [VIDEO RECOVERY] Resumed playback after waiting for ready state for \(self.mid)")
                                }
                            }
                        }
                    }
                }
            }
        }

        // Even if the video *wasn't* playing before backgrounding, it may now be visible and should autoplay.
        // This fixes the case where the app returns to foreground with a visible MediaCell video that should play,
        // but `cachedState.wasPlaying` is false so we never call play().
        if mode == .mediaCell, isVisible, isActuallyVisible {
            Task { @MainActor in
                // Give SwiftUI/AVPlayerLayer a beat to reattach before evaluating autoplay.
                try? await Task.sleep(nanoseconds: 50_000_000) // 0.05s
                self.checkPlaybackConditions(autoPlay: self.currentAutoPlay, isVisible: self.isVisible)
            }
        }
        
        // Reset background flag after recovery to prevent stale flags from affecting future visibility changes
        didEnterBackground = false
        
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

    /// AppDelegate posts `.reloadVisibleVideosOnly` after long background / screen-lock recovery.
    /// At that time SharedAssetCache may have cleared player items AFTER our own foreground recovery ran,
    /// so we must revalidate and recreate *visible* MediaCell players here.
    @MainActor
    private func handleReloadVisibleVideosOnly() {
        guard mode == .mediaCell else { return }
        guard isVisible, isActuallyVisible else { return }

        print("DEBUG: [VIDEO RELOAD VISIBLE] Reload requested for visible video \(mid)")

        // Ensure we don't get stuck showing the explicit "Video paused" overlay.
        // Visible videos should either show last-frame/spinner placeholders or the player itself.
        isPlayerDetached = false

        // If we're already loading, don't thrash.
        if loadingState.isLoading {
            print("DEBUG: [VIDEO RELOAD VISIBLE] Already loading \(mid), skipping")
            return
        }

        let itemMissing = (player?.currentItem == nil)
        let timeInvalid = !(player?.currentTime().seconds.isFinite ?? true)
        let broken = itemMissing || timeInvalid || isPlayerBroken()

        if broken {
            print("⚠️ [VIDEO RELOAD VISIBLE] Player missing/broken for \(mid) (itemMissing: \(itemMissing), timeInvalid: \(timeInvalid)) - recreating")

            // Clean up time observer if attached.
            if let observer = timeObserver, let observerPlayer = timeObserverPlayer {
                observerPlayer.removeTimeObserver(observer)
            }
            timeObserver = nil
            timeObserverPlayer = nil

            // Force fresh creation.
            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
            player?.pause()
            player = nil
            loadingState = .idle
            playbackState = .notStarted

            setupPlayer()
            representableId += 1
        } else {
            // Player is intact; still refresh the layer and re-evaluate autoplay.
            representableId += 1
            checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
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
        // Force SwiftUI to re-evaluate cached last-frame reads when we update it.
        let _ = lastFrameVersion
        let cachedLastFrame = VideoLastFrameCache.shared.image(for: mid)
        
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
                
                // MediaCell UX: last-frame placeholder to avoid black flicker during reattach/buffering.
                if mode == .mediaCell, let frame = cachedLastFrame {
                    let item = player.currentItem
                    let bufferedAhead = item.map { bufferedTimeAhead(for: $0, player: player) } ?? 0
                    let hasBufferedData = !(item?.loadedTimeRanges.isEmpty ?? true)
                    let readyForFirstFrame = (item?.status == .readyToPlay) && hasBufferedData && bufferedAhead >= firstFrameMinimumBuffer
                    
                    let waitingForData = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    let bufferEmpty = item?.isPlaybackBufferEmpty ?? false
                    let shouldShowPlaceholder =
                        isPlayerDetached ||
                        loadingState.isLoading ||
                        (!readyForFirstFrame && (waitingForData || bufferEmpty || !loadingState.isLoaded))
                    
                    if shouldShowPlaceholder {
                        Image(uiImage: frame)
                            .resizable()
                            .scaledToFill()
                            .clipped()
                            .overlay(Color.black.opacity(0.08))
                        
                        // Spinner over the placeholder while waiting.
                        if loadingState.isLoading || waitingForData || bufferEmpty {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.1)
                                .opacity(0.7)
                        }
                    }
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
            // No player yet - show last frame if available, otherwise black placeholder.
            ZStack {
                if mode == .mediaCell, let frame = cachedLastFrame {
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                        .overlay(Color.black.opacity(0.10))
                } else {
                    Color.black.opacity(0.9)
                }
                
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

    // MARK: - Last Frame Capture (MediaCell)
    @MainActor
    private func ensureVideoOutputAttachedIfNeeded(for player: AVPlayer) {
        guard mode == .mediaCell else { return }
        guard isAnyVideoMedia else { return }
        guard let item = player.currentItem else { return }
        
        // If we're already attached to this exact item, do nothing.
        if videoOutputAttachedItem === item, videoOutput != nil {
            return
        }
        
        // Detach from any previous item to avoid accumulating outputs.
        if let previousItem = videoOutputAttachedItem, let existingOutput = videoOutput {
            previousItem.remove(existingOutput)
        }
        
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        
        item.add(output)
        videoOutput = output
        videoOutputAttachedItem = item
    }
    
    @MainActor
    private func captureLastFrameIfPossible(reason: String) {
        guard mode == .mediaCell else { return }
        guard isAnyVideoMedia else { return }
        guard let player = player, let item = player.currentItem else {
            if reason == "willResignActive" {
                print("🖼️ [LAST FRAME] Skip (no player/item) for \(mid) (\(reason))")
            }
            return
        }
        
        // Ensure we have a video output attached to the current item (may have been nil during earlier setup).
        ensureVideoOutputAttachedIfNeeded(for: player)
        guard let output = videoOutput else {
            if reason == "willResignActive" {
                print("🖼️ [LAST FRAME] Skip (no videoOutput) for \(mid) (\(reason))")
            }
            return
        }
        
        // Only capture if we likely have a meaningful frame.
        guard item.status == .readyToPlay else {
            if reason == "willResignActive" {
                print("🖼️ [LAST FRAME] Skip (item not ready: \(item.status.rawValue)) for \(mid) (\(reason))")
            }
            return
        }
        if item.loadedTimeRanges.isEmpty {
            if reason == "willResignActive" {
                print("🖼️ [LAST FRAME] Skip (no buffered ranges) for \(mid) (\(reason))")
            }
            return
        }
        
        // Throttle: avoid capturing repeatedly during scrolling/rapid state changes.
        let now = Date()
        if now.timeIntervalSince(lastFrameCaptureAt) < 0.75 {
            return
        }
        lastFrameCaptureAt = now
        
        let mid = self.mid
        Task.detached(priority: .utility) {
            // Try to capture the frame corresponding to the current host time.
            let hostTime = CACurrentMediaTime()
            var itemTime = output.itemTime(forHostTime: hostTime)
            
            // If no new pixel buffer is available, fall back to the player's currentTime().
            if !output.hasNewPixelBuffer(forItemTime: itemTime) {
                itemTime = item.currentTime()
            }
            
            var displayTime = CMTime.zero
            guard let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) else {
                if reason == "willResignActive" {
                    print("🖼️ [LAST FRAME] Skip (no pixelBuffer) for \(mid) (\(reason))")
                }
                return
            }
            
            guard let image = VideoFrameExtractor.makeDownscaledUIImage(from: pixelBuffer, maxDimension: 720) else {
                if reason == "willResignActive" {
                    print("🖼️ [LAST FRAME] Skip (image conversion failed) for \(mid) (\(reason))")
                }
                return
            }

            // Guard against black placeholder captures (common during backgrounding/transition frames).
            // If the capture is mostly black, keep the previous cached frame instead of overwriting it.
            if VideoFrameExtractor.isMostlyBlack(image) {
                if reason == "willResignActive" {
                    print("🖼️ [LAST FRAME] Skip (mostly black) for \(mid) (\(reason))")
                }
                return
            }
            
            await MainActor.run {
                VideoLastFrameCache.shared.set(image, for: mid)
                self.lastFrameVersion += 1
                print("🖼️ [LAST FRAME] Captured for \(mid) (\(reason))")
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
        
        // SECOND: Check if we have cached content for this tweet/media.
        // Use parentTweetId for tweet-level caching/mapping; fall back to mid (mediaID).
        let tweetIdForCaching = parentTweetId ?? mid
        let hasCachedContent =
            SharedAssetCache.shared.hasCachedContent(for: tweetIdForCaching) ||
            SharedAssetCache.shared.hasCachedContent(for: mid)
        
        if hasCachedContent {
            NSLog("DEBUG: [VIDEO SETUP] Tweet \(mid) has cached content, loading from cache in mode \(mode)")
            
            // Try async loading from cache
            Task.detached(priority: .userInitiated) {
                NSLog("DEBUG: [VIDEO SETUP] Starting async Task to load player from cache for \(mid) in mode \(mode)")
                do {
                    NSLog("DEBUG: [VIDEO SETUP] Calling getOrCreatePlayer for \(mid)")
                    // Use uniquePlayerURL to ensure each tweet gets its own player instance
                    // Use tweetIdForCaching so SharedAssetCache can map tweetId -> mediaIDs (prevents VideoLoadingManager cancelling active videos)
                    let newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(for: uniquePlayerURL, tweetId: tweetIdForCaching, mediaType: mediaType)
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
                let newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(for: uniquePlayerURL, tweetId: tweetIdForCaching, mediaType: mediaType)
                
                
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
        
        // CRITICAL: Check if video already finished while off-screen BEFORE setting up observers
        // This prevents race conditions where video finishes between observer removal and re-setup
        var videoAlreadyFinished = false
        if let playerItem = cachedState.player.currentItem, mode == .mediaCell {
            let currentTime = cachedState.player.currentTime()
            let duration = playerItem.duration
            if duration.isNumeric && currentTime.isNumeric {
                let currentSeconds = CMTimeGetSeconds(currentTime)
                let durationSeconds = CMTimeGetSeconds(duration)
                // If within 0.5s of end, consider it finished
                if durationSeconds > 0 && currentSeconds >= durationSeconds - 0.5 {
                    NSLog("🎬 [VIDEO CACHE] Video already at end (\(String(format: "%.1f", currentSeconds))s/\(String(format: "%.1f", durationSeconds))s): \(mid)")
                    videoAlreadyFinished = true
                }
            }
        }
        
        // CRITICAL: Always set up observers for cached player
        // This is essential for sequential video playback - without observers, onVideoFinished never fires!
        NSLog("DEBUG: [VIDEO CACHE] Setting up observers for cached player: \(mid)")
        removePlayerObservers()
        setupPlayerObservers(cachedState.player)
        
        // Verify observer was set up successfully
        if mode == .mediaCell && videoCompletionObserver == nil && cachedState.player.currentItem != nil {
            NSLog("⚠️ [VIDEO CACHE] videoCompletionObserver is nil after setupPlayerObservers for \(mid) - retrying")
            setupPlayerObservers(cachedState.player)
        }
        
        // CRITICAL: If video already finished, DON'T trigger callback here
        // The observer is already set up and will fire when the video finishes again
        // OR if we need to advance sequential playback, let VideoManager handle it
        // Directly calling handleVideoFinished here causes duplicate callbacks
        if videoAlreadyFinished {
            NSLog("🎬 [VIDEO CACHE] Video \(mid) was already finished - marking as finished, observer will handle completion")
            self.playbackState = .finished
            // DON'T call handleVideoFinished here - it will be called by the observer if video finishes again
            // Or VideoManager will handle advancing to next video if needed
        }
        
        // Restore the cached player (AFTER setting mute state and observers)
        self.player = cachedState.player
        
        // CRITICAL: Only increment representableId when player actually changed
        // This prevents unnecessary view recreation and recomposition that causes jumping
        // The AVPlayerLayerView.updateUIView will handle layer reattachment for the same player
        // Only force recreation when player object actually changes
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
            // For MediaCell, restore position but DON'T auto-play here
            // Let the normal flow (KVO handlers → checkPlaybackConditions) handle playback
            // This ensures the 2nd round behaves exactly like the 1st round
            
            // CRITICAL: Pause immediately to ensure videos start in the same state as first time
            // The normal KVO flow will handle playback, just like the first time
            if mode == .mediaCell {
                cachedState.player.pause()
            }
            
            // Use seek with tolerance for better reliability
            let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
            cachedState.player.seek(to: cachedState.time, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
                if finished {
                    // Don't auto-play here - let KVO handlers handle it (same as first time)
                    // KVO handlers will fire when ready and check VideoManager via checkPlaybackConditions
                    NSLog("DEBUG: [VIDEO CACHE] Seek completed for \(self.mid), waiting for KVO handlers (same as first time)")
                } else {
                    NSLog("DEBUG: [VIDEO CACHE] ⚠️ Seek did not finish for \(self.mid)")
                }
            }
            
            // Update state
            let isReadyForDisplay = playerItem.status == .readyToPlay || hasBufferedData
            self.loadingState = isReadyForDisplay ? .loaded : .loading
            
            // CRITICAL: Mark as initialized when successfully loaded from cache
            // This prevents recomposition when scrolling back into view
            if isReadyForDisplay && mode == .mediaCell {
                self.hasInitialized = true
            }
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
        
        // MediaCell last-frame support: attach a video output so we can snapshot decoded frames
        // (for flicker-free placeholders during layer reattach / buffering).
        ensureVideoOutputAttachedIfNeeded(for: player)
        
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
        
        // Don't automatically rewind - let player start from its natural position
        // Position will be checked when user tries to play if needed
        
        // CRITICAL: Always set up observers for the new player
        // Clear existing observers first, then set up for this player
        removePlayerObservers()
        setupPlayerObservers(player)
        
        // CRITICAL: Only increment representableId if player actually changed
        // This prevents unnecessary view recreation and recomposition during normal scrolling
        let playerChanged = self.player !== player
        if playerChanged {
            self.representableId += 1 // Force VideoPlayerRepresentable to recreate only when player changes
            self.viewConfigTimestamp = Date().timeIntervalSince1970 // Force unique view ID
        }
        
        // CRITICAL: Always update state, even if same player instance
        // This ensures the view's player binding is set when reusing cached players
        self.player = player
        // DON'T set loadingState = .loaded here! Let the KVO observers handle it based on actual readiness
        // CRITICAL: Don't overwrite .loaded state (tweetDetail sets it before calling this)
        // BUT: If player is already ready with data, set to .loaded immediately to prevent stuck spinner
        if let playerItem = player.currentItem,
           playerItem.status == .readyToPlay,
           !playerItem.loadedTimeRanges.isEmpty {
            self.loadingState = .loaded
            NSLog("✅ [VIDEO CONFIGURE] Player already ready with buffered data, setting loadingState to .loaded for \(mid)")
        } else if !self.loadingState.isLoaded {
            self.loadingState = .loading  // Show spinner while video loads
        }
        self.playbackState = .notStarted
        
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
        
        
        // CRITICAL: Verify observers are set up, retry if needed
        // This handles the case where setupPlayerObservers() returned early due to nil currentItem
        if mode == .mediaCell && videoCompletionObserver == nil && player.currentItem != nil {
            NSLog("⚠️ [VIDEO CONFIGURE] videoCompletionObserver is nil but currentItem exists for \(mid) - retrying observer setup")
            setupPlayerObservers(player)
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
        guard let playerItem = player.currentItem else { 
            NSLog("⚠️ [OBSERVER SETUP] Cannot setup observers for \(mid) - currentItem is nil")
            return 
        }
        
        // MediaCell last-frame support: ensure the video output is attached once a real item exists.
        // (configurePlayer() can run while currentItem is temporarily nil for some HLS paths.)
        ensureVideoOutputAttachedIfNeeded(for: player)
        
        // CRITICAL: Check if observer is already attached to this exact playerItem
        // Use object identity (===) to ensure we're checking the same instance
        let alreadySetup = (self.playerItem === playerItem && videoCompletionObserver != nil)
        
        if alreadySetup {
            NSLog("✅ [OBSERVER SETUP] Observers already attached to this playerItem for \(mid) - skipping")
            return
        }
        
        NSLog("✅ [OBSERVER SETUP] Setting up observers for \(mid), playerItem status: \(playerItem.status.rawValue)")
        
        // CRITICAL: Remove existing observers FIRST to prevent duplicates
        // This must happen before storing the new playerItem reference
        removePlayerObservers()
        
        // Store reference for cleanup (AFTER removing old observers)
        self.playerItem = playerItem
        
        // Video finished observer
        // CRITICAL: Since SimpleVideoPlayer is a struct, we can't use weak self
        // The guard in handleVideoFinished prevents duplicate calls
        // We observe a specific playerItem object, so notifications are scoped correctly
        videoCompletionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            // The notification is already scoped to playerItem, so this will only fire for our item
            // The guard in handleVideoFinished prevents duplicate processing
            self.handleVideoFinished()
        }
        
        NSLog("✅ [OBSERVER SETUP] videoCompletionObserver attached for \(mid)")
        
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
                
                // CRITICAL: Ensure notification observers are set up when player becomes ready
                // This handles the case where currentItem was nil during initial setupPlayerObservers() call
                // which happens when restoring players from VideoStateCache
                if self.videoCompletionObserver == nil {
                    NSLog("⚠️ [KVO STATUS] Player ready but videoCompletionObserver is nil for \(mid) - setting up observers now")
                    DispatchQueue.main.async {
                        if let player = self.player {
                            self.setupPlayerObservers(player)
                        }
                    }
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
                        // CRITICAL: For MediaCell, check VideoManager, actual visibility, and detail view activity before playing
                        // This ensures only the current video plays in sequential playback and not when covered or detail view active
                        let approved = self.mode == .mediaCell ? (self.videoManager?.shouldPlayVideo(for: self.mid) ?? false) : true
                        let actuallyVisible = self.mode != .mediaCell || !self.isCoveredByOverlay
                        let noDetailViewActive = !DetailVideoManager.shared.isDetailViewActive()

                        if approved && actuallyVisible && noDetailViewActive {
                            // CRITICAL: Always ensure muteState is correct before playing in MediaCell
                            if self.mode == .mediaCell {
                                player.isMuted = MuteState.shared.isMuted
                                NSLog("🔇 [PLAYER MUTE] KVO status ready - Applied global mute state for MediaCell: \(MuteState.shared.isMuted) for \(self.mid)")
                            }
                            // Start playing automatically
                            if player.rate == 0 {
                                player.play()
                            }
                            if self.mode == .mediaCell {
                                self.playbackState = .playing
                            }
                            NSLog("▶️ [VIDEO READY] Auto-playing \(mid) (buffered: \(hasBufferedData)) - VideoManager approved")
                        } else if !actuallyVisible {
                            NSLog("⏸️ [VIDEO READY] NOT auto-playing \(mid) - covered by overlay")
                        } else if !noDetailViewActive {
                            NSLog("⏸️ [VIDEO READY] NOT auto-playing \(mid) - detail view active")
                        } else {
                            NSLog("⏸️ [VIDEO READY] NOT auto-playing \(mid) - not approved by VideoManager")
                        }
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
                        
                        // CRITICAL: Only play() if video should actually be playing
                        // For sequential playback, check with VideoManager first
                        // This prevents videos from playing to completion prematurely (especially short videos)
                        // CRITICAL: Default to false for MediaCell to prevent both videos from playing
                        // Also check if video is actually visible (not covered by overlay)
                        let managerApproved = self.mode != .mediaCell || self.videoManager?.shouldPlayVideo(for: self.mid) ?? false
                        let actuallyVisible = self.mode != .mediaCell || !self.isCoveredByOverlay
                        let noDetailViewActive = self.mode != .mediaCell || !DetailVideoManager.shared.isDetailViewActive()
                        let shouldPlay = shouldAutoPlay && managerApproved && actuallyVisible && noDetailViewActive
                        
                        if shouldPlay && player.rate == 0 {
                            // CRITICAL: Always ensure muteState is correct before playing in MediaCell
                            if self.mode == .mediaCell {
                                player.isMuted = MuteState.shared.isMuted
                                NSLog("🔇 [PLAYER MUTE] First frame render - Applied global mute state for MediaCell: \(MuteState.shared.isMuted) for \(self.mid)")
                            }
                            player.play()
                            if self.mode == .mediaCell {
                                self.playbackState = .playing
                            }
                            NSLog("▶️ [FIRST FRAME] Auto-playing \(mid) (approved by VideoManager)")
                        } else if !actuallyVisible {
                            NSLog("⏸️ [FIRST FRAME] NOT auto-playing \(mid) - covered by overlay")
                        } else if !noDetailViewActive {
                            NSLog("⏸️ [FIRST FRAME] NOT auto-playing \(mid) - detail view active")
                        } else if !shouldPlay {
                            NSLog("⏸️ [FIRST FRAME] NOT auto-playing \(mid) - waiting for approval from VideoManager")
                            // First frame will render when player is ready, no need to play()
                        }
                        
                        loadingState = .loaded
                        retryAttempts = 0  // Reset retry counter on successful load
                        
                        // Mark as initialized to prevent recomposition when scrolling
                        if mode == .mediaCell {
                            hasInitialized = true
                        }

                        // CRITICAL: If video was waiting to play, check playback conditions now
                        // This handles case where video became approved but was still loading
                        if self.currentAutoPlay && self.isVisible && self.mode == .mediaCell {
                            DispatchQueue.main.async {
                                self.checkPlaybackConditions(autoPlay: self.currentAutoPlay, isVisible: self.isVisible)
                            }
                        }
                        
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
                let bufferedDuration = self.bufferedTimeAhead(for: playerItem, player: player)
                NSLog("✅ [INITIAL CHECK] Already ready for \(mid) - buffered: \(hasBufferedData), duration: \(String(format: "%.2f", bufferedDuration))s")
                
                // Hide spinner if we have buffered data
                // CRITICAL FIX: Check bufferedDuration >= firstFrameMinimumBuffer to ensure enough data
                if hasBufferedData && bufferedDuration >= firstFrameMinimumBuffer {
                    loadingState = .loaded
                    retryAttempts = 0  // Reset retry counter on successful load
                    // Mark as initialized to prevent recomposition when scrolling
                    if mode == .mediaCell {
                        hasInitialized = true
                    }
                    NSLog("🎬 [INITIAL CHECK] Hiding spinner immediately for \(mid)")
                } else if hasBufferedData && bufferedDuration < firstFrameMinimumBuffer {
                    NSLog("⏳ [INITIAL CHECK] Ready but waiting for more buffer data for \(mid) (only \(String(format: "%.2f", bufferedDuration))s buffered)")
                } else {
                    NSLog("⏳ [INITIAL CHECK] Ready but waiting for buffer data for \(mid)")
                }
                
                if shouldAutoPlay {
                    // CRITICAL: For MediaCell, check VideoManager before playing (same as first time)
                    // This ensures only the current video plays in sequential playback
                    let approved = self.mode == .mediaCell ? (self.videoManager?.shouldPlayVideo(for: self.mid) ?? false) : true
                    
                    if approved {
                        // CRITICAL: Always ensure muteState is correct before playing in MediaCell
                        if self.mode == .mediaCell {
                            player.isMuted = MuteState.shared.isMuted
                            NSLog("🔇 [PLAYER MUTE] Initial check ready - Applied global mute state for MediaCell: \(MuteState.shared.isMuted) for \(self.mid)")
                        }
                        player.play()
                        NSLog("▶️ [VIDEO SETUP] Already ready - auto-playing \(mid) (buffered: \(hasBufferedData)) - VideoManager approved")
                    } else {
                        NSLog("⏸️ [VIDEO SETUP] NOT auto-playing \(mid) - not approved by VideoManager")
                    }
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
        // CRITICAL: Prevent duplicate calls - if already finished, ignore
        // This can happen if the notification fires multiple times or if the video finishes again
        guard playbackState != .finished else {
            print("⚠️ [VIDEO FINISHED] Video \(mid) already marked as finished - ignoring duplicate finish event")
            return
        }
        
        print("🎬 [VIDEO FINISHED] Video finished playing for \(mid), mode: \(mode)")
        print("🎬 [VIDEO FINISHED] onVideoFinished callback: \(onVideoFinished != nil ? "SET" : "NIL")")
        resetProgressiveBufferTarget(for: player?.currentItem)
        
        // CRITICAL: Immediately pause to prevent flicker when next video starts
        // This ensures smooth transition between videos
        player?.pause()
        playbackState = .finished
        
        // For MediaCell mode, ensure mute state is correct and prevent any view updates
        if mode == .mediaCell {
            player?.isMuted = MuteState.shared.isMuted
            // CRITICAL: Don't trigger any view updates for finished videos
            // The video layer should remain static showing the last frame
            // Any representableId changes would cause flicker
        }
        
        // CRITICAL: For MediaCell sequential playback, call callback to advance to next video
        // Use a small delay to ensure the pause and state update complete first
        // This prevents the finished video from causing view updates during transition
        if let callback = onVideoFinished {
            print("🎬 [VIDEO FINISHED] Calling onVideoFinished callback for \(mid)")
            // Small delay to ensure pause completes and prevent flicker
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                callback()
            }
        } else {
            print("⚠️ [VIDEO FINISHED] No onVideoFinished callback set for \(mid)")
        }
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
    
    /// Periodic health check to detect and fix stuck loading states while app is in foreground
    /// This catches edge cases where KVO observers don't fire properly with cached players
    @MainActor
    private func performPeriodicHealthCheck() async {
        // Only run health check when in loading state
        guard loadingState.isLoading else { return }
        
        // Wait 3 seconds before checking - gives KVO observers time to fire normally
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        
        // Re-check loading state after sleep (might have changed)
        guard loadingState.isLoading else { return }
        
        // Check if player is actually ready with buffered data
        guard let player = player,
              let playerItem = player.currentItem,
              playerItem.status == .readyToPlay,
              !playerItem.loadedTimeRanges.isEmpty else {
            // Player not ready yet or no buffered data - this is expected, keep waiting
            return
        }
        
        // Calculate buffered duration
        let bufferedDuration = bufferedTimeAhead(for: playerItem, player: player)
        
        // If we have enough buffered data, fix the stuck loading state
        if bufferedDuration >= firstFrameMinimumBuffer {
            NSLog("⚠️ [HEALTH CHECK] LoadingState stuck at .loading but player is ready with \(String(format: "%.2f", bufferedDuration))s buffered - fixing for \(mid)")
            loadingState = .loaded
            retryAttempts = 0
            if mode == .mediaCell {
                hasInitialized = true
            }
            
            // Check if video should be playing
            if currentAutoPlay && isVisible {
                let approved = mode == .mediaCell ? (videoManager?.shouldPlayVideo(for: mid) ?? false) : true
                if approved && player.rate == 0 {
                    if mode == .mediaCell {
                        player.isMuted = MuteState.shared.isMuted
                    }
                    player.play()
                    playbackState = .playing
                    NSLog("▶️ [HEALTH CHECK] Started playback after fixing stuck state for \(mid)")
                }
            }
        } else {
            NSLog("⏳ [HEALTH CHECK] Player ready but still buffering (\(String(format: "%.2f", bufferedDuration))s < \(String(format: "%.2f", firstFrameMinimumBuffer))s required) for \(mid)")
        }
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
        // Validate player state before attempting playback.
        // IMPORTANT: After long background, AppDelegate may clear players asynchronously which can leave
        // `player` non-nil but `currentItem == nil` / invalid time. Treat that as broken and recreate.
        if let player = player {
            guard let playerItem = player.currentItem else {
                if !loadingState.isLoading {
                    NSLog("⚠️ [VIDEO VALIDATION] Player has no currentItem for \(mid) - recreating")
                    SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
                    self.player = nil
                    loadingState = .idle
                    playbackState = .notStarted
                    setupPlayer()
                }
                return
            }

            let currentSeconds = player.currentTime().seconds
            if !currentSeconds.isFinite {
                if !loadingState.isLoading {
                    NSLog("⚠️ [VIDEO VALIDATION] Player currentTime is invalid (\(currentSeconds)) for \(mid) - recreating")
                    SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey)
                    self.player = nil
                    loadingState = .idle
                    playbackState = .notStarted
                    setupPlayer()
                }
                return
            }

            if playerItem.status == .failed {
                NSLog("DEBUG: [VIDEO VALIDATION] Player item is in failed state for \(mid), triggering recovery")
                handleError(strategy: .loadFailure)
                return
            }
        }
        
        // Check if all conditions are met for autoplay
        // For fullscreen and detail modes, bypass shouldLoadVideo check
        let shouldCheckLoading = mode == .mediaCell ? shouldLoadVideo : true
        
        // CRITICAL: For MediaCell, also check if video is actually visible (not covered by sheets/modals or detail views)
        // Use synchronous visibility check (presentedViewController) to avoid timer lag.
        let isActuallyVisibleOrFullscreen = mode != .mediaCell || !isCoveredByOverlay
        let noDetailViewActive = mode != .mediaCell || !DetailVideoManager.shared.isDetailViewActive()
        
        if autoPlay && isVisible && isActuallyVisibleOrFullscreen && noDetailViewActive && player != nil && !loadingState.isLoading && shouldCheckLoading {
            
            // CRITICAL: For sequential playback, check with VideoManager before playing
            // This prevents videos that finished prematurely from restarting
            if mode == .mediaCell {
                // Check if this video is approved by VideoManager for sequential playback
                let approved = videoManager?.shouldPlayVideo(for: mid) ?? true
                if !approved {
                    print("DEBUG: [VIDEO PLAYBACK] Video \(mid) not approved by VideoManager - preventing playback")
                    return
                }
                
                // CRITICAL: If video was finished but is now approved to play (next in sequence),
                // reset it to allow playback - this handles sequential video transitions
                if playbackState == .finished {
                    print("🔄 [VIDEO PLAYBACK] Video \(mid) was finished but is now next in sequence - resetting for playback")
                    playbackState = .notStarted
                    // Seek to start to ensure clean state
                    player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
            
            // Activate audio session for video playback
            AudioSessionManager.shared.activateForVideoPlayback()
            
            // CRITICAL: Always ensure muteState is correct before playing
            // For MediaCell, always respect global mute state
            if mode == .mediaCell, let player = player {
                player.isMuted = MuteState.shared.isMuted
                NSLog("🔇 [PLAYER MUTE] checkPlaybackConditions - Applied global mute state for MediaCell: \(MuteState.shared.isMuted) for \(mid)")
            }
            
            // CRITICAL: For mediaCell mode, if video was never actually played (only first frame shown),
            // seek to start to ensure clean state before playing
            // Also handle case where video was reset from finished state for sequential playback
            if mode == .mediaCell && playbackState == .notStarted {
                NSLog("🔄 [PLAYBACK] Seeking to start for clean playback: \(mid)")
                player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                // Brief delay to let seek complete, then start playing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    // Double-check conditions haven't changed
                    if self.player?.rate == 0 && self.isVisible && self.videoManager?.shouldPlayVideo(for: self.mid) == true {
                        NSLog("▶️ [PLAYBACK] Starting playback after seek: \(self.mid)")
                        self.player?.play()
                        self.playbackState = .playing
                    }
                }
                return
            }
            
            // CRITICAL: Check actual player position before playing
            let currentTime = player!.currentTime().seconds
            let duration = player!.currentItem?.duration.seconds ?? 0
            let atEnd = isVideoAtEnd(player!)
            NSLog("🔍 [PLAYBACK CHECK] Video \(mid): playbackState=\(playbackState), time=\(String(format: "%.2f", currentTime))s/\(String(format: "%.2f", duration))s, atEnd=\(atEnd)")
            
            // If video is at or near the end, rewind it FIRST
            if atEnd || currentTime > duration - 0.5 {
                NSLog("🔄 [PLAYBACK REWIND] Video at end, rewinding to start before playing: \(mid)")
                player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                playbackState = .notStarted
                // Small delay to ensure seek completes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if self.mode == .mediaBrowser {
                        self.playbackState = .playing
                    } else {
                        self.player?.play()
                        self.playbackState = .playing
                        NSLog("▶️ [PLAYBACK] Playing after rewind: \(self.mid)")
                    }
                }
            } else if playbackState.hasFinished {
                player?.seek(to: .zero) { finished in
                    if finished {
                        self.playbackState = .notStarted
                        // Play after rewinding
                        if self.mode == .mediaBrowser {
                            self.playbackState = .playing
                        } else {
                            self.player?.play()
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
            // autoPlay is false
            // For MediaCell mode: Videos should pause when off-screen (handled by visibility changes)
            // This preserves resources while maintaining playback state for correct resume
            // The sequential playback state is preserved in VideoManager, so when user scrolls back,
            // the correct video will resume from where it was paused
            if mode == .mediaCell {
                // Don't reset finished videos here - they may have legitimately played to completion
                // The AVPlayer instance might be shared between multiple SimpleVideoPlayer views
                // Resetting one video could corrupt the state of another video using the same player
                // Let each video manage its own state when it becomes active
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
                var hasLoggedPlayingStart = false // Track if we've already logged "Video started playing"
                
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
                    
                    // Reset logging flag for new player
                    context.coordinator.hasLoggedPlayingStart = false
                    
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
                                // Only log once per playback session
                                if !context.coordinator.hasLoggedPlayingStart {
                                    context.coordinator.hasLoggedPlayingStart = true
                                    NSLog("✅ [AVPlayerViewController] Video started playing")
                                }
                            } else {
                                // Paused - cancel pending show task and hide spinner
                                context.coordinator.bufferingDebounceTask?.cancel()
                                context.coordinator.isBuffering = false
                                // Reset flag when paused so we can log again on next play
                                context.coordinator.hasLoggedPlayingStart = false
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
                
                // Check if player instance changed before detaching
                let playerChanged = uiViewController.player !== player
                
                // Detach and reattach to force fresh layer connection
                uiViewController.player = nil
                uiViewController.player = player
                
                // Reset logging flag if player changed
                if playerChanged {
                    context.coordinator.hasLoggedPlayingStart = false
                }
                
                // Update timeControlStatus observer only if player changed
                if let player = player, playerChanged {
                    context.coordinator.timeControlObserver?.invalidate()
                    context.coordinator.timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { observedPlayer, _ in
                        DispatchQueue.main.async {
                            let isWaitingToPlay = observedPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
                            
                            if isWaitingToPlay {
                                context.coordinator.isBuffering = true
                            } else if observedPlayer.timeControlStatus == .playing {
                                context.coordinator.isBuffering = false
                                // Only log once per playback session
                                if !context.coordinator.hasLoggedPlayingStart {
                                    context.coordinator.hasLoggedPlayingStart = true
                                    NSLog("✅ [AVPlayerViewController] Video started playing in updateUIViewController")
                                }
                            } else {
                                context.coordinator.isBuffering = false
                                // Reset flag when paused so we can log again on next play
                                context.coordinator.hasLoggedPlayingStart = false
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
        
        let currentPlayer = playerView.playerLayer.player
        
        // Only update if player actually changed to prevent unnecessary layer operations
        // This reduces recomposition and jumping when scrolling
        if currentPlayer !== player {
            // Different player - detach old, attach new
            playerView.playerLayer.player = nil
            playerView.playerLayer.player = player
        } else if currentPlayer == nil {
            // No current player but we have one - attach it
            playerView.playerLayer.player = player
        }
        // If same player, don't do anything - layer is already connected
        // This prevents unnecessary operations that cause recomposition
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
    @State private var lastShouldAutoPlay: Bool? = nil
    @State private var lastVideoMids: [String] = []
    
    func body(content: Content) -> some View {
        if let videoManager = videoManager {
            content
                .onReceive(videoManager.$currentVideoIndex) { _ in
                    // When currentVideoIndex changes, re-evaluate autoPlay state
                    // Only trigger if the result actually changed to prevent unnecessary recomposition
                    if mode == .mediaCell {
                        let shouldAutoPlay = videoManager.shouldPlayVideo(for: mid)
                        // Only call callback if the value actually changed
                        if lastShouldAutoPlay != shouldAutoPlay {
                            lastShouldAutoPlay = shouldAutoPlay
                            onVideoIndexChanged(shouldAutoPlay)
                        }
                    }
                }
                .onReceive(videoManager.$videoMids) { newVideoMids in
                    // Also listen to videoMids changes (when sequence changes)
                    // Only trigger if sequence actually changed to prevent unnecessary recomposition
                    if mode == .mediaCell && newVideoMids != lastVideoMids {
                        lastVideoMids = newVideoMids
                        let shouldAutoPlay = videoManager.shouldPlayVideo(for: mid)
                        // Only update if value changed
                        if lastShouldAutoPlay != shouldAutoPlay {
                            lastShouldAutoPlay = shouldAutoPlay
                            onVideoIndexChanged(shouldAutoPlay)
                        }
                    }
                }
        } else {
            content
        }
    }
}

