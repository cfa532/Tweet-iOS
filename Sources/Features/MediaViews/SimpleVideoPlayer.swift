//
//  SimpleVideoPlayer.swift
//  Tweet
//
//  Consolidated video player with asset sharing - Optimized for scroll performance
//

import SwiftUI
import AVKit
import AVFoundation

// MARK: - Background Video Loader
/// Handles all video loading operations in the background to prevent scroll blocking
class BackgroundVideoLoader: ObservableObject {
    static let shared = BackgroundVideoLoader()
    private init() {}
    
    private var loadingTasks: [String: Task<AVPlayer, Error>] = [:]
    private var playerCache: [String: AVPlayer] = [:]
    private let queue = DispatchQueue(label: "com.tweet.videoloader", qos: .userInitiated)
    
    /// Load video in background and return cached player when ready
    func loadVideo(for url: URL, mid: String) async throws -> AVPlayer {
        let cacheKey = url.absoluteString
        
        // Check cache first
        if let cachedPlayer = await getCachedPlayer(for: cacheKey) {
            print("DEBUG: [BACKGROUND LOADER] Using cached player for: \(mid)")
            return cachedPlayer
        }
        
        // Check if already loading
        if let existingTask = loadingTasks[cacheKey] {
            print("DEBUG: [BACKGROUND LOADER] Waiting for existing task for: \(mid)")
            return try await existingTask.value
        }
        
        // Create new background loading task
        let task = Task<AVPlayer, Error> {
            print("DEBUG: [BACKGROUND LOADER] Starting background load for: \(mid)")
            
            // Move all heavy operations to background queue
            return try await queue.asyncResult {
                // Resolve HLS URL in background
                let resolvedURL = try await self.resolveHLSURL(url)
                
                // Create asset in background
                let asset = AVAsset(url: resolvedURL)
                
                // Create player in background
                let playerItem = await AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: playerItem)
                
                // Cache the player
                await self.cachePlayer(player, for: cacheKey)
                
                print("DEBUG: [BACKGROUND LOADER] Background load completed for: \(mid)")
                return player
            }
        }
        
        loadingTasks[cacheKey] = task
        
