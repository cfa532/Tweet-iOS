//
//  MediaBrowserView.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI
import AVKit

struct MediaBrowserView: View {
    let attachments: [MimeiFileType]
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

    private var baseUrl: URL {
        // Try to get baseUrl from the first attachment's parent tweet, fallback to HproseInstance.baseUrl
        return HproseInstance.baseUrl
    }

    init(attachments: [MimeiFileType], initialIndex: Int) {
        self.attachments = attachments
        self.initialIndex = initialIndex
        self._currentIndex = State(initialValue: initialIndex)
        print("MediaBrowserView init - attachments count: \(attachments.count), initialIndex: \(initialIndex)")
    }

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            TabView(selection: $currentIndex) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                    ZStack {
                        if (attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video"), let url = attachment.getUrl(baseUrl) {
                            SimpleVideoPlayer(
                                url: url,
                                autoPlay: true,
                                isMuted: false,
                                isVisible: isVisible && currentIndex == index,
                                aspectRatio: attachment.aspectRatio,
                                contentType: attachment.type
                            )
                            .environmentObject(MuteState.shared)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if attachment.type.lowercased() == "audio", let url = attachment.getUrl(baseUrl) {
                            SimpleAudioPlayer(
                                url: url,
                                autoPlay: isVisible && currentIndex == index
                            )
                        } else if attachment.type.lowercased() == "image", let url = attachment.getUrl(baseUrl) {
                            ImageViewWithPlaceholder(
                                attachment: attachment,
                                baseUrl: baseUrl,
                                url: url,
                                imageState: imageStates[index] ?? .loading
                            )
                            .onAppear {
                                loadImageIfNeeded(for: attachment, at: index)
                            }
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            
            VStack {
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding()
                    }
                    Spacer()
                }
                Spacer()
            }
        }
        .onAppear {
            isVisible = true
        }
        .onDisappear {
            isVisible = false
        }
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
                    Text("Failed to load image")
                        .foregroundColor(.gray)
                        .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
} 