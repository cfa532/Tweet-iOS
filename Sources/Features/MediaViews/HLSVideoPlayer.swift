import SwiftUI
import AVKit
import AVFoundation

/// HLSVideoPlayer provides a SwiftUI wrapper for playing HLS video streams
struct HLSVideoPlayer: View {
    let videoURL: URL
    let aspectRatio: Float?
    
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    init(videoURL: URL, aspectRatio: Float? = nil) {
        self.videoURL = videoURL
        self.aspectRatio = aspectRatio
    }
    
    var body: some View {
        ZStack {
            if let player = player {
                VideoPlayer(player: player)
                    .aspectRatio(aspectRatio.map { CGFloat($0) } ?? 16.0/9.0, contentMode: .fit)
                    .onAppear {
                        setupPlayer()
                    }
                    .onDisappear {
                        cleanupPlayer()
                    }
            } else if isLoading {
                ProgressView("Loading video...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = errorMessage {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            setupPlayer()
        }
    }
    
    private func setupPlayer() {
        isLoading = true
        errorMessage = nil
        
        // Create AVPlayer with the video URL
        let avPlayer = AVPlayer(url: videoURL)
        
        // Add observer for player status
        avPlayer.currentItem?.addObserver(
            NSObject(),
            forKeyPath: "status",
            options: [.new, .old],
            context: nil
        )
        
        // Add periodic time observer
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { _ in
            // Handle time updates if needed
        }
        
        // Add notification observers
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: avPlayer.currentItem,
            queue: .main
        ) { _ in
            // Handle video completion
            isPlaying = false
        }
        
        // Check if the video is playable
        Task {
            do {
                let asset = AVAsset(url: videoURL)
                let isPlayable = try await asset.load(.isPlayable)
                
                await MainActor.run {
                    if isPlayable {
                        self.player = avPlayer
                        self.isLoading = false
                    } else {
                        self.errorMessage = "Video is not playable"
                        self.isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to load video: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
    
    private func cleanupPlayer() {
        player?.pause()
        player = nil
        isPlaying = false
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
                        VStack {
                            Spacer()
                            if showControls {
                                HStack {
                                    Button(action: togglePlayPause) {
                                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                            .font(.title2)
                                            .foregroundColor(.white)
                                    }
                                    .padding()
                                    
                                    Text(formatTime(currentTime))
                                        .foregroundColor(.white)
                                        .font(.caption)
                                    
                                    Slider(
                                        value: Binding(
                                            get: { currentTime },
                                            set: { seekTo($0) }
                                        ),
                                        in: 0...max(duration, 1)
                                    )
                                    .accentColor(.white)
                                    
                                    Text(formatTime(duration))
                                        .foregroundColor(.white)
                                        .font(.caption)
                                }
                                .padding()
                                .background(Color.black.opacity(0.5))
                                .cornerRadius(10)
                                .padding()
                            }
                        }
                    )
                    .onTapGesture {
                        withAnimation {
                            showControls.toggle()
                        }
                    }
                    .onAppear {
                        setupPlayer()
                    }
                    .onDisappear {
                        cleanupPlayer()
                    }
            } else if isLoading {
                ProgressView("Loading video...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = errorMessage {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            setupPlayer()
        }
    }
    
    private func setupPlayer() {
        isLoading = true
        errorMessage = nil
        
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
                }
            } catch {
                print("Failed to get video duration: \(error)")
            }
        }
        
        // Check if video is playable
        Task {
            do {
                let asset = AVAsset(url: videoURL)
                let isPlayable = try await asset.load(.isPlayable)
                
                await MainActor.run {
                    if isPlayable {
                        self.player = avPlayer
                        self.isLoading = false
                    } else {
                        self.errorMessage = "Video is not playable"
                        self.isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to load video: \(error.localizedDescription)"
                    self.isLoading = false
                }
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

// MARK: - Preview

struct HLSVideoPlayer_Previews: PreviewProvider {
    static var previews: some View {
        HLSVideoPlayer(
            videoURL: URL(string: "https://example.com/sample.m3u8")!,
            aspectRatio: 16.0/9.0
        )
    }
} 