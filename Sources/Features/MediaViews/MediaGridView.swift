//
//  MediaGridView.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI
import AVKit

struct MediaGridView: View {
    let parentTweet: Tweet
    let attachments: [MimeiFileType]
    let maxImages: Int = 4
    let onItemTap: ((Int) -> Void)?
    @State private var shouldLoadVideo = true
    @State private var videoLoadTimer: Timer?
    @State private var currentVideoIndex: Int = -1
    
    init(parentTweet: Tweet, attachments: [MimeiFileType], onItemTap: ((Int) -> Void)? = nil) {
        self.parentTweet = parentTweet
        self.attachments = attachments
        self.onItemTap = onItemTap
        
        // Find the first video attachment and set it as the current video
        let firstVideoIndex = attachments.enumerated().first { _, attachment in
            attachment.type.lowercased().contains("video")
        }?.offset ?? -1
        
        self._currentVideoIndex = State(initialValue: firstVideoIndex)
    }

    private func isPortrait(_ attachment: MimeiFileType) -> Bool {
        guard let ar = attachment.aspectRatio, ar > 0 else { return false }
        return ar < 1.0
    }

    private func isLandscape(_ attachment: MimeiFileType) -> Bool {
        guard let ar = attachment.aspectRatio, ar > 0 else { return false }
        return ar > 1.0
    }

    private func shouldAutostart(for index: Int) -> Bool {
        // Only autostart if the grid has been visible for 0.3 seconds
        guard shouldLoadVideo else { return false }
        
        // Check if this is the first video and we should start playing
        let isFirstVideo = index == findFirstVideoIndex()
        let shouldStart = isFirstVideo && (attachments[index].type.lowercased() == "video" || attachments[index].type.lowercased() == "hls_video")
        
        return shouldStart
    }

