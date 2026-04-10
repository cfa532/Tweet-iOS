//
//  CommentsVideoPlaybackCoordinator.swift
//  Tweet
//
//  Coordinates video playback for comments in TweetDetailView
//  Tracks visible comments and autoplays the topmost visible video
//

import Foundation
import SwiftUI
import Combine

/// Tracks video information within a comment
struct CommentVideoInfo: Equatable, Hashable {
    let commentId: String
    let videoMid: String
    let attachmentIndex: Int

    var identifier: String {
        "\(commentId)_\(videoMid)_\(attachmentIndex)"
    }
}

/// Coordinates video playback for comments in TweetDetailView
/// Only one video plays at a time - the topmost visible video
/// Comment videos only play when the main tweet's video attachment is scrolled out of view
@MainActor
class CommentsVideoPlaybackCoordinator: ObservableObject {

    // MARK: - Published State

    /// Currently playing video identifier
    @Published private(set) var currentlyPlayingVideoId: String?

    // MARK: - Video List for Fullscreen Navigation

    /// Ordered list of all video attachments across comments (for fullscreen swipe-between-videos)
    private(set) var allVideos: [VideoPlaybackInfo] = []

    // MARK: - Private State

    /// Visible comments with their video info and visibility ratios
    /// Key: commentId, Value: (videoInfo, visibilityRatio, yPosition)
    private var visibleCommentVideos: [String: (info: CommentVideoInfo, ratio: CGFloat, yPosition: CGFloat)] = [:]

    /// Debounce timer for visibility updates
    private var visibilityDebounceTimer: Timer?
    private let debounceInterval: TimeInterval = 0.15

    /// Minimum visibility ratio required to play a video (50%)
    private let minimumVisibilityRatio: CGFloat = 0.50

    /// Track if coordinator is active
    private var isActive: Bool = false

    /// Track if the main tweet's video attachment is visible
    /// When true, comment videos should NOT autoplay
    /// Kept for backward compatibility but unified tracking now uses visibleCommentVideos
    private var isMainTweetVideoVisible: Bool = false

    // MARK: - Lifecycle

    init() {
        print("📹 [CommentsVideoCoordinator] Initialized")
    }

    deinit {
        visibilityDebounceTimer?.invalidate()
        print("📹 [CommentsVideoCoordinator] Deinitialized")
    }

    // MARK: - Public API

    /// Activate the coordinator (call when TweetDetailView appears)
    /// - Parameter hasMainVideo: Whether the main tweet has a video attachment (unused — kept for call-site compat)
    func activate(hasMainVideo: Bool = false) {
        isActive = true
        isMainTweetVideoVisible = false
        print("📹 [CommentsVideoCoordinator] Activated")
    }

    /// Deactivate the coordinator (call when TweetDetailView disappears)
    func deactivate() {
        isActive = false
        // Don't send pause notification - comment videos will naturally stop when their views disappear
        // This avoids any potential interference with feed videos when returning to the tweet list
        currentlyPlayingVideoId = nil
        visibleCommentVideos.removeAll()
        allVideos.removeAll()
        isMainTweetVideoVisible = false
        visibilityDebounceTimer?.invalidate()
        visibilityDebounceTimer = nil
        print("📹 [CommentsVideoCoordinator] Deactivated")
    }

    /// Build the ordered video list from all comments (for fullscreen navigation)
    /// Call whenever the comments array changes (initial load, pagination, new comment)
    func buildVideoList(from comments: [Tweet]) {
        var videos: [VideoPlaybackInfo] = []
        for comment in comments {
            guard let attachments = comment.attachments else { continue }
            for (index, attachment) in attachments.enumerated() {
                if attachment.type == .video || attachment.type == .hls_video {
                    videos.append(VideoPlaybackInfo(
                        cellTweetId: comment.mid,
                        mediaTweetId: comment.mid,
                        videoMid: attachment.mid,
                        attachmentIndex: index
                    ))
                }
            }
        }
        allVideos = videos
    }

    /// Returns the ordered video list for fullscreen navigation
    func getVideoListForFullscreen() -> [VideoPlaybackInfo] {
        return allVideos
    }

    /// Report that a comment video has become visible
    /// - Parameters:
    ///   - commentId: The comment's ID
    ///   - videoMid: The video attachment's mid
    ///   - attachmentIndex: Index of the video attachment
    ///   - visibilityRatio: How much of the video is visible (0.0 - 1.0)
    ///   - yPosition: The Y position of the video in the scroll coordinate space
    func reportVideoVisible(
        commentId: String,
        videoMid: String,
        attachmentIndex: Int,
        visibilityRatio: CGFloat,
        yPosition: CGFloat
    ) {
        guard isActive else { return }

        let info = CommentVideoInfo(
            commentId: commentId,
            videoMid: videoMid,
            attachmentIndex: attachmentIndex
        )

        visibleCommentVideos[commentId] = (info: info, ratio: visibilityRatio, yPosition: yPosition)

        scheduleVisibilityUpdate()
    }

