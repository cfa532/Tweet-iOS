//
//  SimpleVideoPlayer.swift
//  Tweet
//
//  Clean video player implementation with asset sharing
//

import SwiftUI
import AVKit
import AVFoundation

// MARK: - Asset Sharing System
/// Shared asset cache to avoid duplicate network requests
class SharedAssetCache: ObservableObject {
    static let shared = SharedAssetCache()
    private init() {}
    
    private var assetCache: [String: AVAsset] = [:]
    private var loadingTasks: [String: Task<AVAsset, Error>] = [:]
    
    /// Get or create asset for URL with HLS resolution
    func getAsset(for url: URL) async -> AVAsset {
        let cacheKey = url.absoluteString
        
        // Return cached asset if available
        if let cachedAsset = assetCache[cacheKey] {
            print("DEBUG: [SHARED ASSET CACHE] Cache HIT for: \(url.lastPathComponent)")
            return cachedAsset
        }
        
        // Check if already loading
        if let existingTask = loadingTasks[cacheKey] {
            print("DEBUG: [SHARED ASSET CACHE] Already loading: \(url.lastPathComponent)")
            do {
                return try await existingTask.value
            } catch {
                print("ERROR: [SHARED ASSET CACHE] Loading task failed: \(error)")
                // Fall through to create new task
            }
        }
        
        // Create new loading task
        print("DEBUG: [SHARED ASSET CACHE] Cache MISS - loading: \(url.lastPathComponent)")
        let loadingTask = Task<AVAsset, Error> {
            let resolvedURL = await resolveHLSURL(url)
            return AVAsset(url: resolvedURL)
        }
        
        loadingTasks[cacheKey] = loadingTask
        
        do {
            let asset = try await loadingTask.value
            assetCache[cacheKey] = asset
            loadingTasks.removeValue(forKey: cacheKey)
            print("DEBUG: [SHARED ASSET CACHE] Cached asset for: \(url.lastPathComponent)")
            return asset
        } catch {
            loadingTasks.removeValue(forKey: cacheKey)
            print("ERROR: [SHARED ASSET CACHE] Failed to load asset: \(error)")
            // Return basic asset as fallback
            return AVAsset(url: url)
        }
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

// MARK: - Simple Video Player
struct SimpleVideoPlayer: View {
    let url: URL
    let mid: String
    var autoPlay: Bool = true
    var onVideoFinished: (() -> Void)? = nil
    let isVisible: Bool
    var contentType: String? = nil
    var cellAspectRatio: CGFloat? = nil
    var videoAspectRatio: CGFloat? = nil
    var showNativeControls: Bool = true
    var forceUnmuted: Bool = false // Force unmuted state (for full-screen mode)
    var onVideoTap: (() -> Void)? = nil // Callback when video is tapped
    var disableAutoRestart: Bool = false // Disable auto-restart when video finishes
    
    // Unified mode parameter
    enum Mode {
        case mediaCell // Normal cell in feed/grid
        case mediaBrowser // In MediaBrowserView (fullscreen browser)
        case fullscreen // Direct fullscreen mode
    }
    var mode: Mode = .mediaCell
    
    @EnvironmentObject var muteState: MuteState
    
    var body: some View {
        HLSDirectoryVideoPlayer(
            baseURL: url,
            mid: mid,
            isVisible: isVisible,
            isMuted: forceUnmuted ? false : muteState.isMuted,
            autoPlay: autoPlay,
            onVideoFinished: onVideoFinished,
            onVideoTap: onVideoTap,
            forceUnmuted: forceUnmuted,
            disableAutoRestart: disableAutoRestart,
            mode: mode
        )
    }
}

// MARK: - Clean Video Player
struct CleanVideoPlayer: View {
    let url: URL
    let mid: String
    let autoPlay: Bool
    let forceUnmuted: Bool
    let mode: SimpleVideoPlayer.Mode
    let onVideoFinished: (() -> Void)?
    let onVideoTap: (() -> Void)?
    
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @ObservedObject private var muteState = MuteState.shared
    
    var body: some View {
        Group {
            if let player = player {
                VideoPlayer(player: player)
                    .onTapGesture {
                        onVideoTap?()
                    }
            } else if isLoading {
                ProgressView("Loading video...")
            } else {
                Color.black
                    .overlay(
                        Image(systemName: "play.circle")
                            .font(.system(size: 40))
                            .foregroundColor(.white)
                    )
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
    
    private func setupPlayer() {
        Task {
            let sharedAsset = await SharedAssetCache.shared.getAsset(for: url)
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
                
                print("DEBUG: [CLEAN VIDEO PLAYER \(mid)] Created player using shared asset cache")
            }
        }
    }
}

// MARK: - HLS Directory Video Player
struct HLSDirectoryVideoPlayer: View {
    let baseURL: URL
    let mid: String
    let isVisible: Bool
    let isMuted: Bool
    let autoPlay: Bool
    let onVideoFinished: (() -> Void)?
    let onVideoTap: (() -> Void)?
    let forceUnmuted: Bool
    let disableAutoRestart: Bool
    let mode: SimpleVideoPlayer.Mode
    
    @State private var playlistURL: URL? = nil
    @State private var loading = true
    
    var body: some View {
        Group {
            if let playlistURL = playlistURL {
                CleanVideoPlayer(
                    url: playlistURL,
                    mid: mid,
                    autoPlay: autoPlay,
                    forceUnmuted: forceUnmuted,
                    mode: mode,
                    onVideoFinished: onVideoFinished,
                    onVideoTap: onVideoTap
                )
            } else if loading {
                ProgressView("Loading video...")
            } else {
                Color.clear
            }
        }
        .task {
            if playlistURL == nil && loading {
                loading = false
                // Run HLS resolution
                let url = await getHLSPlaylistURL(baseURL: baseURL)
                
                if let url = url {
                    await MainActor.run {
                        playlistURL = url
                        print("DEBUG: [HLS PLAYER \(mid)] Successfully resolved HLS playlist")
                    }
                } else {
                    await MainActor.run {
                        playlistURL = baseURL // Fallback to original URL
                        print("DEBUG: [HLS PLAYER \(mid)] Using fallback URL")
                    }
                }
            }
        }
    }
    
    private func getHLSPlaylistURL(baseURL: URL) async -> URL? {
        let urlString = baseURL.absoluteString
        
        // If it's already a direct video file, return as-is
        if urlString.hasSuffix(".mp4") || urlString.hasSuffix(".m3u8") {
            return baseURL
        }
        
        // Try to find HLS playlist files
        let masterURL = baseURL.appendingPathComponent("master.m3u8")
        let playlistURL = baseURL.appendingPathComponent("playlist.m3u8")
        
        // Check master.m3u8 first
        if await urlExists(masterURL) {
            return masterURL
        }
        
        // Check playlist.m3u8
        if await urlExists(playlistURL) {
            return playlistURL
        }
        
        // Fallback to original URL
        return baseURL
    }
    
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
