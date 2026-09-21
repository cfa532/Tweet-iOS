//
//  MediaBrowserView.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/5/20.
//

import SwiftUI
import AVKit
import Combine
import Photos
import UIKit

struct MediaBrowserView: View {
    let tweet: Tweet
    let initialIndex: Int
    let cellTweetId: String? // The visible cell's tweet ID (could be retweet or quoting tweet)
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @StateObject private var videoSession = BrowserVideoSession()
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
    @State private var suppressPagingAnimation: Bool = false // Suppress horizontal paging during vertical next-video transitions
    @State private var originalImageTasks: [Int: Task<Void, Never>] = [:]
    @State private var focusedImageMid: String?
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
        // Match inline detail media to the node that supplied the tweet.
        // Keep the existing app route for locally constructed media without a route.
        return currentTweet.mediaBaseURL
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
                videoSession: videoSession,
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
                suppressPagingAnimation: $suppressPagingAnimation,
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
                FullScreenVideoManager.shared.prepareStartupAudioFade(duration: 0.5)
                setupFullScreenManager()
                OverlayVisibilityCoordinator.shared.beginOverlayIfNeeded(id: "mediaBrowserView", source: "MediaBrowserView")
                NotificationCenter.default.post(name: .stopAllVideos, object: nil)
                updateFocusedImageLoad(for: currentIndex)

