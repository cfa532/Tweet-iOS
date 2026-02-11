//
//  MediaGridView.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/5/20.
//

@preconcurrency import Foundation
import SwiftUI

private final class ObserverHolder: @unchecked Sendable {
    var observer: NSObjectProtocol?
    init(_ observer: NSObjectProtocol?) { self.observer = observer }
}
import AVKit

struct MediaGridView: View, Equatable {
    let parentTweet: Tweet
    let attachments: [MimeiFileType]
    let isEmbedded: Bool // Flag to indicate this is an embedded tweet (prevents video loading)
    let maxImages: Int = 4
    let cellTweetId: String? // ID of the tweet user is viewing (retweet ID for retweets, nil = use parentTweet.mid)
    
    // Equatable conformance to help SwiftUI reuse views and prevent unnecessary recomposition
    static func == (lhs: MediaGridView, rhs: MediaGridView) -> Bool {
        return lhs.parentTweet.mid == rhs.parentTweet.mid &&
               lhs.attachments.count == rhs.attachments.count &&
               lhs.attachments.map { $0.mid } == rhs.attachments.map { $0.mid } &&
               lhs.isEmbedded == rhs.isEmbedded &&
               lhs.cellTweetId == rhs.cellTweetId
    }
    @State private var shouldLoadVideo: Bool
    @State private var videoLoadTimer: Timer?
    @State private var isVisible = false
    @State private var hasInitialized = false // Track if we've done initial setup
    @StateObject private var videoLoadingManager = VideoLoadingManager.shared
    
    // Cache screen-based calculations to avoid repeated UIScreen.main calls
    // Account for TweetListView horizontal padding (16pt on each side = 32pt total)
    private static let cachedScreenWidth: CGFloat = UIScreen.main.bounds.width
    private static let cachedGridWidth: CGFloat = max(10, cachedScreenWidth - 32 - 32) // 32 for original spacing + 32 for TweetListView padding
    private static let cachedEmbeddedGridWidth: CGFloat = max(10, cachedScreenWidth - 80) // Embedded tweet: wider media for better content display
    
    init(parentTweet: Tweet, attachments: [MimeiFileType], isEmbedded: Bool = false, cellTweetId: String? = nil) {
        self.parentTweet = parentTweet
        self.attachments = attachments
        self.isEmbedded = isEmbedded
        self.cellTweetId = cellTweetId
        self._shouldLoadVideo = State(initialValue: true)
    }
    
    private func isPortrait(_ attachment: MimeiFileType) -> Bool {
        guard let ar = attachment.aspectRatio, ar > 0 else { return false }
        return ar < 1.0
    }
    
