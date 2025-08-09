//
//  ContextualVideoPlayer.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  Context-specific video players using shared asset cache
//

import SwiftUI
import AVKit
import AVFoundation

/// Video player optimized for different contexts using shared asset cache
struct ContextualVideoPlayer: View {
    let url: URL
    let context: PlaybackContext
    let onVideoFinished: (() -> Void)?
    let onVideoTap: (() -> Void)?
    
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var hasStarted = false
    @ObservedObject private var muteState = MuteState.shared
    
    enum PlaybackContext {
        case mediaCell(autoPlay: Bool)
        case detail(isSelected: Bool)
        case fullscreen
        
        var shouldAutoPlay: Bool {
            switch self {
            case .mediaCell(let autoPlay): return autoPlay
            case .detail(let isSelected): return isSelected
            case .fullscreen: return true
            }
        }
        
        var shouldMute: Bool {
            switch self {
            case .mediaCell: return MuteState.shared.isMuted
            case .detail: return false  // Always unmuted in detail
            case .fullscreen: return false  // Always unmuted in fullscreen
            }
        }
        
        var debugName: String {
            switch self {
            case .mediaCell: return "MEDIA_CELL"
            case .detail: return "DETAIL"
            case .fullscreen: return "FULLSCREEN"
            }
        }
    }
    
    var body: some View {
        Group {
            if let player = player {
                VideoPlayer(player: player)
                    .onAppear {
                        setupPlaybackForContext()
                    }
                    .onChange(of: context.shouldAutoPlay) { shouldPlay in
                        handlePlaybackChange(shouldPlay: shouldPlay)
                    }
                    .onChange(of: muteState.isMuted) { isMuted in
                        updateMuteState()
                    }
                    .onTapGesture {
                        onVideoTap?()
                    }
            } else if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .onAppear {
                        loadVideo()
                    }
            } else {
                // Fallback placeholder
                Color.black
                    .overlay(
                        Image(systemName: "play.circle")
                            .font(.system(size: 40))
                            .foregroundColor(.white)
                    )
                    .onTapGesture {
                        onVideoTap?()
                    }
            }
        }
        .onDisappear {
            cleanup()
        }
    }
    
    // MARK: - Video Loading
    private func loadVideo() {
        Task {
            let cachedAsset = await VideoAssetCache.shared.getAsset(for: url)
            
            await MainActor.run {
                let playerItem = cachedAsset.createPlayerItem()
                let newPlayer = AVPlayer(playerItem: playerItem)
                
                // Configure player for context
                configurePlayerForContext(newPlayer)
                
                // Set up observers
                setupPlayerObservers(newPlayer, playerItem: playerItem)
                
                self.player = newPlayer
                self.isLoading = false
                
                print("DEBUG: [\(context.debugName) PLAYER] Created player for: \(url.lastPathComponent)")
                
                // Start playback if needed
                setupPlaybackForContext()
            }
        }
    }
    
    private func configurePlayerForContext(_ player: AVPlayer) {
        player.isMuted = context.shouldMute
        player.automaticallyWaitsToMinimizeStalling = true
        
        // Context-specific configuration
        switch context {
        case .mediaCell:
            // Optimize for grid scrolling
            break
        case .detail:
            // Optimize for single video focus
            break
        case .fullscreen:
            // Optimize for immersive experience
            break
        }
    }
    
    private func setupPlayerObservers(_ player: AVPlayer, playerItem: AVPlayerItem) {
        // Observe player item status
        Task {
            for await status in playerItem.publisher(for: \.status).values {
                await MainActor.run {
                    handlePlayerStatusChange(status: status)
                }
            }
        }
        
        // Observe end of playback
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            print("DEBUG: [\(context.debugName) PLAYER] Video finished")
            onVideoFinished?()
        }
    }
    
    private func handlePlayerStatusChange(status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            print("DEBUG: [\(context.debugName) PLAYER] Ready to play")
            if context.shouldAutoPlay && !hasStarted {
                startPlayback()
            }
        case .failed:
            if let error = player?.currentItem?.error {
                print("ERROR: [\(context.debugName) PLAYER] Failed: \(error)")
            }
        case .unknown:
            print("DEBUG: [\(context.debugName) PLAYER] Status unknown")
        @unknown default:
            break
        }
    }
    
    // MARK: - Playback Control
    private func setupPlaybackForContext() {
        guard let player = player else { return }
        
        if context.shouldAutoPlay && !hasStarted {
            startPlayback()
        } else if !context.shouldAutoPlay && hasStarted {
            pausePlayback()
        }
    }
    
    private func handlePlaybackChange(shouldPlay: Bool) {
        if shouldPlay && !hasStarted {
            startPlayback()
        } else if !shouldPlay && hasStarted {
            pausePlayback()
        }
    }
    
    private func startPlayback() {
        guard let player = player, player.currentItem?.status == .readyToPlay else { return }
        
        player.play()
        hasStarted = true
        print("DEBUG: [\(context.debugName) PLAYER] Started playback")
    }
    
    private func pausePlayback() {
        guard let player = player else { return }
        
        player.pause()
        hasStarted = false
        print("DEBUG: [\(context.debugName) PLAYER] Paused playback")
    }
    
    private func updateMuteState() {
        guard let player = player else { return }
        
        let shouldMute = context.shouldMute
        if player.isMuted != shouldMute {
            player.isMuted = shouldMute
            print("DEBUG: [\(context.debugName) PLAYER] Mute changed to: \(shouldMute)")
        }
    }
    
    private func cleanup() {
        player?.pause()
        player = nil
        hasStarted = false
        NotificationCenter.default.removeObserver(self)
        print("DEBUG: [\(context.debugName) PLAYER] Cleaned up")
    }
}

// MARK: - Convenience Initializers
extension ContextualVideoPlayer {
    /// Create player for MediaCell context
    static func forMediaCell(
        url: URL,
        autoPlay: Bool,
        onVideoFinished: (() -> Void)? = nil,
        onVideoTap: (() -> Void)? = nil
    ) -> ContextualVideoPlayer {
        return ContextualVideoPlayer(
            url: url,
            context: .mediaCell(autoPlay: autoPlay),
            onVideoFinished: onVideoFinished,
            onVideoTap: onVideoTap
        )
    }
    
    /// Create player for TweetDetailView context
    static func forDetail(
        url: URL,
        isSelected: Bool,
        onVideoTap: (() -> Void)? = nil
    ) -> ContextualVideoPlayer {
        return ContextualVideoPlayer(
            url: url,
            context: .detail(isSelected: isSelected),
            onVideoFinished: nil,
            onVideoTap: onVideoTap
        )
    }
    
    /// Create player for MediaBrowserView context
    static func forFullscreen(
        url: URL,
        onVideoTap: (() -> Void)? = nil
    ) -> ContextualVideoPlayer {
        return ContextualVideoPlayer(
            url: url,
            context: .fullscreen,
            onVideoFinished: nil,
            onVideoTap: onVideoTap
        )
    }
}
