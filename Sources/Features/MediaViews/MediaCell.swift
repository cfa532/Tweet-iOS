//
//  MediaCell.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/5/20.
//

import SwiftUI
import AVFoundation
import Combine

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

// MARK: - Video List Provider Environment Key

/// Closure type for providing a video list for fullscreen navigation.
/// Parameters: (videoMid, outerTweetId, mediaTweetId, attachmentIndex) → (list, startIndex)?
typealias VideoListProvider = (_ videoMid: String, _ outerTweetId: String, _ mediaTweetId: String, _ attachmentIndex: Int) -> ([VideoPlaybackInfo], Int)?

private struct VideoListProviderKey: EnvironmentKey {
    static let defaultValue: VideoListProvider? = nil
}

extension EnvironmentValues {
    var videoListProvider: VideoListProvider? {
        get { self[VideoListProviderKey.self] }
        set { self[VideoListProviderKey.self] = newValue }
    }
}

// MARK: - MediaCell
struct MediaCell: View, Equatable, MediaCellDelegate {
    let parentTweet: Tweet
    let attachmentIndex: Int
    let aspectRatio: Float      // passed in by MediaGrid or MediaBrowser
    let shouldLoadVideo: Bool
    let onVideoFinished: (() -> Void)?
    let isEmbedded: Bool
    let cellTweetId: String?    // ID of visible cell in feed (retweet ID for retweets, quoting tweet ID for quoted tweets)
    
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var showFullScreen = false
    @State private var isVisible = false
    @State private var isOpeningFullScreen = false
    @State private var shouldAutoPlay = false
    @State private var effectiveBaseUrl: URL
    @State private var foregroundObserver: NSObjectProtocol? = nil
    @State private var videoReloadTrigger = false
    @State private var videoFrame: CGRect = .zero
    @State private var isInViewport: Bool = false
    @State private var imageLoadTask: Task<Void, Never>?
    @ObservedObject private var muteState = MuteState.shared
    @Environment(\.videoListProvider) private var videoListProvider

    private var videoIdentifier: String? {
        guard let attachments = parentTweet.attachments,
              attachmentIndex >= 0,
              attachmentIndex < attachments.count else { return nil }
        let attachment = attachments[attachmentIndex]
        let mediaTweetId = parentTweet.mid
        let outerTweetId = cellTweetId ?? mediaTweetId
        return "\(outerTweetId)_\(mediaTweetId)_\(attachment.mid)_\(attachmentIndex)"
    }

    init(parentTweet: Tweet, attachmentIndex: Int, aspectRatio: Float = 1.0, shouldLoadVideo: Bool = false, onVideoFinished: (() -> Void)? = nil, isVisible: Bool = false, isEmbedded: Bool = false, cellTweetId: String? = nil) {
        self.parentTweet = parentTweet
        self.attachmentIndex = attachmentIndex
        self.aspectRatio = aspectRatio
        self.shouldLoadVideo = shouldLoadVideo
        self.onVideoFinished = onVideoFinished
        self._isVisible = State(initialValue: isVisible)
        self.isEmbedded = isEmbedded
        self.cellTweetId = cellTweetId
        
        // Initialize effectiveBaseUrl with fallback chain
        let initialBaseUrl = parentTweet.author?.baseUrl 
            ?? HproseInstance.shared.appUser.baseUrl 
            ?? HproseInstance.baseUrl
        self._effectiveBaseUrl = State(initialValue: initialBaseUrl)
        
        // Initialize shouldAutoPlay based on initial conditions
        // Global VideoPlaybackCoordinator manages all video playback via notifications
        // Videos will receive .shouldPlayVideo notifications when they should play
        if let attachments = parentTweet.attachments,
           attachmentIndex >= 0 && attachmentIndex < attachments.count {
            let attachment = attachments[attachmentIndex]
            let isVideo = attachment.type == .video || attachment.type == .hls_video
            if isVideo {
                if isEmbedded {
                    // Embedded/quoted tweet preview: autoplay when visible (like regular videos)
                    // Note: isVisible is set via onAppear/onDisappear which may fire early
                    // but SimpleVideoPlayer checks actual viewport visibility before playing
                    self._shouldAutoPlay = State(initialValue: shouldLoadVideo && isVisible)
                } else {
                    // Regular videos and embedded videos: coordinator sends notifications to control playback
                    // Initial state is false, coordinator will send play command when appropriate
                    self._shouldAutoPlay = State(initialValue: false)
                }
            } else {
                self._shouldAutoPlay = State(initialValue: false)
            }
        } else {
            self._shouldAutoPlay = State(initialValue: false)
        }
    }
    
