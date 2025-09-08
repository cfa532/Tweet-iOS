//
//  MediaBrowserView.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI
import AVKit

struct MediaBrowserView: View {
    let tweet: Tweet
    let initialIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
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


    private var attachments: [MimeiFileType] {
        return tweet.attachments ?? []
    }

    private var baseUrl: URL {
        return tweet.author?.baseUrl ?? HproseInstance.baseUrl
    }

    init(tweet: Tweet, initialIndex: Int) {
        self.tweet = tweet
        self.initialIndex = initialIndex
        self._currentIndex = State(initialValue: initialIndex)
        self._previousIndex = State(initialValue: initialIndex)
        print("MediaBrowserView init - attachments count: \(tweet.attachments?.count ?? 0), initialIndex: \(initialIndex)")
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
            dismiss: { dismiss() },
            startControlsTimer: startControlsTimer,
            resetControlsTimer: resetControlsTimer,
            loadImageIfNeededClosure: { attachment, index in
                loadImageIfNeeded(for: attachment, at: index)
            }
        )
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
        let dismiss: () -> Void
        let startControlsTimer: () -> Void
        let resetControlsTimer: () -> Void
        let loadImageIfNeededClosure: (MimeiFileType, Int) -> Void
        
        var body: some View {
            ZStack {
                Color.black
                    .ignoresSafeArea(.all, edges: .all)
                
                TabView(selection: $currentIndex) {
                    ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                        Group {
                            if isVideoAttachment(attachment), let url = attachment.getUrl(baseUrl) {
                                videoView(for: attachment, url: url, index: index)
                            } else if isAudioAttachment(attachment), let url = attachment.getUrl(baseUrl) {
                                audioView(for: attachment, url: url, index: index)
                            } else if isImageAttachment(attachment), let url = attachment.getUrl(baseUrl) {
                                imageView(for: attachment, url: url, index: index)
                            }
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page)
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .onChange(of: currentIndex) { _, newIndex in
                    print("DEBUG: [MediaBrowserView] TabView index changed from \(previousIndex) to \(newIndex)")
                    previousIndex = newIndex
                }
                
                // Close button overlay
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
                    }
                    .transition(.opacity)
                }
            }
            .statusBar(hidden: true)
            .offset(y: dragOffset.height)
            .scaleEffect(1.0 - abs(dragOffset.height) / 1000.0)
            .opacity(1.0 - abs(dragOffset.height) / 500.0)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Only allow drag-down-to-exit if no image is zoomed
                        if value.translation.height > 0 && !isImageZoomed {
                            dragOffset = value.translation
                            isDragging = true
                            showControls = true
                        }
                    }
                    .onEnded { value in
                        // Only allow exit if no image is zoomed
                        if !isImageZoomed && (value.translation.height > 100 || value.velocity.height > 500) {
                            dismiss()
                        } else {
                            withAnimation(.spring()) {
                                dragOffset = .zero
                            }
                            isDragging = false
                            resetControlsTimer()
                        }
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
                
                // Stop all videos in the tweet list when entering full screen
                NotificationCenter.default.post(name: .stopAllVideos, object: nil)
                print("DEBUG: [MediaBrowserView] Posted stopAllVideos notification")
                
                previousIndex = currentIndex
            }
            .onDisappear {
                isVisible = false
                UIApplication.shared.isIdleTimerDisabled = false
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
            SimpleVideoPlayer(
                url: url,
                mid: attachment.mid,
                isVisible: true,
                autoPlay: index == currentIndex,
                videoAspectRatio: CGFloat(attachment.aspectRatio ?? 16.0/9.0),
                isMuted: false,
                onVideoTap: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls = true
                    }
                    resetControlsTimer()
                },
                disableAutoRestart: false,
                mode: .mediaBrowser
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
        

    }
    

    
    private func startControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            // Hide close button for ALL content types after 3 seconds
            withAnimation(.easeInOut(duration: 0.3)) {
                showControls = false
            }
        }
    }
    
    private func resetControlsTimer() {
        // Reset timer for ALL content types (including videos)
        startControlsTimer()
    }
    
    private func loadImageIfNeeded(for attachment: MimeiFileType, at index: Int) {
        // Show compressed image as placeholder first
        if let compressedImage = ImageCacheManager.shared.getCompressedImage(for: attachment, baseUrl: baseUrl) {
            imageStates[index] = .placeholder(compressedImage)
        } else {
            imageStates[index] = .loading
        }
        
        // Load original image from backend
        guard let url = attachment.getUrl(baseUrl) else { return }
        
        Task {
            if let originalImage = await ImageCacheManager.shared.loadOriginalImage(from: url, for: attachment, baseUrl: baseUrl) {
                await MainActor.run {
                    imageStates[index] = .loaded(originalImage)
                }
            } else {
                await MainActor.run {
                    imageStates[index] = .error
                }
            }
        }
    }
    

    

    
    private func getCachedPlaceholder(for attachment: MimeiFileType) -> UIImage? {
        return ImageCacheManager.shared.getCompressedImage(for: attachment, baseUrl: baseUrl)
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

// MARK: - Array Extension for Safe Access
extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

 
