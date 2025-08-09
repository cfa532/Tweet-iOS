//
//  NewMediaCell.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  Simplified media cell using the new SimpleVideoPlayer
//

import SwiftUI
import AVFoundation

/// Simplified media cell with basic video playback
struct NewMediaCell: View {
    let parentTweet: Tweet
    let attachmentIndex: Int
    let aspectRatio: Float
    let autoplay: Bool
    let autoReplay: Bool
    let mute: Bool
    let onTap: (() -> Void)?
    
    @State private var image: UIImage?
    @State private var isLoading = false
    
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
    
    init(
        parentTweet: Tweet,
        attachmentIndex: Int,
        aspectRatio: Float = 1.0,
        autoplay: Bool = true,
        autoReplay: Bool = false,
        mute: Bool = true,
        onTap: (() -> Void)? = nil
    ) {
        self.parentTweet = parentTweet
        self.attachmentIndex = attachmentIndex
        self.aspectRatio = aspectRatio
        self.autoplay = autoplay
        self.autoReplay = autoReplay
        self.mute = mute
        self.onTap = onTap
    }
    
    var body: some View {
        Group {
            if let url = attachment.getUrl(baseUrl) {
                switch attachment.type.lowercased() {
                case "video", "hls_video":
                    videoView(url: url)
                case "image":
                    imageView(url: url)
                default:
                    placeholderView
                }
            } else {
                placeholderView
            }
        }
        .aspectRatio(CGFloat(aspectRatio), contentMode: .fit)
        .clipped()
        .onTapGesture {
            onTap?()
        }
    }
    
    // MARK: - Video View
    private func videoView(url: URL) -> some View {
        Group {
            // Only create video player if we should load video (for now, always load)
            if true { // shouldLoadVideo equivalent - always true for NewMediaCell
                SimpleVideoPlayer(
                    url: url,
                    autoplay: autoplay,
                    autoReplay: autoReplay,
                    mute: mute
                )
                .onReceive(MuteState.shared.$isMuted) { isMuted in
                    print("DEBUG: [NEW MEDIA CELL] Mute state changed to: \(isMuted)")
                }
                .overlay(
                    // Video controls overlay - match MediaCell style
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            
                            // Mute button - match MediaCell styling
                            Button(action: {
                                MuteState.shared.toggleMute()
                            }) {
                                Image(systemName: MuteState.shared.isMuted ? "speaker.slash" : "speaker.wave.2")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white.opacity(0.8))
                                    .frame(width: 30, height: 30)
                                    .background(Color.black.opacity(0.4))
                                    .clipShape(Circle())
                                    .contentShape(Circle())
                            }
                            .padding(.trailing, 8)
                            .padding(.bottom, 8)
                        }
                    }
                )
            } else {
                // Show placeholder for videos that haven't been loaded yet - match MediaCell
                Color.black
                    .aspectRatio(contentMode: .fill)
                    .overlay(
                        Image(systemName: "play.circle")
                            .font(.system(size: 40))
                            .foregroundColor(.white)
                    )
                    .onTapGesture {
                        onTap?()
                    }
            }
        }
    }
    
    // MARK: - Image View  
    private func imageView(url: URL) -> some View {
        Group {
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
        }
        .onAppear {
            loadImage(url: url)
        }
    }
    
    // MARK: - Placeholder View
    private var placeholderView: some View {
        EmptyView()
    }
    
    // MARK: - Image Loading
    private func loadImage(url: URL) {
        // First, try to get cached image immediately - match MediaCell pattern
        if let cachedImage = imageCache.getCompressedImage(for: attachment, baseUrl: baseUrl) {
            self.image = cachedImage
            return
        }
        
        // If no cached image, start loading
        guard !isLoading else { return }
        isLoading = true
        
        Task {
            if let loadedImage = await imageCache.loadAndCacheImage(from: url, for: attachment, baseUrl: baseUrl) {
                await MainActor.run {
                    self.image = loadedImage
                    self.isLoading = false
                    print("DEBUG: [NEW MEDIA CELL] Image loaded for: \(attachment.mid)")
                }
            } else {
                await MainActor.run {
                    self.isLoading = false
                    print("ERROR: [NEW MEDIA CELL] Failed to load image for: \(attachment.mid)")
                }
            }
        }
    }
}

// MARK: - Equatable
extension NewMediaCell: Equatable {
    static func == (lhs: NewMediaCell, rhs: NewMediaCell) -> Bool {
        return lhs.parentTweet.mid == rhs.parentTweet.mid &&
               lhs.attachmentIndex == rhs.attachmentIndex &&
               lhs.aspectRatio == rhs.aspectRatio &&
               lhs.autoplay == rhs.autoplay &&
               lhs.autoReplay == rhs.autoReplay &&
               lhs.mute == rhs.mute
    }
}

