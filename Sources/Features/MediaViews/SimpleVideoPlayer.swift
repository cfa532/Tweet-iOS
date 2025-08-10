//
//  SimpleVideoPlayer.swift
//  Tweet
//
//  Consolidated video player with asset sharing
//

import SwiftUI
import AVKit
import AVFoundation

// MARK: - Asset Sharing System
/// Shared asset cache to avoid duplicate network requests and provide immediate cached content
class SharedAssetCache: ObservableObject {
    static let shared = SharedAssetCache()
    private init() {}
    
    private let cacheQueue = DispatchQueue(label: "SharedAssetCache", attributes: .concurrent)
    private var assetCache: [String: AVAsset] = [:]
    private var playerCache: [String: AVPlayer] = [:]
    private var loadingTasks: [String: Task<AVAsset, Error>] = [:]
    private var cacheTimestamps: [String: Date] = [:]
    
    /// Get cached player immediately if available, or create new one
    func getCachedPlayer(for url: URL) -> AVPlayer? {
        let cacheKey = url.absoluteString
        return cacheQueue.sync {
            return playerCache[cacheKey]
        }
    }
    
    /// Get or create asset for URL with HLS resolution
    func getAsset(for url: URL) async throws -> AVAsset {
        let cacheKey = url.absoluteString
        
        // Check if we have a cached asset
        if let cachedAsset = cacheQueue.sync(execute: { assetCache[cacheKey] }) {
            print("DEBUG: [SHARED ASSET CACHE] Using cached asset for: \(url.lastPathComponent)")
            return cachedAsset
        }
        
        // Check if there's already a loading task
        if let existingTask = cacheQueue.sync(execute: { loadingTasks[cacheKey] }) {
            print("DEBUG: [SHARED ASSET CACHE] Waiting for existing loading task for: \(url.lastPathComponent)")
            do {
                return try await existingTask.value
            } catch {
                print("DEBUG: [SHARED ASSET CACHE] Error waiting for existing task: \(error)")
                // Fall through to create new task
            }
        }
        
        // Create new loading task
        let task = Task<AVAsset, Error> {
            print("DEBUG: [SHARED ASSET CACHE] Creating new asset for: \(url.lastPathComponent)")
            let resolvedURL = await resolveHLSURL(url)
            let asset = AVAsset(url: resolvedURL)
            
            // Cache the asset
            await MainActor.run {
                self.assetCache[cacheKey] = asset
                self.cacheTimestamps[cacheKey] = Date()
                self.loadingTasks.removeValue(forKey: cacheKey)
            }
            
            print("DEBUG: [SHARED ASSET CACHE] Cached asset for: \(url.lastPathComponent)")
            return asset
        }
        
        // Store the task
        await MainActor.run {
            self.loadingTasks[cacheKey] = task
        }
        
        do {
            return try await task.value
        } catch {
            print("DEBUG: [SHARED ASSET CACHE] Error creating asset: \(error)")
            // Remove failed task
            await MainActor.run {
                self.loadingTasks.removeValue(forKey: cacheKey)
            }
            throw error
        }
    }
    
    /// Cache a player instance for immediate reuse
    func cachePlayer(_ player: AVPlayer, for url: URL) async {
        let cacheKey = url.absoluteString
        _ = await MainActor.run { () -> Void in
            self.playerCache[cacheKey] = player
            print("DEBUG: [SHARED ASSET CACHE] Cached player for: \(url.lastPathComponent)")
        }
    }
    
    /// Get cached player or create new one with asset
    func getOrCreatePlayer(for url: URL) async throws -> AVPlayer {
        // Try to get cached player first
        if let cachedPlayer = getCachedPlayer(for: url) {
            print("DEBUG: [SHARED ASSET CACHE] Using cached player for: \(url.lastPathComponent)")
            return cachedPlayer
        }
        
        // Create new player with asset
        let asset = try await getAsset(for: url)
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        
        // Cache the player for future use
        await cachePlayer(player, for: url)
        
        return player
    }
    
