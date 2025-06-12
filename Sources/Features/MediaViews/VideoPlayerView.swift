//
//  VideoPlayerView.swift
//  Tweet
//
//  Created by 超方 on 2025/6/12.
//

import SwiftUI
import AVKit

// MARK: - Video Player Error
enum VideoPlayerError: LocalizedError {
    case notPlayable
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .notPlayable:
            return "This video format is not supported"
        case .unknown:
            return "An unknown error occurred"
        }
    }
}

// MARK: - Video Player View
struct VideoPlayerCacheView: View {
    let url: URL
    let attachment: MimeiFileType
    var play: Bool = true // Default to true for auto-play

    @State private var player: AVPlayer?
    @State private var isPlaying: Bool = false
    @State private var isMuted: Bool = PreferenceHelper().getSpeakerMute()
    private let preferenceHelper = PreferenceHelper()

    var body: some View {
        ZStack {
            // Simple VideoPlayer
            VideoPlayer(player: player)
                .onAppear {
                    setupPlayer()
                }
                .onDisappear {
                    cleanupPlayer()
                }
            
            // Controls overlay
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    
                    // Play/Pause button
                    Button(action: togglePlayPause) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .padding(.trailing, 10)
                    
                    // Mute/Unmute button
                    Button(action: toggleMute) {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .padding(.trailing, 20)
                }
                .padding(.bottom, 20)
            }
        }
        .background(Color.black)
        .clipped()
    }
    
    private func setupPlayer() {
        guard player == nil else { return }
        
        print("VideoPlayer: Setting up player for URL: \(url)")
        
        // Simple player setup
        let playerItem = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: playerItem)
        
        // Configure player
        newPlayer.isMuted = isMuted
        newPlayer.volume = isMuted ? 0.0 : 1.0
        
        self.player = newPlayer
        
        // Auto-play if requested
        if play {
            newPlayer.play()
            isPlaying = true
            print("VideoPlayer: Started auto-play")
        }
    }
    
    private func cleanupPlayer() {
        print("VideoPlayer: Cleaning up player")
        player?.pause()
        player = nil
        isPlaying = false
    }
    
    private func togglePlayPause() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
    }
    
    private func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
        player?.volume = isMuted ? 0.0 : 1.0
        preferenceHelper.setSpeakerMute(isMuted)
    }
}

// MARK: - Visibility Detection
struct VisibilityModifier: ViewModifier {
    let onChange: (Bool) -> Void
    
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .background(
                    Color.clear
                        .preference(key: VisibilityPreferenceKey.self, value: geometry.frame(in: .global))
                )
        }
        .onPreferenceChange(VisibilityPreferenceKey.self) { frame in
            let screen = UIScreen.main.bounds
            let isVisible = screen.intersects(frame) && !frame.isEmpty
            onChange(isVisible)
        }
    }
}

struct VisibilityPreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

extension View {
    func onVisibilityChanged(_ perform: @escaping (Bool) -> Void) -> some View {
        self.modifier(VisibilityModifier(onChange: perform))
    }
}

