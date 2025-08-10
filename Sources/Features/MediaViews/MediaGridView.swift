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
    @State private var isVisible = false
    @State private var forceRefreshTrigger = 0
    @StateObject private var videoManager = VideoManager()
    
    init(parentTweet: Tweet, attachments: [MimeiFileType], onItemTap: ((Int) -> Void)? = nil) {
        self.parentTweet = parentTweet
        self.attachments = attachments
        self.onItemTap = onItemTap
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
    
    private func findFirstVideoIndex() -> Int {
        return attachments.enumerated().first { _, attachment in
            attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video"
        }?.offset ?? -1
    }
    
    private func shouldPlayVideo(for index: Int) -> Bool {
        guard index < attachments.count else { return false }
        let attachment = attachments[index]
        
        // Check if this is a video
        let isVideo = attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video"
        guard isVideo else { return false }
        
        // Use VideoManager to determine if this video should play
        let shouldPlay = videoManager.shouldPlayVideo(for: attachment.mid)
        print("DEBUG: [MediaGridView] shouldPlayVideo(\(index)) for \(attachment.mid): shouldPlay=\(shouldPlay)")
        
        return shouldPlay
    }
    
    private func onVideoFinished() {
        videoManager.onVideoFinished()
    }
    
    var body: some View {
        GeometryReader { geometry in
            let gridWidth: CGFloat = geometry.size.width
            let gridAspectRatio = MediaGridViewModel.aspectRatio(for: attachments)
            let gridHeight = gridWidth / gridAspectRatio
            
            ZStack {
                switch attachments.count {
                case 1:
                    MediaCell(
                        parentTweet: parentTweet,
                        attachmentIndex: 0,
                        aspectRatio: Float(gridAspectRatio),
                        shouldLoadVideo: shouldLoadVideo,
                        onVideoFinished: onVideoFinished,
                        videoManager: videoManager,
                        forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                    )
                    .environmentObject(MuteState.shared)
                    .frame(width: gridWidth, height: gridHeight)
                    .clipped().contentShape(Rectangle())
                    .contentShape(Rectangle())
                    // identify MediaCell border
                    //  .border(Color.red, width: 1)
                    
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
                                    aspectRatio: Float((gridWidth/2 - 1) / gridHeight),
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                    forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth/2 - 1, height: gridHeight)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                            }
                        }
                    } else if isLandscape0 && isLandscape1 {
                        // Both landscape: vertical, aspect 4:5
                        VStack(spacing: 2) {
                            ForEach(0..<2) { idx in
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: idx,
                                    aspectRatio: Float(gridWidth / (gridHeight/2 - 1)),
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                    forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth, height: gridHeight/2 - 1)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                            }
                        }
                    } else {
                        // One portrait, one landscape: horizontal, aspect 1:1, portrait 1/3, landscape 2/3
                        HStack(spacing: 2) {
                            if isPortrait0 {
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 0,
                                    aspectRatio: Float((gridWidth * 1/3 - 1) / gridHeight),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                    forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth * 1/3 - 1, height: gridHeight)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 1,
                                    aspectRatio: Float((gridWidth * 2/3 - 1) / gridHeight),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                    forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth * 2/3 - 1, height: gridHeight)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                            } else {
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 0,
                                    aspectRatio: Float((gridWidth * 2/3 - 1) / gridHeight),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                    forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth * 2/3 - 1, height: gridHeight)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 1,
                                    aspectRatio: Float((gridWidth * 1/3 - 1) / gridHeight),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                    forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth * 1/3 - 1, height: gridHeight)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                            }
                        }
                    }
                    
                case 3:
                    // Safety check for array bounds
                    if attachments.count < 3 {
                        EmptyView()
                    } else {
                        
                        let ar0 = attachments[0].aspectRatio ?? 1
                        let ar1 = attachments[1].aspectRatio ?? 1
                        let ar2 = attachments[2].aspectRatio ?? 1
                        let allPortrait = ar0 < 1 && ar1 < 1 && ar2 < 1
                        let allLandscape = ar0 > 1 && ar1 > 1 && ar2 > 1
                        
                        if allPortrait {
                            // All portrait: square grid, first item takes 61.8% of left side, other two divide right part vertically
                            HStack(spacing: 2) {
                                // First item: 61.8% of width (golden ratio)
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 0,
                                    aspectRatio: Float((gridWidth * 0.618 - 1) / gridHeight),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                    forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth * 0.618 - 1, height: gridHeight)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                                
                                // Right side: remaining 38.2% divided vertically
                                VStack(spacing: 2) {
                                    ForEach(1..<3) { idx in
                                        MediaCell(
                                            parentTweet: parentTweet,
                                            attachmentIndex: idx,
                                            aspectRatio: Float((gridWidth * 0.382 - 1) / (gridHeight/2 - 1)),
                                            
                                            shouldLoadVideo: shouldLoadVideo,
                                            onVideoFinished: onVideoFinished,
                                            videoManager: videoManager,
                                            forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                        )
                                        .environmentObject(MuteState.shared)
                                        .frame(width: gridWidth * 0.382 - 1, height: gridHeight/2 - 1)
                                        .clipped().contentShape(Rectangle())
                                        .contentShape(Rectangle())
                                    }
                                }
                            }
                        } else if allLandscape {
                            // All landscape: square grid, first item takes 61.8% of top portion, other two divide lower part horizontally
                            VStack(spacing: 2) {
                                // First item: 61.8% of height (golden ratio)
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 0,
                                    aspectRatio: Float(gridWidth / (gridHeight * 0.618 - 1)),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                    forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth, height: gridHeight * 0.618 - 1)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                                
                                // Bottom part: remaining 38.2% divided horizontally
                                HStack(spacing: 2) {
                                    ForEach(1..<3) { idx in
                                        MediaCell(
                                            parentTweet: parentTweet,
                                            attachmentIndex: idx,
                                            aspectRatio: Float((gridWidth/2 - 1) / (gridHeight * 0.382 - 1)),
                                            
                                            shouldLoadVideo: shouldLoadVideo,
                                            onVideoFinished: onVideoFinished,
                                            videoManager: videoManager,
                                            forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                        )
                                        .environmentObject(MuteState.shared)
                                        .frame(width: gridWidth/2 - 1, height: gridHeight * 0.382 - 1)
                                        .clipped().contentShape(Rectangle())
                                        .contentShape(Rectangle())
                                    }
                                }
                            }
                        } else if ar0 < 1 {
                            // First is portrait: left column tall, right column two stacked
                            HStack(spacing: 2) {
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 0,
                                    aspectRatio: Float((gridWidth/2 - 1) / gridHeight),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                    forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth/2 - 1, height: gridHeight)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                                VStack(spacing: 2) {
                                    ForEach(1..<3) { idx in
                                        MediaCell(
                                            parentTweet: parentTweet,
                                            attachmentIndex: idx,
                                            aspectRatio: Float((gridWidth/2 - 1) / (gridHeight/2 - 1)),
                                            
                                            shouldLoadVideo: shouldLoadVideo,
                                            onVideoFinished: onVideoFinished,
                                            videoManager: videoManager,
                                            forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                        )
                                        .environmentObject(MuteState.shared)
                                        .frame(width: gridWidth/2 - 1, height: gridHeight/2 - 1)
                                        .clipped().contentShape(Rectangle())
                                    }
                                }
                            }
                        } else {
                            // First is landscape: top row wide, bottom row two images
                            VStack(spacing: 2) {
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 0,
                                    aspectRatio: Float(gridWidth / (gridHeight/2 - 1)),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                    forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth, height: gridHeight/2 - 1)
                                .clipped().contentShape(Rectangle())
                                HStack(spacing: 2) {
                                    ForEach(1..<3) { idx in
                                        MediaCell(
                                            parentTweet: parentTweet,
                                            attachmentIndex: idx,
                                            aspectRatio: Float((gridWidth/2 - 1) / (gridHeight/2 - 1)),
                                            
                                            shouldLoadVideo: shouldLoadVideo,
                                            onVideoFinished: onVideoFinished,
                                            videoManager: videoManager,
                                            forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                        )
                                        .environmentObject(MuteState.shared)
                                        .frame(width: gridWidth/2 - 1, height: gridHeight/2 - 1)
                                        .clipped().contentShape(Rectangle())
                                    }
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
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                    forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth/2 - 1, height: gridHeight/2 - 1)
                                .clipped().contentShape(Rectangle())
                            }
                        }
                        HStack(spacing: 2) {
                            ForEach(2..<4) { idx in
                                if idx < attachments.count {
                                    MediaCell(
                                        parentTweet: parentTweet,
                                        attachmentIndex: idx,
                                        
                                        shouldLoadVideo: shouldLoadVideo,
                                        onVideoFinished: onVideoFinished,
                                        videoManager: videoManager,
                                        forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                    )
                                    .environmentObject(MuteState.shared)
                                    .frame(width: gridWidth/2 - 1, height: gridHeight/2 - 1)
                                    .clipped().contentShape(Rectangle())
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
                                    aspectRatio: Float((gridWidth / 2 - 1) / (gridHeight / 2 - 1)),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                    forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                )
                                .environmentObject(MuteState.shared)
                                .frame(width: gridWidth / 2 - 1, height: gridHeight / 2 - 1)
                                .clipped().contentShape(Rectangle())
                            }
                        }
                        HStack(spacing: 2) {
                            ForEach(2..<4) { idx in
                                if idx < attachments.count {
                                    ZStack {
                                        MediaCell(
                                            parentTweet: parentTweet,
                                            attachmentIndex: idx,
                                            aspectRatio: Float((gridWidth / 2 - 1) / (gridHeight / 2 - 1)),
                                            
                                            shouldLoadVideo: shouldLoadVideo,
                                            onVideoFinished: onVideoFinished,
                                            videoManager: videoManager,
                                            forceRefreshTrigger: forceRefreshTrigger,
                        onItemTap: onItemTap
                                        )
                                        .environmentObject(MuteState.shared)
                                        .frame(width: gridWidth / 2 - 1, height: gridHeight / 2 - 1)
                                        .clipped().contentShape(Rectangle())

                                        
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
            .clipped().contentShape(Rectangle())
            .onAppear {
                // Mark the grid as visible
                isVisible = true
                
                // Start video loading timer if this grid contains videos
                let hasVideos = attachments.contains(where: { $0.type.lowercased() == "video" || $0.type.lowercased() == "hls_video" })
                
                if hasVideos {
                    // Balanced delay - enough to let UI settle without feeling slow
                    videoLoadTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                        shouldLoadVideo = true
                        
                        // Setup video playback for any videos in this grid
                        let videoMids = attachments.enumerated().compactMap { index, attachment in
                            if attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video" {
                                return attachment.mid
                            }
                            return nil
                        }
                        
                        if !videoMids.isEmpty {
                            print("DEBUG: [MediaGridView] Grid appeared with \(videoMids.count) videos - setting up playback")
                            // Always stop any existing playback first
                            videoManager.stopSequentialPlayback()
                            // Setup playback starting with the first video in sequence
                            videoManager.setupSequentialPlayback(for: videoMids)
                            // Force refresh all cells to update their play states
                            forceRefreshTrigger += 1
                        }
                    }
                }
            }
            .onDisappear {
                // Mark the grid as not visible
                isVisible = false
                
                videoLoadTimer?.invalidate()
                videoLoadTimer = nil
                shouldLoadVideo = false
                videoManager.stopSequentialPlayback()
            }
            .onAppear {
                // Mark the grid as visible
                isVisible = true
                
                // Setup sequential playback for videos
                let videoMids = attachments.enumerated().compactMap { index, attachment in
                    if attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video" {
                        return attachment.mid
                    }
                    return nil
                }
                
                // Always stop any existing playback first to handle reuse scenarios
                videoManager.stopSequentialPlayback()
                
                if videoMids.count > 1 {
                    videoManager.setupSequentialPlayback(for: videoMids)
                    print("DEBUG: [MediaGridView] Setup sequential playback for \(videoMids.count) videos")
                } else if videoMids.count == 1 {
                    // For single videos, set up the video MID but don't enable sequential playback
                    let wasEmpty = videoManager.videoMids.isEmpty
                    let isNewSequence = videoManager.videoMids != videoMids && !wasEmpty
                    videoManager.videoMids = videoMids
                    videoManager.isSequentialPlaybackEnabled = false
                    videoManager.currentVideoIndex = 0
                    
                    if isNewSequence {
                        print("DEBUG: [MediaGridView] Setup NEW single video playback for \(videoMids[0])")
                        // Reset handled by SimpleVideoPlayer's internal state management
                    } else {
                        print("DEBUG: [MediaGridView] Setup \(wasEmpty ? "FIRST TIME" : "EXISTING") single video playback for \(videoMids[0])")
                    }
                }
            }
            .onChange(of: isVisible) { newVisibility in
                // Handle visibility changes
                if newVisibility {
                    // Grid became visible - start video playback for any videos
                    let videoMids = attachments.enumerated().compactMap { index, attachment in
                        if attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video" {
                            return attachment.mid
                        }
                        return nil
                    }
                    
                    if !videoMids.isEmpty {
                        print("DEBUG: [MediaGridView] Grid became visible with \(videoMids.count) videos - starting playback")
                        // Always stop any existing playback first
                        videoManager.stopSequentialPlayback()
                        // Setup playback starting with the first video in sequence
                        videoManager.setupSequentialPlayback(for: videoMids)
                        // Force refresh all cells to update their play states
                        forceRefreshTrigger += 1
                    }
                } else {
                    // Grid became invisible - stop video playback
                    print("DEBUG: [MediaGridView] Grid became invisible - stopping playback")
                    videoManager.stopSequentialPlayback()
                }
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
                return 1.618 // Square when no aspect ratio is available
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
        
        // Decision algorithm:
        // 1. If all images are portrait (aspect ratio < 1), use square grid with golden ratio layout
        if portraitCount == 3 {
            return 1.0 // Square grid for golden ratio layout
        }
        
        // 2. If all images are landscape (aspect ratio > 1), use square grid with golden ratio layout
        if landscapeCount == 3 {
            return 1.0 // Square grid for golden ratio layout
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
        
        // 4. Default to square layout for better visual balance
        return 1.0 // Square layout
    }
}
