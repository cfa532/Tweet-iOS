//
//  MediaCell.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI
import AVFoundation

// MARK: - MediaCell
struct MediaCell: View {
    let parentTweet: Tweet
    let attachmentIndex: Int
    let aspectRatio: Float      // passed in by MediaGrid or MediaBrowser
    
    @State private var play: Bool
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var showFullScreen = false
    @State private var isVisible = false
    @State private var shouldLoadVideo: Bool
    @State private var onVideoFinished: (() -> Void)?
    
    init(parentTweet: Tweet, attachmentIndex: Int, aspectRatio: Float = 1.0, play: Bool = false, shouldLoadVideo: Bool = false, onVideoFinished: (() -> Void)? = nil) {
        self.parentTweet = parentTweet
        self.attachmentIndex = attachmentIndex
        self.aspectRatio = aspectRatio
        self._play = State(initialValue: play)
        self.shouldLoadVideo = shouldLoadVideo
        self.onVideoFinished = onVideoFinished
    }
    
    private let imageCache = ImageCacheManager.shared
    
    private var attachment: MimeiFileType {
        guard let attachments = parentTweet.attachments,
              attachmentIndex >= 0 && attachmentIndex < attachments.count else {
            return MimeiFileType(mid: "", type: "unknown")
        }
        return attachments[attachmentIndex]
    }
    
    private var baseUrl: URL {
        return parentTweet.author?.baseUrl ?? HproseInstance.baseUrl
    }
    
    var body: some View {
        Group {
            if let url = attachment.getUrl(baseUrl) {
                switch attachment.type.lowercased() {
                case "video", "hls_video":
                    SimpleVideoPlayer(
                        url: url,
                        mid: attachment.mid,
                        autoPlay: play && shouldLoadVideo,
                        onVideoFinished: onVideoFinished,
                        isVisible: isVisible && shouldLoadVideo,
                        contentType: attachment.type,
                        cellAspectRatio: CGFloat(aspectRatio),
                        videoAspectRatio: CGFloat(attachment.aspectRatio ?? 1.0),
                        showNativeControls: true,
                        showCustomControls: false
                    )
                    .environmentObject(MuteState.shared)
                    .onTapGesture(count: 2) {
                        showFullScreen = true
                    }
                case "audio":
                    SimpleAudioPlayer(url: url, autoPlay: play && isVisible)
                        .environmentObject(MuteState.shared)
                        .onTapGesture {
                            handleTap()
                        }
                case "image":
                    if let image = image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipped()
                    } else if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(1.2)
                    } else {
                        Color.gray.opacity(0.3)
                    }
                default:
                    EmptyView()
                }
            } else {
                EmptyView()
            }
        }
        .onAppear(perform: loadImage)
        .onAppear {
            // Refresh mute state from preferences when cell appears
            MuteState.shared.refreshFromPreferences()
            
            // Set visibility for videos
            if attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video" {
                isVisible = true
            }
        }
        .onDisappear {
            isVisible = false
        }
        .onChange(of: isVisible) { newValue in
            if newValue && image == nil {
                loadImage()
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            if let attachments = parentTweet.attachments {
                MediaBrowserView(
                    attachments: attachments,
                    initialIndex: attachmentIndex
                )
            }
        }
    }
    
    private func handleTap() {
        switch attachment.type.lowercased() {
        case "video", "hls_video":
            if shouldLoadVideo {
                // Video is already loaded, toggle playback
                play.toggle()
            } else {
                // Force load video immediately on tap
                shouldLoadVideo = true
                play.toggle()
            }
        case "audio":
            // Toggle audio playback
            play.toggle()
        case "image":
            // Open full-screen for images
            showFullScreen = true
        default:
            // Open full-screen for other types
            showFullScreen = true
        }
    }
    
    private func loadImage() {
        guard let url = attachment.getUrl(baseUrl) else { return }
        
        // First, try to get cached image immediately
        if let cachedImage = imageCache.getCompressedImage(for: attachment, baseUrl: baseUrl) {
            self.image = cachedImage
            return
        }
        
        // If no cached image, start loading
        isLoading = true
        Task {
            if let loadedImage = await imageCache.loadAndCacheImage(from: url, for: attachment, baseUrl: baseUrl) {
                await MainActor.run {
                    self.image = loadedImage
                    self.isLoading = false
                }
            } else {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }
}


