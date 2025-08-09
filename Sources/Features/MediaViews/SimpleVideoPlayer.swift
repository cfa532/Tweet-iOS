//
//  SimpleVideoPlayer.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  Simple video player to replace the old SimpleVideoPlayer with basic controls
//

import SwiftUI
import AVKit
import AVFoundation
import Combine

/// Simple video player with basic autoplay, replay, and mute controls
struct SimpleVideoPlayer: View {
    let url: URL
    let autoplay: Bool
    let autoReplay: Bool
    let mute: Bool
    
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var hasStarted = false
    
    init(url: URL, autoplay: Bool = true, autoReplay: Bool = false, mute: Bool = true) {
        self.url = url
        self.autoplay = autoplay
        self.autoReplay = autoReplay
        self.mute = mute
    }
    
    var body: some View {
        ZStack {
            if let player = player {
                VideoPlayer(player: player)
                    .onAppear {
                        setupPlayer()
                    }
                    .onDisappear {
                        cleanup()
                    }
            } else {
                // Loading state
                Color.black
                    .overlay(
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    )
            }
        }
        .onAppear {
            createPlayer()
        }
        .onDisappear {
            cleanup()
        }
    }
    
    private func createPlayer() {
        print("DEBUG: [SIMPLE VIDEO PLAYER] Creating player for URL: \(url)")
        
        Task {
            // Try to resolve HLS URL if needed
            let resolvedURL = await resolveVideoURL(url)
            print("DEBUG: [SIMPLE VIDEO PLAYER] Resolved URL: \(resolvedURL)")
            
            await MainActor.run {
                let asset = AVAsset(url: resolvedURL)
                let playerItem = AVPlayerItem(asset: asset)
                let newPlayer = AVPlayer(playerItem: playerItem)
                
                // Configure player
                newPlayer.isMuted = mute
                newPlayer.automaticallyWaitsToMinimizeStalling = true
                
                // Set up player item observer for end time
                if autoReplay {
                    NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemDidPlayToEndTime,
                        object: playerItem,
                        queue: .main
                    ) { _ in
                        newPlayer.seek(to: .zero)
                        if autoplay {
                            newPlayer.play()
                        }
                    }
                }
                
                // Set up status observer for debugging
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemNewAccessLogEntry,
                    object: playerItem,
                    queue: .main
                ) { _ in
                    print("DEBUG: [SIMPLE VIDEO PLAYER] New access log entry")
                }
                
                // Add status observer
                self.observePlayerStatus(playerItem: playerItem)
                
                self.player = newPlayer
                self.isLoading = false
                
                print("DEBUG: [SIMPLE VIDEO PLAYER] Player created - autoplay: \(autoplay), mute: \(mute), autoReplay: \(autoReplay)")
                print("DEBUG: [SIMPLE VIDEO PLAYER] Asset: \(asset)")
            }
        }
    }
    
    /// Resolve video URL (handle HLS if needed)
    private func resolveVideoURL(_ originalURL: URL) async -> URL {
        // Check if this might be an HLS directory
        let urlString = originalURL.absoluteString
        if !urlString.hasSuffix(".mp4") && !urlString.hasSuffix(".m3u8") {
            // Try to find HLS playlist
            let masterURL = originalURL.appendingPathComponent("master.m3u8")
            let playlistURL = originalURL.appendingPathComponent("playlist.m3u8")
            
            if await urlExists(masterURL) {
                print("DEBUG: [SIMPLE VIDEO PLAYER] Found master.m3u8")
                return masterURL
            }
            
            if await urlExists(playlistURL) {
                print("DEBUG: [SIMPLE VIDEO PLAYER] Found playlist.m3u8")
                return playlistURL
            }
            
            print("DEBUG: [SIMPLE VIDEO PLAYER] No HLS playlist found, using original URL")
        }
        
        return originalURL
    }
    
    /// Check if URL exists
    private func urlExists(_ url: URL) async -> Bool {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 3.0
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }
    
    private func setupPlayer() {
        guard let player = player, !hasStarted else { return }
        
        if autoplay {
            print("DEBUG: [SIMPLE VIDEO PLAYER] Starting autoplay")
            player.play()
            hasStarted = true
        }
    }
    
    private func observePlayerStatus(playerItem: AVPlayerItem) {
        // Use async observation
        Task {
            for await status in playerItem.publisher(for: \.status).values {
                await MainActor.run {
                    self.handlePlayerStatusChange(status: status)
                }
            }
        }
    }
    
    private func handlePlayerStatusChange(status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            print("DEBUG: [SIMPLE VIDEO PLAYER] Player ready to play")
            if autoplay && !hasStarted {
                setupPlayer()
            }
        case .failed:
            if let error = player?.currentItem?.error {
                print("ERROR: [SIMPLE VIDEO PLAYER] Player failed: \(error)")
            }
        case .unknown:
            print("DEBUG: [SIMPLE VIDEO PLAYER] Player status unknown")
        @unknown default:
            print("DEBUG: [SIMPLE VIDEO PLAYER] Player status unknown default")
        }
    }
    
    private func cleanup() {
        print("DEBUG: [SIMPLE VIDEO PLAYER] Cleaning up player")
        
        player?.pause()
        player = nil
        hasStarted = false
        
        // Remove observers
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Preview
#if DEBUG
struct SimpleVideoPlayer_Previews: PreviewProvider {
    static var previews: some View {
        SimpleVideoPlayer(
            url: URL(string: "https://example.com/video.mp4")!,
            autoplay: true,
            autoReplay: false,
            mute: true
        )
        .frame(width: 300, height: 200)
        .previewDisplayName("Simple Video Player")
    }
}
#endif