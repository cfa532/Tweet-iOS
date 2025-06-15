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

            // Close button
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .resizable()
                    .frame(width: 36, height: 36)
                    .foregroundColor(.white)
                    .padding()
            }
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
                            DispatchQueue.main.async {
                                isMuted = muted
                                HproseInstance.shared.preferenceHelper?.setSpeakerMute(muted)
                            }
                        }
                    )
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(url) // force reload on url change
                    .onAppear {
                        isMuted = HproseInstance.shared.preferenceHelper?.getSpeakerMute() ?? false
                    }
                    
                    // Mute/Unmute button
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: {
                                DispatchQueue.main.async {
                                    isMuted.toggle()
                                    HproseInstance.shared.preferenceHelper?.setSpeakerMute(isMuted)
                                }
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
            }
            .tag(idx)
        } else {
            Color.gray
                .tag(idx)
        }
    }
} 