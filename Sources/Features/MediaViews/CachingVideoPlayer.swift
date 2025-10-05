//
//  CachingVideoPlayer.swift
//  Tweet
//
//  Simple CachingVideoPlayer for MediaBrowserView and chat screens
//

import SwiftUI
import AVKit
import AVFoundation

struct CachingVideoPlayer: View {
    let url: URL
    let mid: String
    let isVisible: Bool
    let mediaType: MediaType
    let autoPlay: Bool
    let videoAspectRatio: CGFloat
    let showNativeControls: Bool
    let isMuted: Bool
    let onVideoTap: (() -> Void)?
    
    @State private var player: AVPlayer?
    @State private var cachingPlayerItem: CachingPlayerItem?
    @State private var playerDelegate: CachingVideoPlayerDelegate?
    @State private var isLoading = true
    @State private var hasFinishedPlaying = false
    @State private var loadFailed = false
    @State private var videoCompletionObserver: NSObjectProtocol?
    
    init(
        url: URL,
        mid: String,
        isVisible: Bool,
        mediaType: MediaType,
        autoPlay: Bool = true,
        videoAspectRatio: CGFloat = 16.0/9.0,
        showNativeControls: Bool = true,
        isMuted: Bool = false,
        onVideoTap: (() -> Void)? = nil,
    ) {
        self.url = url
        self.mid = mid
        self.isVisible = isVisible
        self.mediaType = mediaType
        self.autoPlay = autoPlay
        self.videoAspectRatio = videoAspectRatio
        self.showNativeControls = showNativeControls
        self.isMuted = isMuted
        self.onVideoTap = onVideoTap
    }
    
    var body: some View {
        Group {
            if let player = player {
                if showNativeControls {
                    VideoPlayer(player: player)
                        .aspectRatio(videoAspectRatio, contentMode: .fit)
                        .clipped()
                        .onTapGesture {
                            onVideoTap?()
                        }
                } else {
                    VideoPlayer(player: player)
                        .aspectRatio(videoAspectRatio, contentMode: .fit)
                        .clipped()
                        .onTapGesture {
                            onVideoTap?()
                        }
                }
            } else if isLoading {
                ProgressView("Loading video...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.1))
            } else if loadFailed {
                Color.black
                    .overlay(
                        VStack {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title)
                                .foregroundColor(.white)
                            Text("Failed to load video")
                                .foregroundColor(.white)
                        }
                    )
            } else {
                Color.black
                    .overlay(
                        Image(systemName: "play.circle")
                            .font(.system(size: 40))
                            .foregroundColor(.white)
                    )
            }
        }
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            cleanupPlayer()
        }
        .onChange(of: isVisible) { _, visible in
            if visible && autoPlay {
                player?.play()
            } else {
                player?.pause()
            }
        }
    }
    
    private func setupPlayer() {
        Task {
            do {
                print("DEBUG: [CachingVideoPlayer] Setting up player for \(mid)")
                
                
                // Use SharedAssetCache.getOrCreatePlayer to get cached player or create new one
                let newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(for: url, tweetId: mid, mediaType: mediaType)
                
                await MainActor.run {
                    // Store references
                    self.player = newPlayer
                    
                    // Configure player
                    newPlayer.isMuted = isMuted
                    
                    // Set up delegate for CachingPlayerItem if it exists
                    if let cachingPlayerItem = newPlayer.currentItem as? CachingPlayerItem {
                        self.cachingPlayerItem = cachingPlayerItem
                        
                        let delegate = CachingVideoPlayerDelegate(
                            onReadyToPlay: { [weak newPlayer] in
                                DispatchQueue.main.async {
                                    self.isLoading = false
                                    if self.autoPlay && self.isVisible {
                                        newPlayer?.play()
                                    }
                                }
                            },
                            onPlaybackStalled: {
                                print("DEBUG: [CachingVideoPlayer] Playback stalled for \(self.mid)")
                            },
                            onDidFailToPlay: { error in
                                DispatchQueue.main.async {
                                    print("DEBUG: [CachingVideoPlayer] Failed to play \(self.mid): \(error?.localizedDescription ?? "Unknown error")")
                                    self.handleLoadFailure()
                                }
                            },
                            onDidFinishDownloading: { filePath in
                                print("DEBUG: [CachingVideoPlayer] Finished downloading \(self.mid) to \(filePath)")
                            },
                            onDidDownloadBytes: { bytesDownloaded, bytesExpected in
                                print("DEBUG: [CachingVideoPlayer] Downloaded \(bytesDownloaded)/\(bytesExpected) bytes for \(self.mid)")
                            },
                            onDownloadingFailed: { error in
                                DispatchQueue.main.async {
                                    print("DEBUG: [CachingVideoPlayer] Download failed for \(self.mid): \(error.localizedDescription)")
                                    self.handleLoadFailure()
                                }
                            }
                        )
                        
                        // Store the delegate to prevent deallocation
                        self.playerDelegate = delegate
                        cachingPlayerItem.delegate = delegate
                    } else {
                        // For regular AVPlayerItem, just set loading to false when ready
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.isLoading = false
                            if self.autoPlay && self.isVisible {
                                newPlayer.play()
                            }
                        }
                    }
                    
                    // Set up video completion observer
                    self.setupVideoCompletionObserver(newPlayer)
                    
                    // Start playback if needed
                    if self.autoPlay && self.isVisible {
                        newPlayer.play()
                    }
                }
            } catch {
                await MainActor.run {
                    print("DEBUG: [CachingVideoPlayer] Failed to setup player for \(mid): \(error)")
                    handleLoadFailure()
                }
            }
        }
    }
    
    
    private func handleLoadFailure() {
        isLoading = false
        loadFailed = true
    }
    
    private func setupVideoCompletionObserver(_ player: AVPlayer) {
        // Remove existing observer if any
        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        // Add new observer for video completion
        videoCompletionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            print("DEBUG: [CachingVideoPlayer] Video finished playing for \(mid)")
            
            // Reset video to beginning
            player.seek(to: .zero) { finished in
                guard finished else { return }
                
                // Auto-restart if in fullscreen (autoPlay is true)
                if autoPlay {
                    print("DEBUG: [CachingVideoPlayer] Auto-restarting video for \(mid)")
                    player.play()
                } else {
                    print("DEBUG: [CachingVideoPlayer] Video ready to replay for \(mid)")
                }
            }
        }
    }
    
    private func cleanupPlayer() {
        // Remove video completion observer
        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
        
        player?.pause()
        player = nil
        cachingPlayerItem = nil
        playerDelegate = nil
    }
}

