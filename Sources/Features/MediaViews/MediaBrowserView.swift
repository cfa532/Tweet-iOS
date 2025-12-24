//
//  MediaBrowserView.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/5/20.
//

import SwiftUI
import AVKit
import Photos
import UIKit

struct MediaBrowserView: View {
    let tweet: Tweet
    let initialIndex: Int
    let sourceTweetId: String? // The tweet ID where user tapped (could be retweet)
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var currentTweet: Tweet // Allow changing tweet for auto-advance
    @State private var currentSourceTweetId: String // Track position in visible feed
    @State private var showVideoPlayer = false
    @State private var play = false
    @State private var isVisible = true
    @State private var isMuted: Bool = false // Local mute state for fullscreen (always unmuted)
    @State private var imageStates: [Int: ImageState] = [:]
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    @State private var dragOffset = CGSize.zero
    @State private var isDragging = false
    @State private var previousIndex: Int = -1 // Track previous index for video management
    @State private var isImageZoomed = false // Track if current image is zoomed
    @State private var isTransitioning = false // Track transition animation
    @State private var transitionOffset: CGFloat = 0 // Offset for slide transition
    @State private var isShareSheetVisible: Bool = false // Track share sheet state in fullscreen
    private var attachments: [MimeiFileType] {
        return currentTweet.attachments ?? []
    }

    private var baseUrl: URL {
        // Use author's baseUrl if available, otherwise use appUser's baseUrl
        // If both are nil, use real IP from HproseInstance (resolved at app start)
        return currentTweet.author?.baseUrl 
            ?? HproseInstance.shared.appUser.baseUrl 
            ?? HproseInstance.baseUrl
    }

    init(tweet: Tweet, initialIndex: Int, sourceTweetId: String? = nil) {
        self.tweet = tweet
        self.initialIndex = initialIndex
        self.sourceTweetId = sourceTweetId
        self._currentIndex = State(initialValue: initialIndex)
        self._currentTweet = State(initialValue: tweet)
        self._currentSourceTweetId = State(initialValue: sourceTweetId ?? tweet.mid)
        self._previousIndex = State(initialValue: initialIndex)
        print("MediaBrowserView init - tweet: \(tweet.mid), sourceTweet: \(sourceTweetId ?? tweet.mid), attachments: \(tweet.attachments?.count ?? 0), initialIndex: \(initialIndex)")
    }

