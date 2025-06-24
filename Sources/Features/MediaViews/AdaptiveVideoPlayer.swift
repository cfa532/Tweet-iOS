import SwiftUI
import AVKit
import AVFoundation

struct AdaptiveVideoPlayer: View {
    let videoURL: URL
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var qualityLevel: String = "Auto"
    
    // Quality levels for adaptive streaming
    private let qualityLevels = ["Auto", "High (720p)", "Medium (480p)"]
    
    var body: some View {
        VStack {
            if let errorMessage = errorMessage {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.red)
                    Text("Video Error")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else if isLoading {
                VStack {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading video...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            } else {
                ZStack {
                    if let player = player {
                        VideoPlayer(player: player)
                            .aspectRatio(16/9, contentMode: .fit)
                            .cornerRadius(12)
                            .shadow(radius: 5)
                    }
                    
                    // Quality selector overlay
                    VStack {
                        HStack {
                            Spacer()
                            Menu {
                                ForEach(qualityLevels, id: \.self) { level in
                                    Button(level) {
                                        qualityLevel = level
                                        selectQualityLevel(level)
                                    }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "gear")
                                    Text(qualityLevel)
                                }
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.7))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal)
                        Spacer()
                    }
                }
                
                // Custom controls
                VStack(spacing: 12) {
                    // Progress slider
                    if duration > 0 {
                        HStack {
                            Text(formatTime(currentTime))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Slider(value: Binding(
                                get: { currentTime },
                                set: { newValue in
                                    currentTime = newValue
                                    player?.seek(to: CMTime(seconds: newValue, preferredTimescale: 1))
                                }
                            ), in: 0...duration)
                            
                            Text(formatTime(duration))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                    }
                    
                    // Playback controls
                    HStack(spacing: 30) {
                        Button(action: {
                            if let player = player {
                                let newTime = max(0, currentTime - 10)
                                player.seek(to: CMTime(seconds: newTime, preferredTimescale: 1))
                            }
                        }) {
                            Image(systemName: "gobackward.10")
                                .font(.title2)
                        }
                        .disabled(player == nil)
                        
                        Button(action: togglePlayback) {
                            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title)
                        }
                        .disabled(player == nil)
                        
                        Button(action: {
                            if let player = player {
                                let newTime = min(duration, currentTime + 10)
                                player.seek(to: CMTime(seconds: newTime, preferredTimescale: 1))
                            }
                        }) {
                            Image(systemName: "goforward.10")
                                .font(.title2)
                        }
                        .disabled(player == nil)
                    }
                    .foregroundColor(.primary)
                }
                .padding(.bottom)
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
        isLoading = true
        errorMessage = nil
        
        // Try to set up the player with fallback for single-resolution HLS
        setupPlayerWithFallback()
    }
    
    private func setupPlayerWithFallback() {
        let hlsURL = getHLSPlaylistURL(from: videoURL)
        print("DEBUG: AdaptiveVideoPlayer attempting to play HLS URL: \(hlsURL.absoluteString)")
        
        // Create AVPlayer with adaptive streaming support
        let playerItem = AVPlayerItem(url: hlsURL)
        let avPlayer = AVPlayer(playerItem: playerItem)
        
        // Enable automatic quality switching
        playerItem.preferredForwardBufferDuration = 10.0
        
        // Add observers
        avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 1), queue: DispatchQueue.main) { time in
            currentTime = time.seconds
        }
        