// MARK: - CachingPlayerItem Delegate
private class CachingVideoPlayerDelegate: NSObject, CachingPlayerItemDelegate {
    private let onReadyToPlay: () -> Void
    private let onPlaybackStalled: () -> Void
    private let onDidFailToPlay: (Error?) -> Void
    private let onDidFinishDownloading: (String) -> Void
    private let onDidDownloadBytes: (Int, Int) -> Void
    private let onDownloadingFailed: (Error) -> Void
    
    init(
        onReadyToPlay: @escaping () -> Void,
        onPlaybackStalled: @escaping () -> Void,
        onDidFailToPlay: @escaping (Error?) -> Void,
        onDidFinishDownloading: @escaping (String) -> Void,
        onDidDownloadBytes: @escaping (Int, Int) -> Void,
        onDownloadingFailed: @escaping (Error) -> Void
    ) {
        self.onReadyToPlay = onReadyToPlay
        self.onPlaybackStalled = onPlaybackStalled
        self.onDidFailToPlay = onDidFailToPlay
        self.onDidFinishDownloading = onDidFinishDownloading
        self.onDidDownloadBytes = onDidDownloadBytes
        self.onDownloadingFailed = onDownloadingFailed
    }
    
    func playerItemReadyToPlay(_ playerItem: CachingPlayerItem) {
        onReadyToPlay()
    }
    
    func playerItemPlaybackStalled(_ playerItem: CachingPlayerItem) {
        onPlaybackStalled()
    }
    
    func playerItemDidFailToPlay(_ playerItem: CachingPlayerItem, withError error: Error?) {
        onDidFailToPlay(error)
    }
    
    func playerItem(_ playerItem: CachingPlayerItem, didFinishDownloadingFileAt filePath: String) {
        onDidFinishDownloading(filePath)
    }
    
    func playerItem(_ playerItem: CachingPlayerItem, didDownloadBytesSoFar bytesDownloaded: Int, outOf bytesExpected: Int) {
        onDidDownloadBytes(bytesDownloaded, bytesExpected)
    }
    
    func playerItem(_ playerItem: CachingPlayerItem, downloadingFailedWith error: Error) {
        onDownloadingFailed(error)
    }
}