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
    @Published var isMuted: Bool = false
}

struct SimpleVideoPlayer: View {
    let url: URL
    var autoPlay: Bool = true
    @EnvironmentObject var muteState: MuteState
    var onTimeUpdate: ((Double) -> Void)? = nil
    var isMuted: Bool? = nil
    var onMuteChanged: ((Bool) -> Void)? = nil
    let isVisible: Bool
    var aspectRatio: Float? = nil
    var contentType: String? = nil
    
    var body: some View {
        // Check if this is an HLS stream based on content type
        if isHLSStream(url: url, contentType: contentType) {
            HLSVideoPlayerWithControls(
                videoURL: getHLSPlaylistURL(from: url),
                aspectRatio: aspectRatio
            )
        } else {
            VideoPlayerView(
                url: url,
                autoPlay: autoPlay,
                isMuted: isMuted ?? muteState.isMuted,
                onMuteChanged: onMuteChanged,
                onTimeUpdate: onTimeUpdate
            )
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
    let aspectRatio: Float?
    
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var showControls = true
    
    init(videoURL: URL, aspectRatio: Float? = nil) {
        self.videoURL = videoURL
        self.aspectRatio = aspectRatio
    }
    
    var body: some View {
        ZStack {
            if let player = player {
                VideoPlayer(player: player)
                    .aspectRatio(aspectRatio.map { CGFloat($0) } ?? 16.0/9.0, contentMode: .fit)
                    .overlay(
                        // Custom controls overlay
                        Group {
                            if showControls {
                                VStack {
                                    Spacer()
                                    HStack {
                                        Button(action: togglePlayPause) {
                                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                                .foregroundColor(.white)
                                                .font(.title2)
                                        }
                                        .padding()
                                        
                                        Spacer()
                                        
                                        Text(formatTime(currentTime))
                                            .foregroundColor(.white)
                                            .font(.caption)
                                        
                                        Text("/")
                                            .foregroundColor(.white)
                                            .font(.caption)
                                        
                                        Text(formatTime(duration))
                                            .foregroundColor(.white)
                                            .font(.caption)
                                    }
                                    .padding(.horizontal)
                                    .padding(.bottom)
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
                    .onTapGesture {
                        withAnimation {
                            showControls.toggle()
                        }
                    }
            } else if isLoading {
                VStack {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading HLS stream...")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                }
            }
        }
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            cleanupPlayer()
        }
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
    
    /// Fetch and analyze HLS playlist content for debugging
    private func analyzeHLSPlaylist(url: URL) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("DEBUG: HLS Analysis - HTTP Status: \(httpResponse.statusCode)")
                print("DEBUG: HLS Analysis - Content-Type: \(httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown")")
                print("DEBUG: HLS Analysis - Content-Length: \(httpResponse.value(forHTTPHeaderField: "Content-Length") ?? "unknown")")
            }
            
            if let content = String(data: data, encoding: .utf8) {
                print("DEBUG: HLS Analysis - Full playlist content:")
                print(content)
                
                // Analyze playlist structure
                let lines = content.components(separatedBy: .newlines)
                print("DEBUG: HLS Analysis - Total lines: \(lines.count)")
                
                // Count different types of lines
                let extM3uLines = lines.filter { $0.trimmingCharacters(in: .whitespaces) == "#EXTM3U" }
                let streamInfLines = lines.filter { $0.contains("#EXT-X-STREAM-INF") }
                let targetDurationLines = lines.filter { $0.contains("#EXT-X-TARGETDURATION") }
                let segmentLines = lines.filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                
                print("DEBUG: HLS Analysis - #EXTM3U lines: \(extM3uLines.count)")
                print("DEBUG: HLS Analysis - #EXT-X-STREAM-INF lines: \(streamInfLines.count)")
                print("DEBUG: HLS Analysis - #EXT-X-TARGETDURATION lines: \(targetDurationLines.count)")
                print("DEBUG: HLS Analysis - Segment lines: \(segmentLines.count)")
                
                // Check for common issues
                if extM3uLines.isEmpty {
                    print("DEBUG: HLS Analysis - ISSUE: Missing #EXTM3U header")
                }
                
                if streamInfLines.isEmpty && segmentLines.isEmpty {
                    print("DEBUG: HLS Analysis - ISSUE: No streams or segments found")
                }
                
                // Check segment URLs
                for (index, segment) in segmentLines.enumerated() {
                    let trimmedSegment = segment.trimmingCharacters(in: .whitespaces)
                    if !trimmedSegment.isEmpty {
                        print("DEBUG: HLS Analysis - Segment \(index): \(trimmedSegment)")
                        
                        // Check if segment URL is relative or absolute
                        if trimmedSegment.hasPrefix("http") {
                            print("DEBUG: HLS Analysis - Segment \(index) is absolute URL")
                        } else {
                            print("DEBUG: HLS Analysis - Segment \(index) is relative URL")
                        }
                    }
                }
                
                // Test segment accessibility if this is a media playlist
                if streamInfLines.isEmpty && !segmentLines.isEmpty {
                    print("DEBUG: HLS Analysis - Testing segment accessibility...")
                    await testHLSSegments(baseURL: url, segmentURLs: segmentLines.map { $0.trimmingCharacters(in: .whitespaces) })
                }
            }
        } catch {
            print("DEBUG: HLS Analysis - Failed to fetch playlist: \(error)")
        }
    }
    
    /// Test individual HLS segment accessibility
    private func testHLSSegments(baseURL: URL, segmentURLs: [String]) async {
        print("DEBUG: Testing HLS segment accessibility for \(segmentURLs.count) segments")
        
        for (index, segmentURL) in segmentURLs.enumerated() {
            let fullSegmentURL: URL
            
            if segmentURL.hasPrefix("http") {
                // Absolute URL
                fullSegmentURL = URL(string: segmentURL) ?? baseURL
            } else {
                // Relative URL - construct from base URL
                fullSegmentURL = baseURL.appendingPathComponent(segmentURL)
            }
            
            do {
                let (_, response) = try await URLSession.shared.data(from: fullSegmentURL)
                
                if let httpResponse = response as? HTTPURLResponse {
                    print("DEBUG: Segment \(index) (\(segmentURL)) - Status: \(httpResponse.statusCode)")
                    
                    if httpResponse.statusCode != 200 {
                        print("DEBUG: Segment \(index) is not accessible (Status: \(httpResponse.statusCode))")
                    }
                }
            } catch {
                print("DEBUG: Segment \(index) failed to load: \(error)")
            }
        }
    }
    
    private func setupPlayer() {
        print("DEBUG: Setting up HLS player for URL: \(videoURL.absoluteString)")
        isLoading = true
        errorMessage = nil
        
        // Add error handling for URL validation
        guard videoURL.scheme != nil else {
            print("DEBUG: Invalid URL scheme: \(videoURL)")
            errorMessage = "Invalid video URL"
            isLoading = false
            return
        }
        
        // Try to set up the player with fallback for single-resolution HLS
        setupPlayerWithFallback()
    }
    
    private func setupPlayerWithFallback() {
        let hlsURL = getHLSPlaylistURL(from: videoURL)
        print("DEBUG: Attempting to play HLS URL: \(hlsURL.absoluteString)")
        
        // Test the HLS playlist URL first with enhanced validation
        Task {
            // First, analyze the playlist content for debugging
            await analyzeHLSPlaylist(url: hlsURL)
            
            let isAccessible = await testHLSPlaylist(url: hlsURL)
            if !isAccessible {
                print("DEBUG: HLS playlist is not accessible or invalid, trying fallback immediately")
                await MainActor.run {
                    self.tryFallbackPlaylist()
                }
                return
            }
            
            // If playlist is valid, proceed with player setup
            await MainActor.run {
                self.setupPlayerWithValidatedURL(hlsURL)
            }
        }
    }
    
    private func setupPlayerWithValidatedURL(_ hlsURL: URL) {
        print("DEBUG: Setting up player with validated HLS URL: \(hlsURL.absoluteString)")
        
        let avPlayer = AVPlayer(url: hlsURL)
        
        // Add periodic time observer for progress updates
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { time in
            currentTime = time.seconds
        }
        
        // Check if the HLS stream is playable
        Task {
            do {
                let asset = AVAsset(url: hlsURL)
                let isPlayable = try await asset.load(.isPlayable)
                
                await MainActor.run {
                    if isPlayable {
                        print("DEBUG: HLS video is playable, setting up player")
                        self.player = avPlayer
                        self.isLoading = false
                        
                        // Monitor player item status
                        self.monitorPlayerStatus(avPlayer)
                        
                        // Auto-play the HLS stream
                        avPlayer.play()
                        self.isPlaying = true
                        
                        // Get video duration
                        self.getVideoDuration(asset: asset)
                    } else {
                        print("DEBUG: HLS video is not playable, trying fallback")
                        self.tryFallbackPlaylist()
                    }
                }
            } catch {
                print("DEBUG: Failed to check if HLS video is playable: \(error)")
                await MainActor.run {
                    print("DEBUG: Trying fallback playlist due to error")
                    self.tryFallbackPlaylist()
                }
            }
        }
    }
    
    private func tryFallbackPlaylist() {
        print("DEBUG: Starting fallback playlist search")
        
        // Only try fallback if we're not already using playlist.m3u8
        if !videoURL.absoluteString.contains("playlist.m3u8") && !videoURL.absoluteString.contains("master.m3u8") {
            // Try different HLS playlist structures
            let fallbackPlaylists = [
                // Multi-resolution HLS structure
                videoURL.appendingPathComponent("720p/playlist.m3u8"),
                videoURL.appendingPathComponent("480p/playlist.m3u8"),
                videoURL.appendingPathComponent("360p/playlist.m3u8"),
                videoURL.appendingPathComponent("240p/playlist.m3u8"),
                
                // Single-resolution HLS structure
                videoURL.appendingPathComponent("playlist.m3u8"),
                
                // Alternative naming conventions
                videoURL.appendingPathComponent("index.m3u8"),
                videoURL.appendingPathComponent("manifest.m3u8"),
                videoURL.appendingPathComponent("stream.m3u8"),
                
                // Direct segment access (if it's a single file)
                videoURL.appendingPathComponent("segment0.ts")
            ]
            
            tryQualityPlaylists(playlists: fallbackPlaylists, index: 0)
        } else {
            // Already tried the fallback or using direct playlist URL
            print("DEBUG: Already using playlist URL, no more fallbacks available")
            self.errorMessage = "HLS video is not playable"
            self.isLoading = false
        }
    }
    
    private func tryQualityPlaylists(playlists: [URL], index: Int) {
        guard index < playlists.count else {
            print("DEBUG: All quality playlists failed")
            self.errorMessage = "HLS video is not playable"
            self.isLoading = false
            return
        }
        
        let playlistURL = playlists[index]
        print("DEBUG: Trying quality playlist \(index + 1)/\(playlists.count): \(playlistURL.absoluteString)")
        
        let avPlayer = AVPlayer(url: playlistURL)
        
        // Add periodic time observer for progress updates
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { time in
            currentTime = time.seconds
        }
        
        Task {
            do {
                let asset = AVAsset(url: playlistURL)
                let isPlayable = try await asset.load(.isPlayable)
                
                await MainActor.run {
                    if isPlayable {
                        print("DEBUG: Quality playlist \(index + 1) is playable")
                        self.player = avPlayer
                        self.isLoading = false
                        
                        // Monitor player item status
                        self.monitorPlayerStatus(avPlayer)
                        
                        // Auto-play the HLS stream
                        avPlayer.play()
                        self.isPlaying = true
                        
                        // Get video duration
                        self.getVideoDuration(asset: asset)
                    } else {
                        print("DEBUG: Quality playlist \(index + 1) is not playable, trying next")
                        self.tryQualityPlaylists(playlists: playlists, index: index + 1)
                    }
                }
            } catch {
                print("DEBUG: Quality playlist \(index + 1) failed: \(error)")
                await MainActor.run {
                    self.tryQualityPlaylists(playlists: playlists, index: index + 1)
                }
            }
        }
    }
    
    private func getVideoDuration(asset: AVAsset) {
        Task {
            do {
                let durationTime = try await asset.load(.duration)
                
                await MainActor.run {
                    self.duration = durationTime.seconds
                    print("DEBUG: HLS video duration: \(durationTime.seconds) seconds")
                }
            } catch {
                print("DEBUG: Failed to get video duration: \(error)")
                await MainActor.run {
                    self.errorMessage = "Failed to get video duration: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
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
                    
                    // Provide more specific error messages based on error codes
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
                    case ("NSURLErrorDomain", 404):
                        print("DEBUG: HLS playlist not found (404)")
                        self.errorMessage = "HLS playlist not found"
                    case ("NSURLErrorDomain", 403):
                        print("DEBUG: HLS playlist access denied (403)")
                        self.errorMessage = "HLS playlist access denied"
                    default:
                        print("DEBUG: Unknown HLS error")
                        self.errorMessage = "HLS playback error: \(error.localizedDescription)"
                    }
                }
                self.isLoading = false
                
                // Check if this is a master playlist failure and try fallback
                if let error = playerItem.error as NSError?,
                   error.domain == "CoreMediaErrorDomain" && error.code == -12642 {
                    print("DEBUG: Master playlist parse error detected, trying fallback")
                    self.tryFallbackPlaylist()
                } else {
                    // For other errors, don't try fallback if we've already tried multiple URLs
                    if !self.videoURL.absoluteString.contains("playlist.m3u8") && 
                       !self.videoURL.absoluteString.contains("master.m3u8") {
                        print("DEBUG: Trying fallback for non-playlist error")
                        self.tryFallbackPlaylist()
                    }
                }
                timer.invalidate()
            case .unknown:
                print("DEBUG: HLS player item status is unknown")
                break
            @unknown default:
                break
            }
        }
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
    
    private func cleanupPlayer() {
        player?.pause()
        player = nil
        isPlaying = false
    }
}

struct VideoPlayerView: UIViewControllerRepresentable {
    let url: URL
    let autoPlay: Bool
    let isMuted: Bool
    let onMuteChanged: ((Bool) -> Void)?
    let onTimeUpdate: ((Double) -> Void)?
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        
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
        
        // Store observer in coordinator
        context.coordinator.timeObserver = timeObserver
        
        // Set up player
        controller.player = player
        
        if autoPlay {
            player.play()
        }
        
        return controller
    }
    
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player?.isMuted = isMuted
    }
    
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        // Clean up time observer
        if let timeObserver = coordinator.timeObserver {
            controller.player?.removeTimeObserver(timeObserver)
        }
        
        // Stop playback
        controller.player?.pause()
        controller.player = nil
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onMuteChanged: onMuteChanged, onTimeUpdate: onTimeUpdate)
    }
    
    class Coordinator: NSObject {
        let onMuteChanged: ((Bool) -> Void)?
        let onTimeUpdate: ((Double) -> Void)?
        var timeObserver: Any?
        
        init(onMuteChanged: ((Bool) -> Void)?, onTimeUpdate: ((Double) -> Void)?) {
            self.onMuteChanged = onMuteChanged
            self.onTimeUpdate = onTimeUpdate
        }
    }
} 