    private let imageCache = ImageCacheManager.shared
    
    private var attachment: MimeiFileType {
        guard let attachments = parentTweet.attachments,
              attachmentIndex >= 0 && attachmentIndex < attachments.count else {
            return MimeiFileType(mid: "", mediaType: .unknown)
        }
        return attachments[attachmentIndex]
    }
    
    private var isVideoAttachment: Bool {
        return attachment.type == .video || attachment.type == .hls_video
    }
    
    /// Update effectiveBaseUrl based on current author's baseUrl
    private func updateEffectiveBaseUrl() {
        let newBaseUrl = parentTweet.author?.baseUrl 
            ?? HproseInstance.shared.appUser.baseUrl 
            ?? HproseInstance.baseUrl
        
        // Only update if changed to avoid unnecessary view updates
        if effectiveBaseUrl != newBaseUrl {
            effectiveBaseUrl = newBaseUrl
        }
    }
    
    var body: some View {
        // CRITICAL PERFORMANCE: Use fixed layout to prevent constraint solving
        // The trace shows massive time in Auto Layout constraint generation (103ms+)
        // By using GeometryReader with fixed frames, we bypass constraint system entirely
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            
            Group {
                if let url = attachment.getUrl(effectiveBaseUrl) {
                    switch attachment.type {
                    case .video, .hls_video:
                        // Video content with absolute positioning - no flexible frames
                        videoPlayerViewContent(url: url, width: width, height: height)
                    case .audio:
                        // Audio autoplay controlled by visibility
                        SimpleAudioPlayer(url: url, autoPlay: isVisible)
                            .environmentObject(MuteState.shared)
                            .frame(width: width, height: height, alignment: .center)
                            .onTapGesture {
                                if !isEmbedded {
                                    handleTap()
                                }
                            }
                    case .image:
                        // CRITICAL: Use absolute frames to avoid constraint updates
                        imageViewContent(width: width, height: height)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                handleTap()
                            }
                    default:
                        // Documents (PDF, Word, etc.) are shown in DocumentAttachmentsView, not in MediaGrid
                        Color.clear
                            .frame(width: width, height: height, alignment: .center)
                    }
                } else {
                    Color.clear
                        .frame(width: width, height: height, alignment: .center)
                }
            }
        }
        .clipped() // Prevent content overflow without expensive masking
        .onAppear {
            // Set visibility to true immediately when cell appears
            // onAppear fires when any portion of the view becomes visible
            isVisible = true

            // Update effectiveBaseUrl in case author's baseUrl has been resolved since init
            updateEffectiveBaseUrl()

            // MEMORY FIX: Mark video as visible to prevent eviction
            if isVideoAttachment, attachment.getUrl(effectiveBaseUrl) != nil {
                let mediaID = attachment.mid
                SharedAssetCache.shared.markAsVisible(mediaID)
                VideoStateCache.shared.markAsVisible(attachment.mid)
                print("👁️ [MediaCell] Marked video as visible: \(attachment.mid) (mediaID: \(mediaID))")
            }

            // For embedded videos, viewport visibility is checked via GeometryReader in videoPlayerViewContent
            // No need to enable autoplay here - it will be enabled when the video enters the viewport

            // Load image if not already loaded - ONLY for image attachments
            if attachment.type == .image && image == nil {
                loadImage()
            }

            // Grid-level debouncing handles video preloading
            // Individual cells just track visibility for playback

            // Setup foreground observer to reload resources if released during background
            setupForegroundObserver()

            // Phase 3: Register as delegate for direct video control communication
            if let videoIdentifier {
                VideoPlaybackCoordinator.shared.registerDelegate(self, forIdentifier: videoIdentifier)
            }
        }
        .onDisappear {
            // Set visibility to false immediately when cell disappears
            isVisible = false

            // Cancel any pending image loads to prevent memory leaks
            imageLoadTask?.cancel()
            imageLoadTask = nil
            GlobalImageLoadManager.shared.cancelLoad(id: attachment.mid)

            // Clean up foreground observer
            if let observer = foregroundObserver {
                NotificationCenter.default.removeObserver(observer)
                foregroundObserver = nil
            }

            // Phase 3: Unregister delegate
            if let videoIdentifier {
                VideoPlaybackCoordinator.shared.unregisterDelegate(forIdentifier: videoIdentifier)
            }

            // MEMORY FIX: Mark video as not visible when cell disappears
            // Cleanup is handled by background timer (every 10s) to preserve preloading
            if isVideoAttachment, attachment.getUrl(effectiveBaseUrl) != nil {
                let mediaID = attachment.mid

                // Mark as not visible (allows cleanup after grace period)
                SharedAssetCache.shared.markAsNotVisible(mediaID)
                VideoStateCache.shared.markAsNotVisible(attachment.mid)

                // Cancel active loading tasks to stop wasting bandwidth/memory
                // But DON'T release the player yet - it might be in preload window
                SharedAssetCache.shared.cancelLoadingForOutOfSightTweet(parentTweet.mid)

                print("🔄 [MediaCell] Marked not visible, stopped loading for \(attachment.mid) (mediaID: \(mediaID))")
            }
        }
        .onChange(of: isVisible) { _, newValue in
            // Update effectiveBaseUrl when becoming visible (author may have been resolved)
            if newValue {
                updateEffectiveBaseUrl()
            }
            
            // For embedded videos in detail views, enable autoplay when visible
            // In detail views, they autoplay independently (not managed by coordinator)
            // In feed views, embedded videos are managed by VideoPlaybackCoordinator
            if isEmbedded && isVideoAttachment && newValue {
                // Only autoplay embedded videos if we're actually in a detail view
                // In feed/list views, the coordinator will manage playback
                if NavigationStateManager.shared.isDetailViewActive {
                    shouldAutoPlay = true
                }
            }
        }
        
        // Phase 3: Using delegate-based communication for pause/stop commands
        // Keeping notification listener for play commands from SharedVideoPlayerManager
        .onReceive(NotificationCenter.default.publisher(for: .shouldPlayVideo)) { notification in
            // Extract notification data
            guard let videoMid = notification.userInfo?["videoMid"] as? String,
                  videoMid == attachment.mid else { return }

            // If notification includes full videoId, validate it matches our instance
            if let videoId = notification.userInfo?["videoId"] as? String {
                let ourVideoId = videoIdentifier ?? ""
                guard videoId == ourVideoId else {
                    print("⚠️ [MediaCell] Ignoring play command for different instance - expected: \(ourVideoId), got: \(videoId)")
                    return
                }
            }

            // Ignore duplicate notifications if already playing
            guard !shouldAutoPlay else {
                print("⚠️ [MediaCell] Ignoring duplicate play command for \(attachment.mid) - already set to play")
                return
            }

            print("▶️ [MediaCell] Received coordinated play command for \(attachment.mid) in tweet \(cellTweetId ?? parentTweet.mid)")

            // Always allow playback when we receive a direct command for this instance.
            // VideoPlaybackCoordinator owns the single-primary decision.
            shouldAutoPlay = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .shouldStopAllVideos)) { _ in
            guard isVideoAttachment else { return }

            if shouldAutoPlay {
                print("🛑 [MediaCell] Received stop all videos command for \(attachment.mid) - stopping playback")
            }
            shouldAutoPlay = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDidBecomeActive)) { _ in
            // Update effectiveBaseUrl when app becomes active (author may have been resolved)
            updateEffectiveBaseUrl()

            // Restore video state when app becomes active
            if isVideoAttachment {
                // Note: shouldLoadVideo is controlled by VideoLoadingManager, not overridden here
                // Grid-level debouncing handles video preloading
                // Individual cells just track visibility for playback
            }
        }

        // CRITICAL FIX: Monitor user updates to catch when author's baseUrl is resolved
        // This fixes the race condition where author.baseUrl is nil when cell loads,
        // but gets resolved shortly after by background fetchUser task
        .onReceive(NotificationCenter.default.publisher(for: .userDidUpdate)) { notification in
            // Check if the updated user is this tweet's author
            if let userId = notification.userInfo?["userId"] as? String,
               userId == parentTweet.authorId {
                // Author was updated, refresh effective baseUrl
                updateEffectiveBaseUrl()
            }
        }
        
        .fullScreenCover(isPresented: $showFullScreen) {
            MediaBrowserView(
                tweet: parentTweet,
                initialIndex: attachmentIndex,
                cellTweetId: cellTweetId ?? parentTweet.mid  // Use cell tweet ID if provided, else parent tweet ID
            )
        }
        .onChange(of: showFullScreen) { _, newValue in
            if newValue {
                // Video is going into full-screen mode
                // Pause all MediaCell videos to avoid multiple videos playing
                NotificationCenter.default.post(name: .stopAllVideos, object: nil)

                VideoVisibilityManager.shared.videoEnteredFullScreen(attachment.mid)
                OverlayVisibilityCoordinator.shared.beginOverlay(
                    id: "mediaBrowserFullScreen",
                    source: "MediaCell"
                )
                // Reset loading state once fullscreen is presented
                isOpeningFullScreen = false

                // Set video list for fullscreen navigation if provider is available (e.g. comments)
                if isVideoAttachment,
                   let provider = videoListProvider,
                   let (list, startIndex) = provider(
                    attachment.mid,
                    cellTweetId ?? parentTweet.mid,
                    parentTweet.mid,
                    attachmentIndex
                   ) {
                    FullScreenVideoManager.shared.setVideoList(list, startIndex: startIndex)
                }
            } else {
                // Video is exiting full-screen mode
                VideoVisibilityManager.shared.videoExitedFullScreen(attachment.mid)
                OverlayVisibilityCoordinator.shared.endOverlay(
                    id: "mediaBrowserFullScreen",
                    source: "MediaCell"
                )
            }
        }
    }
    
    private func saveVideoPositionForFullscreen() {
        // Save current playback position before opening fullscreen
        // This allows the video to continue from where it was playing in the cell
        // Get the current time directly from the cached player (more accurate than cached playback info)
        if let cachedState = VideoStateCache.shared.getCachedState(for: attachment.mid) {
            let player = cachedState.player
            let isNearEnd: Bool = {
                guard let item = player.currentItem else { return false }
                let duration = item.duration
                guard duration.isValid, !duration.isIndefinite, duration.seconds > 0 else { return false }
                return duration.seconds - player.currentTime().seconds <= 3.0
            }()
            let currentTime = isNearEnd ? .zero : player.currentTime()
            let wasPlaying = player.rate > 0

            PersistentVideoStateManager.shared.saveState(
                videoMid: attachment.mid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .fullScreen
            )
            print("💾 [MediaCell] Saved video position before opening fullscreen: \(currentTime.seconds)s, wasPlaying: \(wasPlaying)")
        } else if let playbackInfo = VideoStateCache.shared.getCachedPlaybackInfo(for: attachment.mid) {
            // Fallback to cached playback info if player is not available
            PersistentVideoStateManager.shared.saveState(
                videoMid: attachment.mid,
                currentTime: playbackInfo.time,
                wasPlaying: playbackInfo.wasPlaying,
                context: .fullScreen
            )
            print("💾 [MediaCell] Saved video position (fallback) before opening fullscreen: \(playbackInfo.time.seconds)s, wasPlaying: \(playbackInfo.wasPlaying)")
        }
    }
    
    private func handleTap() {
        // Use internal full screen logic
        switch attachment.type {
        case .video, .hls_video:
            // Save current playback position before opening fullscreen
            saveVideoPositionForFullscreen()
            
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
            // Documents are handled by DocumentAttachmentsView
            return
        }
    }
    
    /// Setup observer to detect foreground return and reload image if released
    private func setupForegroundObserver() {
        // Only setup for image attachments
        guard attachment.type == .image else { return }
        
        // Avoid duplicate observers
        guard foregroundObserver == nil else { return }
        
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Only reload if cell is visible and image was released
            guard self.isVisible, self.image == nil, self.attachment.type == .image else { return }
            
            self.loadImage()
        }
    }
    
    private func loadImage() {
        guard let url = attachment.getUrl(effectiveBaseUrl) else {
            // If no URL, ensure isLoading is false
            isLoading = false
            return
        }

        // First, try to get cached image from memory only (fastest, no I/O)
        if let cachedImage = imageCache.getCompressedImageFromMemory(for: attachment) {
            print("DEBUG: [MediaCell] Found image in memory cache for \(attachment.mid)")
            self.image = cachedImage
            self.isLoading = false
            return
        }

        // CRITICAL PERFORMANCE FIX: Disk I/O MUST happen on background thread
        // The getCompressedImage() call does synchronous File I/O which blocks the main thread
        // causing the 227ms hang in -[CALayer _display]
        isLoading = true
        
        // Capture necessary data before entering detached task
        let attachmentCopy = attachment
        let effectiveBaseUrlCopy = effectiveBaseUrl
        let imageCache = imageCache
        
        imageLoadTask?.cancel()
        imageLoadTask = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return }
            // This runs on a background thread; disk I/O stays off the main thread.
            // Disk I/O happens here without blocking UI rendering
            let cachedImage = imageCache.getCompressedImage(for: attachmentCopy)
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                guard !Task.isCancelled,
                      self.isVisible,
                      self.attachment.mid == attachmentCopy.mid else { return }

                self.imageLoadTask = nil
                if let cachedImage = cachedImage {
                    self.image = cachedImage
                    self.isLoading = false
                } else {
                    print("DEBUG: [MediaCell] No cached image found, starting network load for \(attachmentCopy.mid)")
                    // If no cached image at all, visible cells outrank preload/background image work.
                    GlobalImageLoadManager.shared.loadImageCriticalPriority(
                        id: attachmentCopy.mid,
                        url: url,
                        attachment: attachmentCopy,
                        baseUrl: effectiveBaseUrlCopy
                    ) { loadedImage in
                        guard self.isVisible,
                              self.attachment.mid == attachmentCopy.mid else { return }
                        self.image = loadedImage
                        self.isLoading = false
                    }
                }
            }
        }
    }
    
    
    
    // MARK: - Image View Content
    @ViewBuilder
    private func imageViewContent(width: CGFloat, height: CGFloat) -> some View {
        // PERFORMANCE: Absolute positioning eliminates constraint solving
        // No .infinity frames, no padding modifiers - just fixed positions
        if let displayImage = image ?? imageCache.getCompressedImageFromMemory(for: attachment) {
            // Image loaded - show it directly with minimal layers
            Image(uiImage: displayImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height, alignment: .center)
                .clipped()
        } else if isLoading {
            // Loading - show placeholder with spinner
            ZStack {
                Color.gray.opacity(0.2)
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
            }
            .frame(width: width, height: height, alignment: .center)
        } else {
            // No image and not loading - just show placeholder
            Color.gray.opacity(0.2)
                .frame(width: width, height: height, alignment: .center)
        }
    }
    
    // MARK: - Equatable
    static func == (lhs: MediaCell, rhs: MediaCell) -> Bool {
        // Only compare the essential properties that should trigger recomposition
        return lhs.parentTweet.mid == rhs.parentTweet.mid &&
        lhs.attachmentIndex == rhs.attachmentIndex &&
        lhs.aspectRatio == rhs.aspectRatio &&
        lhs.shouldLoadVideo == rhs.shouldLoadVideo
    }
    
    // MARK: - Video Player View
    @ViewBuilder
    private func videoPlayerViewContent(url: URL, width: CGFloat, height: CGFloat) -> some View {
        // PERFORMANCE: Fixed dimensions eliminate recursive size calculations
        ZStack(alignment: .center) {
            Color.black // Background color
            
            SimpleVideoPlayer(
                url: url,
                mid: attachment.mid,
                parentTweetId: parentTweet.mid,
                isVisible: isVisible,
                mediaType: attachment.type,
                authorId: parentTweet.authorId,
                cellTweetId: cellTweetId ?? parentTweet.mid,
                attachmentIndex: attachmentIndex,
                autoPlay: shouldAutoPlay,
                onVideoFinished: onVideoFinished,
                cellAspectRatio: CGFloat(aspectRatio),
                videoAspectRatio: CGFloat(attachment.aspectRatio ?? 1.0),
                showNativeControls: false,
                isMuted: muteState.isMuted,
                onVideoTap: isEmbedded ? nil : {
                    // Save current playback position before opening fullscreen
                    saveVideoPositionForFullscreen()
                    isOpeningFullScreen = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
                        showFullScreen = true
                    }
                },
                disableAutoRestart: true,
                shouldLoadVideo: shouldLoadVideo,
                mode: isEmbedded ? .embeddedDetail : .mediaCell
            )
            .frame(width: width, height: height, alignment: .center)
            .id("video_\(attachment.mid)_\(videoReloadTrigger)")
        }
        .frame(width: width, height: height, alignment: .center)
        .frame(width: width, height: height, alignment: .center)
        .overlay(
            // Invisible overlay to prevent tap propagation to parent views and add long press
            // Only apply gestures in embedded/detail views to avoid interfering with scrolling in feed
            Group {
                if isEmbedded {
                    // Embedded videos in detail views should have gestures
                    Color.clear
                        .frame(width: width, height: height, alignment: .center)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Save current playback position before opening fullscreen
                            saveVideoPositionForFullscreen()
                            isOpeningFullScreen = true
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
                                showFullScreen = true
                            }
                        }
                        .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 50) {
                            handleVideoReload()
                        }
                } else {
                    // Regular feed videos should NOT have gestures to avoid blocking scrolling
                    // Use Color.clear without contentShape to avoid intercepting scroll gestures
                    Color.clear
                        .frame(width: width, height: height, alignment: .center)
                        .allowsHitTesting(false)
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
                    .frame(width: width, height: height, alignment: .center)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: isOpeningFullScreen)
                }
            }
        )
    }
    
    // Preference key to track video frame changes
    private struct VideoFramePreferenceKey: PreferenceKey {
        static var defaultValue: CGRect = .zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            value = nextValue()
        }
    }
    
    /// Check if embedded video is actually visible in the viewport
    private func checkViewportVisibility(geometry: GeometryProxy? = nil, frame: CGRect? = nil) {
        guard isEmbedded && isVideoAttachment else { return }
        
        let currentFrame: CGRect
        if let frame = frame {
            currentFrame = frame
        } else if let geometry = geometry {
            currentFrame = geometry.frame(in: .global)
            videoFrame = currentFrame
        } else if videoFrame != .zero {
            currentFrame = videoFrame
        } else {
            return // No frame information available
        }
        
        // Get screen bounds
        let screenBounds = UIScreen.main.bounds
        
        // Check if video frame intersects with visible screen area
        // Account for safe areas (status bar, navigation bar, tab bar)
        let safeAreaTop: CGFloat = 0 // Will be adjusted if needed
        let safeAreaBottom: CGFloat = 0 // Will be adjusted if needed
        
        let visibleRect = CGRect(
            x: 0,
            y: safeAreaTop,
            width: screenBounds.width,
            height: screenBounds.height - safeAreaTop - safeAreaBottom
        )
        
        let intersection = currentFrame.intersection(visibleRect)
        let isVisibleInViewport = intersection.height > 0 && currentFrame.height > 0 && intersection.height >= currentFrame.height * 0.3 // At least 30% visible
        
        if isVisibleInViewport != isInViewport {
            isInViewport = isVisibleInViewport
            
            if isVisibleInViewport && shouldLoadVideo {
                print("✅ [MediaCell] Embedded video \(attachment.mid) is now in viewport - enabling autoplay")
                shouldAutoPlay = true
            } else if !isVisibleInViewport {
                print("❌ [MediaCell] Embedded video \(attachment.mid) is no longer in viewport - disabling autoplay")
                shouldAutoPlay = false
            }
        }
        
        // Update stored frame
        if geometry != nil {
            videoFrame = currentFrame
        }
    }
    
    private func handleVideoReload() {
        // Provide haptic feedback
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()
        
        // Clear all caches and force reload by toggling shouldLoadVideo
        print("🔄 [VIDEO RELOAD] Long press reload triggered for \(attachment.mid)")
        
        if attachment.getUrl(effectiveBaseUrl) != nil {
            // Clear player cache
            SharedAssetCache.shared.removeInvalidPlayer(for: attachment.mid)
            
            // Clear video state cache
            VideoStateCache.shared.clearCache(for: attachment.mid)
            
            // Clear asset cache
            Task {
                await MainActor.run {
                    SharedAssetCache.shared.clearAssetCache(for: attachment.mid)
                    print("DEBUG: [VIDEO RELOAD] Cleared all caches for \(attachment.mid)")
                }
            }
        }
        
        // Force reload by toggling the reload trigger
        // This will force SimpleVideoPlayer to reinitialize
        videoReloadTrigger.toggle()
        print("✅ [VIDEO RELOAD] Video reload initiated")
    }
}

