//
//  MediaCell.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI
import AVFoundation

// MARK: - MediaCell
struct MediaCell: View {
    let parentTweet: Tweet
    let attachmentIndex: Int
    let aspectRatio: Float      // passed in by MediaGrid or MediaBrowser
    
    @State private var play: Bool
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var showFullScreen = false
    @State private var isVisible = false
    @State private var shouldLoadVideo: Bool
    @State private var onVideoFinished: (() -> Void)?
    let showMuteButton: Bool
    
    init(parentTweet: Tweet, attachmentIndex: Int, aspectRatio: Float = 1.0, play: Bool = false, shouldLoadVideo: Bool = false, onVideoFinished: (() -> Void)? = nil, showMuteButton: Bool = true) {
        self.parentTweet = parentTweet
        self.attachmentIndex = attachmentIndex
        self.aspectRatio = aspectRatio
        self._play = State(initialValue: play)
        self.shouldLoadVideo = shouldLoadVideo
        self.onVideoFinished = onVideoFinished
        self.showMuteButton = showMuteButton
    }
    
    private let imageCache = ImageCacheManager.shared
    
    private var attachment: MimeiFileType {
        guard let attachments = parentTweet.attachments,
              attachmentIndex >= 0 && attachmentIndex < attachments.count else {
            return MimeiFileType(mid: "", type: "unknown")
        }
        return attachments[attachmentIndex]
    }
    
    private var baseUrl: URL {
        return parentTweet.author?.baseUrl ?? HproseInstance.baseUrl
    }
    
