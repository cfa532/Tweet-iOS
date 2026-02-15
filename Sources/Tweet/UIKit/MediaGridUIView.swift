//
//  MediaGridUIView.swift
//  Tweet
//
//  Pure UIKit media grid replacing SwiftUI MediaGridView in the feed.
//  Uses frame-based layout for synchronous, deterministic sizing.
//  Reuses MediaGridViewModel for aspect ratio and height calculations.
//
import UIKit
import Combine

class MediaGridUIView: UIView {

    // MARK: - State

    private var cellViews: [MediaCellUIView] = []
    private var moreLabel: UILabel?  // "+N more" overlay
    private var moreLabelOverlay: UIView?

    private var currentTweetId: String?
    private weak var parentTweet: Tweet?
    private var attachments: [MimeiFileType] = []
    private var isEmbedded: Bool = false
    private var cellTweetId: String?
    private var shouldLoadVideo: Bool = true
    private weak var parentViewController: UIViewController?

    /// Per-feed video coordinator (set by TweetBodyUIView)
    weak var videoCoordinator: VideoPlaybackCoordinator?

    private var hasInitialized: Bool = false
    private var cancellables = Set<AnyCancellable>()

    // Track whether layout needs recalculation
    private var needsFrameRecalculation: Bool = false
    private var lastLayoutWidth: CGFloat = 0

    var isGridVisible: Bool = false {
        didSet {
            guard isGridVisible != oldValue else { return }
            if isGridVisible {
                handleBecameVisible()
            } else {
                handleBecameInvisible()
            }
            // NOTE: Removed automatic forwarding to cells - each cell now detects
            // its own visibility via didMoveToWindow() and layoutSubviews()
            // This prevents all cells from being marked visible simultaneously,
            // which was causing async task cancellation for non-primary videos.
        }
    }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerRadius = 8
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configure