    var body: some View {
        MediaBrowserContentView(
                attachments: attachments,
                currentIndex: $currentIndex,
                previousIndex: $previousIndex,
                showControls: $showControls,
                dragOffset: $dragOffset,
                isDragging: $isDragging,
                isVisible: $isVisible,
                baseUrl: baseUrl,
                imageStates: $imageStates,
                isImageZoomed: $isImageZoomed,
                isTransitioning: $isTransitioning,
                transitionOffset: $transitionOffset,
                currentTweet: currentTweet,
                currentSourceTweetId: currentSourceTweetId,
                dismiss: { dismiss() },
                startControlsTimer: startControlsTimer,
                resetControlsTimer: resetControlsTimer,
                onShareVisibilityChange: { isVisible in
                    DispatchQueue.main.async {
                        isShareSheetVisible = isVisible
                        if isVisible {
                            showControls = true
                            controlsTimer?.invalidate()
                            controlsTimer = nil
                        } else {
                            startControlsTimer()
                        }
                    }
                },
                loadImageIfNeededClosure: { attachment, index in
                    loadImageIfNeeded(for: attachment, at: index)
                }
            )
            .onAppear {
                setupFullScreenManager()
                OverlayVisibilityCoordinator.shared.beginOverlay(id: "mediaBrowserView", source: "MediaBrowserView")

                // NOTE: Don't broadcast stopAllVideos here.
                // MediaCell videos will pause via overlay visibility detection once the fullscreen cover is presented.
            }
            .onDisappear {
                FullScreenVideoManager.shared.clearSingletonPlayer()
                OverlayVisibilityCoordinator.shared.endOverlay(id: "mediaBrowserView", source: "MediaBrowserView")
                
                // CRITICAL FIX: Force reload of visible videos after dismissing fullscreen
                // This handles the case where app returned from background while fullscreen was active:
                // 1. Background recovery cleared all players and posted .reloadVisibleVideosOnly
                // 2. But MediaCell didn't reload because it wasn't visible (overlay was active)
                // 3. Now that fullscreen is dismissed, MediaCell is visible but has a cleared player
                // Solution: Post reload notification again after overlay ends
                Task { @MainActor in
                    // Small delay to ensure overlay state is fully updated
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)
                    print("DEBUG: [MediaBrowserView] Posted reloadVisibleVideosOnly after fullscreen dismissed")
                }
            }
    }
    
    private func setupFullScreenManager() {
        // Set up navigation callback for auto-advance and swipe up
        FullScreenVideoManager.shared.onNavigateToNextVideo = { [self] nextTweet, videoIndex, nextSourceTweetId in
            print("DEBUG: [MediaBrowserView] Navigating to tweet: \(nextTweet.mid), videoIndex: \(videoIndex), sourceTweetId: \(nextSourceTweetId)")
            
            // Animate transition: slide current video up and next video in from bottom
            Task { @MainActor in
                // Start transition - slide current content up (only 30% of screen for tight transition)
                let slideDistance = UIScreen.main.bounds.height * 0.3
                isTransitioning = true
                withAnimation(.easeOut(duration: 0.25)) {
                    transitionOffset = -slideDistance
                }
                
                // Wait for slide-out to complete
                try? await Task.sleep(nanoseconds: 125_000_000) // 0.125 seconds (halfway)
                
                // Load the next video
                if let attachments = nextTweet.attachments,
                   videoIndex < attachments.count {
                    let attachment = attachments[videoIndex]
                    let baseUrl = nextTweet.author?.baseUrl 
                        ?? HproseInstance.shared.appUser.baseUrl 
                        ?? HproseInstance.baseUrl
                    
                    if let url = attachment.getUrl(baseUrl) {
                        print("DEBUG: [MediaBrowserView] Loading next video: \(url)")
                        FullScreenVideoManager.shared.loadVideo(
                            url: url,
                            mid: attachment.mid,
                            tweetId: nextTweet.mid,
                            sourceTweetId: nextSourceTweetId,
                            videoIndex: videoIndex,
                            mediaType: attachment.type
                        )
                    }
                }
                
                // Update UI state
                self.currentTweet = nextTweet
                self.currentIndex = videoIndex
                self.previousIndex = videoIndex
                self.currentSourceTweetId = nextSourceTweetId
                self.imageStates = [:]
                
                // Reset to bottom position for slide-in (30% for tight transition)
                transitionOffset = slideDistance
                
                // Slide in from bottom
                withAnimation(.easeInOut(duration: 0.25)) {
                    transitionOffset = 0
                }
                
                // Wait for slide-in to complete
                try? await Task.sleep(nanoseconds: 250_000_000) // 0.25 seconds
                isTransitioning = false
            }
        }
        
        // Set up exit fullscreen callback (when no more videos)
        FullScreenVideoManager.shared.onExitFullScreen = { [self] in
            print("DEBUG: [MediaBrowserView] Exiting fullscreen - no more videos")
            dismiss()
        }
    }
    
    // MARK: - MediaBrowserContentView
    private struct MediaBrowserContentView: View {
        let attachments: [MimeiFileType]
        @Binding var currentIndex: Int
        @Binding var previousIndex: Int
        @Binding var showControls: Bool
        @Binding var dragOffset: CGSize
        @Binding var isDragging: Bool
        @Binding var isVisible: Bool
        let baseUrl: URL
        @Binding var imageStates: [Int: ImageState]
        @Binding var isImageZoomed: Bool
        @Binding var isTransitioning: Bool
        @Binding var transitionOffset: CGFloat
        let currentTweet: Tweet
        let currentSourceTweetId: String
        let dismiss: () -> Void
        let startControlsTimer: () -> Void
        let resetControlsTimer: () -> Void
        let onShareVisibilityChange: (Bool) -> Void
        let loadImageIfNeededClosure: (MimeiFileType, Int) -> Void
        
        var body: some View {
            ZStack {
                // Background layer - stays in place (not affected by offset)
                Color.black
                    .ignoresSafeArea(.all, edges: .all)
                
                // Content layer - slides during transition
                ZStack {
                    TabView(selection: $currentIndex) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                            Group {
                                if isVideoAttachment(attachment), let url = attachment.getUrl(baseUrl) {
                                    videoView(for: attachment, url: url, index: index)
                                } else if isAudioAttachment(attachment), let url = attachment.getUrl(baseUrl) {
                                    audioView(for: attachment, url: url, index: index)
                                } else if isImageAttachment(attachment), let url = attachment.getUrl(baseUrl) {
                                    imageView(for: attachment, url: url, index: index)
                                } else if isPDFAttachment(attachment) {
                                    pdfView(for: attachment, index: index)
                                }
                            }
                            .background(Color.black)
                            .tag(index)
                        }
                    }
                    .background(Color.black)
                    .tabViewStyle(.page)
                    .indexViewStyle(.page(backgroundDisplayMode: .always))
                    .onChange(of: currentIndex) { _, newIndex in
                        print("DEBUG: [MediaBrowserView] TabView index changed from \(previousIndex) to \(newIndex)")
                        previousIndex = newIndex
                        
                        // Clean up non-visible images to free memory
                        cleanupNonVisibleImages(attachments: attachments, currentIndex: newIndex, imageStates: $imageStates, baseUrl: baseUrl)
                    }
                    
                    // Close button + tweet actions overlay
                    if showControls {
                        VStack {
                            HStack {
                                Button(action: { dismiss() }) {
                                    Image(systemName: "xmark")
                                        .font(.title2)
                                        .foregroundColor(.white)
                                        .padding()
                                        .background(Color.black.opacity(0.5))
                                        .clipShape(Circle())
                                }
                                Spacer()
                            }
                            Spacer()
                            HStack {
                                TweetActionButtonsView(
                                    tweet: currentTweet,
                                    isInDetailView: true,
                                    isFullScreen: true,
                                    currentMediaIndex: currentIndex,
                                    onShareVisibilityChange: { isVisible in
                                        // Forward share visibility changes to outer view
                                        onShareVisibilityChange(isVisible)
                                    }
                                )
                                .environment(\.colorScheme, .dark)
                                .tint(.white)
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 60)
                        }
                        .transition(.opacity)
                    }
                }
                .offset(y: isTransitioning ? transitionOffset : dragOffset.height)
                .scaleEffect(isTransitioning ? 1.0 : (1.0 - abs(dragOffset.height) / 1000.0))
                .opacity(isTransitioning ? 1.0 : (1.0 - abs(dragOffset.height) / 500.0))
            }
            .statusBar(hidden: true)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Disable gestures during transition
                        if isTransitioning {
                            return
                        }
                        
                        // Allow vertical swipes if no image is zoomed
                        if !isImageZoomed {
                            dragOffset = value.translation
                            isDragging = true
                            showControls = true
                        }
                    }
                    .onEnded { value in
                        // Disable gestures during transition
                        if isTransitioning {
                            return
                        }
                        
                        // Only handle gestures if no image is zoomed
                        if !isImageZoomed {
                            let swipeThreshold: CGFloat = 100
                            let velocityThreshold: CGFloat = 500
                            // Ignore system home-indicator swipe-ups (close app / go Home).
                            // Only treat swipe-up as "next video" if the gesture started away from the bottom edge.
                            let bottomExclusion: CGFloat = 44 + MediaBrowserView.currentBottomSafeAreaInset()
                            let startedNearBottomEdge = value.startLocation.y > (UIScreen.main.bounds.height - bottomExclusion)
                            
                            // Swipe down - exit fullscreen
                            if value.translation.height > swipeThreshold || value.velocity.height > velocityThreshold {
                                dismiss()
                                return
                            }
                            
                            // Swipe up - next video
                            if !startedNearBottomEdge,
                               (value.translation.height < -swipeThreshold || value.velocity.height < -velocityThreshold) {
                                print("DEBUG: [SWIPE] Swipe up detected - navigating to next video")
                                FullScreenVideoManager.shared.navigateToNext()
                            }
                        }
                        
                        // Reset drag offset
                        withAnimation(.spring()) {
                            dragOffset = .zero
                        }
                        isDragging = false
                        resetControlsTimer()
                    }
            )
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls = true
                }
                resetControlsTimer()
            }
            .onAppear {
                isVisible = true
                UIApplication.shared.isIdleTimerDisabled = true
                startControlsTimer()
                
                // Don't stop all videos - only the video entering fullscreen will pause itself
                // This allows other videos to continue playing
                
                previousIndex = currentIndex
            }
            .onDisappear {
                isVisible = false
                UIApplication.shared.isIdleTimerDisabled = false
                
                // Don't resume all videos - each video will resume automatically when it becomes visible
                // This allows videos that were already playing to continue, and only the exiting video to resume if needed
                
                // Clean up all image states to free memory
                cleanupImageStates(attachments: attachments, imageStates: $imageStates, baseUrl: baseUrl)
            }
        }
        
        // Helper functions
        private func isVideoAttachment(_ attachment: MimeiFileType) -> Bool {
            attachment.type == .video || attachment.type == .hls_video
        }
        
        private func isAudioAttachment(_ attachment: MimeiFileType) -> Bool {
            attachment.type == .audio
        }
        
        private func isImageAttachment(_ attachment: MimeiFileType) -> Bool {
            attachment.type == .image
        }
        
        private func isPDFAttachment(_ attachment: MimeiFileType) -> Bool {
            attachment.type == .pdf
        }
        
        private func imageView(for attachment: MimeiFileType, url: URL, index: Int) -> some View {
            ImageViewWithPlaceholder(
                attachment: attachment,
                baseUrl: baseUrl,
                url: url,
                imageState: imageStates[index] ?? .loading,
                isImageZoomed: $isImageZoomed,
                isCurrentIndex: index == currentIndex
            )
            .onAppear {
                loadImageIfNeededClosure(attachment, index)
            }
        }
        
        private func videoView(for attachment: MimeiFileType, url: URL, index: Int) -> some View {
            let shouldAutoPlay = index == currentIndex
            
            return SingletonVideoPlayerView(
                url: url,
                mid: attachment.mid,
                tweetId: currentTweet.mid,
                sourceTweetId: currentSourceTweetId,
                videoIndex: index,
                mediaType: attachment.type,
                aspectRatio: attachment.aspectRatio,
                onUserInteraction: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls = true
                    }
                    resetControlsTimer()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onChange(of: currentIndex) { _, newIndex in
                print("DEBUG: [MediaBrowserView] TabView index changed to \(newIndex)")
                
                // Load new video when user swipes
                if newIndex == index && isVideoAttachment(attachment) {
                    FullScreenVideoManager.shared.loadVideo(
                        url: url,
                        mid: attachment.mid,
                        tweetId: currentTweet.mid,
                        sourceTweetId: currentSourceTweetId,
                        videoIndex: index,
                        mediaType: attachment.type
                    )
                }
            }
            .onAppear {
                // Load video when it appears
                if shouldAutoPlay && isVideoAttachment(attachment) {
                    FullScreenVideoManager.shared.loadVideo(
                        url: url,
                        mid: attachment.mid,
                        tweetId: currentTweet.mid,
                        sourceTweetId: currentSourceTweetId,
                        videoIndex: index,
                        mediaType: attachment.type
                    )
                }
            }
        }
        
        private func audioView(for attachment: MimeiFileType, url: URL, index: Int) -> some View {
            SimpleAudioPlayer(
                url: url,
                autoPlay: currentIndex == index
            )
            .environmentObject(MuteState.shared)
        }
        
        private func pdfView(for attachment: MimeiFileType, index: Int) -> some View {
            PDFPreviewViewFullScreen(
                attachment: attachment,
                baseUrl: baseUrl
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

    }

    static func currentBottomSafeAreaInset() -> CGFloat {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            return 0
        }
        return window.safeAreaInsets.bottom
    }
    

    
    private func startControlsTimer() {
        controlsTimer?.invalidate()
        
        // Don't auto-hide controls while share sheet is visible
        if isShareSheetVisible {
            return
        }
        
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            // Hide close button for ALL content types after 3 seconds
            // but only if share sheet isn't visible anymore
            if !isShareSheetVisible {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showControls = false
                }
            }
        }
    }
    
    private func resetControlsTimer() {
        // Reset timer for ALL content types (including videos)
        startControlsTimer()
    }
    
    private func loadImageIfNeeded(for attachment: MimeiFileType, at index: Int) {
        let loadId = "browser_\(index)_\(attachment.mid)_\(baseUrl.absoluteString)"
        print("DEBUG: [MediaBrowserView] loadImageIfNeeded called for \(loadId)")
        
        // First, try to get compressed image immediately
        if let compressedImage = ImageCacheManager.shared.getCompressedImage(for: attachment) {
            print("DEBUG: [MediaBrowserView] Found cached image for \(loadId)")
            imageStates[index] = .loaded(compressedImage)
            return
        }
        
        // If no compressed image available, show loading state
        print("DEBUG: [MediaBrowserView] Starting network load for \(loadId)")
        imageStates[index] = .loading
        
        // Load and cache compressed image
        guard let url = attachment.getUrl(baseUrl) else { 
            print("DEBUG: [MediaBrowserView] No URL for \(loadId)")
            imageStates[index] = .error
            return 
        }
        
        // Use normal priority to load and cache compressed image
        GlobalImageLoadManager.shared.loadImageNormalPriority(
            id: loadId,
            url: url,
            attachment: attachment,
            baseUrl: baseUrl
        ) { compressedImage in
            print("DEBUG: [MediaBrowserView] Load completed for \(loadId), success: \(compressedImage != nil)")
            if let compressedImage = compressedImage {
                self.imageStates[index] = .loaded(compressedImage)
            } else {
                self.imageStates[index] = .error
            }
        }
    }
    

    

    
    private func getCachedPlaceholder(for attachment: MimeiFileType) -> UIImage? {
        return ImageCacheManager.shared.getCompressedImage(for: attachment)
    }
    
    private static func cleanupImageStates(attachments: [MimeiFileType], imageStates: Binding<[Int: ImageState]>, baseUrl: URL) {
        // Cancel all pending image loads
        for (index, attachment) in attachments.enumerated() {
            let loadId = "browser_\(index)_\(attachment.mid)_\(baseUrl.absoluteString)"
            GlobalImageLoadManager.shared.cancelLoad(id: loadId)
        }
        
        // Clear image states to free memory
        imageStates.wrappedValue.removeAll()
        
        print("DEBUG: [MediaBrowserView] Cleaned up image states and cancelled loads")
    }
    
    private static func cleanupNonVisibleImages(attachments: [MimeiFileType], currentIndex: Int, imageStates: Binding<[Int: ImageState]>, baseUrl: URL) {
        // Since we're using compressed images (small), we can keep more in memory
        // Keep current image and 2 images on each side
        let keepRange = max(0, currentIndex - 2)...min(attachments.count - 1, currentIndex + 2)
        
        for (index, _) in imageStates.wrappedValue {
            if !keepRange.contains(index) {
                // Cancel load for non-visible images
                if index < attachments.count {
                    let attachment = attachments[index]
                    let loadId = "browser_\(index)_\(attachment.mid)_\(baseUrl.absoluteString)"
                    GlobalImageLoadManager.shared.cancelLoad(id: loadId)
                }
                
                // Remove from image states
                imageStates.wrappedValue.removeValue(forKey: index)
            }
        }
    }
}