// MARK: - MediaCellDelegate Implementation (Phase 3)

extension MediaCell {
    func shouldPlayVideo(withMid mid: String) {
        guard mid == attachment.mid else { return }

        // Ignore duplicate notifications if already playing
        guard !shouldAutoPlay else {
            print("⚠️ [MediaCell] Ignoring duplicate play command for \(attachment.mid) - already set to play")
            return
        }

        print("▶️ [MediaCell] Received coordinated play command for \(attachment.mid) in tweet \(cellTweetId ?? parentTweet.mid)")

        // Always allow playback when we receive a direct command for this instance.
        // VideoPlaybackCoordinator owns the single-primary decision.
        shouldAutoPlay = true
    }

    func shouldPauseVideo(withMid mid: String) {
        guard mid == attachment.mid else { return }

        // Ignore duplicate pause notifications if already paused
        guard shouldAutoPlay else {
            print("⚠️ [MediaCell] Ignoring duplicate pause command for \(attachment.mid) - already paused")
            return
        }

        print("⏸️ [MediaCell] Received coordinated pause command for \(attachment.mid)")
        shouldAutoPlay = false
    }

    func shouldStopVideo(withMid mid: String) {
        guard mid == attachment.mid else { return }

        // Ignore duplicate stop notifications if already stopped
        guard shouldAutoPlay else {
            print("⚠️ [MediaCell] Ignoring duplicate stop command for \(attachment.mid) - already stopped")
            return
        }

        print("⏹️ [MediaCell] Received coordinated stop command for \(attachment.mid)")
        shouldAutoPlay = false
    }

