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
    @State private var showLoadingAlert: Bool = false

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
                        handleMediaTap(at: 0)
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
                                    handleMediaTap(at: idx)
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
                                    handleMediaTap(at: idx)
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
                                    handleMediaTap(at: idx)
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
                                handleMediaTap(at: 0)
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
                                        handleMediaTap(at: idx)
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
                                handleMediaTap(at: 0)
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
                                        handleMediaTap(at: idx)
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
                                handleMediaTap(at: 0)
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
                                        handleMediaTap(at: idx)
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
                                    handleMediaTap(at: idx)
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
                                    handleMediaTap(at: idx)
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
                                    handleMediaTap(at: idx)
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
                                        handleMediaTap(at: idx)
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
            .alert("Video Loading", isPresented: $showLoadingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Please wait while the video is being prepared.")
            }
        }
    }
    
    private func handleMediaTap(at index: Int) {
        let attachment = attachments[index]
        if attachment.type.lowercased() == "video" {
            // Create a temporary MediaCell to check readiness
            let cell = MediaCell(attachment: attachment, baseUrl: baseUrl)
            if cell.isReady {
                selectedIndex = index
                showBrowser = true
            } else {
                showLoadingAlert = true
            }
        } else {
            selectedIndex = index
            showBrowser = true
        }
    }
}

// MARK: - Zoomable View
struct ZoomableView<Content: View>: View {
    let content: Content
    @Binding var scale: CGFloat
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    init(scale: Binding<CGFloat>, @ViewBuilder content: () -> Content) {
        self._scale = scale
        self.content = content()
    }
    
    var body: some View {
        GeometryReader { geometry in
            content
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let delta = value / lastScale
                                lastScale = value
                                scale = min(max(scale * delta, 1), 4)
                            }
                            .onEnded { _ in
                                lastScale = 1.0
                            },
                        DragGesture()
                            .onChanged { value in
                                if scale > 1 {
                                    let newOffset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                    // Limit the offset based on scale
                                    let maxOffset = (scale - 1) * geometry.size.width / 2
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
                    withAnimation {
                        if scale > 1 {
                            scale = 1
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = 2
                        }
                    }
                }
                .allowsHitTesting(scale > 1) // Only allow zoom gestures when zoomed in
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
    @State private var isZoomed: Bool = false
    @State private var zoomScale: CGFloat = 1.0

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

    @ViewBuilder
    private func mediaBrowserItemView(idx: Int, attachment: MimeiFileType) -> some View {
        if attachment.type.lowercased() == "video", let url = attachment.getUrl(baseUrl) {
            ZStack {
                ZoomableView(scale: $zoomScale) {
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
            ZoomableView(scale: $zoomScale) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } placeholder: {
                    Color.gray
                }
            }
            .onTapGesture {
                dismiss()
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
