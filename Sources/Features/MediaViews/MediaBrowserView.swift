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
    let cellTweetId: String? // The visible cell's tweet ID (could be retweet or quoting tweet)
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var currentTweet: Tweet // Allow changing tweet for auto-advance
    @State private var currentCellTweetId: String // Track position in visible feed
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
    @State private var isCompletingVerticalAdvance = false // Track outgoing swipe-up animation
    @State private var transitionOffset: CGFloat = 0 // Offset for slide transition
    @State private var isShareSheetVisible: Bool = false // Track share sheet state in fullscreen
    @State private var suppressTabPagingAnimation: Bool = false // Suppress TabView paging during vertical next-video transitions
    @State private var isDismissingForBackground = false
    @State private var originalImageTasks: [Int: Task<Void, Never>] = [:]
    private var attachments: [MimeiFileType] {
        // Audio is handled by the compact playlist player; the browser pages visual media only.
        let allAttachments = currentTweet.attachments ?? []
        return allAttachments.filter { attachment in
            switch attachment.type {
            case .image, .video, .hls_video:
                return true
            default:
                return false
            }
        }
    }

    private static func visualAttachmentIndex(in tweet: Tweet, originalIndex: Int, mid: String?) -> Int {
        let allAttachments = tweet.attachments ?? []
        let visualAttachments = allAttachments.filter {
            $0.type == .image || $0.type == .video || $0.type == .hls_video
        }

        if let mid,
           let visualIndex = visualAttachments.firstIndex(where: { $0.mid == mid }) {
            return visualIndex
        }

        if allAttachments.indices.contains(originalIndex) {
            let originalAttachment = allAttachments[originalIndex]
            if let visualIndex = visualAttachments.firstIndex(where: { $0.mid == originalAttachment.mid }) {
                return visualIndex
            }
        }

        return min(max(originalIndex, 0), max(visualAttachments.count - 1, 0))
    }

    private var baseUrl: URL {
        // Use author's baseUrl if available, otherwise use appUser's baseUrl
        // If both are nil, use real IP from HproseInstance (resolved at app start)
        return currentTweet.author?.baseUrl 
            ?? HproseInstance.shared.appUser.baseUrl 
            ?? HproseInstance.baseUrl
    }

    init(tweet: Tweet, initialIndex: Int, cellTweetId: String? = nil) {
        let initialAttachment = tweet.attachments?.indices.contains(initialIndex) == true
            ? tweet.attachments?[initialIndex]
            : nil
        let browserIndex = Self.visualAttachmentIndex(
            in: tweet,
            originalIndex: initialIndex,
            mid: initialAttachment?.mid
        )

        self.tweet = tweet
        self.initialIndex = initialIndex
        self.cellTweetId = cellTweetId
        self._currentIndex = State(initialValue: browserIndex)
        self._currentTweet = State(initialValue: tweet)
        self._currentCellTweetId = State(initialValue: cellTweetId ?? tweet.mid)
        self._previousIndex = State(initialValue: browserIndex)
        print("MediaBrowserView init - tweet: \(tweet.mid), cellTweet: \(cellTweetId ?? tweet.mid), attachments: \(tweet.attachments?.count ?? 0), initialIndex: \(initialIndex)")
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
                isCompletingVerticalAdvance: $isCompletingVerticalAdvance,
                transitionOffset: $transitionOffset,
                suppressTabPagingAnimation: $suppressTabPagingAnimation,
                currentTweet: currentTweet,
                currentCellTweetId: currentCellTweetId,
                dismiss: dismissFullScreen,
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
                },
                cleanupNonVisibleImagesClosure: { index in
                    cleanupNonVisibleImages(attachments: attachments, currentIndex: index)
                },
                cleanupImageStatesClosure: {
                    cleanupImageStates(attachments: attachments)
                }
            )
            .onAppear {
                OrientationManager.shared.unlockOrientation()

                // Activate manager first to register lifecycle observers
                FullScreenVideoManager.shared.activateForFullscreen()
                FullScreenVideoManager.shared.setStartupAudioMuteWindow(duration: 0.2)
                setupFullScreenManager()
                OverlayVisibilityCoordinator.shared.beginOverlayIfNeeded(id: "mediaBrowserView", source: "MediaBrowserView")

                // NOTE: Don't broadcast stopAllVideos here. Fullscreen borrows the
                // feed's shared player, so overlay coverage should transfer ownership
                // without a pause/resume cycle.
            }
            .onDisappear {
                OrientationManager.shared.lockToPortrait()

                // Fullscreen owns its own AVPlayer, so dismissal must pause that player.
                // Feed/detail can reuse cached data and their saved position independently.
                FullScreenVideoManager.shared.deactivate(transferPlaybackToUnderlyingSurface: false)
                OverlayVisibilityCoordinator.shared.endOverlay(id: "mediaBrowserView", source: "MediaBrowserView")
                
                // CRITICAL: Clean up controls timer to prevent CPU cycles accumulation
                controlsTimer?.invalidate()
                controlsTimer = nil
                
                // DON'T post reloadVisibleVideosOnly here
                // MediaCell videos manage themselves via VideoPlaybackCoordinator
                // Fullscreen manager is now inactive and won't interfere
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                dismissFullscreenForBackground()
            }
    }

    private func dismissFullScreen() {
        OrientationManager.shared.lockToPortrait()
        dismiss()
    }

    private func dismissFullscreenForBackground() {
        guard !isDismissingForBackground else { return }
        isDismissingForBackground = true
        // Keep long-background recovery focused on feed/detail. Fullscreen will
        // save position and release its player through the normal onDisappear path.
        dismissFullScreen()
    }
    
    private func setupFullScreenManager() {
        // Set up navigation callback for auto-advance and swipe up
        FullScreenVideoManager.shared.onNavigateToNextVideo = { [self] nextTweet, videoIndex, nextSourceTweetId in
            
            // Animate transition: slide current video up and next video in from bottom
            Task { @MainActor in
                guard !isTransitioning, !isCompletingVerticalAdvance else { return }
                guard let allNextAttachments = nextTweet.attachments,
                      videoIndex < allNextAttachments.count else {
                    return
                }
                let attachment = allNextAttachments[videoIndex]
                let nextBaseUrl = nextTweet.author?.baseUrl
                    ?? HproseInstance.shared.appUser.baseUrl
                    ?? HproseInstance.baseUrl
                var nextBrowserIndex = 0
                nextBrowserIndex = Self.visualAttachmentIndex(
                    in: nextTweet,
                    originalIndex: videoIndex,
                    mid: attachment.mid
                )

                // Prevent TabView from doing a horizontal paging animation when we change currentIndex programmatically.
                // The vertical push should be the only visible transition.
                suppressTabPagingAnimation = true
                isCompletingVerticalAdvance = true
                showControls = false
                let slideDistance = UIScreen.main.bounds.height

                withAnimation(.easeOut(duration: 0.14)) {
                    dragOffset = CGSize(width: 0, height: -slideDistance)
                }

                try? await Task.sleep(nanoseconds: 140_000_000)
                isTransitioning = true
                transitionOffset = slideDistance

                withAnimation(.none) {
                    isDragging = false
                    dragOffset = .zero
                    self.currentTweet = nextTweet
                    self.currentIndex = nextBrowserIndex
                    self.previousIndex = nextBrowserIndex
                }
                self.currentCellTweetId = nextSourceTweetId
                self.imageStates = [:]

                if let url = attachment.getUrl(nextBaseUrl) {
                    FullScreenVideoManager.shared.loadVideo(
                        url: url,
                        mid: attachment.mid,
                        tweetId: nextTweet.mid,
                        cellTweetId: nextSourceTweetId,
                        videoIndex: videoIndex,
                        mediaType: attachment.type
                    )
                }

                withAnimation(.easeInOut(duration: 0.22)) {
                    transitionOffset = 0
                }

                try? await Task.sleep(nanoseconds: 220_000_000)
                isTransitioning = false
                isCompletingVerticalAdvance = false
                suppressTabPagingAnimation = false
            }
        }
        
        // Set up exit fullscreen callback (when no more videos)
        FullScreenVideoManager.shared.onExitFullScreen = { [self] in
            dismissFullScreen()
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
        @Binding var isCompletingVerticalAdvance: Bool
        @Binding var transitionOffset: CGFloat
        @Binding var suppressTabPagingAnimation: Bool
        let currentTweet: Tweet
        let currentCellTweetId: String
        let dismiss: () -> Void
        let startControlsTimer: () -> Void
        let resetControlsTimer: () -> Void
        let onShareVisibilityChange: (Bool) -> Void
        let loadImageIfNeededClosure: (MimeiFileType, Int) -> Void
        let cleanupNonVisibleImagesClosure: (Int) -> Void
        let cleanupImageStatesClosure: () -> Void
        @State private var isCompletingDismiss = false

        /// Find the next video attachment index after the current index (skips images/audio).
        /// Returns nil if there is no next video in this tweet.
        private func nextVideoIndexInThisTweet(after index: Int) -> Int? {
            guard index + 1 < attachments.count else { return nil }
            for i in (index + 1)..<attachments.count {
                let att = attachments[i]
                if att.type == .video || att.type == .hls_video {
                    return i
                }
            }
            return nil
        }
        
        var body: some View {
            ZStack {
                // Background layer - stays in place (not affected by offset)
                Color.black
                    .ignoresSafeArea(.all, edges: .all)
                
                currentContentLayer
            }
            .statusBar(hidden: true)
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
                DispatchQueue.main.async {
                    loadSelectedVideoIfNeeded(reason: "contentAppear")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reloadVisibleVideosOnly)) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    loadSelectedVideoIfNeeded(reason: "reloadVisibleVideosOnly")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    loadSelectedVideoIfNeeded(reason: "didBecomeActive")
                }
            }
            .onDisappear {
                isVisible = false
                UIApplication.shared.isIdleTimerDisabled = false
                
                // Don't resume all videos - each video will resume automatically when it becomes visible
                // This allows videos that were already playing to continue, and only the exiting video to resume if needed
                
                // Clean up all image states to free memory
                cleanupImageStatesClosure()
            }
        }

        private var currentContentLayer: some View {
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
                        .offset(y: verticalOffset(for: index))
                        .scaleEffect(contentScale(for: index))
                        .animation(nil, value: dragOffset)
                        .tag(index)
                    }
                }
                .background(Color.black)
                .tabViewStyle(.page)
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .transaction { txn in
                    if suppressTabPagingAnimation {
                        txn.animation = nil
                    }
                }
                .simultaneousGesture(verticalVideoNavigationGesture)
                .onChange(of: currentIndex) { _, newIndex in
                    previousIndex = newIndex
                    cleanupNonVisibleImagesClosure(newIndex)
                    loadSelectedVideoIfNeeded(reason: "indexChanged")
                }

                if showControls {
                    controlsOverlay
                        .transition(.opacity)
                }
            }
        }

        private func verticalOffset(for index: Int) -> CGFloat {
            guard index == currentIndex else { return 0 }
            return isTransitioning ? transitionOffset : dragOffset.height
        }

        private func contentScale(for index: Int) -> CGFloat {
            guard index == currentIndex else { return 1.0 }
            let progress = min(abs(verticalOffset(for: index)), 520.0)
            return max(0.78, 1.0 - progress / 1300.0)
        }

        private var controlsOverlay: some View {
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
                // Hide action buttons for chat messages
                if !currentTweet.mid.hasPrefix("chat_") {
                    HStack {
                        TweetActionButtonsView(
                            tweet: currentTweet,
                            isInDetailView: true,
                            isFullScreen: true,
                            currentMediaIndex: originalAttachmentIndex(forVisualIndex: currentIndex),
                            onShareVisibilityChange: { isVisible in
                                onShareVisibilityChange(isVisible)
                            }
                        )
                        .environment(\.colorScheme, .dark)
                        .tint(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 60)
                }
            }
        }

        private var verticalVideoNavigationGesture: some Gesture {
            DragGesture(minimumDistance: 25)
                .onChanged { value in
                    guard !isTransitioning, !isCompletingVerticalAdvance, !isCompletingDismiss, !isImageZoomed else { return }

                    let vertical = abs(value.translation.height)
                    let horizontal = abs(value.translation.width)

                    if isDragging || vertical > horizontal * 1.25 {
                        isDragging = true
                        dragOffset = CGSize(width: 0, height: value.translation.height)
                    }
                }
                .onEnded { value in
                    guard !isTransitioning, !isCompletingVerticalAdvance, !isCompletingDismiss, !isImageZoomed else {
                        resetDragOffset(animated: true)
                        return
                    }

                    let vertical = abs(value.translation.height)
                    let horizontal = abs(value.translation.width)
                    guard isDragging || vertical > horizontal * 1.25 else {
                        resetDragOffset(animated: true)
                        return
                    }

                    let swipeThreshold: CGFloat = 90
                    let velocityThreshold: CGFloat = 450

                    if value.translation.height > swipeThreshold || value.velocity.height > velocityThreshold {
                        finishDismissAfterDrag()
                        return
                    }

                    if value.translation.height < -swipeThreshold || value.velocity.height < -velocityThreshold {
                        if let nextVideoIndex = nextVideoIndexInThisTweet(after: currentIndex) {
                            pushToNextVideoInCurrentTweet(nextVideoIndex)
                        } else {
                            FullScreenVideoManager.shared.navigateToNext()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                if !isTransitioning, !isCompletingVerticalAdvance {
                                    resetDragOffset(animated: true)
                                }
                            }
                        }
                    } else {
                        resetDragOffset(animated: true)
                    }
                }
        }

        private func resetDragOffset(animated: Bool) {
            isDragging = false
            if animated {
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9)) {
                    dragOffset = .zero
                }
            } else {
                dragOffset = .zero
            }
        }

        private func finishDismissAfterDrag() {
            guard !isCompletingDismiss else { return }
            isCompletingDismiss = true
            isDragging = false

            Task { @MainActor in
                let slideDistance = UIScreen.main.bounds.height
                withAnimation(.easeOut(duration: 0.16)) {
                    dragOffset = CGSize(width: 0, height: slideDistance)
                }

                try? await Task.sleep(nanoseconds: 160_000_000)
                dismiss()
            }
        }

        private func pushToNextVideoInCurrentTweet(_ nextVideoIndex: Int) {
            guard attachments.indices.contains(nextVideoIndex) else { return }

            Task { @MainActor in
                suppressTabPagingAnimation = true
                isCompletingVerticalAdvance = true
                showControls = false
                let slideDistance = UIScreen.main.bounds.height

                withAnimation(.easeOut(duration: 0.14)) {
                    dragOffset = CGSize(width: 0, height: -slideDistance)
                }

                try? await Task.sleep(nanoseconds: 140_000_000)
                isTransitioning = true
                transitionOffset = slideDistance

                withAnimation(.none) {
                    resetDragOffset(animated: false)
                    currentIndex = nextVideoIndex
                    previousIndex = nextVideoIndex
                }

                loadSelectedVideoIfNeeded(reason: "verticalSwipe")

                withAnimation(.easeInOut(duration: 0.22)) {
                    transitionOffset = 0
                }

                try? await Task.sleep(nanoseconds: 220_000_000)
                isTransitioning = false
                isCompletingVerticalAdvance = false
                suppressTabPagingAnimation = false
            }
        }
        
        // Helper functions
        private func isVideoAttachment(_ attachment: MimeiFileType) -> Bool {
            attachment.type == .video || attachment.type == .hls_video
        }

        private func originalAttachmentIndex(forVisualIndex index: Int) -> Int {
            guard attachments.indices.contains(index) else { return index }
            let attachment = attachments[index]
            return (currentTweet.attachments ?? []).firstIndex(where: { $0.mid == attachment.mid }) ?? index
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

        private func loadSelectedVideoIfNeeded(reason _: String) {
            guard isVisible else { return }
            guard attachments.indices.contains(currentIndex) else { return }

            let attachment = attachments[currentIndex]
            guard isVideoAttachment(attachment) else {
                FullScreenVideoManager.shared.pause()
                return
            }
            guard let url = attachment.getUrl(baseUrl) else {
                return
            }

            // TabView page lifecycle is not deterministic: the selected page's onAppear
            // can be skipped or delayed when fullscreen is presented over an active feed
            // player. The container owns the current selection, so it makes the selected
            // video load explicit; duplicate calls are ignored by FullScreenVideoManager.
            FullScreenVideoManager.shared.loadVideo(
                url: url,
                mid: attachment.mid,
                tweetId: currentTweet.mid,
                cellTweetId: currentCellTweetId,
                videoIndex: originalAttachmentIndex(forVisualIndex: currentIndex),
                mediaType: attachment.type
            )
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
            .contentShape(Rectangle())
            .simultaneousGesture(verticalVideoNavigationGesture)
            .onAppear {
                loadImageIfNeededClosure(attachment, index)
            }
        }
        
        private func videoView(for attachment: MimeiFileType, url: URL, index: Int) -> some View {
            let shouldAutoPlay = index == currentIndex
            let originalIndex = originalAttachmentIndex(forVisualIndex: index)
            
            return SingletonVideoPlayerView(
                url: url,
                mid: attachment.mid,
                tweetId: currentTweet.mid,
                cellTweetId: currentCellTweetId,
                videoIndex: originalIndex,
                mediaType: attachment.type,
                aspectRatio: attachment.aspectRatio,
                shouldAutoPlay: shouldAutoPlay,
                onUserInteraction: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls = true
                    }
                    resetControlsTimer()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
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
        
        // NOTE: Can't use [weak self] for structs (SwiftUI Views), but timer is invalidated properly
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
        // ✅ FIX: Remove baseUrl from request ID - cache key is based on mid, so request ID should match
        // Keep index prefix to distinguish between different browser views of the same image
        let loadId = "browser_\(index)_\(attachment.mid)"
        
        // First, try to get compressed image immediately
        if let compressedImage = ImageCacheManager.shared.getCompressedImage(for: attachment) {
            imageStates[index] = .loaded(compressedImage)
            
            // ✅ Load original image in background and replace compressed cache
            // This ensures fullscreen views use the highest quality image
            guard let url = attachment.getUrl(baseUrl) else { return }
            startOriginalImageLoad(for: attachment, at: index, url: url)
            return
        }
        
        // If no compressed image available, show loading state
        imageStates[index] = .loading
        
        // Load and cache compressed image
        guard let url = attachment.getUrl(baseUrl) else { 
            imageStates[index] = .error
            return 
        }
        
        // Fullscreen-visible media should outrank preload/background image work.
        GlobalImageLoadManager.shared.loadImageCriticalPriority(
            id: loadId,
            url: url,
            attachment: attachment,
            baseUrl: baseUrl
        ) { compressedImage in
            if let compressedImage = compressedImage {
                self.imageStates[index] = .loaded(compressedImage)
                
                // ✅ Load original image in background and replace compressed cache
                // This ensures fullscreen and detail views use the highest quality image
                startOriginalImageLoad(for: attachment, at: index, url: url)
            } else {
                self.imageStates[index] = .error
            }
        }
    }

    private func startOriginalImageLoad(for attachment: MimeiFileType, at index: Int, url: URL) {
        originalImageTasks[index]?.cancel()
        originalImageTasks[index] = Task {
            if let originalImage = await ImageCacheManager.shared.loadOriginalImage(
                from: url,
                for: attachment,
                baseUrl: baseUrl,
                replaceCompressedCache: true,
                priority: .critical
            ) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.originalImageTasks[index] != nil,
                          self.attachments.indices.contains(index),
                          self.attachments[index].mid == attachment.mid else { return }
                    self.imageStates[index] = .loaded(originalImage)
                }
            }

            await MainActor.run {
                if self.originalImageTasks[index]?.isCancelled != false {
                    return
                }
                self.originalImageTasks.removeValue(forKey: index)
            }
        }
    }
    

    

    
    private func getCachedPlaceholder(for attachment: MimeiFileType) -> UIImage? {
        return ImageCacheManager.shared.getCompressedImage(for: attachment)
    }
    
    private static func cleanupImageStates(attachments: [MimeiFileType], imageStates: Binding<[Int: ImageState]>, baseUrl: URL) {
        // Cancel all pending image loads
        // ✅ FIX: Use same request ID format as loadImageIfNeeded (without baseUrl)
        for (index, attachment) in attachments.enumerated() {
            let loadId = "browser_\(index)_\(attachment.mid)"
            GlobalImageLoadManager.shared.cancelLoad(id: loadId)
        }
        
        // Clear image states to free memory
        imageStates.wrappedValue.removeAll()
        
    }

    private func cleanupImageStates(attachments: [MimeiFileType]) {
        for task in originalImageTasks.values {
            task.cancel()
        }
        originalImageTasks.removeAll()

        for (index, attachment) in attachments.enumerated() {
            let loadId = "browser_\(index)_\(attachment.mid)"
            GlobalImageLoadManager.shared.cancelLoad(id: loadId)
        }

        imageStates.removeAll()
    }
    
    private static func cleanupNonVisibleImages(attachments: [MimeiFileType], currentIndex: Int, imageStates: Binding<[Int: ImageState]>, baseUrl: URL) {
        // Since we're using compressed images (small), we can keep more in memory
        // Keep current image and 2 images on each side
        let keepRange = max(0, currentIndex - 2)...min(attachments.count - 1, currentIndex + 2)
        
        for (index, _) in imageStates.wrappedValue {
            if !keepRange.contains(index) {
                // Cancel load for non-visible images
                // ✅ FIX: Use same request ID format as loadImageIfNeeded (without baseUrl)
                if index < attachments.count {
                    let attachment = attachments[index]
                    let loadId = "browser_\(index)_\(attachment.mid)"
                    GlobalImageLoadManager.shared.cancelLoad(id: loadId)
                }
                
                // Remove from image states
                imageStates.wrappedValue.removeValue(forKey: index)
            }
        }
    }

    private func cleanupNonVisibleImages(attachments: [MimeiFileType], currentIndex: Int) {
        let keepRange = max(0, currentIndex - 2)...min(attachments.count - 1, currentIndex + 2)

        let indexesToRemove = imageStates.keys.filter { index in
            !keepRange.contains(index) && index < attachments.count
        }

        for index in indexesToRemove {
            let attachment = attachments[index]
            let loadId = "browser_\(index)_\(attachment.mid)"
            GlobalImageLoadManager.shared.cancelLoad(id: loadId)
            originalImageTasks[index]?.cancel()
            originalImageTasks.removeValue(forKey: index)
            imageStates.removeValue(forKey: index)
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
                        .onEnded { _ in
                            lastOffset = .zero
                        },
                    including: scale > 1.0 ? .gesture : .subviews
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
    let cellTweetId: String
    let videoIndex: Int
    let mediaType: MediaType
    let aspectRatio: Float?
    let shouldAutoPlay: Bool
    let onUserInteraction: () -> Void
    
    @ObservedObject private var manager = FullScreenVideoManager.shared
    @State private var handoffThumbnail: UIImage?
    @State private var handoffThumbnailMid: String?
    @State private var readyForDisplayMid: String?

    private var didThisVideoFailToLoad: Bool {
        manager.loadFailedVideoMid == mid
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // CRITICAL: Also check currentItem is valid - after background release, player may exist but currentItem is nil
                if let player = manager.singletonPlayer, manager.currentVideoMid == mid, player.currentItem != nil {
                    let layerReadyForCurrentVideo = readyForDisplayMid == mid
                    let visualState = manager.visualState(
                        for: mid,
                        hasPoster: currentPosterImage != nil,
                        layerReadyForDisplay: layerReadyForCurrentVideo,
                        player: player
                    )
                    // Show player
                    FullscreenPlayerLayerView(
                        player: player,
                        mid: mid,
                        onReadyForDisplay: {
                            DispatchQueue.main.async {
                                readyForDisplayMid = mid
                            }
                        }
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                onUserInteraction()
                            }
                        )

                    if visualState.showsPoster {
                        posterImage
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }

                    if visualState.showsSpinner {
                        loadingSpinnerOverlay
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                } else {
                    let visualState = manager.visualState(
                        for: mid,
                        hasPoster: currentPosterImage != nil,
                        layerReadyForDisplay: false,
                        player: nil
                    )
                    // No player, no item, or different video — show lastframe as placeholder.
                    // This covers the load-failed case (currentVideoMid set to nil, currentItem nil)
                    // and the initial loading state before the first item is attached.
                    loadingPoster(showSpinner: visualState.showsSpinner)
                }

                if didThisVideoFailToLoad {
                    retryButton
                }

            }
            .onAppear {
                refreshHandoffThumbnail(for: mid)
            }
            .onChange(of: mid) { _, newMid in
                readyForDisplayMid = nil
                refreshHandoffThumbnail(for: newMid)
            }
            .onReceive(NotificationCenter.default.publisher(for: .videoThumbnailCached)) { notification in
                guard notification.userInfo?["mediaID"] as? String == mid else { return }
                refreshHandoffThumbnail(for: mid)
            }
            .onReceive(NotificationCenter.default.publisher(for: .videoPlayerItemReplaced)) { notification in
                guard notification.userInfo?["mediaID"] as? String == mid else { return }
                readyForDisplayMid = nil
                refreshHandoffThumbnail(for: mid)
            }
            .onReceive(NotificationCenter.default.publisher(for: .reloadVisibleVideosOnly)) { _ in
                readyForDisplayMid = nil
                refreshHandoffThumbnail(for: mid)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                readyForDisplayMid = nil
                refreshHandoffThumbnail(for: mid)
            }
        }
    }

    private func refreshHandoffThumbnail(for mediaID: String) {
        handoffThumbnailMid = mediaID
        handoffThumbnail = SharedAssetCache.shared.cachedThumbnail(for: mediaID)
    }

    private var loadingSpinnerOverlay: some View {
        ZStack {
            Color.black.opacity(0.15)
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)
        }
    }

    @ViewBuilder
    private func loadingPoster(showSpinner: Bool) -> some View {
        ZStack {
            posterImage

            if showSpinner {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.5)
            }
        }
    }

    private var retryButton: some View {
        Button {
            manager.loadVideo(
                url: url,
                mid: mid,
                tweetId: tweetId,
                cellTweetId: cellTweetId,
                videoIndex: videoIndex,
                mediaType: mediaType
            )
        } label: {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Retry video"))
        .help("Retry video")
    }

    @ViewBuilder
    private var posterImage: some View {
        if let thumbnail = currentPosterImage {
            Image(uiImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Color.black
        }
    }

    private var currentPosterImage: UIImage? {
        let thumbnailForCurrentMid = handoffThumbnailMid == mid ? handoffThumbnail : nil
        return thumbnailForCurrentMid
            ?? SharedAssetCache.shared.cachedThumbnail(for: mid)
            ?? manager.transitionPoster(for: mid)
    }
}

// MARK: - Simple AVPlayerViewController Wrapper
private struct SimplerAVPlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer
    let mid: String
    
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

    private final class SurfaceAwarePlayerViewController: AVPlayerViewController {
        var onSurfaceReady: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onSurfaceReady?()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if view.window != nil {
                onSurfaceReady?()
            }
        }
    }
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = SurfaceAwarePlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .black
        controller.onSurfaceReady = {
            Task { @MainActor in
                FullScreenVideoManager.shared.markPlaybackSurfaceReady(player: player, mid: mid)
            }
        }
        
        // Setup observer to auto-play when ready
        setupPlayerItemObserver(player: player, context: context)
        
        // Observe currentItem changes to set up observer for new items
        context.coordinator.currentItemObserver = player.observe(\.currentItem, options: [.new]) { player, _ in
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
                // FullScreenVideoManager will handle playback after checking for saved state
            } else {
                context.coordinator.statusObserver = playerItem.observe(\.status, options: [.new]) { item, _ in
                    if item.status == .readyToPlay {
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
        if let controller = uiViewController as? SurfaceAwarePlayerViewController {
            controller.onSurfaceReady = {
                Task { @MainActor in
                    FullScreenVideoManager.shared.markPlaybackSurfaceReady(player: player, mid: mid)
                }
            }
            if controller.view.window != nil {
                controller.onSurfaceReady?()
            }
        }

        if uiViewController.player !== player {
            uiViewController.player = player
            
            // Setup observer for new player - don't auto-play, let FullScreenVideoManager handle it
            context.coordinator.statusObserver?.invalidate()
            if let playerItem = player.currentItem {
                if playerItem.status == .readyToPlay {
                    // FullScreenVideoManager will handle playback after checking for saved state
                } else {
                    context.coordinator.statusObserver = playerItem.observe(\.status, options: [.new]) { item, _ in
                        if item.status == .readyToPlay {
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

private struct FullscreenPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let mid: String
    let onReadyForDisplay: () -> Void

    func makeUIView(context: Context) -> LightweightVideoPlayerView {
        let view = LightweightVideoPlayerView()
        view.backgroundColor = .black
        view.setVideoGravity(.resizeAspect)
        view.onReadyForDisplay = onReadyForDisplay
        view.setPlayer(player)
        view.observeReadyForDisplay()
        markSurfaceReady(for: player, mid: mid)
        return view
    }

    func updateUIView(_ uiView: LightweightVideoPlayerView, context: Context) {
        uiView.setVideoGravity(.resizeAspect)
        uiView.onReadyForDisplay = onReadyForDisplay
        uiView.setPlayer(player)
        uiView.observeReadyForDisplay()
        markSurfaceReady(for: player, mid: mid)
    }

    private func markSurfaceReady(for player: AVPlayer, mid: String) {
        DispatchQueue.main.async {
            FullScreenVideoManager.shared.markPlaybackSurfaceReady(player: player, mid: mid)
        }
    }
}

// MARK: - Array Extension for Safe Access
extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

 
