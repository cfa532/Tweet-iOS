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
    @State private var currentIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var isVisible = true
    @State private var isMuted: Bool = HproseInstance.shared.preferenceHelper?.getSpeakerMute() ?? false

    init(attachments: [MimeiFileType], baseUrl: String, initialIndex: Int) {
        self.attachments = attachments
        self.baseUrl = baseUrl
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
                        if attachment.type.lowercased() == "video", let url = attachment.getUrl(baseUrl) {
                            SimpleVideoPlayer(
                                url: url,
                                autoPlay: true,
                                isMuted: false,
                                isVisible: isVisible && currentIndex == index
                            )
                            .environmentObject(MuteState.shared)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if attachment.type.lowercased() == "audio", let url = attachment.getUrl(baseUrl) {
                            SimpleAudioPlayer(
                                url: url,
                                autoPlay: isVisible && currentIndex == index
                            )
                        } else if let url = attachment.getUrl(baseUrl) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .empty:
                                    ProgressView()
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                case .failure:
                                    Image(systemName: "photo")
                                        .foregroundColor(.gray)
                                @unknown default:
                                    EmptyView()
                                }
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
} 