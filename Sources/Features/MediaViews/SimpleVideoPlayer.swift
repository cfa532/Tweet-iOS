//
//  SimpleVideoPlayer.swift
//  Tweet
//
//  A simpler video player implementation with HLS support
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

// Simple Video Player Cache - only cleans up when memory is high
class VideoPlayerCache: ObservableObject {
    static let shared = VideoPlayerCache()
    
    private var players: [String: AVPlayer] = [:]
    private var playerTimestamps: [String: Date] = [:]
    
    private init() {
        // Monitor memory warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        
        // Start periodic memory check
        startPeriodicMemoryCheck()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func getPlayer(for url: URL) -> AVPlayer? {
        let key = url.absoluteString
        if let player = players[key] {
            // Validate that the player is still functional
            if let playerItem = player.currentItem, playerItem.status == .readyToPlay {
                // Update last access timestamp
                playerTimestamps[key] = Date()
                return player
            } else {
                print("DEBUG: Cached player is invalid, removing from cache")
                removePlayer(for: url)
                return nil
            }
        }
        return nil
    }
    
    func isPlayerValid(for url: URL) -> Bool {
        let key = url.absoluteString
        if let player = players[key] {
            return player.currentItem?.status == .readyToPlay
        }
        return false
    }
    
    func getCacheStats() -> (totalPlayers: Int, validPlayers: Int) {
        let totalPlayers = players.count
        let validPlayers = players.values.filter { player in
            player.currentItem?.status == .readyToPlay
        }.count
        return (totalPlayers, validPlayers)
    }
    
    func setPlayer(_ player: AVPlayer, for url: URL) {
        let key = url.absoluteString
        players[key] = player
        playerTimestamps[key] = Date()
        print("DEBUG: Cached player for URL: \(key), total cached players: \(players.count)")
    }
    
    func removePlayer(for url: URL) {
        let key = url.absoluteString
        if let player = players[key] {
            player.pause()
            print("DEBUG: Removed player from cache for URL: \(key)")
        }
        players.removeValue(forKey: key)
        playerTimestamps.removeValue(forKey: key)
    }
    
    func clearOldPlayers(olderThan minutes: Int = 30) {
        let cutoffTime = Date().addingTimeInterval(-TimeInterval(minutes * 60))
        let keysToRemove = playerTimestamps.compactMap { key, timestamp in
            timestamp < cutoffTime ? key : nil
        }
        
        for key in keysToRemove {
            removePlayer(for: URL(string: key) ?? URL(string: "invalid")!)
        }
        
        print("VideoPlayerCache: Cleared \(keysToRemove.count) old video players")
    }
    
    func getMemoryUsage() -> Double {
        // Get current memory usage as percentage
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let memoryUsageMB = Double(info.resident_size) / 1024.0 / 1024.0
            // Estimate memory threshold (this is approximate)
            let estimatedThreshold = 1024.0 // 1GB as rough estimate
            return (memoryUsageMB / estimatedThreshold) * 100.0
        }
        
        return 0.0
    }
    
    @objc private func handleMemoryWarning() {
        print("VideoPlayerCache: Memory warning received, clearing old players")
        clearOldPlayers(olderThan: 20) // Clear players older than 20 minutes (increased from 10)
    }
    
    func forceReloadVideo(for url: URL) {
        print("VideoPlayerCache: Force reloading video for URL: \(url.absoluteString)")
        removePlayer(for: url)
    }
    
