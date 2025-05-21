//
//  MediaGridView.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI
import AVKit

struct MediaGridView: View {
    let attachments: [MimeiFileType]
    let baseUrl: String

    @State private var isVisible: Bool = false
    @State private var showBrowser: Bool = false
    @State private var selectedIndex: Int = 0

    var body: some View {
        if attachments.isEmpty {
            EmptyView()
        } else {
            GeometryReader { geometry in
                let gridWidth = geometry.size.width
                let isSingleVideo = attachments.count == 1 && attachments[0].type.lowercased() == "video"
                let aspectRatio: CGFloat = {
                    if isSingleVideo, let ar = attachments[0].aspectRatio, ar > 0 {
                        return CGFloat(ar)
                    } else {
                        return 4.0 / 3.0
                    }
                }()
                let gridHeight = gridWidth / aspectRatio
                let firstVideoIndex = attachments.firstIndex { $0.type.lowercased() == "video" }

                ZStack {
                    switch attachments.count {
                    case 1:
                        MediaCell(
                            attachment: attachments[0],
                            baseUrl: baseUrl,
                            play: isVisible && firstVideoIndex == 0
                        )
                        .frame(width: gridWidth, height: gridHeight)
                        .onTapGesture {
                            selectedIndex = 0
                            showBrowser = true
                        }
                    case 2:
                        HStack(spacing: 2) {
                            MediaCell(
                                attachment: attachments[0],
                                baseUrl: baseUrl,
                                play: isVisible && firstVideoIndex == 0
                            )
                            .onTapGesture {
                                selectedIndex = 0
                                showBrowser = true
                            }
                            MediaCell(
                                attachment: attachments[1],
                                baseUrl: baseUrl,
                                play: isVisible && firstVideoIndex == 1
                            )
                            .onTapGesture {
                                selectedIndex = 1
                                showBrowser = true
                            }
                        }
                        .frame(width: gridWidth, height: gridHeight)
                    case 3:
                        HStack(spacing: 2) {
                            MediaCell(
                                attachment: attachments[0],
                                baseUrl: baseUrl,
                                play: isVisible && firstVideoIndex == 0
                            )
                            .frame(width: gridWidth / 2 - 1, height: gridHeight)
                            .onTapGesture {
                                selectedIndex = 0
                                showBrowser = true
                            }
                            VStack(spacing: 2) {
                                MediaCell(
                                    attachment: attachments[1],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == 1
                                )
                                .onTapGesture {
                                    selectedIndex = 1
                                    showBrowser = true
                                }
                                MediaCell(
                                    attachment: attachments[2],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == 2
                                )
                                .onTapGesture {
                                    selectedIndex = 2
                                    showBrowser = true
                                }
                            }
                            .frame(width: gridWidth / 2 - 1, height: gridHeight)
                        }
                        .frame(width: gridWidth, height: gridHeight)
                    case 4:
                        VStack(spacing: 2) {
                            HStack(spacing: 2) {
                                MediaCell(
                                    attachment: attachments[0],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == 0
                                )
                                .onTapGesture {
                                    selectedIndex = 0
                                    showBrowser = true
                                }
                                MediaCell(
                                    attachment: attachments[1],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == 1
                                )
                                .onTapGesture {
                                    selectedIndex = 1
                                    showBrowser = true
                                }
                            }
                            HStack(spacing: 2) {
                                MediaCell(
                                    attachment: attachments[2],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == 2
                                )
                                .onTapGesture {
                                    selectedIndex = 2
                                    showBrowser = true
                                }
                                MediaCell(
                                    attachment: attachments[3],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == 3
                                )
                                .onTapGesture {
                                    selectedIndex = 3
                                    showBrowser = true
                                }
                            }
                        }
                        .frame(width: gridWidth, height: gridHeight)
                    default:
                        EmptyView()
                    }
                }
                .frame(width: gridWidth, height: gridHeight)
                .clipped()
                .cornerRadius(8)
                .onAppear { isVisible = true }
                .onDisappear { isVisible = false }
                .fullScreenCover(isPresented: $showBrowser) {
                    MediaBrowserView(attachments: attachments, baseUrl: baseUrl, initialIndex: selectedIndex)
                }
            }
            .aspectRatio(attachments.count == 1 && attachments[0].type.lowercased() == "video" && attachments[0].aspectRatio != nil ? CGFloat(attachments[0].aspectRatio!) : 4.0/3.0, contentMode: .fit)
        }
    }
}

struct MediaBrowserView: View {
    let attachments: [MimeiFileType]
    let baseUrl: String
    let initialIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int

    init(attachments: [MimeiFileType], baseUrl: String, initialIndex: Int) {
        self.attachments = attachments
        self.baseUrl = baseUrl
        self.initialIndex = initialIndex
        _currentIndex = State(initialValue: initialIndex)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TabView(selection: $currentIndex) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { idx, attachment in
                    Group {
                        if attachment.type.lowercased() == "video", let url = attachment.getUrl(baseUrl) {
                            VideoPlayer(player: AVPlayer(url: url))
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let url = attachment.getUrl(baseUrl) {
                            AsyncImage(url: url) { image in
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } placeholder: {
                                Color.gray
                            }
                        } else {
                            Color.gray
                        }
                    }
                    .tag(idx)
                }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
            .background(Color.black.edgesIgnoringSafeArea(.all))
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .resizable()
                    .frame(width: 36, height: 36)
                    .foregroundColor(.white)
                    .padding()
            }
        }
    }
}
