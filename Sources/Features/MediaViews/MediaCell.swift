//
//  MediaCell.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI
import AVFoundation

// Global video visibility manager
class VideoVisibilityManager: ObservableObject {
    static let shared = VideoVisibilityManager()
    
    private init() {}
    
    func videoEnteredFullScreen(_ videoMid: String) {
        print("DEBUG: [VIDEO VISIBILITY] Video \(videoMid) entered full-screen - pausing handled by SimpleVideoPlayer")
    }
    
    func videoExitedFullScreen(_ videoMid: String) {
        print("DEBUG: [VIDEO VISIBILITY] Video \(videoMid) exited full-screen")
        // Videos will resume playing when they become visible again
    }
}

// MARK: - MediaCell
struct MediaCell: View, Equatable {
    let parentTweet: Tweet
    let attachmentIndex: Int
    let aspectRatio: Float      // passed in by MediaGrid or MediaBrowser
    
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var showFullScreen = false
    @State private var isVisible = false
    @State private var shouldLoadVideo: Bool
    @State private var onVideoFinished: (() -> Void)?
    @State private var isMuted: Bool = MuteState.shared.isMuted
    let showMuteButton: Bool
    let forceRefreshTrigger: Int
    @ObservedObject var videoManager: VideoManager
    
    init(parentTweet: Tweet, attachmentIndex: Int, aspectRatio: Float = 1.0, shouldLoadVideo: Bool = false, onVideoFinished: (() -> Void)? = nil, showMuteButton: Bool = true, isVisible: Bool = false, videoManager: VideoManager, forceRefreshTrigger: Int = 0) {
        self.parentTweet = parentTweet
        self.attachmentIndex = attachmentIndex
        self.aspectRatio = aspectRatio
        self.shouldLoadVideo = shouldLoadVideo
        self.onVideoFinished = onVideoFinished
        self.showMuteButton = showMuteButton
        self._isVisible = State(initialValue: isVisible)
        self.videoManager = videoManager
        self.forceRefreshTrigger = forceRefreshTrigger
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
                            isVisible: isVisible,
                            autoPlay: videoManager.shouldPlayVideo(for: attachment.mid),
                            videoManager: videoManager, // Pass VideoManager for reactive playback
                            onVideoFinished: onVideoFinished,
                            contentType: attachment.type,
                            cellAspectRatio: CGFloat(aspectRatio),
                            videoAspectRatio: CGFloat(attachment.aspectRatio ?? 1.0),
                            showNativeControls: false, // Disable native controls to allow fullscreen tap
                            isMuted: isMuted,
                            onVideoTap: {
                                showFullScreen = true
                            },
                            disableAutoRestart: true,
                            mode: .mediaCell
                        )
                        .onAppear {
                            print("DEBUG: [MEDIA CELL \(attachment.mid)] SimpleVideoPlayer appeared - isVisible: \(isVisible), autoPlay: \(videoManager.shouldPlayVideo(for: attachment.mid))")
                            
                            // Preload video for immediate display
                            if let url = attachment.getUrl(baseUrl) {
                                SharedAssetCache.shared.preloadVideo(for: url)
                            }
                        }
                        .onChange(of: isVisible) { newIsVisible in
                            print("DEBUG: [MEDIA CELL \(attachment.mid)] isVisible changed to: \(newIsVisible)")
                        }
                        .onChange(of: MuteState.shared.isMuted) { newMuteState in
                            print("DEBUG: [MEDIA CELL \(attachment.mid)] Global mute state changed to: \(newMuteState)")
                            isMuted = newMuteState
                            print("DEBUG: [MEDIA CELL \(attachment.mid)] Local mute state updated to: \(newMuteState)")
                        }
                        .overlay(
                            // Video controls overlay
                            Group {
                                VStack {
                                    Spacer()
                                    HStack {
                                        // Video time remaining label in bottom left corner
                                        if videoManager.shouldPlayVideo(for: attachment.mid) && isVisible {
                                            VideoTimeRemainingLabel(mid: attachment.mid)
                                                .padding(.leading, 8)
                                                .padding(.bottom, 8)
                                        }
                                        
                                        Spacer()
                                        
                                        // Mute button in bottom right corner (only if showMuteButton is true)
                                        if showMuteButton {
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
                                handleTap()
                            }
                    }
                case "audio":
                    SimpleAudioPlayer(url: url, autoPlay: videoManager.shouldPlayVideo(for: attachment.mid) && isVisible)
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
                            .onTapGesture {
                                handleTap()
                            }
                    } else if isLoading {
                        // Show cached placeholder while loading original image
                        if let cachedImage = imageCache.getCompressedImage(for: attachment, baseUrl: baseUrl) {
                            Image(uiImage: cachedImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .overlay(
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                        .background(Color.black.opacity(0.3))
                                        .clipShape(Circle())
                                        .padding(4),
                                    alignment: .topTrailing
                                )
                                .onTapGesture {
                                    handleTap()
                                }
                        } else {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(1.2)
                                .onTapGesture {
                                    handleTap()
                                }
                        }
                    } else {
                        // Show cached placeholder if available, otherwise gray background
                        if let cachedImage = imageCache.getCompressedImage(for: attachment, baseUrl: baseUrl) {
                            Image(uiImage: cachedImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .onTapGesture {
                                    handleTap()
                                }
                        } else {
                            Color.gray.opacity(0.3)
                                .onTapGesture {
                                    handleTap()
                                }
                        }
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
            // Set visibility to true immediately when cell appears
            isVisible = true
            
            // Refresh mute state from preferences when cell appears
            MuteState.shared.refreshFromPreferences()
        }
        .onDisappear {
            // Set visibility to false when cell disappears
            isVisible = false
        }
        .onChange(of: isVisible) { newValue in
            if newValue && image == nil {
                loadImage()
            }
        }
        
        .onReceive(NotificationCenter.default.publisher(for: .appDidBecomeActive)) { _ in
            // Restore video state when app becomes active
            if attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video" {
                print("DEBUG: [MEDIA CELL \(attachment.mid)] App became active - ensuring video is loaded")
                shouldLoadVideo = true
            }
        }
        
        .fullScreenCover(isPresented: $showFullScreen) {
            MediaBrowserView(
                tweet: parentTweet,
                initialIndex: attachmentIndex
            )
        }
        .onChange(of: showFullScreen) { newValue in
            if newValue {
                // Video is going into full-screen mode
                VideoVisibilityManager.shared.videoEnteredFullScreen(attachment.mid)
            } else {
                // Video is exiting full-screen mode
                VideoVisibilityManager.shared.videoExitedFullScreen(attachment.mid)
            }
        }
        
    }
    
    private func handleTap() {
        // Use internal full screen logic
        switch attachment.type.lowercased() {
        case "video", "hls_video":
            // Open full screen for videos
            showFullScreen = true
        case "audio":
            // Toggle audio playback - handled by SimpleAudioPlayer
            break
        case "image":
            // Open full-screen for images
            showFullScreen = true
        default:
            // Open full-screen for other types
            return
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
    
    
    
    // MARK: - Equatable
    static func == (lhs: MediaCell, rhs: MediaCell) -> Bool {
        // Only compare the essential properties that should trigger recomposition
        return lhs.parentTweet.mid == rhs.parentTweet.mid &&
        lhs.attachmentIndex == rhs.attachmentIndex &&
        lhs.aspectRatio == rhs.aspectRatio &&
        lhs.shouldLoadVideo == rhs.shouldLoadVideo &&
        lhs.showMuteButton == rhs.showMuteButton
    }
}

// MARK: - MuteButton
struct MuteButton: View {
    @EnvironmentObject var muteState: MuteState
    
    var body: some View {
        Button(action: {
            muteState.toggleMute()
        }) {
            Image(systemName: muteState.isMuted ? "speaker.slash" : "speaker.wave.2")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.4))
                .clipShape(Circle())
                .contentShape(Circle())
        }

    }
}

// MARK: - VideoTimeRemainingLabel
struct VideoTimeRemainingLabel: View {
    let mid: String
    @State private var isVisible = true
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var timeObserver: Any?
    @State private var hideTimer: Timer?
    
    var body: some View {
        Group {
            if isVisible {
                Text(formatTimeRemaining())
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .transition(.opacity)
            }
        }
        .onAppear {
            setupTimeObserver()
            startHideTimer()
        }
        .onDisappear {
            removeTimeObserver()
            stopHideTimer()
        }
    }
    
    private func setupTimeObserver() {
        // Time observer functionality moved to SimpleVideoPlayer
        // This component is simplified to avoid conflicts with new system
    }
    
    private func removeTimeObserver() {
        // Time observer functionality moved to SimpleVideoPlayer
        timeObserver = nil
    }
    
    private func startHideTimer() {
        // Cancel any existing timer
        stopHideTimer()
        
        // Start new timer to hide after 3 seconds
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                isVisible = false
            }
        }
    }
    
    private func stopHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }
    
    private func formatTimeRemaining() -> String {
        let remaining = max(0, duration - currentTime)
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let seconds = Int(remaining) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}


