//
//  VideoControls.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI
import AVFoundation

// MARK: - Video Controls Component
struct VideoControls: View {
    @ObservedObject var playerState: VideoPlayerState
    let showControls: Bool
    
    var body: some View {
        if showControls {
            VStack {
                Spacer()
                HStack {
                    Button(action: playerState.togglePlayPause) {
                        Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundColor(.white)
                            .font(.title2)
                    }
                    .padding()
                    
                    Spacer()
                    
                    Text(formatTime(playerState.currentTime))
                        .foregroundColor(.white)
                        .font(.caption)
                    
                    Text("/")
                        .foregroundColor(.white)
                        .font(.caption)
                    
                    Text(formatTime(playerState.duration))
                        .foregroundColor(.white)
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.bottom)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.black.opacity(0.7), Color.clear]),
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
            }
        }
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
} 

// Global mute state
class MuteState: ObservableObject {
    static let shared = MuteState()
    @Published var isMuted: Bool = false
}

// MARK: - Video Player State Manager
class VideoPlayerState: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isLoading: Bool = true
    @Published var errorMessage: String?
    @Published var isMuted: Bool = false
    
    var player: AVPlayer? { _player }
    private var _player: AVPlayer?
    private var timeObserver: Any?
    
    func setPlayer(_ player: AVPlayer?) {
        _player = player
        _player?.isMuted = isMuted
    }
    
    func setupPlayer(url: URL, autoPlay: Bool = true) {
        isLoading = true
        errorMessage = nil
        
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
        _player = AVPlayer(playerItem: playerItem)
        _player?.automaticallyWaitsToMinimizeStalling = true
        _player?.isMuted = isMuted
        
        // Get duration
        Task {
            do {
                let durationTime = try await playerItem.asset.load(.duration)
                await MainActor.run {
                    self.duration = durationTime.seconds
                }
            } catch {
                print("Error loading duration: \(error)")
            }
        }
        
        // Add time observer
        timeObserver = _player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
            self.currentTime = time.seconds
        }
        
        isLoading = false
        
        if autoPlay {
            play()
        }
    }
    
    func play() {
        _player?.play()
        isPlaying = true
    }
    
    func pause() {
        _player?.pause()
        isPlaying = false
    }
    
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    func toggleMute() {
        isMuted.toggle()
        _player?.isMuted = isMuted
    }
    
    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 1)
        _player?.seek(to: cmTime)
    }
    
    func cleanup() {
        if let timeObserver = timeObserver {
            _player?.removeTimeObserver(timeObserver)
        }
        _player?.pause()
        _player = nil
        isPlaying = false
    }
}
