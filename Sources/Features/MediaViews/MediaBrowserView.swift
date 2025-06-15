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
    let baseUrl: String
    let initialIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var isMuted: Bool = HproseInstance.shared.preferenceHelper?.getSpeakerMute() ?? false
    @State private var isZoomed: Bool = false
    @State private var zoomScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0

    init(attachments: [MimeiFileType], baseUrl: String, initialIndex: Int) {
        self.attachments = attachments
        self.baseUrl = baseUrl
        self.initialIndex = initialIndex
        _currentIndex = State(initialValue: initialIndex)
        print("MediaBrowserView init - attachments count: \(attachments.count), initialIndex: \(initialIndex)")
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TabView(selection: Binding(
                get: { currentIndex },
                set: { currentIndex = $0 }
            )) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { idx, attachment in
                    mediaBrowserItemView(idx: idx, attachment: attachment)
                        .tag(idx)
                }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
            .background(Color.black.edgesIgnoringSafeArea(.all))
            .disabled(isZoomed) // Disable TabView when zoomed

            // Close button
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .resizable()
                    .frame(width: 36, height: 36)
                    .foregroundColor(.white)
                    .padding()
            }
        }
        .onChange(of: zoomScale) { newScale in
            isZoomed = newScale > 1
        }
    }

    private func resetZoom() {
        withAnimation {
            zoomScale = 1.0
            offset = .zero
            lastOffset = .zero
            lastScale = 1.0
        }
    }

    @ViewBuilder
    private func mediaBrowserItemView(idx: Int, attachment: MimeiFileType) -> some View {
        if attachment.type.lowercased() == "video", let url = attachment.getUrl(baseUrl) {
            GeometryReader { geometry in
                ZStack {
                    SimpleVideoPlayer(
                        url: url,
                        autoPlay: true,
                        isMuted: isMuted,
                        onMuteChanged: { muted in
                            isMuted = muted
                            HproseInstance.shared.preferenceHelper?.setSpeakerMute(muted)
                            WebVideoPlayer.updateMuteExternally(isMuted: muted)
                        }
                    )
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(url) // force reload on url change
                    .onAppear {
                        isMuted = HproseInstance.shared.preferenceHelper?.getSpeakerMute() ?? false
                    }
                    .scaleEffect(zoomScale)
                    .offset(offset)
                    .gesture(
                        SimultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    let delta = value / lastScale
                                    lastScale = value
                                    zoomScale = min(max(zoomScale * delta, 1), 4)
                                }
                                .onEnded { _ in
                                    lastScale = 1.0
                                },
                            DragGesture()
                                .onChanged { value in
                                    if zoomScale > 1 {
                                        let newOffset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                        // Limit the offset based on scale
                                        let maxOffset = (zoomScale - 1) * geometry.size.width / 2
                                        offset = CGSize(
                                            width: min(max(newOffset.width, -maxOffset), maxOffset),
                                            height: min(max(newOffset.height, -maxOffset), maxOffset)
                                        )
                                    }
                                }
                                .onEnded { _ in
                                    lastOffset = offset
                                }
                        )
                    )
                    .onTapGesture(count: 2) {
                        if zoomScale > 1 {
                            resetZoom()
                        } else {
                            withAnimation {
                                zoomScale = 2.0
                            }
                        }
                    }
                    
                    // Mute/Unmute button
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: {
                                isMuted.toggle()
                                HproseInstance.shared.preferenceHelper?.setSpeakerMute(isMuted)
                                WebVideoPlayer.updateMuteExternally(isMuted: isMuted)
                            }) {
                                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .foregroundColor(.white)
                                    .padding(12)
                                    .background(Color.black.opacity(0.5))
                                    .clipShape(Circle())
                            }
                            .padding()
                        }
                        Spacer()
                    }
                }
            }
            .tag(idx)
        } else if attachment.type.lowercased() == "audio", let url = attachment.getUrl(baseUrl) {
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                SimpleAudioPlayer(url: url, autoPlay: true)
                    .frame(maxWidth: 400)
                    .padding()
            }
            .tag(idx)
        } else if let url = attachment.getUrl(baseUrl) {
            GeometryReader { geometry in
                ZStack {
                    // Show cached image first
                    if let cachedImage = ImageCacheManager.shared.getImage(for: attachment, baseUrl: baseUrl) {
                        Image(uiImage: cachedImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    
                    // Load and show full-size image
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                    } placeholder: {
                        if ImageCacheManager.shared.getImage(for: attachment, baseUrl: baseUrl) == nil {
                            Color.gray
                        }
                    }
                }
                .scaleEffect(zoomScale)
                .offset(offset)
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let delta = value / lastScale
                                lastScale = value
                                zoomScale = min(max(zoomScale * delta, 1), 4)
                            }
                            .onEnded { _ in
                                lastScale = 1.0
                            },
                        DragGesture()
                            .onChanged { value in
                                if zoomScale > 1 {
                                    let newOffset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                    // Limit the offset based on scale
                                    let maxOffset = (zoomScale - 1) * geometry.size.width / 2
                                    offset = CGSize(
                                        width: min(max(newOffset.width, -maxOffset), maxOffset),
                                        height: min(max(newOffset.height, -maxOffset), maxOffset)
                                    )
                                }
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                )
                .onTapGesture(count: 2) {
                    if zoomScale > 1 {
                        resetZoom()
                    } else {
                        withAnimation {
                            zoomScale = 2.0
                        }
                    }
                }
            }
            .tag(idx)
        } else {
            Color.gray
                .tag(idx)
        }
    }
} 