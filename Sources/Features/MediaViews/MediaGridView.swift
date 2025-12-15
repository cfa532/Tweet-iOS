//
//  MediaGridView.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/5/20.
//

import SwiftUI
import AVKit

struct MediaGridView: View, Equatable {
    let parentTweet: Tweet
    let attachments: [MimeiFileType]
    let visibleTweetId: String? // The ID of the visible tweet in feed (for retweets)
    let isEmbedded: Bool // Flag to indicate this is an embedded tweet (prevents video loading)
    let maxImages: Int = 4
    
    // Equatable conformance to help SwiftUI reuse views and prevent unnecessary recomposition
    static func == (lhs: MediaGridView, rhs: MediaGridView) -> Bool {
        return lhs.parentTweet.mid == rhs.parentTweet.mid &&
               lhs.attachments.count == rhs.attachments.count &&
               lhs.attachments.map { $0.mid } == rhs.attachments.map { $0.mid } &&
               lhs.visibleTweetId == rhs.visibleTweetId &&
               lhs.isEmbedded == rhs.isEmbedded
    }
    @State private var shouldLoadVideo = true
    @State private var videoLoadTimer: Timer?
    @State private var isVisible = false
    @State private var hasSetupSequentialPlayback = false // Track if we've already set up sequential playback
    @State private var hasInitialized = false // Track if we've done initial setup
    @StateObject private var videoManager = VideoManager()
    @StateObject private var videoLoadingManager = VideoLoadingManager.shared
    
    // Cache screen-based calculations to avoid repeated UIScreen.main calls
    // Account for TweetListView horizontal padding (16pt on each side = 32pt total)
    private static let cachedScreenWidth: CGFloat = UIScreen.main.bounds.width
    private static let cachedGridWidth: CGFloat = max(10, cachedScreenWidth - 32 - 32) // 32 for original spacing + 32 for TweetListView padding
    private static let cachedEmbeddedGridWidth: CGFloat = max(10, cachedScreenWidth - 140) // Narrower width for embedded/quoted tweets
    
    init(parentTweet: Tweet, attachments: [MimeiFileType], visibleTweetId: String? = nil, isEmbedded: Bool = false) {
        self.parentTweet = parentTweet
        self.attachments = attachments
        self.visibleTweetId = visibleTweetId
        self.isEmbedded = isEmbedded
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
        let shouldStart = isFirstVideo && (attachments[index].type == .video || attachments[index].type == .hls_video)
        
        return shouldStart
    }
    
    private func findFirstVideoIndex() -> Int {
        return attachments.enumerated().first { _, attachment in
            attachment.type == .video || attachment.type == .hls_video
        }?.offset ?? -1
    }
    
    private func shouldPlayVideo(for index: Int) -> Bool {
        guard index < attachments.count else { return false }
        let attachment = attachments[index]
        
        // Check if this is a video
        let isVideo = attachment.type == .video || attachment.type == .hls_video
        guard isVideo else { return false }
        
        // Use VideoManager to determine if this video should play
        let shouldPlay = videoManager.shouldPlayVideo(for: attachment.mid)
        print("DEBUG: [MediaGridView] shouldPlayVideo(\(index)) for \(attachment.mid): shouldPlay=\(shouldPlay)")
        
        return shouldPlay
    }
    
    private func onVideoFinished() {
        print("DEBUG: [MediaGridView] onVideoFinished called for tweet \(parentTweet.mid)")
        videoManager.onVideoFinished(tweetId: parentTweet.mid)
    }
    
