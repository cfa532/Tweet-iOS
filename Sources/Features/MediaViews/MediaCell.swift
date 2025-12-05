//
//  MediaCell.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/5/20.
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
    let visibleTweetId: String? // The ID of the visible tweet in feed (for retweets)
    
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var showFullScreen = false
    @State private var isVisible = false
    @State private var shouldLoadVideo: Bool
    @State private var onVideoFinished: (() -> Void)?
    @State private var preloadTask: Task<Void, Never>?
    @State private var isPreloading = false
    @State private var isOpeningFullScreen = false
    let showMuteButton: Bool
    @ObservedObject var videoManager: VideoManager
    @ObservedObject private var muteState = MuteState.shared
    
    init(parentTweet: Tweet, attachmentIndex: Int, aspectRatio: Float = 1.0, shouldLoadVideo: Bool = false, onVideoFinished: (() -> Void)? = nil, showMuteButton: Bool = true, isVisible: Bool = false, videoManager: VideoManager, visibleTweetId: String? = nil) {
        self.parentTweet = parentTweet
        self.attachmentIndex = attachmentIndex
        self.aspectRatio = aspectRatio
        self.visibleTweetId = visibleTweetId
        self.shouldLoadVideo = shouldLoadVideo
        self.onVideoFinished = onVideoFinished
        self.showMuteButton = showMuteButton
        self._isVisible = State(initialValue: isVisible)
        self.videoManager = videoManager
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
        // Use author's baseUrl if available, otherwise use appUser's baseUrl
        // If both are nil, use real IP from HproseInstance (resolved at app start)
        return parentTweet.author?.baseUrl 
            ?? HproseInstance.shared.appUser.baseUrl 
            ?? HproseInstance.baseUrl
    }
    
    private var isVideoAttachment: Bool {
        return attachment.type == .video || attachment.type == .hls_video
    }
    
    var body: some View {
        Group {
            if let url = attachment.getUrl(baseUrl) {
                switch attachment.type {
                case .video, .hls_video:
                    // MediaGrid already sets fixed frame - content should fill parent naturally
                    videoPlayerView(url: url)
                        .clipped()
                case .audio:
                    SimpleAudioPlayer(url: url, autoPlay: videoManager.shouldPlayVideo(for: attachment.mid) && isVisible)
                        .environmentObject(MuteState.shared)
                        .onTapGesture {
                            handleTap()
                        }
                case .image:
                    // MediaGrid already sets fixed frame - content should fill parent naturally
                    // Use .fill to maintain aspect ratio and clip overflow
                    Group {
                        if let image = image {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if isLoading {
                            // Show cached placeholder while loading original image
                            if let cachedImage = imageCache.getCompressedImage(for: attachment, baseUrl: baseUrl) {
                                Image(uiImage: cachedImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                // Reserve space with placeholder color
                                Color.gray.opacity(0.3)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        } else {
                            // Show cached placeholder if available, otherwise gray background
                            if let cachedImage = imageCache.getCompressedImage(for: attachment, baseUrl: baseUrl) {
                                Image(uiImage: cachedImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                // Reserve space with placeholder color
                                Color.gray.opacity(0.3)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                    .clipped()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(
                        // Show loading indicator only when loading and no cached image
                        Group {
                            if isLoading, imageCache.getCompressedImage(for: attachment, baseUrl: baseUrl) == nil {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .scaleEffect(1.2)
                            } else if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                                    .background(Color.gray.opacity(0.3))
                                    .clipShape(Circle())
                                    .padding(4)
                            }
                        },
                        alignment: isLoading && imageCache.getCompressedImage(for: attachment, baseUrl: baseUrl) != nil ? .topTrailing : .center
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleTap()
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
        
        .onReceive(NotificationCenter.default.publisher(for: .appDidBecomeActive)) { _ in
            // Restore video state when app becomes active
            if isVideoAttachment {
                // Note: shouldLoadVideo is controlled by VideoLoadingManager, not overridden here
                // Grid-level debouncing handles video preloading
                // Individual cells just track visibility for playback
            }
        }
        
        .fullScreenCover(isPresented: $showFullScreen) {
            MediaBrowserView(
                tweet: parentTweet,
                initialIndex: attachmentIndex,
                sourceTweetId: visibleTweetId ?? parentTweet.mid // Use visibleTweetId if available
            )
        }
        .onChange(of: showFullScreen) { _, newValue in
            if newValue {
                // Video is going into full-screen mode
                VideoVisibilityManager.shared.videoEnteredFullScreen(attachment.mid)
                // Reset loading state once fullscreen is presented
                isOpeningFullScreen = false
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
            // Show loading spinner for videos
            isOpeningFullScreen = true
            // Delay opening fullscreen to allow spinner to render
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
                showFullScreen = true
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
        guard let url = attachment.getUrl(baseUrl) else { 
            // If no URL, ensure isLoading is false
            isLoading = false
            return 
        }
        
        // First, try to get cached image immediately
        if let cachedImage = imageCache.getCompressedImage(for: attachment, baseUrl: baseUrl) {
            self.image = cachedImage
            self.isLoading = false
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
            // Completion is already @MainActor, so state updates will happen on main thread
            // Use Task to ensure SwiftUI view updates properly
            Task { @MainActor in
                self.image = loadedImage
                self.isLoading = false
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
    
    // MARK: - Video Player View
    @ViewBuilder
    private func videoPlayerView(url: URL) -> some View {
        SimpleVideoPlayer(
                url: url,
                mid: attachment.mid,
                parentTweetId: parentTweet.mid,
                isVisible: isVisible,
                mediaType: attachment.type,
                autoPlay: videoManager.shouldPlayVideo(for: attachment.mid),
                videoManager: videoManager,
                onVideoFinished: onVideoFinished,
                cellAspectRatio: CGFloat(aspectRatio),
                videoAspectRatio: CGFloat(attachment.aspectRatio ?? 1.0),
                showNativeControls: false,
                isMuted: muteState.isMuted,
                onVideoTap: {
                    isOpeningFullScreen = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
                        showFullScreen = true
                    }
                },
                disableAutoRestart: true,
                shouldLoadVideo: shouldLoadVideo,
                mode: .mediaCell
            )
            .overlay(
                // Invisible overlay to prevent tap propagation to parent views and add long press
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isOpeningFullScreen = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
                            showFullScreen = true
                        }
                    }
                    .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 50) {
                        handleVideoReload()
                    }
            )
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
        .overlay(
            // Loading spinner overlay when opening fullscreen
            Group {
                if isOpeningFullScreen {
                    ZStack {
                        Color.black.opacity(0.4)
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                    }
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: isOpeningFullScreen)
                }
            }
        )
    }
    
    private func handleVideoReload() {
        // Provide haptic feedback
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()
        
        // Clear all caches and force reload by toggling shouldLoadVideo
        print("🔄 [VIDEO RELOAD] Long press reload triggered for \(attachment.mid)")
        
        if let url = attachment.getUrl(baseUrl) {
            // Clear player cache
            SharedAssetCache.shared.removeInvalidPlayer(for: SharedAssetCache.shared.extractMediaID(from: url) ?? attachment.mid)
            
            // Clear video state cache
            VideoStateCache.shared.clearCache(for: attachment.mid)
            
            // Clear asset cache
            Task {
                await MainActor.run {
                    SharedAssetCache.shared.clearAssetCache(for: SharedAssetCache.shared.extractMediaID(from: url) ?? attachment.mid)
                    print("DEBUG: [VIDEO RELOAD] Cleared all caches for \(attachment.mid)")
                }
            }
        }
        
        // Force reload by clearing cache and resetting state
        // The state change will trigger proper reload through onChange observer
        shouldLoadVideo = false
        // Use Task to avoid blocking
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second delay
            shouldLoadVideo = true
            print("✅ [VIDEO RELOAD] Video reload initiated")
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
