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

// MARK: - MediaCell
struct MediaCell: View, Equatable {
    let parentTweet: Tweet
    let attachmentIndex: Int
    let aspectRatio: Float      // passed in by MediaGrid or MediaBrowser
    let isEmbedded: Bool
    let sourceTweetId: String?  // ID of tweet user is viewing (retweet ID for retweets)
    
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var showFullScreen = false
    @State private var isVisible = false
    @State private var shouldLoadVideo: Bool
    @State private var onVideoFinished: (() -> Void)?
    @State private var preloadTask: Task<Void, Never>?
    @State private var isPreloading = false
    @State private var isOpeningFullScreen = false
    @State private var shouldAutoPlay = false // Track if video should autoplay
    @State private var effectiveBaseUrl: URL // Reactive baseUrl that updates when author's baseUrl changes
    @State private var foregroundObserver: NSObjectProtocol? = nil // Observer for app foreground events
    @ObservedObject var videoManager: VideoManager
    @ObservedObject private var muteState = MuteState.shared
    
    init(parentTweet: Tweet, attachmentIndex: Int, aspectRatio: Float = 1.0, shouldLoadVideo: Bool = false, onVideoFinished: (() -> Void)? = nil, isVisible: Bool = false, videoManager: VideoManager, isEmbedded: Bool = false, sourceTweetId: String? = nil) {
        self.parentTweet = parentTweet
        self.attachmentIndex = attachmentIndex
        self.aspectRatio = aspectRatio
        self.shouldLoadVideo = shouldLoadVideo
        self.onVideoFinished = onVideoFinished
        self._isVisible = State(initialValue: isVisible)
        self.videoManager = videoManager
        self.isEmbedded = isEmbedded
        self.sourceTweetId = sourceTweetId
        
        // Initialize effectiveBaseUrl with fallback chain
        let initialBaseUrl = parentTweet.author?.baseUrl 
            ?? HproseInstance.shared.appUser.baseUrl 
            ?? HproseInstance.baseUrl
        self._effectiveBaseUrl = State(initialValue: initialBaseUrl)
        
        // Initialize shouldAutoPlay based on initial conditions
        if let attachments = parentTweet.attachments,
           attachmentIndex >= 0 && attachmentIndex < attachments.count {
            let attachment = attachments[attachmentIndex]
            let isVideo = attachment.type == .video || attachment.type == .hls_video
            if isVideo {
                if isEmbedded {
                    // Embedded/quoted tweet preview: allow autoplay for the first attachment only.
                    self._shouldAutoPlay = State(initialValue: shouldLoadVideo && isVisible && attachmentIndex == 0)
                } else {
                    self._shouldAutoPlay = State(initialValue: videoManager.shouldPlayVideo(for: attachment.mid) && shouldLoadVideo && isVisible)
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
        Group {
            if let url = attachment.getUrl(effectiveBaseUrl) {
                switch attachment.type {
                case .video, .hls_video:
                    // MediaGrid already sets fixed frame - content should fill parent naturally
                    videoPlayerViewContent(url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .audio:
                    SimpleAudioPlayer(url: url, autoPlay: videoManager.shouldPlayVideo(for: attachment.mid) && isVisible)
                        .environmentObject(MuteState.shared)
                        .onTapGesture {
                            if !isEmbedded {
                                handleTap()
                            }
                        }
                case .image:
                    // STABILITY: MediaGrid already sets fixed frame - content must maintain stable dimensions
                    // All image states (loading, cached, loaded) use same frame to prevent layout shifts
                    ZStack {
                        // Background: Always show gray placeholder to reserve space
                        Color.gray.opacity(0.2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        
                        // Layer 1: Cached/Loaded image (fills parent with aspect ratio preserved)
                        // CRITICAL: Use memory-only cache check to avoid blocking disk I/O in view body
                        if let displayImage = image ?? imageCache.getCompressedImageFromMemory(for: attachment) {
                            Image(uiImage: displayImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipped()
                                // STABILITY: Use transition to smooth appearance, reducing visual jump
                                .transition(.opacity)
                        }
                        
                        // Layer 2: Loading indicator (only show if no cached image available)
                        // CRITICAL: Use memory-only cache check to avoid blocking disk I/O
                        if isLoading, imageCache.getCompressedImageFromMemory(for: attachment) == nil {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(1.2)
                        } else if isLoading, image == nil {
                            // Small indicator when refining cached image
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.6)
                                .padding(8)
                                .background(
                                    Circle()
                                        .fill(Color.black.opacity(0.3))
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                .padding(8)
                        }
                    }
                    // STABILITY: Fixed frame prevents any size changes during loading
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !isEmbedded {
                            handleTap()
                        }
                    }
                    // STABILITY: ID ensures SwiftUI doesn't recreate view when image changes
                    .id("image_\(attachment.mid)")
                default:
                    // Documents (PDF, Word, etc.) are shown in DocumentAttachmentsView, not in MediaGrid
                    EmptyView()
                }
            } else {
                EmptyView()
            }
        }
        .onAppear {
            // Set visibility to true immediately when cell appears
            // onAppear fires when any portion of the view becomes visible
            isVisible = true
            
            // Update effectiveBaseUrl in case author's baseUrl has been resolved since init
            updateEffectiveBaseUrl()
            
            // For video attachments, update autoplay state based on current conditions
            if isVideoAttachment {
                if isEmbedded {
                    shouldAutoPlay = shouldLoadVideo && attachmentIndex == 0
                } else {
                    let managerSays = videoManager.shouldPlayVideo(for: attachment.mid)
                    shouldAutoPlay = managerSays && shouldLoadVideo
                    
                    // CRITICAL FIX: If this is a new grid that just appeared and has videos,
                    // ensure VideoManager knows to play the first video
                    if !managerSays && shouldLoadVideo {
                        // Check if this video is in the manager's list
                        if let videoIndex = videoManager.videoMids.firstIndex(of: attachment.mid) {
                            // This video is in the list but not set to play
                            // If it's the current index, we should play it
                            if videoIndex == videoManager.currentVideoIndex {
                                print("⚠️ [MediaCell] VideoManager has video at current index but shouldPlayVideo=false. Forcing shouldAutoPlay=true")
                                shouldAutoPlay = true
                            }
                        }
                    }
                }
            }
            
            // Load image if not already loaded - ONLY for image attachments
            if attachment.type == .image && image == nil {
                loadImage()
            }
            
            // Grid-level debouncing handles video preloading
            // Individual cells just track visibility for playback
            
            // Setup foreground observer to reload resources if released during background
            setupForegroundObserver()
        }
        .onDisappear {
            // Set visibility to false immediately when cell disappears
            // onDisappear fires when the view is scrolled completely off screen
            isVisible = false
            
            // Cancel any ongoing preload tasks
            cancelPreloadTask()
            
            // Cancel any pending image loads to prevent memory leaks
            GlobalImageLoadManager.shared.cancelLoad(id: "\(attachment.mid)_\(effectiveBaseUrl.absoluteString)")
            
            // Clean up foreground observer
            if let observer = foregroundObserver {
                NotificationCenter.default.removeObserver(observer)
                foregroundObserver = nil
            }
        }
        .onChange(of: isVisible) { _, newValue in
            // Update effectiveBaseUrl when becoming visible (author may have been resolved)
            if newValue {
                updateEffectiveBaseUrl()
            }
            
            // Update autoplay state when visibility changes for video attachments
            if isVideoAttachment && newValue {
                if isEmbedded {
                    shouldAutoPlay = shouldLoadVideo && attachmentIndex == 0
                } else {
                    shouldAutoPlay = videoManager.shouldPlayVideo(for: attachment.mid) && shouldLoadVideo
                }
            }
        }
        
        .onChange(of: shouldLoadVideo) { _, newValue in
            // Update autoplay state when shouldLoadVideo changes for video attachments
            if isVideoAttachment && isVisible && newValue {
                if isEmbedded {
                    shouldAutoPlay = attachmentIndex == 0
                } else {
                    shouldAutoPlay = videoManager.shouldPlayVideo(for: attachment.mid)
                }
            }
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
                sourceTweetId: sourceTweetId ?? parentTweet.mid  // Use retweet ID if provided, else original tweet ID
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
    
    // MARK: - Video Preloading Methods
    
    /// Start background preloading of video assets
    /// DISABLED: Grid-level debouncing now handles all video preloading
    private func startBackgroundPreloading() {
        // This method is disabled because grid-level debouncing now handles all video preloading
        // Individual cells no longer need to preload videos independently
        return
    }
    
    /// Cancel ongoing preload task
    private func cancelPreloadTask() {
        preloadTask?.cancel()
        preloadTask = nil
        isPreloading = false
    }
    
    private func saveVideoPositionForFullscreen() {
        // Save current playback position before opening fullscreen
        // This allows the video to continue from where it was playing in the cell
        // Get the current time directly from the cached player (more accurate than cached playback info)
        if let cachedState = VideoStateCache.shared.getCachedState(for: attachment.mid) {
            let currentTime = cachedState.player.currentTime()
            let wasPlaying = cachedState.player.rate > 0
            
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
        
        // First, try to get cached image immediately (disk check is OK in async context)
        // This happens in onAppear which is safe for disk I/O
        if let cachedImage = imageCache.getCompressedImage(for: attachment) {
            self.image = cachedImage
            self.isLoading = false
            return
        }
        
        // If no cached image, start loading with global manager
        isLoading = true
        
        // Use normal priority for grid images (they're visible but not as critical as detail view)
        GlobalImageLoadManager.shared.loadImageNormalPriority(
            id: "\(attachment.mid)_\(effectiveBaseUrl.absoluteString)",
            url: url,
            attachment: attachment,
            baseUrl: effectiveBaseUrl
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
        lhs.shouldLoadVideo == rhs.shouldLoadVideo
    }
    
    // MARK: - Video Player View
    @ViewBuilder
    private func videoPlayerViewContent(url: URL) -> some View {
        SimpleVideoPlayer(
                url: url,
                mid: attachment.mid,
                parentTweetId: parentTweet.mid,
                isVisible: isVisible,
                mediaType: attachment.type,
                authorId: parentTweet.authorId, // Pass authorId for health check
                autoPlay: shouldAutoPlay, // Use state variable instead of computed value
                videoManager: isEmbedded ? nil : videoManager,
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
            .overlay(
                // Invisible overlay to prevent tap propagation to parent views and add long press
                Color.clear
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
        
        if let url = attachment.getUrl(effectiveBaseUrl) {
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
    @State private var timeRemaining: String = "0:00"
    @State private var updateTimer: Timer?
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
            startTimer()
            startHideTimer()
        }
        .onDisappear {
            updateTimer?.invalidate()
            updateTimer = nil
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
    
    private func startTimer() {
        // Request immediate update
        requestUpdate()
        
        // Setup repeating timer for updates (use .common mode to fire during scroll)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [videoMid] _ in
            // Request update from SimpleVideoPlayer
            NotificationCenter.default.post(
                name: .requestVideoTimerUpdate,
                object: nil,
                userInfo: ["videoMid": videoMid]
            )
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }
    
    private func startHideTimer() {
        // Cancel any existing hide timer
        hideTimer?.invalidate()
        
        // Hide after 5 seconds
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            Task { @MainActor in
                self.isVisible = false
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }
    
    private func requestUpdate() {
        NotificationCenter.default.post(
            name: .requestVideoTimerUpdate,
            object: nil,
            userInfo: ["videoMid": videoMid]
        )
    }
}
