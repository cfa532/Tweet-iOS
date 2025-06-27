//
//  MediaCell.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI
import AVFoundation
import CryptoKit

// MARK: - MediaCell
struct MediaCell: View {
    let parentTweet: Tweet
    let attachmentIndex: Int
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var showFullScreen = false
    @State private var play = false
    @State private var isVisible = false
    @State private var shouldLoadVideo = false
    
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
                    ZStack {
                        SimpleVideoPlayer(
                            url: url,
                            autoPlay: play, // play is false by default, true after tap
                            isVisible: true,
                            aspectRatio: 1,
                            contentType: attachment.type
                        )
                        .frame(width: 320)
                        .environmentObject(MuteState.shared)
                        .onTapGesture {
                            handleVideoTap()
                        }
                        .onTapGesture(count: 2) {
                            showFullScreen = true
                        }
                        // Overlay play button if not playing
                        if !play {
                            Color.black.opacity(0.2)
                            Image(systemName: "play.circle.fill")
                                .resizable()
                                .frame(width: 40, height: 40)
                                .foregroundColor(.white)
                        }
                    }
                case "audio":
                    SimpleAudioPlayer(url: url, autoPlay: play && isVisible)
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
            if !shouldLoadVideo {
                // First tap: load and start video
                shouldLoadVideo = true
                play = true
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
    
    private func handleVideoTap() {
        // For videos that are already loaded, toggle play/pause
        play.toggle()
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