    private func startPeriodicMemoryCheck() {
        Timer.scheduledTimer(withTimeInterval: 120.0, repeats: true) { _ in // Increased from 60 seconds to 120 seconds
            let memoryUsage = self.getMemoryUsage()
            let stats = self.getCacheStats()
            print("VideoPlayerCache: Current memory usage: \(String(format: "%.1f", memoryUsage))%, Total players: \(stats.totalPlayers), Valid players: \(stats.validPlayers)")
            
            if memoryUsage > 85.0 { // Increased from 80% to 85%
                print("VideoPlayerCache: High memory usage detected (\(String(format: "%.1f", memoryUsage))%), clearing old players")
                self.clearOldPlayers(olderThan: 25) // Increased from 15 to 25 minutes
            } else if memoryUsage > 70.0 { // Increased from 60% to 70%
                print("VideoPlayerCache: Moderate memory usage (\(String(format: "%.1f", memoryUsage))%), clearing very old players")
                self.clearOldPlayers(olderThan: 60) // Increased from 45 to 60 minutes
            }
        }
    }
}

struct SimpleVideoPlayer: View {
    let url: URL
    var autoPlay: Bool = true
    var onTimeUpdate: ((Double) -> Void)? = nil
    var onMuteChanged: ((Bool) -> Void)? = nil
    let isVisible: Bool
    var contentType: String? = nil
    var cellAspectRatio: CGFloat? = nil
    var videoAspectRatio: CGFloat? = nil
    var showNativeControls: Bool = true
    var forceUnmuted: Bool = false // Force unmuted state (for full-screen mode)
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
                    if isHLSStream(url: url, contentType: contentType) {
                        HLSDirectoryVideoPlayer(
                            baseURL: url,
                            isVisible: isVisible,
                            isMuted: forceUnmuted ? false : muteState.isMuted,
                            onMuteChanged: onMuteChanged
                        )
                        .offset(y: -pad)
                        .aspectRatio(videoAR, contentMode: .fit)
                    } else {
                        VideoPlayerView(
                            url: url,
                            autoPlay: autoPlay && isVisible,
                            isMuted: forceUnmuted ? false : muteState.isMuted,
                            onMuteChanged: onMuteChanged,
                            onTimeUpdate: onTimeUpdate,
                            isVisible: isVisible,
                            showNativeControls: showNativeControls
                        )
                        .padding(.top, -pad)
                        .aspectRatio(videoAR, contentMode: .fit)
                    }
                }
            } else {
                ZStack {
                    if isHLSStream(url: url, contentType: contentType) {
                        HLSDirectoryVideoPlayer(
                            baseURL: url,
                            isVisible: isVisible,
                            isMuted: forceUnmuted ? false : muteState.isMuted,
                            onMuteChanged: onMuteChanged
                        )
                    } else {
                        VideoPlayerView(
                            url: url,
                            autoPlay: autoPlay && isVisible,
                            isMuted: forceUnmuted ? false : muteState.isMuted,
                            onMuteChanged: onMuteChanged,
                            onTimeUpdate: onTimeUpdate,
                            isVisible: isVisible,
                            showNativeControls: showNativeControls
                        )
                    }
                }
            }
        }
    }
    
    /// Check if the URL points to an HLS stream
    private func isHLSStream(url: URL, contentType: String?) -> Bool {
        print("DEBUG: Checking if URL is HLS stream: \(url.absoluteString), contentType: \(contentType ?? "nil")")
        
        // Primary detection: Check content type
        if let contentType = contentType?.lowercased() {
            if contentType == "hls_video" {
                print("DEBUG: Detected HLS by content type: \(contentType)")
                return true
            }
        }
        
        // IPFS URL detection: If URL contains /ipfs/ and content type is video, treat as HLS
        if url.absoluteString.contains("/ipfs/") {
            if let contentType = contentType?.lowercased(), contentType == "video" {
                print("DEBUG: Detected HLS by IPFS URL with video content type")
                return true
            }
        }
        
        // Fallback detection: Check for .m3u8 extension (for direct playlist URLs)
        if url.pathExtension.lowercased() == "m3u8" {
            print("DEBUG: Detected HLS by .m3u8 extension")
            return true
        }
        
        // Fallback detection: Check for HLS content type in URL
        if url.absoluteString.contains("playlist.m3u8") || url.absoluteString.contains("master.m3u8") {
            print("DEBUG: Detected HLS by playlist.m3u8 or master.m3u8 in URL")
            return true
        }
        
        // Fallback detection: Check for HLS-related query parameters
        if let query = url.query, query.contains("hls") || query.contains("stream") {
            print("DEBUG: Detected HLS by query parameters")
            return true
        }
        
        print("DEBUG: URL is not HLS stream")
        return false
    }
    
    /// Get the correct HLS playlist URL
    private func getHLSPlaylistURL(from url: URL) -> URL {
        print("DEBUG: Getting HLS playlist URL from: \(url.absoluteString)")
        
        // If URL already ends with .m3u8, return as is
        if url.pathExtension.lowercased() == "m3u8" {
            print("DEBUG: URL already ends with .m3u8, returning as is")
            return url
        }
        
        // If URL contains playlist.m3u8 or master.m3u8, return as is
        if url.absoluteString.contains("playlist.m3u8") || url.absoluteString.contains("master.m3u8") {
            print("DEBUG: URL contains playlist.m3u8 or master.m3u8, returning as is")
            return url
        }
        
        // For CID-based URLs (no file extension), try to detect multi-resolution HLS first
        if url.pathExtension.isEmpty {
            // Check if this is a multi-resolution HLS stream by trying master.m3u8 first
            let masterPlaylistURL = url.appendingPathComponent("master.m3u8")
            print("DEBUG: CID-based URL, trying master.m3u8 first: \(masterPlaylistURL.absoluteString)")
            
            // Note: We'll let AVPlayer handle the actual validation of the master playlist
            // If master.m3u8 doesn't exist, AVPlayer will fail gracefully and we can fall back
            return masterPlaylistURL
        }
        
        // For other URLs, try to append master.m3u8 first (for multi-resolution)
        let masterPlaylistURL = url.appendingPathComponent("master.m3u8")
        print("DEBUG: Appending master.m3u8 to URL: \(masterPlaylistURL.absoluteString)")
        return masterPlaylistURL
    }
    
    /// Test if an HLS playlist URL is accessible and valid
    private func testHLSPlaylist(url: URL) async -> Bool {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("DEBUG: HLS playlist HTTP response: \(httpResponse.statusCode)")
                print("DEBUG: HLS playlist content type: \(httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown")")
                
                // Check if we got a successful response
                guard httpResponse.statusCode == 200 else {
                    print("DEBUG: HLS playlist returned non-200 status: \(httpResponse.statusCode)")
                    return false
                }
            }
            
            if let content = String(data: data, encoding: .utf8) {
                print("DEBUG: HLS playlist content (first 1000 chars): \(String(content.prefix(1000)))")
                
                // Validate HLS playlist format
                let lines = content.components(separatedBy: .newlines)
                if lines.isEmpty {
                    print("DEBUG: HLS playlist is empty")
                    return false
                }
                
                // Check for required HLS header
                if !lines[0].trimmingCharacters(in: .whitespaces).hasPrefix("#EXTM3U") {
                    print("DEBUG: HLS playlist missing #EXTM3U header")
                    return false
                }
                
                // Check if this is a master playlist (contains #EXT-X-STREAM-INF)
                let isMasterPlaylist = lines.contains { $0.contains("#EXT-X-STREAM-INF") }
                print("DEBUG: HLS playlist type: \(isMasterPlaylist ? "Master" : "Media")")
                
                // For master playlists, check for variant streams
                if isMasterPlaylist {
                    let variantLines = lines.filter { $0.contains("#EXT-X-STREAM-INF") }
                    print("DEBUG: Master playlist contains \(variantLines.count) variant streams")
                    
                    if variantLines.isEmpty {
                        print("DEBUG: Master playlist has no variant streams")
                        return false
                    }
                } else {
                    // For media playlists, check for segments
                    let segmentLines = lines.filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    print("DEBUG: Media playlist contains \(segmentLines.count) segments")
                    
                    if segmentLines.isEmpty {
                        print("DEBUG: Media playlist has no segments")
                        return false
                    }
                }
            }
            
            return true
        } catch {
            print("DEBUG: Failed to fetch HLS playlist: \(error)")
            return false
        }
    }
}

