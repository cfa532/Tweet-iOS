//
//  VideoPlayerView.swift
//  Tweet
//
//  Created by 超方 on 2025/6/12.
//

import SwiftUI
import AVKit

// MARK: - Video Player View
struct VideoPlayerCacheView: View {
    let url: URL
    let attachment: MimeiFileType
    var play: Bool = true // Default to true for auto-play

    @State private var player: AVPlayer?
    @State private var isPlaying: Bool = false
    @State private var isMuted: Bool = PreferenceHelper().getSpeakerMute()
    @State private var isVisible: Bool = false
    private let preferenceHelper = PreferenceHelper()

    var body: some View {
        ZStack {
            VideoPlayer(player: player)
                .onAppear {
                    setupPlayer()
                }
                .onDisappear {
                    cleanupPlayer()
                }
                .clipped()
                .onVisibilityChanged { visible in
                    isVisible = visible
                    handlePlayback()
                }
            
            // Controls overlay
            controlsOverlay
        }
        .clipped()
    }
    
    @ViewBuilder
    private var controlsOverlay: some View {
        HStack(spacing: 20) {
            // Play/Pause button
            Button(action: togglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
            
            // Mute/Unmute button
            Button(action: toggleMute) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
    
    private func setupPlayer() {
        guard player == nil else { return }
        
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)
        player?.isMuted = isMuted
        
        handlePlayback()
    }
    
    private func cleanupPlayer() {
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
        preferenceHelper.setSpeakerMute(isMuted)
    }

    private func handlePlayback() {
        if isVisible && play {
            player?.play()
            isPlaying = true
        } else {
            player?.pause()
            isPlaying = false
        }
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
            let isVisible = screen.intersects(frame)
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