    private func isLandscape(_ attachment: MimeiFileType) -> Bool {
        guard let ar = attachment.aspectRatio, ar > 0 else { return false }
        return ar > 1.0
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
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                    .frame(width: actualWidth, height: gridHeight, alignment: .center)
                    .clipped()
                    .contentShape(Rectangle())
                    // identify MediaCell border
                    //  .border(Color.red, width: 1)
                    
                case 2:
                    // Use getAspectRatio to get stable defaults if aspect ratio is nil
                    let ar0 = MediaGridViewModel.getAspectRatio(for: attachments[0])
                    let ar1 = MediaGridViewModel.getAspectRatio(for: attachments[1])
                    let isPortrait0 = ar0 < 1
                    let isPortrait1 = ar1 < 1
                    let isLandscape0 = ar0 > 1
                    let isLandscape1 = ar1 > 1
                    if isPortrait0 && isPortrait1 {
                        // Both portrait: horizontal, aspect 3:2
                        // Divide width proportionally based on each image's aspect ratio
                        // This ensures both images show maximum content without excessive cropping
                        let totalWidth = actualWidth
                        
                        // Calculate ideal widths for each image based on their aspect ratios
                        let idealWidth0 = gridHeight * CGFloat(ar0)
                        let idealWidth1 = gridHeight * CGFloat(ar1)
                        let totalIdealWidth = idealWidth0 + idealWidth1
                        
                        // Calculate proportional widths (subtracting spacing)
                        let proportion0 = idealWidth0 / totalIdealWidth
                        let proportion1 = idealWidth1 / totalIdealWidth
                        let width0 = (totalWidth - 2) * proportion0
                        let width1 = (totalWidth - 2) * proportion1
                        
                        HStack(spacing: 2) {
                            MediaCell(
                                parentTweet: parentTweet,
                                attachmentIndex: 0,
                                aspectRatio: Float(width0 / gridHeight),
                                shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                            .frame(width: width0, height: gridHeight)
                            .clipped().contentShape(Rectangle())
                            .contentShape(Rectangle())
                            
                            MediaCell(
                                parentTweet: parentTweet,
                                attachmentIndex: 1,
                                aspectRatio: Float(width1 / gridHeight),
                                shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                            .frame(width: width1, height: gridHeight)
                            .clipped().contentShape(Rectangle())
                            .contentShape(Rectangle())
                        }
                    } else if isLandscape0 && isLandscape1 {
                        // Both landscape: vertical, aspect 4:5 (0.8)
                        // Divide height proportionally based on each image's aspect ratio
                        // This ensures both images show maximum content without excessive cropping
                        let totalHeight = gridHeight
                        
                        // Calculate ideal heights for each image based on their aspect ratios
                        let idealHeight0 = actualWidth / CGFloat(ar0)
                        let idealHeight1 = actualWidth / CGFloat(ar1)
                        let totalIdealHeight = idealHeight0 + idealHeight1
                        
                        // Calculate proportional heights (subtracting spacing)
                        let proportion0 = idealHeight0 / totalIdealHeight
                        let proportion1 = idealHeight1 / totalIdealHeight
                        let height0 = (totalHeight - 2) * proportion0
                        let height1 = (totalHeight - 2) * proportion1
                        
                        VStack(spacing: 2) {
                            MediaCell(
                                parentTweet: parentTweet,
                                attachmentIndex: 0,
                                aspectRatio: Float(actualWidth / height0),
                                shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                            .frame(width: actualWidth, height: height0)
                            .clipped().contentShape(Rectangle())
                            .contentShape(Rectangle())
                            
                            MediaCell(
                                parentTweet: parentTweet,
                                attachmentIndex: 1,
                                aspectRatio: Float(actualWidth / height1),
                                shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                            .frame(width: actualWidth, height: height1)
                            .clipped().contentShape(Rectangle())
                            .contentShape(Rectangle())
                        }
                    } else {
                        // Mixed: one portrait, one landscape (horizontal layout)
                        // Divide width proportionally based on each image's aspect ratio
                        // This ensures both images show maximum content without excessive cropping
                        let totalWidth = actualWidth
                        
                        // Calculate ideal widths for each image based on their aspect ratios
                        // Both images share the same height (gridHeight)
                        let idealWidth0 = gridHeight * CGFloat(ar0)
                        let idealWidth1 = gridHeight * CGFloat(ar1)
                        let totalIdealWidth = idealWidth0 + idealWidth1
                        
                        // Calculate proportional widths (subtracting spacing)
                        let proportion0 = idealWidth0 / totalIdealWidth
                        let proportion1 = idealWidth1 / totalIdealWidth
                        let width0 = (totalWidth - 2) * proportion0
                        let width1 = (totalWidth - 2) * proportion1
                        
                        HStack(spacing: 2) {
                            MediaCell(
                                parentTweet: parentTweet,
                                attachmentIndex: 0,
                                aspectRatio: Float(width0 / gridHeight),
                                shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                            .frame(width: width0, height: gridHeight)
                            .clipped().contentShape(Rectangle())
                            .contentShape(Rectangle())
                            
                            MediaCell(
                                parentTweet: parentTweet,
                                attachmentIndex: 1,
                                aspectRatio: Float(width1 / gridHeight),
                                shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                            .frame(width: width1, height: gridHeight)
                            .clipped().contentShape(Rectangle())
                            .contentShape(Rectangle())
                        }
                    }
                    
                case 3:
                    // Safety check for array bounds
                    if attachments.count < 3 {
                        EmptyView()
                    } else {
                        
                        // Use getAspectRatio to get stable defaults if aspect ratio is nil
                        let ar0 = MediaGridViewModel.getAspectRatio(for: attachments[0])
                        let ar1 = MediaGridViewModel.getAspectRatio(for: attachments[1])
                        let ar2 = MediaGridViewModel.getAspectRatio(for: attachments[2])
                        let allPortrait = ar0 < 1 && ar1 < 1 && ar2 < 1
                        let allLandscape = ar0 > 1 && ar1 > 1 && ar2 > 1
                        
                        if allPortrait {
                            // All portrait: first (hero) takes full height on left, minimum golden ratio (61.8%)
                            // Right side: two images stacked vertically with heights divided proportionally
                            let heroWidth = actualWidth * 0.618 - 1  // Golden ratio
                            let sideWidth = actualWidth - heroWidth - 2
                            
                            // Calculate proportional heights for right-side images
                            let idealHeight1 = sideWidth / CGFloat(ar1)
                            let idealHeight2 = sideWidth / CGFloat(ar2)
                            let totalIdealHeight = idealHeight1 + idealHeight2
                            let proportion1 = idealHeight1 / totalIdealHeight
                            let proportion2 = idealHeight2 / totalIdealHeight
                            let height1 = (gridHeight - 2) * proportion1
                            let height2 = (gridHeight - 2) * proportion2
                            
                            HStack(spacing: 2) {
                                // Hero image on left
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 0,
                                    aspectRatio: Float(heroWidth / gridHeight),
                                    shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                                .frame(width: heroWidth, height: gridHeight)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                                
                                // Right side: two images stacked with proportional heights
                                VStack(spacing: 2) {
                                    MediaCell(
                                        parentTweet: parentTweet,
                                        attachmentIndex: 1,
                                        aspectRatio: Float(sideWidth / height1),
                                        shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                                    .frame(width: sideWidth, height: height1)
                                    .clipped().contentShape(Rectangle())
                                    .contentShape(Rectangle())
                                    
                                    MediaCell(
                                        parentTweet: parentTweet,
                                        attachmentIndex: 2,
                                        aspectRatio: Float(sideWidth / height2),
                                        shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                                    .frame(width: sideWidth, height: height2)
                                    .clipped().contentShape(Rectangle())
                                    .contentShape(Rectangle())
                                }
                            }
                        } else if allLandscape {
                            // All landscape: first (hero) takes full width on top, minimum golden ratio (61.8%)
                            // Bottom: two images side-by-side with widths divided proportionally
                            let heroHeight = gridHeight * 0.618 - 1  // Golden ratio
                            let bottomHeight = gridHeight - heroHeight - 2
                            
                            // Calculate proportional widths for bottom images
                            let idealWidth1 = bottomHeight * CGFloat(ar1)
                            let idealWidth2 = bottomHeight * CGFloat(ar2)
                            let totalIdealWidth = idealWidth1 + idealWidth2
                            let proportion1 = idealWidth1 / totalIdealWidth
                            let proportion2 = idealWidth2 / totalIdealWidth
                            let width1 = (actualWidth - 2) * proportion1
                            let width2 = (actualWidth - 2) * proportion2
                            
                            VStack(spacing: 2) {
                                // Hero image on top
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 0,
                                    aspectRatio: Float(actualWidth / heroHeight),
                                    shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                                .frame(width: actualWidth, height: heroHeight)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                                
                                // Bottom: two images side-by-side with proportional widths
                                HStack(spacing: 2) {
                                    MediaCell(
                                        parentTweet: parentTweet,
                                        attachmentIndex: 1,
                                        aspectRatio: Float(width1 / bottomHeight),
                                        shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                                    .frame(width: width1, height: bottomHeight)
                                    .clipped().contentShape(Rectangle())
                                    .contentShape(Rectangle())
                                    
                                    MediaCell(
                                        parentTweet: parentTweet,
                                        attachmentIndex: 2,
                                        aspectRatio: Float(width2 / bottomHeight),
                                        shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                                    .frame(width: width2, height: bottomHeight)
                                    .clipped().contentShape(Rectangle())
                                    .contentShape(Rectangle())
                                }
                            }
                        } else if ar0 < 1 {
                            // Mixed: first is portrait (hero on left), others stacked on right
                            // Divide width proportionally, but cap hero at 50% of total area
                            let idealWidth0 = gridHeight * CGFloat(ar0)
                            let idealWidth1 = gridHeight * CGFloat(ar1)
                            let idealWidth2 = gridHeight * CGFloat(ar2)
                            // Right side gets combined ideal width of both images
                            let rightIdealWidth = max(idealWidth1, idealWidth2) // Use max to ensure enough space
                            let totalIdealWidth = idealWidth0 + rightIdealWidth
                            
                            // Calculate proportional width, ensure hero is always >= golden ratio (61.8%)
                            let proportionalLeftWidth = (actualWidth - 2) * (idealWidth0 / totalIdealWidth)
                            let minLeftWidthGoldenRatio = actualWidth * 0.618 - 1
                            let leftWidth = max(proportionalLeftWidth, minLeftWidthGoldenRatio)
                            let rightWidth = actualWidth - leftWidth - 2
                            
                            // Calculate proportional heights for right-side images
                            let idealHeight1 = rightWidth / CGFloat(ar1)
                            let idealHeight2 = rightWidth / CGFloat(ar2)
                            let totalIdealHeight = idealHeight1 + idealHeight2
                            let height1 = (gridHeight - 2) * (idealHeight1 / totalIdealHeight)
                            let height2 = (gridHeight - 2) * (idealHeight2 / totalIdealHeight)
                            
                            HStack(spacing: 2) {
                                // Hero portrait on left
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 0,
                                    aspectRatio: Float(leftWidth / gridHeight),
                                    shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                                .frame(width: leftWidth, height: gridHeight)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                                
                                // Right side: two images stacked with proportional heights
                                VStack(spacing: 2) {
                                    MediaCell(
                                        parentTweet: parentTweet,
                                        attachmentIndex: 1,
                                        aspectRatio: Float(rightWidth / height1),
                                        shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                                    .frame(width: rightWidth, height: height1)
                                    .clipped().contentShape(Rectangle())
                                    .contentShape(Rectangle())
                                    
                                    MediaCell(
                                        parentTweet: parentTweet,
                                        attachmentIndex: 2,
                                        aspectRatio: Float(rightWidth / height2),
                                        shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                                    .frame(width: rightWidth, height: height2)
                                    .clipped().contentShape(Rectangle())
                                    .contentShape(Rectangle())
                                }
                            }
                        } else {
                            // Mixed: first is landscape (hero on top), others side-by-side on bottom
                            // Divide height proportionally, but cap hero at 50% of total area
                            let idealHeight0 = actualWidth / CGFloat(ar0)
                            let idealHeight1 = actualWidth / CGFloat(ar1)
                            let idealHeight2 = actualWidth / CGFloat(ar2)
                            // Bottom gets combined ideal height of both images
                            let bottomIdealHeight = max(idealHeight1, idealHeight2) // Use max to ensure enough space
                            let totalIdealHeight = idealHeight0 + bottomIdealHeight
                            
                            // Calculate proportional height, ensure hero is always >= golden ratio (61.8%)
                            let proportionalTopHeight = (gridHeight - 2) * (idealHeight0 / totalIdealHeight)
                            let minTopHeightGoldenRatio = gridHeight * 0.618 - 1
                            let topHeight = max(proportionalTopHeight, minTopHeightGoldenRatio)
                            let bottomHeight = gridHeight - topHeight - 2
                            
                            // Calculate proportional widths for bottom images
                            let idealWidth1 = bottomHeight * CGFloat(ar1)
                            let idealWidth2 = bottomHeight * CGFloat(ar2)
                            let totalIdealWidth = idealWidth1 + idealWidth2
                            let width1 = (actualWidth - 2) * (idealWidth1 / totalIdealWidth)
                            let width2 = (actualWidth - 2) * (idealWidth2 / totalIdealWidth)
                            
                            VStack(spacing: 2) {
                                // Hero landscape on top
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: 0,
                                    aspectRatio: Float(actualWidth / topHeight),
                                    shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                                .frame(width: actualWidth, height: topHeight)
                                .clipped().contentShape(Rectangle())
                                .contentShape(Rectangle())
                                
                                // Bottom: two images side-by-side with proportional widths
                                HStack(spacing: 2) {
                                    MediaCell(
                                        parentTweet: parentTweet,
                                        attachmentIndex: 1,
                                        aspectRatio: Float(width1 / bottomHeight),
                                        shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                                    .frame(width: width1, height: bottomHeight)
                                    .clipped().contentShape(Rectangle())
                                    .contentShape(Rectangle())
                                    
                                    MediaCell(
                                        parentTweet: parentTweet,
                                        attachmentIndex: 2,
                                        aspectRatio: Float(width2 / bottomHeight),
                                        shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
                    )
                                    .frame(width: width2, height: bottomHeight)
                                    .clipped().contentShape(Rectangle())
                                    .contentShape(Rectangle())
                                }
                            }
                        }
                    }
                    
                case 4:
                    // Calculate aspect ratio for each cell to ensure consistent rendering
                    // This matches Android's MediaGrid algorithm for 4 items
                    let cellAspectRatio = Float((actualWidth / 2 - 1) / (gridHeight / 2 - 1))
                    
                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            ForEach(0..<2) { idx in
                                MediaCell(
                                    parentTweet: parentTweet,
                                    attachmentIndex: idx,
                                    aspectRatio: cellAspectRatio,
                                    shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
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
                                        aspectRatio: cellAspectRatio,
                                        shouldLoadVideo: shouldLoadVideo,
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
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
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
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
                        isEmbedded: isEmbedded,
                        cellTweetId: cellTweetId
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
        .onTapGesture {
            // Empty tap gesture to prevent taps from propagating to parent tweet
            // MediaCell handles its own taps for fullscreen video/image
        }
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
        .overlay(alignment: .bottomLeading) {
            // Show timer for video (bottom left)
            if attachments.count == 1,
               let attachment = attachments.first,
               attachment.type == .video || attachment.type == .hls_video {
                VideoTimerOverlay(videoMid: attachment.mid)
                    .padding(.leading, 12)
                    .padding(.bottom, 12)
                    // Removed repetitive timer overlay log
            } else {
                // Debug: show why timer is not displayed
                Color.clear
                    // Removed repetitive timer log
            }
        }
        .onAppear {
            // CRITICAL: If already initialized, do NOTHING to prevent recomposition
            // This is the key to smooth scrolling - once a retweet is rendered, it stays rendered
            // No state changes, no checks, no work - just mark as visible
            if hasInitialized {
                isVisible = true
                return
            }
            
            // Mark as initialized immediately to prevent any future work
            hasInitialized = true
            isVisible = true
            
            // Start media loading if this grid contains videos or audio
            let hasVideos = attachments.contains(where: { $0.type == .video || $0.type == .hls_video })
            let hasAudio = attachments.contains(where: { $0.type == .audio })
            let hasMedia = hasVideos || hasAudio
            
            if hasMedia {
                // Register this tweet as containing media (videos or audio)
                // This is important for tweets with multiple attachments to be tracked
                // Defer to background to avoid blocking main thread
                Task.detached(priority: .background) {
                    await videoLoadingManager.registerTweetWithVideos(parentTweet.mid)
                }
                
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
            
            // Note: MediaGrid no longer sends play commands directly
            // VideoPlaybackCoordinator handles all playback decisions based on scroll position
        }
        .onDisappear {
            // Update visibility when grid disappears
            // Global VideoPlaybackCoordinator handles video state
            isVisible = false
            
            // Note: MediaGrid no longer sends stop commands directly
            // VideoPlaybackCoordinator handles all playback decisions based on scroll position
        }
        .onChange(of: isVisible) { _, newVisibility in
            // Visibility changes handled by global coordinator
        }
        .onReceive(NotificationCenter.default.publisher(for: .cancelVideoLoading)) { notification in
            if let tweetId = notification.userInfo?["tweetId"] as? String,
               tweetId == parentTweet.mid {
                // Don't cancel loading for a tweet that is currently visible.
                // Fullscreen/login overlays can confuse global visibility/cancellation heuristics.
                guard !isVisible else {
                    return
                }
                shouldLoadVideo = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerVideoPreloading)) { notification in
            if let tweetId = notification.userInfo?["tweetId"] as? String,
               tweetId == parentTweet.mid {
                // Enable video loading for preloading
                shouldLoadVideo = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopAllVideos)) { _ in
            // Handle audio interruptions (calls, alarms, etc.) from AudioSessionManager
            // Fullscreen opening now uses visibility detection instead of this notification
            shouldLoadVideo = false
            // Videos controlled by global coordinator
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
    /// Calculate precise height for MediaGrid given attachments and actual grid width
    /// Use this when you know the exact available width (e.g., from view bounds or constraints)
    static func calculateHeight(for attachments: [MimeiFileType], gridWidth: CGFloat) -> CGFloat {
        guard !attachments.isEmpty else { return 0 }

        let gridAspectRatio = aspectRatio(for: attachments)
        let gridHeight = max(10, gridWidth / gridAspectRatio)

        return gridHeight
    }

    /// Calculate precise height for MediaGrid given attachments and whether it's embedded
    /// This uses screen-width-based estimates - prefer the gridWidth variant when actual width is known
    static func calculateHeight(for attachments: [MimeiFileType], isEmbedded: Bool) -> CGFloat {
        guard !attachments.isEmpty else { return 0 }

        let screenWidth = UIScreen.main.bounds.width
        let gridWidth = isEmbedded
            ? max(10, screenWidth - 124)  // Match TweetBodyUIView embedded: cell(16) + leading(3) + avatar(42) + spacing(4) + embedded(8+4) + embAvatar(40) + embSpacing(8) - wrapper(-4)
            : max(10, screenWidth - 32 - 32)  // Regular width

        return calculateHeight(for: attachments, gridWidth: gridWidth)
    }

    /// Get aspect ratio for an attachment, detecting from cached image if nil
    /// STABILITY: Once aspect ratio is determined, it's cached to prevent layout shifts
    static func getAspectRatio(for attachment: MimeiFileType) -> Float {
        // CRITICAL: Always prefer server-provided aspect ratio to prevent layout shifts
        // Only fall back to detection if absolutely necessary AND only once per attachment
        if let ar = attachment.aspectRatio, ar > 0 {
            return ar
        }
        
        // For images without aspect ratio, use a stable default instead of detecting
        // This prevents layout shifts when images load asynchronously
        // The .fill content mode will handle any aspect ratio differences gracefully
        if attachment.type == .image {
            // Use 1.0 square as default for images without aspect ratio
            return 1.0
        }
        
        // For videos without aspect ratio, default to 16:9 (standard video format)
        if attachment.type == .video || attachment.type == .hls_video {
            return 16.0 / 9.0
        }
        
        // Default square aspect ratio for other media types
        return 1.0
    }
    
    static func aspectRatio(for attachments: [MimeiFileType]) -> CGFloat {
        // Clamp aspect ratios between 0.8 (tallest) and 1.618 (widest, golden ratio)
        // This prevents extreme layouts that are too narrow or too wide
        let minAspectRatio: CGFloat = 0.8
        let maxAspectRatio: CGFloat = 1.618
        
        switch attachments.count {
        case 1:
            let ar = getAspectRatio(for: attachments[0])
            if ar > 0 {
                if ar < 0.9 {
                    return max(minAspectRatio, 0.9) // Portrait aspect ratio
                } else {
                    return min(max(CGFloat(ar), minAspectRatio), maxAspectRatio) // Clamped
                }
            } else {
                return maxAspectRatio // Golden ratio when no aspect ratio is available
            }
        case 2:
            let ar0 = getAspectRatio(for: attachments[0])
            let ar1 = getAspectRatio(for: attachments[1])
            let isPortrait0 = ar0 < 1
            let isPortrait1 = ar1 < 1
            let isLandscape0 = ar0 > 1
            let isLandscape1 = ar1 > 1
            if isPortrait0 && isPortrait1 {
                // Both portrait: horizontal layout
                return min(1.5, maxAspectRatio)  // Clamped to max
            } else if isLandscape0 && isLandscape1 {
                // Both landscape: vertical layout
                return max(0.8, minAspectRatio)  // Clamped to min
            } else {
                // Mixed: one portrait, one landscape
                // Calculate and clamp dynamic aspect ratio
                let totalIdealWidth = ar0 + ar1
                return min(max(CGFloat(totalIdealWidth), minAspectRatio), maxAspectRatio)
            }
        case 4:
            // Get aspect ratios - detect from cached images if nil
            let ar0 = getAspectRatio(for: attachments[0])
            let ar1 = getAspectRatio(for: attachments[1])
            let ar2 = getAspectRatio(for: attachments[2])
            let ar3 = getAspectRatio(for: attachments[3])
            
            // Check orientation: portrait < 1.0, landscape > 1.0
            let allPortrait = ar0 < 1.0 && ar1 < 1.0 && ar2 < 1.0 && ar3 < 1.0
            let allLandscape = ar0 > 1.0 && ar1 > 1.0 && ar2 > 1.0 && ar3 > 1.0
            
            if allLandscape {
                return min(maxAspectRatio, 1.618)  // Clamped
            } else if allPortrait {
                return max(minAspectRatio, 0.8)  // Clamped
            } else {
                return 1.0  // Square for mixed orientations
            }
        default:
            // For 5+ attachments, only show first 4 in grid
            // Use first 4 to determine grid aspect ratio (matches Android behavior)
            guard attachments.count >= 4 else {
                // Case 3 - handled by MediaGridView body separately
                return 1.0
            }
            
            // Get aspect ratios of first 4 items
            let ar0 = getAspectRatio(for: attachments[0])
            let ar1 = getAspectRatio(for: attachments[1])
            let ar2 = getAspectRatio(for: attachments[2])
            let ar3 = getAspectRatio(for: attachments[3])
            
            // Check orientation of first 4: portrait < 1.0, landscape > 1.0
            let allPortrait = ar0 < 1.0 && ar1 < 1.0 && ar2 < 1.0 && ar3 < 1.0
            let allLandscape = ar0 > 1.0 && ar1 > 1.0 && ar2 > 1.0 && ar3 > 1.0
            
            if allLandscape {
                return min(maxAspectRatio, 1.618)  // Clamped golden ratio for all landscape
            } else if allPortrait {
                return max(minAspectRatio, 0.8)  // Clamped tall for all portrait
            } else {
                return 1.0  // Square for mixed orientations
            }
        }
    }
}
