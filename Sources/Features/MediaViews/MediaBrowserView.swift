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
    @State private var isMuted: Bool = HproseInstance.shared.preferenceHelper?.getSpeakerMute() ?? false
    @State private var imageStates: [Int: ImageState] = [:]
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    @State private var dragOffset = CGSize.zero
    @State private var isDragging = false
    @State private var previousIndex: Int = -1 // Track previous index for video management
    @State private var isVideoLoading = false // Track if video is loading to prevent premature close
    @State private var hasBeenOpenForAWhile = false // Track if fullscreen has been open long enough to prevent premature close


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
        ZStack {
            Color.black
                .ignoresSafeArea(.all, edges: .all)
            
            TabView(selection: $currentIndex) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                    Group {
                        if isVideoAttachment(attachment), let url = attachment.getUrl(baseUrl) {
                            // Create video player for all video attachments, but only play the current one
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
            .onChange(of: currentIndex) { newIndex in
                print("DEBUG: [MediaBrowserView] TabView index changed from \(previousIndex) to \(newIndex)")
                
                // Handle video switching in fullscreen mode
                if let previousAttachment = attachments[safe: previousIndex],
                   isVideoAttachment(previousAttachment) {
                    // Pause the previous video
                    if let player = VideoCacheManager.shared.getVideoPlayer(for: previousAttachment.mid, url: previousAttachment.getUrl(baseUrl)!, isHLS: true) {
                        player.pause()
                        print("DEBUG: [MediaBrowserView] Paused previous video: \(previousAttachment.mid)")
                    }
                }
                
                if let newAttachment = attachments[safe: newIndex],
                   isVideoAttachment(newAttachment) {
                    // Start playing the new video
                    if let player = VideoCacheManager.shared.getVideoPlayer(for: newAttachment.mid, url: newAttachment.getUrl(baseUrl)!, isHLS: true) {
                        player.play()
                        print("DEBUG: [MediaBrowserView] Started playing new video: \(newAttachment.mid)")
                    }
                }
                
                previousIndex = newIndex
            }
            
            // Close button overlay
            if showControls {
                VStack {
                    HStack {
                        Button(action: { 
                            // Only dismiss if video is not loading AND fullscreen has been open for a while
                            if !isVideoLoading || !hasBeenOpenForAWhile {
                                dismiss()
                            } else {
                                print("DEBUG: [MediaBrowserView] Preventing close button dismiss - video is still loading and fullscreen has been open")
                            }
                        }) {
                            Image(systemName: "xmark")
                                .font(.title2)
                                .foregroundColor(.white)
                                .padding()
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .disabled(isVideoLoading && hasBeenOpenForAWhile) // Only disable button while video is loading AND fullscreen has been open for a while
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
                    if value.translation.height > 0 { // Only allow downward drag
                        dragOffset = value.translation
                        isDragging = true
                        showControls = true
                        // Don't reset timer during drag - let it stay visible
                    }
                }
                .onEnded { value in
                    if value.translation.height > 100 || value.velocity.height > 500 {
                        // Dismiss if dragged down far enough or with enough velocity
                        // But only if video is not loading AND fullscreen has been open for a while
                        if !isVideoLoading || !hasBeenOpenForAWhile {
                            dismiss()
                        } else {
                            print("DEBUG: [MediaBrowserView] Preventing dismiss - video is still loading and fullscreen has been open")
                            // Reset position with animation
                            withAnimation(.spring()) {
                                dragOffset = .zero
                            }
                            isDragging = false
                            resetControlsTimer()
                        }
                    } else {
                        // Reset position with animation
                        withAnimation(.spring()) {
                            dragOffset = .zero
                        }
                        isDragging = false
                        // Reset timer after drag ends
                        resetControlsTimer()
                    }
                }
        )
        .onTapGesture {
            // Show close button for ALL content types on tap
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls = true
            }
            resetControlsTimer()
        }
        .onAppear {
            isVisible = true
            UIApplication.shared.isIdleTimerDisabled = true
            startControlsTimer()
            
            // Initialize previous index
            previousIndex = currentIndex
            
            // Pause all videos in MediaCells to prevent audio overlap
            pauseAllMediaCellVideos()
            
            // Allow fullscreen to stay open for at least 1 second before checking loading state
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                hasBeenOpenForAWhile = true
                print("DEBUG: [MediaBrowserView] Fullscreen has been open for a while - enabling loading state checks")
            }
            
            // Start playing the initial video if it's a video
            if let initialAttachment = attachments[safe: currentIndex],
               isVideoAttachment(initialAttachment) {
                print("DEBUG: [MediaBrowserView] Starting initial video with mid: \(initialAttachment.mid)")
                
                // Add a small delay to ensure the video player is properly initialized
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let player = VideoCacheManager.shared.getVideoPlayer(for: initialAttachment.mid, url: initialAttachment.getUrl(baseUrl)!, isHLS: true) {
                        player.play()
                        print("DEBUG: [MediaBrowserView] Started playing initial video for mid: \(initialAttachment.mid)")
                    }
                }
            }
        }
        .onDisappear {
            isVisible = false
            UIApplication.shared.isIdleTimerDisabled = false
            controlsTimer?.invalidate()
            
            // Resume MediaCell videos when exiting fullscreen
            resumeMediaCellVideos()
            
            print("DEBUG: [MediaBrowserView] Exiting full-screen - resuming MediaCell videos")
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
    
    // MARK: - Helper Methods
    private func isVideoAttachment(_ attachment: MimeiFileType) -> Bool {
        let type = attachment.type.lowercased()
        return type == "video" || type == "hls_video"
    }
    
    private func isAudioAttachment(_ attachment: MimeiFileType) -> Bool {
        return attachment.type.lowercased() == "audio"
    }
    
    private func isImageAttachment(_ attachment: MimeiFileType) -> Bool {
        return attachment.type.lowercased() == "image"
    }
    
    private func handleVideoLoadingState(_ isLoading: Bool) {
        // Only set loading state if fullscreen has been open for a while
        // This prevents premature dismissal during initial load
        if hasBeenOpenForAWhile {
            isVideoLoading = isLoading
            print("DEBUG: [MediaBrowserView] Video loading state changed to: \(isLoading) (fullscreen has been open)")
        } else {
            print("DEBUG: [MediaBrowserView] Ignoring video loading state change to: \(isLoading) (fullscreen not open long enough)")
        }
    }
    
    private func pauseAllMediaCellVideos() {
        // Pause all videos in the current tweet's MediaCells to prevent audio overlap
        for attachment in attachments {
            if isVideoAttachment(attachment) {
                VideoCacheManager.shared.pauseVideoPlayer(for: attachment.mid)
                print("DEBUG: [MediaBrowserView] Paused MediaCell video: \(attachment.mid)")
            }
        }
    }
    
    private func resumeMediaCellVideos() {
        // Resume MediaCell videos when exiting fullscreen
        // Only resume the current video if it was playing in fullscreen
        if let currentAttachment = attachments[safe: currentIndex],
           isVideoAttachment(currentAttachment) {
            // The current video will continue playing from where it left off in fullscreen
            print("DEBUG: [MediaBrowserView] Current video will continue in MediaCell: \(currentAttachment.mid)")
        }
        
        // For other videos, they will resume based on their visibility state in MediaCells
        for (index, attachment) in attachments.enumerated() {
            if isVideoAttachment(attachment) && index != currentIndex {
                // These videos will be managed by their respective MediaCells
                print("DEBUG: [MediaBrowserView] Video \(attachment.mid) will be managed by MediaCell")
            }
        }
    }
    
    @ViewBuilder
    private func videoView(for attachment: MimeiFileType, url: URL, index: Int) -> some View {
        SimpleVideoPlayer(
            url: url,
            mid: attachment.mid,
            autoPlay: index == currentIndex, // Only auto-play if this is the current video
            onMuteChanged: { _ in
                // In full-screen mode, don't update global mute state
                // Full-screen videos should have independent audio control
            },
            onVideoLoadingChanged: { isLoading in
                // Update loading state to prevent premature fullscreen close
                handleVideoLoadingState(isLoading)
            },
            isVisible: index == currentIndex, // Only visible if this is the current video
            contentType: attachment.type,
            videoAspectRatio: CGFloat(attachment.aspectRatio ?? 16.0/9.0),
            onVideoTap: {
                // Show close button when video is tapped
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls = true
                }
                resetControlsTimer() // Reset close button timer
            },
            disableAutoRestart: false, // Enable auto-restart in fullscreen mode
            mode: .mediaBrowser
        )
        .environmentObject(MuteState.shared)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
    

    
    @ViewBuilder
    private func audioView(for attachment: MimeiFileType, url: URL, index: Int) -> some View {
        SimpleAudioPlayer(
            url: url,
            autoPlay: isVisible && currentIndex == index
        )
        .environmentObject(MuteState.shared)
    }
    
    @ViewBuilder
    private func imageView(for attachment: MimeiFileType, url: URL, index: Int) -> some View {
        ZoomableImageView(
            imageURL: url,
            placeholderImage: getCachedPlaceholder(for: attachment),
            contentMode: .fit
        )
        .onAppear {
            loadImageIfNeeded(for: attachment, at: index)
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
    
    var body: some View {
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
                    .overlay(
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.0)
                            .background(Color.black.opacity(0.3))
                            .clipShape(Circle())
                            .padding(),
                        alignment: .topTrailing
                    )
                
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Array Extension for Safe Access
extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

 