                // Fullscreen has its own autoplay list. Feed and inline players
                // must stay stopped while fullscreen is active.
            }
            .onDisappear {
                OrientationManager.shared.lockToPortrait()
                videoSession.close()

                let shouldTransferVideoPlayback = attachments.indices.contains(currentIndex)
                    && (attachments[currentIndex].type == .video || attachments[currentIndex].type == .hls_video)
                    && FullScreenVideoManager.shared.currentVideoMid == attachments[currentIndex].mid

                FullScreenVideoManager.shared.deactivate(
                    transferPlaybackToUnderlyingSurface: shouldTransferVideoPlayback,
                    audioFadeDuration: 0.35
                ) {
                    OverlayVisibilityCoordinator.shared.endOverlay(
                        id: "mediaBrowserView",
                        source: "MediaBrowserView"
                    )
                }
                
                // CRITICAL: Clean up controls timer to prevent CPU cycles accumulation
                controlsTimer?.invalidate()
                controlsTimer = nil
                clearFocusedImageLoad()
                
                // DON'T post reloadVisibleVideosOnly here
                // MediaCell videos manage themselves via VideoPlaybackCoordinator
                // Fullscreen manager is now inactive and won't interfere
            }
            .onChange(of: currentIndex) { _, newIndex in
                updateFocusedImageLoad(for: newIndex)
                guard attachments.indices.contains(newIndex) else { return }
                let selectedAttachment = attachments[newIndex]
                if selectedAttachment.type == .image {
                    loadImageIfNeeded(for: selectedAttachment, at: newIndex)
                }
            }
            .presentationBackground(.clear)
    }

    private func dismissFullScreen() {
        OrientationManager.shared.lockToPortrait()
        dismiss()
    }

    private func setupFullScreenManager() {
        // Set up navigation callback for auto-advance and swipe up
        FullScreenVideoManager.shared.onNavigateToNextVideo = { [self] nextTweet, videoIndex, nextSourceTweetId in
            
            // Animate transition: slide current video up and next video in from bottom
            Task { @MainActor in
                var waitAttempts = 0
                while (isTransitioning || isCompletingVerticalAdvance) && waitAttempts < 10 {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    waitAttempts += 1
                }
                if isTransitioning || isCompletingVerticalAdvance {
                    isTransitioning = false
                    isCompletingVerticalAdvance = false
                    suppressPagingAnimation = false
                    dragOffset = .zero
                    transitionOffset = 0
                }
                guard let allNextAttachments = nextTweet.attachments,
                      videoIndex < allNextAttachments.count else {
                    return
                }
                let attachment = allNextAttachments[videoIndex]
                let nextBaseUrl = nextTweet.mediaBaseURL
                    ?? HproseInstance.shared.appUser.baseUrl
                    ?? HproseInstance.baseUrl
                var nextBrowserIndex = 0
                nextBrowserIndex = Self.visualAttachmentIndex(
                    in: nextTweet,
                    originalIndex: videoIndex,
                    mid: attachment.mid
                )

                // Prevent the pager from doing a horizontal paging animation when we change currentIndex programmatically.
                // The vertical push should be the only visible transition.
                suppressPagingAnimation = true
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
                suppressPagingAnimation = false
            }
        }
        
        // Set up exit fullscreen callback (when no more videos)
        FullScreenVideoManager.shared.onExitFullScreen = { [self] in
            dismissFullScreen()
        }
    }

    private func updateFocusedImageLoad(for index: Int) {
        guard attachments.indices.contains(index),
              attachments[index].type == .image else {
            cancelOriginalImageTasks(except: nil)
            clearFocusedImageLoad()
            return
        }

        let mid = attachments[index].mid
        cancelOriginalImageTasks(except: index)
        guard focusedImageMid != mid else { return }

        clearFocusedImageLoad()
        focusedImageMid = mid
        GlobalImageLoadManager.shared.beginFocusedImageLoad(for: mid)
        SharedAssetCache.shared.suspendFeedActivityForFocusedPlayback(
            protecting: mid,
            owner: "fullscreen image"
        )
    }

    private func clearFocusedImageLoad() {
        guard let focusedImageMid else { return }
        GlobalImageLoadManager.shared.endFocusedImageLoad(for: focusedImageMid)
        self.focusedImageMid = nil
    }

    private func cancelOriginalImageTasks(except protectedIndex: Int?) {
        let indexesToCancel = originalImageTasks.keys.filter { $0 != protectedIndex }
        for index in indexesToCancel {
            originalImageTasks[index]?.cancel()
            originalImageTasks.removeValue(forKey: index)
        }
    }
    
    // MARK: - MediaBrowserContentView
    private struct MediaBrowserContentView: View {
        let attachments: [MimeiFileType]
        let videoSession: BrowserVideoSession
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
        @Binding var suppressPagingAnimation: Bool
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
        @State private var isVideoZoomed = false

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
            GeometryReader { geometry in
                ZStack {
                    // Fade the shared backdrop as the current media is pulled down so
                    // the presenting screen is already visible when dismissal begins.
                    Color.black.opacity(dismissBackdropOpacity)
                        .ignoresSafeArea(.all, edges: .all)

                    // Full-screen covers in the iPad-on-Mac runtime can propose a size
                    // larger than their app window to UIKit-backed descendants. Pin the
                    // pager to the actual presentation geometry so media cannot escape it.
                    currentContentLayer
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .statusBar(hidden: true)
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
                NativeMediaPager(
                    count: attachments.count,
                    index: $currentIndex,
                    animateSelection: !suppressPagingAnimation,
                    isVideoZoomed: isVideoZoomed,
                    isVideo: { isVideoAttachment(attachments[$0]) }
                ) { index in
                    let attachment = attachments[index]
                    Group {
                        if isVideoAttachment(attachment), let url = attachment.getUrl(baseUrl) {
                            videoView(for: attachment, url: url, index: index)
                        } else if isAudioAttachment(attachment), let url = attachment.getUrl(baseUrl) {
                            audioView(for: attachment, url: url, index: index)
                        } else if isImageAttachment(attachment), attachment.getUrl(baseUrl) != nil {
                            imageView(for: attachment, index: index)
                        } else if isPDFAttachment(attachment) {
                            pdfView(for: attachment, index: index)
                        }
                    }
                    .background(Color.clear)
                    .offset(y: verticalOffset(for: index))
                    .scaleEffect(contentScale(for: index))
                    .animation(nil, value: dragOffset)
                }
                // A new tweet or attachment list owns a new set of hosted pages.
                .id([currentTweet.mid] + attachments.map(\.mid))
                .background(Color.clear)
                .simultaneousGesture(verticalNavigationGesture(allowImageAttachments: false))
                .onChange(of: currentIndex) { _, newIndex in
                    isVideoZoomed = false
                    previousIndex = newIndex
                    cleanupNonVisibleImagesClosure(newIndex)
                    loadSelectedVideoIfNeeded(reason: "indexChanged")
                }
                .onChange(of: currentTweet.mid) { _, _ in isVideoZoomed = false }
                .onChange(of: currentAttachmentIsImage) { _, isImage in
                    if !isImage { isImageZoomed = false }
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

        private var dismissBackdropOpacity: Double {
            let downwardOffset = max(dragOffset.height, 0)
            let fadeDistance = max(UIScreen.main.bounds.height * 0.35, 1)
            let progress = min(downwardOffset / fadeDistance, 1)
            return 1 - (0.2 * Double(progress))
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
                        .environmentObject(HproseInstance.shared)
                        .environment(\.colorScheme, .dark)
                        .tint(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, currentAttachmentIsImage ? 60 : 145)
                }
            }
        }

        private var currentAttachmentIsImage: Bool {
            guard attachments.indices.contains(currentIndex) else { return false }
            return isImageAttachment(attachments[currentIndex])
        }

        /// Reserve the home gesture and video controls, including a seek that
        /// outlasts the overlay timer, so those drags cannot advance or dismiss.
        private func isReservedSwipeStart(_ value: DragGesture.Value) -> Bool {
            let bottomExclusion: CGFloat = currentAttachmentIsImage ? 44 : 200
            return value.startLocation.y > UIScreen.main.bounds.height - bottomExclusion
        }

        private func verticalNavigationGesture(allowImageAttachments: Bool) -> some Gesture {
            DragGesture(minimumDistance: 25, coordinateSpace: .global)
                .onChanged { value in
                    guard !isReservedSwipeStart(value) else { return }
                    guard allowImageAttachments || !currentAttachmentIsImage else { return }
                    guard !isTransitioning, !isCompletingVerticalAdvance, !isCompletingDismiss, !isImageZoomed, !isVideoZoomed else { return }

                    let vertical = abs(value.translation.height)
                    let horizontal = abs(value.translation.width)

                    if isDragging || vertical > horizontal * 1.25 {
                        isDragging = true
                        dragOffset = CGSize(width: 0, height: value.translation.height)
                    }
                }
                .onEnded { value in
                    // If the app is resigning/backgrounding (home swipe took over),
                    // never treat the gesture end as navigation.
                    guard UIApplication.shared.applicationState == .active, !isReservedSwipeStart(value) else {
                        resetDragOffset(animated: false)
                        return
                    }
                    guard allowImageAttachments || !currentAttachmentIsImage else { return }
                    guard !isTransitioning, !isCompletingVerticalAdvance, !isCompletingDismiss, !isImageZoomed, !isVideoZoomed else {
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
            dismiss()
        }

        private func pushToNextVideoInCurrentTweet(_ nextVideoIndex: Int) {
            guard attachments.indices.contains(nextVideoIndex) else { return }

            Task { @MainActor in
                suppressPagingAnimation = true
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
                suppressPagingAnimation = false
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

            // Neighbouring pages are mounted before selection. The container owns
            // playback so preloading a page cannot start its video early.
            FullScreenVideoManager.shared.loadVideo(
                url: url,
                mid: attachment.mid,
                tweetId: currentTweet.mid,
                cellTweetId: currentCellTweetId,
                videoIndex: originalAttachmentIndex(forVisualIndex: currentIndex),
                mediaType: attachment.type
            )
        }
        
        private func imageView(for attachment: MimeiFileType, index: Int) -> some View {
            ImageViewWithPlaceholder(
                imageState: imageStates[index] ?? .loading,
                isImageZoomed: $isImageZoomed,
                isCurrentIndex: index == currentIndex,
                onTap: {
                    withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
                    resetControlsTimer()
                }
            )
            .contentShape(Rectangle())
            .simultaneousGesture(verticalNavigationGesture(allowImageAttachments: true))
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
                videoSession: videoSession,
                showControls: showControls,
                onNavigationLockChange: { zoomed in
                    isVideoZoomed = zoomed
                    if zoomed { resetDragOffset(animated: false) }
                },
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
            MainActor.assumeIsolated {
                // Hide close button for ALL content types after 3 seconds
                // but only if share sheet isn't visible anymore
                if !isShareSheetVisible {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showControls = false
                    }
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
            if index == currentIndex {
                startOriginalImageLoad(for: attachment, at: index, url: url)
            }
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
                if index == currentIndex {
                    startOriginalImageLoad(for: attachment, at: index, url: url)
                }
            } else {
                self.imageStates[index] = .error
            }
        }
    }

    private func startOriginalImageLoad(for attachment: MimeiFileType, at index: Int, url: URL) {
        guard index == currentIndex else { return }
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
    let imageState: ImageState
    @Binding var isImageZoomed: Bool
    let isCurrentIndex: Bool
    let onTap: () -> Void

    @State private var zoomed = false
    @State private var showDownloadToast = false
    @State private var downloadToastMessage = ""

    private var image: UIImage? {
        switch imageState {
        case .placeholder(let image), .loaded(let image): return image
        default: return nil
        }
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
        
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized || status == .limited else {
                showDownloadToast(message: NSLocalizedString("Photo library access denied", comment: "Photo library permission error"))
                return
            }

            do {
                let changes: @Sendable () -> Void = {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                try await PHPhotoLibrary.shared().performChanges(changes)
                showDownloadToast(message: NSLocalizedString("Image saved to Photos", comment: "Image save success"))
            } catch {
                showDownloadToast(message: NSLocalizedString("Failed to save image", comment: "Image save error"))
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
        ZStack {
            // Keep one native image view alive as the thumbnail is replaced by
            // the original, preserving zoom and pan when its aspect ratio matches.
            BrowserZoomableImage(
                image: image,
                onZoomChange: { zoomed = $0 },
                onTap: onTap,
                onLongPress: downloadImage
            )

            switch imageState {
            case .loading:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.5)
                    .allowsHitTesting(false)
            case .error:
                VStack {
                    Image(systemName: "photo")
                        .font(.system(size: 50))
                        .foregroundColor(.gray)
                    Text(LocalizedStringKey("Failed to load image"))
                        .foregroundColor(.gray)
                        .font(.caption)
                }
                .allowsHitTesting(false)
            case .placeholder, .loaded:
                EmptyView()
            }

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
                .allowsHitTesting(false)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: showDownloadToast)
            }
        }
        .clipped()
        .onAppear {
            if isCurrentIndex { isImageZoomed = zoomed }
        }
        .onChange(of: zoomed) { _, newValue in
            if isCurrentIndex { isImageZoomed = newValue }
        }
        .onChange(of: isCurrentIndex) { _, isCurrent in
            if isCurrent { isImageZoomed = zoomed }
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
    @ObservedObject var videoSession: BrowserVideoSession
    let showControls: Bool
    let onNavigationLockChange: (Bool) -> Void
    let onUserInteraction: () -> Void
    
    @ObservedObject private var manager = FullScreenVideoManager.shared
    @State private var handoffThumbnail: UIImage?
    @State private var handoffThumbnailMid: String?

    private var didThisVideoFailToLoad: Bool {
        manager.loadFailedVideoMid == mid
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // CRITICAL: Also check currentItem is valid - after background release, player may exist but currentItem is nil
                if let player = manager.singletonPlayer, manager.currentVideoMid == mid, let currentItem = player.currentItem {
                    let layerReadyForCurrentVideo = videoSession.isReady(for: player, mid: mid)
                    let visualState = manager.visualState(
                        for: mid,
                        hasPoster: currentPosterImage != nil,
                        layerReadyForDisplay: layerReadyForCurrentVideo,
                        player: player
                    )
                    BrowserVideoPlayer(
                        player: player,
                        mid: mid,
                        session: videoSession,
                        showControls: showControls,
                        onNavigationLockChange: onNavigationLockChange,
                        onUserInteraction: onUserInteraction
                    )
                    .id(fullscreenSurfaceID(mid: mid, item: currentItem))
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()

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
                refreshHandoffThumbnail(for: newMid)
            }
            .onReceive(NotificationCenter.default.publisher(for: .videoThumbnailCached)) { notification in
                guard notification.userInfo?["mediaID"] as? String == mid else { return }
                refreshHandoffThumbnail(for: mid)
            }
            .onReceive(NotificationCenter.default.publisher(for: .videoPlayerItemReplaced)) { notification in
                guard notification.userInfo?["mediaID"] as? String == mid else { return }
                refreshHandoffThumbnail(for: mid)
            }
            .onReceive(NotificationCenter.default.publisher(for: .reloadVisibleVideosOnly)) { _ in
                refreshHandoffThumbnail(for: mid)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                refreshHandoffThumbnail(for: mid)
            }
        }
    }

    private func fullscreenSurfaceID(mid: String, item: AVPlayerItem) -> String {
        "\(mid)-\(ObjectIdentifier(item).hashValue)"
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

// MARK: - Array Extension for Safe Access
extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

 