    func configure(
        tweet: Tweet,
        attachments: [MimeiFileType],
        isEmbedded: Bool,
        cellTweetId: String?,
        shouldLoadVideo: Bool,
        parentViewController: UIViewController
    ) {
        // Skip if same tweet
        if currentTweetId == tweet.mid { return }
        currentTweetId = tweet.mid
        self.parentTweet = tweet
        self.attachments = attachments
        self.isEmbedded = isEmbedded
        self.cellTweetId = cellTweetId
        self.shouldLoadVideo = shouldLoadVideo
        self.parentViewController = parentViewController
        hasInitialized = false

        // Remove old cells
        clearCells()

        guard !attachments.isEmpty else { return }

        // Create cells (max 4 shown) - frames will be set in layoutSubviews()
        let displayCount = min(attachments.count, 4)

        for i in 0..<displayCount {
            let cellView = MediaCellUIView()
            cellView.videoCoordinator = videoCoordinator
            // Frame will be set in layoutSubviews when actual width is known
            cellView.frame = .zero

            // Aspect ratio will be updated in layoutSubviews with correct dimensions
            cellView.configure(
                parentTweet: tweet,
                attachmentIndex: i,
                aspectRatio: 1.0,  // Placeholder, will be updated in layoutSubviews
                shouldLoadVideo: shouldLoadVideo,
                isEmbedded: isEmbedded,
                cellTweetId: cellTweetId,
                isSingleMedia: attachments.count == 1,
                parentViewController: parentViewController
            )

            addSubview(cellView)
            cellViews.append(cellView)
        }

        // Mark that we need to calculate frames in layoutSubviews
        needsFrameRecalculation = true
        setNeedsLayout()

        // Empty tap gesture to prevent propagation to parent tweet
        if gestureRecognizers?.isEmpty ?? true {
            let tap = UITapGestureRecognizer(target: self, action: #selector(gridTapped))
            addGestureRecognizer(tap)
        }
    }

    @objc private func gridTapped() {
        // Consume tap to prevent propagation
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // Only recalculate if width changed or if we haven't laid out yet
        guard bounds.width > 0 &&
              (needsFrameRecalculation || bounds.width != lastLayoutWidth) else {
            return
        }

        lastLayoutWidth = bounds.width
        needsFrameRecalculation = false

        // Calculate frames using actual container width
        guard let parentTweet,
              !attachments.isEmpty,
              !cellViews.isEmpty else { return }

        let gridWidth = bounds.width
        let gridAspectRatio = MediaGridViewModel.aspectRatio(for: attachments)
        let gridHeight = max(10, gridWidth / gridAspectRatio)

        let frames = calculateCellFrames(
            attachments: attachments,
            gridWidth: gridWidth,
            gridHeight: gridHeight
        )

        // Update cell frames and aspect ratios
        for (i, cellView) in cellViews.enumerated() where i < frames.count {
            cellView.frame = frames[i]

            // Update aspect ratio based on actual frame
            let cellAspectRatio = Float(frames[i].width / max(1, frames[i].height))
            if let parentVC = parentViewController {
                cellView.configure(
                    parentTweet: parentTweet,
                    attachmentIndex: i,
                    aspectRatio: cellAspectRatio,
                    shouldLoadVideo: shouldLoadVideo,
                    isEmbedded: isEmbedded,
                    cellTweetId: cellTweetId,
                    isSingleMedia: attachments.count == 1,
                    parentViewController: parentVC
                )
            }
        }

        // Update "+N more" overlay position if present
        if attachments.count > 4, frames.count >= 4 {
            moreLabelOverlay?.frame = frames[3]
            moreLabel?.frame = moreLabelOverlay?.bounds ?? .zero
        }
    }

    // MARK: - Frame Calculations

    /// Calculate frames for each cell, matching SwiftUI MediaGridView layout exactly
    private func calculateCellFrames(
        attachments: [MimeiFileType],
        gridWidth: CGFloat,
        gridHeight: CGFloat
    ) -> [CGRect] {
        let spacing: CGFloat = 1

        switch attachments.count {
        case 1:
            return [CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight)]

        case 2:
            return calculateTwoCellFrames(
                attachments: attachments,
                gridWidth: gridWidth,
                gridHeight: gridHeight,
                spacing: spacing
            )

        case 3:
            return calculateThreeCellFrames(
                attachments: attachments,
                gridWidth: gridWidth,
                gridHeight: gridHeight,
                spacing: spacing
            )

        default: // 4+
            return calculateFourCellFrames(
                gridWidth: gridWidth,
                gridHeight: gridHeight,
                spacing: spacing
            )
        }
    }

    private func calculateTwoCellFrames(
        attachments: [MimeiFileType],
        gridWidth: CGFloat,
        gridHeight: CGFloat,
        spacing: CGFloat
    ) -> [CGRect] {
        let ar0 = MediaGridViewModel.getAspectRatio(for: attachments[0])
        let ar1 = MediaGridViewModel.getAspectRatio(for: attachments[1])
        let isLandscape0 = ar0 > 1
        let isLandscape1 = ar1 > 1

        if isLandscape0 && isLandscape1 {
            // Both landscape: vertical stack
            let idealHeight0 = gridWidth / CGFloat(ar0)
            let idealHeight1 = gridWidth / CGFloat(ar1)
            let totalIdealHeight = idealHeight0 + idealHeight1
            let height0 = (gridHeight - spacing) * (idealHeight0 / totalIdealHeight)
            let height1 = (gridHeight - spacing) * (idealHeight1 / totalIdealHeight)

            return [
                CGRect(x: 0, y: 0, width: gridWidth, height: height0),
                CGRect(x: 0, y: height0 + spacing, width: gridWidth, height: height1)
            ]
        } else {
            // Both portrait, mixed, or same: horizontal side-by-side
            let idealWidth0 = gridHeight * CGFloat(ar0)
            let idealWidth1 = gridHeight * CGFloat(ar1)
            let totalIdealWidth = idealWidth0 + idealWidth1
            let width0 = (gridWidth - spacing) * (idealWidth0 / totalIdealWidth)
            let width1 = (gridWidth - spacing) * (idealWidth1 / totalIdealWidth)

            return [
                CGRect(x: 0, y: 0, width: width0, height: gridHeight),
                CGRect(x: width0 + spacing, y: 0, width: width1, height: gridHeight)
            ]
        }
    }