    /// Report that a comment video is no longer visible
    func reportVideoNotVisible(commentId: String) {
        guard isActive else { return }

        visibleCommentVideos.removeValue(forKey: commentId)

        scheduleVisibilityUpdate()
    }

    /// Report the visibility of the main tweet's video attachment
    /// When the main tweet video is visible, comment videos should NOT autoplay
    /// - Parameter isVisible: Whether the main tweet video is visible on screen
    /// Deprecated: use reportAttachmentVideoVisible/NotVisible instead for unified tracking
    func reportMainTweetVideoVisibility(isVisible: Bool) {
        guard isActive else { return }

        let wasVisible = isMainTweetVideoVisible
        isMainTweetVideoVisible = isVisible

        if wasVisible && !isVisible {
            print("📹 [CommentsVideoCoordinator] Main tweet video scrolled out - enabling comment autoplay")
            scheduleVisibilityUpdate()
        } else if !wasVisible && isVisible {
            print("📹 [CommentsVideoCoordinator] Main tweet video visible - pausing comment videos")
            stopCurrentVideo()
        }
    }

    /// Report that a main tweet attachment video became visible (unified tracking)
    func reportAttachmentVideoVisible(
        attachmentIndex: Int,
        videoMid: String,
        visibilityRatio: CGFloat,
        yPosition: CGFloat
    ) {
        guard isActive else { return }
        // Synthetic commentId must not contain underscores — stopCurrentVideo() splits on "_"
        // and expects commentId_videoMid_attachmentIndex format (videoMid at index 1).
        let syntheticId = "att\(attachmentIndex)"
        let info = CommentVideoInfo(commentId: syntheticId, videoMid: videoMid, attachmentIndex: attachmentIndex)
        visibleCommentVideos[syntheticId] = (info: info, ratio: visibilityRatio, yPosition: yPosition)
        scheduleVisibilityUpdate()
    }

    /// Report that a main tweet attachment video is no longer visible
    func reportAttachmentVideoNotVisible(attachmentIndex: Int) {
        guard isActive else { return }
        visibleCommentVideos.removeValue(forKey: "att\(attachmentIndex)")
        scheduleVisibilityUpdate()
    }

    // MARK: - Private Methods

    private func scheduleVisibilityUpdate() {
        visibilityDebounceTimer?.invalidate()
        visibilityDebounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.processVisibilityUpdate()
            }
        }
    }

    private func processVisibilityUpdate() {
        guard isActive else { return }

        // Find the topmost visible video with sufficient visibility
        // Attachment videos and comment videos compete on equal footing — topmost visible wins
        let eligibleVideos = visibleCommentVideos.values
            .filter { $0.ratio >= minimumVisibilityRatio }
            .sorted { $0.yPosition < $1.yPosition } // Sort by Y position (topmost first)

        guard let topVideo = eligibleVideos.first else {
            // No eligible videos visible - stop current playback
            stopCurrentVideo()
            return
        }

        let videoId = topVideo.info.identifier

        // If the same video is already playing, do nothing
        if currentlyPlayingVideoId == videoId {
            return
        }

        // Stop current video and start the new one
        stopCurrentVideo()
        startVideo(topVideo.info)
    }

    private func startVideo(_ videoInfo: CommentVideoInfo) {
        currentlyPlayingVideoId = videoInfo.identifier

        print("▶️ [CommentsVideoCoordinator] Playing video: \(videoInfo.videoMid) in comment \(videoInfo.commentId)")

        // Send play notification to the specific video
        // Uses the same notification name as VideoPlaybackCoordinator
        NotificationCenter.default.post(
            name: Notification.Name("shouldPlayVideo"),
            object: nil,
            userInfo: [
                "videoMid": videoInfo.videoMid,
                "videoId": videoInfo.identifier,
                "source": "commentsCoordinator"
            ]
        )
    }

    private func stopCurrentVideo() {
        guard let currentVideoId = currentlyPlayingVideoId else { return }

        // Extract videoMid from the identifier
        let components = currentVideoId.split(separator: "_")
        guard components.count >= 2 else { return }

        let videoMid = String(components[1])

        print("⏹️ [CommentsVideoCoordinator] Stopping video: \(videoMid)")

        // Send pause notification
        // Uses the same notification name as VideoPlaybackCoordinator
        NotificationCenter.default.post(
            name: Notification.Name("shouldPauseVideo"),
            object: nil,
            userInfo: [
                "videoMid": videoMid,
                "source": "commentsCoordinator"
            ]
        )

        currentlyPlayingVideoId = nil
    }
}