// MARK: - Image State
enum ImageState {
    case loading
    case placeholder(UIImage)
    case loaded(UIImage)
    case error
}

// MARK: - Image View With Placeholder
struct ImageViewWithPlaceholder: View {
    let attachment: MimeiFileType
    let baseUrl: URL
    let url: URL
    let imageState: ImageState
    @Binding var isImageZoomed: Bool
    let isCurrentIndex: Bool
    
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var showDownloadToast = false
    @State private var downloadToastMessage = ""
    
    // Calculate zoom parameters based on actual image dimensions and screen dimensions
    private func getActualAspectRatio() -> CGFloat {
        switch imageState {
        case .loaded(let image):
            return image.size.width / image.size.height
        case .placeholder(let image):
            return image.size.width / image.size.height
        default:
            return CGFloat(attachment.aspectRatio ?? 1.0)
        }
    }
    
    private func calculateDoubleTapScale(for geometry: GeometryProxy) -> CGFloat {
        let screenWidth = geometry.size.width
        let screenHeight = geometry.size.height
        let actualAspectRatio = getActualAspectRatio()
        
        // For images with AR < 0.6: calculate scale to cover full width
        // For other images: use 2.0 as double-tap zoom scale
        if actualAspectRatio < 0.6 {
            // Image is tall, so it's fitted to screen height
            // Current width = screenHeight * actualAspectRatio
            // We want width = screenWidth
            // So scale = screenWidth / (screenHeight * actualAspectRatio)
            return screenWidth / (screenHeight * actualAspectRatio)
        } else {
            // Image is wide or normal, use 2.0 zoom
            return 2.0
        }
    }
    
