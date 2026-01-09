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
    case embeddedDetail // In TweetDetailView, embedded/quoted tweet preview
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
    private let maxCacheSize = 15 // Maximum number of cached states (reduced for better performance)
    
    // CRITICAL: Track visible videos to prevent them from being evicted
    private var visibleVideoMids: Set<String> = []
    
    private init() {}
    
    /// Mark a video as visible (prevents eviction)
    func markAsVisible(_ mid: String) {
        visibleVideoMids.insert(mid)
    }
    
    /// Mark a video as not visible (allows eviction)
    func markAsNotVisible(_ mid: String) {
        visibleVideoMids.remove(mid)
    }
    
    /// Clear cached state for a video (e.g., when video finishes)
    func clearCachedState(for mid: String) {
        cache.removeValue(forKey: mid)
        visibleVideoMids.remove(mid)
    }
    
    func cacheVideoState(for mid: String, player: AVPlayer, time: CMTime, wasPlaying: Bool, originalMuteState: Bool) {
        cache[mid] = (player: player, time: time, wasPlaying: wasPlaying, originalMuteState: originalMuteState, timestamp: Date())
        
        // Manage cache size with LRU eviction
        if cache.count > maxCacheSize {
            // Sort by timestamp (oldest first) and remove oldest entries
            // CRITICAL: Never evict visible videos
            let sortedKeys = cache
                .filter { !visibleVideoMids.contains($0.key) } // Skip visible videos
                .sorted { $0.value.timestamp < $1.value.timestamp }
                .map { $0.key }
            let keysToRemove = sortedKeys.prefix(cache.count - maxCacheSize)
            
            for key in keysToRemove {
                if let oldPlayer = cache[key]?.player {
                    oldPlayer.pause()
                }
                cache.removeValue(forKey: key)
            }
        }
    }
    
    func getCachedState(for mid: String) -> (player: AVPlayer, time: CMTime, wasPlaying: Bool, originalMuteState: Bool)? {
        guard let cachedState = cache[mid] else {
            return nil
        }
        
        // Check if cache is stale
        let age = Date().timeIntervalSince(cachedState.timestamp)
        if age > cacheExpirationInterval {
            cache.removeValue(forKey: mid)
            return nil
        }
        
        // Validate player is still valid.
        //
        // IMPORTANT: AppDelegate background recovery may clear `currentItem` to force recreation.
        // In that case, we MUST keep the cached playback time so we can resume after recreating the player.
        if cachedState.player.currentItem == nil || cachedState.player.currentItem?.status == .failed {
            return nil
        }
        
        return (player: cachedState.player, time: cachedState.time, wasPlaying: cachedState.wasPlaying, originalMuteState: cachedState.originalMuteState)
    }

    /// Returns cached playback info even if the cached player is no longer valid.
    ///
    /// This is important for background recovery: AppDelegate may clear/replace player items
    /// (making cachedState.player.currentItem nil) but we still want to resume from the last known time.
    func getCachedPlaybackInfo(for mid: String) -> (time: CMTime, wasPlaying: Bool)? {
        guard let cachedState = cache[mid] else { return nil }

        // Expire old entries; this is still safe to clear.
        let age = Date().timeIntervalSince(cachedState.timestamp)
        if age > cacheExpirationInterval {
            cache.removeValue(forKey: mid)
            return nil
        }

        return (time: cachedState.time, wasPlaying: cachedState.wasPlaying)
    }

    func hasCachedPlaybackInfo(for mid: String) -> Bool {
        return getCachedPlaybackInfo(for: mid) != nil
    }
    
    /// Check if video finished playing in mediaCell by comparing cached time with duration
    func hasVideoFinishedInMediaCell(for mid: String, duration: CMTime) -> Bool {
        guard let cachedInfo = getCachedPlaybackInfo(for: mid) else {
            return false
        }
        
        guard duration.isValid && duration.seconds > 0 else {
            return false
        }
        
        let cachedTimeSeconds = cachedInfo.time.seconds
        let durationSeconds = duration.seconds
        
        // Consider finished if within 0.5 seconds of end
        return cachedTimeSeconds >= durationSeconds - 0.5
    }
    
    func clearCache(for mid: String, force: Bool = false) {
        // CRITICAL: Never clear cache for visible videos (unless forced)
        if !force && visibleVideoMids.contains(mid) {
            print("⚠️ [VIDEO CACHE] Refusing to clear cache for visible video \(mid)")
            return
        }
        cache.removeValue(forKey: mid)
    }
    
    func clearAllCache() {
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
        // Validate pixel buffer dimensions first before creating CIImage
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        guard width > 0, height > 0, width < 10000, height < 10000 else {
            // Silently return nil for invalid dimensions - this can happen with some video formats
            return nil
        }
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent

        // Validate extent dimensions are finite, positive, and reasonable
        // Use pixel buffer dimensions as fallback if extent is invalid
        let validExtent: CGRect
        if extent.width.isFinite && extent.height.isFinite &&
           extent.width > 0 && extent.height > 0 &&
           extent.width < 10000 && extent.height < 10000 {
            validExtent = extent
        } else {
            // Use pixel buffer dimensions if extent is invalid
            validExtent = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        }

        guard let cgImage = ciContext.createCGImage(ciImage, from: validExtent) else {
            // Silently return nil - this can happen with some video formats during loading
            return nil
        }
        let image = UIImage(cgImage: cgImage)
        return downscale(image, maxDimension: maxDimension)
    }
    
    /// Downscale without changing aspect ratio.
    static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size

        // Validate image dimensions are finite, positive, and reasonable
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width < 10000, size.height < 10000 else {
            return image
        }

        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension, maxSide > 0 else { return image }

        let scale = maxDimension / maxSide

        // Ensure scale is valid
        guard scale.isFinite, scale > 0, scale <= 1 else {
            return image
        }

        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        // Ensure target size is also finite, positive, and reasonable
        guard targetSize.width.isFinite, targetSize.height.isFinite,
              targetSize.width > 0, targetSize.height > 0,
              targetSize.width < 10000, targetSize.height < 10000 else {
            return image
        }

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
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else { return false }
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
    private static let cachedScreenWidth: CGFloat = UIScreen.main.bounds.width
    
    // MARK: Required Parameters
    let url: URL
    let mid: String
    let parentTweetId: String? // Optional parent tweet ID for unique identification
    let isVisible: Bool
    let mediaType: MediaType // Add MediaType parameter
    let authorId: String? // Author ID for health check during retry
    
    // MARK: Optional Parameters
    var autoPlay: Bool = true
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
    @State private var coordinatorWantsToPlay: Bool = false // Track if coordinator commanded playback
    @State private var isPlayerDetached = false  // Track background state
    @State private var hasRecoveredThisCycle = false  // Prevent double recovery (background + screen lock)
    @State private var didEnterBackground = false  // Track if we actually went to background (vs just screen lock)
    @State private var needsHealthCheckAfterForeground = false  // Only check health once after foreground entry
    @State private var isSeekingToBeginning = false  // Track if we're seeking to beginning (don't check health during seek)
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
    @State private var isHoldingRecoveryCover: Bool = false
    @State private var recoveryCoverTask: Task<Void, Never>? = nil
    @State private var recoveryTimeoutTask: Task<Void, Never>? = nil // 15s timeout for MediaCell recovery
    // (removed) finished-video last-frame cover behavior; last-frame is for background recovery only
    @State private var isHandlingFinishEvent: Bool = false
    
    // TweetDetail: prevent "play from 0 then jump back" by restoring seek before playback.
    @State private var hasAppliedDetailRestore: Bool = false
    @State private var isApplyingDetailRestore: Bool = false
    
    // Timer display state (MediaCell only) - exposed for parent overlay
    @State var showTimeRemaining: Bool = false
    @State private var timeRemainingDisplayTask: Task<Void, Never>?
    var timeRemainingText: String {
        guard let duration = player?.currentItem?.duration.seconds,
              duration.isFinite,
              let currentTime = player?.currentTime().seconds else {
            return "0:00"
        }
        let remaining = max(0, duration - currentTime)
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Helper Functions
    
    /// Apply mute state to player based on current mode
    private func applyMuteState(to player: AVPlayer) {
        if mode == .mediaCell || mode == .embeddedDetail {
            player.isMuted = MuteState.shared.isMuted
        } else {
            // Fullscreen/Detail: Always unmute
            player.isMuted = false
        }
    }
    
    // MARK: - Time Remaining Display (MediaCell)
    
    /// Start the timer display cycle: show all the time (for debugging)
    @MainActor
    private func startTimeRemainingDisplayCycle() {
        guard mode == .mediaCell else { return }
        
        
        // Cancel any existing task
        stopTimeRemainingDisplayCycle()
        
        // Show timer all the time (for debugging)
        showTimeRemaining = true
    }
    
    /// Stop the timer display cycle
    @MainActor
    private func stopTimeRemainingDisplayCycle() {
        timeRemainingDisplayTask?.cancel()
        timeRemainingDisplayTask = nil
        showTimeRemaining = false
    }
    
    // MARK: - Resume helpers (MediaCell)
    /// Start playback, resuming from cached time when appropriate.
    ///
    /// For short background: AppDelegate clears players, we recreate them; to avoid restarting from 0
    /// we seek to the cached time *if the video was playing* before background.
    @MainActor
    private func playWithResumeIfNeeded(_ player: AVPlayer) {
        if mode != .mediaCell {
            player.volume = 0
            player.play()
            UIView.animate(withDuration: 0.3) {
                player.volume = 1.0
            }
            return
        }

        // If we have a cached playback time (e.g. short background where player was cleared),
        // resume from it when auto-playing. Don't rely on `wasPlaying` here because AVPlayer.rate
        // can be 0 during buffering/background transitions even if the user considers it "playing".
        guard let info = VideoStateCache.shared.getCachedPlaybackInfo(for: mid) else {
            player.volume = 0
            player.play()
            UIView.animate(withDuration: 0.3) {
                player.volume = 1.0
            }
            scheduleRecoveryCoverRelease(reason: "playNoCache")
            startPlaybackWatchdogIfNeeded(player: player, reason: "playNoCache")
            return
        }

        let targetSeconds = info.time.seconds
        guard targetSeconds.isFinite, targetSeconds > 0.25 else {
            player.volume = 0
            player.play()
            UIView.animate(withDuration: 0.3) {
                player.volume = 1.0
            }
            scheduleRecoveryCoverRelease(reason: "playNoResumeTime")
            startPlaybackWatchdogIfNeeded(player: player, reason: "playNoResumeTime")
            return
        }

        let currentSeconds = player.currentTime().seconds
        if currentSeconds.isFinite, abs(currentSeconds - targetSeconds) <= 0.25 {
            player.volume = 0
            player.play()
            UIView.animate(withDuration: 0.3) {
                player.volume = 1.0
            }
            scheduleRecoveryCoverRelease(reason: "playAlreadyAtResumeTime")
            startPlaybackWatchdogIfNeeded(player: player, reason: "playAlreadyAtResumeTime")
            return
        }

        // Seeking to cached time before play
        player.seek(to: info.time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            guard finished else {
                player.volume = 0
                player.play()
                UIView.animate(withDuration: 0.3) {
                    player.volume = 1.0
                }
                Task { @MainActor in
                    self.scheduleRecoveryCoverRelease(reason: "playAfterSeekNotFinished")
                    self.startPlaybackWatchdogIfNeeded(player: player, reason: "playAfterSeekNotFinished")
                }
                return
            }
            player.volume = 0
            player.play()
            UIView.animate(withDuration: 0.3) {
                player.volume = 1.0
            }
            Task { @MainActor in
                self.scheduleRecoveryCoverRelease(reason: "playAfterSeekFinished")
                self.startPlaybackWatchdogIfNeeded(player: player, reason: "playAfterSeekFinished")
            }
        }
    }
    
    // MARK: - Resume helpers (TweetDetail)
    /// Returns true if we started an async seek that must complete before playback.
    @MainActor
    private func startTweetDetailRestoreIfNeeded(for player: AVPlayer) -> Bool {
        guard mode == .tweetDetail else { return false }
        if isApplyingDetailRestore { return true }
        if hasAppliedDetailRestore { return false }
        
        // Check if video finished in mediaCell - if so, restart from beginning
        // Check VideoStateCache first (even if player item not ready yet)
        if VideoStateCache.shared.hasCachedPlaybackInfo(for: mid) {
            // If player item is ready, check duration
            if let playerItem = player.currentItem,
               playerItem.status == .readyToPlay {
                let duration = playerItem.duration
                if duration.isValid && duration.seconds > 0 {
                    if VideoStateCache.shared.hasVideoFinishedInMediaCell(for: mid, duration: duration) {
                        // Video finished in mediaCell - restarting from beginning
                        isApplyingDetailRestore = true
                        player.pause()
                        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                            Task { @MainActor in
                                self.isApplyingDetailRestore = false
                                self.hasAppliedDetailRestore = true
                                
                                if finished {
                                    // Start playback from beginning
                                    if self.currentAutoPlay {
                                        self.checkPlaybackConditions(autoPlay: true, isVisible: self.isVisible)
                                    }
                                } else {
                                    self.checkPlaybackConditions(autoPlay: self.currentAutoPlay, isVisible: self.isVisible)
                                }
                            }
                        }
                        return true
                    }
                }
            }
        }
        
        guard PersistentVideoStateManager.shared.shouldRestorePlayback(videoMid: mid, context: .detailView),
              let saved = PersistentVideoStateManager.shared.getState(videoMid: mid, context: .detailView) else {
            hasAppliedDetailRestore = true
            return false
        }
        
        let savedSeconds = saved.currentTime.seconds
        guard savedSeconds.isFinite, savedSeconds > 0.25 else {
            hasAppliedDetailRestore = true
            return false
        }
        
        // Check if saved position is near the end (video finished in previous detail view session)
        // If player item is ready, check duration; otherwise wait for it to become ready
        if let playerItem = player.currentItem,
           playerItem.status == .readyToPlay {
            let duration = playerItem.duration
            if duration.isValid && duration.seconds > 0 {
                // If saved position is within 0.5s of end, restart from beginning
                if savedSeconds >= duration.seconds - 0.5 {
                    // Video saved position is near end - restarting from beginning
                    isApplyingDetailRestore = true
                    player.pause()
                    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                        Task { @MainActor in
                            self.isApplyingDetailRestore = false
                            self.hasAppliedDetailRestore = true
                            
                            if finished {
                                // Start playback from beginning
                                if self.currentAutoPlay {
                                    self.checkPlaybackConditions(autoPlay: true, isVisible: self.isVisible)
                                }
                            } else {
                                self.checkPlaybackConditions(autoPlay: self.currentAutoPlay, isVisible: self.isVisible)
                            }
                        }
                    }
                    return true
                }
            }
        }
        
        let currentSeconds = player.currentTime().seconds
        let needsSeek = !currentSeconds.isFinite || abs(currentSeconds - savedSeconds) > 0.25
        guard needsSeek else {
            hasAppliedDetailRestore = true
            return false
        }
        
        isApplyingDetailRestore = true
        player.pause()
        // Seeking to saved position
        
        player.seek(to: saved.currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in
                self.isApplyingDetailRestore = false
                self.hasAppliedDetailRestore = true
                
                // If seek fails, fall back to normal autoplay logic.
                guard finished else {
                    self.checkPlaybackConditions(autoPlay: self.currentAutoPlay, isVisible: self.isVisible)
                    return
                }
                
                // Start playback from restored position if requested.
                let shouldPlay = self.currentAutoPlay || saved.wasPlaying
                if shouldPlay {
                    self.checkPlaybackConditions(autoPlay: true, isVisible: self.isVisible)
                }
            }
        }
        
        return true
    }

    /// Lightweight watchdog: only for stuck autoplay in MediaCell
    /// Runs on background thread to avoid blocking UI
    @MainActor
    private func startPlaybackWatchdogIfNeeded(player: AVPlayer, reason: String) {
        // DISABLED: Watchdog causes scroll performance degradation even with background threads
        // Relying on existing error handling mechanisms:
        // 1. KVO observers detect failed/stalled items
        // 2. onAppear/onDisappear lifecycle handles state transitions
        // 3. Conservative recreatePlayer() for actually broken players
        // 4. VideoPlaybackCoordinator handles playback approval via notifications
        return
    }
    
    /// Recreate player (called from background thread, hops to main)
    @MainActor
    private func recreatePlayer(reason: String, mid: String) {
        guard self.mid == mid else { return } // Ensure still same video
        
        // Recreating player due to error
        
        captureLastFrameIfPossible(reason: "watchdog_\(reason)")
        
        SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey, force: true)
        VideoStateCache.shared.clearCache(for: mid, force: true)
        
        player?.pause()
        player = nil
        loadingState = .idle
        playbackState = .notStarted
        
        if mode == .tweetDetail {
            DetailVideoManager.shared.clearCurrentVideo()
        } else if mode == .mediaBrowser {
            FullScreenVideoManager.shared.clearSingletonPlayer()
        }
        
        setupPlayer()
    }

    /// Foreground recovery UX: keep last-frame cover until we confirm frames are rendering.
    /// This prevents a "blink" (black frame) while AVPlayerLayer / AVPlayerItem rewires.
    @MainActor
    private func scheduleRecoveryCoverRelease(reason: String) {
        guard mode == .mediaCell else { return }
        guard isHoldingRecoveryCover else { return }
        guard isVisible, isActuallyVisible else { return }

        recoveryCoverTask?.cancel()

        let baselinePlayer = self.player
        let baselineSeconds = baselinePlayer?.currentTime().seconds ?? 0
        
        // Starting recovery polling

        recoveryCoverTask = Task { @MainActor in
            var didRefreshLayer = false

            // Poll for a short period; we release the cover only after we see fresh frames/time progress.
            for i in 0..<35 { // ~3.5s
                guard !Task.isCancelled else { 
                    return 
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s

                guard self.mode == .mediaCell, self.isVisible, self.isActuallyVisible else { 
                    return 
                }
                guard self.isHoldingRecoveryCover else { return }
                guard !self.isPlayerDetached else { continue }

                guard let player = self.player else { 
                    continue 
                }
                if let bp = baselinePlayer, player !== bp { return } // player swapped; new flow will handle
                guard let item = player.currentItem else { 
                    continue 
                }

                // Preferred signal: AVPlayerItemVideoOutput says a new frame is available.
                var hasNewFrame = false
                if let output = self.videoOutput {
                    let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
                    hasNewFrame = output.hasNewPixelBuffer(forItemTime: itemTime)
                }

                // Fallback: time advances (even if output is temporarily missing).
                let nowSeconds = player.currentTime().seconds
                let advanced = baselineSeconds.isFinite && nowSeconds.isFinite && nowSeconds > baselineSeconds + 0.15
                let playing = player.timeControlStatus == .playing || player.rate > 0
                
                if hasNewFrame || (playing && advanced) {
                    // Recovery complete
                    withAnimation(.easeOut(duration: 0.15)) {
                        self.isHoldingRecoveryCover = false
                    }
                    return
                }

                // After ~2.0s, do a single layer refresh behind the cover if we're still waiting.
                if !didRefreshLayer, i == 20 {
                    let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    let bufferEmpty = item.isPlaybackBufferEmpty
                    let noRanges = item.loadedTimeRanges.isEmpty
                    // Refreshing layer for recovery
                    if waiting || bufferEmpty || noRanges {
                        didRefreshLayer = true
                        self.representableId += 1
                        // Keep cover up; we'll release once we see frames.
                    }
                }
            }

            // If we still didn't see frames, keep the cover (spinner stays) and let watchdog/retry handle.
            // Recovery polling timeout - video may still be loading
        }
    }
    
    private let progressiveBufferTargets: [Double] = [8.0, 12.0, 18.0, 24.0, 30.0]
    
    /// Minimum buffered seconds required before we consider the first frame renderable.
    private var firstFrameMinimumBuffer: Double {
        mediaType == .video ? 3.0 : 0.1
    }
    
    /// Minimum buffered seconds required before we resume playback after a stall.
    private var stallRecoveryMinimumBuffer: Double {
        mediaType == .video ? 5.0 : 0.5
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
    
    // Reactive autoPlay state
    // For fullscreen and detail modes, use static autoPlay parameter
    // CRITICAL: For MediaCell mode, NEVER auto-play - VideoPlaybackCoordinator controls all playback via notifications
    private var currentAutoPlay: Bool {
        if mode == .mediaBrowser || mode == .tweetDetail || mode == .embeddedDetail {
            return autoPlay
        }
        // MediaCell mode: coordinator controls playback via notifications
        if mode == .mediaCell {
            return false
        }
        // For other modes, use autoPlay parameter
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
        // Gate MediaCell-like playback by overlay coverage.
        // Fullscreen/detail contexts manage their own visibility and should not be paused by feed overlays.
        if mode == .mediaCell || mode == .embeddedDetail {
            return !isCoveredByOverlay
        }
        return true
    }
    
    var body: some View {
        videoContentView
            .modifier(lifecycleModifiers)
            .modifier(notificationModifiers)
            .modifier(gestureModifiers)
    }
    
    private var lifecycleModifiers: AnyViewModifier {
        AnyViewModifier { content in
            content
                .onAppear {
                    handleOnAppear()
                    isCoveredByOverlay = OverlayVisibilityCoordinator.shared.isCovered
                }
                .onDisappear { 
                    stopTimeRemainingDisplayCycle()
                    handleOnDisappear() 
                }
                .onChange(of: mode) { oldMode, newMode in handleModeChange(oldMode: oldMode, newMode: newMode) }
                .onChange(of: isMuted) { _, newMuteState in handleMuteChange(newMuteState: newMuteState) }
                .onChange(of: currentAutoPlay) { _, shouldAutoPlay in handleAutoPlayChange(shouldAutoPlay: shouldAutoPlay) }
                .onChange(of: isVisible) { _, visible in handleVisibilityChange(visible: visible) }
                .onChange(of: isActuallyVisible) { _, actuallyVisible in handleActualVisibilityChange(actuallyVisible: actuallyVisible) }
                .onChange(of: player) { _, newPlayer in handlePlayerChange(newPlayer: newPlayer) }
                .onChange(of: shouldLoadVideo) { _, newShouldLoadVideo in handleLoadingStateChange(newShouldLoadVideo: newShouldLoadVideo) }
                .onChange(of: playbackState) { oldState, newState in
                    if newState == .playing && oldState != .playing {
                        startTimeRemainingDisplayCycle()
                    } else if newState != .playing {
                        stopTimeRemainingDisplayCycle()
                    }
                }
                // VideoManager removed - videos now controlled by global VideoPlaybackCoordinator
        }
    }
    
    private var notificationModifiers: AnyViewModifier {
        AnyViewModifier { content in
            content
                .onReceive(MuteState.shared.$isMuted) { globalMuteState in handleGlobalMuteChange(globalMuteState: globalMuteState) }
                .onReceive(NotificationCenter.default.publisher(for: .overlayCoverageChanged)) { notification in
                    guard mode == .mediaCell else { return }
                    if let isCovered = notification.userInfo?["isCovered"] as? Bool {
                        isCoveredByOverlay = isCovered
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .stopAllVideos)) { _ in handleStopAllVideos() }
                .onReceive(NotificationCenter.default.publisher(for: .shouldStopAllVideos)) { _ in handleCoordinatorStopCommand() }
                .onReceive(NotificationCenter.default.publisher(for: .shouldStopVideo)) { notification in handleCoordinatorStopCommand(notification: notification) }
                .onReceive(NotificationCenter.default.publisher(for: .shouldPlayVideo)) { notification in handleCoordinatorPlayCommand(notification: notification) }
                .onReceive(NotificationCenter.default.publisher(for: .shouldPauseVideo)) { notification in handleCoordinatorPauseCommand(notification: notification) }
                .onReceive(NotificationCenter.default.publisher(for: .videoInfrastructureRestarted)) { _ in handleVideoInfrastructureRestarted() }
                .onReceive(NotificationCenter.default.publisher(for: .videoLayerRefresh)) { _ in handleVideoLayerRefresh() }
                .onReceive(NotificationCenter.default.publisher(for: .reloadVisibleVideosOnly)) { _ in handleReloadVisibleVideosOnly() }
                .onReceive(NotificationCenter.default.publisher(for: .appUserReady)) { _ in handleAppUserReady() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in handleWillResignActive() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in handleDidEnterBackground() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in handleWillEnterForeground() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in handleDidBecomeActive() }
                .onReceive(NotificationCenter.default.publisher(for: .requestVideoTimerUpdate)) { notification in
                    guard let requestedMid = notification.userInfo?["videoMid"] as? String,
                          requestedMid == mid,
                          mode == .mediaCell else { return }
                    // Post current timer state
                    NotificationCenter.default.post(
                        name: .videoTimerUpdate,
                        object: nil,
                        userInfo: [
                            "videoMid": mid,
                            "show": showTimeRemaining,
                            "timeRemaining": timeRemainingText
                        ]
                    )
                }
        }
    }
    
    private var gestureModifiers: AnyViewModifier {
        AnyViewModifier { content in
            content
                .onTapGesture { handleTap() }
                .onLongPressGesture(minimumDuration: 0.5) { handleLongPress() } onPressingChanged: { pressing in handlePressingChanged(pressing: pressing) }
        }
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
                
            case .embeddedDetail:
                // Embedded/quoted tweet preview inside TweetDetailView: behave like a MediaCell (fills its grid slot)
                videoPlayerView()
                    .aspectRatio(videoAR, contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // CRITICAL: Mark video as visible to prevent cache eviction
        if mode == .mediaCell {
            VideoStateCache.shared.markAsVisible(mid)
            SharedAssetCache.shared.markAsVisible(mid)
        }
        
        // Handle idle timer for fullscreen modes
        if mode == .mediaBrowser {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        
        // For fullscreen and detail modes, always try to set up player regardless of shouldLoadVideo
        if mode == .mediaBrowser || mode == .tweetDetail {
            if player == nil {
                // Reset loading state if stuck
                if loadingState.isLoading {
                    loadingState = .idle
                }
                setupPlayer()
            } else {
                // Player exists, validate and configure it
                validateAndConfigureExistingPlayer()
            }
            return
        }
        
        // For MediaCell mode, check if existing player is broken and needs recreation
        if let player = player, let playerItem = player.currentItem {
            // Check for various broken states
            let isFailed = playerItem.status == .failed
            let hasError = playerItem.error != nil || player.error != nil
            let isStuckLoading = loadingState.isLoading && playerItem.status == .readyToPlay && !playerItem.loadedTimeRanges.isEmpty
            
            if isFailed || hasError || isStuckLoading {
                handleError(strategy: .loadFailure)
                return
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
                loadingState = .idle
            }
            
            // PERFORMANCE: Add small delay for MediaCell to let scroll settle
            // Detail/fullscreen modes start immediately (user is focused on them)
            if mode == .mediaCell {
                Task {
                    try? await Task.sleep(nanoseconds: 150_000_000) // 150ms delay
                    guard self.player == nil, self.shouldLoadVideo, self.isVisible else { return }
                    setupPlayer()
                }
            } else {
                setupPlayer()
            }
        } else if player != nil && loadingState.isLoaded && !hasInitialized {
            // Player exists and is loaded - mark as initialized
            hasInitialized = true
        }
    }
    
    private func handleOnDisappear() {
        // CRITICAL: Mark video as not visible to allow cache eviction if needed
        if mode == .mediaCell {
            VideoStateCache.shared.markAsNotVisible(mid)
            SharedAssetCache.shared.markAsNotVisible(mid)
        }
        
        // Cancel recovery timeout task (cleanup)
        recoveryTimeoutTask?.cancel()
        recoveryTimeoutTask = nil
        
        // Handle idle timer for fullscreen modes
        if mode == .mediaBrowser {
            UIApplication.shared.isIdleTimerDisabled = false
            
            // Before exiting full screen, restore the mute state to global mute state
            // This ensures the player instance is properly muted when returning to MediaCell
            if let player = player {
                player.isMuted = MuteState.shared.isMuted
            }
        }
        
        // PERFORMANCE FIX: Remove ALL observers when off-screen to free resources
        // Previously kept video completion observers active for sequential playback,
        // but this caused excessive resource usage when many videos are off-screen
        // Removing observers for off-screen video
        removePlayerObservers()

        // Cache the current video state (MediaCell only, NOT TweetDetail or MediaBrowser)
        // TweetDetail uses DetailVideoManager singleton and should not share players with MediaCell
        // MediaBrowser uses FullScreenVideoManager singleton and should not share players with MediaCell
        if mode == .mediaCell, let player = player {
            // Don't save position if video is finished (at the end)
            // This prevents restoring to the end position when scrolling back
            if isVideoAtEnd(player) {
                // Skipping save - video finished
            } else {
                // For MediaCell mode, save the current global mute state
                // For detail/fullscreen modes, we need to track the original global mute state
                let originalMuteState = mode == .mediaCell ? isMuted : MuteState.shared.isMuted
                // Saving video position on disappear
                VideoStateCache.shared.cacheVideoState(
                    for: mid,
                    player: player,
                    time: player.currentTime(),
                    wasPlaying: player.rate > 0,
                    originalMuteState: originalMuteState
                )
            }
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
                // Applied mute state on disappear
            }
            
            // CRITICAL FIX: Stop buffering when video goes out of sight to prevent performance degradation
            // This stops CachingPlayerItem from continuing to download segments in the background
            if let playerItem = player?.currentItem {
                // Reduce buffer duration to stop aggressive buffering
                playerItem.preferredForwardBufferDuration = 0.0
                // Ensure network resources are not used while paused
                if let cachingPlayerItem = playerItem as? CachingPlayerItem {
                    cachingPlayerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
                }
                // Stopped buffering for out-of-sight video
            }
            
            // Also cancel loading tasks in SharedAssetCache for this video
            Task { @MainActor in
                if let parentTweetId = parentTweetId {
                    // Cancel loading tasks even if cached content exists (video is out of sight)
                    SharedAssetCache.shared.cancelLoadingForOutOfSightTweet(parentTweetId)
                }
            }
        } else if mode == .mediaBrowser {
            // Exiting fullscreen - ALWAYS pause and restore mute state for MediaCell reuse
            player?.pause()
            if let player = player {
                // Restore mute state to global state before returning to MediaCell
                player.isMuted = MuteState.shared.isMuted
                // Restored mute state after exiting fullscreen
            }
        } else if mode == .tweetDetail {
            // TweetDetail: DO NOTHING.
            // Detail view uses a singleton player (DetailVideoManager) and SwiftUI may recreate
            // cells/views (TabView) during normal interaction. Pausing here causes the
            // "plays briefly then stops" bug. Cleanup is handled by TweetDetailView's lifecycle.
        } else if mode == .embeddedDetail {
            // Embedded/quoted tweet video: pause and clean up (independent player instance).
            player?.pause()
        }
    }
    
    private func handleModeChange(oldMode: Mode, newMode: Mode) {
        // When mode changes, apply appropriate mute state
        guard let player = player else {
            return
        }
        
        if newMode == .mediaBrowser {
            // Entering full screen - force unmute
            player.isMuted = false
            
            // CRITICAL: Force layer detachment and increment representableId
            // This ensures the VideoPlayerRepresentable in MediaCell releases the layer
            // before AVPlayerViewController tries to use it, preventing black screen
            self.representableId += 1
            
            // Don't pause here - let AVPlayerViewController handle play/pause
        } else if newMode == .mediaCell && oldMode == .mediaBrowser {
            // Exiting full screen to MediaCell - apply global mute state
            
            // Store playback state before transition
            let wasPlaying = player.rate > 0
            let currentTime = player.currentTime()
            
            // Pause player to allow clean layer detachment
            player.pause()
            // Paused player for layer transition
            
            // Apply global mute state
            player.isMuted = MuteState.shared.isMuted
            
            // Force recreation of VideoPlayerRepresentable to ensure fresh layer attachment
            self.representableId += 1
            
            // Resume playback using proper completion handler instead of arbitrary delay
            if wasPlaying {
                // CRITICAL: Always ensure muteState is correct before resuming playback in MediaCell
                player.isMuted = MuteState.shared.isMuted
                
                // Seek to current position with completion handler to ensure layer is ready
                player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    guard finished else { return }
                    player.play()
                }
            }
        } else if newMode == .mediaCell {
            // Any other transition to MediaCell - apply global mute state
            player.isMuted = MuteState.shared.isMuted
        }
    }
    
    private func handleMuteChange(newMuteState: Bool) {
        // For full screen modes, always keep unmuted regardless of the isMuted parameter
        if mode == .mediaBrowser {
            player?.isMuted = false
        } else {
            player?.isMuted = newMuteState
        }
    }
    
    private func handleGlobalMuteChange(globalMuteState: Bool) {
        // For MediaCell mode, always sync with global mute state
        if mode == .mediaCell {
            player?.isMuted = globalMuteState
        }
        // For full screen modes, ignore global mute state and always keep unmuted
        else if mode == .mediaBrowser {
            player?.isMuted = false
        }
    }
    
    private func handleAutoPlayChange(shouldAutoPlay: Bool) {
        // Handle autoPlay state changes
        // DON'T pause here - shared players might be in use by fullscreen/detail
        // MediaCell videos are controlled by coordinator notifications
        if mode == .mediaCell {
            // For MediaCell, coordinator controls via notifications
            // If video just finished, ensure it's paused
            if playbackState == .finished {
                // Video finished - ensure it's paused
                // Don't do ANYTHING else - no state changes, no view updates, just keep it paused
                // This prevents flicker during sequential video transitions
                if (player?.rate ?? 0) > 0 {
                    player?.pause()
                }
                return
            }
            
            // CRITICAL: Also skip if video is finished and shouldAutoPlay is false
            // This handles the case where coordinator updates but the finished video shouldn't react
            if playbackState == .finished && !shouldAutoPlay {
                return
            }
            
            // CRITICAL: If already initialized and player is set up, skip work to prevent recomposition
            // This is key for smooth scrolling - once a video is initialized, don't recompose it
            let shouldSkip = hasInitialized && player != nil && loadingState.isLoaded
            
            if shouldSkip {
                // Only update if the playback state actually needs to change
                let currentShouldPlay = shouldAutoPlay && isVisible
                let isCurrentlyPlaying = (player?.rate ?? 0) > 0
                
                // If state matches, do nothing to prevent recomposition
                if currentShouldPlay == isCurrentlyPlaying {
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
        
        // Update player access time to prevent premature cleanup when video becomes visible
        if visible {
            Task { @MainActor in
                SharedAssetCache.shared.updatePlayerAccessTime(mediaID: self.mid)
            }
        }
        
        // Handle visibility changes - simplified logic to avoid conflicts
        if visible {
            // For fullscreen and detail modes, always allow setup regardless of shouldLoadVideo
            if mode == .mediaBrowser || mode == .tweetDetail {
                        // Fullscreen/Detail mode - checking state
                
                // Check if video failed and needs retry
                if loadingState.hasFailed {
                    // Fullscreen video was in failed state, retrying load
                    player = nil
                    loadingState = .idle
                    playbackState = .notStarted
                    setupPlayer()
                    return
                }
                
                if player == nil {
                    // Reset loading state if stuck
                    if loadingState.isLoading {
                        // Loading state stuck, resetting
                        loadingState = .idle
                    }
                    setupPlayer()
                } else {
                    // Check if player is ready and should play
                    if let playerItem = player?.currentItem {
                        let hasBufferedData = !playerItem.loadedTimeRanges.isEmpty
                        let isPlayerReady = playerItem.status == .readyToPlay || hasBufferedData
                        
                        if isPlayerReady {
                            // Fullscreen player ready with data
                            if loadingState.isLoading {
                                loadingState = .loaded
                            }
                            
                            // Auto-play fullscreen videos if not already playing
                            if player?.rate == 0 {
                                // For fullscreen mode, always unmute
                                player?.isMuted = false
                                // Starting fullscreen playback
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
                return
            }
            
            // CRITICAL FIX: Restore buffering settings when video becomes visible again
            // This allows videos to buffer properly when they come back into view
            if mode == .mediaCell, let playerItem = player?.currentItem {
                // Restore buffer duration for proper buffering
                if let cachingPlayerItem = playerItem as? CachingPlayerItem {
                    cachingPlayerItem.preferredForwardBufferDuration = 15.0  // Restore normal buffering
                    cachingPlayerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false  // Keep this false
                } else {
                    // For progressive videos, restore buffer duration
                    playerItem.preferredForwardBufferDuration = 30.0
                }
            }
            
            // Check if video is in failed state and needs retry
            if loadingState.hasFailed {
                player = nil
                loadingState = .idle
                playbackState = .notStarted
                setupPlayer()
                return
            }
            
            // Validate existing player state if present
            if let player = player, let playerItem = player.currentItem {
                if playerItem.status == .failed {
                    handleError(strategy: .loadFailure)
                    return
                }
                
                // Check if player has data ready and should play
                let hasBufferedData = !playerItem.loadedTimeRanges.isEmpty
                let isPlayerReady = playerItem.status == .readyToPlay || hasBufferedData
                
                if isPlayerReady {
                    
                    // Update loading state to show video is ready
                    // CRITICAL FIX: Check buffered duration to ensure we have enough data before hiding spinner
                    // This prevents hiding spinner too early and fixes stuck loading states after background
                    if loadingState.isLoading {
                        let bufferedDuration = bufferedTimeAhead(for: playerItem, player: player)
                        if bufferedDuration >= firstFrameMinimumBuffer {
                            loadingState = .loaded
                            retryAttempts = 0  // Reset retry counter on successful load
                            // Mark as initialized to prevent recomposition when scrolling
                            if mode == .mediaCell {
                                hasInitialized = true
                            }
                        }
                    }
                    
                    // Check if should auto-play
                    if currentAutoPlay && player.rate == 0 {
                        // CRITICAL: Always ensure muteState is correct before playing
                        // For MediaCell, always respect global muteState
                        if mode == .mediaCell {
                            player.isMuted = MuteState.shared.isMuted
                            // Applied mute state for MediaCell
                        }
                        player.volume = 0
                        player.play()
                        UIView.animate(withDuration: 0.3) {
                            player.volume = 1.0
                        }
                        playbackState = .playing
                    }
                    return
                }
            }
            
            // If no player and loading is enabled, set up the player
            if player == nil {
                // Reset loading state if stuck
                if loadingState.isLoading {
                    loadingState = .idle
                }
                setupPlayer()
            } else {
                // FAST HEALTH CHECK: Quick validation during normal scrolling
                // Only do expensive checks if we detect potential issues from background recovery
                let playerIsMissing = player == nil || player?.currentItem == nil
                let playerIsBroken = !playerIsMissing && isPlayerBroken()
                
                if playerIsMissing || playerIsBroken {
                    SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey, force: true)
                    player = nil
                    loadingState = .idle
                    playbackState = .notStarted
                    setupPlayer()
                    return
                }
                
                // ADDITIONAL CHECK: Only after background recovery, check if player time is valid
                // This catches players cleared during background (fast check, no file I/O)
                if didEnterBackground && !hasRecoveredThisCycle {
                    if let currentPlayer = player {
                        let currentTime = currentPlayer.currentTime()
                        if !currentTime.isValid || !currentTime.seconds.isFinite {
                            // Player was likely cleared during background recovery
                            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey, force: true)
                            player = nil
                            loadingState = .idle
                            playbackState = .notStarted
                            setupPlayer()
                            return
                        }
                    }
                }
                
                // CRITICAL FIX: Reset finished videos when scrolled back into view
                // This ensures finished videos restart from beginning when they become visible again
                if mode == .mediaCell && playbackState == .finished {
                    // Resetting finished video to beginning
                    VideoStateCache.shared.clearCachedState(for: mid)
                    playbackState = .notStarted
                    if let player = player {
                        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                            // After seeking, check playback conditions to start if appropriate
                            Task { @MainActor in
                                self.checkPlaybackConditions(autoPlay: self.currentAutoPlay, isVisible: true)
                            }
                        }
                    }
                    return
                }
                
                // CRITICAL FIX: For MediaCell videos becoming visible after background,
                // only force view refresh if we actually went to background (not just screen lock/share sheet)
                // This prevents unnecessary refreshes during normal scrolling that cause black flicker
                if mode == .mediaCell && didEnterBackground && !hasRecoveredThisCycle {
                    representableId += 1
                    hasRecoveredThisCycle = true  // Mark as recovered to avoid repeated refreshes
                }
                
                // Player is healthy, restore cached state
                // CRITICAL: Don't call checkPlaybackConditions here - let the normal flow handle it
                // Just like the first time, KVO handlers will fire when ready and handle playback
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
                }
            }
        } else {
            // Video is no longer covered.
            // If it was playing before it got covered (fullscreen/login/sheet), resume immediately
            // (don't depend on coordinator here, since state can be stale/cleared).
            if isVisible, let player = player {
                let wasPlayingBeforeCover = VideoStateCache.shared.getCachedPlaybackInfo(for: mid)?.wasPlaying ?? false
                let shouldResume = wasPlayingBeforeCover || playbackState == .playing
                let noDetailViewActive = !DetailVideoManager.shared.isDetailViewActive()

                if shouldResume && noDetailViewActive {
                    // CRITICAL: Check for saved position from fullscreen exit before resuming
                    if PersistentVideoStateManager.shared.shouldRestorePlayback(videoMid: mid, context: .mediaCell),
                       let savedState = PersistentVideoStateManager.shared.getState(videoMid: mid, context: .mediaCell) {
                        // CRITICAL: Validate saved time before seeking to prevent crash
                        guard savedState.currentTime.isValid && savedState.currentTime.seconds.isFinite else {
                            PersistentVideoStateManager.shared.clearState(videoMid: mid, context: .mediaCell)
                            if player.rate == 0 {
                                player.isMuted = MuteState.shared.isMuted
                                player.volume = 0
                                player.play()
                                UIView.animate(withDuration: 0.3) {
                                    player.volume = 1.0
                                }
                                playbackState = .playing
                            }
                            return
                        }
                        
                        
                        player.seek(to: savedState.currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                            guard finished else { return }
                            
                            Task { @MainActor in
                                
                                // Apply mute state and resume playback if it was playing in fullscreen
                                self.player?.isMuted = MuteState.shared.isMuted
                                if savedState.wasPlaying {
                                    self.player?.volume = 0
                                    self.player?.play()
                                    if let player = self.player {
                                        UIView.animate(withDuration: 0.3) {
                                            player.volume = 1.0
                                        }
                                    }
                                    self.playbackState = .playing
                                }
                                
                                // Clear the saved state so we don't restore again
                                PersistentVideoStateManager.shared.clearState(videoMid: self.mid, context: .mediaCell)
                            }
                        }
                    } else if player.rate == 0 {
                        // No saved position from fullscreen - resume normally
                        player.isMuted = MuteState.shared.isMuted
                        player.volume = 0
                        player.play()
                        UIView.animate(withDuration: 0.3) {
                            player.volume = 1.0
                        }
                        playbackState = .playing
                    }
                } else {
                    // Otherwise, re-check playback conditions on uncover (coordinator decides).
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
        if mode == .mediaCell || mode == .embeddedDetail {
            // If we're currently *in* a TweetDetailView and this MediaCell is visible there (e.g. quoted tweet),
            // do NOT pause it. We only want to stop feed/background MediaCells.
            if NavigationStateManager.shared.isDetailViewActive && isVisible {
                // Ignoring stop for visible MediaCell inside TweetDetailView
                return
            }

            // Store playback state before pausing so we can resume later
            if let player = player {
                // CRITICAL: Check both player.rate AND playbackState
                // Player might already be paused by cachePlayerStateForBackground()
                // but playbackState still indicates it was playing
                let wasPlaying = (player.rate > 0) || (playbackState == .playing)
                if wasPlaying {
                    // CRITICAL: Keep playbackState as .playing so we know it was playing
                    // Don't change to .paused - we'll use .playing to determine if we should resume
                    // Only pause the player, not the state
                    // Paused - will resume when fullscreen closes
                }
                // PERFORMANCE FIX: Save position before pausing (Twitter-style)
                // Pass wasPlaying explicitly to preserve state before pause
                saveCurrentPosition(player: player, wasPlaying: wasPlaying, reason: "stopAllVideos")
                
                // Capture the last visible frame right before pausing (covers interruptions / audio session changes).
                captureLastFrameIfPossible(reason: "stopAllVideos")
                player.pause()
                player.isMuted = true
            }
        }
        // TweetDetail and MediaBrowser: DO NOTHING
    }
    
    // MARK: - Video Playback Coordinator Handlers
    
    private func handleCoordinatorStopCommand(notification: Notification? = nil) {
        // Stop command from VideoPlaybackCoordinator
        guard mode == .mediaCell else { return }
        
        // If notification has a specific videoMid, only stop if it matches this video
        if let videoMid = notification?.userInfo?["videoMid"] as? String {
            guard videoMid == mid else { return }
        }
        // Otherwise, stop all videos (shouldStopAllVideos notification)
        
        coordinatorWantsToPlay = false
        
        // PERFORMANCE FIX: Save position before pausing (Twitter-style)
        // CRITICAL: Capture wasPlaying state BEFORE pausing
        if let player = player {
            let wasPlaying = (player.rate > 0) || (playbackState == .playing)
            
            // Only save if this is the first stop (not a duplicate)
            // Prevents overwriting wasPlaying: true with wasPlaying: false
            if wasPlaying || player.rate > 0 {
                saveCurrentPosition(player: player, wasPlaying: wasPlaying, reason: "coordinatorStop")
            }
            
            player.pause()
        }
        
        // CRITICAL: Don't change playbackState to .paused if it was .playing
        // This preserves the "was playing" state for background recovery
        // Multiple coordinator stop commands can arrive in quick succession,
        // and we don't want subsequent calls to overwrite the original state
        // Only set to .paused if it wasn't playing
        if playbackState != .playing {
            playbackState = .paused
        }
    }
    
    private func handleCoordinatorPauseCommand(notification: Notification) {
        // Pause command from VideoPlaybackCoordinator - check if it's for this video
        guard mode == .mediaCell else { return }
        guard let videoMid = notification.userInfo?["videoMid"] as? String else { return }
        guard videoMid == mid else { return }
        
        
        coordinatorWantsToPlay = false
        if let player = player {
            // CRITICAL: Capture wasPlaying state BEFORE pausing
            let wasPlaying = (player.rate > 0) || (playbackState == .playing)
            
            // PERFORMANCE FIX: Save position before pausing (Twitter-style)
            // Only save if this is the first pause (not a duplicate)
            if wasPlaying || player.rate > 0 {
                saveCurrentPosition(player: player, wasPlaying: wasPlaying, reason: "coordinatorPause")
            }
            
            UIView.animate(withDuration: 0.2, animations: {
                player.volume = 0
            }, completion: { _ in
                player.pause()
            })
        }
        
        // CRITICAL: Don't change playbackState to .paused if it was .playing
        // This preserves the "was playing" state for background recovery
        if playbackState != .playing {
            playbackState = .paused
        }
    }
    
    private func handleCoordinatorPlayCommand(notification: Notification) {
        // Play command from VideoPlaybackCoordinator - check if it's for this video
        guard mode == .mediaCell else { return }
        guard let videoMid = notification.userInfo?["videoMid"] as? String else { return }
        guard videoMid == mid else { return }
        
        let isSurvey = notification.userInfo?["isSurvey"] as? Bool ?? false
        let isPrimary = notification.userInfo?["isPrimary"] as? Bool ?? false
        
        // Set flag to play when ready
        coordinatorWantsToPlay = true
        
        // Only play if player is ready
        guard let player = player, loadingState == .loaded else {
            return
        }
        
        // Check if video is already playing
        let isCurrentlyPlaying = player.rate > 0 && playbackState == .playing
        
        // For survey mode, only start from beginning if there's no cached position
        // For primary mode, continue from current position
        if isSurvey {
            // Check if video has a cached position from previous viewing
            let hasCachedPosition = VideoStateCache.shared.hasCachedPlaybackInfo(for: mid)
            let currentTime = player.currentTime().seconds
            
            // CRITICAL: If video is at the end (finished), always restart from beginning
            // even if there's a cached position. This ensures finished videos restart properly.
            if isVideoAtEnd(player) {
                // Video at end - restarting from beginning
                VideoStateCache.shared.clearCachedState(for: mid)
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            } else if hasCachedPosition && currentTime > 0.5 {
                // Video was restored from cache - keep the current position
                // Video has cached position - NOT seeking to zero
            } else {
                // New video or at beginning - start from zero for survey
                // Video starting from beginning
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        } else if isPrimary {
            // Primary phase: continue from current position without interruption
            // CRITICAL: If already playing from survey phase, don't restart
            if isCurrentlyPlaying {
                // Video already playing - continuing seamlessly
                // Update state but don't interrupt playback
                playbackState = .playing
                return
            }
            // Playing video
        }
        
        // Only start/restart playback if not already playing
        if !isCurrentlyPlaying {
            player.volume = 0
            player.play()
            UIView.animate(withDuration: 0.3) {
                player.volume = 1.0
            }
        }
        playbackState = .playing
    }
    
    private func handleWillResignActive() {
        // CRITICAL: This handles BOTH screen lock AND app backgrounding AND share sheet
        // Screen lock: willResignActive → (locked) → didBecomeActive
        // App background: willResignActive → didEnterBackground → willEnterForeground → didBecomeActive
        // Share sheet: willResignActive → (sheet shown) → didBecomeActive (when dismissed)
        
        // Reset flags to ensure recovery will run when app becomes active again
        // This is critical for share sheet case where didEnterBackground might not fire
        hasRecoveredThisCycle = false
        didEnterBackground = false  // Reset - will be set to true if didEnterBackground fires
        
        // Cache player state but DON'T detach yet - keep video visible
        captureLastFrameIfPossible(reason: "willResignActive")
        // Hold last-frame cover across background → foreground to prevent black blink.
        isHoldingRecoveryCover = true
        cachePlayerStateForBackground()
    }
    
    private func handleDidEnterBackground() {
        // App actually went to background (not just screen lock)
        didEnterBackground = true  // Mark that we went to background (not just screen lock)
    }
    
    private func handleWillEnterForeground() {
        coordinateRecovery(source: .willEnterForeground)
    }
    
    private func handleDidBecomeActive() {
        coordinateRecovery(source: .didBecomeActive)
    }
    
    /// Central recovery coordinator that decides which recovery path to take
    /// This prevents duplicate recovery operations and consolidates recovery logic
    private func coordinateRecovery(source: RecoverySource) {
        // If already recovered this cycle, skip
        if hasRecoveredThisCycle {
            return
        }
        
        // For MediaCell with actual background (not screen lock), defer to `.reloadVisibleVideosOnly`
        // AppDelegate will post this notification after clearing players
        if mode == .mediaCell && didEnterBackground && source == .willEnterForeground {
            isPlayerDetached = false
            hasRecoveredThisCycle = true
            return
        }
        
        // For non-MediaCell or screen-lock cycles, recover immediately
        // But only if video infrastructure is ready
        if !AppDelegate.isVideoInfrastructureReady {
            isPlayerDetached = false
            return
        }
        
        recoverFromBackground()
        
        // Mark that we need a health check after this foreground entry
        needsHealthCheckAfterForeground = true
        
        // Perform delayed health check after recovery (only once)
        performDelayedHealthCheck()
    }
    
    private enum RecoverySource {
        case willEnterForeground
        case didBecomeActive
    }
    
    /// Validates player state and recovers from invalid states
    /// Returns true if player is valid or recovery was initiated, false if caller should return early
    /// - Note: Invalid states can occur due to background transitions, memory pressure, or AVFoundation issues
    @MainActor
    private func validatePlayerState() -> Bool {
        guard let player = player else {
            return true // No player yet, validation passes
        }
        
        // Check 1: Player must have a currentItem
        guard let playerItem = player.currentItem else {
            if !loadingState.isLoading {
                // Player has no currentItem - recreating
                recoverFromInvalidPlayer()
            }
            return false
        }
        
        // Check 2: Current time must be finite
        let currentSeconds = player.currentTime().seconds
        if !currentSeconds.isFinite {
            if !loadingState.isLoading {
                // Player currentTime is invalid - recreating
                recoverFromInvalidPlayer()
            }
            return false
        }
        
        // Check 3: Player item must not be in failed state
        if playerItem.status == .failed {
            // Player item is in failed state, triggering recovery
            handleError(strategy: .loadFailure)
            return false
        }
        
        return true
    }
    
    /// Recovers from invalid player state by cleaning up and recreating
    @MainActor
    private func recoverFromInvalidPlayer() {
        SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey, force: true)
        self.player = nil
        self.loadingState = .idle
        self.playbackState = .notStarted
        setupPlayer()
    }
    
    private func performDelayedHealthCheck() {
        // CRITICAL: Delayed health check after recovery
        // Sometimes players appear healthy immediately after recovery but are actually broken
        // Check again after a short delay to catch these cases
        // OPTIMIZATION: Only runs once after foreground entry, not continuously
        Task { @MainActor in
            // Only proceed if we actually need a health check
            guard self.needsHealthCheckAfterForeground else { return }
            
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
            
            // Clear the flag - health check completed
            self.needsHealthCheckAfterForeground = false
            
            // Check if player is broken or stuck in loading
            if let player = self.player, let playerItem = player.currentItem {
                let isBroken = self.isPlayerBroken()
                let isStuckLoading = self.loadingState.isLoading && playerItem.status == .readyToPlay
                let hasError = playerItem.error != nil || player.error != nil
                
                if isBroken || isStuckLoading || hasError {
                    
                    // Clean up observers
                    if let observer = self.timeObserver, let observerPlayer = self.timeObserverPlayer {
                        observerPlayer.removeTimeObserver(observer)
                    }
                    self.timeObserver = nil
                    self.timeObserverPlayer = nil
                    
                    // Remove from SharedAssetCache
                    SharedAssetCache.shared.removeInvalidPlayer(for: self.playerCacheKey, force: true)
                    
                    let wasPlaying = VideoStateCache.shared.getCachedPlaybackInfo(for: self.mid)?.wasPlaying ?? false
                    
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
                        self.loadingState = .loaded
                        self.retryAttempts = 0
                        if self.mode == .mediaCell {
                            self.hasInitialized = true
                        }
                    }
                }
            }
        }
    }
    
    /// SANITY CHECK: Detects if player is broken
    private func isPlayerBroken() -> Bool {
        // Check 1: Player or item is missing
        guard let player = player else {
            return true
        }
        guard let playerItem = player.currentItem else {
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
            return false // Give it a chance
        }
        
        // Check 6: For screen lock recovery, don't check loadedTimeRanges alone
        // iOS might temporarily clear this data after screen lock, but it will reload
        // Only check loadedTimeRanges if status is .readyToPlay AND duration is invalid
        // This prevents false positives where player is healthy but temporarily has no ranges
        if playerItem.status == .readyToPlay && 
           playerItem.loadedTimeRanges.isEmpty && 
           !playerItem.duration.isValid {
            return true
        }
        
        // Check 7: Progressive player is stalled
        if shouldForceProgressiveReload(player: player, item: playerItem) {
            // Progressive player stalled, marking as broken
            return true
        }
        
        return false
    }
    
    private func shouldForceProgressiveReload(player: AVPlayer, item: AVPlayerItem) -> Bool {
        guard mediaType == .video else { return false }
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
        let backgroundedThisCycle = didEnterBackground
        
        // Mark that we've recovered (but don't reattach yet)
        hasRecoveredThisCycle = true
        
        // CRITICAL: Cancel any existing recovery timeout task
        recoveryTimeoutTask?.cancel()
        recoveryTimeoutTask = nil
        
        // Start 10-second timeout for MediaCell recovery
        // If video doesn't get ready and start playing within 10s, force full recreation
        if mode == .mediaCell {
            recoveryTimeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                
                // Check if task was cancelled (normal recovery succeeded)
                guard !Task.isCancelled else {
                    return
                }
                
                // After 10 seconds, check if video is playing properly
                guard let player = self.player, let playerItem = player.currentItem else {
                    return
                }
                
                let isPlaying = player.rate > 0
                let isReady = playerItem.status == .readyToPlay
                let hasBuffer = !playerItem.loadedTimeRanges.isEmpty
                
                // If video is playing or at least ready with buffer, recovery succeeded
                if isPlaying || (isReady && hasBuffer) {
                    self.recoveryTimeoutTask = nil
                    return
                }
                
                // Video still not ready after 10s - force full recreation
                // Video failed to recover within 10s - forcing full recreation
                
                // Clean up observers
                if let observer = self.timeObserver, let observerPlayer = self.timeObserverPlayer {
                    observerPlayer.removeTimeObserver(observer)
                }
                self.timeObserver = nil
                self.timeObserverPlayer = nil
                
                // Remove from SharedAssetCache
                SharedAssetCache.shared.removeInvalidPlayer(for: self.playerCacheKey, force: true)
                
                // Clear player and state
                player.pause()
                self.player = nil
                self.loadingState = .idle
                self.playbackState = .notStarted
                
                // Force recreation
                if self.shouldLoadVideo || self.isVisible {
                    // Recreating player after timeout
                    self.setupPlayer()
                } else {
                    // Not recreating player (not visible)
                }
                
                self.recoveryTimeoutTask = nil
            }
        }
        
        // CONSERVATIVE RECOVERY STRATEGY:
        // Only recreate players that are actually broken, leave healthy ones alone
        // This prevents unnecessary work and potential issues with working players

        // CRITICAL: Don't check player health during seek operations
        // Seeking puts player in transitional state that looks "broken" but is actually just mid-seek
        if isSeekingToBeginning {
            print("⏭️ [VIDEO RECOVERY] Skipping health check - video is seeking to beginning")
            return
        }

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
            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey, force: true)
            
            let wasPlaying = VideoStateCache.shared.getCachedPlaybackInfo(for: mid)?.wasPlaying ?? false
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
                        
                        // Restore position and resume if was playing
                        if wasPlaying && CMTimeGetSeconds(currentTime) > 0 {
                            player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                                guard finished else { return }
                                Task { @MainActor in
                                    // Resume playback if was playing
                                    // For MediaCell, check no overlays/detail active (coordinator controls approval)
                                    if self.mode == .mediaCell {
                                        player.isMuted = MuteState.shared.isMuted
                                        let noOverlaysActive = !self.isCoveredByOverlay
                                        let noDetailViewActive = !DetailVideoManager.shared.isDetailViewActive()
                                        if self.isVisible && noOverlaysActive && noDetailViewActive {
                                            player.play()
                                            self.playbackState = .playing
                                            // Cancel recovery timeout - video is playing successfully
                                            self.recoveryTimeoutTask?.cancel()
                                            self.recoveryTimeoutTask = nil
                                        } else {
                                        }
                                    } else {
                                        // For other modes, resume if visible
                                        if self.isVisible {
                                            player.play()
                                            self.playbackState = .playing
                                            // Cancel recovery timeout - video is playing successfully
                                            self.recoveryTimeoutTask?.cancel()
                                            self.recoveryTimeoutTask = nil
                                        }
                                    }
                                }
                            }
                        } else if wasPlaying {
                            // Video was playing but no time to restore - just resume
                            if self.mode == .mediaCell {
                                player.isMuted = MuteState.shared.isMuted
                                let noOverlaysActive = !self.isCoveredByOverlay
                                let noDetailViewActive = !DetailVideoManager.shared.isDetailViewActive()
                                if self.isVisible && noOverlaysActive && noDetailViewActive {
                                    player.play()
                                    self.playbackState = .playing
                                    // Cancel recovery timeout - video is playing successfully
                                    self.recoveryTimeoutTask?.cancel()
                                    self.recoveryTimeoutTask = nil
                                }
                            } else if self.isVisible {
                                player.play()
                                self.playbackState = .playing
                                // Cancel recovery timeout - video is playing successfully
                                self.recoveryTimeoutTask?.cancel()
                                self.recoveryTimeoutTask = nil
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
        
        // Ensure player is in valid state (should always pass here since isPlayerBroken() checked)
        guard let player = player, let playerItem = player.currentItem else {
            return
        }
        
        // CRITICAL: Double-check player is actually ready after short backgrounds
        // Sometimes players pass isPlayerBroken() but are still not ready to play
        // This can happen if currentItem was cleared by AppDelegate but player object still exists
        if playerItem.status == .unknown {
            // Unknown status after background usually means player was cleared - recreate it
            if let observer = timeObserver, let observerPlayer = timeObserverPlayer {
                observerPlayer.removeTimeObserver(observer)
            }
            timeObserver = nil
            timeObserverPlayer = nil
            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey, force: true)
            let wasPlaying = VideoStateCache.shared.getCachedPlaybackInfo(for: mid)?.wasPlaying ?? false
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
            // Player was cleared by AppDelegate - recreate it
            if let observer = timeObserver, let observerPlayer = timeObserverPlayer {
                observerPlayer.removeTimeObserver(observer)
            }
            timeObserver = nil
            timeObserverPlayer = nil
            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey, force: true)
            let wasPlaying = VideoStateCache.shared.getCachedPlaybackInfo(for: mid)?.wasPlaying ?? false
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
            let wasPlayingBeforeBackground = VideoStateCache.shared.getCachedPlaybackInfo(for: mid)?.wasPlaying ?? false
            
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
                    self.representableId += 1
                } else {
                }
            }
        }
        
        // Restore mute state
        applyMuteState(to: player)
        
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
                    } else {
                    }
                }
            } else if timeDiff > 0.5 {
                // Player not ready yet - wait for it to become ready before seeking
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
                            } else {
                            }
                        }
                    }
                }
            }
            
            // CRITICAL: Resume video if it was playing before backgrounding
            // For MediaCell, check no overlays (fullscreen/detail view) - coordinator controls approval
            // For other modes, resume if was playing and should load
            if cachedState.wasPlaying {
                if mode == .mediaCell {
                    // For MediaCell, check that no overlays/detail views are active (coordinator controls approval)
                    let noOverlaysActive = !isCoveredByOverlay
                    let noDetailViewActive = !DetailVideoManager.shared.isDetailViewActive()
                    if isVisible && noOverlaysActive && noDetailViewActive {
                        // CRITICAL: Always ensure muteState is correct before playing
                        player.isMuted = MuteState.shared.isMuted
                        // Applied mute state after background recovery
                        
                        // Validate player is ready before playing
                        if playerItem.status == .readyToPlay {
                            player.play()
                            playbackState = .playing
                        } else {
                            // Player not ready yet - wait for it to become ready
                            Task { @MainActor in
                                let noOverlaysActive = !self.isCoveredByOverlay
                                let noDetailViewActive = !DetailVideoManager.shared.isDetailViewActive()
                                var attempts = 0
                                while self.playerItem?.status != .readyToPlay && attempts < 50 {
                                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                                    attempts += 1
                                }
                                if self.playerItem?.status == .readyToPlay && self.isVisible && noOverlaysActive && noDetailViewActive {
                                    player.isMuted = MuteState.shared.isMuted
                                    player.play()
                                    self.playbackState = .playing
                                }
                            }
                        }
                    } else {
                        // Defer to checkPlaybackConditions via the delayed check below
                    }
                } else {
                    // For other modes, resume if was playing
                    let shouldResume = (shouldLoadVideo || mode == .tweetDetail || mode == .mediaBrowser)
                    if shouldResume {
                        // Validate player is ready before playing
                        if playerItem.status == .readyToPlay {
                            player.play()
                            playbackState = .playing
                        } else {
                            // Player not ready yet - wait for it to become ready
                            Task { @MainActor in
                                var attempts = 0
                                while playerItem.status != .readyToPlay && attempts < 50 {
                                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                                    attempts += 1
                                }
                                if playerItem.status == .readyToPlay {
                                    player.play()
                                    self.playbackState = .playing
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
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                
                // CRITICAL: Only trigger autoplay if player isn't already playing
                // This prevents competing with the direct play() calls above
                guard self.player?.rate == 0 && self.playbackState != .playing else {
                    return
                }
                
                self.checkPlaybackConditions(autoPlay: self.currentAutoPlay, isVisible: self.isVisible)
            }
        }
        
        // Reset background flag after recovery to prevent stale flags from affecting future visibility changes
        didEnterBackground = false
        
    }
    
    private func handleVideoInfrastructureRestarted() {
        
        // BULLETPROOF: For MediaCell, ALWAYS recreate if player exists OR currentItem is nil
        // This handles the case where AppDelegate cleared players (currentItem set to nil) before this notification
        if mode == .mediaCell {
            // Check if player exists OR if currentItem is nil (cleared by clearVideoPlayersForBackgroundRecovery)
            let hadPlayer = player != nil
            let currentItemIsNil = player?.currentItem == nil
            let wasInCache = VideoStateCache.shared.hasCachedPlaybackInfo(for: mid)
            
            // Force recreate if: player exists, OR currentItem is nil (was cleared), OR was in cache
            if hadPlayer || currentItemIsNil || wasInCache {
                
                if let observer = timeObserver, let observerPlayer = timeObserverPlayer {
                    observerPlayer.removeTimeObserver(observer)
                }
                timeObserver = nil
                timeObserverPlayer = nil
                
                // Remove from SharedAssetCache to force fresh creation
                SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey, force: true)
                
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
                return
            }
        }
        
        // For other modes, check if broken
        let playerIsMissing = player == nil || player?.currentItem == nil
        let playerIsBroken = !playerIsMissing && isPlayerBroken()
        
        if playerIsMissing || playerIsBroken {
            
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
            representableId += 1
            
            if let cachedState = VideoStateCache.shared.getCachedPlaybackInfo(for: mid) {
                let shouldResume = cachedState.wasPlaying && (shouldLoadVideo || mode == .tweetDetail || mode == .mediaBrowser)
                if shouldResume && player?.rate == 0 {
                    // CRITICAL: Always ensure muteState is correct before playing
                    if mode == .mediaCell, let player = player {
                        player.isMuted = MuteState.shared.isMuted
                        // Applied mute state after infrastructure restart
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
        guard isVisible, isActuallyVisible else { 
            // Skipping - not visible
            return 
        }

        // Ensure we don't get stuck showing the explicit "Video paused" overlay.
        // Visible videos should either show last-frame/spinner placeholders or the player itself.
        isPlayerDetached = false

        // CRITICAL FIX: After short background, AppDelegate clears all players via
        // clearVideoPlayersForBackgroundRecovery(), which sets currentItem to nil.
        // Videos may be stuck in loading state or have no player. We need to recreate them.
        let playerMissing = (player == nil)
        let itemMissing = (player?.currentItem == nil)
        let timeInvalid = !(player?.currentTime().seconds.isFinite ?? true)
        let broken = itemMissing || timeInvalid || isPlayerBroken()
        
        // For videos that should be loaded but don't have a player, or have a broken player, recreate
        // Also reset stuck loading states - after background recovery, loading state might be stuck
        let needsRecreation = (playerMissing && shouldLoadVideo) || broken
        let hasStuckLoading = loadingState.isLoading && (playerMissing || broken)
        
        // Checking visible video state

        if needsRecreation || hasStuckLoading {
            // ONLY set recovery cover for videos that actually need recreation
            // Intact players don't need the spinner - they're already working fine
            isHoldingRecoveryCover = true
            if hasStuckLoading {
                loadingState = .idle
            }
            
            print("⚠️ [VIDEO RELOAD VISIBLE] Player missing/broken for \(mid) (playerMissing: \(playerMissing), itemMissing: \(itemMissing), timeInvalid: \(timeInvalid)) - recreating")

            // Clean up time observer if attached.
            if let observer = timeObserver, let observerPlayer = timeObserverPlayer {
                observerPlayer.removeTimeObserver(observer)
            }
            timeObserver = nil
            timeObserverPlayer = nil

            // Force fresh creation.
            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey, force: true)
            player?.pause()
            player = nil
            loadingState = .idle
            playbackState = .notStarted

            // Setup player - this will recreate it and properly initialize
            setupPlayer()
            
            // CRITICAL: After background recovery, ensure videos that should be playing actually start.
            // Add a delayed check to catch cases where videos get stuck in loading state.
            Task { @MainActor in
                // Wait for player to be created and ready
                var attempts = 0
                while (self.player == nil || self.loadingState.isLoading) && attempts < 30 {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                    attempts += 1
                }
                
                // Check if player is ready and should be playing
                guard let player = self.player,
                      let playerItem = player.currentItem,
                      playerItem.status == .readyToPlay,
                      self.isVisible,
                      self.shouldLoadVideo else {
                    return
                }
                
                // Check if loading state is stuck
                if self.loadingState.isLoading {
                    let hasBufferedData = !playerItem.loadedTimeRanges.isEmpty
                    let bufferedDuration = self.bufferedTimeAhead(for: playerItem, player: player)
                    
                    if hasBufferedData && bufferedDuration >= self.firstFrameMinimumBuffer {
                        self.loadingState = .loaded
                        self.retryAttempts = 0
                        if self.mode == .mediaCell {
                            self.hasInitialized = true
                        }
                    }
                }
                
                // CRITICAL: Check if coordinator commanded playback while loading
                // This handles the case where play command arrives before player is ready
                if self.mode == .mediaCell && self.coordinatorWantsToPlay && self.loadingState.isLoaded && player.rate == 0 {
                    print("▶️ [FOREGROUND RECOVERY] Playing video as coordinator requested (delayed)")
                    player.isMuted = MuteState.shared.isMuted
                    player.play()
                    self.playbackState = .playing
                } else if self.currentAutoPlay && self.loadingState.isLoaded {
                    // Fallback: If video should be playing, ensure it starts
                    let noOverlaysActive = !self.isCoveredByOverlay
                    let noDetailViewActive = !DetailVideoManager.shared.isDetailViewActive()

                    if noOverlaysActive && noDetailViewActive {
                        self.checkPlaybackConditions(autoPlay: true, isVisible: true)
                    }
                }

                // Start polling to release the cover once frames render again.
                self.scheduleRecoveryCoverRelease(reason: "reloadVisibleVideosOnlyDelayed")
            }
        } else if player != nil {
            // Player is intact; re-evaluate autoplay conditions.
            // CRITICAL: Don't unconditionally refresh view to avoid flicker.
            // Use delayed check to detect if layer is actually stale (similar to recoverFromBackground).
            // Most intact players will work fine without view refresh.
            
            // CRITICAL FIX: Check if loading state is stuck even though player is ready
            // This can happen after long background when KVO observers don't fire properly
            if loadingState.isLoading, let playerItem = player?.currentItem,
               playerItem.status == .readyToPlay, !playerItem.loadedTimeRanges.isEmpty {
                let bufferedDuration = bufferedTimeAhead(for: playerItem, player: player!)
                if bufferedDuration >= firstFrameMinimumBuffer {
                    // Loading state stuck after background - fixing
                    loadingState = .loaded
                    retryAttempts = 0
                }
            }
            
            // CRITICAL FIX: Reset finished videos to beginning after foreground recovery
            // For short backgrounds, players are preserved but positions stay at the end
            // This causes videos to show spinner but not play (they're already finished)
            var needsSeekBeforePlay = false
            if let player = player, let item = player.currentItem, item.status == .readyToPlay {
                let duration = item.duration.seconds
                let currentTime = player.currentTime().seconds
                
                // Check if video is finished (within 0.5s of end)
                if !duration.isNaN && !duration.isInfinite && duration > 0 {
                    let isFinished = currentTime >= (duration - 0.5)
                    if isFinished {
                        print("🔄 [FOREGROUND RECOVERY] Resetting finished video \(mid) from \(String(format: "%.1f", currentTime))s to beginning")
                        needsSeekBeforePlay = true
                        isSeekingToBeginning = true  // Mark as seeking to prevent health checks
                        
                        // CRITICAL: Seek is async - must wait for completion before playing
                        // Otherwise player is still at old position when play() is called, causing immediate finish
                        let shouldPlay = mode == .mediaCell && coordinatorWantsToPlay && loadingState == .loaded
                        let videoMid = mid  // Capture for logging
                        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { completed in
                            guard completed else {
                                Task { @MainActor in
                                    self.isSeekingToBeginning = false  // Clear flag even on failure
                                }
                                return
                            }
                            Task { @MainActor in
                                self.playbackState = .notStarted  // Clear finished state after seek completes
                                self.isSeekingToBeginning = false  // Seek complete, safe to check health again
                                print("✅ [FOREGROUND RECOVERY] Seek completed for \(videoMid)")
                                
                                // Now play if coordinator wants to
                                if shouldPlay, let player = self.player, player.rate == 0 {
                                    print("▶️ [FOREGROUND RECOVERY] Playing video after seek completion")
                                    player.isMuted = MuteState.shared.isMuted
                                    player.play()
                                    self.playbackState = .playing
                                }
                            }
                        }
                    }
                }
            }
            
            // CRITICAL FIX: Check if video was playing before background and resume it
            // When app returns from background, handleStopAllVideos pauses the video but saves wasPlaying=true
            // We need to check this saved state and resume playback
            let cachedState = VideoStateCache.shared.getCachedPlaybackInfo(for: self.mid)
            let wasPlayingBeforeBackground = cachedState?.wasPlaying ?? false
            
            // CRITICAL FIX: For MediaCell, check if coordinator wants to play
            // DON'T play immediately if we're seeking - wait for seek completion
            if !needsSeekBeforePlay && mode == .mediaCell && coordinatorWantsToPlay && loadingState == .loaded {
                if let player = player, player.rate == 0 {
                    print("▶️ [FOREGROUND RECOVERY] Playing intact video as coordinator requested")
                    player.isMuted = MuteState.shared.isMuted
                    player.play()
                    playbackState = .playing
                }
            } else if !needsSeekBeforePlay {
                // Fallback: normal playback condition check (only if not seeking)
                checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
            }
            
            // CRITICAL FIX: After returning from background, explicitly restart playback if it was playing
            if let player = self.player, player.rate == 0 {
                // Check if video was playing before background OR coordinator wants to play
                let shouldResume = wasPlayingBeforeBackground || (mode == .mediaCell && coordinatorWantsToPlay) || currentAutoPlay
                
                if shouldResume {
                    // Check if video should be playing (coordinator controls MediaCell approval)
                    let actuallyVisible = !self.isCoveredByOverlay
                    let noDetailViewActive = !DetailVideoManager.shared.isDetailViewActive()
                    let isReady = player.currentItem?.status == .readyToPlay

                    if actuallyVisible && noDetailViewActive && isReady {
                        player.isMuted = MuteState.shared.isMuted
                        playWithResumeIfNeeded(player)
                        playbackState = .playing
                        // Resumed playback
                    } else {
                        // Cannot resume - conditions not met
                    }
                }
            }
            
            // Delayed check: only refresh if player appears to have stale layer
            // This prevents unnecessary flicker while still fixing actual black screen issues
            Task { @MainActor in
                // Give iOS a moment to re-wire the underlying layer pipeline after foregrounding
                try? await Task.sleep(nanoseconds: 250_000_000) // 0.25s
                
                // Only check if still visible and player still exists
                guard self.mode == .mediaCell, self.isVisible, self.isActuallyVisible else { return }
                guard let player = self.player, let item = player.currentItem else { return }
                
                // If player is actually broken, the normal recovery path will handle it
                if self.isPlayerBroken() { return }
                
                let statusReady = item.status == .readyToPlay
                let hasBufferedData = !item.loadedTimeRanges.isEmpty
                let bufferedAhead = self.bufferedTimeAhead(for: item, player: player)
                
                // Heuristic: refresh only if we're "ready" but have no frames buffered,
                // or if we're stuck waiting with insufficient buffer (indicates stale layer)
                let stuckWaiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate || item.isPlaybackBufferEmpty
                let shouldRefresh =
                    (statusReady && !hasBufferedData) ||
                    (stuckWaiting && bufferedAhead < self.firstFrameMinimumBuffer)
                
                if shouldRefresh {
                    self.representableId += 1
                } else {
                }
            }
        } else {
            // Player is nil but shouldLoadVideo is false - this is expected for non-playing videos
            // in a grid waiting for sequential playback. Just ensure state is clean.
        }
    }
    
    private func handleVideoLayerRefresh() {
        // This is called when DetailVideoManager detects screen lock recovery
        // Force view refresh for detail/fullscreen modes to reconnect AVPlayerViewController layer
        if mode == .tweetDetail || mode == .mediaBrowser {
            representableId += 1
            
            // Ensure player is in correct state
            if let player = player {
                player.isMuted = false
            }
        }
    }
    
    private func handleAppUserReady() {
        // This is called when app initialization completes
        // Force reload for any videos that were blocked waiting for initialization
        
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
            
            // Force reload by replacing the current item with a new one
            Task { @MainActor in
                player.pause()
                loadingState = .idle
                
                // Recreate the player
                do {
                    let newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(
                        for: url,
                        mediaType: mediaType
                    )
                    self.player = newPlayer
                    configurePlayer(newPlayer)
                    
                    // CRITICAL: Force AVPlayer to start loading data by calling play() then pausing
                    // Without this, progressive videos won't make network requests after recovery
                    // Note: preroll() doesn't work because player status is still .unknown
                    newPlayer.play()
                    // Immediately pause - we only want to trigger loading, not actual playback
                    // The KVO observers and normal visibility logic will handle playback
                    newPlayer.pause()
                } catch {
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
                            progressiveForwardBufferDuration: progressiveForwardBufferDuration,
                            // Only fullscreen auto-plays inside AVPlayerViewController.
                            // TweetDetail playback is driven by `checkPlaybackConditions` after we restore seek.
                            shouldAutoPlay: mode == .mediaBrowser
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
                
                // MediaCell UX: last-frame placeholder used ONLY for background recovery cover.
                if mode == .mediaCell, let frame = cachedLastFrame {
                    let item = player.currentItem
                    let bufferedAhead = item.map { bufferedTimeAhead(for: $0, player: player) } ?? 0
                    let hasBufferedData = !(item?.loadedTimeRanges.isEmpty ?? true)
                    let readyForFirstFrame = (item?.status == .readyToPlay) && hasBufferedData && bufferedAhead >= firstFrameMinimumBuffer
                    
                    let waitingForData = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    let bufferEmpty = item?.isPlaybackBufferEmpty ?? false
                    let isFinished = (playbackState == .finished)
                    
                    // Show the cached frame when:
                    // 1. Holding recovery cover (background recovery)
                    // 2. Player explicitly detached (app lifecycle)
                    // 3. Video is being initialized (prevents black flicker when scrolling back)
                    // NOTE: Do NOT show cached frame when video naturally finishes - let it show the actual last frame from AVPlayer
                    let isInitializing = loadingState.isLoading && player.rate == 0
                    let shouldShowPlaceholder = isHoldingRecoveryCover || isPlayerDetached || isInitializing
                    
                    if shouldShowPlaceholder {
                        // IMPORTANT: This overlay must be tap-through so taps still reach the video layer
                        // (and ultimately the fullscreen tap handler).
                        Group {
                            Image(uiImage: frame)
                                .resizable()
                                .scaledToFill()
                                .clipped()
                                .overlay(Color.black.opacity(0.08))
                            
                            // Spinner over the cover frame during recovery/buffering.
                            // IMPORTANT: Never show spinner when the video is finished.
                            if !isFinished && (loadingState.isLoading || waitingForData || bufferEmpty || !readyForFirstFrame) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(1.1)
                                    .opacity(0.7)
                            }
                        }
                        .allowsHitTesting(false)
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
            // No player yet - ONLY show last frame during background recovery; otherwise black placeholder.
            ZStack {
                // Tap-through cover: let MediaCell's overlay / parent tap gestures still work
                // even while the player is being created.
                Group {
                    if mode == .mediaCell, isHoldingRecoveryCover, let frame = cachedLastFrame {
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
                }
                .allowsHitTesting(false)
                
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
            }
            return
        }
        
        // Ensure we have a video output attached to the current item (may have been nil during earlier setup).
        ensureVideoOutputAttachedIfNeeded(for: player)
        guard let output = videoOutput else {
            if reason == "willResignActive" {
            }
            return
        }
        
        // Only capture if we likely have a meaningful frame.
        guard item.status == .readyToPlay else {
            if reason == "willResignActive" {
            }
            return
        }
        if item.loadedTimeRanges.isEmpty {
            if reason == "willResignActive" {
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
        // Capture times on the main actor to avoid touching AVFoundation objects from the detached task.
        let playerTimeNow = player.currentTime()
        let itemTimeNow = item.currentTime()
        let hostTimeNow = CACurrentMediaTime()
        let hostItemTimeNow = output.itemTime(forHostTime: hostTimeNow)

        Task.detached(priority: .utility) {
            // IMPORTANT: On willResignActive, host-time mapping can drift and player/item times can jump.
            // We never want to overwrite a good cached frame with a "way off" one.
            //
            // Strategy:
            // - If resign-active: only accept a *fresh* host-time pixel buffer; otherwise, skip caching.
            // - Otherwise: try player time with small backoffs, then item time, then host-time.
            var candidateTimes: [CMTime] = []
            if reason == "willResignActive" {
                if hostItemTimeNow.isValid, output.hasNewPixelBuffer(forItemTime: hostItemTimeNow) {
                    candidateTimes = [hostItemTimeNow]
                } else {
                    // Keep the previous cached frame; don't overwrite with something stale/off.
                    return
                }
            } else {
                let base = playerTimeNow
                let backoffs: [Double] = [0.0, -0.08, -0.20, -0.40]
                for d in backoffs {
                    let t = CMTime(seconds: max(0, base.seconds + d), preferredTimescale: 600)
                    if t.isValid { candidateTimes.append(t) }
                }
                if itemTimeNow.isValid { candidateTimes.append(itemTimeNow) }
                if hostItemTimeNow.isValid { candidateTimes.append(hostItemTimeNow) }
            }

            var pixelBuffer: CVPixelBuffer? = nil
            var displayTime = CMTime.zero

            for t in candidateTimes {
                // Don't require "hasNewPixelBuffer" here; we just want the nearest available decoded frame.
                if let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &displayTime) {
                    pixelBuffer = pb
                    break
                }
            }

            guard let pixelBuffer else {
                if reason == "willResignActive" {
                }
                return
            }
            
            // Validate pixel buffer dimensions before processing
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            guard width > 0, height > 0, width < 10000, height < 10000 else {
                if reason == "willResignActive" {
                }
                return
            }
            
            guard let image = VideoFrameExtractor.makeDownscaledUIImage(from: pixelBuffer, maxDimension: 720) else {
                if reason == "willResignActive" {
                }
                return
            }

            // Guard against black placeholder captures (common during backgrounding/transition frames).
            // If the capture is mostly black, keep the previous cached frame instead of overwriting it.
            if VideoFrameExtractor.isMostlyBlack(image) {
                if reason == "willResignActive" {
                }
                return
            }
            
            // Swift 6: freeze values before actor hop.            
            await MainActor.run {
                VideoLastFrameCache.shared.set(image, for: mid)
                self.lastFrameVersion += 1
                if reason == "willResignActive" {
                } else {
                }
            }
        }
    }

    /// After a video finishes, some files show a black end-frame. This captures a non-black frame
    /// by scanning backward from the end and caching the first frame with content.
    @MainActor
    private func captureLastFrameNearEndIfPossible(reason: String) async {
        guard mode == .mediaCell else { return }
        guard isAnyVideoMedia else { return }
        guard let player = player, let item = player.currentItem else { return }

        ensureVideoOutputAttachedIfNeeded(for: player)
        guard let output = videoOutput else { return }

        guard item.status == .readyToPlay else { return }
        guard !item.loadedTimeRanges.isEmpty else { return }

        // Pick an "end" anchor that works for both HLS and progressive.
        let durationSeconds = item.duration.seconds.isFinite ? item.duration.seconds : 0
        let currentSeconds = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
        let endSeconds = durationSeconds > 0.5 ? durationSeconds : max(currentSeconds, item.currentTime().seconds)

        // IMPORTANT: AVPlayerItemVideoOutput only has *recently decoded* frames.
        // After finishing, asking for "end - 2s" often returns nil/black because that frame was never decoded.
        // Instead: seek slightly backwards (while paused) to force decoding, then snapshot.
        let seekBackoffs: [Double] = [0.10, 0.25, 0.50, 0.90, 1.40, 2.20, 3.20]

        func seekAsync(to time: CMTime) async -> Bool {
            await withCheckedContinuation { cont in
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    cont.resume(returning: finished)
                }
            }
        }

        for back in seekBackoffs {
            let target = max(0, endSeconds - back)
            let t = CMTime(seconds: target, preferredTimescale: 600)
            guard t.isValid else { continue }

            let ok = await seekAsync(to: t)
            guard ok else { continue }

            // Give AVFoundation a beat to produce a decoded frame at the new time.
            // (This stays paused; we just want a frame.)
            try? await Task.sleep(nanoseconds: 30_000_000) // 0.03s

            var displayTime = CMTime.zero
            // Prefer the current item time after seek.
            let itemTime = item.currentTime()
            guard let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) else { continue }
            
            // Validate pixel buffer dimensions before processing
            let pbWidth = CVPixelBufferGetWidth(pb)
            let pbHeight = CVPixelBufferGetHeight(pb)
            guard pbWidth > 0, pbHeight > 0, pbWidth < 10000, pbHeight < 10000 else { continue }
            
            guard let img = VideoFrameExtractor.makeDownscaledUIImage(from: pb, maxDimension: 720) else { continue }
            // Slightly stricter threshold here; end-frames can be near-black.
            if VideoFrameExtractor.isMostlyBlack(img, luminanceThreshold: 0.08) { continue }

            VideoLastFrameCache.shared.set(img, for: mid)
            lastFrameVersion += 1
            return
        }
    }
    
    // MARK: - Player Setup
    private func validateAndConfigureExistingPlayer() {
        guard let player = player else {
            // No player to validate
            return
        }
        
        // Validating existing player
        
        // Check if player item exists and is valid
        if let playerItem = player.currentItem {
            switch playerItem.status {
            case .readyToPlay:
                configurePlayer(player)
            case .failed:
                handleError(strategy: .loadFailure)
            case .unknown:
                // Configure the player anyway - KVO in AVPlayerViewControllerRepresentable will trigger play when ready
                configurePlayer(player)
            @unknown default:
                configurePlayer(player)
            }
        } else {
            // No player item, setting up new player
            if loadingState.isLoading {
                loadingState = .idle
            }
            setupPlayer()
        }
    }
    
    private func setupPlayer() {
        // CRITICAL: Prevent duplicate setup calls - check if already loading
        if loadingState.isLoading {
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
                // For tweetDetail mode, always unmute and ensure restore happens before any playback.
                existingPlayer.isMuted = false
                self.configurePlayer(existingPlayer)
                return
            }
            
            // Different video or no singleton - create an INDEPENDENT player and store in singleton.
            // IMPORTANT: Do NOT reuse SharedAssetCache's cached AVPlayer here, otherwise MediaCell's
            // onDisappear() will pause the same player instance and TweetDetail will "play briefly then stop".
            
            // CRITICAL: Check for cached player and reuse its asset to avoid network timeout
            if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: mid),
               let cachedPlayerItem = cachedPlayer.currentItem {
                let asset = cachedPlayerItem.asset
                let playerItem = AVPlayerItem(asset: asset)
                let newPlayer = AVPlayer(playerItem: playerItem)
                newPlayer.isMuted = false
                
                // Created independent AVPlayer, storing in singleton
                
                // Stop old singleton player if exists
                DetailVideoManager.shared.currentPlayer?.pause()
                
                // Store new player in singleton
                DetailVideoManager.shared.currentPlayer = newPlayer
                DetailVideoManager.shared.currentVideoMid = mid
                
                self.player = newPlayer
                self.loadingState = .loaded
                self.configurePlayer(newPlayer)
                return
            }
            
            // No cached player - load fresh
            // Use .userInitiated for detail view (not in scrolling feed, user is focused on this video)
            Task.detached(priority: .userInitiated) {
                do {
                    let playerItem = try await SharedAssetCache.shared.getOrCreatePlayerItem(
                        for: uniquePlayerURL,
                        mediaID: mid,
                        mediaType: mediaType
                    )
                    let newPlayer = AVPlayer(playerItem: playerItem)
                    newPlayer.isMuted = false
                    
                    await MainActor.run {
                        // Stop old singleton player if exists
                        DetailVideoManager.shared.currentPlayer?.pause()
                        
                        // Store new player in singleton
                        DetailVideoManager.shared.currentPlayer = newPlayer
                        DetailVideoManager.shared.currentVideoMid = mid
                        
                        self.player = newPlayer
                        self.loadingState = .loaded
                        self.configurePlayer(newPlayer)
                    }
                } catch {
                    print("ERROR: Failed to create player: \(error.localizedDescription)")
                    await MainActor.run {
                        self.handleError(strategy: .loadFailure)
                    }
                }
            }
            return
        }

        // SPECIAL CASE: Embedded/quoted tweet video inside TweetDetailView.
        // Use an independent AVPlayer instance (fresh AVPlayerItem) so it does not share the feed MediaCell player.
        if mode == .embeddedDetail {
            // CRITICAL: Check for cached player and reuse its asset to avoid network timeout
            if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: mid),
               let cachedPlayerItem = cachedPlayer.currentItem {
                let asset = cachedPlayerItem.asset
                let playerItem = AVPlayerItem(asset: asset)
                let newPlayer = AVPlayer(playerItem: playerItem)
                // Respect global mute state for embedded previews
                newPlayer.isMuted = MuteState.shared.isMuted
                self.configurePlayer(newPlayer)
                return
            }
            
            // No cached player - load fresh
            Task.detached(priority: .userInitiated) {
                do {
                    let playerItem = try await SharedAssetCache.shared.getOrCreatePlayerItem(
                        for: uniquePlayerURL,
                        mediaID: mid,
                        mediaType: mediaType
                    )
                    let newPlayer = AVPlayer(playerItem: playerItem)
                    await MainActor.run {
                        // Respect global mute state for embedded previews
                        newPlayer.isMuted = MuteState.shared.isMuted
                        self.configurePlayer(newPlayer)
                    }
                } catch {
                    print("ERROR: Failed to create player: \(error.localizedDescription)")
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
        // CRITICAL: Skip VideoStateCache during error retries to prevent infinite loops with broken cached players
        if retryAttempts == 0, let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            // Found shared player
            
            // Apply mute state based on current mode
            if mode == .mediaCell {
                cachedState.player.isMuted = MuteState.shared.isMuted
            } else if mode == .mediaBrowser {
                cachedState.player.isMuted = false
            }
            
            restoreFromCache(cachedState)
            // loadingState will be set to .loaded in restoreFromCache
            return
        } else if retryAttempts > 0 {
            // Skipping cache check during retry - will load fresh
        }
        
        // SECOND: Always try async loading - SharedAssetCache handles cache vs network internally
        // This avoids synchronous file system operations on the main thread during scrolling
        Task.detached(priority: .userInitiated) {
            do {
                // Use uniquePlayerURL to ensure each tweet gets its own player instance
                let newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(for: uniquePlayerURL, mediaType: mediaType)

                // Apply mute state IMMEDIATELY after player creation, before returning to MainActor
                // This prevents any brief moment where the player might start with wrong audio state
                if await MainActor.run(body: { self.mode }) == .mediaCell {
                    let muteState = await MainActor.run { MuteState.shared.isMuted }
                    newPlayer.isMuted = muteState
                } else {
                    newPlayer.isMuted = false
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
                    self.handleError(strategy: .loadFailure)
                }
            }
        }
        return
    }
    
    private func restoreFromCache(_ cachedState: (player: AVPlayer, time: CMTime, wasPlaying: Bool, originalMuteState: Bool)) {
        
        // Early return if loading is disabled
        guard shouldLoadVideo else {
            // Loading disabled, skipping cache restoration
            return
        }
        
        // Validate cached player before using it
        guard let playerItem = cachedState.player.currentItem else {
            // Cached player has no currentItem; creating new player
            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey, force: true)
            loadingState = .idle  // Reset loading state before recreating
            setupPlayer()
            return
        }
        
        
        // Check if player item is in a failed state
        if playerItem.status == .failed {
            // Cached player item is in failed state; creating new player
            SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey, force: true)
            loadingState = .idle  // Reset loading state before recreating
            setupPlayer()
            return
        }
        
        // Check if player has buffered any data
        let hasBufferedData = !playerItem.loadedTimeRanges.isEmpty
        
        // For fullscreen/detail modes, ensure player has buffered data
        if mode == .mediaBrowser || mode == .tweetDetail {
            // Fullscreen/detail mode - trust player state, KVO will handle ready state
        } else {
            // For MediaCell mode, check player readiness but trust players with buffered data
            if playerItem.status != .readyToPlay {
                // If player has buffered data, it's transitioning and will be ready soon - use it!
                if hasBufferedData {
                    // Player not ready but has buffered data - will use it
                } else if playerItem.status == .failed {
                    // Only clear cache if player has FAILED, not if it's just loading
                    // Cached player item FAILED; creating new player
                    SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey, force: true)
                    loadingState = .idle  // Reset loading state before recreating
                    setupPlayer()
                    return
                } else {
                    // Status is .unknown (0) - for HLS videos with cached playlists, this is normal
                    // The player needs time to fetch segments. Let KVO handle it.
                    // Cached player item status not ready - giving it time to load
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
                // Paused playing cached player before restoring
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
                    // Video already at end
                    videoAlreadyFinished = true
                }
            }
        }
        
        // CRITICAL: Always set up observers for cached player
        // This is essential for sequential video playback - without observers, onVideoFinished never fires!
        // Setting up observers for cached player
        removePlayerObservers()
        setupPlayerObservers(cachedState.player)
        
        // Verify observer was set up successfully
        if mode == .mediaCell && videoCompletionObserver == nil && cachedState.player.currentItem != nil {
            print("⚠️ [VIDEO CACHE] videoCompletionObserver is nil after setupPlayerObservers for \(mid) - retrying")
            setupPlayerObservers(cachedState.player)
        }
        
        // CRITICAL: If video already finished, DON'T trigger callback here
        // The observer is already set up and will fire when the video finishes again
        // OR if we need to advance sequential playback, coordinator handles it
        // Directly calling handleVideoFinished here causes duplicate callbacks
        if videoAlreadyFinished {
            // Video was already finished - marking as finished
            self.playbackState = .finished
            // DON'T call handleVideoFinished here - it will be called by the observer if video finishes again
            // Or coordinator will handle advancing to next video if needed
        }
        
        // Restore the cached player (AFTER setting mute state and observers)
        self.player = cachedState.player
        
        // CRITICAL: Only increment representableId when player actually changed
        // This prevents unnecessary view recreation and recomposition that causes jumping
        // The AVPlayerLayerView.updateUIView will handle layer reattachment for the same player
        // Only force recreation when player object actually changes
        if playerChanged && mode == .mediaCell {
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
                configureAutomaticWaiting(for: cachedState.player)
            }
            
            // If player is at end or has invalid position, reset to beginning
            if isAtEnd || currentTime.seconds < 0 {
                // Player at end or invalid position - resetting to beginning
                let videoMid = self.mid
                cachedState.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    if !finished {
                        print("⚠️ [VIDEO CACHE] Seek to start failed for \(videoMid) - player may be broken")
                        Task { @MainActor in
                            // If even seek to zero fails, player is likely broken - clear cache
                            VideoStateCache.shared.clearCache(for: videoMid)
                        }
                    }
                }
            } else if cachedState.time.seconds > 0 {
                // If we have a cached position, seek to it
                // Seeking to cached position for fullscreen
                let videoMid = self.mid
                let seekTime = cachedState.time.seconds
                cachedState.player.seek(to: cachedState.time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    if !finished {
                        // Seek to saved position failed - just start from beginning instead
                        print("⚠️ [VIDEO CACHE] Seek to \(seekTime)s failed for \(videoMid) - starting from beginning")
                        Task { @MainActor in
                            VideoStateCache.shared.clearCache(for: videoMid)
                            cachedState.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    }
                }
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
            
            // Restore cached position
            let videoMid = self.mid
            let seekTime = cachedState.time.seconds
            let duration = cachedState.player.currentItem?.duration.seconds ?? 0
            
            // Log if cached position exceeds known duration (metadata may still be loading)
            if seekTime > duration && duration > 0 {
                print("⚠️ [VIDEO CACHE] Cached position \(String(format: "%.2f", seekTime))s exceeds current known duration \(String(format: "%.2f", duration))s for \(videoMid) - seeking anyway (AVPlayer will clamp if needed)")
            }
            
            // Use seek with tolerance for better reliability
            // AVPlayer will clamp the seek position to valid range if metadata is still loading
            let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
            cachedState.player.seek(to: cachedState.time, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
                if !finished {
                    // CRITICAL: Seek failed (common after background transitions)
                    // Instead of recreating, just start from beginning - much faster!
                    print("⚠️ [VIDEO CACHE] Seek to \(cachedState.time.seconds)s failed for \(videoMid) - starting from beginning instead")
                    
                    Task { @MainActor in
                        // Clear cached position so we start fresh
                        VideoStateCache.shared.clearCache(for: videoMid)
                        
                        // Seek to beginning - this should succeed even if position seek failed
                        cachedState.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { seekToZeroFinished in
                            if seekToZeroFinished {
                                // Successfully reset to beginning
                            } else {
                                print("❌ [VIDEO CACHE] Even seek to zero failed for \(videoMid) - player may be broken, will recreate on next attempt")
                            }
                        }
                    }
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
        }
    }

    private func bumpProgressiveBufferTarget(for item: AVPlayerItem?) {
        guard mediaType == .video else { return }
        guard progressiveBufferTargetIndex + 1 < progressiveBufferTargets.count else { return }
        progressiveBufferTargetIndex += 1
        applyProgressiveBufferTarget(to: item)
    }

    private func resetProgressiveBufferTarget(for item: AVPlayerItem?) {
        guard mediaType == .video else { return }
        guard progressiveBufferTargetIndex != 0 else { return }
        progressiveBufferTargetIndex = 0
        applyProgressiveBufferTarget(to: item)
    }
    
    private func configurePlayer(_ player: AVPlayer) {
        
        configureAutomaticWaiting(for: player)
        
        // MediaCell last-frame support: attach a video output so we can snapshot decoded frames
        // (for flicker-free placeholders during layer reattach / buffering).
        ensureVideoOutputAttachedIfNeeded(for: player)
        
        // CRITICAL: Reset finished videos when they come back into view
        // Check both playbackState AND player position (SwiftUI view is recreated on scroll)
        if mode == .mediaCell && (playbackState == .finished || isVideoAtEnd(player)) {
            // Resetting finished video to beginning
            // Clear any cached state and seek to beginning
            VideoStateCache.shared.clearCachedState(for: mid)
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
        }
        
        // CRITICAL: For MediaCell, pause playing shared players FIRST to prevent audio bleed
        if mode == .mediaCell && player.rate > 0 {
            player.pause()
        }
        
        // Configure player mute state based on mode
        applyMuteState(to: player)
        
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
        // For foreground recovery, skip incrementing representableId to avoid flicker - the view
        // will update naturally when player binding changes, and last frame placeholder covers the transition
        let playerChanged = self.player !== player
        if playerChanged && !hasRecoveredThisCycle {
            // Only increment for non-recovery cases (normal player changes during scrolling)
            self.representableId += 1
            self.viewConfigTimestamp = Date().timeIntervalSince1970
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
            // Player already ready with buffered data
        } else if !self.loadingState.isLoaded {
            self.loadingState = .loading  // Show spinner while video loads
        }
        self.playbackState = .notStarted
        
        // NOTE: We intentionally do NOT cache `player.currentTime()` here.
        // During foreground recovery, a freshly recreated player starts at ~0s and this block can
        // overwrite the real resume time captured in `cachePlayerStateForBackground()`, causing
        // MediaCell to restart from the beginning.
        //
        // Resume time is owned by background/visibility caching + the periodic time observer once playing.
        
        
        // CRITICAL: Verify observers are set up, retry if needed
        // This handles the case where setupPlayerObservers() returned early due to nil currentItem
        if mode == .mediaCell && videoCompletionObserver == nil && player.currentItem != nil {
            print("⚠️ [VIDEO CONFIGURE] videoCompletionObserver is nil but currentItem exists for \(mid) - retrying observer setup")
            setupPlayerObservers(player)
        }
        
        // CRITICAL: During foreground recovery, skip checkPlaybackConditions here to avoid duplicate playback
        // The KVO observers (status + buffer) will handle playback when the player is ready
        // This prevents flicker from multiple playback attempts
        if !hasRecoveredThisCycle {
            // TweetDetail: restore saved position BEFORE any playback to prevent "play then jump back".
            // For tweetDetail mode, wait for player item to be ready before checking if video finished
            if mode == .tweetDetail {
                // If player item is ready, check immediately
                if let playerItem = player.currentItem,
                   playerItem.status == .readyToPlay {
                    if startTweetDetailRestoreIfNeeded(for: player) {
                        return
                    }
                } else {
                    // Player item not ready yet - set up observer to check when ready
                    let playerItem = player.currentItem
                    if playerItem != nil {
                        // Wait for player item to become ready, then check
                        let capturedPlayer = player
                        Task { @MainActor in
                            var attempts = 0
                            while attempts < 50 {
                                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                                if let item = self.player?.currentItem,
                                   item.status == .readyToPlay,
                                   self.player === capturedPlayer {
                                    // If restore starts an async seek, it will re-trigger playback later.
                                    if self.startTweetDetailRestoreIfNeeded(for: capturedPlayer) {
                                        return
                                    }
                                    // No restore needed (or restore was a no-op): now that we're ready,
                                    // re-run playback conditions to ensure autoplay actually starts.
                                    self.checkPlaybackConditions(autoPlay: self.currentAutoPlay, isVisible: self.isVisible)
                                    return
                                }
                                attempts += 1
                            }
                            // If still not ready after waiting, give normal playback a chance (it will gate on readiness).
                            if self.player === capturedPlayer {
                                self.checkPlaybackConditions(autoPlay: self.currentAutoPlay, isVisible: self.isVisible)
                            }
                        }
                        return // Don't proceed with normal playback yet
                    }
                }
            }
            // Start playback if needed (normal flow, not recovery)
            checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
        }
    }
    
    /// PERFORMANCE FIX: Save current playback position (Twitter-style)
    /// Called whenever video state changes (pause/stop/disappear) instead of periodic polling
    /// This eliminates CPU overhead from periodic observers while ensuring position is always saved
    /// 
    /// - Parameters:
    ///   - player: The AVPlayer instance
    ///   - wasPlaying: Optional override for wasPlaying state (captures state before pause)
    ///   - reason: Debug reason for logging
    private func saveCurrentPosition(player: AVPlayer, wasPlaying: Bool? = nil, reason: String) {
        guard mode == .mediaCell else { return }
        guard player.currentItem != nil else { return }
        
        let currentTime = player.currentTime()
        
        // Only save if time is valid and video is not at the end
        guard currentTime.seconds.isFinite, currentTime.seconds > 0.25 else { return }
        
        // Don't save if video finished (at the end)
        if isVideoAtEnd(player) {
            return
        }
        
        // Determine wasPlaying state
        // If explicitly provided (e.g., from before-pause state), use that
        // Otherwise, check both player.rate AND playbackState
        let actuallyWasPlaying: Bool
        if let wasPlaying = wasPlaying {
            actuallyWasPlaying = wasPlaying
        } else {
            actuallyWasPlaying = (player.rate > 0) || (playbackState == .playing)
        }
        
        VideoStateCache.shared.cacheVideoState(
            for: mid,
            player: player,
            time: currentTime,
            wasPlaying: actuallyWasPlaying,
            originalMuteState: player.isMuted
        )
        
        // Saved video position
    }
    
    private func setupTimeObserver(for player: AVPlayer) {
        // REMOVED: Periodic time observer (every 2 seconds) - replaced with event-driven saving
        // Position is now saved on every pause/stop/disappear event (Twitter-style)
        // This eliminates continuous CPU overhead while ensuring position is always captured
        //
        // Previous implementation created a periodic observer that fired every 2 seconds on main thread.
        // This caused severe CPU slowdown as observers accumulated (100 videos = 50 callbacks/sec).
        //
        // New approach: Save position only when video state actually changes:
        // - When paused (handleCoordinatorPauseCommand, handleCoordinatorStopCommand)
        // - When stopped (handleStopAllVideos)
        // - When scrolled away (handleOnDisappear)
        // - When backgrounded (cachePlayerStateForBackground)
        //
        // Benefits:
        // - Zero continuous CPU overhead
        // - Position saved exactly when needed
        // - Same behavior as Twitter's video player
        
        // Store reference for compatibility
        timeObserverPlayer = player
    }
    
    private func setupPlayerObservers(_ player: AVPlayer) {
        guard let playerItem = player.currentItem else { 
            print("⚠️ [OBSERVER SETUP] Cannot setup observers for \(mid) - currentItem is nil")
            return 
        }
        
        // MediaCell last-frame support: ensure the video output is attached once a real item exists.
        // (configurePlayer() can run while currentItem is temporarily nil for some HLS paths.)
        ensureVideoOutputAttachedIfNeeded(for: player)
        
        // CRITICAL: Check if observer is already attached to this exact playerItem
        // Use object identity (===) to ensure we're checking the same instance
        let alreadySetup = (self.playerItem === playerItem && videoCompletionObserver != nil)
        
        if alreadySetup {
            // Observers already attached - skipping
            return
        }
        
        // Setting up observers
        
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
            Task { @MainActor in
                await self.handleVideoFinished()
            }
        }
        
        // Video completion observer attached
        
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
            print("⚠️ [PLAYBACK STALL] Video stalled for \(self.mid), waiting for data...")
            self.bumpProgressiveBufferTarget(for: playerItem)
            
            // UX: Show spinner when stalled
            DispatchQueue.main.async {
                self.loadingState = .loading
                // Showing spinner for stall
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
                    return
                }
                
                // Data available, resuming playback
                DispatchQueue.main.async {
                    if resumePlayer.rate == 0 {
                        // CRITICAL: Always ensure muteState is correct before playing in MediaCell
                        if self.mode == .mediaCell {
                            resumePlayer.isMuted = MuteState.shared.isMuted
                            // Applied mute state on playback resume
                        }
                        resumePlayer.play()
                        // Manually triggered play()
                    } else {
                        // Player already playing
                    }
                    
                    if self.loadingState.isLoading {
                        self.loadingState = .loaded
                        // Hiding spinner
                    }
                }
                
                // Clean up the temporary observer
                resumeObserver?.invalidate()
                resumeObserver = nil
            }
        }
        
        // Simple approach: Tell AVPlayer what to do and let IT handle the rest
        // For MediaCell mode, observe when player is ready and react accordingly
        if mode == .mediaCell || mode == .embeddedDetail {
            let shouldAutoPlay = self.currentAutoPlay && self.isVisible && self.shouldLoadVideo
            
            // Observe player status to know when it's ready
            playerItemStatusObserver = playerItem.observe(\.status, options: [.new, .initial]) { item, change in
                
                // KVO status updated
                
                // Check for failed status first
                if item.status == .failed {
                    print("❌ [KVO STATUS] Player FAILED for \(mid) - error: \(item.error?.localizedDescription ?? "unknown")")
                    DispatchQueue.main.async {
                        self.handleError(strategy: .loadFailure)
                    }
                    return
                }
                
                guard item.status == .readyToPlay else { 
                    // Not ready yet
                    return 
                }
                
                // CRITICAL: Ensure notification observers are set up when player becomes ready
                // This handles the case where currentItem was nil during initial setupPlayerObservers() call
                // which happens when restoring players from VideoStateCache
                if self.videoCompletionObserver == nil {
                    print("⚠️ [KVO STATUS] Player ready but videoCompletionObserver is nil for \(mid) - setting up observers now")
                    DispatchQueue.main.async {
                        if let player = self.player {
                            self.setupPlayerObservers(player)
                        }
                    }
                }
                
                // CRITICAL: For HLS videos, .readyToPlay fires BEFORE data is buffered
                // Check if we have buffered data before acting
                let hasBufferedData = !item.loadedTimeRanges.isEmpty
                // Player ready
                
                DispatchQueue.main.async {
                    // CRITICAL: Hide spinner if we have buffered data (buffer observer might have already fired)
                    if hasBufferedData && loadingState.isLoading {
                        // Data already buffered, hiding spinner
                        loadingState = .loaded
                        retryAttempts = 0  // Reset retry counter on successful load
                    }
                    
                    if shouldAutoPlay {
                        // CRITICAL: For MediaCell mode, NEVER auto-play on status ready
                        // VideoPlaybackCoordinator controls all playback via notifications
                        if self.mode == .mediaCell {
                            // NOT auto-playing - waiting for coordinator
                        } else {
                            // Non-MediaCell modes: use old auto-play logic
                            let actuallyVisible = !self.isCoveredByOverlay
                            let noDetailViewActive = !DetailVideoManager.shared.isDetailViewActive()

                            if actuallyVisible && noDetailViewActive {
                                // Check actual player state instead of time-based flag
                                guard player.rate == 0 && self.playbackState != .playing else {
                                    // Skipping playback start - already playing
                                    return
                                }
                                self.playWithResumeIfNeeded(player)
                                // Auto-playing (non-MediaCell mode)
                            } else if !actuallyVisible {
                                // NOT auto-playing - covered by overlay
                            } else if !noDetailViewActive {
                                // NOT auto-playing - detail view active
                            }
                        }
                    } else {
                        // Preroll to render first frame without playing
                        player.preroll(atRate: 0.0) { finished in
                            guard finished else { 
                                // Preroll failed, keeping observers active
                                return 
                            }
                            // Prerolled first frame
                        }
                    }
                }
            }
            
            // Observe buffered data to hide spinner when data arrives
            playerItemBufferObserver = playerItem.observe(\.loadedTimeRanges, options: [.new]) { item, change in
                
                let hasBufferedData = !item.loadedTimeRanges.isEmpty
                let bufferedDurationAhead = self.bufferedTimeAhead(for: item, player: player)
                
                DispatchQueue.main.async {
                    // UX FIX: Hide spinner as soon as we have enough buffered data to render the first frame
                    let hasEnoughData = hasBufferedData && bufferedDurationAhead >= firstFrameMinimumBuffer
                    
                    if hasEnoughData && loadingState.isLoading {
                        // Sufficient data arrived, showing first frame
                        
                        // CRITICAL: For MediaCell mode, NEVER auto-play on load
                        // VideoPlaybackCoordinator will send explicit play commands via notifications
                        // This prevents multiple videos from playing simultaneously
                        // Only non-MediaCell modes (mediaBrowser, embeddedDetail) can auto-play
                        if self.mode == .mediaCell {
                            // NOT auto-playing - waiting for coordinator
                            // First frame will render, but playback controlled by coordinator
                        } else {
                            // Non-MediaCell modes: use old auto-play logic
                            let actuallyVisible = !self.isCoveredByOverlay
                            let noDetailViewActive = !DetailVideoManager.shared.isDetailViewActive()
                            let shouldPlay = shouldAutoPlay && actuallyVisible && noDetailViewActive
                            
                            // Check actual player state instead of time-based flag
                            if shouldPlay && player.rate == 0 && self.playbackState != .playing {
                                self.playWithResumeIfNeeded(player)
                                // Auto-playing (non-MediaCell mode)
                            } else if !actuallyVisible {
                                // NOT auto-playing - covered by overlay
                            } else if !noDetailViewActive {
                                // NOT auto-playing - detail view active
                            }
                        }
                        
                        loadingState = .loaded
                        retryAttempts = 0  // Reset retry counter on successful load
                        
                        // Mark as initialized to prevent recomposition when scrolling
                        if mode == .mediaCell {
                            hasInitialized = true
                            
                            // CRITICAL: If coordinator commanded playback while video was loading, play now
                            if coordinatorWantsToPlay && player.rate == 0 {
                                // Playing as coordinator requested
                                player.volume = 0
                                player.play()
                                UIView.animate(withDuration: 0.3) {
                                    player.volume = 1.0
                                }
                                playbackState = .playing
                            }
                        }

                        // CRITICAL: If video was waiting to play, check playback conditions now
                        // This handles case where video became approved but was still loading
                        // However, skip if playback is already playing to avoid duplicate attempts
                        if self.currentAutoPlay && self.isVisible && self.mode == .mediaCell && player.rate == 0 && self.playbackState != .playing {
                            DispatchQueue.main.async {
                                self.checkPlaybackConditions(autoPlay: self.currentAutoPlay, isVisible: self.isVisible)
                            }
                        }
                        
                        // Keep observer active to detect stalls - it will be cleaned up when view disappears
                    } else if hasBufferedData && bufferedDurationAhead < firstFrameMinimumBuffer && loadingState.isLoading {
                        // Waiting for more buffer data
                    }
                }
            }
            
            // If already ready, trigger immediately
            // Initial check of player status
            if playerItem.status == .readyToPlay {
                let hasBufferedData = !playerItem.loadedTimeRanges.isEmpty
                let bufferedDuration = self.bufferedTimeAhead(for: playerItem, player: player)
                // Already ready with buffered data
                
                // Hide spinner if we have buffered data
                // CRITICAL FIX: For cached players, trust non-empty loadedTimeRanges even if bufferedDuration is 0
                // This handles the case where a reused player has buffered data but the duration calculation fails
                let hasSufficientBuffer = hasBufferedData && (bufferedDuration >= firstFrameMinimumBuffer || bufferedDuration == 0)
                
                if hasSufficientBuffer {
                    loadingState = .loaded
                    retryAttempts = 0  // Reset retry counter on successful load
                    // Mark as initialized to prevent recomposition when scrolling
                    if mode == .mediaCell {
                        hasInitialized = true
                    }
                    if bufferedDuration == 0 && hasBufferedData {
                        // Cached player with buffered data but 0 duration - trusting it's ready
                    } else {
                        // Hiding spinner immediately
                    }
                } else {
                    // Ready but waiting for buffer data
                }
                
                if shouldAutoPlay {
                    // For MediaCell, coordinator controls which video plays
                    // For other modes, approve by default
                    let approved = self.mode != .mediaCell

                    if approved {
                        // CRITICAL: Always ensure muteState is correct before playing in MediaCell
                        if self.mode == .mediaCell {
                            player.isMuted = MuteState.shared.isMuted
                            // Applied mute state
                        }
                        self.playWithResumeIfNeeded(player)
                        // Already ready - auto-playing (coordinator approved)
                    } else {
                        // NOT auto-playing - not approved by coordinator
                    }
                } else {
                    player.preroll(atRate: 0.0) { finished in
                        guard finished else { 
                            // Preroll failed, keeping observers active for retry
                            return 
                        }
                        // Already ready - prerolled
                    }
                }
            } else {
                // Not ready yet, waiting for KVO
            }
        }
    }
    
    private func cleanupFailedPlayer() {
        // Cleaning up failed player
        
        // CRITICAL: Clear VideoStateCache first - this is checked FIRST in setupPlayer()
        // Force clear even if visible - we're cleaning up a failed player!
        VideoStateCache.shared.clearCache(for: self.mid, force: true)
        
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
        
        // PERFORMANCE FIX: Remove periodic time observer to prevent CPU accumulation
        // This observer fires every 2 seconds - if not removed, hundreds of observers
        // can accumulate over time, causing severe CPU slowdown on main thread
        if let observer = timeObserver, let observerPlayer = timeObserverPlayer {
            observerPlayer.removeTimeObserver(observer)
        }
        timeObserver = nil
        timeObserverPlayer = nil
        
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
        
        // Clear caches using uniquePlayerURL to match caching key (force clear for error recovery)
        VideoStateCache.shared.clearCache(for: mid, force: true)
        SharedAssetCache.shared.removeInvalidPlayer(for: playerCacheKey, force: true)
        
        // CRITICAL: Clear disk cache on failure to force fresh fetch
        // With only 1 retry, we clear everything to maximize recovery chances
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
            
            // Automatic retry once only
            if retryAttempts < 1 {
                let retryDelay = 2.0 // 2 second delay

                // Keep showing spinner during retry by staying in loading state
                loadingState = .loading
                player = nil
                retryAttempts += 1

                Task { @MainActor in
                    // Check author health first
                    if let authorId = self.authorId {
                        do {
                            // Refresh user to check health
                            _ = try await HproseInstance.shared.fetchUser(authorId)
                        } catch {
                        }
                    }

                    try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))

                    // Only retry if still visible and should load
                    guard self.isVisible && self.shouldLoadVideo else {
                        return
                    }

                    self.loadingState = .idle
                    self.playbackState = .notStarted
                    self.setupPlayer()
                }
            } else {
                // CRITICAL: After 1 retry fails, mark as FAILED (not loading forever!)
                // This prevents memory leak from infinite retry attempts
                self.loadingState = .failed(retryCount: self.retryAttempts)
                self.player = nil
                
                // Clear all resources to prevent memory leak
                SharedAssetCache.shared.clearPlayerForMediaID(self.mid)
                
                print("❌ [MEMORY LEAK FIX] Player failed after retry, marked as failed: \(self.mid)")
            }
            
            // For fullscreen, try to restore from cache as last resort
            if mode == .mediaBrowser && retryAttempts >= 3 {
                restoreCachedVideoState()
            }
            
        case .manualReset, .networkRecovery:
            // CRITICAL: For manual reset, completely clean up the broken player
            // This ensures we don't reuse a broken cached player
            removePlayerObservers()
            cleanupFailedPlayer()
            
            // Clear from all caches to force fresh load
            SharedAssetCache.shared.clearAssetCache(for: mid)
            
            playbackState = .notStarted
            loadingState = .idle  // Reset to idle - setupPlayer() will set to .loading
            retryAttempts = 0  // Reset retry counter on manual/network recovery
            player = nil  // CRITICAL: Clear the broken player reference
            
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
    
    private func handleVideoFinished() async {
        // CRITICAL: Prevent duplicate calls - if already finished/in-flight, ignore.
        // This can happen if the notification fires multiple times.
        guard playbackState != .finished, !isHandlingFinishEvent else {
            print("⚠️ [VIDEO FINISHED] Video \(mid) already marked as finished - ignoring duplicate finish event")
            return
        }
        isHandlingFinishEvent = true
        
        print("🎬 [VIDEO FINISHED] Video finished playing for \(mid), mode: \(mode)")
        resetProgressiveBufferTarget(for: player?.currentItem)
        
        // CRITICAL: Immediately pause to prevent flicker when next video starts
        // This ensures smooth transition between videos
        player?.pause()
        loadingState = .loaded
        isHoldingRecoveryCover = false
        // Mark finished immediately to prevent any auto-restart logic from firing.
        playbackState = .finished

        // CRITICAL: Clear cached playback state when video finishes
        // This prevents stale "wasPlaying: true" state from causing issues
        // after background/foreground cycles
        // NOTE: We don't rewind here - video stays at last frame (better UX)
        // Rewind happens when video comes back into view (see setupPlayer)
        if mode == .mediaCell {
            player?.isMuted = MuteState.shared.isMuted
            VideoStateCache.shared.clearCachedState(for: mid)
            // Cleared cached state - will restart from beginning when scrolled back
        }
        
        // Notify the coordinator that video finished (for sequential playback)
        NotificationCenter.default.post(
            name: .videoDidFinishPlaying,
            object: nil,
            userInfo: ["videoMid": mid, "tweetId": parentTweetId ?? ""]
        )
        
        // CRITICAL: Check disableAutoRestart before calling callback
        // If disabled, video should stay paused at end (no loop, no advance to next)
        if disableAutoRestart {
            // Clear cached position so when this video scrolls back into view, it starts from zero naturally
            // Force clear even if video is still visible, to ensure clean restart
            VideoStateCache.shared.clearCache(for: mid, force: true)
            // Don't capture last frame here - AVPlayer already shows it naturally
            // Only capture when scrolling away (in onDisappear) to preserve for recovery
            return
        }
        
        // CRITICAL: For MediaCell sequential playback, call callback to advance to next video
        // Use a small delay to ensure the pause and state update complete first
        // This prevents the finished video from causing view updates during transition
        if let callback = onVideoFinished {
            // Small delay to ensure pause completes and prevent flicker
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                callback()
            }
        } else {
        }
        
        isHandlingFinishEvent = false
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
    
    /// REMOVED: Periodic health check that was running continuously
    /// Health checks now only run ONCE after app enters foreground via performDelayedHealthCheck()
    /// This eliminates continuous background processing and improves performance
    
    private func restoreCachedVideoState() {
        // Check if we have a cached state
        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            restoreFromCache(cachedState)
        } else {
            // Fallback: check SharedAssetCache for cached player (app restart scenarios)
            // Use uniquePlayerURL (with query params) to match caching key
            if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: playerCacheKey) {
                
                // CRITICAL: Prepare player state before using it
                if mode == .mediaCell {
                    // Pause if playing to prevent audio bleed
                    if cachedPlayer.rate > 0 {
                        cachedPlayer.pause()
                    }
                    cachedPlayer.isMuted = MuteState.shared.isMuted
                } else if mode == .mediaBrowser || mode == .tweetDetail {
                    cachedPlayer.isMuted = false
                }
                
                configurePlayer(cachedPlayer)
            }
        }
    }
    
    private func checkPlaybackConditions(autoPlay: Bool, isVisible: Bool) {
        // TweetDetail: if we're in the middle of restoring (seek-before-play), do not start playback yet.
        // This prevents any other lifecycle/change handlers from calling play() at t=0.
        if mode == .tweetDetail, isApplyingDetailRestore {
            return
        }
        
        // Validate and recover from invalid player states
        // These can occur due to background transitions, memory pressure, or AVFoundation issues
        if !validatePlayerState() {
            return
        }

        // TweetDetail: do not start playback until the item is ready.
        // Otherwise we can briefly play a few frames and then seek/rewind (e.g. "finished in MediaCell"),
        // which causes a momentary black flash.
        if mode == .tweetDetail {
            guard let player = player, let item = player.currentItem else { return }
            guard item.status == .readyToPlay else { return }
        }
        
        // Check if all conditions are met for autoplay
        // For fullscreen and tweetDetail modes, bypass shouldLoadVideo check.
        // For embeddedDetail (quoted video), treat like MediaCell and respect shouldLoadVideo.
        let shouldCheckLoading = (mode == .mediaCell || mode == .embeddedDetail) ? shouldLoadVideo : true
        
        // CRITICAL: For MediaCell, also check if video is actually visible (not covered by sheets/modals or detail views)
        // Use synchronous visibility check (presentedViewController) to avoid timer lag.
        let isActuallyVisibleOrFullscreen = (mode == .mediaCell || mode == .embeddedDetail) ? !isCoveredByOverlay : true
        let noDetailViewActive = mode != .mediaCell || !DetailVideoManager.shared.isDetailViewActive()
        
        if autoPlay && isVisible && isActuallyVisibleOrFullscreen && noDetailViewActive && player != nil && !loadingState.isLoading && shouldCheckLoading {
            
            // For MediaCell, coordinator controls playback via notifications
            // This prevents videos from auto-restarting - they wait for coordinator commands
            if mode == .mediaCell {
                // MediaCell videos don't auto-restart - wait for coordinator notification
                return
            }
            
            // For other modes, allow restart
            if mode != .mediaCell {
                // CRITICAL: If video was finished but should play again,
                // reset it ONLY if the video actually played to completion (no cached position exists)
                // This allows videos that were paused mid-playback to resume from their saved position
                if playbackState == .finished {
                    // Check if we have a saved position for this video (scrolled away before finishing)
                    let hasCachedPosition = VideoStateCache.shared.hasCachedPlaybackInfo(for: mid)
                    let cachedInfo = VideoStateCache.shared.getCachedPlaybackInfo(for: mid)
                    let duration = player?.currentItem?.duration.seconds ?? 0
                    let cachedTime = cachedInfo?.time.seconds ?? 0
                    let isNearEnd = duration > 0 && cachedTime > duration - 0.5
                    
                    // Only clear cache and restart if video actually finished (cached position is near end or no cache)
                    // This prevents restarting videos that were paused mid-playback when scrolling
                    if !hasCachedPosition || isNearEnd {
                        playbackState = .notStarted
                        VideoStateCache.shared.clearCache(for: mid)
                        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    } else {
                        playbackState = .notStarted
                        // Don't clear cache - let the resume logic below handle it
                    }
                }
            }
            
            // Activate audio session for video playback
            AudioSessionManager.shared.activateForVideoPlayback()
            
            // CRITICAL: Always ensure muteState is correct before playing
            // For MediaCell, always respect global mute state
            if mode == .mediaCell, let player = player {
                player.isMuted = MuteState.shared.isMuted
                // Applied mute state for MediaCell
            }
            
            // MediaCell: Trust player position - either at 0 (new player) or at cached position (from restoreFromCache)
            // DON'T seek to zero here - that would erase positions that restoreFromCache just set!
            if mode == .mediaCell && playbackState == .notStarted {
                // Player ready, letting VideoPlaybackCoordinator control playback
                // Position is already correct - do nothing
            }
            
            // CRITICAL: Check actual player position before playing
            let atEnd = isVideoAtEnd(player!)
            // Checking playback conditions
            
            // If video is at or near the end, rewind it FIRST
                if atEnd {
                    // Video at end, rewinding to start
                    player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    playbackState = .notStarted
                    // Small delay to ensure seek completes
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        if self.mode == .mediaBrowser {
                            self.playbackState = .playing
                        } else {
                            self.player?.volume = 0
                            self.player?.play()
                            if let player = self.player {
                                UIView.animate(withDuration: 0.3) {
                                    player.volume = 1.0
                                }
                            }
                            self.playbackState = .playing
                            // Playing after rewind
                        }
                    }
                } else if playbackState.hasFinished {
                    player?.seek(to: .zero) { finished in
                        guard finished else { return }
                        self.playbackState = .notStarted
                        // Play after rewinding
                        if self.mode == .mediaBrowser {
                            self.playbackState = .playing
                        } else {
                            self.player?.play()
                            if let player = self.player {
                                UIView.animate(withDuration: 0.3) {
                                    player.volume = 1.0
                                }
                            }
                            self.playbackState = .playing
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
                        player?.volume = 0
                        player?.play()
                        if let player = player {
                            UIView.animate(withDuration: 0.3) {
                                player.volume = 1.0
                            }
                        }
                        playbackState = .playing
                    }
                }
        } else {
            // autoPlay is false
            // For MediaCell mode: Videos should pause when off-screen (handled by visibility changes)
            // This preserves resources while maintaining playback state for correct resume
            // The playback state is managed by VideoPlaybackCoordinator, so when user scrolls back,
            // the correct video will resume from where it was paused
            if mode == .mediaCell {
                // Don't reset finished videos here - they may have legitimately played to completion
                // The AVPlayer instance might be shared between multiple SimpleVideoPlayer views
                // Resetting one video could corrupt the state of another video using the same player
                // Let each video manage its own state when it becomes active
            }
        }
    }
    
    /// Check if video is at or near the end
    /// - Parameters:
    ///   - player: The AVPlayer to check
    ///   - tolerance: Seconds from end to consider as "at end" (default: 0.5s)
    /// - Returns: True if video is within tolerance of the end
    private func isVideoAtEnd(_ player: AVPlayer, tolerance: Double = 0.5) -> Bool {
        guard let playerItem = player.currentItem else { return false }
        
        let currentTime = player.currentTime()
        let duration = playerItem.duration
        
        // Check if current time is very close to the end
        if duration.isValid && !duration.isIndefinite {
            let timeDifference = CMTimeSubtract(duration, currentTime)
            return CMTimeCompare(timeDifference, CMTime(seconds: tolerance, preferredTimescale: duration.timescale)) <= 0
        }
        
        return false
    }
    
    
    private func handleLoadingStateChange(newShouldLoadVideo: Bool) {
        
        if newShouldLoadVideo {
            // Loading enabled - set up player if needed
            if player == nil {
                // Reset loading state if stuck
                if loadingState.isLoading {
                    loadingState = .idle
                }
                setupPlayer()
            } else {
                // Player exists, validate and reconfigure it
                validateAndConfigureExistingPlayer()
                checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
            }
        } else {
            // Loading disabled - pause player
            player?.pause()
        }
    }
    
    
    /// Cache player state when going to background (but don't detach)
    private func cachePlayerStateForBackground() {
        guard let player = player else { 
            return 
        }
        
        // Store current state for later restoration
        // AVPlayer.rate can be 0 while buffering; use our logical playbackState too.
        let wasPlaying = (player.rate > 0) || (playbackState == .playing)
        let rawTime = player.currentTime()
        // Fallback: if player.currentTime reports 0/invalid at resign-active,
        // use the last cached playback time (kept even when players are cleared on foreground).
        let cachedTime = VideoStateCache.shared.getCachedPlaybackInfo(for: mid)?.time ?? .zero
        let currentTime: CMTime
        if rawTime.seconds.isFinite, rawTime.seconds > 0.25 {
            currentTime = rawTime
        } else if cachedTime.seconds.isFinite, cachedTime.seconds > 0.25 {
            currentTime = cachedTime
        } else {
            currentTime = rawTime.seconds.isFinite ? rawTime : .zero
        }
        
        
        // Cache the state for restoration (MediaCell only, NOT TweetDetail or MediaBrowser)
        // TweetDetail uses DetailVideoManager singleton and should not share players with MediaCell
        // MediaBrowser uses FullScreenVideoManager singleton and should not share players with MediaCell
        // CRITICAL: Don't cache if video is finished - we want it to start fresh
        // Trust playbackState as source of truth (not player position which may lag due to async seeks)
        let shouldSkipCaching = playbackState == .finished
        
        if mode == .mediaCell && !shouldSkipCaching {
            VideoStateCache.shared.cacheVideoState(
                for: mid,
                player: player,
                time: currentTime,
                wasPlaying: wasPlaying,
                originalMuteState: isMuted
            )
            // Saved state for background
        } else {
            // Skipping cache - video finished
        }
        
        // Pause the player but keep it attached
        player.pause()
    }
}

