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
        
        // Create AVPlayer with adaptive streaming support
        let playerItem = AVPlayerItem(url: videoURL)
        player = AVPlayer(playerItem: playerItem)
        
        // Enable automatic quality switching
        playerItem.preferredForwardBufferDuration = 10.0
        
        // Add observers
        player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 1), queue: .main) { time in
            currentTime = time.seconds
        }
        
        // Observe player item status
        playerItem.addObserver(self, forKeyPath: "status", options: [.new, .old], context: nil)
        
        // Observe duration
        playerItem.addObserver(self, forKeyPath: "duration", options: [.new, .old], context: nil)
        
        // Observe loading status
        playerItem.addObserver(self, forKeyPath: "loadedTimeRanges", options: [.new, .old], context: nil)
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
                    self.errorMessage = playerItem.error?.localizedDescription ?? "Failed to load video"
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