    /// Resolve HLS URL if needed
    private func resolveHLSURL(_ url: URL) async -> URL {
        let urlString = url.absoluteString
        
        // If already an m3u8 file, return as-is
        if urlString.hasSuffix(".m3u8") || urlString.hasSuffix(".mp4") {
            return url
        }
        
        // Try to find HLS playlist
        let masterURL = url.appendingPathComponent("master.m3u8")
        let playlistURL = url.appendingPathComponent("playlist.m3u8")
        
        if await urlExists(masterURL) {
            print("DEBUG: [SHARED ASSET CACHE] Found master.m3u8 for: \(url.lastPathComponent)")
            return masterURL
        }
        
        if await urlExists(playlistURL) {
            print("DEBUG: [SHARED ASSET CACHE] Found playlist.m3u8 for: \(url.lastPathComponent)")
            return playlistURL
        }
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
    
    /// Clear cache
    func clearCache() {
        Task { @MainActor in
            self.assetCache.removeAll()
            self.playerCache.removeAll()
            self.cacheTimestamps.removeAll()
            self.loadingTasks.values.forEach { $0.cancel() }
            self.loadingTasks.removeAll()
        }
        print("DEBUG: [SHARED ASSET CACHE] Cache cleared")
    }
    
    /// Preload video for immediate display
    func preloadVideo(for url: URL) {
        Task {
            do {
                _ = try await getOrCreatePlayer(for: url)
            } catch {
                print("DEBUG: [SHARED ASSET CACHE] Error preloading video: \(error)")
            }
        }
    }
    
    /// Preload asset only (for background loading)
    func preloadAsset(for url: URL) {
        Task {
            do {
                _ = try await getAsset(for: url)
            } catch {
                print("DEBUG: [SHARED ASSET CACHE] Error preloading asset: \(error)")
            }
        }
    }
    
    /// Get cache statistics
    func getCacheStats() -> (assetCount: Int, playerCount: Int) {
        return cacheQueue.sync {
            return (assetCache.count, playerCache.count)
        }
    }
}

// MARK: - Global Mute State
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
    var forceUnmuted: Bool = false // Force unmuted state (for full-screen mode)
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
    @ObservedObject private var muteState = MuteState.shared
    @State private var instanceId = UUID().uuidString.prefix(8)
    
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
        .onChange(of: muteState.isMuted) { newMuteState in
            if mode == .mediaCell && !forceUnmuted {
                player?.isMuted = newMuteState
            }
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
            // Additional restoration when app becomes active
            if wasPlayingBeforeBackground && isVisible && currentAutoPlay {
                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] App became active - ensuring playback restoration")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    // Slightly longer delay for more reliable restoration
                    if let player = player, player.rate == 0 {
                        print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Player was paused after background - restarting")
                        checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
                    }
                }
            }
        }
    }
    
    // MARK: Private Methods
    private func checkPlaybackConditions(autoPlay: Bool, isVisible: Bool) {
        // Check if all conditions are met for autoplay
        print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Checking conditions - autoPlay: \(autoPlay), isVisible: \(isVisible), player exists: \(player != nil), isLoading: \(isLoading), hasFinished: \(hasFinishedPlaying)")
        
        if autoPlay && isVisible && player != nil && !isLoading {
            if hasFinishedPlaying {
                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Restarting finished video")
                // Reset to beginning and play
                player?.seek(to: .zero)
                hasFinishedPlaying = false
                player?.play()
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
                        .onTapGesture {
                            onVideoTap?()
                        }
                        .onLongPressGesture {
                            print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Long press detected - reloading video")
                            retryLoad()
                    }
                } else {
                    VideoPlayer(player: player, videoOverlay: {
                        // Custom overlay that captures taps
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onVideoTap?()
                            }
                            .onLongPressGesture {
                                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Long press detected - reloading video")
                                retryLoad()
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
                // Step 1: Try to get cached player immediately
                if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: url) {
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Using cached player immediately")
                    await MainActor.run {
            self.player = cachedPlayer
                self.isLoading = false
                        self.loadFailed = false
                        self.retryCount = 0
                        
                        // Start playback if needed
                        checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
                    }
                    return
                }
                
                // Step 2: Get or create player with asset
                let newPlayer: AVPlayer
                do {
                    newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(for: url)
                } catch {
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Failed to get or create player: \(error)")
                    await MainActor.run {
                        self.handleLoadFailure()
                    }
                    return
                }
            
                await MainActor.run {
                    // Configure player for context
                    newPlayer.isMuted = forceUnmuted ? false : muteState.isMuted
                    
                    // Set up video finished observer
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                        object: newPlayer.currentItem,
                queue: .main
            ) { _ in
                        print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Video finished playing - disableAutoRestart: \(disableAutoRestart)")
                        
                        if !disableAutoRestart {
                            // Auto-restart immediately for fullscreen/detail contexts
                            print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Auto-restarting video immediately")
                            newPlayer.seek(to: .zero) { finished in
                                if finished {
                                    newPlayer.play()
                            }
                        }
                    } else {
                            // For MediaCell, just mark as finished for manual restart on reappearance
                            self.hasFinishedPlaying = true
                        }
                        
                        // Call the external callback if provided
                        if let onVideoFinished = onVideoFinished {
                            onVideoFinished()
                        }
                    }
                    
                    // Set up error observer
                    NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemFailedToPlayToEndTime,
                        object: newPlayer.currentItem,
                        queue: .main
                    ) { notification in
                        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                        print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Video failed to play to end - \(error?.localizedDescription ?? "unknown error")")
                        self.handleLoadFailure()
                    }
                    
                    // Monitor player item status for load failures
                    Task {
                        // Give the player a moment to start loading
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                        
                        await MainActor.run {
                            if let playerItem = newPlayer.currentItem, playerItem.status == .failed {
                                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Player item failed to load: \(playerItem.error?.localizedDescription ?? "unknown error")")
                                self.handleLoadFailure()
                            }
                        }
                    }
                    
                    self.player = newPlayer
                    self.isLoading = false
                    self.loadFailed = false
                    self.retryCount = 0
                    
                    // Start playback if needed
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid):\(instanceId)] Player ready - checking playback conditions")
                    checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
                    
                    print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Created player using shared asset cache")
                }
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
} 