    func shouldStopAllVideos() {
        guard isVideoAttachment else { return }
        print("🛑 [MediaCell] Received stop all videos command for \(attachment.mid) - stopping playback")
        shouldAutoPlay = false
    }

    func updateVideoTimer(withMid mid: String, timeRemaining: String) {
        // This is handled by VideoTimerOverlay, which has its own notification listener
        // The delegate method is here for completeness but VideoTimerOverlay still uses notifications
    }

    func appDidBecomeActive() {
        // Update effectiveBaseUrl when app becomes active (author may have been resolved)
        updateEffectiveBaseUrl()
    }

    func userDidUpdate(userId: String) {
        // Check if the updated user is this tweet's author
        if userId == parentTweet.authorId {
            // Update baseUrl in case it changed
            updateEffectiveBaseUrl()
        }
    }

    var isActuallyPlaying: Bool { false }
    var isLoadingForCoordinator: Bool { false }
    var isRecentlyPlaying: Bool { false }
}

// MARK: - MuteButton
struct MuteButton: View {
    @ObservedObject private var muteState = MuteState.shared
    
    var body: some View {
        Button(action: {
            muteState.toggleMute()
        }) {
            Image(systemName: muteState.isMuted ? "speaker.slash" : "speaker.wave.2")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 26, height: 26)
                .background(
                    // Semi-transparent dark background for visibility - no shadow
                    Circle()
                        .fill(Color.black.opacity(0.3))
                )
                .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle()) // Remove default button shadow
    }
}