// MARK: - View Modifier for Comment Video Visibility Tracking

/// A view modifier that tracks video visibility within a comment
@available(iOS 16.0, *)
struct CommentVideoVisibilityTracker: ViewModifier {
    let commentId: String
    let videoMid: String
    let attachmentIndex: Int
    let coordinator: CommentsVideoPlaybackCoordinator
    let scrollCoordinateSpace: String

    @State private var isInViewport = false

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            updateVisibility(geometry: geometry)
                        }
                        .onChange(of: geometry.frame(in: .named(scrollCoordinateSpace))) { _, _ in
                            updateVisibility(geometry: geometry)
                        }
                }
            )
            .onDisappear {
                coordinator.reportVideoNotVisible(commentId: commentId)
            }
    }

    private func updateVisibility(geometry: GeometryProxy) {
        let frame = geometry.frame(in: .named(scrollCoordinateSpace))
        let screenBounds = UIScreen.main.bounds

        // Calculate how much of the video is visible
        let visibleTop = max(frame.minY, 0)
        let visibleBottom = min(frame.maxY, screenBounds.height)
        let visibleHeight = max(0, visibleBottom - visibleTop)
        let totalHeight = frame.height

        let visibilityRatio = totalHeight > 0 ? visibleHeight / totalHeight : 0

        if visibilityRatio > 0 {
            coordinator.reportVideoVisible(
                commentId: commentId,
                videoMid: videoMid,
                attachmentIndex: attachmentIndex,
                visibilityRatio: visibilityRatio,
                yPosition: frame.minY
            )
        } else {
            coordinator.reportVideoNotVisible(commentId: commentId)
        }
    }
}

@available(iOS 16.0, *)
extension View {
    /// Track video visibility for comments video playback coordination
    func trackCommentVideoVisibility(
        commentId: String,
        videoMid: String,
        attachmentIndex: Int,
        coordinator: CommentsVideoPlaybackCoordinator,
        scrollCoordinateSpace: String
    ) -> some View {
        self.modifier(CommentVideoVisibilityTracker(
            commentId: commentId,
            videoMid: videoMid,
            attachmentIndex: attachmentIndex,
            coordinator: coordinator,
            scrollCoordinateSpace: scrollCoordinateSpace
        ))
    }

    /// Track video visibility for main tweet attachment video playback coordination
    func trackAttachmentVideoVisibility(
        attachmentIndex: Int,
        videoMid: String,
        coordinator: CommentsVideoPlaybackCoordinator,
        scrollCoordinateSpace: String
    ) -> some View {
        self.modifier(AttachmentVideoVisibilityTracker(
            attachmentIndex: attachmentIndex,
            videoMid: videoMid,
            coordinator: coordinator,
            scrollCoordinateSpace: scrollCoordinateSpace
        ))
    }
}

// MARK: - View Modifier for Attachment Video Visibility Tracking

/// Tracks visibility of a main tweet attachment video in TweetDetailView's scroll space
@available(iOS 16.0, *)
struct AttachmentVideoVisibilityTracker: ViewModifier {
    let attachmentIndex: Int
    let videoMid: String
    let coordinator: CommentsVideoPlaybackCoordinator
    let scrollCoordinateSpace: String

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            updateVisibility(geometry: geometry)
                        }
                        .onChange(of: geometry.frame(in: .named(scrollCoordinateSpace))) { _, _ in
                            updateVisibility(geometry: geometry)
                        }
                }
            )
            .onDisappear {
                coordinator.reportAttachmentVideoNotVisible(attachmentIndex: attachmentIndex)
                print("📹 [AttachmentTracker] Disappeared: idx=\(attachmentIndex)")
            }
    }

    private func updateVisibility(geometry: GeometryProxy) {
        let frame = geometry.frame(in: .named(scrollCoordinateSpace))
        let screenHeight = UIScreen.main.bounds.height
        let visibleTop = max(frame.minY, 0)
        let visibleBottom = min(frame.maxY, screenHeight)
        let visibleHeight = max(0, visibleBottom - visibleTop)
        let ratio = frame.height > 0 ? visibleHeight / frame.height : 0

        if ratio > 0 {
            coordinator.reportAttachmentVideoVisible(
                attachmentIndex: attachmentIndex,
                videoMid: videoMid,
                visibilityRatio: ratio,
                yPosition: frame.minY
            )
        } else {
            coordinator.reportAttachmentVideoNotVisible(attachmentIndex: attachmentIndex)
        }
    }
}