/// HLSVideoPlayer with custom controls
struct HLSVideoPlayerWithControls: View {
    let videoURL: URL
    let isVisible: Bool
    let isMuted: Bool
    let onMuteChanged: ((Bool) -> Void)?
    
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var showControls = true
    @State private var playerMuted: Bool = false
    @State private var controlsTimer: Timer?
    
    init(videoURL: URL, isVisible: Bool, isMuted: Bool, onMuteChanged: ((Bool) -> Void)?) {
        self.videoURL = videoURL
        self.isVisible = isVisible
        self.isMuted = isMuted
        self.onMuteChanged = onMuteChanged
        self._playerMuted = State(initialValue: isMuted)
    }
    
    var body: some View {
        ZStack {
            if let player = player {
                VideoPlayer(player: player)
                    .overlay(
                        // Custom controls overlay
                        Group {
                            if showControls {
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
                    
                    Button("Retry") {
                        // Force reload the video
                        VideoPlayerCache.shared.forceReloadVideo(for: videoURL)
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
            // Toggle controls visibility
            withAnimation {
                showControls.toggle()
            }
            
            // Start auto-hide timer when controls are shown
            if showControls {
                startControlsTimer()
            } else {
                stopControlsTimer()
            }
            
            // If player is paused and we tap, also resume playback
            if let player = player, player.rate == 0 && isVisible {
                print("DEBUG: Resuming playback on tap")
                player.play()
                isPlaying = true
            }
        }
        .onAppear {
            setupPlayer()
        }
        .onChange(of: isVisible) { visible in
            if !visible {
                player?.pause()
            } else {
                // When becoming visible, always try to resume if we have a valid player
                if let player = player, VideoPlayerCache.shared.isPlayerValid(for: videoURL) {
                    // Resume playback if it was previously playing or if this is a new player
                    if isPlaying || player.rate == 0 {
                        print("DEBUG: Resuming playback for visible player")
                        player.play()
                        isPlaying = true
                    }
                } else {
                    print("DEBUG: Player became invalid, recreating...")
                    setupPlayer()
                }
            }
        }
        .onChange(of: isMuted) { newMuteState in
            print("DEBUG: HLS player isMuted parameter changed to \(newMuteState)")
            player?.isMuted = newMuteState
            playerMuted = newMuteState
        }
        .onChange(of: playerMuted) { newMuteState in
            // This is triggered when the user interacts with native controls
            if newMuteState != isMuted {
                print("DEBUG: HLS player mute state changed by user interaction to \(newMuteState)")
                onMuteChanged?(newMuteState)
            }
        }
        .onDisappear {
            // Don't destroy the player, just pause it
            player?.pause()
            stopControlsTimer()
        }
    }
    
    private func setupPlayer() {
        print("DEBUG: Setting up HLS player for URL: \(videoURL.absoluteString)")
        
        // Check if we already have a cached player
        if let cachedPlayer = VideoPlayerCache.shared.getPlayer(for: videoURL) {
            print("DEBUG: Using cached HLS player for URL: \(videoURL.absoluteString)")
            
            // Check if the cached player is still valid
            if let playerItem = cachedPlayer.currentItem, playerItem.status == .readyToPlay {
                self.player = cachedPlayer
                self.isLoading = false
                self.isPlaying = cachedPlayer.rate > 0
                self.duration = playerItem.duration.seconds
                
                // Update mute state
                cachedPlayer.isMuted = isMuted
                
                // Resume playback if visible and should be playing
                if isVisible {
                    if isPlaying {
                        print("DEBUG: Resuming cached player that was playing")
                        cachedPlayer.play()
                    } else if cachedPlayer.rate == 0 {
                        // If player is paused but should be playing, resume it
                        print("DEBUG: Resuming paused cached player")
                        cachedPlayer.play()
                        isPlaying = true
                    }
                }
                
                // Monitor the cached player to ensure it stays valid
                self.monitorPlayerStatus(cachedPlayer)
                return
            } else {
                print("DEBUG: Cached player is invalid, removing from cache and creating new one")
                VideoPlayerCache.shared.removePlayer(for: videoURL)
            }
        }
        
        isLoading = true
        errorMessage = nil
        
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
        }
        
        // Set up the player
        self.player = avPlayer
        
        // Cache the player immediately
        VideoPlayerCache.shared.setPlayer(avPlayer, for: videoURL)
        
        // Monitor player item status
        self.monitorPlayerStatus(avPlayer)
        
        // Auto-play the HLS stream
        avPlayer.play()
        self.isPlaying = true
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
                print("DEBUG: HLS player item is ready to play")
                self.isLoading = false
                self.duration = playerItem.duration.seconds
                timer.invalidate()
            case .failed:
                print("DEBUG: HLS player item failed: \(playerItem.error?.localizedDescription ?? "Unknown error")")
                if let error = playerItem.error as NSError? {
                    print("DEBUG: Error domain: \(error.domain), code: \(error.code)")
                    print("DEBUG: Error user info: \(error.userInfo)")
                    
                    // Try fallback to single-resolution playlist if master.m3u8 fails
                    if error.domain == "NSURLErrorDomain" && error.code == -1008 {
                        print("DEBUG: Master playlist failed, trying single-resolution fallback")
                        self.trySingleResolutionFallback()
                        timer.invalidate()
                        return
                    }
                    
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
    
    private func trySingleResolutionFallback() {
        print("DEBUG: Trying single-resolution fallback")
        
        // Get the base URL without master.m3u8
        let baseURL = videoURL.deletingLastPathComponent()
        let fallbackURL = baseURL.appendingPathComponent("playlist.m3u8")
        
        print("DEBUG: Fallback URL: \(fallbackURL.absoluteString)")
        
        // Test if this URL is accessible
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(from: fallbackURL)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    await MainActor.run {
                        self.setupFallbackPlayer(with: fallbackURL)
                    }
                    return
                }
            } catch {
                print("DEBUG: Fallback URL failed: \(error)")
            }
            
            // If fallback fails, show error
            await MainActor.run {
                self.errorMessage = "Unable to load video stream"
                self.isLoading = false
            }
        }
    }
    
    private func setupFallbackPlayer(with url: URL) {
        print("DEBUG: Setting up fallback player with URL: \(url.absoluteString)")
        
        // Create asset with hardware acceleration support
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetOutOfBandMIMETypeKey": "application/x-mpegURL",
            "AVURLAssetHTTPHeaderFieldsKey": ["Accept": "*/*"]
        ])
        
        // Create player item with asset
        let playerItem = AVPlayerItem(asset: asset)
        
        // Configure player item for better performance
        playerItem.preferredForwardBufferDuration = 10.0
        playerItem.preferredPeakBitRate = 0 // Let system decide
        
        // Create AVPlayer with the player item
        let fallbackPlayer = AVPlayer(playerItem: playerItem)
        
        // Enable hardware acceleration
        fallbackPlayer.automaticallyWaitsToMinimizeStalling = true
        
        // Set initial mute state
        fallbackPlayer.isMuted = isMuted
        
        // Add periodic time observer for progress updates
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        fallbackPlayer.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { time in
            currentTime = time.seconds
        }
        
        // Set up the fallback player
        self.player = fallbackPlayer
        
        // Monitor the fallback player
        self.monitorPlayerStatus(fallbackPlayer)
        
        // Auto-play the fallback stream
        fallbackPlayer.play()
        self.isPlaying = true
    }
    
    private func togglePlayPause() {
        guard let player = player else { return }
        
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }
    
    private func forceResumePlayback() {
        guard let player = player, VideoPlayerCache.shared.isPlayerValid(for: videoURL) else {
            print("DEBUG: Cannot resume playback - player is invalid")
            return
        }
        
        print("DEBUG: Force resuming playback")
        player.play()
        isPlaying = true
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
}

struct VideoPlayerView: UIViewControllerRepresentable {
    let url: URL
    let autoPlay: Bool
    let isMuted: Bool
    let onMuteChanged: ((Bool) -> Void)?
    let onTimeUpdate: ((Double) -> Void)?
    let isVisible: Bool
    let showNativeControls: Bool
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = showNativeControls
        controller.videoGravity = .resizeAspect
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        controller.delegate = context.coordinator
        
        // Check if we already have a cached player
        if let cachedPlayer = VideoPlayerCache.shared.getPlayer(for: url) {
            print("DEBUG: Using cached video player for URL: \(url.absoluteString)")
            controller.player = cachedPlayer
            cachedPlayer.isMuted = isMuted
            
            if autoPlay && isVisible {
                cachedPlayer.play()
            }
            
            return controller
        }
        
        // Create asset with proper configuration
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetOutOfBandMIMETypeKey": "video/mp4",
            "AVURLAssetHTTPHeaderFieldsKey": ["Accept": "*/*", "Range": "bytes=0-"]
        ])
        