    private func calculateMaxScale(for geometry: GeometryProxy) -> CGFloat {
        // Allow up to 2x the double-tap scale for pinch zoom
        return calculateDoubleTapScale(for: geometry) * 2.0
    }
    
    private func downloadImage() {
        // Get the image to download
        let imageToDownload: UIImage?
        
        switch imageState {
        case .loaded(let image):
            imageToDownload = image
        case .placeholder(let image):
            imageToDownload = image
        default:
            imageToDownload = nil
        }
        
        guard let image = imageToDownload else {
            showDownloadToast(message: NSLocalizedString("No image to download", comment: "No image download error"))
            return
        }
        
        // Request photo library permission and save
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    self.showDownloadToast(message: NSLocalizedString("Photo library access denied", comment: "Photo library permission error"))
                }
                return
            }
            
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        self.showDownloadToast(message: NSLocalizedString("Image saved to Photos", comment: "Image save success"))
                    } else {
                        self.showDownloadToast(message: NSLocalizedString("Failed to save image", comment: "Image save error"))
                    }
                }
            }
        }
    }
    
    private func showDownloadToast(message: String) {
        downloadToastMessage = message
        showDownloadToast = true
        
        // Auto-hide toast after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            showDownloadToast = false
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                
                Group {
                    switch imageState {
                    case .loading:
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                        
                    case .placeholder(let placeholderImage):
                        Image(uiImage: placeholderImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                        
                    case .loaded(let image):
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                        
                    case .error:
                        VStack {
                            Image(systemName: "photo")
                                .font(.system(size: 50))
                                .foregroundColor(.gray)
                            Text(LocalizedStringKey("Failed to load image"))
                                .foregroundColor(.gray)
                                .font(.caption)
                        }
                    }
                }
                .scaleEffect(scale)
                .offset(offset)
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let delta = value / lastScale
                            lastScale = value
                            let maxScale = calculateMaxScale(for: geometry)
                            scale = min(max(scale * delta, 1.0), maxScale)
                        }
                        .onEnded { _ in
                            lastScale = 1.0
                            // Snap back to bounds if needed
                            if scale < 1.0 {
                                withAnimation(.easeOut(duration: 0.3)) {
                                    scale = 1.0
                                    offset = .zero
                                }
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 15)
                        .onChanged { value in
                            // Only handle drag when zoomed in
                            if scale > 1.0 {
                                let delta = CGSize(
                                    width: value.translation.width - lastOffset.width,
                                    height: value.translation.height - lastOffset.height
                                )
                                lastOffset = value.translation
                                
                                let actualAspectRatio = getActualAspectRatio()
                                let maxOffsetX = (geometry.size.width * (scale - 1.0)) / 2
                                let maxOffsetY = (geometry.size.height * (scale - 1.0)) / 2
                                
                                // For tall images (AR < 0.6), align to top and only allow upward scrolling
                                if actualAspectRatio < 0.6 {
                                    // Align to top: offset.y should be positive (image top aligned to screen top)
                                    let topAlignedOffsetY = maxOffsetY
                                    
                                    offset = CGSize(
                                        width: max(-maxOffsetX, min(maxOffsetX, offset.width + delta.width)),
                                        height: max(0, min(topAlignedOffsetY, offset.height + delta.height))
                                    )
                                } else {
                                    // Normal behavior for wide/normal images
                                    offset = CGSize(
                                        width: max(-maxOffsetX, min(maxOffsetX, offset.width + delta.width)),
                                        height: max(-maxOffsetY, min(maxOffsetY, offset.height + delta.height))
                                    )
                                }
                            }
                        }
                        .onEnded { _ in
                            lastOffset = .zero
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        if scale > 1.0 {
                            scale = 1.0
                            offset = .zero
                        } else {
                            scale = calculateDoubleTapScale(for: geometry)
                            
                            // For tall images (AR < 0.6), align to top when zooming in
                            let actualAspectRatio = getActualAspectRatio()
                            if actualAspectRatio < 0.6 {
                                let maxOffsetY = (geometry.size.height * (scale - 1.0)) / 2
                                offset = CGSize(width: 0, height: maxOffsetY)
                            } else {
                                offset = .zero
                            }
                        }
                    }
                }
                .onLongPressGesture {
                    // Download image on long press
                    downloadImage()
                }
                
                // Download toast overlay
                if showDownloadToast {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(downloadToastMessage)
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(8)
                            Spacer()
                        }
                        .padding(.bottom, 100)
                    }
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: showDownloadToast)
                }
            }
        }
        .clipped()
        .onChange(of: scale) { _, newScale in
            // Update the zoom state for the current image
            if isCurrentIndex {
                isImageZoomed = newScale > 1.0
            }
        }
        .onChange(of: isCurrentIndex) { _, newIsCurrent in
            // Reset zoom state when switching to a different image
            if newIsCurrent {
                isImageZoomed = scale > 1.0
            } else {
                isImageZoomed = false
            }
        }
    }
}

