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
        print("DEBUG: [VIDEO VISIBILITY] Video \(videoMid) entered full-screen - pausing all other videos")
        VideoCacheManager.shared.pauseAllVideosExcept(videoMid)
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
    
    @State private var play: Bool
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var showFullScreen = false
    @State private var isVisible = false
    @State private var shouldLoadVideo: Bool
    @State private var onVideoFinished: (() -> Void)?
    let showMuteButton: Bool
    let forceRefreshTrigger: Int
    @ObservedObject var videoManager: VideoManager
    
    init(parentTweet: Tweet, attachmentIndex: Int, aspectRatio: Float = 1.0, play: Bool = false, shouldLoadVideo: Bool = false, onVideoFinished: (() -> Void)? = nil, showMuteButton: Bool = true, isVisible: Bool = false, videoManager: VideoManager, forceRefreshTrigger: Int = 0) {
        self.parentTweet = parentTweet
        self.attachmentIndex = attachmentIndex
        self.aspectRatio = aspectRatio
        self._play = State(initialValue: play)
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
                            autoPlay: play,
                            onVideoFinished: onVideoFinished,
                            isVisible: isVisible,
                            contentType: attachment.type,
                            cellAspectRatio: CGFloat(aspectRatio),
                            videoAspectRatio: CGFloat(attachment.aspectRatio ?? 1.0),
                            onVideoTap: {
                                showFullScreen = true
                            },
                            disableAutoRestart: true,
                            mode: .mediaCell
                        )
                        .onAppear {
                            print("DEBUG: [MEDIA CELL \(attachment.mid)] SimpleVideoPlayer appeared - play: \(play), isVisible: \(isVisible), autoPlay: \(play)")
                        }
                        .onChange(of: play) { newPlayValue in
                            print("DEBUG: [MEDIA CELL \(attachment.mid)] play changed to: \(newPlayValue), isVisible: \(isVisible), autoPlay: \(newPlayValue)")
                        }
                        .onChange(of: isVisible) { newIsVisible in
                            print("DEBUG: [MEDIA CELL \(attachment.mid)] isVisible changed to: \(newIsVisible), play: \(play), autoPlay: \(play)")
                        }


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
            // Set visibility to true immediately when cell appears
            isVisible = true
            
            // Refresh mute state from preferences when cell appears
            MuteState.shared.refreshFromPreferences()
            
            // Auto-load videos when they become visible
            if attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video" {
                shouldLoadVideo = true
                // Update play state based on VideoManager
                play = videoManager.shouldPlayVideo(for: attachment.mid)
            }
        }
        .task {
            // Update play state after visibility is set
            if attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video" {
                let newPlayState = videoManager.shouldPlayVideo(for: attachment.mid)
                play = newPlayState
            }
        }
        .onDisappear {
            // Set visibility to false when cell disappears
            isVisible = false
        }
        .onChange(of: isVisible) { newValue in
            if newValue && image == nil {
                loadImage()
            }
            
            // Handle video visibility changes
            if attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video" {
                if newValue {
                    // Video became visible - ensure it's loaded and update play state
                    shouldLoadVideo = true
                    let newPlayState = videoManager.shouldPlayVideo(for: attachment.mid)
                    if play != newPlayState {
                        print("DEBUG: [MEDIA CELL \(attachment.mid)] Video became visible - updating play from \(play) to \(newPlayState)")
                        play = newPlayState
                    }
                } else {
                    // Video became invisible - pause playback
                    if play {
                        print("DEBUG: [MEDIA CELL \(attachment.mid)] Video became invisible - pausing playback")
                        play = false
                    }
                }
            }
        }
        .onChange(of: videoManager.currentVideoIndex) { newIndex in
            // Update play state when VideoManager changes
            if attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video" {
                let newPlayState = videoManager.shouldPlayVideo(for: attachment.mid)
                print("DEBUG: [MEDIA CELL \(attachment.mid)] VideoManager currentVideoIndex changed to \(newIndex) - current play: \(play), newPlayState: \(newPlayState), isVisible: \(isVisible)")
                if play != newPlayState {
                    print("DEBUG: [MEDIA CELL \(attachment.mid)] VideoManager changed - updating play from \(play) to \(newPlayState)")
                    play = newPlayState
                }
            }
        }
        .onChange(of: forceRefreshTrigger) { _ in
            // Force refresh play state when grid becomes visible
            if attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video" {
                let newPlayState = videoManager.shouldPlayVideo(for: attachment.mid)
                if play != newPlayState {
                    print("DEBUG: [MEDIA CELL \(attachment.mid)] Force refresh triggered - updating play from \(play) to \(newPlayState)")
                    play = newPlayState
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDidBecomeActive)) { _ in
            // Restore video state when app becomes active
            if attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video" {
                // Force refresh video layer to fix black screen issue
                VideoCacheManager.shared.forceRefreshVideoLayer(for: attachment.mid)
                
                // Ensure video is loaded
                shouldLoadVideo = true
                
                // Update play state based on visibility and VideoManager
                let newPlayState = isVisible && videoManager.shouldPlayVideo(for: attachment.mid)
                if play != newPlayState {
                    print("DEBUG: [MEDIA CELL \(attachment.mid)] App became active - updating play from \(play) to \(newPlayState) (isVisible: \(isVisible))")
                    play = newPlayState
                }
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
    

    
    // MARK: - Equatable
    static func == (lhs: MediaCell, rhs: MediaCell) -> Bool {
        // Only compare the essential properties that should trigger recomposition
        return lhs.parentTweet.mid == rhs.parentTweet.mid &&
               lhs.attachmentIndex == rhs.attachmentIndex &&
               lhs.aspectRatio == rhs.aspectRatio &&
               lhs.play == rhs.play &&
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
        guard let player = VideoCacheManager.shared.getVideoPlayer(for: mid, url: URL(string: "placeholder")!, isHLS: true) else {
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
            VideoCacheManager.shared.getVideoPlayer(for: mid, url: URL(string: "placeholder")!, isHLS: true)?.removeTimeObserver(observer)
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


