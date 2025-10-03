//
//  FullScreenVideoPlayer.swift
//  Tweet
//
//  Created by Assistant on 2025/10/3.
//

import SwiftUI
import AVKit
import AVFoundation

struct FullScreenVideoPlayer: View {
    let videoURL: URL
    let tweetId: String?
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var wasOrientationLocked = false
    @State private var wasMuted = false
    @State private var wasPlaying = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var fullScreenMuted = false // Independent mute state for full screen
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @ObservedObject private var muteState = MuteState.shared
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea(.all)
            
            if let errorMessage = errorMessage {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50))
                        .foregroundColor(.white)
                    
                    Text("Unable to load video")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button("Dismiss") {
                        dismiss()
                    }
                    .foregroundColor(.blue)
                }
            } else if let player = player {
                VideoPlayer(player: player)
                    .onAppear {
                        // Always play unmuted in full screen (independent of global mute state)
                        player.isMuted = false
                        fullScreenMuted = false
                        player.play()
                    }
                    .onDisappear {
                        // Save current play status
                        wasPlaying = player.rate > 0
                        
                        // Restore original mute state (don't change global mute state)
                        player.isMuted = wasMuted
                        player.pause()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                        // When orientation changes, maintain the current play status
                        if let player = self.player {
                            let currentRate = player.rate
                            if currentRate > 0 {
                                // Video was playing, ensure it continues playing after rotation
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    player.play()
                                }
                            }
                            // If video was paused, it stays paused
                        }
                    }
            } else if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.5)
            }
        }
        .offset(dragOffset)
        .scaleEffect(isDragging ? max(0.6, 1 - abs(dragOffset.height) / 600.0) : 1)
        .opacity(isDragging ? max(0.3, 1 - abs(dragOffset.height) / 500.0) : 1)
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Only allow downward drag
                    if value.translation.height > 0 {
                        isDragging = true
                        dragOffset = value.translation
                    }
                }
                .onEnded { value in
                    isDragging = false
                    
                    // If dragged down significantly, dismiss
                    if value.translation.height > 150 {
                        dismiss()
                    } else {
                        // Snap back to original position
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                            dragOffset = .zero
                        }
                    }
                }
        )
        .onAppear {
            setupPlayer()
            handleOrientation()
        }
        .onDisappear {
            cleanup()
        }
        .onTapGesture {
            dismiss()
        }
    }
    
    private func setupPlayer() {
        Task {
            do {
                // Use the SharedAssetCache to get or create the player
                let videoPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(for: videoURL, tweetId: tweetId)
                
                await MainActor.run {
                    // Save the original mute state before entering full screen
                    self.wasMuted = videoPlayer.isMuted
                    
                    // Save the current play status
                    self.wasPlaying = videoPlayer.rate > 0
                    
                    self.player = videoPlayer
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    
    private func handleOrientation() {
        // Save current orientation lock state
        wasOrientationLocked = OrientationManager.shared.isLocked
        
        // Unlock orientation for full-screen video
        OrientationManager.shared.unlockOrientation()
    }
    
    private func cleanup() {
        // Save current play status before pausing
        if let player = player {
            wasPlaying = player.rate > 0
        }
        
        player?.pause()
        player = nil
        
        // Restore original orientation lock state
        if wasOrientationLocked {
            OrientationManager.shared.lockToPortrait()
        }
    }
}

// MARK: - Full Screen Video Manager
class FullScreenVideoManager: ObservableObject {
    static let shared = FullScreenVideoManager()
    
    @Published var isPresenting = false
    @Published var videoURL: URL?
    @Published var tweetId: String?
    
    private init() {}
    
    func presentVideo(url: URL, tweetId: String? = nil) {
        videoURL = url
        self.tweetId = tweetId
        isPresenting = true
    }
    
    func dismiss() {
        isPresenting = false
        videoURL = nil
        tweetId = nil
    }
}

// MARK: - Full Screen Video Modifier
struct FullScreenVideoModifier: ViewModifier {
    @StateObject private var manager = FullScreenVideoManager.shared
    
    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $manager.isPresenting) {
                if let videoURL = manager.videoURL {
                    FullScreenVideoPlayer(videoURL: videoURL, tweetId: manager.tweetId)
                        .onDisappear {
                            manager.dismiss()
                        }
                }
            }
    }
}

extension View {
    func fullScreenVideoPlayer() -> some View {
        self.modifier(FullScreenVideoModifier())
    }
}