// MARK: - TimeRemainingDisplay
struct TimeRemainingDisplay: View {
    let timeRemaining: String
    
    var body: some View {
        Text(timeRemaining)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.6))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                // Semi-transparent dark background for visibility - similar to mute button
                Capsule()
                    .fill(Color.black.opacity(0.4))
            )
            .contentShape(Capsule())
    }
}

// MARK: - VideoTimerOverlay
struct VideoTimerOverlay: View {
    let videoMid: String
    @State private var displayLinkObserverID = UUID()
    @State private var timeRemaining: String = "0:00"
    @State private var isVisible: Bool = true
    @State private var hideTimer: Timer?

    var body: some View {
        Group {
            if isVisible {
                TimeRemainingDisplay(timeRemaining: timeRemaining)
                    .transition(.opacity)
            }
        }
        .onAppear {
            isVisible = true
            // PHASE 2: Use centralized display link instead of individual timer
            SharedDisplayLinkManager.shared.addObserver(id: displayLinkObserverID) { _ in
                Self.requestUpdate(for: videoMid)
            }
            startHideTimer()
            // Request immediate update
            requestUpdate()
        }
        .onDisappear {
            // PHASE 2: Remove from centralized display link
            SharedDisplayLinkManager.shared.removeObserver(id: displayLinkObserverID)
            hideTimer?.invalidate()
            hideTimer = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .videoTimerUpdate)) { notification in
            guard let mid = notification.userInfo?["videoMid"] as? String,
                  mid == self.videoMid,
                  let time = notification.userInfo?["timeRemaining"] as? String else {
                return
            }
            timeRemaining = time
        }
    }

    private func startHideTimer() {
        // Cancel any existing hide timer
        hideTimer?.invalidate()

        // Hide after 5 seconds
        // NOTE: Can't use [weak self] for structs (SwiftUI Views), but timer is invalidated properly
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            Task { @MainActor in
                isVisible = false
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func requestUpdate() {
        Self.requestUpdate(for: videoMid)
    }

    private static func requestUpdate(for videoMid: String) {
        NotificationCenter.default.post(
            name: .requestVideoTimerUpdate,
            object: nil,
            userInfo: ["videoMid": videoMid]
        )
    }
}
