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
    @State private var preloadTask: Task<Void, Never>?
    @State private var isPreloading = false
    @State private var cancelVideoTrigger = 0
    @State private var localForceRefreshTrigger: Int = 0
    let showMuteButton: Bool
    let forceRefreshTrigger: Int
    @ObservedObject var videoManager: VideoManager
    @ObservedObject private var muteState = MuteState.shared
    
    init(parentTweet: Tweet, attachmentIndex: Int, aspectRatio: Float = 1.0, shouldLoadVideo: Bool = false, onVideoFinished: (() -> Void)? = nil, showMuteButton: Bool = true, isVisible: Bool = false, videoManager: VideoManager, forceRefreshTrigger: Int = 0, cancelVideoTrigger: Int = 0) {
        self.parentTweet = parentTweet
        self.attachmentIndex = attachmentIndex
        self.aspectRatio = aspectRatio
        self.shouldLoadVideo = shouldLoadVideo
        self.onVideoFinished = onVideoFinished
        self.showMuteButton = showMuteButton
        self._isVisible = State(initialValue: isVisible)
        self.videoManager = videoManager
        self.forceRefreshTrigger = forceRefreshTrigger
        self._cancelVideoTrigger = State(initialValue: cancelVideoTrigger)
    }
    
    private let imageCache = ImageCacheManager.shared
    
    private var attachment: MimeiFileType {
        guard let attachments = parentTweet.attachments,
              attachmentIndex >= 0 && attachmentIndex < attachments.count else {
            return MimeiFileType(mid: "", mediaType: .unknown)
        }
        return attachments[attachmentIndex]
    }
    
    private var baseUrl: URL {
        return parentTweet.author?.baseUrl ?? HproseInstance.baseUrl
    }
    
    private var isVideoAttachment: Bool {
        return attachment.type == .video || attachment.type == .hls_video
    }
    
    var body: some View {
        Group {
            if let url = attachment.getUrl(baseUrl) {
                switch attachment.type {
                case .video, .hls_video:
                    
                    if shouldLoadVideo {
                        videoPlayerView(url: url)
                    } else {
                        // Show placeholder for videos that haven't been loaded yet
                        ZStack {
                            Color.gray.opacity(0.3)
                                .aspectRatio(contentMode: .fill)
                                .overlay(
                                    Group {
                                        if isPreloading {
                                            // Show loading indicator during preload
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                                .scaleEffect(0.8)
                                                .background(Color.gray.opacity(0.4))
                                                .clipShape(Circle())
                                                .padding(4)
                                        } else {
                                            // Show play button when not preloading
                                            Image(systemName: "play.circle")
                                                .font(.system(size: 40))
                                                .foregroundColor(.white)
                                        }
                                    }
                                )
                                .onTapGesture {
                                    // Open full screen for video placeholders
                                    handleTap()
                                }
                            
                            // Invisible overlay to prevent tap propagation to parent views and add long press
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    // This prevents the tap from reaching parent views
                                    handleTap()
                                }
                                .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 50) {
                                    // FIRST: Clear all caches immediately
                                    print("DEBUG: [VIDEO RELOAD] Long press load triggered for \(attachment.mid)")
                                    
                                    if let url = attachment.getUrl(baseUrl) {
                                        // Clear player cache
                                        SharedAssetCache.shared.removeInvalidPlayer(for: url)
                                        
                                        // Clear asset cache
                                        Task {
                                            await MainActor.run {
                                                SharedAssetCache.shared.clearAssetCache(for: url)
                                                print("DEBUG: [VIDEO RELOAD] Cleared all caches for \(attachment.mid)")
                                            }
                                        }
                                    }
                                    
                                    // Note: shouldLoadVideo is controlled by VideoLoadingManager, not overridden here
                                }
                        }
                    }
                    // #endif
                case .audio:
                    SimpleAudioPlayer(url: url, autoPlay: videoManager.shouldPlayVideo(for: attachment.mid) && isVisible)
                        .environmentObject(MuteState.shared)
                        .onTapGesture {
                            handleTap()
                        }
                case .image:
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
                                        .background(Color.gray.opacity(0.3))
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
        .onAppear {
            // Set visibility to true immediately when cell appears
            isVisible = true
            
            // Load image if not already loaded - ONLY for image attachments
            if attachment.type == .image && image == nil {
                loadImage()
            }
            
            // Grid-level debouncing handles video preloading
            // Individual cells just track visibility for playback
        }
        .onDisappear {
            // Set visibility to false when cell disappears
            isVisible = false
            
            // Cancel any ongoing preload tasks
            cancelPreloadTask()
            
            // Cancel any pending image loads to prevent memory leaks
            GlobalImageLoadManager.shared.cancelLoad(id: "\(attachment.mid)_\(baseUrl.absoluteString)")
        }
        .onChange(of: isVisible) { _, newValue in
            // Handle visibility changes - image loading is now handled in onAppear
            // This prevents conflicts with the onAppear block
        }
        .onChange(of: forceRefreshTrigger) { _, _ in
            // Force refresh triggered by MediaGridView - update video state
            if isVideoAttachment {
                // The SimpleVideoPlayer will automatically update its autoPlay state
                // based on the videoManager.shouldPlayVideo() call
            }
        }
        .onChange(of: cancelVideoTrigger) { _, _ in
            // Video cancellation triggered by MediaGridView
            if isVideoAttachment {
                print("DEBUG: [MediaCell] Received cancelVideoTrigger for \(attachment.mid)")
                // The SimpleVideoPlayer will handle the actual cancellation
            }
        }
        
        .onReceive(NotificationCenter.default.publisher(for: .appDidBecomeActive)) { _ in
            // Restore video state when app becomes active
            if isVideoAttachment {
                // Note: shouldLoadVideo is controlled by VideoLoadingManager, not overridden here
                // Grid-level debouncing handles video preloading
                // Individual cells just track visibility for playback
            }
        }
        
        .fullScreenVideoPlayer()
        .fullScreenCover(isPresented: $showFullScreen) {
            MediaBrowserView(
                tweet: parentTweet,
                initialIndex: attachmentIndex
            )
        }
        .onChange(of: showFullScreen) { _, newValue in
            if newValue {
                // Video is going into full-screen mode
                VideoVisibilityManager.shared.videoEnteredFullScreen(attachment.mid)
            } else {
                // Video is exiting full-screen mode
                VideoVisibilityManager.shared.videoExitedFullScreen(attachment.mid)
            }
        }
    }
    
    // MARK: - Video Preloading Methods
    
    /// Start background preloading of video assets
    /// DISABLED: Grid-level debouncing now handles all video preloading
    private func startBackgroundPreloading() {
        // This method is disabled because grid-level debouncing now handles all video preloading
        // Individual cells no longer need to preload videos independently
        print("DEBUG: [MediaCell] startBackgroundPreloading() called but disabled - grid-level debouncing handles preloading")
        return
    }
    
    /// Cancel ongoing preload task
    private func cancelPreloadTask() {
        preloadTask?.cancel()
        preloadTask = nil
        isPreloading = false
    }
    
    private func handleTap() {
        // Use internal full screen logic
        switch attachment.type {
        case .video, .hls_video:
            // Open full screen for videos using the new video player
            let baseUrl = parentTweet.author?.baseUrl ?? HproseInstance.baseUrl
            if let videoURL = attachment.getUrl(baseUrl) {
                FullScreenVideoManager.shared.presentVideo(url: videoURL, tweetId: parentTweet.mid)
            }
        case .audio:
            // Toggle audio playback - handled by SimpleAudioPlayer
            break
        case .image:
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
        
        // If no cached image, start loading with global manager
        isLoading = true
        
        // Use normal priority for grid images (they're visible but not as critical as detail view)
        GlobalImageLoadManager.shared.loadImageNormalPriority(
            id: "\(attachment.mid)_\(baseUrl.absoluteString)",
            url: url,
            attachment: attachment,
            baseUrl: baseUrl
        ) { loadedImage in
            self.image = loadedImage
            self.isLoading = false
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
    
    // MARK: - Video Player View
    @ViewBuilder
    private func videoPlayerView(url: URL) -> some View {
        ZStack {
            SimpleVideoPlayer(
                url: url,
                mid: attachment.mid,
                isVisible: isVisible,
                autoPlay: videoManager.shouldPlayVideo(for: attachment.mid),
                videoManager: videoManager,
                onVideoFinished: onVideoFinished,
                cellAspectRatio: CGFloat(aspectRatio),
                videoAspectRatio: CGFloat(attachment.aspectRatio ?? 1.0),
                showNativeControls: false,
                isMuted: muteState.isMuted,
                onVideoTap: {
                    let baseUrl = parentTweet.author?.baseUrl ?? HproseInstance.baseUrl
                    if let videoURL = attachment.getUrl(baseUrl) {
                        FullScreenVideoManager.shared.presentVideo(url: videoURL, tweetId: parentTweet.mid)
                    }
                },
                disableAutoRestart: true,
                forceRefreshTrigger: localForceRefreshTrigger,
                cancelVideoTrigger: cancelVideoTrigger,
                shouldLoadVideo: shouldLoadVideo,
                mode: .mediaCell
            )
            
            // Invisible overlay to prevent tap propagation to parent views and add long press
            Color.clear
                .contentShape(Rectangle())
            .onTapGesture {
                let baseUrl = parentTweet.author?.baseUrl ?? HproseInstance.baseUrl
                if let videoURL = attachment.getUrl(baseUrl) {
                    FullScreenVideoManager.shared.presentVideo(url: videoURL, tweetId: parentTweet.mid)
                }
            }
                .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 50) {
                    handleVideoReload()
                }
        }
        // Note: SimpleVideoPlayer handles its own lifecycle internally
        .overlay(
            // Video controls overlay
            Group {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        if showMuteButton {
                            MuteButton()
                                .padding(.trailing, 8)
                                .padding(.bottom, 8)
                        }
                    }
                }
            }
        )
    }
    
    private func handleVideoReload() {
        // FIRST: Clear all caches immediately
        print("DEBUG: [VIDEO RELOAD] Long press reload triggered for \(attachment.mid)")
        
        if let url = attachment.getUrl(baseUrl) {
            // Clear player cache
            SharedAssetCache.shared.removeInvalidPlayer(for: url)
            
            // Clear video state cache
            VideoStateCache.shared.clearCache(for: attachment.mid)
            
            // Clear asset cache
            Task {
                await MainActor.run {
                    SharedAssetCache.shared.clearAssetCache(for: url)
                    print("DEBUG: [VIDEO RELOAD] Cleared all caches for \(attachment.mid)")
                }
            }
        }
        
        // THEN: Force a complete reload
        shouldLoadVideo = false
        localForceRefreshTrigger += 1 // Increment local trigger to notify SimpleVideoPlayer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            shouldLoadVideo = true
        }
    }
}

// MARK: - MuteButton
struct MuteButton: View {
    @ObservedObject private var muteState = MuteState.shared
    
    var body: some View {
        Button(action: {
            muteState.toggleMute()
        }) {
            Image(systemName: muteState.isMuted ? "speaker.slash" : "speaker.wave.2")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 30, height: 30)
                .background(Color.gray.opacity(0.4))
                .clipShape(Circle())
                .contentShape(Circle())
        }
    }
}