        do {
            let player = try await task.value
            loadingTasks.removeValue(forKey: cacheKey)
            return player
        } catch {
            loadingTasks.removeValue(forKey: cacheKey)
            throw error
        }
    }
    
    @MainActor
    private func getCachedPlayer(for cacheKey: String) -> AVPlayer? {
        return playerCache[cacheKey]
    }
    
    @MainActor
    private func cachePlayer(_ player: AVPlayer, for cacheKey: String) {
        playerCache[cacheKey] = player
    }
    
    private func resolveHLSURL(_ url: URL) async throws -> URL {
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
    
    private func urlExists(_ url: URL) async -> Bool {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5.0 // Shorter timeout for better responsiveness
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

// MARK: - Async Result Extension
extension DispatchQueue {
    func asyncResult<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            self.async {
                Task {
                    do {
                        let result = try await operation()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}

// MARK: - Optimized Simple Video Player
struct SimpleVideoPlayer: View {
    // MARK: Required Parameters
    let url: URL
    let mid: String
    let isVisible: Bool
    
    // MARK: Optional Parameters
    var autoPlay: Bool = true
    var videoManager: VideoManager? = nil
    var onVideoFinished: (() -> Void)? = nil
    var contentType: String? = nil
    var cellAspectRatio: CGFloat? = nil
    var videoAspectRatio: CGFloat? = nil
    var showNativeControls: Bool = true
    var isMuted: Bool = false // Mute state passed from parent
    var onVideoTap: (() -> Void)? = nil
    var disableAutoRestart: Bool = false
    
    // MARK: Mode
    enum Mode {
        case mediaCell
        case mediaBrowser
        case fullscreen
    }
    var mode: Mode = .mediaCell
    
    // MARK: State - Minimized for better performance
    @State private var player: AVPlayer?
    @State private var isLoading = false
    @State private var hasFinishedPlaying = false
    @State private var loadFailed = false
    @State private var retryCount = 0
    @State private var wasPlayingBeforeBackground = false

    @State private var instanceId = UUID().uuidString.prefix(8)
    @State private var isLongPressing = false
    
    // MARK: Computed Properties
    private var isVideoPortrait: Bool {
        guard let ar = videoAspectRatio else { return false }
        return ar < 1.0
    }
    
    private var isVideoLandscape: Bool {
        guard let ar = videoAspectRatio else { return false }
        return ar > 1.0
    }
    
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
                    if let cellAR = cellAspectRatio {
                        let cellWidth = geometry.size.width
                        let cellHeight = cellWidth / cellAR
                        let needsVerticalPadding = videoAR < cellAR
                        let videoHeight = cellWidth / videoAR
                        let overflow = videoHeight - cellHeight
                        let pad = needsVerticalPadding && overflow > 0 ? overflow / 2 : 0
                        ZStack {
                            videoPlayerView()
                            .offset(y: -pad)
                            .aspectRatio(videoAR, contentMode: .fill)
                        }
                    } else {
                        videoPlayerView()
                        .aspectRatio(videoAR, contentMode: .fit)
                    }
                    
                case .mediaBrowser:
                    videoPlayerView()
                    .aspectRatio(videoAR, contentMode: .fit)
                    .frame(maxWidth: screenWidth, maxHeight: screenHeight)
                    
                case .fullscreen:
                    if isVideoPortrait {
                        ZStack {
                            videoPlayerView()
                            .aspectRatio(videoAR, contentMode: .fit)
                            .frame(maxWidth: screenWidth, maxHeight: screenHeight)
                        }
                        .onAppear {
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                        .onDisappear {
                            UIApplication.shared.isIdleTimerDisabled = false
                        }
                    } else if isVideoLandscape {
                        ZStack {
                            videoPlayerView()
                            .aspectRatio(videoAR, contentMode: .fit)
                            .frame(maxWidth: screenWidth - 2, maxHeight: screenHeight - 2)
                            .rotationEffect(.degrees(-90))
                            .scaleEffect(screenHeight / screenWidth)
                            .background(Color.black)
                        }
                        .onAppear {
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                        .onDisappear {
                            UIApplication.shared.isIdleTimerDisabled = false
                        }
                    } else {
                        ZStack {
                            videoPlayerView()
                            .aspectRatio(1.0, contentMode: .fit)
                            .frame(maxWidth: screenWidth, maxHeight: screenHeight)
                        }
                        .onAppear {
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                        .onDisappear {
                            UIApplication.shared.isIdleTimerDisabled = false
                        }
                    }
                }
            } else {
                videoPlayerView()
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .frame(maxWidth: screenWidth, maxHeight: screenHeight)
            }
        }
        .onAppear {
            // Start background loading immediately
            startBackgroundLoading()
        }
        .onDisappear {
            player?.pause()
        }
        .onChange(of: isMuted) { newMuteState in
            player?.isMuted = newMuteState
            print("DEBUG: [SIMPLE VIDEO PLAYER] Mute state updated: \(newMuteState) for video: \(mid)")
        }
        .onChange(of: currentAutoPlay) { shouldAutoPlay in
            checkPlaybackConditions(autoPlay: shouldAutoPlay, isVisible: isVisible)
            if !shouldAutoPlay {
                player?.pause()
            }
        }
        .onChange(of: isVisible) { visible in
            if visible {
                if loadFailed && retryCount < 3 {
                    startBackgroundLoading()
                } else {
                    checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: visible)
                }
            } else {
                player?.pause()
            }
        }
        .onChange(of: player) { newPlayer in
            if newPlayer != nil {
                checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            if let player = player {
                wasPlayingBeforeBackground = player.rate > 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            if wasPlayingBeforeBackground && isVisible && currentAutoPlay {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if wasPlayingBeforeBackground && isVisible && currentAutoPlay {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if let player = player, player.rate == 0 {
                        checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
                    }
                }
            }
        }
        .onDisappear {
            if let player = player {
                NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)
                NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: player.currentItem)
            }
        }
    }
    
    // MARK: Private Methods - Optimized for performance
    
    private func startBackgroundLoading() {
        // Only start loading if not already loading and no player exists
        guard !isLoading && player == nil else { return }
        
        isLoading = true
        loadFailed = false
        
        Task {
            do {
                let newPlayer = try await BackgroundVideoLoader.shared.loadVideo(for: url, mid: mid)
                
                await MainActor.run {
                    configurePlayer(newPlayer)
                }
            } catch {
                await MainActor.run {
                    handleLoadFailure()
                }
            }
        }
    }
    
    private func configurePlayer(_ player: AVPlayer) {
        player.isMuted = isMuted
        print("DEBUG: [SIMPLE VIDEO PLAYER] Player configured with mute state: \(isMuted) for video: \(mid)")
        player.seek(to: .zero)
        setupPlayerObservers(player)
        
        self.player = player
        self.isLoading = false
        self.loadFailed = false
        self.retryCount = 0
        self.hasFinishedPlaying = false
        
        checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
    }
    
    private func setupPlayerObservers(_ player: AVPlayer) {
        guard let playerItem = player.currentItem else { return }
        
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            if !disableAutoRestart {
                player.seek(to: .zero) { finished in
                    if finished {
                        player.play()
                    }
                }
            } else {
                self.hasFinishedPlaying = true
            }
            
            onVideoFinished?()
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            self.handleLoadFailure()
        }
    }
    
    private func checkPlaybackConditions(autoPlay: Bool, isVisible: Bool) {
        if autoPlay && isVisible && player != nil && !isLoading {
            // Apply current mute state
            player?.isMuted = isMuted
            print("DEBUG: [SIMPLE VIDEO PLAYER] Playback conditions checked - mute state: \(isMuted) for video: \(mid)")
            
            if hasFinishedPlaying {
                if !disableAutoRestart {
                    player?.seek(to: .zero)
                    hasFinishedPlaying = false
                    player?.play()
                }
            } else {
                player?.play()
            }
        }
    }
    
    private func handleLoadFailure() {
        loadFailed = true
        isLoading = false
        player = nil
    }
    
    private func retryLoad() {
        guard retryCount < 3 else { return }
        
        retryCount += 1
        loadFailed = false
        isLoading = true
        hasFinishedPlaying = false
        
        startBackgroundLoading()
    }
                    
    @ViewBuilder
    private func videoPlayerView() -> some View {
        Group {
            if let player = player {
                if showNativeControls {
                    VideoPlayer(player: player)
                        .clipped()
                        .contentShape(Rectangle())
                        .scaleEffect(isLongPressing ? 0.95 : 1.0)
                        .animation(.easeInOut(duration: 0.1), value: isLongPressing)
                        .onTapGesture {
                            onVideoTap?()
                        }
                        .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 50) {
                            retryLoad()
                        } onPressingChanged: { pressing in
                            isLongPressing = pressing
                        }
                } else {
                    VideoPlayer(player: player, videoOverlay: {
                        Color.clear
                            .contentShape(Rectangle())
                            .scaleEffect(isLongPressing ? 0.95 : 1.0)
                            .animation(.easeInOut(duration: 0.1), value: isLongPressing)
                            .onTapGesture {
                                onVideoTap?()
                            }
                            .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 50) {
                                retryLoad()
                            } onPressingChanged: { pressing in
                                isLongPressing = pressing
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
} 
