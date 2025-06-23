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
        if url.absoluteString.contains("playlist.m3u8") {
            print("DEBUG: Detected HLS by playlist.m3u8 in URL")
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
        
        // If URL contains playlist.m3u8, return as is
        if url.absoluteString.contains("playlist.m3u8") {
            print("DEBUG: URL contains playlist.m3u8, returning as is")
            return url
        }
        
        // For CID-based URLs (no file extension), append playlist.m3u8
        // This handles both IPFS and regular CID-based URLs
        if url.pathExtension.isEmpty {
            let playlistURL = url.appendingPathComponent("playlist.m3u8")
            print("DEBUG: CID-based URL, appending playlist.m3u8: \(playlistURL.absoluteString)")
            return playlistURL
        }
        
        // For other URLs, try to append playlist.m3u8
        let playlistURL = url.appendingPathComponent("playlist.m3u8")
        print("DEBUG: Appending playlist.m3u8 to URL: \(playlistURL.absoluteString)")
        return playlistURL
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
        
        let avPlayer = AVPlayer(url: videoURL)
        
        // Add periodic time observer for progress updates
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            currentTime = time.seconds
        }
        
        // Get video duration
        Task {
            do {
                let asset = AVAsset(url: videoURL)
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
        
        // Check if video is playable and monitor player status
        Task {
            do {
                let asset = AVAsset(url: videoURL)
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
                    } else {
                        print("DEBUG: HLS video is not playable")
                        self.errorMessage = "Video is not playable"
                        self.isLoading = false
                    }
                }
            } catch {
                print("DEBUG: Failed to check if HLS video is playable: \(error)")
                await MainActor.run {
                    self.errorMessage = "Failed to load video: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
    
    private func monitorPlayerStatus(_ player: AVPlayer) {
        // Monitor player item status using a timer
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            guard let playerItem = player.currentItem else {
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
                self.isLoading = false
                self.errorMessage = playerItem.error?.localizedDescription ?? "Failed to load HLS stream"
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
