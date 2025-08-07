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
    
    private func shouldPlayVideo(for index: Int) -> Bool {
        // A video should play if:
        // 1. It's the current video index, OR
        // 2. It's the first video and we haven't set a current video yet
        let isFirstVideo = index == findFirstVideoIndex()
        let isCurrentVideo = index == currentVideoIndex
        let shouldStartFirstVideo = isFirstVideo && currentVideoIndex == -1 && shouldLoadVideo
        
        return isCurrentVideo || shouldStartFirstVideo
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
            // Video playback is now controlled by visibility detection in MediaCell
        }
    }

    private func stopVideoPlayback() {
        // Video playback is now controlled by visibility detection in MediaCell
        currentVideoIndex = -1
    }

    private func onVideoFinished() {
        let nextIndex = findNextVideoIndex()
        
        if nextIndex != -1 {
            // Move to next video - playback controlled by visibility detection
            currentVideoIndex = nextIndex
        } else {
            // No more videos to play
            currentVideoIndex = -1
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let gridWidth: CGFloat = geometry.size.width
            let gridHeight = gridWidth / MediaGridViewModel.aspectRatio(for: attachments)

            ZStack {
                switch attachments.count {
                case 1:
                    MediaCell(
                        parentTweet: parentTweet,
                        attachmentIndex: 0,
                        aspectRatio: 1.0,
                        play: shouldPlayVideo(for: 0),
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
                    // identify MediaCell border
                   // .border(Color.red, width: 1)
                    
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
                                    play: shouldPlayVideo(for: idx),
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
                                    play: shouldPlayVideo(for: idx),
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
                                    play: shouldPlayVideo(for: 0),
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
                                    play: shouldPlayVideo(for: 1),
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
                                    play: shouldPlayVideo(for: 0),
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
                                    play: shouldPlayVideo(for: 1),
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
                    let ar0 = attachments[0].aspectRatio ?? 1
                    let ar1 = attachments[1].aspectRatio ?? 1
                    let ar2 = attachments[2].aspectRatio ?? 1
                    let allPortrait = ar0 < 1 && ar1 < 1 && ar2 < 1
                    let allLandscape = ar0 > 1 && ar1 > 1 && ar2 > 1
                    if allPortrait {
                        // All portrait: horizontal stack
                        HStack(spacing: 2) {
                            ForEach(0..<3) { idx in
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: idx,
                                    play: shouldPlayVideo(for: idx),
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth/3 - 1, height: gridHeight)
                                .clipped()
                                .contentShape(Rectangle())
                                .onTapGesture { onItemTap?(idx) }
                            }
                        }
                    } else if allLandscape {
                        // All landscape: vertical stack
                        VStack(spacing: 2) {
                            ForEach(0..<3) { idx in
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: idx,
                                    play: shouldPlayVideo(for: idx),
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth, height: gridHeight/3 - 1)
                                .clipped()
                                .contentShape(Rectangle())
                                .onTapGesture { onItemTap?(idx) }
                            }
                        }
                    } else if ar0 < 1 {
                        // First is portrait: left column tall, right column two stacked
                        HStack(spacing: 2) {
                            MediaCell(
                                parentTweet: parentTweet,
                                attachmentIndex: 0,
                                play: shouldPlayVideo(for: 0),
                                shouldLoadVideo: shouldLoadVideo,
                                onVideoFinished: onVideoFinished
                            )
                            .environmentObject(MuteState.shared)
                            .frame(width: gridWidth/2 - 1, height: gridHeight)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { onItemTap?(0) }
                            VStack(spacing: 2) {
                                ForEach(1..<3) { idx in
                                    MediaCell(
                                        parentTweet: parentTweet,
                                        attachmentIndex: idx,
                                        play: shouldPlayVideo(for: idx),
                                        shouldLoadVideo: shouldLoadVideo,
                                        onVideoFinished: onVideoFinished
                                    )
                                    .environmentObject(MuteState.shared)
                                    .frame(width: gridWidth/2 - 1, height: gridHeight/2 - 1)
                                    .clipped()
                                    .contentShape(Rectangle())
                                    .onTapGesture { onItemTap?(idx) }
                                }
                            }
                        }
                    } else {
                        // First is landscape: top row wide, bottom row two images
                        VStack(spacing: 2) {
                            MediaCell(
                                parentTweet: parentTweet,
                                attachmentIndex: 0,
                                play: shouldPlayVideo(for: 0),
                                shouldLoadVideo: shouldLoadVideo,
                                onVideoFinished: onVideoFinished
                            )
                            .environmentObject(MuteState.shared)
                            .frame(width: gridWidth, height: gridHeight/2 - 1)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { onItemTap?(0) }
                            HStack(spacing: 2) {
                                ForEach(1..<3) { idx in
                                    MediaCell(
                                        parentTweet: parentTweet,
                                        attachmentIndex: idx,
                                        play: shouldPlayVideo(for: idx),
                                        shouldLoadVideo: shouldLoadVideo,
                                        onVideoFinished: onVideoFinished
                                    )
                                    .environmentObject(MuteState.shared)
                                    .frame(width: gridWidth/2 - 1, height: gridHeight/2 - 1)
                                    .clipped()
                                    .contentShape(Rectangle())
                                    .onTapGesture { onItemTap?(idx) }
                                }
                            }
                        }
                    }
                    
                case 4:
                    let ar0 = attachments[0].aspectRatio ?? 1
                    let ar1 = attachments[1].aspectRatio ?? 1
                    let ar2 = attachments[2].aspectRatio ?? 1
                    let ar3 = attachments[3].aspectRatio ?? 1
                    let allPortrait = ar0 < 1 && ar1 < 1 && ar2 < 1 && ar3 < 1
                    let allLandscape = ar0 > 1 && ar1 > 1 && ar2 > 1 && ar3 > 1
                    let cellAspect: CGFloat = allPortrait ? 3.0/2.0 : (allLandscape ? 4.0/5.0 : 1.0)
                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            ForEach(0..<2) { idx in
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: idx,
                                    play: shouldPlayVideo(for: idx),
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished
                                )
                                .environmentObject(MuteState.shared)
                                .aspectRatio(cellAspect, contentMode: .fill)
                                .frame(width: gridWidth/2 - 1, height: gridHeight/2 - 1)
                                .clipped()
                                .contentShape(Rectangle())
                                .onTapGesture { onItemTap?(idx) }
                            }
                        }
                        HStack(spacing: 2) {
                            ForEach(2..<4) { idx in
                                if idx < attachments.count {
                                    MediaCell(
                                        parentTweet: parentTweet,
                                        attachmentIndex: idx,
                                        play: shouldPlayVideo(for: idx),
                                        shouldLoadVideo: shouldLoadVideo,
                                        onVideoFinished: onVideoFinished
                                    )
                                    .environmentObject(MuteState.shared)
                                    .aspectRatio(cellAspect, contentMode: .fill)
                                    .frame(width: gridWidth/2 - 1, height: gridHeight/2 - 1)
                                    .clipped()
                                    .contentShape(Rectangle())
                                    .onTapGesture { onItemTap?(idx) }
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
                                    play: shouldPlayVideo(for: idx),
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
                                            play: shouldPlayVideo(for: idx),
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
                    // Use a shorter delay for faster video loading
                    videoLoadTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
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
            return calculateOptimalAspectRatioForThreeItems(attachments)
        default:
            return 1.0
        }
    }
    
    /// Calculates optimal aspect ratio for 3 items based on their characteristics
    private static func calculateOptimalAspectRatioForThreeItems(_ attachments: [MimeiFileType]) -> CGFloat {
        let ar0 = attachments[0].aspectRatio ?? 1
        let ar1 = attachments[1].aspectRatio ?? 1
        let ar2 = attachments[2].aspectRatio ?? 1
        
        // Count portrait and landscape images
        let portraitCount = [ar0, ar1, ar2].filter { $0 < 1 }.count
        let landscapeCount = [ar0, ar1, ar2].filter { $0 > 1 }.count
        
        // Calculate average aspect ratio
        let avgAspectRatio = (ar0 + ar1 + ar2) / 3
        
        // Calculate variance to understand how diverse the aspect ratios are
        let variance = pow(ar0 - avgAspectRatio, 2) + pow(ar1 - avgAspectRatio, 2) + pow(ar2 - avgAspectRatio, 2)
        let standardDeviation = sqrt(variance / 3)
        
        // Decision algorithm:
        // 1. If all images are portrait (aspect ratio < 1), use 4:6 (0.67) for better vertical stacking
        if portraitCount == 3 {
            return 4.0/6.0 // 0.67 - Portrait layout
        }
        
        // 2. If all images are landscape (aspect ratio > 1), use 4:6 (0.67) for vertical stacking
        if landscapeCount == 3 {
            return 4.0/6.0 // 0.67 - Portrait layout for better landscape image display
        }
        
        // 3. If there's a mix of orientations, analyze the distribution
        if portraitCount == 2 && landscapeCount == 1 {
            // Two portraits, one landscape - prefer portrait layout
            return 4.0/6.0 // 0.67
        }
        
        if portraitCount == 1 && landscapeCount == 2 {
            // One portrait, two landscapes - prefer square layout for better balance
            return 1.0 // Square layout
        }
        
        // 4. If aspect ratios are very diverse (high standard deviation), use square layout
        if standardDeviation > 0.5 {
            return 1.0 // Square layout for diverse content
        }
        
        // 5. If average aspect ratio is close to square, use square layout
        if abs(avgAspectRatio - 1.0) < 0.2 {
            return 1.0 // Square layout
        }
        
        // 6. Default to portrait layout for better visual balance
        return 4.0/6.0 // 0.67 - Portrait layout
    }
}
