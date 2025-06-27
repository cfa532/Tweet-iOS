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
    let aspectRatio: Float
    
    @State private var showFullScreen = false
    @State private var autoPlay: Bool         // play/stop video/audio
    @State private var isVisible = false    // load Image
    @State private var shouldLoadVideo = false
    @StateObject private var videoPlayerState = VideoPlayerState()
    @StateObject private var imageLoader = MediaImageLoader()
    
    private let imageCache = ImageCacheManager.shared
    
    init(parentTweet: Tweet, attachmentIndex: Int, aspectRatio: Float = 1.0, play: Bool = false) {
        self.parentTweet = parentTweet
        self.attachmentIndex = attachmentIndex
        self.aspectRatio = aspectRatio
        self._autoPlay = State(initialValue: play)
    }
    
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
        GeometryReader { geometry in
            Group {
                if let url = attachment.getUrl(baseUrl) {
                    switch attachment.type.lowercased() {
                    case "video", "hls_video":
                        ZStack {
                            SimpleVideoPlayer(
                                url: url,
                                autoPlay: autoPlay,
                                aspectRatio: aspectRatio,
                                contentType: attachment.type,
                                playerState: videoPlayerState
                            )
                            .frame(width: geometry.size.width, height: geometry.size.width / CGFloat(aspectRatio))
                            .environmentObject(MuteState.shared)
                            .onTapGesture {
                                handleVideoTap()
                            }
                            .onTapGesture(count: 2) {
                                showFullScreen = true
                            }

                            // Overlay play button if not playing
                            if !autoPlay {
                                Color.black.opacity(0.2)
                                Image(systemName: "play.circle.fill")
                                    .resizable()
                                    .frame(width: 40, height: 40)
                                    .foregroundColor(.white)
                            }

                            // Video controls overlay at the bottom
                            VStack {
                                Spacer()
                                VideoControls(
                                    playerState: videoPlayerState,
                                    showControls: true
                                )
                                .padding(.bottom, 8)
                            }
                        }
                    case "audio":
                        SimpleAudioPlayer(url: url, autoPlay: autoPlay, playerState: videoPlayerState)
                            .onTapGesture {
                                handleTap()
                            }
                    case "image":
                        if let image = imageLoader.image {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else if imageLoader.isLoading {
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
            .frame(
                width: geometry.size.width,
                height: geometry.size.width / CGFloat(aspectRatio)
            )
        }
        .aspectRatio(CGFloat(aspectRatio), contentMode: .fit)
        .clipped()
        .onAppear {
            imageLoader.loadImage(for: attachment, baseUrl: baseUrl)
        }
        .onChange(of: isVisible) { newValue in
            if newValue && imageLoader.image == nil {
                imageLoader.loadImage(for: attachment, baseUrl: baseUrl)
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            if let attachments = parentTweet.attachments {
                MediaBrowserView(
                    attachments: attachments,
                    initialIndex: attachmentIndex,
                    autoPlay: true
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
                autoPlay = true
            }
        case "audio":
            // Toggle audio playback
            autoPlay.toggle()
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
        autoPlay.toggle()
    }
}