// MARK: - Singleton Video Player View
struct SingletonVideoPlayerView: View {
    let url: URL
    let mid: String
    let tweetId: String
    let sourceTweetId: String
    let videoIndex: Int
    let mediaType: MediaType
    let aspectRatio: Float?
    let onUserInteraction: () -> Void
    
    @ObservedObject private var manager = FullScreenVideoManager.shared
    @State private var hasAttemptedReload = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let player = manager.singletonPlayer, manager.currentVideoMid == mid {
                    // Show player
                    SimplerAVPlayerViewController(player: player, aspectRatio: aspectRatio)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                onUserInteraction()
                            }
                        )
                } else {
                    // Loading placeholder or broken player - attempt to reload
                    Color.black
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                }
                
                // Show buffering spinner when waiting for data (non-interactive overlay)
                if manager.isBuffering && manager.currentVideoMid == mid {
                    ZStack {
                        Color.black.opacity(0.15)
                        ProgressView()
                            .scaleEffect(3.0)
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .opacity(0.8)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false) // Don't block touches - allow user to interact with player controls
                }
            }
            .onAppear {
                    // If player is nil or doesn't match current video, reload it
                    if manager.singletonPlayer == nil || manager.currentVideoMid != mid {
                        if !hasAttemptedReload {
                            hasAttemptedReload = true
                            print("DEBUG: [SingletonVideoPlayerView] Player missing or mismatched - reloading video for mid: \(mid)")
                            // Reload the video
                            manager.loadVideo(
                                url: url,
                                mid: mid,
                                tweetId: tweetId,
                                sourceTweetId: sourceTweetId,
                                videoIndex: videoIndex,
                                mediaType: mediaType
                            )
                        }
                    }
                }
                .onChange(of: manager.currentVideoMid) { _, newMid in
                    // Reset reload flag when video changes
                    if newMid == mid {
                        hasAttemptedReload = false
                    }
                }
            }
        }
    }

