//
//  MediaBrowserView.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI
import AVKit
import SDWebImageSwiftUI

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
                            // Only create video player for currently visible attachment
                            if index == currentIndex {
                                videoView(for: attachment, url: url, index: index)
                                    .onAppear {
                                        print("DEBUG: [MediaBrowserView] Video view appeared for index: \(index), currentIndex: \(currentIndex)")
                                    }
                            } else {
                                // Show placeholder for non-visible videos
                                videoPlaceholderView(for: attachment, url: url, index: index)
                            }
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
                        dismiss()
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
        }
        .onDisappear {
            isVisible = false
            UIApplication.shared.isIdleTimerDisabled = false
            controlsTimer?.invalidate()
            
            // Pause all videos when exiting full-screen
            pauseAllVideos()
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
    
    /// Pause all videos when exiting full-screen mode
    private func pauseAllVideos() {
        print("DEBUG: [MediaBrowserView] Pausing all videos when exiting full-screen")
        
        // Pause all video attachments in this tweet
        for attachment in attachments {
            if isVideoAttachment(attachment) {
                let fullscreenMid = "\(attachment.mid)_fullscreen"
                print("DEBUG: [MediaBrowserView] Pausing fullscreen video with mid: \(fullscreenMid)")
                
                // Pause the fullscreen video (keep it in memory for potential quick return)
                VideoCacheManager.shared.pauseVideoPlayer(for: fullscreenMid)
            }
        }
    }
    
    @ViewBuilder
    private func videoView(for attachment: MimeiFileType, url: URL, index: Int) -> some View {
        SimpleVideoPlayer(
            url: url,
            mid: attachment.mid,
            autoPlay: true, // Always auto-play in full-screen
            onMuteChanged: { _ in
                // In full-screen mode, don't update global mute state
                // Full-screen videos should have independent audio control
            },
            isVisible: true, // Always visible in full-screen
            contentType: attachment.type,
            cellAspectRatio: nil,
            videoAspectRatio: CGFloat(attachment.aspectRatio ?? 16.0/9.0),
            showNativeControls: true,
            forceUnmuted: true, // Force unmuted in full-screen
            onVideoTap: {
                // Show close button when video is tapped
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls = true
                }
                resetControlsTimer() // Reset close button timer
            },
            showCustomControls: true, // Enable custom controls in full-screen
            forcePlay: true // Force play and stop all other videos
        )
        .environmentObject(MuteState.shared)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
    
    @ViewBuilder
    private func videoPlaceholderView(for attachment: MimeiFileType, url: URL, index: Int) -> some View {
        // Show a placeholder for videos that are not currently visible
        Color.black
            .aspectRatio(contentMode: .fit)
            .overlay(
                VStack {
                    Image(systemName: "play.circle")
                        .font(.system(size: 60))
                        .foregroundColor(.white)
                    Text(LocalizedStringKey("Swipe to view"))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.top, 8)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

 