// MARK: - AVPlayerViewController Wrapper for Full Screen
        struct AVPlayerViewControllerRepresentable: UIViewControllerRepresentable {
            let player: AVPlayer?
            @Binding var isBuffering: Bool
            let mediaType: MediaType
            let progressiveForwardBufferDuration: Double
            let shouldAutoPlay: Bool
            
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
                                    // Video started playing
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
                                if shouldAutoPlay {
                                    player.play()
                                }
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
                            // Player item in failed state
                        }
                    } else {
                        // Player has no current item
                    }
                } else {
                    print("ERROR: AVPlayerViewController created with nil player!")
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
                                    // Video started playing in updateUIViewController
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
                            if shouldAutoPlay {
                                player.play()
                            }
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
                                    if shouldAutoPlay {
                                        player.play()
                                    }
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
                                    if shouldAutoPlay {
                                        player.play()
                                    }
                                    context.coordinator.statusObserver?.invalidate()
                                    context.coordinator.statusObserver = nil
                                    // Buffering state will be updated by timeControlStatus observer
                                }
                            }
                        }
                    } else {
                        // Player item in failed state
                    }
                } else if player != nil {
                    // Player provided but has no current item
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

// MARK: - AnyViewModifier Helper

struct AnyViewModifier: ViewModifier {
    let modifier: (Content) -> AnyView
    
    init<V: View>(@ViewBuilder modifier: @escaping (Content) -> V) {
        self.modifier = { AnyView(modifier($0)) }
    }
    
    func body(content: Content) -> some View {
        modifier(content)
    }
}