    private func calculateThreeCellFrames(
        attachments: [MimeiFileType],
        gridWidth: CGFloat,
        gridHeight: CGFloat,
        spacing: CGFloat
    ) -> [CGRect] {
        let ar0 = MediaGridViewModel.getAspectRatio(for: attachments[0])
        let ar1 = MediaGridViewModel.getAspectRatio(for: attachments[1])
        let ar2 = MediaGridViewModel.getAspectRatio(for: attachments[2])
        let allPortrait = ar0 < 1 && ar1 < 1 && ar2 < 1
        let allLandscape = ar0 > 1 && ar1 > 1 && ar2 > 1

        if allPortrait {
            // Hero left (golden ratio), two stacked right
            let heroWidth = gridWidth * 0.618 - 1
            let sideWidth = gridWidth - heroWidth - spacing

            let idealHeight1 = sideWidth / CGFloat(ar1)
            let idealHeight2 = sideWidth / CGFloat(ar2)
            let totalIdealHeight = idealHeight1 + idealHeight2
            let height1 = (gridHeight - spacing) * (idealHeight1 / totalIdealHeight)
            let height2 = (gridHeight - spacing) * (idealHeight2 / totalIdealHeight)

            return [
                CGRect(x: 0, y: 0, width: heroWidth, height: gridHeight),
                CGRect(x: heroWidth + spacing, y: 0, width: sideWidth, height: height1),
                CGRect(x: heroWidth + spacing, y: height1 + spacing, width: sideWidth, height: height2)
            ]
        } else if allLandscape {
            // Hero top (golden ratio), two side-by-side bottom
            let heroHeight = gridHeight * 0.618 - 1
            let bottomHeight = gridHeight - heroHeight - spacing

            let idealWidth1 = bottomHeight * CGFloat(ar1)
            let idealWidth2 = bottomHeight * CGFloat(ar2)
            let totalIdealWidth = idealWidth1 + idealWidth2
            let width1 = (gridWidth - spacing) * (idealWidth1 / totalIdealWidth)
            let width2 = (gridWidth - spacing) * (idealWidth2 / totalIdealWidth)

            return [
                CGRect(x: 0, y: 0, width: gridWidth, height: heroHeight),
                CGRect(x: 0, y: heroHeight + spacing, width: width1, height: bottomHeight),
                CGRect(x: width1 + spacing, y: heroHeight + spacing, width: width2, height: bottomHeight)
            ]
        } else if ar0 < 1 {
            // Mixed: first is portrait (hero on left)
            let idealWidth0 = gridHeight * CGFloat(ar0)
            let idealWidth1 = gridHeight * CGFloat(ar1)
            let idealWidth2 = gridHeight * CGFloat(ar2)
            let rightIdealWidth = max(idealWidth1, idealWidth2)
            let totalIdealWidth = idealWidth0 + rightIdealWidth
            let proportionalLeftWidth = (gridWidth - spacing) * (idealWidth0 / totalIdealWidth)
            let minLeftWidthGoldenRatio = gridWidth * 0.618 - 1
            let leftWidth = max(proportionalLeftWidth, minLeftWidthGoldenRatio)
            let rightWidth = gridWidth - leftWidth - spacing

            let idealHeight1 = rightWidth / CGFloat(ar1)
            let idealHeight2 = rightWidth / CGFloat(ar2)
            let totalIdealHeight = idealHeight1 + idealHeight2
            let height1 = (gridHeight - spacing) * (idealHeight1 / totalIdealHeight)
            let height2 = (gridHeight - spacing) * (idealHeight2 / totalIdealHeight)

            return [
                CGRect(x: 0, y: 0, width: leftWidth, height: gridHeight),
                CGRect(x: leftWidth + spacing, y: 0, width: rightWidth, height: height1),
                CGRect(x: leftWidth + spacing, y: height1 + spacing, width: rightWidth, height: height2)
            ]
        } else {
            // Mixed: first is landscape (hero on top)
            let idealHeight0 = gridWidth / CGFloat(ar0)
            let idealHeight1 = gridWidth / CGFloat(ar1)
            let idealHeight2 = gridWidth / CGFloat(ar2)
            let bottomIdealHeight = max(idealHeight1, idealHeight2)
            let totalIdealHeight = idealHeight0 + bottomIdealHeight
            let proportionalTopHeight = (gridHeight - spacing) * (idealHeight0 / totalIdealHeight)
            let minTopHeightGoldenRatio = gridHeight * 0.618 - 1
            let topHeight = max(proportionalTopHeight, minTopHeightGoldenRatio)
            let bottomHeight = gridHeight - topHeight - spacing

            let idealWidth1 = bottomHeight * CGFloat(ar1)
            let idealWidth2 = bottomHeight * CGFloat(ar2)
            let totalIdealWidth = idealWidth1 + idealWidth2
            let width1 = (gridWidth - spacing) * (idealWidth1 / totalIdealWidth)
            let width2 = (gridWidth - spacing) * (idealWidth2 / totalIdealWidth)

            return [
                CGRect(x: 0, y: 0, width: gridWidth, height: topHeight),
                CGRect(x: 0, y: topHeight + spacing, width: width1, height: bottomHeight),
                CGRect(x: width1 + spacing, y: topHeight + spacing, width: width2, height: bottomHeight)
            ]
        }
    }