    var body: some View {
        Group {
            if let url = attachment.getUrl(baseUrl) {
                switch attachment.type.lowercased() {
                case "video", "hls_video":
                    // Only create video player if we should load video
                    if shouldLoadVideo {
                        SimpleVideoPlayer(
                            url: url,
                            mid: attachment.mid,
                            autoPlay: play,
                            onVideoFinished: onVideoFinished,
                            isVisible: isVisible,
                            contentType: attachment.type,
                            cellAspectRatio: CGFloat(aspectRatio),
                            videoAspectRatio: CGFloat(attachment.aspectRatio ?? 1.0),
                            showNativeControls: false,
                            onVideoTap: {
                                showFullScreen = true
                            },
                            showCustomControls: false,
                            disableAutoRestart: false,
                        )
                        .environmentObject(MuteState.shared)
                        .onReceive(MuteState.shared.$isMuted) { isMuted in
                            print("DEBUG: [MEDIA CELL] Mute state changed to: \(isMuted)")
                        }
                        
                        .overlay(
                            // Mute button in bottom right corner (only if showMuteButton is true)
                            Group {
                                if showMuteButton {
                                    VStack {
                                        Spacer()
                                        HStack {
                                            Spacer()
                                            MuteButton()
                                                .padding(.trailing, 8)
                                                .padding(.bottom, 8)
                                        }
                                    }
                                }
                            }
                        )
                    } else {
                        // Show placeholder for videos that haven't been loaded yet
                        Color.black
                            .aspectRatio(contentMode: .fill)
                            .overlay(
                                Image(systemName: "play.circle")
                                    .font(.system(size: 40))
                                    .foregroundColor(.white)
                            )
                            .onTapGesture {
                                // Open full screen for video placeholders
                                showFullScreen = true
                            }
                    }
                case "audio":
                    SimpleAudioPlayer(url: url, autoPlay: play && isVisible)
                        .environmentObject(MuteState.shared)
                        .onTapGesture {
                            handleTap()
                        }
                case "image":
                    if let image = image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipped()
                    } else if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(1.2)
                    } else {
                        Color.gray.opacity(0.3)
                    }
                default:
                    EmptyView()
                }
            } else {
                EmptyView()
            }
        }
        .onAppear(perform: loadImage)
        .onAppear {
            // Refresh mute state from preferences when cell appears
            MuteState.shared.refreshFromPreferences()
            
            // Set visibility for videos
            if attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video" {
                isVisible = true
                // Auto-load videos when they become visible
                shouldLoadVideo = true
                // Log video player decision when cell appears
                logVideoPlayerDecision()
            }
        }
        .onDisappear {
            isVisible = false
        }
        .onChange(of: isVisible) { newValue in
            if newValue && image == nil {
                loadImage()
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            MediaBrowserView(
                tweet: parentTweet,
                initialIndex: attachmentIndex
            )
        }
    }
    
    private func handleTap() {
        switch attachment.type.lowercased() {
        case "video", "hls_video":
            // Open full screen for videos
            showFullScreen = true
        case "audio":
            // Toggle audio playback
            play.toggle()
        case "image":
            // Open full-screen for images
            showFullScreen = true
        default:
            // Open full-screen for other types
            showFullScreen = true
        }
    }
    
    private func loadImage() {
        guard let url = attachment.getUrl(baseUrl) else { return }
        
        // First, try to get cached image immediately
        if let cachedImage = imageCache.getCompressedImage(for: attachment, baseUrl: baseUrl) {
            self.image = cachedImage
            return
        }
        
        // If no cached image, start loading
        isLoading = true
        Task {
            if let loadedImage = await imageCache.loadAndCacheImage(from: url, for: attachment, baseUrl: baseUrl) {
                await MainActor.run {
                    self.image = loadedImage
                    self.isLoading = false
                }
            } else {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }
    
    private func logVideoPlayerDecision() {
        let hasCachedPlayer = VideoCacheManager.shared.hasVideoPlayer(for: attachment.mid)
        if shouldLoadVideo {
            print("DEBUG: [MEDIA CELL] Creating video player for \(attachment.mid) - shouldLoadVideo: \(shouldLoadVideo), hasCachedPlayer: \(hasCachedPlayer)")
        } else {
            print("DEBUG: [MEDIA CELL] Showing placeholder for \(attachment.mid) - shouldLoadVideo: \(shouldLoadVideo), hasCachedPlayer: \(hasCachedPlayer)")
        }
    }
}

// MARK: - MuteButton
struct MuteButton: View {
    @EnvironmentObject var muteState: MuteState
    
    var body: some View {
        Button(action: {
            print("DEBUG: [MUTE BUTTON] Tapped")
            muteState.toggleMute()
            print("DEBUG: [MUTE BUTTON] Mute state after toggle: \(muteState.isMuted)")
        }) {
            Image(systemName: muteState.isMuted ? "speaker.slash" : "speaker.wave.2")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.4))
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .onAppear {
            print("DEBUG: [MUTE BUTTON] Appeared with mute state: \(muteState.isMuted)")
        }
        .onReceive(muteState.$isMuted) { isMuted in
            print("DEBUG: [MUTE BUTTON] Mute state changed to: \(isMuted)")
        }
    }
}

// MARK: - VideoTimeLabel
struct VideoTimeLabel: View {
    let mid: String
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var timeObserver: Any?
    
    var body: some View {
        Text(formatTimeRemaining())
            .font(.caption)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onAppear {
                setupTimeObserver()
            }
            .onDisappear {
                removeTimeObserver()
            }
    }
    
    private func setupTimeObserver() {
        guard let player = VideoCacheManager.shared.getVideoPlayer(for: mid, url: URL(string: "placeholder")!) else {
            return
        }
        
        // Get duration
        if let durationTime = player.currentItem?.duration {
            duration = durationTime.seconds
        }
        
        // Add time observer
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { time in
            currentTime = time.seconds
        }
    }
    
    private func removeTimeObserver() {
        if let observer = timeObserver {
            VideoCacheManager.shared.getVideoPlayer(for: mid, url: URL(string: "placeholder")!)?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }
    
    private func formatTimeRemaining() -> String {
        let remaining = max(0, duration - currentTime)
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        return String(format: "-%d:%02d", minutes, seconds)
    }
}