// MARK: - Simple AVPlayerViewController Wrapper
private struct SimplerAVPlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer
    let aspectRatio: Float?
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject {
        var statusObserver: NSKeyValueObservation?
        var currentItemObserver: NSKeyValueObservation?
        
        deinit {
            statusObserver?.invalidate()
            currentItemObserver?.invalidate()
        }
    }
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .black
        
        // Rotate landscape videos (aspectRatio > 1) by -90 degrees
        if let aspectRatio = aspectRatio, aspectRatio > 1.0 {
            print("DEBUG: [SingletonVideoPlayer] Landscape video detected (aspectRatio: \(aspectRatio)), rotating -90 degrees")
            controller.view.transform = CGAffineTransform(rotationAngle: -.pi / 2)
        }
        
        // Setup observer to auto-play when ready
        setupPlayerItemObserver(player: player, context: context)
        
        // Observe currentItem changes to set up observer for new items
        context.coordinator.currentItemObserver = player.observe(\.currentItem, options: [.new]) { player, _ in
            print("DEBUG: [SingletonVideoPlayer] Player currentItem changed, setting up new observer")
            setupPlayerItemObserver(player: player, context: context)
        }
        
        return controller
    }
    
    private func setupPlayerItemObserver(player: AVPlayer, context: Context) {
        context.coordinator.statusObserver?.invalidate()
        
        // Don't auto-play here - let FullScreenVideoManager handle playback after restoring position
        // FullScreenVideoManager will check for saved state and seek/play accordingly
        if let playerItem = player.currentItem {
            if playerItem.status == .readyToPlay {
                print("DEBUG: [SingletonVideoPlayer] Player already ready - FullScreenVideoManager will handle playback")
                // FullScreenVideoManager will handle playback after checking for saved state
            } else {
                print("DEBUG: [SingletonVideoPlayer] Player not ready yet, setting up observer")
                context.coordinator.statusObserver = playerItem.observe(\.status, options: [.new]) { item, _ in
                    if item.status == .readyToPlay {
                        print("DEBUG: [SingletonVideoPlayer] Player became ready - FullScreenVideoManager will handle playback")
                        // FullScreenVideoManager will handle playback after checking for saved state
                        context.coordinator.statusObserver?.invalidate()
                        context.coordinator.statusObserver = nil
                    } else if item.status == .failed {
                        print("ERROR: [SingletonVideoPlayer] Player item failed")
                    }
                }
            }
        }
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Update rotation based on aspect ratio
        if let aspectRatio = aspectRatio, aspectRatio > 1.0 {
            if uiViewController.view.transform == .identity {
                print("DEBUG: [SingletonVideoPlayer] Applying rotation on update (aspectRatio: \(aspectRatio))")
                uiViewController.view.transform = CGAffineTransform(rotationAngle: -.pi / 2)
            }
        } else {
            if uiViewController.view.transform != .identity {
                print("DEBUG: [SingletonVideoPlayer] Removing rotation on update")
                uiViewController.view.transform = .identity
            }
        }
        
        if uiViewController.player !== player {
            uiViewController.player = player
            
            // Setup observer for new player - don't auto-play, let FullScreenVideoManager handle it
            context.coordinator.statusObserver?.invalidate()
            if let playerItem = player.currentItem {
                if playerItem.status == .readyToPlay {
                    print("DEBUG: [SingletonVideoPlayer] Player ready on update - FullScreenVideoManager will handle playback")
                    // FullScreenVideoManager will handle playback after checking for saved state
                } else {
                    context.coordinator.statusObserver = playerItem.observe(\.status, options: [.new]) { item, _ in
                        if item.status == .readyToPlay {
                            print("DEBUG: [SingletonVideoPlayer] Player ready after update - FullScreenVideoManager will handle playback")
                            // FullScreenVideoManager will handle playback after checking for saved state
                            context.coordinator.statusObserver?.invalidate()
                            context.coordinator.statusObserver = nil
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Array Extension for Safe Access
extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

 
