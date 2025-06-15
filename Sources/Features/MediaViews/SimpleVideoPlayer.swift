//
//  SimpleVideoPlayer.swift
//  Tweet
//
//  A simpler video player implementation
//

import SwiftUI
import AVKit

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
    @State private var shouldLoadVideo: Bool = false
    @State private var loadTimer: Timer?
    
    var body: some View {
        ZStack {
            if shouldLoadVideo {
                VideoPlayerView(
                    url: url,
                    autoPlay: autoPlay,
                    isMuted: isMuted ?? muteState.isMuted,
                    onMuteChanged: onMuteChanged,
                    onTimeUpdate: onTimeUpdate
                )
            } else {
                // Placeholder view
                Color.black
                
                // Play button overlay
                Image(systemName: "play.circle.fill")
                    .resizable()
                    .frame(width: 50, height: 50)
                    .foregroundColor(.white)
            }
        }
        .onAppear {
            // Start timer to delay video loading
            loadTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                shouldLoadVideo = true
            }
        }
        .onDisappear {
            // Cancel timer and reset state when view disappears
            loadTimer?.invalidate()
            loadTimer = nil
            shouldLoadVideo = false
        }
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