    private func getVideoIndices() -> [Int] {
        return attachments.enumerated().compactMap { index, attachment in
            if attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video" {
                return index
            }
            return nil
        }
    }

    private func findFirstVideoIndex() -> Int {
        return getVideoIndices().first ?? -1
    }

    private func findNextVideoIndex() -> Int {
        let videoIndices = getVideoIndices()
        guard let currentIndex = videoIndices.firstIndex(of: currentVideoIndex) else {
            return videoIndices.first ?? -1
        }
        
        let nextIndex = currentIndex + 1
        if nextIndex < videoIndices.count {
            return videoIndices[nextIndex]
        }
        return -1 // No more videos to play
    }

    private func startVideoPlayback() {
        let firstVideoIndex = findFirstVideoIndex()
        
        if currentVideoIndex == -1 && firstVideoIndex != -1 {
            currentVideoIndex = firstVideoIndex
        }
    }

    private func stopVideoPlayback() {
        currentVideoIndex = -1
    }

    private func onVideoFinished() {
        let nextIndex = findNextVideoIndex()
        if nextIndex != -1 {
            currentVideoIndex = nextIndex
        } else {
            // No more videos to play, stop playback
            currentVideoIndex = -1
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let gridWidth: CGFloat = 320
            let gridHeight = gridWidth / MediaGridViewModel.aspectRatio(for: attachments)

            ZStack {
                switch attachments.count {
                case 1:
                    MediaCell(
                        parentTweet: parentTweet,
                        attachmentIndex: 0,
                        aspectRatio: 1.0,
                        play: currentVideoIndex == 0,
                        shouldLoadVideo: shouldLoadVideo,
                        onVideoFinished: onVideoFinished
                    )
                    .environmentObject(MuteState.shared)
                    .frame(width: gridWidth, height: gridHeight)
                    .aspectRatio(contentMode: .fill)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onItemTap?(0)
                    }
                    .border(Color.red, width: 1)
                    
                case 2:
                    let ar0 = attachments[0].aspectRatio ?? 1
                    let ar1 = attachments[1].aspectRatio ?? 1
                    let isPortrait0 = ar0 < 1
                    let isPortrait1 = ar1 < 1
                    let isLandscape0 = ar0 > 1
                    let isLandscape1 = ar1 > 1
                    if isPortrait0 && isPortrait1 {
                        // Both portrait: horizontal, aspect 3:2
                        HStack(spacing: 2) {
                            ForEach(0..<2) { idx in
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: idx,
                                    play: currentVideoIndex == idx,
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth/2 - 1, height: gridHeight)
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .contentShape(Rectangle())
                                .onTapGesture { onItemTap?(idx) }
                            }
                        }
                    } else if isLandscape0 && isLandscape1 {
                        // Both landscape: vertical, aspect 4:5
                        VStack(spacing: 2) {
                            ForEach(0..<2) { idx in
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: idx,
                                    play: currentVideoIndex == idx,
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth, height: gridHeight/2 - 1)
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .contentShape(Rectangle())
                                .onTapGesture { onItemTap?(idx) }
                            }
                        }
                    } else {
                        // One portrait, one landscape: horizontal, aspect 1:1, portrait 1/3, landscape 2/3
                        HStack(spacing: 2) {
                            if isPortrait0 {
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 0,
                                    play: currentVideoIndex == 0,
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth * 1/3 - 1, height: gridHeight)
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .contentShape(Rectangle())
                                .onTapGesture { onItemTap?(0) }
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 1,
                                    play: currentVideoIndex == 1,
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth * 2/3 - 1, height: gridHeight)
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .contentShape(Rectangle())
                                .onTapGesture { onItemTap?(1) }
                            } else {
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 0,
                                    play: currentVideoIndex == 0,
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth * 2/3 - 1, height: gridHeight)
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .contentShape(Rectangle())
                                .onTapGesture { onItemTap?(0) }
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 1,
                                    play: currentVideoIndex == 1,
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth * 1/3 - 1, height: gridHeight)
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .contentShape(Rectangle())
                                .onTapGesture { onItemTap?(1) }
                            }
                        }
                    }
                    
                case 3:
                    if isPortrait(attachments[0]) {
                        HStack(spacing: 2) {
                            MediaCell(
                                parentTweet: parentTweet,
                                attachmentIndex: 0,
                                play: currentVideoIndex == 0,
                                shouldLoadVideo: shouldLoadVideo,
                                onVideoFinished: onVideoFinished
                            )
                            .environmentObject(MuteState.shared)
                            .frame(width: gridWidth / 2 - 1, height: gridHeight)
                            .aspectRatio(contentMode: .fill)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onItemTap?(0)
                            }
                            
                            VStack(spacing: 2) {
                                ForEach(1..<3) { idx in
                                    MediaCell(
                                        parentTweet: parentTweet,
                                        attachmentIndex: idx,
                                        play: currentVideoIndex == idx,
                                        shouldLoadVideo: shouldLoadVideo,
                                        onVideoFinished: onVideoFinished
                                    )
                                    .environmentObject(MuteState.shared)
                                    .frame(width: gridWidth / 2 - 1, height: gridHeight / 2 - 1)
                                    .aspectRatio(contentMode: .fill)
                                    .clipped()
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        onItemTap?(idx)
                                    }
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 2) {
                            MediaCell(
                                parentTweet: parentTweet,
                                attachmentIndex: 0,
                                play: currentVideoIndex == 0,
                                shouldLoadVideo: shouldLoadVideo,
                                onVideoFinished: onVideoFinished
                            )
                            .environmentObject(MuteState.shared)
                            .frame(width: gridWidth, height: gridHeight / 2 - 1)
                            .aspectRatio(contentMode: .fill)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onItemTap?(0)
                            }
                            
                            HStack(spacing: 2) {
                                ForEach(1..<3) { idx in
                                    MediaCell(
                                        parentTweet: parentTweet,
                                        attachmentIndex: idx,
                                        play: currentVideoIndex == idx,
                                        shouldLoadVideo: shouldLoadVideo,
                                        onVideoFinished: onVideoFinished
                                    )
                                    .environmentObject(MuteState.shared)
                                    .frame(width: gridWidth / 2 - 1, height: gridHeight / 2 - 1)
                                    .aspectRatio(contentMode: .fill)
                                    .clipped()
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        onItemTap?(idx)
                                    }
                                }
                            }
                        }
                    }
                    
                default:
                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            ForEach(0..<2) { idx in
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: idx,
                                    play: currentVideoIndex == idx,
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth / 2 - 1, height: gridHeight / 2 - 1)
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onItemTap?(idx)
                                }
                            }
                        }
                        HStack(spacing: 2) {
                            ForEach(2..<4) { idx in
                                if idx < attachments.count {
                                    ZStack {
                                        MediaCell(
                                            parentTweet: parentTweet,
                                            attachmentIndex: idx,
                                            play: currentVideoIndex == idx,
                                            shouldLoadVideo: shouldLoadVideo,
                                            onVideoFinished: onVideoFinished
                                        )
                                        .environmentObject(MuteState.shared)
                                        .frame(width: gridWidth / 2 - 1, height: gridHeight / 2 - 1)
                                        .aspectRatio(contentMode: .fill)
                                        .clipped()
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            onItemTap?(idx)
                                        }
                                        
                                        if idx == 3 && attachments.count > 4 {
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
            }
            .frame(width: gridWidth, height: gridHeight)
            .clipped()
            .onAppear {
                // Start video loading timer if this grid contains videos
                let hasVideos = attachments.contains(where: { $0.type.lowercased() == "video" || $0.type.lowercased() == "hls_video" })
                
                if hasVideos {
                    videoLoadTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                        shouldLoadVideo = true
                        startVideoPlayback()
                    }
                }
            }
            .onDisappear {
                videoLoadTimer?.invalidate()
                videoLoadTimer = nil
                shouldLoadVideo = false
                stopVideoPlayback()
            }
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

// MARK: - MediaGridViewModel
struct MediaGridViewModel {
    static func aspectRatio(for attachments: [MimeiFileType]) -> CGFloat {
        switch attachments.count {
        case 1:
            if let ar = attachments[0].aspectRatio, ar > 0 {
                if ar < 0.9 {
                    return 0.9 // Portrait aspect ratio
                } else {
                    return CGFloat(ar) // Use actual aspect ratio for landscape
                }
            } else {
                return 1.0 // Square when no aspect ratio is available
            }
        case 2:
            let ar0 = attachments[0].aspectRatio ?? 1
            let ar1 = attachments[1].aspectRatio ?? 1
            let isPortrait0 = ar0 < 1
            let isPortrait1 = ar1 < 1
            let isLandscape0 = ar0 > 1
            let isLandscape1 = ar1 > 1
            if isPortrait0 && isPortrait1 {
                return 3.0/2.0  // Both portrait: horizontal, aspect 3:2
            } else if isLandscape0 && isLandscape1 {
                return 4.0/5.0  // Both landscape: vertical, aspect 4:5
            } else {
                return 2.0      // One portrait, one landscape: horizontal, aspect 2:1
            }
        case 3:
            if (attachments[0].aspectRatio ?? 1) < 1 {
                return CGFloat(attachments[0].aspectRatio ?? 1.0)
            } else {
                return CGFloat(attachments[0].aspectRatio ?? 1.0) / 2
            }
        default:
            return 1.0
        }
    }
}
