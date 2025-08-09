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
/// Shared asset cache to avoid duplicate network requests
class SharedAssetCache: ObservableObject {
    static let shared = SharedAssetCache()
    private init() {}
    
    private let cacheQueue = DispatchQueue(label: "SharedAssetCache", attributes: .concurrent)
    private var assetCache: [String: AVAsset] = [:]
    private var loadingTasks: [String: Task<AVAsset, Error>] = [:]
    
    /// Get or create asset for URL with HLS resolution
    func getAsset(for url: URL) async -> AVAsset {
        // For now, let's bypass caching to eliminate the crash
        // and create assets directly to identify the root cause
        print("DEBUG: [SHARED ASSET CACHE] Creating asset directly for: \(url.lastPathComponent)")
        
        let resolvedURL = await resolveHLSURL(url)
        let asset = AVAsset(url: resolvedURL)
        
        print("DEBUG: [SHARED ASSET CACHE] Created asset for: \(url.lastPathComponent)")
        return asset
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
            request.timeoutInterval = 3.0
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
    
    /// Clear cache
    func clearCache() {
        assetCache.removeAll()
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll()
        print("DEBUG: [SHARED ASSET CACHE] Cache cleared")
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
    @ObservedObject private var muteState = MuteState.shared
    
    // MARK: Computed Properties
    private var isVideoPortrait: Bool {
        guard let ar = videoAspectRatio else { return false }
        return ar < 1.0
    }
    
    private var isVideoLandscape: Bool {
        guard let ar = videoAspectRatio else { return false }
        return ar > 1.0
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
    }
    
    // MARK: Private Methods
    @ViewBuilder
    private func videoPlayerView() -> some View {
        Group {
            if let player = player {
                VideoPlayer(player: player)
                    .clipped()
                    .onTapGesture {
                        onVideoTap?()
                    }
            } else if isLoading {
                ProgressView("Loading video...")
                    .frame(maxWidth: .infinity, maxHeight: 200)
                    .background(Color.black.opacity(0.1))
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
            // Step 1: Resolve HLS if needed
            let resolvedURL = await resolveHLSURL(url)
            
            // Step 2: Get shared asset
            let sharedAsset = await SharedAssetCache.shared.getAsset(for: resolvedURL)
            
            // Step 3: Create player
            let playerItem = AVPlayerItem(asset: sharedAsset)
            let newPlayer = AVPlayer(playerItem: playerItem)
            
            await MainActor.run {
                // Configure player for context
                newPlayer.isMuted = forceUnmuted ? false : muteState.isMuted
                
                // Set up video finished observer
                if !forceUnmuted, let onVideoFinished = onVideoFinished {
                    NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemDidPlayToEndTime,
                        object: playerItem,
                        queue: .main
                    ) { _ in
                        onVideoFinished()
                    }
                }
                
                self.player = newPlayer
                self.isLoading = false
                
                // Start playback if needed
                if autoPlay {
                    newPlayer.play()
                }
                
                print("DEBUG: [SIMPLE VIDEO PLAYER \(mid)] Created player using shared asset cache")
            }
        }
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
            request.timeoutInterval = 3.0
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