    var body: some View {
        // Use cached dimensions to prevent repeated UIScreen.main calls
        let gridAspectRatio = MediaGridViewModel.aspectRatio(for: attachments)
        // Use different width for embedded vs regular tweets
        let actualWidth = isEmbedded ? Self.cachedEmbeddedGridWidth : Self.cachedGridWidth
        let gridHeight = max(10, actualWidth / gridAspectRatio)
        
        // Fixed frame to prevent layout shifts during image loading
        ZStack(alignment: .center) {
                switch attachments.count {
                case 1:
                    MediaCell(
                        parentTweet: parentTweet,
                        attachmentIndex: 0,
                        aspectRatio: Float(gridAspectRatio),
                        shouldLoadVideo: shouldLoadVideo,
                        onVideoFinished: onVideoFinished,
                        videoManager: videoManager,
                        visibleTweetId: visibleTweetId
                    )
                    .frame(width: actualWidth, height: gridHeight, alignment: .center)
                    .clipped()
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
                                    aspectRatio: Float((actualWidth/2 - 1) / gridHeight),
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                    visibleTweetId: visibleTweetId
                                )
                                .frame(width: actualWidth/2 - 1, height: gridHeight)
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
                                    aspectRatio: Float(actualWidth / (gridHeight/2 - 1)),
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                    visibleTweetId: visibleTweetId
                                )
                                .frame(width: actualWidth, height: gridHeight/2 - 1)
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
                                    aspectRatio: Float((actualWidth * 1/3 - 1) / gridHeight),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                    visibleTweetId: visibleTweetId
                                )
                                .frame(width: actualWidth * 1/3 - 1, height: gridHeight)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 1,
                                    aspectRatio: Float((actualWidth * 2/3 - 1) / gridHeight),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                    visibleTweetId: visibleTweetId
                                )
                                .frame(width: actualWidth * 2/3 - 1, height: gridHeight)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                            } else {
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 0,
                                    aspectRatio: Float((actualWidth * 2/3 - 1) / gridHeight),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                        visibleTweetId: visibleTweetId
                                )
                                .frame(width: actualWidth * 2/3 - 1, height: gridHeight)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 1,
                                    aspectRatio: Float((actualWidth * 1/3 - 1) / gridHeight),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                        visibleTweetId: visibleTweetId
                                )
                                .frame(width: actualWidth * 1/3 - 1, height: gridHeight)
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
                                    aspectRatio: Float((actualWidth * 0.618 - 1) / gridHeight),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                        visibleTweetId: visibleTweetId
                                )
                                .frame(width: actualWidth * 0.618 - 1, height: gridHeight)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                                
                                // Right side: remaining 38.2% divided vertically
                                VStack(spacing: 2) {
                                    ForEach(1..<3) { idx in
                                        MediaCell(
                                            parentTweet: parentTweet,
                                            attachmentIndex: idx,
                                            aspectRatio: Float((actualWidth * 0.382 - 1) / (gridHeight/2 - 1)),
                                            
                                            shouldLoadVideo: shouldLoadVideo,
                                            onVideoFinished: onVideoFinished,
                                            videoManager: videoManager,
                                        )
                                                .frame(width: actualWidth * 0.382 - 1, height: gridHeight/2 - 1)
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
                                    aspectRatio: Float(actualWidth / (gridHeight * 0.618 - 1)),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                        visibleTweetId: visibleTweetId
                                )
                                .frame(width: actualWidth, height: gridHeight * 0.618 - 1)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                                
                                // Bottom part: remaining 38.2% divided horizontally
                                HStack(spacing: 2) {
                                    ForEach(1..<3) { idx in
                                        MediaCell(
                                            parentTweet: parentTweet,
                                            attachmentIndex: idx,
                                            aspectRatio: Float((actualWidth/2 - 1) / (gridHeight * 0.382 - 1)),
                                            
                                            shouldLoadVideo: shouldLoadVideo,
                                            onVideoFinished: onVideoFinished,
                                            videoManager: videoManager,
                                        )
                                                .frame(width: actualWidth/2 - 1, height: gridHeight * 0.382 - 1)
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
                                    aspectRatio: Float((actualWidth/2 - 1) / gridHeight),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                        visibleTweetId: visibleTweetId
                                )
                                .frame(width: actualWidth/2 - 1, height: gridHeight)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                                VStack(spacing: 2) {
                                    ForEach(1..<3) { idx in
                                        MediaCell(
                                            parentTweet: parentTweet,
                                            attachmentIndex: idx,
                                            aspectRatio: Float((actualWidth/2 - 1) / (gridHeight/2 - 1)),
                                            
                                            shouldLoadVideo: shouldLoadVideo,
                                            onVideoFinished: onVideoFinished,
                                            videoManager: videoManager,
                                        )
                                                .frame(width: actualWidth/2 - 1, height: gridHeight/2 - 1)
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
                                    aspectRatio: Float(actualWidth / (gridHeight/2 - 1)),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                        visibleTweetId: visibleTweetId
                                )
                                .frame(width: actualWidth, height: gridHeight/2 - 1)
                                .clipped().contentShape(Rectangle())
                                HStack(spacing: 2) {
                                    ForEach(1..<3) { idx in
                                        MediaCell(
                                            parentTweet: parentTweet,
                                            attachmentIndex: idx,
                                            aspectRatio: Float((actualWidth/2 - 1) / (gridHeight/2 - 1)),
                                            
                                            shouldLoadVideo: shouldLoadVideo,
                                            onVideoFinished: onVideoFinished,
                                            videoManager: videoManager,
                                        )
                                                .frame(width: actualWidth/2 - 1, height: gridHeight/2 - 1)
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
                    let _: CGFloat = allPortrait ? 3.0/2.0 : (allLandscape ? 4.0/5.0 : 1.0)
                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            ForEach(0..<2) { idx in
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: idx,
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                        visibleTweetId: visibleTweetId
                                )
                                .frame(width: actualWidth/2 - 1, height: gridHeight/2 - 1)
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
                                        videoManager: videoManager
                                    )
                                        .frame(width: actualWidth/2 - 1, height: gridHeight/2 - 1)
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
                                    aspectRatio: Float((actualWidth / 2 - 1) / (gridHeight / 2 - 1)),
                                    
                                    shouldLoadVideo: shouldLoadVideo,
                                    onVideoFinished: onVideoFinished,
                                    videoManager: videoManager,
                                        visibleTweetId: visibleTweetId
                                )
                                .frame(width: actualWidth / 2 - 1, height: gridHeight / 2 - 1)
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
                                            aspectRatio: Float((actualWidth / 2 - 1) / (gridHeight / 2 - 1)),
                                            
                                            shouldLoadVideo: shouldLoadVideo,
                                            onVideoFinished: onVideoFinished,
                                            videoManager: videoManager,
                                        )
                                                .frame(width: actualWidth / 2 - 1, height: gridHeight / 2 - 1)
                                        .clipped().contentShape(Rectangle())

                                        
                                        if idx == 3 && attachments.count > 4 {
                                            Color.black.opacity(0.4)
                                            Text(String(format: NSLocalizedString("+%d more", comment: "Additional media count"), attachments.count - 4))
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
        .frame(width: actualWidth)
        .aspectRatio(gridAspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8)) // Add rounded corners to media grid
        .contentShape(Rectangle())
        .id("mediagrid_\(parentTweet.mid)") // Stable identity to prevent unnecessary recomposition
        .overlay(alignment: .bottomTrailing) {
            // Show mute button only when there's exactly one video attachment
            if attachments.count == 1,
               let attachment = attachments.first,
               attachment.type == .video || attachment.type == .hls_video {
                MuteButton()
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
            }
        }
        .onAppear {
            // CRITICAL: If already initialized, do NOTHING to prevent recomposition
            // This is the key to smooth scrolling - once a retweet is rendered, it stays rendered
            // No state changes, no checks, no work - just mark as visible
            if hasInitialized {
                isVisible = true
                
                // CRITICAL FIX: Even though initialized, we need to ensure VideoManager state
                // is correct when grid reappears (e.g., after scrolling away and back)
                let videoMids = attachments.enumerated().compactMap { index, attachment in
                    if attachment.type == .video || attachment.type == .hls_video {
                        return attachment.mid
                    }
                    return nil
                }
                
                if videoMids.count >= 1 {
                    // Check if VideoManager needs to be re-initialized for this tweet
                    let needsReinit = videoManager.videoMids != videoMids || videoManager.videoMids.isEmpty
                    if needsReinit {
                        print("DEBUG: [MediaGridView] Re-initializing VideoManager on reappear for tweet \(parentTweet.mid)")
                        videoManager.setupSequentialPlayback(for: videoMids, tweetId: parentTweet.mid)
                    }
                }
                
                return
            }
            
            // Mark as initialized immediately to prevent any future work
            hasInitialized = true
            isVisible = true
            
            // Simulator video playback disabled - uncomment to re-enable
            // #if targetEnvironment(simulator)
            // print("DEBUG: [MediaGridView] Running in simulator - disabling video playback to prevent crashes")
            // shouldLoadVideo = false
            // return
            // #endif
            
            // Setup sequential playback for videos
            let videoMids = attachments.enumerated().compactMap { index, attachment in
                if attachment.type == .video || attachment.type == .hls_video {
                    return attachment.mid
                }
                return nil
            }
            
            // Only stop sequential playback if we're switching to a different video set
            // This preserves state when multiple MediaGrids exist during scrolling
            let isSwitchingVideoSet = videoManager.videoMids != videoMids && !videoManager.videoMids.isEmpty
            if isSwitchingVideoSet {
                videoManager.stopSequentialPlayback()
                hasSetupSequentialPlayback = false // Reset flag when switching
            }
            
            // Setup sequential playback for all videos (1 or more)
            // Single video is just sequential playback with 1 item
            // CRITICAL: Only setup if not already set up for this exact sequence to prevent duplicate calls
            // This prevents recomposition when scrolling up past retweets
            if videoMids.count >= 1 {
                let alreadySetup = videoManager.videoMids == videoMids && videoManager.currentVideoIndex >= 0
                print("DEBUG: [MediaGridView] onAppear for tweet \(parentTweet.mid): videoMids=\(videoMids), alreadySetup=\(alreadySetup), currentIndex=\(videoManager.currentVideoIndex)")
                
                if !alreadySetup && !hasSetupSequentialPlayback {
                    videoManager.setupSequentialPlayback(for: videoMids, tweetId: parentTweet.mid)
                    hasSetupSequentialPlayback = true
                    print("DEBUG: [MediaGridView] ✅ Setup sequential playback for tweet \(parentTweet.mid), currentIndex after setup: \(videoManager.currentVideoIndex)")
                    
                    // If all videos were finished (saved index >= count), restart from beginning
                    if videoManager.currentVideoIndex >= videoMids.count {
                        videoManager.currentVideoIndex = 0
                        videoManager.saveCurrentIndex(for: parentTweet.mid)
                        print("DEBUG: [MediaGridView] Reset currentVideoIndex to 0 (was >= count)")
                    }
                } else if alreadySetup {
                    // Already set up - mark as done to prevent future checks
                    hasSetupSequentialPlayback = true
                    print("DEBUG: [MediaGridView] Already set up for tweet \(parentTweet.mid), currentIndex: \(videoManager.currentVideoIndex)")
                }
            }
            
            // Start media loading if this grid contains videos or audio
            let hasVideos = attachments.contains(where: { $0.type == .video || $0.type == .hls_video })
            let hasAudio = attachments.contains(where: { $0.type == .audio })
            let hasMedia = hasVideos || hasAudio
            
            if hasMedia {
                // Register this tweet as containing media (videos or audio)
                // This is important for tweets with multiple attachments to be tracked
                videoLoadingManager.registerTweetWithVideos(parentTweet.mid)
                
                // Check if this tweet should load media based on VideoLoadingManager
                // For embedded tweets, still check - if VideoLoadingManager says yes (e.g., it's the original
                // of a visible retweet), then allow loading
                // CRITICAL: Only check if shouldLoadVideo is false to avoid unnecessary state checks
                // This prevents recomposition when scrolling up past already-loaded retweets
                if !shouldLoadVideo {
                    let shouldLoad = videoLoadingManager.shouldLoadVideos(for: parentTweet.mid)
                    if shouldLoad {
                        // Allow enabling loading even for embedded tweets if VideoLoadingManager approves
                        // This allows videos in original tweets of visible retweets to load
                        shouldLoadVideo = true
                    }
                }
                // If shouldLoadVideo is already true, don't check or change it
                // This keeps already-loaded videos loaded, preventing layout instability
            }
        }
        .onDisappear {
            // CRITICAL: Only update visibility, don't do any other work
            // This prevents state changes that cause recomposition when scrolling
            // State saving is handled by SimpleVideoPlayer's handleOnDisappear
            isVisible = false
            
            // Save current video index to resume later (only if we have valid state)
            // Do this silently without logging to reduce overhead
            if videoManager.currentVideoIndex >= 0 && !videoManager.videoMids.isEmpty {
                videoManager.saveCurrentIndex(for: parentTweet.mid)
            }
            
            // Don't stop sequential playback state - preserve it so videos resume correctly when scrolling back
            // SimpleVideoPlayer will handle pausing the actual playback when it becomes invisible
        }
        .onChange(of: isVisible) { _, newVisibility in
            // Handle visibility changes
            // Don't stop sequential playback state when visibility changes
            // SimpleVideoPlayer handles pausing/resuming the actual playback based on visibility
        }
        .onReceive(NotificationCenter.default.publisher(for: .cancelVideoLoading)) { notification in
            if let tweetId = notification.userInfo?["tweetId"] as? String,
               tweetId == parentTweet.mid {
                print("DEBUG: [MediaGridView] Received cancel video loading notification for tweet \(tweetId)")
                // Don't cancel loading for a tweet that is currently visible.
                // Fullscreen/login overlays can confuse global visibility/cancellation heuristics.
                guard !isVisible else {
                    print("DEBUG: [MediaGridView] Ignoring cancelVideoLoading for visible tweet \(tweetId)")
                    return
                }
                shouldLoadVideo = false
                // DON'T stop sequential playback here; it breaks resume after overlays.
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerVideoPreloading)) { notification in
            if let tweetId = notification.userInfo?["tweetId"] as? String,
               tweetId == parentTweet.mid {
                print("DEBUG: [MediaGridView] Received video preloading notification for tweet \(tweetId)")
                // Enable video loading for preloading
                shouldLoadVideo = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopAllVideos)) { _ in
            // Handle audio interruptions (calls, alarms, etc.) from AudioSessionManager
            // Fullscreen opening now uses visibility detection instead of this notification
            shouldLoadVideo = false
            // DON'T call videoManager.stopSequentialPlayback() - this clears state
            // Videos will be paused by SimpleVideoPlayer.handleStopAllVideos()
            // And resumed when audio session is restored
        }
        .onReceive(NotificationCenter.default.publisher(for: .overlayCoverageChanged)) { notification in
            guard let isCovered = notification.userInfo?["isCovered"] as? Bool else { return }
            // When overlays dismiss, re-enable loading only for grids that are currently visible.
            // This replaces the old fullscreen "resumeMediaCellVideos" broadcast and keeps resume scoped.
            if !isCovered, isVisible {
                shouldLoadVideo = true
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
        default:
            return 1.0
        }
    }
}