        // Check if the HLS stream is playable
        Task {
            do {
                let asset = AVAsset(url: hlsURL)
                let isPlayable = try await asset.load(.isPlayable)
                
                await MainActor.run {
                    if isPlayable {
                        print("DEBUG: AdaptiveVideoPlayer HLS video is playable")
                        self.player = avPlayer
                        self.isLoading = false
                        
                        // Observe player item status
                        playerItem.addObserver(self, forKeyPath: "status", options: [.new, .old], context: nil)
                        
                        // Observe duration
                        playerItem.addObserver(self, forKeyPath: "duration", options: [.new, .old], context: nil)
                        
                        // Observe loading status
                        playerItem.addObserver(self, forKeyPath: "loadedTimeRanges", options: [.new, .old], context: nil)
                        
                        // Auto-play the HLS stream
                        avPlayer.play()
                        self.isPlaying = true
                        
                        // Get video duration
                        self.getVideoDuration(asset: asset)
                    } else {
                        print("DEBUG: AdaptiveVideoPlayer HLS video is not playable, trying fallback")
                        self.tryFallbackPlaylist()
                    }
                }
            } catch {
                print("DEBUG: AdaptiveVideoPlayer failed to check if HLS video is playable: \(error)")
                await MainActor.run {
                    print("DEBUG: AdaptiveVideoPlayer trying fallback playlist due to error")
                    self.tryFallbackPlaylist()
                }
            }
        }
    }
    
    private func tryFallbackPlaylist() {
        // Only try fallback if we're not already using playlist.m3u8
        if !videoURL.absoluteString.contains("playlist.m3u8") && !videoURL.absoluteString.contains("master.m3u8") {
            let fallbackURL = videoURL.appendingPathComponent("playlist.m3u8")
            print("DEBUG: AdaptiveVideoPlayer trying fallback playlist: \(fallbackURL.absoluteString)")
            
            // Create AVPlayer with adaptive streaming support
            let playerItem = AVPlayerItem(url: fallbackURL)
            let avPlayer = AVPlayer(playerItem: playerItem)
            
            // Enable automatic quality switching
            playerItem.preferredForwardBufferDuration = 10.0
            
            // Add observers
            avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 1), queue: DispatchQueue.main) { time in
                currentTime = time.seconds
            }
            
            Task {
                do {
                    let asset = AVAsset(url: fallbackURL)
                    let isPlayable = try await asset.load(.isPlayable)
                    
                    await MainActor.run {
                        if isPlayable {
                            print("DEBUG: AdaptiveVideoPlayer fallback HLS video is playable")
                            self.player = avPlayer
                            self.isLoading = false
                            
                            // Observe player item status
                            playerItem.addObserver(self, forKeyPath: "status", options: [.new, .old], context: nil)
                            
                            // Observe duration
                            playerItem.addObserver(self, forKeyPath: "duration", options: [.new, .old], context: nil)
                            
                            // Observe loading status
                            playerItem.addObserver(self, forKeyPath: "loadedTimeRanges", options: [.new, .old], context: nil)
                            
                            // Auto-play the HLS stream
                            avPlayer.play()
                            self.isPlaying = true
                            
                            // Get video duration
                            self.getVideoDuration(asset: asset)
                        } else {
                            print("DEBUG: AdaptiveVideoPlayer both master and playlist HLS are not playable")
                            self.errorMessage = "HLS video is not playable"
                            self.isLoading = false
                        }
                    }
                } catch {
                    print("DEBUG: AdaptiveVideoPlayer fallback HLS also failed: \(error)")
                    await MainActor.run {
                        self.errorMessage = "Failed to load HLS stream: \(error.localizedDescription)"
                        self.isLoading = false
                    }
                }
            }
        } else {
            // Already tried the fallback or using direct playlist URL
            self.errorMessage = "HLS video is not playable"
            self.isLoading = false
        }
    }
    
    private func getHLSPlaylistURL(from url: URL) -> URL {
        print("DEBUG: AdaptiveVideoPlayer getting HLS playlist URL from: \(url.absoluteString)")
        
        // If URL already ends with .m3u8, return as is
        if url.pathExtension.lowercased() == "m3u8" {
            print("DEBUG: AdaptiveVideoPlayer URL already ends with .m3u8, returning as is")
            return url
        }
        
        // If URL contains playlist.m3u8 or master.m3u8, return as is
        if url.absoluteString.contains("playlist.m3u8") || url.absoluteString.contains("master.m3u8") {
            print("DEBUG: AdaptiveVideoPlayer URL contains playlist.m3u8 or master.m3u8, returning as is")
            return url
        }
        
        // For CID-based URLs (no file extension), try to detect multi-resolution HLS first
        if url.pathExtension.isEmpty {
            // Check if this is a multi-resolution HLS stream by trying master.m3u8 first
            let masterPlaylistURL = url.appendingPathComponent("master.m3u8")
            print("DEBUG: AdaptiveVideoPlayer CID-based URL, trying master.m3u8 first: \(masterPlaylistURL.absoluteString)")
            
            // Note: We'll let AVPlayer handle the actual validation of the master playlist
            // If master.m3u8 doesn't exist, AVPlayer will fail gracefully and we can fall back
            return masterPlaylistURL
        }
        
        // For other URLs, try to append master.m3u8 first (for multi-resolution)
        let masterPlaylistURL = url.appendingPathComponent("master.m3u8")
        print("DEBUG: AdaptiveVideoPlayer appending master.m3u8 to URL: \(masterPlaylistURL.absoluteString)")
        return masterPlaylistURL
    }
    
    private func getVideoDuration(asset: AVAsset) {
        Task {
            do {
                let durationTime = try await asset.load(.duration)
                
                await MainActor.run {
                    self.duration = durationTime.seconds
                    print("DEBUG: AdaptiveVideoPlayer HLS video duration: \(durationTime.seconds) seconds")
                }
            } catch {
                print("DEBUG: AdaptiveVideoPlayer failed to get video duration: \(error)")
                await MainActor.run {
                    self.errorMessage = "Failed to get video duration: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
    
    private func cleanupPlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
    
    private func togglePlayback() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
    }
    
    private func selectQualityLevel(_ level: String) {
        // For adaptive streaming, the player automatically selects the best quality
        // based on network conditions. This is more of a UI indicator.
        qualityLevel = level
        
        // You could implement manual quality selection here if needed
        // by switching to different playlist URLs
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - KVO Observers
extension AdaptiveVideoPlayer {
    func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let playerItem = object as? AVPlayerItem else { return }
        
        DispatchQueue.main.async {
            switch keyPath {
            case "status":
                switch playerItem.status {
                case .readyToPlay:
                    self.isLoading = false
                    self.duration = playerItem.duration.seconds
                case .failed:
                    self.isLoading = false
                    
                    // Check if this is a master playlist failure and try fallback
                    if let error = playerItem.error as NSError?,
                       error.domain == "CoreMediaErrorDomain" && error.code == -12642 {
                        print("DEBUG: AdaptiveVideoPlayer master playlist parse error detected, trying fallback")
                        self.tryFallbackPlaylist()
                    } else {
                        self.errorMessage = playerItem.error?.localizedDescription ?? "Failed to load video"
                    }
                case .unknown:
                    break
                @unknown default:
                    break
                }
                
            case "duration":
                self.duration = playerItem.duration.seconds
                
            case "loadedTimeRanges":
                // Update loading status based on buffering
                if let timeRange = playerItem.loadedTimeRanges.first?.timeRangeValue {
                    let bufferedDuration = timeRange.duration.seconds
                    self.isLoading = bufferedDuration < 5.0 // Show loading if less than 5 seconds buffered
                }
                
            default:
                break
            }
        }
    }
}

// MARK: - Preview
struct AdaptiveVideoPlayer_Previews: PreviewProvider {
    static var previews: some View {
        AdaptiveVideoPlayer(videoURL: URL(string: "https://example.com/video.m3u8")!)
            .previewLayout(.sizeThatFits)
    }
} 