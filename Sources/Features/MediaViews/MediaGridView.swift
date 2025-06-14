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

    // Helper to determine if an attachment is portrait
    private func isPortrait(_ attachment: MimeiFileType) -> Bool {
        guard let ar = attachment.aspectRatio, ar > 0 else { return false }
        return ar < 1.0 // width/height < 1 means portrait
    }
    // Helper to determine if an attachment is landscape
    private func isLandscape(_ attachment: MimeiFileType) -> Bool {
        guard let ar = attachment.aspectRatio, ar > 0 else { return false }
        return ar > 1.0 // width/height > 1 means landscape
    }

    var body: some View {
        if attachments.isEmpty {
            EmptyView()
        } else {
            let count = attachments.count
            // Determine layout/aspect ratio
            let allPortrait = attachments.allSatisfy { isPortrait($0) }
            let allLandscape = attachments.allSatisfy { isLandscape($0) }
            let aspect: CGFloat = {
                switch count {
                case 1:
                    if let ar = attachments[0].aspectRatio, ar > 0 {
                        return CGFloat(ar) // Use actual aspect ratio
                    } else {
                        return 1.0 // Square when no aspect ratio is available
                    }
                case 2:
                    if allPortrait { return 4.0/3.0 }
                    else if allLandscape { return 3.0/4.0 }
                    else { return 1.0 } // mixed
                case 3:
                    if allPortrait { return 4.0/3.0 }
                    else if allLandscape { return 3.0/4.0 }
                    else { return 1.0 }
                case 4:
                    return 1.0
                default:
                    return 1.0
                }
            }()
            let gridWidth: CGFloat = 320
            let gridHeight = gridWidth / aspect
            let firstVideoIndex = attachments.firstIndex { $0.type.lowercased() == "video" }

            ZStack {
                switch count {
                case 1:
                    // Single image: use actual aspect ratio
                    MediaCell(
                        attachment: attachments[0],
                        baseUrl: baseUrl,
                        play: isVisible && firstVideoIndex == 0
                    )
                    .frame(width: gridWidth, height: gridHeight)
                    .aspectRatio(contentMode: .fill)
                    .clipped()
                    .onTapGesture {
                        selectedIndex = 0
                        showBrowser = true
                    }
                case 2:
                    if allPortrait {
                        // HStack, 4:3
                        HStack(spacing: 2) {
                            ForEach(0..<2) { idx in
                                MediaCell(
                                    attachment: attachments[idx],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == idx
                                )
                                .frame(width: gridWidth / 2 - 1, height: gridHeight)
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .onTapGesture {
                                    selectedIndex = idx
                                    showBrowser = true
                                }
                            }
                        }
                    } else if allLandscape {
                        // VStack, 3:4
                        VStack(spacing: 2) {
                            ForEach(0..<2) { idx in
                                MediaCell(
                                    attachment: attachments[idx],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == idx
                                )
                                .frame(width: gridWidth, height: gridHeight / 2 - 1)
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .onTapGesture {
                                    selectedIndex = idx
                                    showBrowser = true
                                }
                            }
                        }
                    } else {
                        // Mixed: HStack, 1:1
                        HStack(spacing: 2) {
                            ForEach(0..<2) { idx in
                                MediaCell(
                                    attachment: attachments[idx],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == idx
                                )
                                .frame(width: gridWidth / 2 - 1, height: gridHeight)
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .onTapGesture {
                                    selectedIndex = idx
                                    showBrowser = true
                                }
                            }
                        }
                    }
                case 3:
                    if allPortrait {
                        // HStack: left 1, right VStack 2, 4:3
                        HStack(spacing: 2) {
                            MediaCell(
                                attachment: attachments[0],
                                baseUrl: baseUrl,
                                play: isVisible && firstVideoIndex == 0
                            )
                            .frame(width: gridWidth / 2 - 1, height: gridHeight)
                            .aspectRatio(contentMode: .fill)
                            .clipped()
                            .onTapGesture {
                                selectedIndex = 0
                                showBrowser = true
                            }
                            VStack(spacing: 2) {
                                ForEach(1..<3) { idx in
                                    MediaCell(
                                        attachment: attachments[idx],
                                        baseUrl: baseUrl,
                                        play: isVisible && firstVideoIndex == idx
                                    )
                                    .frame(width: gridWidth / 2 - 1, height: gridHeight / 2 - 1)
                                    .aspectRatio(contentMode: .fill)
                                    .clipped()
                                    .onTapGesture {
                                        selectedIndex = idx
                                        showBrowser = true
                                    }
                                }
                            }
                        }
                    } else if allLandscape {
                        // VStack: top 1, bottom HStack 2, 3:4
                        VStack(spacing: 2) {
                            MediaCell(
                                attachment: attachments[0],
                                baseUrl: baseUrl,
                                play: isVisible && firstVideoIndex == 0
                            )
                            .frame(width: gridWidth, height: gridHeight / 2 - 1)
                            .aspectRatio(contentMode: .fill)
                            .clipped()
                            .onTapGesture {
                                selectedIndex = 0
                                showBrowser = true
                            }
                            HStack(spacing: 2) {
                                ForEach(1..<3) { idx in
                                    MediaCell(
                                        attachment: attachments[idx],
                                        baseUrl: baseUrl,
                                        play: isVisible && firstVideoIndex == idx
                                    )
                                    .frame(width: gridWidth / 2 - 1, height: gridHeight / 2 - 1)
                                    .aspectRatio(contentMode: .fill)
                                    .clipped()
                                    .onTapGesture {
                                        selectedIndex = idx
                                        showBrowser = true
                                    }
                                }
                            }
                        }
                    } else {
                        // Mixed: HStack, left 1, right VStack 2, 1:1
                        HStack(spacing: 2) {
                            MediaCell(
                                attachment: attachments[0],
                                baseUrl: baseUrl,
                                play: isVisible && firstVideoIndex == 0
                            )
                            .frame(width: gridWidth / 2 - 1, height: gridHeight)
                            .aspectRatio(contentMode: .fill)
                            .clipped()
                            .onTapGesture {
                                selectedIndex = 0
                                showBrowser = true
                            }
                            VStack(spacing: 2) {
                                ForEach(1..<3) { idx in
                                    MediaCell(
                                        attachment: attachments[idx],
                                        baseUrl: baseUrl,
                                        play: isVisible && firstVideoIndex == idx
                                    )
                                    .frame(width: gridWidth / 2 - 1, height: gridHeight / 2 - 1)
                                    .aspectRatio(contentMode: .fill)
                                    .clipped()
                                    .onTapGesture {
                                        selectedIndex = idx
                                        showBrowser = true
                                    }
                                }
                            }
                        }
                    }
                case 4:
                    // 2x2 grid, 1:1
                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            ForEach(0..<2) { idx in
                                MediaCell(
                                    attachment: attachments[idx],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == idx
                                )
                                .frame(width: gridWidth / 2 - 1, height: gridHeight / 2 - 1)
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .onTapGesture {
                                    selectedIndex = idx
                                    showBrowser = true
                                }
                            }
                        }
                        HStack(spacing: 2) {
                            ForEach(2..<4) { idx in
                                MediaCell(
                                    attachment: attachments[idx],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == idx
                                )
                                .frame(width: gridWidth / 2 - 1, height: gridHeight / 2 - 1)
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .onTapGesture {
                                    selectedIndex = idx
                                    showBrowser = true
                                }
                            }
                        }
                    }
                default:
                    // For more than 4, show first 4 and overlay a count
                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            ForEach(0..<2) { idx in
                                MediaCell(
                                    attachment: attachments[idx],
                                    baseUrl: baseUrl,
                                    play: isVisible && firstVideoIndex == idx
                                )
                                .frame(width: gridWidth / 2 - 1, height: gridHeight / 2 - 1)
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .onTapGesture {
                                    selectedIndex = idx
                                    showBrowser = true
                                }
                            }
                        }
                        HStack(spacing: 2) {
                            ForEach(2..<4) { idx in
                                ZStack {
                                    MediaCell(
                                        attachment: attachments[idx],
                                        baseUrl: baseUrl,
                                        play: isVisible && firstVideoIndex == idx
                                    )
                                    .frame(width: gridWidth / 2 - 1, height: gridHeight / 2 - 1)
                                    .aspectRatio(contentMode: .fill)
                                    .clipped()
                                    .onTapGesture {
                                        selectedIndex = idx
                                        showBrowser = true
                                    }
                                    if idx == 3 {
                                        Color.black.opacity(0.4)
                                        Text("+\(attachments.count - 4)")
                                            .foregroundColor(.white)
                                            .font(.title)
                                            .bold()
                                    }
                                }
                            }
                        }
                    }
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
    }
}

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
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TabView(selection: $currentIndex) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { idx, attachment in
                    mediaBrowserItemView(idx: idx, attachment: attachment)
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
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture {
                        dismiss()
                    }
            } placeholder: {
                Color.gray
                    .onTapGesture {
                        dismiss()
                    }
            }
            .tag(idx)
        } else {
            Color.gray
                .onTapGesture {
                    dismiss()
                }
                .tag(idx)
        }
    }
}