    private func calculateFourCellFrames(
        gridWidth: CGFloat,
        gridHeight: CGFloat,
        spacing: CGFloat
    ) -> [CGRect] {
        let cellW = (gridWidth - spacing) / 2
        let cellH = (gridHeight - spacing) / 2

        return [
            CGRect(x: 0, y: 0, width: cellW, height: cellH),
            CGRect(x: cellW + spacing, y: 0, width: cellW, height: cellH),
            CGRect(x: 0, y: cellH + spacing, width: cellW, height: cellH),
            CGRect(x: cellW + spacing, y: cellH + spacing, width: cellW, height: cellH)
        ]
    }

    // MARK: - "+N more" Overlay

    private func addMoreOverlay(count: Int, frame: CGRect) {
        let overlay = UIView(frame: frame)
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        let label = UILabel()
        label.text = String(format: NSLocalizedString("+%d more", comment: "Additional media count"), count)
        label.textColor = .white
        label.font = .systemFont(ofSize: 24, weight: .bold)
        label.textAlignment = .center
        label.frame = overlay.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.addSubview(label)

        addSubview(overlay)
        moreLabel = label
        moreLabelOverlay = overlay
    }

    // MARK: - Visibility Management

    private func handleBecameVisible() {
        guard let parentTweet else { return }

        if hasInitialized { return }
        hasInitialized = true

        // Register tweet with video loading manager
        let hasVideos = attachments.contains { $0.type == .video || $0.type == .hls_video }
        let hasAudio = attachments.contains { $0.type == .audio }

        if hasVideos || hasAudio {
            Task.detached(priority: .background) {
                await VideoLoadingManager.shared.registerTweetWithVideos(parentTweet.mid)
            }

            if !shouldLoadVideo {
                let shouldLoad = VideoLoadingManager.shared.shouldLoadVideos(for: parentTweet.mid)
                if shouldLoad {
                    shouldLoadVideo = true
                }
            }
        }
    }

    private func handleBecameInvisible() {
        // Managed by individual cell visibility
    }

    // MARK: - Cleanup

    private func clearCells() {
        for cell in cellViews {
            cell.prepareForReuse()
            cell.removeFromSuperview()
        }
        cellViews.removeAll()
        moreLabelOverlay?.removeFromSuperview()
        moreLabelOverlay = nil
        moreLabel = nil
    }

    func refreshVideoLayersAfterForeground() {
        for cell in cellViews {
            cell.refreshVideoLayerAfterForeground()
        }
    }

    func showVideoThumbnailsForBackground() {
        for cell in cellViews {
            cell.showThumbnailForBackground()
        }
    }

    func prepareForReuse() {
        clearCells()
        cancellables.removeAll()
        currentTweetId = nil
        parentTweet = nil
        attachments = []
        isGridVisible = false
        hasInitialized = false
        shouldLoadVideo = true
    }
}