        // Create player item with asset
        let playerItem = AVPlayerItem(asset: asset)
        
        // Configure player item
        playerItem.preferredForwardBufferDuration = 2.0 // Limit buffer size
        playerItem.preferredPeakBitRate = 2_000_000 // 2 Mbps limit
        
        // Create and configure player
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = isMuted
        
        // Set up time observer
        let timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
            onTimeUpdate?(time.seconds)
        }
        
        // Cache the player
        VideoPlayerCache.shared.setPlayer(player, for: url)
        
        // Store observer and player in coordinator
        context.coordinator.timeObserver = timeObserver
        context.coordinator.player = player
        context.coordinator.onMuteChanged = onMuteChanged
        
        // Set up player
        controller.player = player
        
        if autoPlay {
            player.play()
        }
        
        return controller
    }
    
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        // Update mute state
        if controller.player?.isMuted != isMuted {
            controller.player?.isMuted = isMuted
        }
        
        if !isVisible {
            controller.player?.pause()
        } else if autoPlay {
            controller.player?.play()
        }
    }
    
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        // Stop mute monitoring
        coordinator.stopMuteMonitoring()
        
        // Just pause the player, don't destroy it
        controller.player?.pause()
        
        // Don't set player to nil - keep it in cache
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onMuteChanged: onMuteChanged, onTimeUpdate: onTimeUpdate)
    }
    
    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var onMuteChanged: ((Bool) -> Void)?
        let onTimeUpdate: ((Double) -> Void)?
        var timeObserver: Any?
        var player: AVPlayer?
        
        init(onMuteChanged: ((Bool) -> Void)?, onTimeUpdate: ((Double) -> Void)?) {
            self.onMuteChanged = onMuteChanged
            self.onTimeUpdate = onTimeUpdate
        }
        
        // Monitor mute state changes from native controls
        func playerViewController(_ playerViewController: AVPlayerViewController, willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            // Full screen presentation
        }
        
        func playerViewController(_ playerViewController: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            // Full screen dismissal
        }
        
        // Start monitoring mute state changes
        func startMuteMonitoring() {
            // The mute state is now handled by the binding system in HLSVideoPlayerWithControls
        }
        
        // Stop monitoring mute state changes
        func stopMuteMonitoring() {
            // No timer to invalidate anymore
        }
        
        deinit {
            stopMuteMonitoring()
        }
    }
}

struct HLSDirectoryVideoPlayer: View {
    let baseURL: URL
    let isVisible: Bool
    let isMuted: Bool
    let onMuteChanged: ((Bool) -> Void)?
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
                    onMuteChanged: onMuteChanged
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
