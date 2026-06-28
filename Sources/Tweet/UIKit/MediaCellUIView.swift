//
//  MediaCellUIView.swift
//  Tweet
//
//  Pure UIKit media cell replacing SwiftUI MediaCell in the feed.
//  Handles image, video, and audio attachments.
//  Video uses LightweightVideoPlayerView (pure UIKit AVPlayerLayer) — no UIHostingController.
//  Coordinator commands arrive via MediaCellDelegate and .stopAllVideos notification.
//
import UIKit
import SwiftUI
import Combine
import AVFoundation

// MARK: - Video Cell State Machine

/// Explicit states for video cell UI — each state defines exactly what's visible.
enum VideoCellState {
    case noContent      // No thumbnail, no player — spinner on dark backdrop
    case thumbnail      // Showing cached/generated thumbnail in imageView
    case playerLoading  // Player attached, awaiting first frame render
    case playerReady    // Player rendered first frame, paused
    case playing        // Actively playing
    case paused         // Paused, showing last rendered frame
    case failed         // Loading failed — showing retry button over thumbnail/dark backdrop
}

// MARK: - Feed Video Resume Store

@MainActor
enum FeedVideoResumeStore {
    static func save(mid: String, player: AVPlayer, wasPlaying: Bool) {
        guard let item = player.currentItem else { return }
        let currentTime = player.currentTime()
        guard currentTime.isValid,
              currentTime.seconds.isFinite,
              currentTime.seconds > 0.25 else { return }
        guard !isNearEnd(time: currentTime, duration: item.duration, tolerance: 5.0) else { return }

        VideoStateCache.shared.cachePlaybackInfo(
            for: mid,
            time: currentTime,
            wasPlaying: wasPlaying,
            originalMuteState: player.isMuted
        )

        PersistentVideoStateManager.shared.saveState(
            videoMid: mid,
            currentTime: currentTime,
            wasPlaying: wasPlaying,
            context: .mediaCell,
            duration: item.duration
        )
    }

    static func resumeTime(for mid: String, player: AVPlayer? = nil) -> CMTime? {
        if FullScreenVideoManager.shared.currentVideoMid == mid,
           let currentTime = validResumeTime(
                FullScreenVideoManager.shared.singletonPlayer?.currentTime(),
                duration: player?.currentItem?.duration
           ) {
            return currentTime
        }

        if DetailVideoManager.shared.currentVideoMid == mid,
           let currentTime = validResumeTime(
                DetailVideoManager.shared.currentPlayer?.currentTime(),
                duration: player?.currentItem?.duration
           ) {
            return currentTime
        }

        if let latest = PersistentVideoStateManager.shared.latestState(
            videoMid: mid,
            excluding: .mediaCell,
            duration: player?.currentItem?.duration
        ) {
            return latest.currentTime
        }

        if let info = VideoStateCache.shared.getCachedPlaybackInfo(for: mid),
           let currentTime = validResumeTime(info.time, duration: player?.currentItem?.duration) {
            return currentTime
        }

        if let saved = PersistentVideoStateManager.shared.getState(
            videoMid: mid,
            context: .mediaCell,
            duration: player?.currentItem?.duration
        ),
           let currentTime = validResumeTime(saved.currentTime, duration: player?.currentItem?.duration) {
            return currentTime
        }

        return nil
    }

    static func clear(mid: String) {
        VideoStateCache.shared.clearCachedState(for: mid)
        PersistentVideoStateManager.shared.clearState(videoMid: mid, context: .mediaCell)
    }

    private static func isNearEnd(time: CMTime, duration: CMTime, tolerance: Double) -> Bool {
        guard duration.isValid,
              !duration.isIndefinite,
              duration.seconds.isFinite,
              duration.seconds > 0 else { return false }

        return duration.seconds - time.seconds <= tolerance
    }

    private static func validResumeTime(_ time: CMTime?, duration: CMTime?) -> CMTime? {
        guard let time,
              time.isValid,
              time.seconds.isFinite,
              time.seconds > 0.25 else { return nil }

        if let duration, isNearEnd(time: time, duration: duration, tolerance: 0.5) {
            return .zero
        }

        return time
    }
}

// MARK: - MediaCellUIView

class MediaCellUIView: UIView, MediaCellDelegate, UIGestureRecognizerDelegate {
    private static var feedPlayerRebuildHistory: [String: [Date]] = [:]
    private static let maxFeedPlayerRebuildsPerWindow = 2
    private static let feedPlayerRebuildWindow: TimeInterval = 90
    private static let maxIndependentFeedPlayers = Constants.MAX_PLAYER_CACHE_SIZE
    private static let slowLoadingNudgeInterval: TimeInterval = 5
    private static let slowLoadingNudgeIntervalNanos: UInt64 = 5_000_000_000
    private static let activeHLSSegmentStartupTimeout: TimeInterval = 75
    private static let foregroundFeedResumeSuppressionDuration: TimeInterval = 30

    private final class IndependentFeedPlayerEntry {
        weak var owner: MediaCellUIView?
        weak var player: AVPlayer?
        let mediaID: String
        var lastAccess: Date

        init(owner: MediaCellUIView, player: AVPlayer, mediaID: String) {
            self.owner = owner
            self.player = player
            self.mediaID = mediaID
            self.lastAccess = Date()
        }
    }

    private static var independentFeedPlayerEntries: [ObjectIdentifier: IndependentFeedPlayerEntry] = [:]

    private static func registerIndependentFeedPlayer(_ player: AVPlayer, owner: MediaCellUIView, mediaID: String) {
        let ownerID = ObjectIdentifier(owner)
        independentFeedPlayerEntries[ownerID] = IndependentFeedPlayerEntry(owner: owner, player: player, mediaID: mediaID)
        enforceIndependentFeedPlayerLimit(excluding: owner)
    }

    private static func unregisterIndependentFeedPlayer(owner: MediaCellUIView) {
        independentFeedPlayerEntries.removeValue(forKey: ObjectIdentifier(owner))
    }

    private static func enforceIndependentFeedPlayerLimit(excluding protectedOwner: MediaCellUIView? = nil) {
        independentFeedPlayerEntries = independentFeedPlayerEntries.filter { _, entry in
            entry.owner != nil && entry.player != nil
        }

        var liveEntries = Array(independentFeedPlayerEntries.values)
        guard liveEntries.count > maxIndependentFeedPlayers else { return }

        liveEntries.sort { lhs, rhs in
            let lhsVisible = lhs.owner?.isVisible == true
            let rhsVisible = rhs.owner?.isVisible == true
            if lhsVisible != rhsVisible { return !lhsVisible && rhsVisible }

            let lhsPrimary = lhs.owner?.coordinatorWantsToPlay == true
            let rhsPrimary = rhs.owner?.coordinatorWantsToPlay == true
            if lhsPrimary != rhsPrimary { return !lhsPrimary && rhsPrimary }

            return lhs.lastAccess < rhs.lastAccess
        }

        for entry in liveEntries where independentFeedPlayerEntries.count > maxIndependentFeedPlayers {
            guard let owner = entry.owner,
                  owner !== protectedOwner,
                  let player = entry.player else {
                continue
            }

            guard !owner.coordinatorWantsToPlay else { continue }
            owner.releaseCurrentIndependentPlayer(
                reason: "independentFeedPlayerLimit",
                showCover: owner.isVisible,
                expectedPlayer: player
            )
        }
    }

#if DEBUG && VERBOSE_VIDEO_LOGS
    private static let verboseLogsEnabled = true
#else
    private static let verboseLogsEnabled = false
#endif

    // MARK: - Subviews

    private let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = UIColor.systemGray6
        return iv
    }()

    /// Pure UIKit video player (AVPlayerLayer) — replaces UIHostingController<SimpleVideoPlayer>
    private let videoPlayerView: LightweightVideoPlayerView = {
        let v = LightweightVideoPlayerView()
        v.backgroundColor = UIColor.systemGray5
        v.clipsToBounds = true
        v.isHidden = true
        // Fill container (clip overflow) — matches SimpleVideoPlayer's .resizeAspectFill for feed cells
        v.setVideoGravity(.resizeAspectFill)
        return v
    }()

    private let loadingSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.hidesWhenStopped = true
        spinner.isUserInteractionEnabled = false
        return spinner
    }()

    /// Retry button shown when image download fails
    private lazy var retryButton: UIButton = {
        let btn = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        btn.setImage(UIImage(systemName: "arrow.clockwise.circle", withConfiguration: config), for: .normal)
        btn.tintColor = UIColor.label.withAlphaComponent(0.72)
        btn.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.86)
        btn.layer.cornerRadius = 22
        btn.layer.borderWidth = 1
        btn.layer.borderColor = UIColor.separator.cgColor
        btn.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        btn.accessibilityLabel = "Retry media"
        btn.isHidden = true
        return btn
    }()

    /// Replay button shown only after this video has naturally played to the end.
    private lazy var replayButton: UIButton = {
        let btn = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        btn.setImage(UIImage(systemName: "play.fill", withConfiguration: config), for: .normal)
        btn.tintColor = .white.withAlphaComponent(0.78)
        btn.backgroundColor = .black.withAlphaComponent(0.34)
        btn.layer.borderWidth = 1
        btn.layer.borderColor = UIColor.white.withAlphaComponent(0.45).cgColor
        btn.addTarget(self, action: #selector(replayTapped), for: .touchUpInside)
        btn.accessibilityLabel = "Replay video"
        btn.isHidden = true
        return btn
    }()

    /// Mute button background circle (26pt visual, inside 44pt touch area)
    private let muteCircleLayer: CALayer = {
        let layer = CALayer()
        layer.backgroundColor = UIColor.black.withAlphaComponent(0.4).cgColor
        layer.cornerRadius = 13
        return layer
    }()

    /// Mute button (only for single-video tweets) — 44pt touch area, 26pt visual circle
    private lazy var muteButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.tintColor = .white
        btn.backgroundColor = .clear
        btn.layer.insertSublayer(muteCircleLayer, at: 0)
        btn.addTarget(self, action: #selector(muteTapped), for: .touchUpInside)
        btn.isHidden = true
        return btn
    }()

    /// Video timer label (only for single-video tweets)
    private lazy var timerLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        label.textColor = .white.withAlphaComponent(0.6)
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        label.layer.cornerRadius = 13
        label.clipsToBounds = true
        label.isHidden = true
        return label
    }()

    // Audio hosting controller (hosts SimpleAudioPlayer — still SwiftUI)
    private var audioHostingController: UIHostingController<AnyView>?

    // MARK: - Video Player State

    /// The AVPlayer instance for this cell's video
    private var player: AVPlayer?

    /// Whether the coordinator wants this video to play
    private var coordinatorWantsToPlay: Bool = false

    /// AVPlayerItemVideoOutput for last-frame capture
    private var videoOutput: AVPlayerItemVideoOutput?
    private weak var videoOutputAttachedItem: AVPlayerItem?

    /// KVO observers
    private var playerItemStatusObserver: NSKeyValueObservation?
    private var playerItemLoadedTimeRangesObserver: NSKeyValueObservation?
    private var timeControlStatusObserver: NSKeyValueObservation?

    /// Notification observers
    private var videoCompletionObserver: NSObjectProtocol?
    private var stopAllObserver: NSObjectProtocol?
    private var playerClaimedObserver: NSObjectProtocol?
    private var videoThumbnailObserver: NSObjectProtocol?
    private var videoPlayerPreloadedObserver: NSObjectProtocol?
    private var videoPlayerItemReplacedObserver: NSObjectProtocol?
    private var shouldPlayObserver: NSObjectProtocol?
    private var shouldPauseObserver: NSObjectProtocol?
    private var shouldStopObserver: NSObjectProtocol?

    /// Async player acquisition task
    private var setupPlayerTask: Task<Void, Never>?

    /// Debounce task that delays player acquisition during fast scroll.
    /// Cancelled if the cell scrolls off-screen before the short acquisition grace elapses.
    private var playerAcquireDebounceTask: Task<Void, Never>?

    /// Fallback task: if item.status stays .unknown after deferring to statusKVO,
    /// enable network and kick playback after a delay (same as deadlock fix).
    private var statusUnknownFallbackTask: Task<Void, Never>?
    private var automaticTransientRetryTask: Task<Void, Never>?
    private var automaticTransientRetryCount = 0
    private let primarySpinnerDebounceNanos: UInt64 = 500_000_000
    /// Defers the primary spinner for cached/covered videos so instant starts do
    /// not flash loading chrome over an already-present frame.
    private var delayedPrimarySpinnerTask: Task<Void, Never>?
    /// Short grace window that avoids flashing primary loading chrome over an
    /// already-present frame.
    private var suppressPrimarySpinnerUntil: Date = .distantPast
    /// Recovery for ready players that were promoted from preload but remain
    /// stuck at the first buffer gap after play() was requested.
    private var playbackStartupRecoveryTask: Task<Void, Never>?
    private var playbackStartupRecoveryRequestDate: Date?
    private var playbackStartupRecoveryDelay: UInt64?
    private var playbackProgressWatchdogTask: Task<Void, Never>?
    /// True after app backgrounding captured a visible feed frame. While active,
    /// keep that frame over the player so foreground proxy/player recovery never
    /// exposes a black AVPlayerLayer.
    private var isHoldingBackgroundVideoCover = false
    private var backgroundVideoCoverMid: String?
    private var foregroundRecoveryLoadingDeadline: Date?
    /// After app foreground recovery, feed autoplay should restart quickly from
    /// the cached prefix instead of seeking to an old feed position that may sit
    /// outside the progressive cache window.
    private var suppressFeedResumeUntil: Date = .distantPast

    /// Periodic time observer token for the video timer label
    private var timeObserverToken: Any?
    /// The player that owns timeObserverToken — must remove from the same instance.
    private weak var timeObserverPlayer: AVPlayer?
    private var timerLabelVideoMid: String?

    /// Frame capture throttle
    private var lastFrameCaptureAt: Date = .distantPast

    /// Last time AVPlayer confirmed playing (timeControlStatus == .playing).
    /// Used by stall-check to distinguish HLS buffer gaps from genuine stalls.
    private var lastActualPlaybackDate: Date = .distantPast
    /// Last time the playback clock actually advanced. AVPlayer can briefly
    /// report .playing while the visible frame is still frozen.
    private var lastPlaybackProgressDate: Date = .distantPast
    /// Last time a decoded frame was observed for the visible video.
    /// This is stronger evidence than AVPlayer's clock and drives stall recovery.
    private var lastDecodedPlaybackProgressDate: Date = .distantPast
    private var lastDecodedPlaybackSeconds: Double = 0
    private var lastObservedPlaybackSeconds: Double = 0
    private var lastPlaybackRequestPositionSeconds: Double = 0
    private var hlsBufferedUnknownStartDate: Date = .distantPast
    private var hlsEmptyWaitingStartDate: Date = .distantPast
    private var hlsActiveSegmentWaitStartDate: Date = .distantPast
    private var hlsActiveSegmentWaitMediaID: String?
    /// True after the current AVPlayerLayer has rendered a frame for this player.
    /// This lets visible non-primary videos stop their spinner once they have
    /// something real to show, even if frame capture did not produce a poster.
    private var hasRenderedFrameForCurrentPlayer: Bool = false {
        didSet {
            if hasRenderedFrameForCurrentPlayer {
                hlsBufferedUnknownStartDate = .distantPast
                hlsEmptyWaitingStartDate = .distantPast
            }
        }
    }
    /// Last time this cell asked AVPlayer to play. This is intent only; it is
    /// intentionally separate from lastActualPlaybackDate.
    private var lastPlaybackRequestDate: Date = .distantPast
    /// Diagnostic counter for repeated waits at the same playback position.
    private var bufferingWaitCount = 0
    private var lastBufferingWaitDate: Date = .distantPast
    private var lastBufferingWaitPositionBucket: Int = -1
    private var lastBufferingWaitLogKey: String?
    private var lastBufferingWaitLogDate: Date = .distantPast
    private var lastSlowLoadWaitLogDate: Date = .distantPast
    private var didLogFirstDecodedPlayback = false
    private var didLogFirstPlaybackProgress = false
    private var lastStartupBufferReleaseDate: Date = .distantPast
    private var startupBufferReleaseUntil: Date = .distantPast
    private var pendingRecoverySeekTime: CMTime?
    private weak var liveHandoffPlayer: AVPlayer?
    private var liveHandoffMid: String?
    private var liveHandoffSeekSuppressionUntil: Date = .distantPast
    private var liveHandoffLastLayerRefreshAt: Date = .distantPast
    private var feedPlayerRebuildCount = 0
    private var firstFeedPlayerRebuildDate: Date = .distantPast
    private var slowLoadingRecoveryTask: Task<Void, Never>?
    private var lastSlowLoadingNudgeDate: Date = .distantPast
    private var lastLoggedTimeControlStatus: AVPlayer.TimeControlStatus?
    private var lastLoggedTimeControlBucket: Int = -1
    private var lastLoggedTimeControlDate: Date = .distantPast


    /// Prevent duplicate finish handling
    private var isHandlingFinishEvent: Bool = false

    /// Video cell state machine — controls imageView/videoPlayerView/spinner visibility
    private var videoCellState: VideoCellState = .noContent


    // MARK: - General State

    /// Per-feed video coordinator (set by MediaGridUIView during configure)
    weak var videoCoordinator: VideoPlaybackCoordinator?

    private var attachment: MimeiFileType?
    private weak var parentTweet: Tweet?
    private var attachmentIndex: Int = 0
    private var aspectRatio: Float = 1.0
    private var cellTweetId: String?
    private var isEmbeddedMedia: Bool = false
    // Visibility and player acquisition intent - true when cell should have a player
    private var isVisible: Bool = false
    private var shouldAcquirePlayer: Bool = true
    private var effectiveBaseUrl: URL = HproseInstance.baseUrl
    private var isSingleMedia: Bool = false
    private weak var parentViewController: UIViewController?
    private var requestedFallbackThumbnailMid: String?

    /// Matches VideoPlaybackInfo.identifier format: outerTweetId_mediaTweetId_videoMid_attachmentIndex.
    /// Used to register/unregister delegate independently per feed cell, so the same video
    /// appearing in both a tweet and its retweet gets separate delegates.
    var videoIdentifier: String? {
        guard let attachment else { return nil }
        let mediaTweetId = parentTweet?.mid ?? ""
        let outerTweetId = cellTweetId ?? mediaTweetId
        return "\(outerTweetId)_\(mediaTweetId)_\(attachment.mid)_\(attachmentIndex)"
    }

    private var usesIndependentPlayerInstance: Bool {
        true
    }

    private var imageLoadTask: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?
    private var imageCacheObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var timerHideTask: DispatchWorkItem?

    private let imageCache = ImageCacheManager.shared

    private lazy var mediaTapGesture: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(mediaTapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        return tap
    }()

    // Logging helper
    private var logPrefix: String {
        let mid = attachment?.mid ?? "nil"
        let shortMid = mid.count > 8 ? String(mid.prefix(8)) : mid
        return "[VIDEO-\(shortMid)]"
    }

    private var canDriveForegroundPlayback: Bool {
        UIApplication.shared.applicationState == .active && AppDelegate.isVideoInfrastructureReady
    }

    private var fullscreenOverlayOwnsCurrentVideo: Bool {
        guard let mid = attachment?.mid else { return false }
        return OverlayVisibilityCoordinator.shared.isCovered
            && FullScreenVideoManager.shared.currentVideoMid == mid
    }

    @discardableResult
    private func deferVideoWorkUntilInfrastructureReady(reason: String, wantsPlayback: Bool? = nil) -> Bool {
        guard !AppDelegate.isVideoInfrastructureReady else { return false }

        if let wantsPlayback {
            coordinatorWantsToPlay = wantsPlayback
        }

        setupPlayerTask?.cancel()
        setupPlayerTask = nil
        playerAcquireDebounceTask?.cancel()
        playerAcquireDebounceTask = nil
        retryButton.isHidden = true
        replayButton.isHidden = true

        if isVisible, isVideoAttachment {
            restoreCachedPosterForFailureIfNeeded()
            if videoCellState == .failed || videoCellState == .noContent {
                transitionTo(imageView.image != nil ? .thumbnail : .playerLoading)
            } else if coordinatorWantsToPlay && imageView.image == nil {
                showPrimarySpinnerAfterDebounce(for: player)
            }
        }

        logVerbose("⏳ \(reason): waiting for video infrastructure")
        return true
    }

    private func logVerbose(_ message: String) {
        guard Self.verboseLogsEnabled else { return }
        print("\(logPrefix) \(message)")
    }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        clipsToBounds = true

        addSubview(videoPlayerView)
        addSubview(imageView)
        addSubview(loadingSpinner)
        addSubview(retryButton)
        addSubview(replayButton)
        addSubview(muteButton)
        addSubview(timerLabel)

        isUserInteractionEnabled = true
        addGestureRecognizer(mediaTapGesture)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === mediaTapGesture else { return true }
        var view: UIView? = touch.view
        while let current = view {
            if current is UIControl {
                return false
            }
            view = current.superview
        }
        return true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil && isVisible {
            setVisible(false)
        } else if window != nil && isVisible {
            resumeSurfaceReturnHandoffIfNeeded(reason: "didMoveToWindow")
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        imageView.frame = b
        videoPlayerView.frame = b
        loadingSpinner.center = CGPoint(x: b.midX, y: b.midY)

        retryButton.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        retryButton.center = CGPoint(x: b.midX, y: b.midY)
        replayButton.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        replayButton.layer.cornerRadius = 20
        replayButton.center = CGPoint(x: b.midX, y: b.midY)
        // Mute button: 44pt touch area centered on 26pt visual circle, bottom-right
        let visualSize: CGFloat = 24
        let touchSize: CGFloat = 44
        let inset = (touchSize - visualSize) / 2  // 9pt
        muteButton.frame = CGRect(
            x: b.maxX - visualSize - 6 - inset,
            y: b.maxY - visualSize - 6 - inset,
            width: touchSize, height: touchSize
        )
        muteCircleLayer.frame = CGRect(x: inset, y: inset, width: visualSize, height: visualSize)

        layoutTimerLabel(in: b)

        audioHostingController?.view.frame = b
    }

    // MARK: - Video Cell State Machine

    /// Single source of truth for video cell visibility.
    /// imageView is NEVER shown with nil image — either it has content or it's hidden.
    private func transitionTo(_ state: VideoCellState) {
        let oldState = videoCellState
        discardInvalidVideoCoverIfNeeded()
        videoCellState = state
        let holdBackgroundCover = isHoldingBackgroundVideoCover
            && backgroundVideoCoverMid == attachment?.mid
            && imageView.image != nil

        // Log state transitions
        if oldState != state {
            logVerbose("State: \(oldState) → \(state)")
        }

        // Hide retry button when leaving .failed state
        if state != .failed {
            retryButton.isHidden = true
        }
        updateReplayButtonVisibility()

        switch state {
        case .noContent:
            videoPlayerView.alpha = 1
            if holdBackgroundCover {
                showImageView()
                videoPlayerView.isHidden = true
            } else {
                hideImageViewImmediately()
                videoPlayerView.isHidden = false
            }
            if coordinatorWantsToPlay {
                showPrimarySpinnerAfterDebounce(for: player)
            } else if shouldShowVisibleVideoCoverSpinner(hasCover: false) {
                loadingSpinner.startAnimating()
            } else {
                loadingSpinner.stopAnimating()
            }
        case .thumbnail:
            videoPlayerView.alpha = 1
            if imageView.image != nil {
                showImageView()
                videoPlayerView.isHidden = true
            } else {
                hideImageViewImmediately()
                videoPlayerView.isHidden = false
            }
            // If this is the selected video, a newly captured cover frame should not
            // briefly dismiss loading feedback before AVPlayer is actually playing.
            if shouldShowBackgroundRecoverySpinner {
                showPrimarySpinnerAfterDebounce(for: player)
            } else if coordinatorWantsToPlay {
                showPrimarySpinnerAfterDebounce()
            } else {
                loadingSpinner.stopAnimating()
            }
        case .playerLoading:
            let canRevealLoadedPlayer = currentPlayerCanReplaceCover
            let hasDisplayableCover = canRevealLoadedPlayer || hasVideoCoverForSpinner
            let shouldShowThumbnail = imageView.image != nil && !canRevealLoadedPlayer
            if shouldShowThumbnail {
                showImageView()
            } else {
                hideImageViewImmediately()
                if canRevealLoadedPlayer {
                    imageView.image = nil
                }
            }
            // Keep the attached player layer alive behind the thumbnail. Hiding
            // AVPlayerLayer can prevent it from becoming readyForDisplay, while
            // imageView sits above it and covers any black surface until then.
            videoPlayerView.isHidden = false
            videoPlayerView.alpha = 1
            // Primary videos always show loading chrome. Visible non-primary videos
            // also show it until their cover frame arrives; off-screen preloads stay quiet.
            if shouldShowBackgroundRecoverySpinner {
                showPrimarySpinnerAfterDebounce(for: player)
            } else if coordinatorWantsToPlay {
                showPrimarySpinnerAfterDebounce(for: player)
            } else if shouldShowVisibleVideoCoverSpinner(hasCover: hasDisplayableCover) {
                loadingSpinner.startAnimating()
            } else {
                loadingSpinner.stopAnimating()
            }
        case .playerReady:
            let canRevealLoadedPlayer = currentPlayerCanReplaceCover
            let shouldShowThumbnail = imageView.image != nil && !canRevealLoadedPlayer
            let hasDisplayableCover = canRevealLoadedPlayer || hasVideoCoverForSpinner
            // Keep a thumbnail until the attached player layer has a displayable
            // frame. Buffered data alone can still render as a black AVPlayerLayer.
            if shouldShowThumbnail {
                showImageView()
            } else {
                hideImageViewImmediately()
                if canRevealLoadedPlayer {
                    imageView.image = nil
                }
            }
            videoPlayerView.isHidden = false
            videoPlayerView.alpha = 1
            // With streaming, the first frame can render before playback can continue.
            // Keep primary feedback on, and keep visible non-primary feedback on until
            // a cover frame exists. Off-screen preloads should not show spinner chrome.
            if coordinatorWantsToPlay {
                showPrimarySpinnerAfterDebounce(for: player)
            } else if shouldShowVisibleVideoCoverSpinner(hasCover: hasDisplayableCover) {
                loadingSpinner.startAnimating()
            } else {
                loadingSpinner.stopAnimating()
            }
        case .playing, .paused:
            videoPlayerView.alpha = 1
            videoPlayerView.isHidden = false
            // Spinner stays on as long as the video is supposed to be playing but isn't
            // actually rendering frames yet — covers the transient .paused window between
            // play() and the first .waitingToPlayAtSpecifiedRate / .playing KVO callback.
            if state == .playing,
               let player = self.player,
               !isVideoAtEnd(player),
               !isVisibleVideoFrameReady(player) {
                showPrimarySpinnerAfterDebounce(for: player)
            } else {
                loadingSpinner.stopAnimating()
            }
            // Keep thumbnail as cover until the player layer has a displayable
            // frame. Buffered data alone can still show a black AVPlayerLayer.
            if player != nil,
               currentPlayerCanReplaceCover {
                hideImageViewImmediately()
                imageView.image = nil
            } else if imageView.image == nil {
                hideImageViewImmediately()
            } else {
                showImageView()
            }
        case .failed:
            videoPlayerView.alpha = 1
            replayButton.isHidden = true
            restoreCachedPosterForFailureIfNeeded()
            // Prefer thumbnail (captured from last rendered frame) over black backdrop.
            // cleanupFailedPlayerState nils the player before we get here, so rely on
            // imageView which was set by preserveFrameToCache() earlier in the failure path.
            if imageView.image != nil {
                showImageView()
                videoPlayerView.isHidden = true
            } else {
                // No thumbnail — show videoPlayerView as black backdrop
                hideImageViewImmediately()
                videoPlayerView.isHidden = false
            }
            if automaticTransientRetryTask != nil {
                loadingSpinner.startAnimating()
                retryButton.isHidden = true
            } else {
                loadingSpinner.stopAnimating()
                retryButton.isHidden = false
            }
        }
    }

    private func showImageView() {
        discardInvalidVideoCoverIfNeeded()
        guard imageView.image != nil else {
            hideImageViewImmediately()
            return
        }
        imageView.layer.removeAllAnimations()
        imageView.alpha = 1
        imageView.isHidden = false
    }

    private func isInvalidVideoCover(_ image: UIImage) -> Bool {
        VideoFrameExtractor.isMostlyBlack(image) || VideoFrameExtractor.isMostlyWhite(image)
    }

    private func discardInvalidVideoCoverIfNeeded() {
        guard let image = imageView.image,
              isInvalidVideoCover(image) else { return }
        imageView.image = nil
        hideImageViewImmediately()
    }

    private func hideImageViewImmediately() {
        imageView.layer.removeAllAnimations()
        imageView.alpha = 1
        imageView.isHidden = true
    }

    private func fadeOutVideoCoverForPlayback() {
        videoPlayerView.isHidden = false
        imageView.layer.removeAllAnimations()
        hideImageViewImmediately()
        imageView.image = nil
        clearBackgroundVideoCoverHold()
    }

    @discardableResult
    private func capturePlayerFrameAsCoverIfPossible() -> Bool {
        guard isVideoAttachment,
              player != nil else { return false }

        return preserveFrameToCache(skipImageView: true, allowCachedFallback: false)
            || preserveFrameToCache(useVideoOutput: false, skipImageView: true, allowCachedFallback: false)
    }

    private var shouldShowBackgroundRecoverySpinner: Bool {
        isHoldingBackgroundVideoCover
            && backgroundVideoCoverMid == attachment?.mid
            && isVisible
            && isVideoAttachment
            && (coordinatorWantsToPlay || setupPlayerTask != nil || playerAcquireDebounceTask != nil)
    }

    private func clearBackgroundVideoCoverHold() {
        isHoldingBackgroundVideoCover = false
        backgroundVideoCoverMid = nil
        foregroundRecoveryLoadingDeadline = nil
    }

    @discardableResult
    private func removeVideoCoverIfLoadedAndDisplayable(_ player: AVPlayer, reason: String) -> Bool {
        guard isVideoAttachment,
              self.player === player,
              imageView.image != nil else { return false }
        guard playerHasDisplayableFrame(player) else { return false }

        videoPlayerView.isHidden = false
        hideImageViewImmediately()
        imageView.image = nil
        clearBackgroundVideoCoverHold()
        if coordinatorWantsToPlay {
            updateLoadingSpinnerForPlayback(player)
        } else {
            loadingSpinner.stopAnimating()
        }
        logVerbose("🖼️ removed video cover after displayable frame (\(reason))")
        return true
    }

    @discardableResult
    private func settleForegroundCachedPlayerIfReady(_ player: AVPlayer, reason: String) -> Bool {
        guard isVisible,
              isVideoAttachment,
              self.player === player,
              let item = player.currentItem,
              item.status == .readyToPlay,
              playerHasLoadedData(player) else { return false }

        if videoPlayerView.isLayerReadyForDisplay {
            hasRenderedFrameForCurrentPlayer = true
            removeVideoCoverIfLoadedAndDisplayable(player, reason: "\(reason)-settle")
        } else {
            restoreCachedPosterForFailureIfNeeded()
        }

        if videoCellState == .noContent || videoCellState == .playerLoading {
            transitionTo(.playerReady)
        }

        if coordinatorWantsToPlay {
            requestPlaybackStartIfNeeded(player, reason: "\(reason)-cachedReady")
        }

        if coordinatorWantsToPlay {
            updateLoadingSpinnerForPlayback(player)
        } else if imageView.image != nil || hasRenderedFrameForCurrentPlayer || videoPlayerView.isLayerReadyForDisplay {
            cancelDelayedPrimarySpinner()
            loadingSpinner.stopAnimating()
        } else {
            updateLoadingSpinnerForPlayback(player)
        }

        logVerbose("✅ foreground cached player settled (\(reason)): buffered=\(String(format: "%.2f", bufferedTimeAhead(for: player)))s")
        return true
    }

    private var hasVideoCoverForSpinner: Bool {
        imageView.image != nil || hasRenderedFrameForCurrentPlayer
    }

    private func shouldShowVisibleVideoCoverSpinner(hasCover: Bool? = nil) -> Bool {
        isVisible && isVideoAttachment && shouldAcquirePlayer && !(hasCover ?? hasVideoCoverForSpinner)
    }

    private var shouldShowReplayButton: Bool {
        guard isVisible,
              isVideoAttachment,
              let id = videoIdentifier,
              VideoStateCache.shared.isVideoFinished(id) else {
            return false
        }

        if let player, shouldSuppressReplayButtonForActivePlayback(player) {
            return false
        }

        return true
    }

    private func updateReplayButtonVisibility() {
        replayButton.isHidden = !shouldShowReplayButton
    }

    private func reconcileReplayButtonWithPlaybackState(for player: AVPlayer?, reason: String) {
        guard isVideoAttachment, let mid = attachment?.mid else { return }

        if let player,
           shouldSuppressReplayButtonForActivePlayback(player),
           let id = videoIdentifier,
           VideoStateCache.shared.isVideoFinished(id) {
            isHandlingFinishEvent = false
            VideoStateCache.shared.clearStoppedByCoordinator(mid)
            (videoCoordinator ?? .shared).clearFinishedPlaybackState(identifier: id)
            logVerbose("🔁 cleared stale finished replay state (\(reason))")
        }

        updateReplayButtonVisibility()
    }

    private func shouldSuppressReplayButtonForActivePlayback(_ player: AVPlayer) -> Bool {
        guard player.currentItem != nil, !isVideoAtEnd(player) else { return false }

        if isActuallyPlaying { return true }
        if hasActivePlaybackIntent(player) { return true }
        return videoCellState == .playing || videoCellState == .playerReady
    }

    private func hasActivePlaybackIntent(_ player: AVPlayer) -> Bool {
        player.rate > 0 ||
            player.timeControlStatus == .playing ||
            player.timeControlStatus == .waitingToPlayAtSpecifiedRate ||
            coordinatorWantsToPlay
    }

    // MARK: - Configure

    func configure(
        parentTweet: Tweet,
        attachmentIndex: Int,
        aspectRatio: Float,
        shouldAcquirePlayer: Bool,
        isEmbedded: Bool,
        cellTweetId: String?,
        isSingleMedia: Bool,
        parentViewController: UIViewController
    ) {
        // Skip full teardown/rebuild if same attachment — just update aspect ratio.
        // MediaGridUIView.layoutSubviews() re-calls configure() to pass the real aspect ratio
        // after the placeholder 1.0; without this guard we'd destroy and recreate the player.
        if self.parentTweet?.mid == parentTweet.mid,
           self.attachmentIndex == attachmentIndex,
           self.attachment != nil {
            self.aspectRatio = aspectRatio
            self.isEmbeddedMedia = isEmbedded
            self.shouldAcquirePlayer = shouldAcquirePlayer
            self.cellTweetId = cellTweetId
            self.isSingleMedia = isSingleMedia
            self.parentViewController = parentViewController
            setNeedsLayout()
            return
        }

        self.parentTweet = parentTweet
        self.attachmentIndex = attachmentIndex
        self.aspectRatio = aspectRatio
        self.isEmbeddedMedia = isEmbedded
        self.shouldAcquirePlayer = shouldAcquirePlayer
        self.cellTweetId = cellTweetId
        self.isSingleMedia = isSingleMedia
        self.parentViewController = parentViewController

        guard let attachments = parentTweet.attachments,
              attachmentIndex >= 0 && attachmentIndex < attachments.count else { return }

        let att = attachments[attachmentIndex]

        self.attachment = att

        // Compute effective base URL
        effectiveBaseUrl = parentTweet.author?.baseUrl
            ?? HproseInstance.shared.appUser.baseUrl
            ?? HproseInstance.baseUrl

        // Reset UI
        imageView.image = nil
        imageView.isHidden = true
        videoPlayerView.isHidden = true
        muteButton.isHidden = true
        timerLabel.isHidden = true
        retryButton.isHidden = true
        replayButton.isHidden = true
        loadingSpinner.stopAnimating()

        guard let url = att.getUrl(effectiveBaseUrl) else { return }

        switch att.type {
        case .image:
            setupImageCell(attachment: att, url: url)

        case .video, .hls_video:
            setupVideoCell(attachment: att, url: url, parentTweet: parentTweet)

        case .audio:
            setupAudioCell(url: url)

        default:
            break
        }
    }

    // MARK: - Image

    private func setupImageCell(attachment: MimeiFileType, url: URL) {
        imageView.isHidden = false
        setupImageCacheObserver()

        if isVisible {
            loadImage(attachment: attachment, url: url)
        } else {
            applyCachedImageIfAvailable(for: attachment)
        }
    }

    @discardableResult
    private func applyCachedImageIfAvailable(for attachment: MimeiFileType) -> Bool {
        guard let cached = imageCache.getCompressedImageFromMemory(for: attachment) else {
            return false
        }

        imageView.image = cached
        imageView.isHidden = false
        loadingSpinner.stopAnimating()
        retryButton.isHidden = true
        imageLoadTask = nil
        return true
    }

    private func setupImageCacheObserver() {
        guard imageCacheObserver == nil else { return }
        imageCacheObserver = NotificationCenter.default.addObserver(
            forName: .imageCached,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let currentAttachment = self.attachment,
                  currentAttachment.type == .image,
                  notification.userInfo?["avatarId"] as? String == currentAttachment.mid else { return }

            self.applyCachedImageIfAvailable(for: currentAttachment)
        }
    }

    private func loadImage(attachment: MimeiFileType, url: URL) {
        guard isVisible else { return }

        // 1. Memory cache (synchronous)
        if applyCachedImageIfAvailable(for: attachment) {
            return
        }

        imageLoadTask?.cancel()

        // 2. Disk cache (background) → network (default gray color for light image background)
        loadingSpinner.color = nil  // reset to system default (gray, visible on .systemGray6)
        loadingSpinner.startAnimating()
        let attachmentCopy = attachment
        let baseUrlCopy = effectiveBaseUrl

        imageLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            let cachedImage = self.imageCache.getCompressedImage(for: attachmentCopy)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                // Guard: cell may have been reused for a different attachment
                guard !Task.isCancelled,
                      self.attachment?.mid == attachmentCopy.mid,
                      self.isVisible else { return }

                if let cachedImage {
                    self.imageView.image = cachedImage
                    self.loadingSpinner.stopAnimating()
                    self.imageLoadTask = nil
                } else {
                    // Use critical priority for ALL visible images (single or grid)
                    GlobalImageLoadManager.shared.loadImageCriticalPriority(
                        id: attachmentCopy.mid,
                        url: url,
                        attachment: attachmentCopy,
                        baseUrl: baseUrlCopy
                    ) { [weak self] loadedImage in
                        // Guard: cell may have been reused while network load was in flight
                        guard let self,
                              self.attachment?.mid == attachmentCopy.mid,
                              self.isVisible else { return }
                        self.imageLoadTask = nil
                        if let loadedImage = loadedImage {
                            self.imageView.image = loadedImage
                            self.loadingSpinner.stopAnimating()
                            self.retryButton.isHidden = true
                        } else {
                            // Image failed/cancelled - show retry button if not cancelled
                            self.loadingSpinner.stopAnimating()
                            if !Task.isCancelled {
                                self.retryButton.isHidden = false
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Video

    private func setupVideoCell(attachment: MimeiFileType, url: URL, parentTweet: Tweet) {

        // Reset any previous video state
        let hasSameVideoRecoveryCover = isVideoAttachment
            && self.attachment?.mid == attachment.mid
            && imageView.image != nil
        pendingRecoverySeekTime = nil
        cleanupVideoPlayer(
            reason: "setupVideoCell",
            preserveBackgroundCover: hasSameVideoRecoveryCover
        )
        if hasSameVideoRecoveryCover {
            isHoldingBackgroundVideoCover = true
            backgroundVideoCoverMid = attachment.mid
            foregroundRecoveryLoadingDeadline = Date().addingTimeInterval(5.0)
            SharedAssetCache.shared.protectBackgroundPoster(for: attachment.mid)
        }

        // Keep the spinner subtle, but less faint than before on the light video placeholder.
        loadingSpinner.color = .white.withAlphaComponent(0.9)

        // Start with a dark loading state, then apply/generate any cached poster
        // immediately. If AVPlayer stalls before first render, a poster is much
        // better feedback than a black rectangle.
        transitionTo(imageView.image == nil ? .noContent : .thumbnail)
        observeCachedVideoThumbnail(for: attachment.mid)
        observePreloadedVideoPlayer(for: attachment.mid)
        if let transitionPoster = FullScreenVideoManager.shared.transitionPoster(for: attachment.mid) {
            applyCachedVideoThumbnail(transitionPoster)
        }
        if let thumbnail = SharedAssetCache.shared.cachedThumbnail(for: attachment.mid) {
            applyCachedVideoThumbnail(thumbnail)
        }
        requestFallbackVideoThumbnailIfNeeded(for: attachment.mid)

        // Tap gesture for fullscreen — on both videoPlayerView and imageView so that
        // any visible video is tappable (thumbnail state or non-primary use imageView).
        // Listen for .stopAllVideos (posted by non-coordinator code like handleVideoTap)
        stopAllObserver = NotificationCenter.default.addObserver(
            forName: .stopAllVideos, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleStopAllVideos()
        }

        // Listen for another feed cell claiming exclusive ownership of the same player.
        // When tweet A and its retweet B both show the same videoMid, both call acquirePlayer()
        // and get the same cached AVPlayer. Whichever cell calls configurePlayer() last posts
        // this notification so earlier holders release their KVO observers and player reference,
        // preventing duplicate timeControlStatus and statusKVO logs.
        let myIdentity = ObjectIdentifier(self).hashValue
        playerClaimedObserver = NotificationCenter.default.addObserver(
            forName: .videoPlayerClaimedByCell, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  !self.usesIndependentPlayerInstance,
                  let claimedMid = notification.userInfo?["videoMid"] as? String,
                  let claimerHash = notification.userInfo?["claimerIdentity"] as? Int,
                  claimedMid == self.attachment?.mid,
                  claimerHash != myIdentity,
                  self.player != nil else { return }
            self.detachSharedPlayerReference(reason: "claimedByAnotherCell")
        }

        videoPlayerItemReplacedObserver = NotificationCenter.default.addObserver(
            forName: .videoPlayerItemReplaced, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  !self.usesIndependentPlayerInstance,
                  let replacedMid = notification.userInfo?["mediaID"] as? String,
                  replacedMid == self.attachment?.mid,
                  let player = self.player else { return }
            if notification.userInfo?["released"] as? Bool == true || player.currentItem == nil {
                self.detachSharedPlayerReference(reason: "sharedPlayerReleased")
                return
            }
            self.refreshAfterSharedPlayerItemReplacement(player, reason: "sharedItemReplaced")
        }

        // Observe MuteState changes → forward to player
        MuteState.shared.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] muted in
                self?.player?.isMuted = muted
            }
            .store(in: &cancellables)

        schedulePlayerAcquireIfNeeded()

        // Mute button on all feed videos; timer shown only for single-attachment videos
        setupMuteButton()
    }

    private func observeCachedVideoThumbnail(for mediaID: String) {
        if let observer = videoThumbnailObserver {
            NotificationCenter.default.removeObserver(observer)
            videoThumbnailObserver = nil
        }

        videoThumbnailObserver = NotificationCenter.default.addObserver(
            forName: .videoThumbnailCached,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let notifiedMediaID = notification.userInfo?["mediaID"] as? String
            Task { @MainActor [weak self] in
                guard let self,
                      self.attachment?.mid == mediaID,
                      notifiedMediaID == mediaID,
                      let thumbnail = SharedAssetCache.shared.cachedThumbnail(for: mediaID) else {
                    return
                }
                self.applyCachedVideoThumbnail(thumbnail)
            }
        }
    }

    private func applyCachedVideoThumbnail(_ image: UIImage) {
        guard canShowCachedCoverForCurrentVideo else { return }
        guard !isInvalidVideoCover(image) else { return }
        if coordinatorWantsToPlay,
           player != nil,
           (videoCellState == .playerLoading || videoCellState == .playerReady || videoCellState == .playing),
           currentPlayerCanReplaceCover {
            return
        }
        imageView.image = image
        switch videoCellState {
        case .noContent:
            transitionTo(.thumbnail)
        case .thumbnail, .playerLoading, .playerReady, .playing, .paused:
            // Re-evaluate visibility now that the poster exists. For non-primary
            // preload cells this hides the black layer and stops the spinner.
            transitionTo(videoCellState)
        case .failed:
            // Keep the retry affordance, but replace the black backdrop if a cover
            // frame arrives after the failure transition.
            transitionTo(.failed)
        }
    }

    private func requestFallbackVideoThumbnailIfNeeded(for mediaID: String) {
        guard requestedFallbackThumbnailMid != mediaID,
              imageView.image == nil,
              player == nil,
              setupPlayerTask == nil,
              playerAcquireDebounceTask == nil,
              !videoPlayerView.hasAttachedPlayer,
              !videoPlayerView.isLayerReadyForDisplay,
              !hasRenderedFrameForCurrentPlayer,
              SharedAssetCache.shared.cachedThumbnail(for: mediaID) == nil else { return }
        requestedFallbackThumbnailMid = mediaID
        SharedAssetCache.shared.generatePreloadedThumbnailIfNeeded(for: mediaID)
        SharedAssetCache.shared.generateThumbnailIfNeeded(for: mediaID) { [weak self] image in
            guard let self,
                  self.attachment?.mid == mediaID else { return }
            self.applyCachedVideoThumbnail(image)
        }
    }

    private func observePreloadedVideoPlayer(for mediaID: String) {
        if let observer = videoPlayerPreloadedObserver {
            NotificationCenter.default.removeObserver(observer)
            videoPlayerPreloadedObserver = nil
        }

        videoPlayerPreloadedObserver = NotificationCenter.default.addObserver(
            forName: .videoPlayerPreloaded,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  self.isVisible,
                  self.attachment?.mid == mediaID,
                  notification.userInfo?["mediaID"] as? String == mediaID,
                  let att = self.attachment,
                  let url = att.getUrl(self.effectiveBaseUrl),
                  let parentTweet = self.parentTweet else {
                return
            }
            self.playerAcquireDebounceTask?.cancel()
            self.playerAcquireDebounceTask = nil
            if self.attachCachedPlayerIfAvailable(reason: "preloadNotification") {
                return
            }
            guard self.player == nil, self.setupPlayerTask == nil else { return }
            self.acquirePlayer(attachment: att, url: url, parentTweet: parentTweet)
        }
    }

    // MARK: - Player Acquisition

    @discardableResult
    private func attachCachedPlayerIfAvailable(reason: String) -> Bool {
        guard !usesIndependentPlayerInstance else {
            return false
        }

        guard isVisible,
              isVideoAttachment,
              shouldAcquirePlayer,
              let mid = attachment?.mid,
              let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: mid),
              cachedPlayer.currentItem != nil else {
            return false
        }

        if let player,
           player !== cachedPlayer,
           videoPlayerView.isShowingPlayer(player),
           isVisibleVideoFrameReady(player) {
            return false
        }

        setupPlayerTask?.cancel()
        setupPlayerTask = nil
        playerAcquireDebounceTask?.cancel()
        playerAcquireDebounceTask = nil
        cachedPlayer.isMuted = MuteState.shared.isMuted

        if player === cachedPlayer {
            attachPlayerToLayer(cachedPlayer)
            refreshAfterSharedPlayerItemReplacement(cachedPlayer, reason: reason)
            settleForegroundCachedPlayerIfReady(cachedPlayer, reason: reason)
        } else if isSurfaceReturnHandoffPlayer(cachedPlayer, mid: mid) {
            attachSharedPlayerForHandoff(cachedPlayer, reason: reason)
        } else {
            if cachedPlayer.rate > 0 { cachedPlayer.pause() }
            configurePlayer(cachedPlayer)
        }
        return true
    }

    private func schedulePlayerAcquireIfNeeded() {
        guard isVisible,
              isVideoAttachment,
              player == nil,
              setupPlayerTask == nil,
              playerAcquireDebounceTask == nil else {
            return
        }
        guard !deferVideoWorkUntilInfrastructureReady(reason: "schedulePlayerAcquire") else {
            return
        }

        if let att = attachment,
           (VideoStateCache.shared.getCachedState(for: att.mid) != nil
            || SharedAssetCache.shared.getCachedPlayer(for: att.mid) != nil),
           let url = att.getUrl(effectiveBaseUrl),
           let parentTweet = parentTweet {
            if attachCachedPlayerIfAvailable(reason: "scheduleAcquire.cacheHit") {
                return
            }
            acquirePlayer(attachment: att, url: url, parentTweet: parentTweet)
            return
        }

        playerAcquireDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled,
                  let self else { return }
            defer { self.playerAcquireDebounceTask = nil }

            guard self.isVisible,
                  let att = self.attachment,
                  att.type == .video || att.type == .hls_video,
                  let url = att.getUrl(self.effectiveBaseUrl),
                  let parentTweet = self.parentTweet else { return }

            // Skip if a player is already configured (coordinator may have acquired one
            // during the 0.5s window). Without this guard, the debounce reconfigures
            // an already-playing player — causing a playing→playerLoading state reset.
            guard self.player == nil, self.setupPlayerTask == nil else { return }
            self.acquirePlayer(attachment: att, url: url, parentTweet: parentTweet)
        }
    }

    private func acquirePlayer(attachment: MimeiFileType, url: URL, parentTweet: Tweet) {
        guard isVisible else { return }
        guard !deferVideoWorkUntilInfrastructureReady(reason: "acquirePlayer") else { return }

        let mid = attachment.mid

        if usesIndependentPlayerInstance {
            acquireIndependentPlayer(attachment: attachment, url: url, parentTweet: parentTweet)
            return
        }

        // TIER 1: Synchronous cache hit (VideoStateCache)
        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            let cachedPlayer = cachedState.player
            cachedPlayer.isMuted = MuteState.shared.isMuted

            // Validate cached player
            guard cachedPlayer.currentItem != nil else {
                print("\(logPrefix) ⚠️ Cached player invalid - falling back to async")
                SharedAssetCache.shared.removeInvalidPlayer(for: mid, force: true)
                VideoStateCache.shared.clearCachedState(for: mid)
                clearFeedResumeState(for: mid)
                acquirePlayerAsync(attachment: attachment, url: url, parentTweet: parentTweet)
                return
            }

            if shouldRebuildCachedFeedPlayer(cachedPlayer, mid: mid, source: "VideoStateCache") {
                guard rebuildCachedFeedPlayer(cachedPlayer, mid: mid, reason: "VideoStateCache cached player wedged") else { return }
                acquirePlayerAsync(attachment: attachment, url: url, parentTweet: parentTweet)
                return
            }

            let isAtEnd = isVideoAtEnd(cachedPlayer)

            // Reset finished videos to beginning
            if isAtEnd {
                VideoStateCache.shared.clearCachedState(for: mid)
                clearFeedResumeState(for: mid)
                cachedPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            }

            if isSurfaceReturnHandoffPlayer(cachedPlayer, mid: mid) {
                attachSharedPlayerForHandoff(cachedPlayer, reason: "VideoStateCache-surfaceReturn")
                return
            }

            // Pause if playing (prevent audio bleed in feed)
            if cachedPlayer.rate > 0 { cachedPlayer.pause() }
            configurePlayer(cachedPlayer)
            return
        }

        // TIER 2: Synchronous directional-preload cache hit
        if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: mid),
           cachedPlayer.currentItem != nil {
            cachedPlayer.isMuted = MuteState.shared.isMuted
            if shouldRebuildCachedFeedPlayer(cachedPlayer, mid: mid, source: "SharedAssetCache") {
                guard rebuildCachedFeedPlayer(cachedPlayer, mid: mid, reason: "SharedAssetCache cached player wedged") else { return }
                acquirePlayerAsync(attachment: attachment, url: url, parentTweet: parentTweet)
                return
            }
            if isVideoAtEnd(cachedPlayer) {
                clearFeedResumeState(for: mid)
                cachedPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            }
            if isSurfaceReturnHandoffPlayer(cachedPlayer, mid: mid) {
                attachSharedPlayerForHandoff(cachedPlayer, reason: "SharedAssetCache-surfaceReturn")
                return
            }
            if cachedPlayer.rate > 0 { cachedPlayer.pause() }
            configurePlayer(cachedPlayer)
            return
        }

        // TIER 3: Async loading
        acquirePlayerAsync(attachment: attachment, url: url, parentTweet: parentTweet)
    }

    private func acquireIndependentPlayer(attachment: MimeiFileType, url: URL, parentTweet: Tweet) {
        guard shouldAcquirePlayer else { return }
        acquireIndependentPlayerAsync(attachment: attachment, url: url, parentTweet: parentTweet)
    }

    private func acquireIndependentPlayerAsync(attachment: MimeiFileType, url: URL, parentTweet: Tweet) {
        guard shouldAcquirePlayer else { return }

        let uniqueURL = buildUniquePlayerURL(url: url, parentTweetId: parentTweet.mid)
        let mediaType = attachment.type
        let expectedMid = attachment.mid

        setupPlayerTask?.cancel()
        setupPlayerTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try Task.checkCancellation()
                let playerItem = try await SharedAssetCache.shared.getOrCreatePlayerItem(
                    for: uniqueURL,
                    mediaID: expectedMid,
                    mediaType: mediaType
                )
                try Task.checkCancellation()

                let newPlayer = AVPlayer(playerItem: playerItem)
                let muteState = await MainActor.run { MuteState.shared.isMuted }
                newPlayer.isMuted = muteState

                await MainActor.run { [weak self] in
                    guard !Task.isCancelled, let self else { return }
                    guard self.attachment?.mid == expectedMid,
                          self.isVisible else {
                        print("\(self.logPrefix) ⚠️ Independent player for \(expectedMid) arrived after cell reuse — discarding")
                        self.releaseDetachedPlayer(newPlayer)
                        return
                    }

                    newPlayer.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = self.isVisible || self.coordinatorWantsToPlay
                    newPlayer.isMuted = MuteState.shared.isMuted
                    self.configurePlayer(newPlayer)
                    self.setupPlayerTask = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                let nsError = error as NSError
                let isCancellation = nsError.code == NSURLErrorCancelled || error is CancellationError
                let isBlacklisted = nsError.domain == "SharedAssetCache" && nsError.code == -2
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard self.isVisible else {
                        self.setupPlayerTask = nil
                        return
                    }
                    if isCancellation {
                        print("\(self.logPrefix) ⚠️ Independent player creation cancelled")
                        self.setupPlayerTask = nil
                        return
                    }
                    if isBlacklisted {
                        print("\(self.logPrefix) 🚫 Video blacklisted - no retry")
                        self.loadingSpinner.stopAnimating()
                        self.setupPlayerTask = nil
                        if self.imageView.image != nil {
                            self.transitionTo(.thumbnail)
                        } else {
                            self.videoPlayerView.isHidden = true
                            self.videoCellState = .thumbnail
                        }
                        return
                    }
                    let nsErr = error as NSError
                    self.handleVideoLoadFailure(reason: "Independent player creation failed: \(nsErr.domain) \(nsErr.code)")
                }
            }
        }
    }

    private func shouldRebuildCachedFeedPlayer(_ player: AVPlayer, mid: String, source: String) -> Bool {
        guard let item = player.currentItem else { return true }

        if player.error != nil || item.error != nil || item.status == .failed {
            return true
        }

        let bufferedAhead = bufferedTimeAhead(for: player)
        if attachment?.type == .hls_video,
           item.status == .unknown,
           playerHasLoadedData(player),
           !isSurfaceReturnHandoffPlayer(player, mid: mid) {
            print("\(logPrefix) ⏳ \(source) cached HLS player has buffered data but item is still .unknown for \(mid): buffered=\(String(format: "%.1f", bufferedAhead))s - keeping player for playback kick")
            return false
        }

        guard coordinatorWantsToPlay,
              isVisible,
              !isVideoAtEnd(player) else { return false }

        let isWaitingWithoutBuffer = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            && bufferedAhead < 0.25
        let isUnknownAndWaiting = item.status == .unknown
            && player.timeControlStatus == .waitingToPlayAtSpecifiedRate

        if isWaitingWithoutBuffer || isUnknownAndWaiting {
            print("\(logPrefix) 🔄 \(source) cached player looks wedged for \(mid): status=\(item.status.rawValue), timeControl=\(player.timeControlStatus.rawValue), buffered=\(String(format: "%.1f", bufferedAhead))s - rebuilding from proxy cache")
            return true
        }

        return false
    }

    private func reserveFeedPlayerRebuild(player: AVPlayer, mid: String, reason: String) -> Bool {
        let now = Date()
        let rebuildWindowStart = now.addingTimeInterval(-Self.feedPlayerRebuildWindow)
        let recentRebuilds = Self.feedPlayerRebuildHistory[mid, default: []].filter { $0 >= rebuildWindowStart }
        guard recentRebuilds.count < Self.maxFeedPlayerRebuildsPerWindow else {
            print("\(logPrefix) ❌ \(reason): rebuild budget exceeded for \(mid) in \(Int(Self.feedPlayerRebuildWindow))s - stopping recovery loop")
            preserveReleaseCoverForCurrentVideo(reason: "\(reason).rebuildBudget", showCover: isVisible)
            restoreCachedPosterForFailureIfNeeded()
            softResetFeedPlayerIfEmpty(player, mid: mid)
            handleVideoLoadFailure(reason: "\(reason) repeated rebuilds")
            return false
        }
        Self.feedPlayerRebuildHistory[mid] = recentRebuilds + [now]

        if firstFeedPlayerRebuildDate == .distantPast ||
            now.timeIntervalSince(firstFeedPlayerRebuildDate) > 45.0 {
            firstFeedPlayerRebuildDate = now
            feedPlayerRebuildCount = 0
        }

        guard feedPlayerRebuildCount < 2 else {
            print("\(logPrefix) ❌ \(reason): rebuild budget exceeded for \(mid) - stopping recovery loop")
            preserveReleaseCoverForCurrentVideo(reason: "\(reason).cellRebuildBudget", showCover: isVisible)
            restoreCachedPosterForFailureIfNeeded()
            softResetFeedPlayerIfEmpty(player, mid: mid)
            handleVideoLoadFailure(reason: "\(reason) repeated rebuilds")
            return false
        }

        feedPlayerRebuildCount += 1
        return true
    }

    private func resetFeedPlayerRebuildBudget() {
        feedPlayerRebuildCount = 0
        firstFeedPlayerRebuildDate = .distantPast
    }

    private func playerHasLoadedData(_ player: AVPlayer) -> Bool {
        guard let item = player.currentItem else { return false }
        if item.status == .readyToPlay { return true }
        return item.loadedTimeRanges.contains { value in
            let duration = CMTimeGetSeconds(value.timeRangeValue.duration)
            return duration.isFinite && duration > 0
        }
    }

    private var currentPlayerHasLoadedData: Bool {
        guard let player else { return false }
        return playerHasLoadedData(player)
    }

    private var currentPlayerCanReplaceCover: Bool {
        guard let player else { return false }
        return playerHasDisplayableFrame(player)
    }

    private func playerHasDisplayableFrame(_ player: AVPlayer) -> Bool {
        guard self.player === player else { return false }
        return videoPlayerView.isShowingPlayer(player) && videoPlayerView.isLayerReadyForDisplay
            || hasRenderedFrameForCurrentPlayer
            || hasRecentDecodedPlayback(for: player, maxAge: 1.0)
    }

    private func softResetFeedPlayerIfEmpty(_ player: AVPlayer, mid: String) {
        if attachment?.type == .hls_video,
           player.currentItem?.status == .unknown,
           playerHasLoadedData(player) {
            print("\(logPrefix) 🔄 Releasing buffered-but-unknown HLS player for \(mid)")
            preserveReleaseCoverForCurrentVideo(reason: "softReset.bufferedUnknownHLS", showCover: isVisible)
            VideoStateCache.shared.clearCachedState(for: mid)
            SharedAssetCache.shared.clearPlayerForMediaID(mid, deleteDiskCache: false)
            LocalHTTPServer.shared.clearCancelledState(for: mid)
            return
        }

        guard !playerHasLoadedData(player) else {
            print("\(logPrefix) ⏳ Keeping buffered player for \(mid) - loaded data exists")
            return
        }
        VideoStateCache.shared.clearCachedState(for: mid)
        preserveReleaseCoverForCurrentVideo(reason: "softReset.emptyPlayer", showCover: isVisible)
        SharedAssetCache.shared.softResetPlayer(for: mid)
    }

    @discardableResult
    private func rebuildCachedFeedPlayer(_ player: AVPlayer, mid: String, reason: String) -> Bool {
        let isBufferedUnknownHLS = attachment?.type == .hls_video
            && player.currentItem?.status == .unknown
            && playerHasLoadedData(player)

        guard !playerHasLoadedData(player) || isBufferedUnknownHLS else {
            print("\(logPrefix) ⏳ \(reason): cached player has loaded data - keeping it")
            return false
        }
        guard !shouldSuppressPositionRestore(for: player, mid: mid) else { return false }
        guard reserveFeedPlayerRebuild(player: player, mid: mid, reason: reason) else { return false }

        let resumeTime = player.currentTime()
        if resumeTime.isValid, resumeTime.seconds.isFinite, resumeTime.seconds > 0.25 {
            pendingRecoverySeekTime = resumeTime
        }

        player.pause()
        VideoStateCache.shared.clearCachedState(for: mid)
        preserveReleaseCoverForCurrentVideo(reason: reason, showCover: isVisible)
        if isBufferedUnknownHLS {
            SharedAssetCache.shared.clearPlayerForMediaID(mid, deleteDiskCache: false)
            LocalHTTPServer.shared.clearCancelledState(for: mid)
        } else {
            SharedAssetCache.shared.softResetPlayer(for: mid)
        }
        return true
    }

    private func acquirePlayerAsync(attachment: MimeiFileType, url: URL, parentTweet: Tweet) {
        guard shouldAcquirePlayer else { return }

        let uniqueURL = buildUniquePlayerURL(url: url, parentTweetId: parentTweet.mid)
        let tweetId = parentTweet.mid
        let mediaType = attachment.type
        // Capture mid so we can detect cell reuse at the landing site.
        let expectedMid = attachment.mid

        setupPlayerTask?.cancel()
        setupPlayerTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try Task.checkCancellation()
                let newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(
                    for: uniqueURL, mediaID: expectedMid, tweetId: tweetId, mediaType: mediaType
                )
                try Task.checkCancellation()

                // Apply mute state immediately after creation
                let muteState = await MainActor.run { MuteState.shared.isMuted }
                newPlayer.isMuted = muteState

                await MainActor.run { [weak self] in
                    guard !Task.isCancelled, let self else { return }
                    // Staleness check: if the cell was reused for a different attachment
                    // while the player was being created, discard the player to avoid
                    // attaching a QmX player to a QmY cell.
                    guard self.attachment?.mid == expectedMid,
                          self.isVisible else {
                        print("\(self.logPrefix) ⚠️ Player for \(expectedMid) arrived after cell reuse — discarding")
                        return
                    }
                    newPlayer.isMuted = MuteState.shared.isMuted
                    self.configurePlayer(newPlayer)
                    self.setupPlayerTask = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                let nsError = error as NSError
                let isCancellation = nsError.code == NSURLErrorCancelled || error is CancellationError
                let isBlacklisted = nsError.domain == "SharedAssetCache" && nsError.code == -2
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard self.isVisible else {
                        self.setupPlayerTask = nil
                        return
                    }
                    if isCancellation {
                        print("\(self.logPrefix) ⚠️ Player creation cancelled")
                        self.setupPlayerTask = nil
                        return
                    }
                    if isBlacklisted {
                        print("\(self.logPrefix) 🚫 Video blacklisted - no retry")
                        self.loadingSpinner.stopAnimating()
                        self.setupPlayerTask = nil
                        if self.imageView.image != nil {
                            self.transitionTo(.thumbnail)
                        } else {
                            self.videoPlayerView.isHidden = true
                            self.videoCellState = .thumbnail
                        }
                        return
                    }
                    let nsErr = error as NSError
                    self.handleVideoLoadFailure(reason: "Player creation failed: \(nsErr.domain) \(nsErr.code)")
                }
            }
        }
    }

    private func buildUniquePlayerURL(url: URL, parentTweetId: String) -> URL {
        let tweetHash = abs(parentTweetId.hashValue) % 10000
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "dig", value: String(tweetHash))]
            return components.url ?? url
        }
        return url
    }

    // MARK: - Player Configuration

    private func configurePlayer(_ newPlayer: AVPlayer) {
        guard (attachment?.mid) != nil else { return }

        preparePlayerForConfiguration(newPlayer)
        registerFirstFrameCallback(newPlayer)
        // KVO BEFORE layer attachment: attachPlayerToLayer may fire onReadyForDisplay
        // synchronously (stale GPU frame), which calls actuallyStartPlayback → player.play()
        // → timeControlStatus changes. Without observers in place, the transition is lost
        // and the spinner from actuallyStartPlayback never stops.
        setupPlayerObservers(newPlayer)
        attachPlayerToLayer(newPlayer)
        removeVideoCoverIfLoadedAndDisplayable(newPlayer, reason: "configure-loadedData")
        handleAlreadyReadyPlayer(newPlayer)
        continueCoordinatorPlaybackAfterConfigurationIfNeeded(newPlayer)
        deferVideoOutputAttachment(newPlayer)
    }

    private func isSurfaceReturnHandoffPlayer(_ player: AVPlayer, mid: String) -> Bool {
        FullScreenVideoManager.shared.currentVideoMid == mid && FullScreenVideoManager.shared.singletonPlayer === player
            || FullScreenVideoManager.shared.isTransferringPlayerToFeed(player, mid: mid)
            || DetailVideoManager.shared.currentVideoMid == mid && DetailVideoManager.shared.currentPlayer === player
            || DetailVideoManager.shared.isTransferringPlayerToFeed(player, mid: mid)
    }

    private func beginLiveHandoffProtection(for player: AVPlayer, mid: String, reason: String) {
        player.currentItem?.cancelPendingSeeks()
        pendingRecoverySeekTime = nil
        liveHandoffPlayer = player
        liveHandoffMid = mid
        liveHandoffSeekSuppressionUntil = Date().addingTimeInterval(4.0)
        VideoSurfaceHandoffRegistry.shared.extendTransfer(mediaID: mid, player: player)
        reconcileReplayButtonWithPlaybackState(for: player, reason: reason)

        let hasRenderableHandoffFrame = isVisibleVideoFrameReady(player)
        if hasRenderableHandoffFrame {
            suppressPrimarySpinnerUntil = Date().addingTimeInterval(3.0)
            cancelDelayedPrimarySpinner()
            loadingSpinner.stopAnimating()
            hasRenderedFrameForCurrentPlayer = true
        } else {
            suppressPrimarySpinnerUntil = .distantPast
        }
        keepLiveHandoffFrameVisibleIfReady(player)
        resetPlaybackProgressTracking(to: player.currentTime())
        logVerbose("🔒 live handoff protection (\(reason)) at \(String(format: "%.2f", player.currentTime().seconds))s")
    }

    private func keepLiveHandoffFrameVisibleIfReady(_ player: AVPlayer) {
        guard videoPlayerView.isShowingPlayer(player),
              videoPlayerView.isLayerReadyForDisplay,
              player.timeControlStatus == .playing || player.rate > 0 else {
            return
        }

        videoPlayerView.isHidden = false
        hideImageViewImmediately()
        hasRenderedFrameForCurrentPlayer = true
        cancelDelayedPrimarySpinner()
        loadingSpinner.stopAnimating()
    }

    private func isLiveSurfaceHandoff(_ player: AVPlayer, mid: String) -> Bool {
        if VideoSurfaceHandoffRegistry.shared.isActiveTransfer(mediaID: mid, player: player) {
            return true
        }

        if isSurfaceReturnHandoffPlayer(player, mid: mid) {
            return true
        }

        return liveHandoffPlayer === player
            && liveHandoffMid == mid
            && Date() <= liveHandoffSeekSuppressionUntil
    }

    private func shouldSuppressPositionRestore(for player: AVPlayer, mid: String) -> Bool {
        isLiveSurfaceHandoff(player, mid: mid)
    }

    @discardableResult
    private func resumeSurfaceReturnHandoffIfNeeded(reason: String) -> Bool {
        guard let mid = attachment?.mid,
              let player,
              isSurfaceReturnHandoffPlayer(player, mid: mid) else {
            return false
        }

        let alreadyProtected = liveHandoffPlayer === player
            && liveHandoffMid == mid
            && Date() <= liveHandoffSeekSuppressionUntil
        if !alreadyProtected {
            beginLiveHandoffProtection(for: player, mid: mid, reason: reason)
        } else {
            pendingRecoverySeekTime = nil
            player.currentItem?.cancelPendingSeeks()
        }

        let layerAlreadyHasPlayer = videoPlayerView.isShowingPlayer(player)
        if window != nil,
           (!alreadyProtected || !layerAlreadyHasPlayer || videoPlayerView.isHidden) {
            liveHandoffLastLayerRefreshAt = Date()
            attachPlayerToLayer(player)
            refreshAfterSharedPlayerItemReplacement(player, reason: reason)
        } else if coordinatorWantsToPlay {
            reconcileReplayButtonWithPlaybackState(for: player, reason: reason)
            player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            applyAVPlayerBufferDefaults(to: player)
            videoPlayerView.isHidden = false
            keepLiveHandoffFrameVisibleIfReady(player)
            if videoCellState != .playing {
                videoCellState = .playing
            }
        }
        return true
    }

    /// Pause, mute, assign player, transition to .playerLoading.
    private func preparePlayerForConfiguration(_ newPlayer: AVPlayer) {
        let previousPlayer = player
        if newPlayer.rate > 0 { newPlayer.pause() }
        newPlayer.isMuted = MuteState.shared.isMuted
        if isVisible {
            newPlayer.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        }
        hasRenderedFrameForCurrentPlayer = false
        didLogFirstDecodedPlayback = false
        didLogFirstPlaybackProgress = false
        resetPlaybackProgressTracking(to: newPlayer.currentTime())
        removePlayerObservers()
        if usesIndependentPlayerInstance, let previousPlayer, previousPlayer !== newPlayer {
            removePlayerTimeObserver()
        }
        self.player = newPlayer
        if usesIndependentPlayerInstance, let previousPlayer, previousPlayer !== newPlayer {
            Self.unregisterIndependentFeedPlayer(owner: self)
            releaseDetachedPlayer(previousPlayer)
        }
        if usesIndependentPlayerInstance, let mid = attachment?.mid {
            Self.registerIndependentFeedPlayer(newPlayer, owner: self, mediaID: mid)
            VideoStateCache.shared.cacheVideoState(
                for: mid,
                player: newPlayer,
                time: newPlayer.currentTime(),
                wasPlaying: newPlayer.rate > 0 || coordinatorWantsToPlay,
                originalMuteState: newPlayer.isMuted
            )
        }
        // Notify other feed cells that may hold the same player (tweet + retweet case)
        // to release their KVO observers. Must post after self.player = newPlayer so that
        // when the notification fires synchronously, this cell is already the owner.
        if let mid = attachment?.mid, !usesIndependentPlayerInstance {
            NotificationCenter.default.post(
                name: .videoPlayerClaimedByCell,
                object: nil,
                userInfo: ["videoMid": mid, "claimerIdentity": ObjectIdentifier(self).hashValue]
            )
        }
        // Pick up a real playback cover only after this visible cell has actually
        // rendered playback, or when the frame was decoded by off-screen preload.
        // Saved resume time alone should not create a cover.
        if imageView.image == nil, let mid = attachment?.mid,
           canShowCachedCoverForCurrentVideo,
           let cached = SharedAssetCache.shared.cachedThumbnail(for: mid) {
            imageView.image = cached
        }
        transitionTo(.playerLoading)
    }

    /// Register onReadyForDisplay callback for first-frame capture and state transition.
    private func registerFirstFrameCallback(_ newPlayer: AVPlayer) {
        videoPlayerView.onReadyForDisplay = { [weak self] in
            guard let self else { return }
            self.hasRenderedFrameForCurrentPlayer = true
            if let player = self.player {
                self.removeVideoCoverIfLoadedAndDisplayable(player, reason: "onReadyForDisplay-firstFrame")
            }
            // Defer capture by one run-loop cycle: isReadyForDisplay fires before
            // the GPU composites the frame into the layer's backing store.
            // If a generated/cached cover is already visible, replace it with the
            // actual decoded player frame so the later cover→video handoff matches.
            if self.imageView.image != nil || self.hasPlaybackCoverForCurrentVideo {
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.hasPlaybackCoverForCurrentVideo else { return }
                    self.capturePlayerFrameAsCoverIfPossible()
                    // Re-transition to update imageView visibility now that a thumbnail exists.
                    if self.videoCellState == .playerLoading || self.videoCellState == .playerReady {
                        self.transitionTo(self.videoCellState)
                    }
                }
            }

            if self.videoCellState == .playerLoading {
                self.transitionTo(.playerReady)
            }

            if let player = self.player {
                self.removeVideoCoverIfLoadedAndDisplayable(player, reason: "onReadyForDisplay")
                self.updateLoadingSpinnerForPlayback(player)
                if self.isVisibleVideoFrameReady(player),
                   self.videoCellState == .playing || self.videoCellState == .playerReady {
                    self.fadeOutVideoCoverForPlayback()
                }
            }

            // If coordinator already told us to play, attempt now — covers the case
            // where KVO fired before onReadyForDisplay (or didn't fire for preloaded players).
            if self.coordinatorWantsToPlay, let player = self.player {
                self.logVerbose("🖼️ onReadyForDisplay: coordinatorWants=true, calling requestPlayback")
                self.requestPlaybackStartIfNeeded(player, reason: "onReadyForDisplay-coordinatorWaiting")
            } else {
                // Notify coordinator — video is ready. If idle, start; if primary is
                // stuck (not actually playing), reset and pick a new primary.
                self.logVerbose("🖼️ onReadyForDisplay: coordinatorWants=false, checking stall")
                (self.videoCoordinator ?? .shared).requestStartPlaybackIfStalled()
            }
        }
    }

    /// Attach player to the AVPlayerLayer, suppressing implicit CALayer animations.
    private func attachPlayerToLayer(_ newPlayer: AVPlayer) {
        guard !videoPlayerView.isShowingPlayer(newPlayer) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoPlayerView.setPlayer(newPlayer)
        CATransaction.commit()
    }

    /// If item is already readyToPlay (cached player or returning from fullscreen), play or seek immediately.
    private func handleAlreadyReadyPlayer(_ newPlayer: AVPlayer) {
        guard let item = newPlayer.currentItem, item.status == .readyToPlay else { return }

        // onReadyForDisplay may have fired synchronously during attachPlayerToLayer (stale GPU
        // frame from the previous video) and already called actuallyStartPlayback, setting
        // videoCellState = .playing.  Regressing back to .playerReady here would:
        //   1. Re-show the spinner unnecessarily (transitionTo(.playerReady) shows it when
        //      coordinatorWantsToPlay=true), creating a window where the spinner is visible
        //      even though the video is already playing.
        //   2. Set isRecentlyPlaying = false (it requires videoCellState == .playing), leaving
        //      the coordinator's 5-second grace period unprotected for a newly-started video.
        // Skip the state regression; proceed to requestPlaybackStartIfNeeded for volume/timer
        // side-effects (rate>0 branch won't call actuallyStartPlayback again).
        if videoCellState != .playing {
            transitionTo(.playerReady)
        }

        removeVideoCoverIfLoadedAndDisplayable(newPlayer, reason: "alreadyReady")
        settleForegroundCachedPlayerIfReady(newPlayer, reason: "alreadyReady")

        if coordinatorWantsToPlay {
            if isVideoAtEnd(newPlayer, tolerance: 5.0) {
                newPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    guard let self, self.coordinatorWantsToPlay, let player = self.player else { return }
                    self.requestPlaybackStartIfNeeded(player, reason: "alreadyReady-seekToStart")
                }
            } else {
                requestPlaybackStartIfNeeded(newPlayer, reason: "alreadyReady")
            }
        } else {
            // Seek to force AVPlayerLayer to decode a frame for the thumbnail.
            // Prefer the saved resume position so the thumbnail shows where the user left off,
            // and so a coordinator play command arriving moments later finds the player already
            // at the right position (avoids the race where a pending 0.01s seek overrides play).
            videoPlayerView.observeReadyForDisplay()
            let mid = attachment?.mid ?? ""
            if !shouldSuppressPositionRestore(for: newPlayer, mid: mid) {
                let seekTarget = savedFeedResumeTime(for: mid, player: newPlayer)
                    ?? CMTime(seconds: 0.01, preferredTimescale: 600)
                newPlayer.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    /// If the coordinator selected this cell before its cached/preloaded player attached,
    /// the original play command may have found no ready item to kick. HLS/proxy players can
    /// then stay in `.unknown` while paused, leaving the selected first visible video on a
    /// permanent spinner. Once the player is attached, honor the existing coordinator intent.
    private func continueCoordinatorPlaybackAfterConfigurationIfNeeded(_ newPlayer: AVPlayer) {
        guard coordinatorWantsToPlay,
              isVisible,
              player === newPlayer,
              !isActuallyPlayerReady(newPlayer) else { return }

        if newPlayer.currentItem?.status == .unknown {
            newPlayer.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            actuallyStartPlayback(newPlayer)
        } else {
            requestPlaybackStartIfNeeded(newPlayer, reason: "configuredNotReady-coordinatorWaiting")
        }
    }

    /// Defer video output attachment to next run-loop cycle.
    private func deferVideoOutputAttachment(_ newPlayer: AVPlayer) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === newPlayer else { return }
            self.ensureVideoOutputAttached(for: newPlayer)
        }
    }

    private func attachSharedPlayerForHandoff(_ newPlayer: AVPlayer, reason: String) {
        if let mid = attachment?.mid, isSurfaceReturnHandoffPlayer(newPlayer, mid: mid) {
            beginLiveHandoffProtection(for: newPlayer, mid: mid, reason: reason)
        }

        if player !== newPlayer {
            removePlayerTimeObserver()
            removePlayerObservers()
            player = newPlayer
            newPlayer.isMuted = MuteState.shared.isMuted
            if imageView.image == nil, let mid = attachment?.mid,
               let cached = SharedAssetCache.shared.cachedThumbnail(for: mid) {
                imageView.image = cached
                showImageView()
            }

            if let mid = attachment?.mid, !usesIndependentPlayerInstance {
                NotificationCenter.default.post(
                    name: .videoPlayerClaimedByCell,
                    object: nil,
                    userInfo: ["videoMid": mid, "claimerIdentity": ObjectIdentifier(self).hashValue]
                )
            }
            registerFirstFrameCallback(newPlayer)
            attachPlayerToLayer(newPlayer)
        } else if !videoPlayerView.isShowingPlayer(newPlayer) || videoPlayerView.isHidden {
            attachPlayerToLayer(newPlayer)
        }

        refreshAfterSharedPlayerItemReplacement(newPlayer, reason: reason)
    }

    private func refreshAfterSharedPlayerItemReplacement(_ player: AVPlayer, reason: String) {
        guard self.player === player else { return }
        guard let item = player.currentItem else {
            detachSharedPlayerReference(reason: "\(reason).nilItem")
            return
        }

        item.canUseNetworkResourcesForLiveStreamingWhilePaused = isVisible || coordinatorWantsToPlay
        setupPlayerObservers(player)
        ensureVideoOutputAttached(for: player)
        resetPlaybackProgressTracking(to: player.currentTime())
        if playerHasLoadedData(player),
           videoPlayerView.isLayerReadyForDisplay || hasRenderedFrameForCurrentPlayer {
            hasRenderedFrameForCurrentPlayer = true
            removeVideoCoverIfLoadedAndDisplayable(player, reason: "sharedItemRefresh-\(reason)")
        } else if let mid = attachment?.mid,
                  !shouldSuppressPositionRestore(for: player, mid: mid) {
            restoreCachedPosterForFailureIfNeeded()
        }
        logVerbose("🔁 refreshed shared item after \(reason): status=\(item.status.rawValue), coordWants=\(coordinatorWantsToPlay), state=\(videoCellState)")

        if coordinatorWantsToPlay {
            requestPlaybackStartIfNeeded(player, reason: "sharedItemRefresh-\(reason)")
        } else if item.status == .readyToPlay {
            if videoCellState == .playerLoading {
                transitionTo(.playerReady)
            } else {
                updateLoadingSpinnerForPlayback(player)
            }
        } else if isVisible && videoCellState == .noContent {
            transitionTo(imageView.image == nil ? .noContent : .thumbnail)
        }
    }

    private func detachSharedPlayerReference(reason: String) {
        logVerbose("🔁 detached shared player after \(reason)")
        cancelDelayedPrimarySpinner()
        playbackStartupRecoveryTask?.cancel()
        playbackStartupRecoveryTask = nil
        playbackStartupRecoveryRequestDate = nil
        playbackStartupRecoveryDelay = nil
        slowLoadingRecoveryTask?.cancel()
        slowLoadingRecoveryTask = nil
        playbackProgressWatchdogTask?.cancel()
        playbackProgressWatchdogTask = nil
        statusUnknownFallbackTask?.cancel()
        statusUnknownFallbackTask = nil
        removePlayerTimeObserver()
        removePlayerObservers()
        videoPlayerView.setPlayer(nil)
        player = nil
        coordinatorWantsToPlay = false
        loadingSpinner.stopAnimating()
        restoreCachedPosterForFailureIfNeeded()
        transitionTo(imageView.image != nil ? .thumbnail : .noContent)
    }

    /// Canonical readiness check from AVPlayerItem status.
    private func isActuallyPlayerReady(_ player: AVPlayer?) -> Bool {
        guard let status = player?.currentItem?.status else { return false }
        return status == .readyToPlay
    }

    private func hasVisiblePlaybackProgress(for player: AVPlayer) -> Bool {
        guard lastPlaybackRequestDate != .distantPast else { return !coordinatorWantsToPlay }
        guard let mid = attachment?.mid,
              let decodedTime = VideoPlaybackSessionStore.shared.trustedVisibleTime(
                for: mid,
                beforeOrAt: player.currentTime()
              ) else { return false }
        return seconds(from: decodedTime) + 0.25 >= lastPlaybackRequestPositionSeconds
    }

    /// A video is visually ready only once playback has started, the layer can
    /// display frames, and the playback clock has moved since the play request.
    private func isVisibleVideoFrameReady(_ player: AVPlayer) -> Bool {
        guard player.timeControlStatus == .playing,
              videoPlayerView.isLayerReadyForDisplay else { return false }

        // Cached players can report .playing while AVPlayerLayer is still showing
        // the previous still frame. Keep loading feedback until time actually moves.
        return hasVisiblePlaybackProgress(for: player)
    }

    /// Keep the spinner up until the user can actually see moving video content.
    private func updateLoadingSpinnerForPlayback(_ player: AVPlayer) {
        if shouldShowPrimarySpinner(for: player) {
            showPrimarySpinnerAfterDebounce(for: player)
        } else {
            cancelDelayedPrimarySpinner()
            loadingSpinner.stopAnimating()
        }
    }

    private func shouldShowPrimarySpinner(for player: AVPlayer? = nil) -> Bool {
        guard coordinatorWantsToPlay else { return false }
        if Date() < suppressPrimarySpinnerUntil {
            if let player {
                if isVisibleVideoFrameReady(player) {
                    return false
                }
            } else if hasRenderedFrameForCurrentPlayer && videoPlayerView.isLayerReadyForDisplay {
                return false
            }
        }
        guard let player else { return true }
        return !isVideoAtEnd(player) && !isVisibleVideoFrameReady(player)
    }

    private func shouldDebouncePrimarySpinner(for player: AVPlayer? = nil) -> Bool {
        // Primary feed spinners should always get one short grace window. AVPlayer can
        // report a cached/ready player before the layer displays moving frames; the
        // delayed re-check below prevents flicker without hiding genuine stalls.
        guard coordinatorWantsToPlay else { return false }

        if let player {
            if lastActualPlaybackDate != .distantPast,
               player.timeControlStatus != .playing {
                return false
            }
            return !isVideoAtEnd(player)
        }

        return true
    }

    private func showPrimarySpinnerAfterDebounce(for player: AVPlayer? = nil) {
        guard shouldShowPrimarySpinner(for: player) else {
            cancelDelayedPrimarySpinner()
            loadingSpinner.stopAnimating()
            return
        }

        guard shouldDebouncePrimarySpinner(for: player) else {
            cancelDelayedPrimarySpinner()
            loadingSpinner.startAnimating()
            return
        }

        if loadingSpinner.isAnimating {
            return
        }

        if delayedPrimarySpinnerTask != nil {
            return
        }

        cancelDelayedPrimarySpinner()
        delayedPrimarySpinnerTask = Task { @MainActor [weak self, player] in
            try? await Task.sleep(nanoseconds: self?.primarySpinnerDebounceNanos ?? 500_000_000)
            guard let self,
                  self.coordinatorWantsToPlay else {
                self?.delayedPrimarySpinnerTask = nil
                return
            }
            let currentPlayer = player ?? self.player
            if let currentPlayer {
                if let player {
                    guard self.player === player else {
                        self.delayedPrimarySpinnerTask = nil
                        return
                    }
                }
                guard self.shouldShowPrimarySpinner(for: currentPlayer) else {
                    self.delayedPrimarySpinnerTask = nil
                    return
                }
            } else {
                guard self.shouldShowPrimarySpinner() else {
                    self.delayedPrimarySpinnerTask = nil
                    return
                }
            }
            self.delayedPrimarySpinnerTask = nil
            self.loadingSpinner.startAnimating()
        }
    }

    private func cancelDelayedPrimarySpinner() {
        delayedPrimarySpinnerTask?.cancel()
        delayedPrimarySpinnerTask = nil
    }

    private func bufferedTimeAhead(for player: AVPlayer) -> Double {
        guard let item = player.currentItem else { return 0 }
        let currentSeconds = seconds(from: player.currentTime())
        guard currentSeconds.isFinite else { return 0 }

        var bestBufferAhead: Double = 0
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = seconds(from: range.start)
            let duration = seconds(from: range.duration)
            let end = start + duration
            if currentSeconds >= start && currentSeconds <= end {
                return max(0, end - currentSeconds)
            } else if end > currentSeconds {
                bestBufferAhead = max(bestBufferAhead, end - currentSeconds)
            }
        }
        return max(0, bestBufferAhead)
    }

    private func applyAVPlayerBufferDefaults(to player: AVPlayer) {
        if Date() >= startupBufferReleaseUntil {
            player.automaticallyWaitsToMinimizeStalling = true
        }
        player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        // Let AVPlayer pick its own forward buffer. Our job is intent/ownership;
        // micromanaging buffer duration fights AVPlayer's stall recovery.
        player.currentItem?.preferredForwardBufferDuration = 0
    }

    private func noteBufferingWaitIfNeeded(for player: AVPlayer, reason: String) {
        guard coordinatorWantsToPlay,
              lastActualPlaybackDate != .distantPast,
              !isVideoAtEnd(player) else { return }

        let playbackPosition = seconds(from: player.currentTime())
        let positionBucket = Int(playbackPosition.rounded(.down))
        let now = Date()
        if positionBucket == lastBufferingWaitPositionBucket,
           now.timeIntervalSince(lastBufferingWaitDate) < 2.0 {
            return
        }

        bufferingWaitCount = min(bufferingWaitCount + 1, 4)
        lastBufferingWaitDate = now
        lastBufferingWaitPositionBucket = positionBucket
        applyAVPlayerBufferDefaults(to: player)

        let logKey = "\(reason)|\(bufferingWaitCount)"
        if logKey != lastBufferingWaitLogKey || now.timeIntervalSince(lastBufferingWaitLogDate) >= 8.0 {
            print("\(logPrefix) ⏳ buffering wait (\(reason)): pos=\(String(format: "%.1f", playbackPosition))s, stall=\(bufferingWaitCount)")
            lastBufferingWaitLogKey = logKey
            lastBufferingWaitLogDate = now
        }
    }

    private func seconds(from time: CMTime) -> Double {
        let value = CMTimeGetSeconds(time)
        return value.isFinite ? value : 0
    }

    private func timeControlLogBucket(for seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        let bucket = (seconds * 10).rounded()
        guard bucket.isFinite else { return 0 }
        if bucket > Double(Int.max) { return Int.max }
        if bucket < Double(Int.min) { return Int.min }
        return Int(bucket)
    }

    /// Keep loading presentation and slow-load observation alive while AVPlayer
    /// is waiting. Do not issue extra play/seek commands here; AVPlayer owns buffering.
    private func monitorPlaybackIfWaiting(_ player: AVPlayer, reason: String) {
        guard coordinatorWantsToPlay,
              canDriveForegroundPlayback,
              player.currentItem?.status == .readyToPlay,
              player.timeControlStatus != .playing,
              !isVideoAtEnd(player) else { return }

        applyAVPlayerBufferDefaults(to: player)
        updateLoadingSpinnerForPlayback(player)
        if let mid = attachment?.mid,
           isLiveSurfaceHandoff(player, mid: mid) {
            return
        }
        if releaseStartupBufferIfReady(player, bufferedAhead: bufferedTimeAhead(for: player), reason: reason) {
            return
        }
        scheduleStartupRecovery(for: player, reason: reason)
    }

    private func scheduleStartupRecovery(for player: AVPlayer, reason: String) {
        if let mid = attachment?.mid,
           isLiveSurfaceHandoff(player, mid: mid) {
            return
        }

        let requestDate = lastPlaybackRequestDate
        let requestPosition = player.currentTime()
        let requestSeconds = seconds(from: requestPosition)
        let isStartupAttempt = lastActualPlaybackDate == .distantPast && requestSeconds < 8.0
        let isResumeWaitAttempt = lastActualPlaybackDate == .distantPast &&
            requestSeconds >= 0.25 &&
            player.currentItem?.status == .readyToPlay &&
            player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let isSlowLoadingNudgeFollowUp = reason.hasPrefix("slowLoading")
        let isHLSWaitFollowUp = reason.hasPrefix("activeHLSSegment-")
            || reason.hasPrefix("emptyHLSWait-")
        let recoveryDelay: UInt64
        if isHLSWaitFollowUp {
            recoveryDelay = 2_000_000_000
        } else if isSlowLoadingNudgeFollowUp {
            recoveryDelay = Self.slowLoadingNudgeIntervalNanos
        } else if isResumeWaitAttempt {
            recoveryDelay = 4_000_000_000
        } else {
            recoveryDelay = isStartupAttempt ? 5_000_000_000 : 15_000_000_000
        }
        if playbackStartupRecoveryTask != nil,
           playbackStartupRecoveryRequestDate == requestDate,
           let existingDelay = playbackStartupRecoveryDelay,
           existingDelay <= recoveryDelay {
            return
        }

        playbackStartupRecoveryTask?.cancel()
        playbackStartupRecoveryRequestDate = requestDate
        playbackStartupRecoveryDelay = recoveryDelay

        playbackStartupRecoveryTask = Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(nanoseconds: recoveryDelay)
            guard let self else { return }
            defer {
                if self.playbackStartupRecoveryRequestDate == requestDate {
                    self.playbackStartupRecoveryTask = nil
                    self.playbackStartupRecoveryRequestDate = nil
                    self.playbackStartupRecoveryDelay = nil
                }
            }
            guard !Task.isCancelled,
                  let player,
                  self.player === player,
                  self.coordinatorWantsToPlay,
                  self.canDriveForegroundPlayback,
                  self.videoCellState == .playing,
                  self.lastPlaybackRequestDate == requestDate,
                  !self.isVideoAtEnd(player) else { return }

            guard !self.fullscreenOverlayOwnsCurrentVideo else { return }

            if self.isVisibleVideoFrameReady(player) {
                self.updateLoadingSpinnerForPlayback(player)
                return
            }

            let label = isStartupAttempt ? "startup watchdog" : "playback watchdog"
            let now = Date()
            let bufferedAhead = self.bufferedTimeAhead(for: player)
            let status = player.currentItem?.status.rawValue ?? -1
            let recoverySeconds = self.seconds(from: player.currentTime())
            if now.timeIntervalSince(self.lastSlowLoadWaitLogDate) >= 10.0 {
                print("\(self.logPrefix) ⏳ \(label) (\(reason)): still waiting, keeping AVPlayer alive, pos=\(String(format: "%.1f", recoverySeconds))s, buffered=\(String(format: "%.1f", bufferedAhead))s, itemStatus=\(status), timeControl=\(player.timeControlStatus.rawValue)")
                self.lastSlowLoadWaitLogDate = now
            }

            if self.releaseStartupBufferIfReady(player, bufferedAhead: bufferedAhead, reason: reason) {
                return
            }

            if self.waitForActiveHLSDownloadsIfNeeded(player, bufferedAhead: bufferedAhead, reason: "\(label)-\(reason)") {
                return
            }

            if self.rebuildEmptyWaitingHLSPrimaryIfRecoverable(player, bufferedAhead: bufferedAhead, reason: "\(label)-\(reason)") {
                return
            }

            if self.failUnbufferedUnknownPrimaryIfTimedOut(player, bufferedAhead: bufferedAhead, reason: "\(label)-\(reason)") {
                return
            }

            if self.rebuildUnknownPrimaryIfRecoverable(player, bufferedAhead: bufferedAhead, reason: "\(label)-\(reason)") {
                return
            }

            if self.rebuildStarvedReadyPrimaryIfRecoverable(player, bufferedAhead: bufferedAhead, reason: "\(label)-\(reason)") {
                return
            }

            if self.nudgeSlowLoadingPrimaryIfUseful(player, bufferedAhead: bufferedAhead, reason: "\(label)-\(reason)") {
                return
            }

            self.applyAVPlayerBufferDefaults(to: player)
            self.updateLoadingSpinnerForPlayback(player)
            self.scheduleStartupRecoveryAfterCurrentTask(for: player, reason: "slowLoadingWatchdog-\(reason)")
        }
    }

    private func scheduleStartupRecoveryAfterCurrentTask(for player: AVPlayer, reason: String) {
        let requestDate = lastPlaybackRequestDate
        Task { @MainActor [weak self, weak player] in
            await Task.yield()
            guard let self,
                  let player,
                  self.player === player,
                  self.lastPlaybackRequestDate == requestDate,
                  self.coordinatorWantsToPlay,
                  self.canDriveForegroundPlayback,
                  self.videoCellState == .playing,
                  !self.isVideoAtEnd(player) else { return }

            self.scheduleStartupRecovery(for: player, reason: reason)
        }
    }

    @discardableResult
    private func releaseStartupBufferIfReady(_ player: AVPlayer, bufferedAhead: Double, reason: String) -> Bool {
        guard coordinatorWantsToPlay,
              canDriveForegroundPlayback,
              videoCellState == .playing,
              player.currentItem?.status == .readyToPlay,
              player.timeControlStatus != .playing,
              !isVideoAtEnd(player) else { return false }

        let now = Date()
        let currentSeconds = seconds(from: player.currentTime())
        let isStartup = lastActualPlaybackDate == .distantPast && currentSeconds < 1.0
        let hasNoRecentProgress = lastPlaybackProgressDate == .distantPast
            || now.timeIntervalSince(lastPlaybackProgressDate) >= 2.0
        let isStalledResume = lastActualPlaybackDate != .distantPast && hasNoRecentProgress
        let keepUp = player.currentItem?.isPlaybackLikelyToKeepUp ?? false
        let requiredBuffer: Double
        if attachment?.type == .video {
            requiredBuffer = keepUp ? 0.5 : 0.75
        } else if keepUp {
            requiredBuffer = 0.75
        } else if isStartup {
            requiredBuffer = 2.0
        } else {
            requiredBuffer = 2.5
        }
        let hasUsableBuffer = bufferedAhead >= requiredBuffer
        guard hasUsableBuffer else { return false }

        startupBufferReleaseUntil = now.addingTimeInterval(6.0)
        player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        player.currentItem?.preferredForwardBufferDuration = 0
        player.automaticallyWaitsToMinimizeStalling = false
        lastPlaybackRequestDate = now
        resetPlaybackProgressTracking(to: player.currentTime())
        player.play()
        updateLoadingSpinnerForPlayback(player)

        if now.timeIntervalSince(lastStartupBufferReleaseDate) >= 2.0 {
            lastStartupBufferReleaseDate = now
            let label: String
            if isStartup {
                label = "startup buffer ready"
            } else if isStalledResume {
                label = "resume buffer ready"
            } else {
                label = "primary buffer ready"
            }
            print("\(logPrefix) ▶️ \(label) (\(reason)): nudging playback, pos=\(String(format: "%.1f", currentSeconds))s, buffered=\(String(format: "%.1f", bufferedAhead))s, required=\(String(format: "%.1f", requiredBuffer))s, keepUp=\(keepUp)")
        }
        return true
    }

    @discardableResult
    private func rebuildCurrentFeedPlayerFromProxyCache(
        mid: String,
        reacquireReason: String,
        transitionState: VideoCellState? = nil
    ) -> Bool {
        preserveReleaseCoverForCurrentVideo(reason: reacquireReason, showCover: isVisible)
        VideoStateCache.shared.clearCachedState(for: mid)
        SharedAssetCache.shared.clearPlayerForMediaID(mid, deleteDiskCache: false)
        LocalHTTPServer.shared.clearCancelledState(for: mid)
        LocalHTTPServer.shared.setPrimaryMediaID(mid)
        return reacquirePlayerForCurrentVideo(
            reason: reacquireReason,
            transitionState: transitionState,
            requireLoadableVisibleVideo: true,
            wantsPlayback: true
        )
    }

    @discardableResult
    private func waitForActiveHLSDownloadsIfNeeded(_ player: AVPlayer, bufferedAhead: Double, reason: String) -> Bool {
        guard attachment?.type == .hls_video,
              player.currentItem?.status == .unknown,
              bufferedAhead < 0.25,
              let mid = attachment?.mid,
              LocalHTTPServer.shared.hasActiveHLSSegmentDownloads(for: mid) else { return false }

        if LocalHTTPServer.shared.hasCachedActiveHLSSegment(for: mid) {
            guard reserveFeedPlayerRebuild(player: player, mid: mid, reason: reason) else { return true }
            hlsEmptyWaitingStartDate = .distantPast
            preserveReleaseCoverForCurrentVideo(reason: reason, showCover: isVisible)
            restoreCachedPosterForFailureIfNeeded()
            print("\(logPrefix) 🔄 \(reason): HLS segment is cached but current item stayed empty — rebuilding feed player from proxy cache")
            return rebuildCurrentFeedPlayerFromProxyCache(
                mid: mid,
                reacquireReason: "cachedActiveHLSSegmentRecovery",
                transitionState: imageView.image != nil ? .thumbnail : .playerLoading
            )
        }

        let activeSegments = LocalHTTPServer.shared.activeHLSSegmentKeys(for: mid)
        let segmentLabel = activeSegments.isEmpty ? "segment" : activeSegments.joined(separator: ",")
        notePrimaryPlaybackIntentWhileWaiting(player)
        hlsEmptyWaitingStartDate = .distantPast
        let now = Date()
        if hlsActiveSegmentWaitMediaID != mid || hlsActiveSegmentWaitStartDate == .distantPast {
            hlsActiveSegmentWaitMediaID = mid
            hlsActiveSegmentWaitStartDate = now
        }
        let activeWaitSeconds = now.timeIntervalSince(hlsActiveSegmentWaitStartDate)

        if activeWaitSeconds >= Self.activeHLSSegmentStartupTimeout {
            guard reserveFeedPlayerRebuild(player: player, mid: mid, reason: reason) else { return true }
            hlsActiveSegmentWaitStartDate = .distantPast
            hlsActiveSegmentWaitMediaID = nil
            preserveReleaseCoverForCurrentVideo(reason: reason, showCover: isVisible)
            restoreCachedPosterForFailureIfNeeded()
            LocalHTTPServer.shared.resumeVisibleDownloads(for: mid)
            print("\(logPrefix) 🔄 \(reason): HLS active segment download still pending after \(String(format: "%.1f", activeWaitSeconds))s (\(segmentLabel)) — rebuilding feed player while preserving downloads")
            return rebuildCurrentFeedPlayerFromProxyCache(
                mid: mid,
                reacquireReason: "activeHLSSegmentTimeoutRecovery",
                transitionState: imageView.image != nil ? .thumbnail : .playerLoading
            )
        }

        player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        player.currentItem?.preferredForwardBufferDuration = 0
        player.automaticallyWaitsToMinimizeStalling = true
        updateLoadingSpinnerForPlayback(player)
        print("\(logPrefix) ⏳ \(reason): HLS item still .unknown with no buffered data, waiting for active download: \(segmentLabel)")
        let recoveryReason = normalizedRecoveryReason(prefix: "activeHLSSegment-", reason: reason)
        scheduleStartupRecoveryAfterCurrentTask(for: player, reason: recoveryReason)
        return true
    }

    private func normalizedRecoveryReason(prefix: String, reason: String) -> String {
        if let range = reason.range(of: prefix) {
            return prefix + String(reason[range.upperBound...])
        }
        return prefix + reason
    }

    private func progressWatchdogReason(after reason: String) -> String {
        let prefix = "progressWatchdog-"
        var base = reason
        while base.hasPrefix(prefix) {
            base.removeFirst(prefix.count)
        }
        return prefix + base
    }

    private func notePrimaryPlaybackIntentWhileWaiting(_ player: AVPlayer) {
        guard coordinatorWantsToPlay,
              canDriveForegroundPlayback,
              !isVideoAtEnd(player) else { return }

        if lastPlaybackRequestDate == .distantPast {
            lastPlaybackRequestDate = Date()
            resetPlaybackProgressTracking(to: player.currentTime())
        }

        if videoCellState != .playing {
            transitionTo(.playing)
        } else {
            showPrimarySpinnerAfterDebounce(for: player)
        }
        applyAVPlayerBufferDefaults(to: player)
        player.isMuted = MuteState.shared.isMuted
        if player.rate == 0 {
            player.play()
        }
        retryButton.isHidden = true
    }

    @discardableResult
    private func nudgeSlowLoadingPrimaryIfUseful(_ player: AVPlayer, bufferedAhead: Double, reason: String) -> Bool {
        guard coordinatorWantsToPlay,
              canDriveForegroundPlayback,
              videoCellState == .playing,
              let item = player.currentItem,
              item.status != .failed,
              !isVideoAtEnd(player),
              let mid = attachment?.mid else { return false }
        guard !shouldSuppressPositionRestore(for: player, mid: mid) else { return false }

        let now = Date()
        guard now.timeIntervalSince(lastSlowLoadingNudgeDate) >= Self.slowLoadingNudgeInterval else { return false }
        guard !isVisibleVideoFrameReady(player) else { return false }

        if waitForActiveHLSDownloadsIfNeeded(player, bufferedAhead: bufferedAhead, reason: reason) {
            lastSlowLoadingNudgeDate = now
            return true
        }

        let hasSomethingWorthKeeping = playerHasLoadedData(player)
            || bufferedAhead > 0
            || hasPlaybackCoverForCurrentVideo
            || SharedAssetCache.shared.cachedThumbnail(for: mid) != nil
            || hasEstablishedDecodedPlayback(for: player)

        if hasSomethingWorthKeeping {
            preserveFrameToCache(skipImageView: imageView.image != nil)
            restoreCachedPosterForFailureIfNeeded()
        }
        applyAVPlayerBufferDefaults(to: player)
        showPrimarySpinnerAfterDebounce(for: player)
        lastSlowLoadingNudgeDate = now

        let currentSeconds = seconds(from: player.currentTime())
        if attachment?.type == .hls_video,
           lastActualPlaybackDate == .distantPast,
           !hasEstablishedDecodedPlayback(for: player),
           currentSeconds > 0.25 {
            clearFeedResumeState(for: mid)
            print("\(logPrefix) 🔄 \(reason): cold HLS player stuck at \(String(format: "%.1f", currentSeconds))s before decoded playback — seeking to start")
            player.currentItem?.cancelPendingSeeks()
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
                DispatchQueue.main.async {
                    guard let self,
                          let player,
                          self.player === player,
                          self.coordinatorWantsToPlay,
                          self.canDriveForegroundPlayback,
                          !self.isVideoAtEnd(player) else { return }
                    self.applyAVPlayerBufferDefaults(to: player)
                    self.resetPlaybackProgressTracking(to: .zero)
                    player.play()
                    self.updateLoadingSpinnerForPlayback(player)
                    self.scheduleStartupRecovery(for: player, reason: "coldHLSSeekToStart-\(reason)")
                }
            }
            return true
        }
        print("\(logPrefix) ⏳ \(reason): slow-loading nudge, keeping player, cover=\(hasSomethingWorthKeeping), pos=\(String(format: "%.1f", currentSeconds))s, buffered=\(String(format: "%.1f", bufferedAhead))s, itemStatus=\(item.status.rawValue), timeControl=\(player.timeControlStatus.rawValue)")

        if attachment?.type == .video {
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            player.automaticallyWaitsToMinimizeStalling = true
            if player.rate == 0 {
                player.play()
            }
            updateLoadingSpinnerForPlayback(player)
            return true
        }

        player.pause()
        slowLoadingRecoveryTask?.cancel()
        slowLoadingRecoveryTask = Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self else { return }
            defer { self.slowLoadingRecoveryTask = nil }
            guard !Task.isCancelled,
                  let player,
                  self.player === player,
                  self.coordinatorWantsToPlay,
                  self.canDriveForegroundPlayback,
                  !self.isVideoAtEnd(player) else { return }

            self.applyAVPlayerBufferDefaults(to: player)
            self.resetPlaybackProgressTracking(to: player.currentTime())
            player.play()
            self.updateLoadingSpinnerForPlayback(player)
            self.scheduleStartupRecovery(for: player, reason: "slowLoadingNudge-\(reason)")
        }

        return true
    }

    @discardableResult
    private func rebuildUnknownPrimaryIfRecoverable(_ player: AVPlayer, bufferedAhead: Double, reason: String) -> Bool {
        guard coordinatorWantsToPlay,
              videoCellState == .playing,
              player.currentItem?.status == .unknown,
              bufferedAhead >= 1.0,
              !isVideoAtEnd(player),
              let mid = attachment?.mid else { return false }
        guard !shouldSuppressPositionRestore(for: player, mid: mid) else { return false }

        if attachment?.type == .hls_video {
            let now = Date()
            let hasDecodedPlayback = hasEstablishedDecodedPlayback(for: player)
                || lastActualPlaybackDate != .distantPast
            let hasBufferedUnknownNoFrame = !hasDecodedPlayback
                && !isVisibleVideoFrameReady(player)
                && bufferedAhead >= 2.0

            if hasBufferedUnknownNoFrame {
                if hlsBufferedUnknownStartDate == .distantPast {
                    hlsBufferedUnknownStartDate = now
                }
            } else {
                hlsBufferedUnknownStartDate = .distantPast
            }

            let bufferedUnknownRebuildDelay: TimeInterval = bufferedAhead >= 6.0 ? 2.0 : 4.0
            let waitedForBufferedUnknown = hlsBufferedUnknownStartDate != .distantPast
                && now.timeIntervalSince(hlsBufferedUnknownStartDate) >= bufferedUnknownRebuildDelay

            if hasBufferedUnknownNoFrame,
               waitedForBufferedUnknown {
                if let resumeTime = trustedRecoverySeekTime(for: player),
                   resumeTime.isValid,
                   resumeTime.seconds.isFinite {
                    pendingRecoverySeekTime = resumeTime
                }

                guard reserveFeedPlayerRebuild(player: player, mid: mid, reason: reason) else { return true }

                hlsBufferedUnknownStartDate = .distantPast
                preserveReleaseCoverForCurrentVideo(reason: reason, showCover: isVisible)
                restoreCachedPosterForFailureIfNeeded()
                print("\(logPrefix) 🔄 \(reason): HLS item stayed .unknown with \(String(format: "%.1f", bufferedAhead))s buffered and no decoded frame — rebuilding feed player from proxy cache")
                return rebuildCurrentFeedPlayerFromProxyCache(
                    mid: mid,
                    reacquireReason: "unknownHLSBufferedStartupRecovery",
                    transitionState: imageView.image != nil ? .thumbnail : .playerLoading
                )
            }

            player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            player.currentItem?.preferredForwardBufferDuration = 0
            player.automaticallyWaitsToMinimizeStalling = true
            lastPlaybackRequestDate = Date()
            resetPlaybackProgressTracking(to: player.currentTime())
            player.play()
            updateLoadingSpinnerForPlayback(player)
            print("\(logPrefix) ⏳ \(reason): HLS item still .unknown with \(String(format: "%.1f", bufferedAhead))s buffered — waiting briefly before rebuild")
            return true
        }

        if attachment?.type == .video {
            notePrimaryPlaybackIntentWhileWaiting(player)
            applyAVPlayerBufferDefaults(to: player)
            player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            if player.rate == 0 {
                player.play()
            }
            updateLoadingSpinnerForPlayback(player)
            if Date().timeIntervalSince(lastSlowLoadWaitLogDate) >= 10.0 {
                print("\(logPrefix) ⏳ \(reason): progressive item still .unknown with \(String(format: "%.1f", bufferedAhead))s buffered — keeping existing AVPlayer")
                lastSlowLoadWaitLogDate = Date()
            }
            scheduleStartupRecoveryAfterCurrentTask(
                for: player,
                reason: normalizedRecoveryReason(prefix: "progressiveUnknownWait-", reason: reason)
            )
            return true
        }

        // If playback has already shown real progress, do not tear down the
        // visible layer. Rebuilding at that point causes frames -> black -> reload.
        guard lastActualPlaybackDate == .distantPast else {
            player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            player.currentItem?.preferredForwardBufferDuration = 0
            player.automaticallyWaitsToMinimizeStalling = true
            lastPlaybackRequestDate = Date()
            resetPlaybackProgressTracking(to: player.currentTime())
            player.play()
            updateLoadingSpinnerForPlayback(player)
            print("\(logPrefix) ⏳ \(reason): item still .unknown with \(String(format: "%.1f", bufferedAhead))s buffered after playback — keeping existing player")
            return true
        }

        if let resumeTime = trustedRecoverySeekTime(for: player),
           resumeTime.isValid,
           resumeTime.seconds.isFinite {
            pendingRecoverySeekTime = resumeTime
        }

        guard reserveFeedPlayerRebuild(player: player, mid: mid, reason: reason) else { return true }

        print("\(logPrefix) 🔄 \(reason): item stayed .unknown with \(String(format: "%.1f", bufferedAhead))s buffered before playback — rebuilding feed player")
        return rebuildCurrentFeedPlayerFromProxyCache(
            mid: mid,
            reacquireReason: "unknownItemBufferedStartupRecovery",
            transitionState: imageView.image != nil ? .thumbnail : .playerLoading
        )
    }

    @discardableResult
    private func rebuildEmptyWaitingHLSPrimaryIfRecoverable(_ player: AVPlayer, bufferedAhead: Double, reason: String) -> Bool {
        guard coordinatorWantsToPlay,
              canDriveForegroundPlayback,
              videoCellState == .playing,
              attachment?.type == .hls_video,
              let item = player.currentItem,
              item.status == .unknown,
              bufferedAhead < 0.25,
              !isVideoAtEnd(player),
              let mid = attachment?.mid else { return false }
        guard !shouldSuppressPositionRestore(for: player, mid: mid) else { return false }

        if LocalHTTPServer.shared.hasActiveHLSSegmentDownloads(for: mid) {
            return waitForActiveHLSDownloadsIfNeeded(player, bufferedAhead: bufferedAhead, reason: reason)
        }

        let isEmptyWaiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            || item.isPlaybackBufferEmpty
            || !item.isPlaybackLikelyToKeepUp
        guard isEmptyWaiting, !playerHasLoadedData(player) else {
            hlsEmptyWaitingStartDate = .distantPast
            return false
        }

        notePrimaryPlaybackIntentWhileWaiting(player)
        let now = Date()
        if hlsEmptyWaitingStartDate == .distantPast {
            hlsEmptyWaitingStartDate = now
            applyAVPlayerBufferDefaults(to: player)
            updateLoadingSpinnerForPlayback(player)
            print("\(logPrefix) ⏳ \(reason): HLS item still empty after downloads went idle — rechecking shortly")
            scheduleStartupRecoveryAfterCurrentTask(
                for: player,
                reason: normalizedRecoveryReason(prefix: "emptyHLSWait-", reason: reason)
            )
            return true
        }

        guard now.timeIntervalSince(hlsEmptyWaitingStartDate) >= 2.0 else {
            applyAVPlayerBufferDefaults(to: player)
            updateLoadingSpinnerForPlayback(player)
            scheduleStartupRecoveryAfterCurrentTask(
                for: player,
                reason: normalizedRecoveryReason(prefix: "emptyHLSWait-", reason: reason)
            )
            return true
        }

        if let resumeTime = trustedRecoverySeekTime(for: player),
           resumeTime.isValid,
           resumeTime.seconds.isFinite {
            pendingRecoverySeekTime = resumeTime
        }

        guard reserveFeedPlayerRebuild(player: player, mid: mid, reason: reason) else {
            hlsEmptyWaitingStartDate = .distantPast
            return true
        }

        hlsEmptyWaitingStartDate = .distantPast
        preserveReleaseCoverForCurrentVideo(reason: reason, showCover: isVisible)
        restoreCachedPosterForFailureIfNeeded()
        print("\(logPrefix) 🔄 \(reason): HLS primary stayed empty with no active segment downloads — rebuilding feed player from proxy cache")
        return rebuildCurrentFeedPlayerFromProxyCache(
            mid: mid,
            reacquireReason: "emptyWaitingHLSStartupRecovery",
            transitionState: imageView.image != nil ? .thumbnail : .playerLoading
        )
    }

    @discardableResult
    private func rebuildStarvedReadyPrimaryIfRecoverable(_ player: AVPlayer, bufferedAhead: Double, reason: String) -> Bool {
        guard coordinatorWantsToPlay,
              videoCellState == .playing,
              player.currentItem?.status == .readyToPlay,
              player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
              bufferedAhead < 0.5,
              !isVideoAtEnd(player),
              let mid = attachment?.mid else { return false }
        guard !shouldSuppressPositionRestore(for: player, mid: mid) else { return false }

        let now = Date()
        let hasDecodedPlaybackHistory = hasEstablishedDecodedPlayback(for: player)
            || lastActualPlaybackDate != .distantPast
            || lastPlaybackProgressDate != .distantPast
            || lastDecodedPlaybackProgressDate != .distantPast
        let hasPlaybackHistory = hasDecodedPlaybackHistory
            || hasPlaybackCoverForCurrentVideo
        let noRecentPlaybackProgress = lastPlaybackProgressDate == .distantPast
            || now.timeIntervalSince(lastPlaybackProgressDate) >= 20.0
        let noRecentDecodedProgress = !hasRecentDecodedPlayback(for: player, maxAge: 20.0)
        let coldReadyStarved = !hasDecodedPlaybackHistory
            && lastPlaybackRequestDate != .distantPast
            && noRecentDecodedProgress
        let coldReadyWaitSeconds: TimeInterval = attachment?.type == .video ? 6.0 : 15.0
        let hlsReadyStarved = attachment?.type == .hls_video
            && coldReadyStarved
            && !LocalHTTPServer.shared.hasActiveHLSSegmentDownloads(for: mid)
        let hlsReadyStarvedWaitSeconds: TimeInterval = 6.0
        let waitedLongWithCover = hasPlaybackHistory
            && lastPlaybackRequestDate != .distantPast
            && now.timeIntervalSince(lastPlaybackRequestDate) >= 45.0
            && noRecentPlaybackProgress
            && noRecentDecodedProgress
        let waitedForColdStart = coldReadyStarved
            && now.timeIntervalSince(lastPlaybackRequestDate) >= (hlsReadyStarved ? hlsReadyStarvedWaitSeconds : coldReadyWaitSeconds)
            && noRecentPlaybackProgress

        if coldReadyStarved,
           !waitedForColdStart {
            notePrimaryPlaybackIntentWhileWaiting(player)
            applyAVPlayerBufferDefaults(to: player)
            updateLoadingSpinnerForPlayback(player)
            if player.rate == 0 {
                player.play()
            }
            if now.timeIntervalSince(lastSlowLoadWaitLogDate) >= 10.0 {
                let waited = now.timeIntervalSince(lastPlaybackRequestDate)
                print("\(logPrefix) ⏳ \(reason): cold ready item has \(String(format: "%.1f", bufferedAhead))s buffered after \(String(format: "%.1f", waited))s — keeping existing player")
                lastSlowLoadWaitLogDate = now
            }
            scheduleStartupRecoveryAfterCurrentTask(
                for: player,
                reason: normalizedRecoveryReason(prefix: "readyStarvedColdWait-", reason: reason)
            )
            return true
        }

        guard waitedForColdStart
            || waitedLongWithCover else { return false }

        if attachment?.type == .video {
            notePrimaryPlaybackIntentWhileWaiting(player)
            applyAVPlayerBufferDefaults(to: player)
            player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            if player.rate == 0 {
                player.play()
            }
            updateLoadingSpinnerForPlayback(player)
            if now.timeIntervalSince(lastSlowLoadWaitLogDate) >= 10.0 {
                print("\(logPrefix) ⏳ \(reason): progressive ready item is starved; keeping existing AVPlayer")
                lastSlowLoadWaitLogDate = now
            }
            scheduleStartupRecoveryAfterCurrentTask(
                for: player,
                reason: normalizedRecoveryReason(prefix: "readyProgressiveWait-", reason: reason)
            )
            return true
        }

        if waitedForColdStart,
           !hasDecodedPlaybackHistory {
            if let resumeTime = trustedRecoverySeekTime(for: player),
               resumeTime.isValid,
               resumeTime.seconds.isFinite {
                pendingRecoverySeekTime = resumeTime
            }

            guard reserveFeedPlayerRebuild(player: player, mid: mid, reason: reason) else { return true }

            print("\(logPrefix) 🔄 \(reason): ready item stayed starved with \(String(format: "%.1f", bufferedAhead))s buffered before decoded playback — rebuilding feed player from proxy cache")
            return rebuildCurrentFeedPlayerFromProxyCache(
                mid: mid,
                reacquireReason: "readyStarvedStartupRecovery",
                transitionState: imageView.image != nil ? .thumbnail : .playerLoading
            )
        }

        if waitedLongWithCover {
            let currentTime = player.currentTime()
            if let resumeTime = trustedRecoverySeekTime(for: player) ?? (currentTime.seconds.isFinite && currentTime.seconds > 0.25 ? currentTime : nil),
               resumeTime.isValid,
               resumeTime.seconds.isFinite {
                pendingRecoverySeekTime = resumeTime
            }

            guard reserveFeedPlayerRebuild(player: player, mid: mid, reason: reason) else { return true }

            print("\(logPrefix) 🔄 \(reason): ready item stalled at \(String(format: "%.1f", seconds(from: player.currentTime())))s with \(String(format: "%.1f", bufferedAhead))s buffered — rebuilding feed player from proxy cache")
            return rebuildCurrentFeedPlayerFromProxyCache(
                mid: mid,
                reacquireReason: "readyStarvedPlaybackRecovery",
                transitionState: imageView.image != nil ? .thumbnail : .playerLoading
            )
        }

        return false
    }

    @discardableResult
    private func failUnbufferedUnknownPrimaryIfTimedOut(_ player: AVPlayer, bufferedAhead: Double, reason: String) -> Bool {
        guard coordinatorWantsToPlay,
              canDriveForegroundPlayback,
              videoCellState == .playing,
              player.currentItem?.status == .unknown,
              bufferedAhead < 0.25,
              lastActualPlaybackDate == .distantPast,
              lastPlaybackRequestDate != .distantPast,
              Date().timeIntervalSince(lastPlaybackRequestDate) >= 30.0,
              !isVisibleVideoFrameReady(player),
              !isVideoAtEnd(player) else { return false }

        if attachment?.type == .hls_video,
           let mid = attachment?.mid,
           LocalHTTPServer.shared.hasActiveHLSSegmentDownloads(for: mid) {
            waitForActiveHLSDownloadsIfNeeded(player, bufferedAhead: bufferedAhead, reason: reason)
            return true
        }

        if attachment?.type == .video {
            notePrimaryPlaybackIntentWhileWaiting(player)
            applyAVPlayerBufferDefaults(to: player)
            player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            if player.rate == 0 {
                player.play()
            }
            updateLoadingSpinnerForPlayback(player)
            if Date().timeIntervalSince(lastSlowLoadWaitLogDate) >= 10.0 {
                print("\(logPrefix) ⏳ \(reason): progressive item still .unknown with no buffered data — keeping existing AVPlayer")
                lastSlowLoadWaitLogDate = Date()
            }
            scheduleStartupRecoveryAfterCurrentTask(
                for: player,
                reason: normalizedRecoveryReason(prefix: "progressiveUnknownWait-", reason: reason)
            )
            return true
        }

        print("\(logPrefix) ❌ \(reason): item stayed .unknown with no buffered data - moving to next video")
        handleVideoLoadFailure(reason: "\(reason) unknown item timed out")
        return true
    }

    private func scheduleStillFrameRecovery(for player: AVPlayer, reason: String) {
        updateLoadingSpinnerForPlayback(player)
        scheduleStartupRecovery(for: player, reason: reason)
    }

    /// Queue extra work for the next first-frame event without discarding an existing callback.
    private func addReadyForDisplayAction(_ action: @escaping () -> Void) {
        let existingAction = videoPlayerView.onReadyForDisplay
        videoPlayerView.onReadyForDisplay = {
            existingAction?()
            action()
        }
        videoPlayerView.observeReadyForDisplay()
    }


    // MARK: - Coordinator Command Handlers

    private func currentVideoContext(
        requireLoadableVisibleVideo: Bool = false
    ) -> (attachment: MimeiFileType, url: URL, parentTweet: Tweet)? {
        if requireLoadableVisibleVideo {
            guard isVisible, shouldAcquirePlayer else { return nil }
        }
        guard isVideoAttachment,
              let attachment,
              let url = attachment.getUrl(effectiveBaseUrl),
              let parentTweet else {
            return nil
        }
        return (attachment, url, parentTweet)
    }

    @discardableResult
    private func reacquirePlayerForCurrentVideo(
        reason: String,
        clearCachedPlayer: Bool = false,
        transitionState: VideoCellState? = nil,
        requireLoadableVisibleVideo: Bool = false,
        runFullSetup: Bool = false,
        wantsPlayback: Bool = true
    ) -> Bool {
        guard !deferVideoWorkUntilInfrastructureReady(reason: reason, wantsPlayback: wantsPlayback) else {
            return true
        }
        guard let context = currentVideoContext(requireLoadableVisibleVideo: requireLoadableVisibleVideo) else {
            return false
        }

        let mid = context.attachment.mid
        if clearCachedPlayer {
            preserveReleaseCoverForCurrentVideo(reason: "\(reason).clearCachedPlayer", showCover: isVisible)
            SharedAssetCache.shared.clearPlayerForMediaID(mid, deleteDiskCache: false)
            LocalHTTPServer.shared.clearCancelledState(for: mid)
            LocalHTTPServer.shared.setPrimaryMediaID(mid)
        }

        if runFullSetup {
            setupVideoCell(attachment: context.attachment, url: context.url, parentTweet: context.parentTweet)
            if wantsPlayback {
                coordinatorWantsToPlay = true
            }
            return true
        }

        cleanupVideoPlayer(reason: reason)
        if wantsPlayback {
            coordinatorWantsToPlay = true
        }
        let restoredRecoveryPoster = restoreForegroundRecoveryPosterIfNeeded(reason: reason)
        if let transitionState {
            let resolvedState: VideoCellState
            if restoredRecoveryPoster, transitionState == .noContent {
                resolvedState = wantsPlayback ? .playerLoading : .thumbnail
            } else {
                resolvedState = transitionState
            }
            transitionTo(resolvedState)
        } else if restoredRecoveryPoster, wantsPlayback {
            transitionTo(.playerLoading)
        }
        acquirePlayer(attachment: context.attachment, url: context.url, parentTweet: context.parentTweet)
        return true
    }

    private func handleCoordinatorPlayCommand() {
        guard let mid = attachment?.mid else { return }

        let hasPlayer = player != nil
        let itemStatus = player?.currentItem?.status.rawValue ?? -1
        let rate = player?.rate ?? -1
        logVerbose("🎬 shouldPlayVideo: state=\(videoCellState), hasPlayer=\(hasPlayer), itemStatus=\(itemStatus), rate=\(rate)")

        isHandlingFinishEvent = false
        VideoStateCache.shared.clearStoppedByCoordinator(mid)
        coordinatorWantsToPlay = true
        replayButton.isHidden = true
        restoreForegroundRecoveryPosterIfNeeded(reason: "coordinatorPlay")

        let returningPlayer: AVPlayer? = {
            if let player, isLiveSurfaceHandoff(player, mid: mid) {
                return player
            }
            if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: mid),
               cachedPlayer.currentItem != nil,
               isLiveSurfaceHandoff(cachedPlayer, mid: mid) {
                return cachedPlayer
            }
            return nil
        }()

        if let returningPlayer {
            beginLiveHandoffProtection(for: returningPlayer, mid: mid, reason: "coordinatorPlay")
            if player !== returningPlayer {
                attachSharedPlayerForHandoff(returningPlayer, reason: "coordinatorPlay-liveHandoff")
            } else {
                videoPlayerView.isHidden = false
                if videoCellState != .playing {
                    videoCellState = .playing
                }
            }
            requestPlaybackStartIfNeeded(returningPlayer, reason: "coordinatorPlay-liveHandoff")
            return
        }

        restoreVisibleLoadingStateIfNeeded(reason: "coordinatorPlay")

        // A foreground-visible primary should autoplay even if it finished before
        // backgrounding. Treat an explicit coordinator play as replay intent.
        if let id = videoIdentifier, VideoStateCache.shared.isVideoFinished(id) {
            VideoStateCache.shared.clearVideoFinished(id)
            clearFeedResumeState(for: mid)
            replayButton.isHidden = true
            if let player, isActuallyPlayerReady(player) {
                cancelDelayedPrimarySpinner()
                loadingSpinner.stopAnimating()
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    guard let self, self.coordinatorWantsToPlay, let player = self.player else { return }
                    self.requestPlaybackStartIfNeeded(player, reason: "coordinatorPlay-finishedReplay")
                }
                return
            }
        }

        // A video that finished, left the viewport, and came back should autoplay
        // from the already-cached player instead of being treated as a stall at end.
        if let player = player,
           isActuallyPlayerReady(player),
           isVideoAtEnd(player, tolerance: 5.0) {
            cancelDelayedPrimarySpinner()
            loadingSpinner.stopAnimating()
            clearFeedResumeState(for: mid)
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self, self.coordinatorWantsToPlay, let player = self.player else { return }
                self.requestPlaybackStartIfNeeded(player, reason: "coordinatorPlay-replayAfterReturn")
            }
            return
        }

        // If the layer already has a frame AND item is actually ready, play immediately.
        // If item is not ready (stale .playerReady state), fall through to re-acquire.
        if let player = player, videoCellState == .playerReady {
            if isActuallyPlayerReady(player) {
                // Re-evaluate spinner: coordinatorWantsToPlay is now true, so
                // transitionTo(.playerReady) will show the spinner while buffering.
                transitionTo(.playerReady)
                requestPlaybackStartIfNeeded(player, reason: "coordinatorPlay-playerReady")
                return
            }
            // Item not ready despite .playerReady state — show spinner and fall through
            // to the main logic which handles re-acquisition.
            transitionTo(.playerLoading)
        }

        // If already in playing state, resume if stalled (rate==0) and return.
        if let player = player, videoCellState == .playing {
            if player.timeControlStatus == .playing {
                return
            }
            requestPlaybackStartIfNeeded(player, reason: "coordinatorPlay-resumePlayingState")
            return
        }

        // If video is in failed state, always clean up and retry regardless of player health.
        // Buffering timeout transitions to .failed but preserves the player — simply calling
        // play() on the same player won't fix the underlying network issue.
        if videoCellState == .failed {
            print("\(logPrefix) 🔄 Coordinator play on failed video - cleaning up and retrying")
            retryButton.isHidden = true
            _ = reacquirePlayerForCurrentVideo(
                reason: "coordinatorPlay.failedStateRetry",
                clearCachedPlayer: true,
                transitionState: imageView.image != nil ? .playerLoading : .noContent
            )
            return
        }

        // If player not ready, let KVO trigger play when ready
        guard let player = player, isActuallyPlayerReady(player) else {

            // Show loading state whenever primary and not yet playing.
            // IMPORTANT: do not downgrade .playerReady back to .playerLoading;
            // that causes unnecessary spinner loops on partially loaded videos.
            if videoCellState == .noContent || videoCellState == .thumbnail || videoCellState == .playerLoading {
                transitionTo(.playerLoading)
            }

            // Background memory release keeps the AVPlayer shell in visible cells but
            // strips its currentItem. Treat that as missing, otherwise foreground
            // coordinator play gets stuck on a black/loading layer forever.
            if let existingPlayer = self.player,
               existingPlayer.currentItem == nil || !existingPlayer.currentTime().seconds.isFinite {
                print("\(logPrefix) 🔄 Coordinator play found released player shell - reacquiring")
                _ = reacquirePlayerForCurrentVideo(
                    reason: "coordinatorPlay.releasedPlayerShell",
                    transitionState: imageView.image != nil ? .thumbnail : .playerLoading,
                    requireLoadableVisibleVideo: true
                )
                return
            }

            // Trigger player setup if needed.
            // Guard against re-triggering when setupPlayerTask is already in flight —
            // doing so would cancel the in-flight creation and start a duplicate one,
            // causing multiple AVPlayers for the same mediaID during fast scroll.
            if self.player == nil,
               setupPlayerTask == nil,
               let context = currentVideoContext(requireLoadableVisibleVideo: true) {
                acquirePlayer(
                    attachment: context.attachment,
                    url: context.url,
                    parentTweet: context.parentTweet
                )
            } else if let player = self.player, player.currentItem?.status == .unknown {
                // DEADLOCK FIX: Paused player created with
                // canUseNetworkResourcesForLiveStreamingWhilePaused=false (SharedAssetCache
                // default) can't fetch HLS data while paused → item.status stays .unknown
                // forever → requestPlaybackStartIfNeeded blocks → permanent spinner.
                // Enable network and play() to kick AVPlayer into requesting segments.
                // Segments are on the proxy's disk cache → data arrives instantly.
                player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
                actuallyStartPlayback(player)
            }

            return
        }

        // Validate player health — after background, currentItem may have been stripped
        // while cell was not visible during foreground recovery.
        if player.currentItem == nil || player.currentTime().seconds.isNaN {
            _ = reacquirePlayerForCurrentVideo(
                reason: "coordinatorPlay.invalidPlayerHealth",
                runFullSetup: true
            )
            return
        }

        // If near the end (within 5s), restart from the beginning rather than resuming
        // at an awkward near-end position. Videos that finished naturally are already
        // gated above by the finishedVideoIdentifiers check.
        if isVideoAtEnd(player, tolerance: 5.0) {
            VideoStateCache.shared.clearCachedState(for: mid)
            clearFeedResumeState(for: mid)
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self, self.coordinatorWantsToPlay, let player = self.player else { return }
                self.requestPlaybackStartIfNeeded(player, reason: "coordinatorPlay-seekToStart")
            }
            return
        }

        // Player is ready — play
        requestPlaybackStartIfNeeded(player, reason: "coordinatorPlay-ready")
    }

    private func handleCoordinatorPauseCommand() {
        guard let mid = attachment?.mid else { return }
        coordinatorWantsToPlay = false

        if let player = player {
            if player.rate > 0 {
                saveCurrentPosition(player: player, wasPlaying: true)
            }
            captureLastFrameIfPossible(reason: "coordinatorPause")
            refreshVisualStateAfterCoordinatorStopped()
            // Volume fade-out then pause
            UIView.animate(withDuration: 0.2, animations: {
                player.volume = 0
            }, completion: { _ in
                player.pause()
            })
        } else {
            refreshVisualStateAfterCoordinatorStopped()
        }
        VideoStateCache.shared.markAsStoppedByCoordinator(mid)
    }

    private func handleCoordinatorStopCommand() {
        guard let mid = attachment?.mid else { return }
        coordinatorWantsToPlay = false

        if let player = player {
            if player.rate > 0 {
                saveCurrentPosition(player: player, wasPlaying: true)
            }
            captureLastFrameIfPossible(reason: "coordinatorStop")

            if !isActuallyPlayerReady(player) && videoCellState == .playerLoading {
                if !isVisible {
                    // Cell is off-screen — release player to free network resources
                    // instead of waiting for the coordinator's stall timer.
                    preserveReleaseCoverForCurrentVideo(reason: "coordinatorStop.offscreen", showCover: false)
                    removePlayerObservers()
                    SharedAssetCache.shared.clearPlayerForMediaID(mid, deleteDiskCache: false)
                    self.player = nil
                    setupPlayerTask = nil
                    if imageView.image != nil {
                        transitionTo(.thumbnail)
                    } else {
                        transitionTo(.noContent)
                        loadingSpinner.stopAnimating()
                    }
                } else {
                    // Cell is still visible but no longer primary.
                    // Keep the player so it can finish loading and show a preview frame.
                    // Re-evaluate spinner: coordinatorWantsToPlay is now false.
                    transitionTo(.playerLoading)
                    player.pause()
                }
            } else if videoCellState == .playing {
                if !isHandlingFinishEvent {
                    transitionTo(.paused)
                }
                player.pause()
            } else if videoCellState == .playerReady {
                // Re-evaluate spinner: coordinatorWantsToPlay is now false.
                transitionTo(.playerReady)
                player.pause()
            } else {
                refreshVisualStateAfterCoordinatorStopped()
                player.pause()
            }
        } else {
            refreshVisualStateAfterCoordinatorStopped()
        }
        VideoStateCache.shared.markAsStoppedByCoordinator(mid)
    }

    private func handleStopAllVideos() {
        guard isVideoAttachment else { return }
        coordinatorWantsToPlay = false

        if let player = player {
            if player.rate > 0 {
                saveCurrentPosition(player: player, wasPlaying: true)
            }
            captureLastFrameIfPossible(reason: "stopAllVideos")
            // When video finished naturally, keep AVPlayerLayer showing the last
            // rendered frame — don't reveal the lower-res imageView thumbnail.
            if videoCellState == .playing && !isHandlingFinishEvent {
                transitionTo(.paused)
            }
            player.pause()
            player.isMuted = MuteState.shared.isMuted
        }
    }

    /// Re-evaluate chrome after this cell is no longer the autoplay primary.
    /// Visible non-primary videos may keep loading to produce a cover, but once
    /// a poster/frame exists their spinner must stop even if playback is paused.
    private func refreshVisualStateAfterCoordinatorStopped() {
        cancelDelayedPrimarySpinner()
        switch videoCellState {
        case .playing:
            if !isHandlingFinishEvent {
                transitionTo(.paused)
            }
        case .noContent, .thumbnail, .playerLoading, .playerReady, .paused:
            transitionTo(videoCellState)
        case .failed:
            break
        }
    }

    // MARK: - Playback

    private func playWithVolumeFadeIn(_ player: AVPlayer) {
        guard let mid = attachment?.mid else { return }

        if shouldSuppressPositionRestore(for: player, mid: mid) {
            pendingRecoverySeekTime = nil
            startPlaybackWithFade(player)
            return
        }

        if let recoveryTime = pendingRecoverySeekTime,
           recoveryTime.seconds.isFinite,
           recoveryTime.seconds > 0.25 {
            pendingRecoverySeekTime = nil
            updateLoadingSpinnerForPlayback(player)
            player.seek(to: recoveryTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard self.attachment?.mid == mid else { return }
                    self.logVerbose("🔄 recovery seek restored \(String(format: "%.1f", recoveryTime.seconds))s")
                    self.startPlaybackWithFade(player)
                }
            }
            return
        }

        // Resume from saved position.
        // Always seek even when player.currentTime() already reports the target — a pending
        // async seek to 0.01s (issued by handleAlreadyReadyPlayer for thumbnail decoding) can
        // race against play() and snap the position back to near-zero after play is called.
        // Issuing a new seek here cancels that pending seek and guarantees the correct start.
        if let resumeTime = feedResumeSeekTargetIfNeeded(for: mid, player: player) {
            pendingRecoverySeekTime = nil
            updateLoadingSpinnerForPlayback(player)
            player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard let self, let _ = self.attachment?.mid else { return }
                self.startPlaybackWithFade(player)
            }
            return
        }

        startPlaybackWithFade(player)
    }

    /// Start playback if coordinator wants to play and player isn't already playing.
    private func requestPlaybackStartIfNeeded(_ player: AVPlayer, reason: String) {
        guard canDriveForegroundPlayback else {
            _ = deferVideoWorkUntilInfrastructureReady(reason: "requestPlayback.\(reason)", wantsPlayback: true)
            logVerbose("⏸️ requestPlayback(\(reason)): skipped, app/infrastructure not ready")
            return
        }
        guard coordinatorWantsToPlay else {
            logVerbose("⏸️ requestPlayback(\(reason)): skipped, coordinatorWantsToPlay=false")
            return
        }
        guard isVisible else {
            logVerbose("👻 requestPlayback(\(reason)): skipped, cell not visible")
            return
        }
        // Guard against premature play() when onReadyForDisplay fires from a stale GPU frame
        // (fast-recovery player reuse) while item.status is still .unknown. Calling play()
        // on a player with disabled network (canUseNetworkResourcesForLiveStreamingWhilePaused
        // =false) disrupts AVPlayer's buffering state machine and prevents statusKVO
        // .readyToPlay from ever firing. The coordinator's play command bypasses this guard
        // by enabling network + calling actuallyStartPlayback() directly.
        guard isActuallyPlayerReady(player) else {
            let itemStatus = player.currentItem?.status
            logVerbose("⏸️ requestPlayback(\(reason)): item not ready (status=\(itemStatus?.rawValue ?? -1)), deferring to statusKVO")
            // If item is in a terminal failure state or has no currentItem, statusKVO will
            // never fire .readyToPlay. Clean up and re-acquire instead of spinning forever.
            if itemStatus == .failed || player.currentItem == nil {
                print("\(logPrefix) 🔄 Item terminal — cleaning up for re-acquisition")
                _ = reacquirePlayerForCurrentVideo(
                    reason: "requestPlayback.terminalItem",
                    clearCachedPlayer: true
                )
                return
            }
            // Primary loading feedback is debounced so cached/quick starts don't flash.
            showPrimarySpinnerAfterDebounce(for: player)

            // FALLBACK: A paused HLS player with canUseNetworkResourcesForLiveStreamingWhilePaused=false
            // may never transition item.status from .unknown → .readyToPlay, causing a permanent spinner.
            // Schedule a delayed check: if status is still .unknown after 2s, enable network and play().
            // This is the same fix as the deadlock code in handleCoordinatorPlayCommand (line ~988).
            if itemStatus == .unknown {
                statusUnknownFallbackTask?.cancel()
                statusUnknownFallbackTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                    guard !Task.isCancelled, let self,
                          let player = self.player,
                          self.coordinatorWantsToPlay,
                          self.canDriveForegroundPlayback,
                          !self.fullscreenOverlayOwnsCurrentVideo,
                          player.currentItem?.status == .unknown else { return }
                    if self.waitForActiveHLSDownloadsIfNeeded(
                        player,
                        bufferedAhead: self.bufferedTimeAhead(for: player),
                        reason: "statusKVO fallback"
                    ) {
                        return
                    }
                    print("\(self.logPrefix) ⏰ statusKVO fallback: item still .unknown after 2s, enabling network + play")
                    player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
                    self.actuallyStartPlayback(player)
                }
            }
            return
        }

        logVerbose("▶️ requestPlayback(\(reason)): rate=\(player.rate), timeControl=\(player.timeControlStatus.rawValue), state=\(videoCellState)")
        removeVideoCoverIfLoadedAndDisplayable(player, reason: "requestPlayback-\(reason)")
        let isLiveHandoff: Bool
        if let mid = attachment?.mid {
            isLiveHandoff = isLiveSurfaceHandoff(player, mid: mid)
        } else {
            isLiveHandoff = false
        }

        if player.rate > 0 {
            lastPlaybackRequestDate = Date()
            resetPlaybackProgressTracking(to: player.currentTime())
            // Already told to play — sync UI state.
            videoPlayerView.isHidden = false
            if videoCellState != .playing {
                logVerbose("State: \(videoCellState) → playing")
                videoCellState = .playing
            }
            // Only stop spinner if actually rendering frames. rate > 0 just means
            // play() was called; the player may still be buffering (timeControlStatus
            // == .waitingToPlayAtSpecifiedRate) with no frames to show.
            updateLoadingSpinnerForPlayback(player)
            retryButton.isHidden = true
            applyAVPlayerBufferDefaults(to: player)
            player.isMuted = MuteState.shared.isMuted
            player.volume = 1.0
            if isSingleMedia, let mid = attachment?.mid {
                setupVideoTimer(videoMid: mid)
            }
            startPlayerTimeObserver()
            if isLiveHandoff {
                applyAVPlayerBufferDefaults(to: player)
            } else if player.timeControlStatus != .playing {
                monitorPlaybackIfWaiting(player, reason: "\(reason)-rateAlreadyPositive")
            } else {
                scheduleStillFrameRecovery(for: player, reason: "\(reason)-rateAlreadyPositive")
            }
            return
        }

        playWithVolumeFadeIn(player)
    }

    private func startPlaybackWithFade(_ player: AVPlayer) {
        // No deferral needed: actuallyStartPlayback() removes stale cover art as
        // soon as the attached player has displayable content.
        actuallyStartPlayback(player)
    }

    private func actuallyStartPlayback(_ player: AVPlayer) {
        guard let mid = attachment?.mid else { return }
        guard canDriveForegroundPlayback else {
            _ = deferVideoWorkUntilInfrastructureReady(reason: "actuallyStartPlayback", wantsPlayback: true)
            logVerbose("⏸️ actuallyStartPlayback skipped, app/infrastructure not ready")
            return
        }
        guard !fullscreenOverlayOwnsCurrentVideo else {
            logVerbose("⏸️ actuallyStartPlayback skipped, fullscreen owns current video")
            return
        }

        // Show player layer (may have been hidden for non-primary .playerReady)
        videoPlayerView.isHidden = false

        // Update state directly — skip transitionTo() to avoid touching imageView.
        // If the layer already has content from preload/cache, remove the cover
        // before play() so playback does not flash through a stale thumbnail.
        if videoCellState != .playing {
            logVerbose("State: \(videoCellState) → playing")
        }
        videoCellState = .playing
        retryButton.isHidden = true

        _ = removeVideoCoverIfLoadedAndDisplayable(player, reason: "actuallyStartPlayback")

        // Show loading feedback only if playback does not become visibly active
        // within the debounce window. Cached videos can still need a short moment
        // to attach/render after becoming primary, so schedule the same re-check.
        showPrimarySpinnerAfterDebounce(for: player)

        // Primary playback must own network recovery. Preloaded players may be
        // paused with background-friendly settings, so restore AVPlayer's normal
        // stall handling before issuing play().
        applyAVPlayerBufferDefaults(to: player)
        player.isMuted = MuteState.shared.isMuted
        lastPlaybackRequestDate = Date()
        resetPlaybackProgressTracking(to: player.currentTime())
        startPlayerTimeObserver()
        let isLiveHandoff = isLiveSurfaceHandoff(player, mid: mid)
        playPlayerWithResumeIfNeeded(player, reason: "actuallyStartPlayback") { [weak self] player in
            guard let self else { return }
            guard !isLiveHandoff else { return }
            self.scheduleStartupRecovery(for: player, reason: "actuallyStartPlayback")
            self.scheduleStillFrameRecovery(for: player, reason: "actuallyStartPlayback")
            self.schedulePlaybackProgressWatchdog(for: player, reason: "actuallyStartPlayback")
        }

        // Show timer when playback starts
        if isSingleMedia {
            setupVideoTimer(videoMid: mid)
        }
    }


    // MARK: - Frame Capture

    private func ensureVideoOutputAttached(for player: AVPlayer) {
        guard isVideoAttachment else { return }
        guard let item = player.currentItem else { return }

        // Already attached to this item
        if videoOutputAttachedItem === item, videoOutput != nil { return }

        // Detach from previous item
        if let previousItem = videoOutputAttachedItem, let existingOutput = videoOutput {
            previousItem.remove(existingOutput)
        }

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        item.add(output)
        videoOutput = output
        videoOutputAttachedItem = item
    }

    /// Unified frame capture: tries up to 4 sources in priority order for temporary cover rendering.
    /// Returns `true` if a usable frame was obtained (captured fresh or restored from cached media thumbnail).
    ///
    /// Priority order:
    /// 1. If `imageView.image` already set → save to cache → return true
    /// 2. Video output (AVPlayerItemVideoOutput) — highest quality, requires readyToPlay
    /// 3. Layer snapshot (UIGraphicsImageRenderer) — works before readyToPlay
    /// 4. Cached-media thumbnail fallback (SharedAssetCache) → restore into imageView → return true
    ///
    /// - Parameters:
    ///   - useVideoOutput: Set `false` for stuck players (status unknown) where video output won't work.
    ///   - async: Set `true` only for periodic captures during playback to avoid main-thread hitch.
    ///   - skipImageView: Set `true` when capturing during active playback — skips stale imageView.image
    ///     (which may hold an old first-frame thumbnail) and goes directly to video output for a fresh frame.
    @discardableResult
    private func preserveFrameToCache(
        useVideoOutput: Bool = true,
        async: Bool = false,
        skipImageView: Bool = false,
        allowCachedFallback: Bool = true
    ) -> Bool {
        guard let mid = attachment?.mid else { return false }
        guard hasPlaybackCoverForCurrentVideo else { return false }

        // Priority 1: imageView already has a frame — save to cache and we're done.
        // Skipped during active playback captures (skipImageView=true) because imageView
        // may hold a stale first-frame thumbnail, not the current video frame.
        if !skipImageView, let existingImage = imageView.image {
            guard !isInvalidVideoCover(existingImage) else {
                imageView.image = nil
                hideImageViewImmediately()
                return preserveFrameToCache(useVideoOutput: useVideoOutput, async: async, skipImageView: true)
            }
            SharedAssetCache.shared.updateCachedThumbnail(existingImage, for: mid)
            return true
        }

        // Priority 2: Video output capture (highest quality).
        // We try regardless of item.status — copyPixelBuffer returns nil when no frame is
        // available, so it's safe to call even when status is still .unknown (streaming-before-ready).
        if useVideoOutput,
           let player = player, player.currentItem != nil {

            ensureVideoOutputAttached(for: player)

            if let output = videoOutput {
                let playerTimeNow = player.currentTime()
                let hostTimeNow = CACurrentMediaTime()
                let hostItemTimeNow = output.itemTime(forHostTime: hostTimeNow)

                if async {
                    // Async path: offload pixel buffer processing to background (for periodic playback captures)
                    Task.detached(priority: .utility) {
                        let base = playerTimeNow
                        let backoffs: [Double] = [0.0, -0.08, -0.20, -0.40]
                        var candidateTimes: [CMTime] = backoffs.compactMap { d in
                            let t = CMTime(seconds: max(0, base.seconds + d), preferredTimescale: 600)
                            return t.isValid ? t : nil
                        }
                        if hostItemTimeNow.isValid { candidateTimes.append(hostItemTimeNow) }

                        var displayTime = CMTime.zero
                        var pixelBuffer: CVPixelBuffer?
                        for t in candidateTimes {
                            if let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &displayTime) {
                                pixelBuffer = pb
                                break
                            }
                        }
                        guard let pixelBuffer else { return }
                        let width = CVPixelBufferGetWidth(pixelBuffer)
                        let height = CVPixelBufferGetHeight(pixelBuffer)
                        guard width > 0, height > 0, width < 10000, height < 10000 else { return }
                        guard let image = VideoFrameExtractor.makeDownscaledUIImage(from: pixelBuffer, maxDimension: 720) else { return }
                        if VideoFrameExtractor.isMostlyBlack(image) || VideoFrameExtractor.isMostlyWhite(image) { return }
                        let frameTime = displayTime.isValid ? displayTime : base
                        await MainActor.run {
                            VideoPlaybackSessionStore.shared.noteDecodedFrame(mediaID: mid, time: frameTime)
                            SharedAssetCache.shared.updateCachedThumbnail(image, for: mid)
                        }
                    }
                    return true  // Async dispatch counts as captured
                } else {
                    // Sync path: try to get pixel buffer on main thread (for cleanup/failure captures)
                    let backoffs: [Double] = [0.0, -0.08, -0.20, -0.40]
                    var candidateTimes: [CMTime] = backoffs.compactMap { d in
                        let t = CMTime(seconds: max(0, playerTimeNow.seconds + d), preferredTimescale: 600)
                        return t.isValid ? t : nil
                    }
                    if hostItemTimeNow.isValid { candidateTimes.append(hostItemTimeNow) }

                    var displayTime = CMTime.zero
                    var pixelBuffer: CVPixelBuffer?
                    for t in candidateTimes {
                        if let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &displayTime) {
                            pixelBuffer = pb
                            break
                        }
                    }
                    if let pixelBuffer {
                        let width = CVPixelBufferGetWidth(pixelBuffer)
                        let height = CVPixelBufferGetHeight(pixelBuffer)
                        if width > 0, height > 0, width < 10000, height < 10000,
                           let image = VideoFrameExtractor.makeDownscaledUIImage(from: pixelBuffer, maxDimension: 720),
                           !isInvalidVideoCover(image) {
                            imageView.image = image
                            let frameTime = displayTime.isValid ? displayTime : playerTimeNow
                            VideoPlaybackSessionStore.shared.noteDecodedFrame(mediaID: mid, time: frameTime)
                            SharedAssetCache.shared.updateCachedThumbnail(image, for: mid)
                            return true
                        }
                    }
                }
            }
        }

        // Async callers are on scroll/playback-sensitive paths. Avoid falling
        // through to layer.render, which is synchronous and can block scrolling.
        if async {
            if let cached = SharedAssetCache.shared.cachedThumbnail(for: mid) {
                imageView.image = cached
                return true
            }
            return false
        }

        // Priority 3: Layer snapshot — captures whatever the player layer is currently showing.
        // Works even before readyToPlay (onReadyForDisplay fires before status transitions).
        if videoPlayerView.isLayerReadyForDisplay, !videoPlayerView.isHidden,
           videoPlayerView.bounds.width > 0, videoPlayerView.bounds.height > 0 {
            let renderer = UIGraphicsImageRenderer(bounds: videoPlayerView.bounds)
            let snapshot = renderer.image { ctx in
                videoPlayerView.layer.render(in: ctx.cgContext)
            }
            if !isInvalidVideoCover(snapshot) {
                imageView.image = snapshot
                SharedAssetCache.shared.updateCachedThumbnail(snapshot, for: mid)
                return true
            }
        }

        // Priority 4: Restore cached-media thumbnail poster if available.
        guard allowCachedFallback else { return false }
        if let cached = SharedAssetCache.shared.cachedThumbnail(for: mid) {
            imageView.image = cached
            return true
        }

        return false
    }

    /// Sync frame capture for event handlers (pause, stop, scroll-out).
    /// Captures from video output (skips stale imageView) and updates imageView immediately.
    private func captureLastFrameIfPossible(reason: String, async: Bool = false) {
        guard isVideoAttachment else { return }
        guard player != nil, player?.currentItem != nil else { return }
        guard (attachment?.mid) != nil else { return }

        // Throttle: 0.75s minimum between captures
        let now = Date()
        guard now.timeIntervalSince(lastFrameCaptureAt) >= 0.75 else { return }
        lastFrameCaptureAt = now

        if !preserveFrameToCache(async: async, skipImageView: true), !async {
            _ = preserveFrameToCache(useVideoOutput: false, async: false, skipImageView: false)
        }
    }

    @discardableResult
    private func preserveReleaseCoverForCurrentVideo(reason: String, showCover: Bool = true) -> Bool {
        guard isVideoAttachment else { return false }
        guard player != nil, player?.currentItem != nil else {
            restoreCachedPosterForFailureIfNeeded()
            return imageView.image != nil
        }

        let didPreserveCover = preserveFrameToCache(skipImageView: true)
            || preserveFrameToCache(useVideoOutput: false, skipImageView: true)

        if !didPreserveCover {
            restoreCachedPosterForFailureIfNeeded()
        }

        guard imageView.image != nil else { return false }

        if showCover {
            showImageView()
            videoPlayerView.isHidden = true
        }
        logVerbose("🖼️ preserved release cover (\(reason)), capturedOrCached=\(didPreserveCover)")
        return true
    }

    // MARK: - Player Observers

    private func setupPlayerObservers(_ player: AVPlayer) {
        guard let playerItem = player.currentItem else { return }
        removePlayerObservers()

        // Video finished
        videoCompletionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem, queue: .main
        ) { [weak self, weak player, weak playerItem] _ in
            Task { @MainActor in
                guard let player, let playerItem else { return }
                await self?.handleVideoFinished(player: player, item: playerItem)
            }
        }

        playerItemLoadedTimeRangesObserver = playerItem.observe(\.loadedTimeRanges, options: [.new]) { [weak self, weak player] item, _ in
            DispatchQueue.main.async {
                guard let self,
                      let player,
                      self.player === player,
                      player.currentItem === item else { return }
                self.removeVideoCoverIfLoadedAndDisplayable(player, reason: "loadedTimeRanges")
            }
        }

        // KVO: player item status — tracks logical readiness (for coordinator play commands)
        // NOTE: .initial removed — it fires the callback synchronously during observe() setup,
        // causing a main-thread hitch. Initial state is checked manually in configurePlayer().
        playerItemStatusObserver = playerItem.observe(\.status, options: [.old, .new]) { [weak self] item, change in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let mid = self.attachment?.mid else { return }

                if item.status == .readyToPlay {
                    self.hlsEmptyWaitingStartDate = .distantPast
                    self.hlsActiveSegmentWaitStartDate = .distantPast
                    self.hlsActiveSegmentWaitMediaID = nil
                    // Cancel the fallback task — statusKVO arrived before the timeout.
                    self.statusUnknownFallbackTask?.cancel()
                    self.statusUnknownFallbackTask = nil

                    let firstReadyTransition = change.oldValue != .readyToPlay
                    self.logVerbose("📺 statusKVO: readyToPlay (first=\(firstReadyTransition), coordWants=\(self.coordinatorWantsToPlay), state=\(self.videoCellState))")
                    if let player = self.player {
                        self.removeVideoCoverIfLoadedAndDisplayable(player, reason: "statusKVO-ready")
                    }

                    // If playback already started before status reached readyToPlay,
                    // reveal player layer now (safe point) instead of relying on an
                    // earlier .playing callback that may have fired while still unknown.
                    // Keep the spinner until the playback clock advances; AVPlayer can
                    // report .playing while the visible frame is still frozen.
                    if let player = self.player,
                       player.timeControlStatus == .playing,
                       (self.videoCellState == .playing || self.videoCellState == .playerReady) {
                        if self.playPlayerWithResumeIfNeeded(player, reason: "statusKVO-readyAlreadyPlaying", afterPlay: { [weak self] player in
                            guard let self else { return }
                            self.updateLoadingSpinnerForPlayback(player)
                        }) {
                            return
                        }
                        self.updateLoadingSpinnerForPlayback(player)
                        if self.isVisibleVideoFrameReady(player) {
                            self.fadeOutVideoCoverForPlayback()
                        } else {
                            self.addReadyForDisplayAction { [weak self] in
                                guard let self, let player = self.player else { return }
                                self.updateLoadingSpinnerForPlayback(player)
                                if self.isVisibleVideoFrameReady(player) {
                                    self.fadeOutVideoCoverForPlayback()
                                }
                            }
                        }
                    }

                    if firstReadyTransition {
                        if self.coordinatorWantsToPlay, let player = self.player {
                            if self.isVideoAtEnd(player, tolerance: 5.0) {
                                self.clearFeedResumeState(for: mid)
                                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                                    guard let self, self.coordinatorWantsToPlay, let player = self.player else { return }
                                    // Only start if not already playing (onReadyForDisplay may have fired first)
                                    if player.rate == 0 {
                                        self.requestPlaybackStartIfNeeded(player, reason: "statusKVO-ready-seekToStart")
                                    }
                                }
                            } else if player.rate == 0 {
                                // Only start if not already playing (onReadyForDisplay may have fired first)
                                self.requestPlaybackStartIfNeeded(player, reason: "statusKVO-ready")
                            }
                        } else if let player = self.player {
                            // Not going to play — transition to playerReady and seek to decode a frame.
                            if self.videoCellState == .playerLoading {
                                self.transitionTo(.playerReady)
                            }
                            // Set fresh callback for thumbnail capture (original may have been consumed).
                            self.videoPlayerView.onReadyForDisplay = { [weak self] in
                                guard let self, self.imageView.image == nil else { return }
                                self.hasRenderedFrameForCurrentPlayer = true
                                self.preserveFrameToCache()
                                if self.videoCellState == .playerReady || self.videoCellState == .playerLoading {
                                    self.transitionTo(self.videoCellState)
                                }
                            }
                            self.videoPlayerView.observeReadyForDisplay()
                            if !self.shouldSuppressPositionRestore(for: player, mid: mid) {
                                let seekTarget = CMTime(seconds: 0.01, preferredTimescale: 600)
                                player.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: .zero)
                            }
                        }
                    }

                    // Notify coordinator — video data is fully ready. If idle, start;
                    // if primary is stuck (not actually playing), reset and pick new.
                    if !self.coordinatorWantsToPlay {
                        (self.videoCoordinator ?? .shared).requestStartPlaybackIfStalled()
                    }
                } else if item.status == .failed {
                    let nsError = item.error.map { $0 as NSError }
                    let errorMsg = nsError.map { "\($0.domain) \($0.code)" } ?? "Unknown error"
                    print("\(self.logPrefix) ❌ Player failed: \(errorMsg)")
                    if self.fullscreenOverlayOwnsCurrentVideo {
                        self.logVerbose("Ignoring feed player failure while fullscreen owns \(mid)")
                        return
                    }

                    // Release the failed player from SharedAssetCache.
                    self.preserveReleaseCoverForCurrentVideo(reason: "playerItem.failed", showCover: self.isVisible)
                    let deleteDiskCache = self.shouldDeleteDiskCacheAfterPlayerFailure(nsError)
                    if !deleteDiskCache {
                        print("\(self.logPrefix) ⚠️ Preserving disk cache after transient player failure: \(errorMsg)")
                    }
                    SharedAssetCache.shared.clearPlayerForMediaID(mid, deleteDiskCache: deleteDiskCache)
                    if !deleteDiskCache,
                       self.scheduleAutomaticTransientRetryIfNeeded(errorMsg: errorMsg) {
                        self.cleanupFailedPlayerState()
                        self.restoreCachedPosterForFailureIfNeeded()
                        self.transitionTo(self.imageView.image != nil ? .playerLoading : .noContent)
                        return
                    }
                    self.handleVideoLoadFailure(reason: "playerItem.status == .failed (\(errorMsg))")
                }
            }
        }

        // KVO: timeControlStatus — show spinner while buffering, stop when actually playing
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let canDrivePlayback = self.canDriveForegroundPlayback
                self.reconcileReplayButtonWithPlaybackState(for: player, reason: "timeControl")

                // Diagnostic logging for all timeControlStatus transitions
                let statusName: String
                switch player.timeControlStatus {
                case .paused: statusName = "paused"
                case .playing: statusName = "playing"
                case .waitingToPlayAtSpecifiedRate: statusName = "waiting"
                @unknown default: statusName = "unknown(\(player.timeControlStatus.rawValue))"
                }
                let pos = self.seconds(from: player.currentTime())
                let dur = self.seconds(from: player.currentItem?.duration ?? .zero)
                let atEnd = self.isVideoAtEnd(player)
                let positionBucket = self.timeControlLogBucket(for: pos)
                let isDuplicateStatus = self.lastLoggedTimeControlStatus == player.timeControlStatus
                    && self.lastLoggedTimeControlBucket == positionBucket
                    && Date().timeIntervalSince(self.lastLoggedTimeControlDate) < 1.0
                if isDuplicateStatus {
                    return
                }
                self.lastLoggedTimeControlStatus = player.timeControlStatus
                self.lastLoggedTimeControlBucket = positionBucket
                self.lastLoggedTimeControlDate = Date()

                var logMsg = "\(self.logPrefix) ⏱️ timeControl: \(statusName), pos=\(String(format: "%.1f", pos))/\(String(format: "%.1f", dur)), atEnd=\(atEnd), state=\(self.videoCellState)"
                if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    let reason = player.reasonForWaitingToPlay?.rawValue ?? "nil"
                    let ranges = player.currentItem?.loadedTimeRanges.map {
                        let r = $0.timeRangeValue
                        return "\(String(format: "%.1f", r.start.seconds))-\(String(format: "%.1f", r.end.seconds))"
                    }.joined(separator: ", ") ?? "none"
                    let bufferEmpty = player.currentItem?.isPlaybackBufferEmpty ?? true
                    let keepUp = player.currentItem?.isPlaybackLikelyToKeepUp ?? false
                    logMsg += ", reason=\(reason), ranges=[\(ranges)], bufEmpty=\(bufferEmpty), keepUp=\(keepUp)"
                }
                if Self.verboseLogsEnabled {
                    print(logMsg)
                }

                if player.timeControlStatus == .playing {
                    self.hlsEmptyWaitingStartDate = .distantPast
                    self.hlsActiveSegmentWaitStartDate = .distantPast
                    self.hlsActiveSegmentWaitMediaID = nil
                    self.foregroundRecoveryLoadingDeadline = nil
                    self.playbackStartupRecoveryTask?.cancel()
                    self.playbackStartupRecoveryTask = nil
                    self.playbackStartupRecoveryRequestDate = nil
                    self.playbackStartupRecoveryDelay = nil
                    if !player.automaticallyWaitsToMinimizeStalling {
                        player.automaticallyWaitsToMinimizeStalling = true
                    }
                    self.updateLoadingSpinnerForPlayback(player)
                    // Hide thumbnail cover only once playback is visibly advancing.
                    if self.isActuallyPlayerReady(player) && (self.videoCellState == .playing || self.videoCellState == .playerReady) {
                        if self.isVisibleVideoFrameReady(player) {
                            self.lastActualPlaybackDate = Date()
                            self.fadeOutVideoCoverForPlayback()
                        } else {
                            self.scheduleStillFrameRecovery(for: player, reason: "timeControl-playing")
                            self.addReadyForDisplayAction { [weak self] in
                                guard let self, let player = self.player else { return }
                                self.updateLoadingSpinnerForPlayback(player)
                                if self.isVisibleVideoFrameReady(player) {
                                    self.fadeOutVideoCoverForPlayback()
                                }
                            }
                        }
                    }
                } else if canDrivePlayback,
                          player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                          self.videoCellState == .playing || self.videoCellState == .playerReady || self.videoCellState == .playerLoading {
                    guard !self.isVideoAtEnd(player) else { return }
                    self.noteBufferingWaitIfNeeded(for: player, reason: "waiting")
                    self.updateLoadingSpinnerForPlayback(player)
                    self.monitorPlaybackIfWaiting(player, reason: "timeControl-waiting")
                } else if canDrivePlayback,
                            player.timeControlStatus == .paused
                            && self.coordinatorWantsToPlay
                            && (self.videoCellState == .playing || self.videoCellState == .playerLoading)
                            && !self.isVideoAtEnd(player) {
                    self.noteBufferingWaitIfNeeded(for: player, reason: "paused")
                    self.updateLoadingSpinnerForPlayback(player)
                    self.monitorPlaybackIfWaiting(player, reason: "timeControl-paused")
                }
            }
        }
    }

    private func removePlayerObservers() {
        if let o = videoCompletionObserver { NotificationCenter.default.removeObserver(o) }
        videoCompletionObserver = nil
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = nil
        playerItemLoadedTimeRangesObserver?.invalidate()
        playerItemLoadedTimeRangesObserver = nil
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
    }


    // MARK: - Video Finished

    private func handleVideoFinished(player: AVPlayer, item: AVPlayerItem) async {
        guard !isHandlingFinishEvent else { return }

        guard self.player === player,
              player.currentItem === item,
              item.status == .readyToPlay,
              let mid = attachment?.mid else { return }

        let duration = item.duration
        guard duration.isValid,
              !duration.isIndefinite,
              duration.seconds.isFinite,
              duration.seconds > 0 else { return }

        let currentTime = player.currentTime().seconds
        guard currentTime.isFinite else { return }
        let timeUntilEnd = duration.seconds - currentTime

        guard timeUntilEnd < 0.5 else {
            return
        }

        isHandlingFinishEvent = true
        print("\(logPrefix) ✅ video finished: current=\(String(format: "%.1f", currentTime))s, duration=\(String(format: "%.1f", duration.seconds))s")
        // Note: flag stays true until cell is reused (cleanupVideoPlayer)
        // or coordinator sends a new play command (handleCoordinatorPlayCommand)

        // Pause immediately
        player.pause()
        player.isMuted = MuteState.shared.isMuted
        // Cache a final frame for later release/offscreen recovery, but do not put it
        // over the still-attached player. Finished videos should show the AVPlayerLayer's
        // last frame until the player is actually released.
        _ = preserveFrameToCache(skipImageView: true)
        clearFeedResumeState(for: mid)
        VideoStateCache.shared.clearCache(for: mid, force: true)

        hideImageViewImmediately()
        videoPlayerView.isHidden = false
        videoCellState = .paused

        // Notify coordinator to advance to next video (include full identifier: tweet id + video id + index)
        var userInfo: [String: Any] = ["videoMid": mid, "tweetId": parentTweet?.mid ?? ""]
        if let id = videoIdentifier { userInfo["videoIdentifier"] = id }
        NotificationCenter.default.post(
            name: .videoDidFinishPlaying,
            object: nil,
            userInfo: userInfo
        )
        // Prevent coordinator from auto-replaying this video when it scrolls back into view.
        if let id = videoIdentifier {
            VideoStateCache.shared.markVideoFinished(identifier: id)
        }
        coordinatorWantsToPlay = false
        cancelDelayedPrimarySpinner()
        loadingSpinner.stopAnimating()
        updateReplayButtonVisibility()
    }

    private func detachFinishedPlayer(for mid: String) {
        playerAcquireDebounceTask?.cancel()
        playerAcquireDebounceTask = nil
        setupPlayerTask?.cancel()
        setupPlayerTask = nil
        slowLoadingRecoveryTask?.cancel()
        slowLoadingRecoveryTask = nil
        statusUnknownFallbackTask?.cancel()
        statusUnknownFallbackTask = nil
        playbackStartupRecoveryTask?.cancel()
        playbackStartupRecoveryTask = nil
        playbackStartupRecoveryRequestDate = nil
        playbackStartupRecoveryDelay = nil

        removePlayerObservers()
        removePlayerTimeObserver()

        if let item = videoOutputAttachedItem, let output = videoOutput {
            item.remove(output)
        }
        videoOutput = nil
        videoOutputAttachedItem = nil

        videoPlayerView.onReadyForDisplay = nil
        videoPlayerView.setPlayer(nil)
        hasRenderedFrameForCurrentPlayer = false
        let detachedPlayer = player
        player = nil

        detachedPlayer?.pause()
        detachedPlayer?.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        detachedPlayer?.currentItem?.asset.cancelLoading()
        detachedPlayer?.replaceCurrentItem(with: nil)
        SharedAssetCache.shared.clearPlayerForMediaID(mid, deleteDiskCache: false)
    }

    // MARK: - Utilities

    private func saveCurrentPosition(player: AVPlayer, wasPlaying: Bool) {
        guard let mid = attachment?.mid else { return }
        guard hasEstablishedDecodedPlayback(for: player) || lastActualPlaybackDate != .distantPast else {
            FeedVideoResumeStore.clear(mid: mid)
            return
        }
        FeedVideoResumeStore.save(mid: mid, player: player, wasPlaying: wasPlaying)
    }

    private func savedFeedResumeTime(for mid: String, player: AVPlayer? = nil) -> CMTime? {
        FeedVideoResumeStore.resumeTime(for: mid, player: player)
    }

    private func feedResumeSeekTargetIfNeeded(for mid: String, player: AVPlayer) -> CMTime? {
        guard player.currentItem?.status == .readyToPlay else { return nil }

        if shouldSuppressPositionRestore(for: player, mid: mid) {
            pendingRecoverySeekTime = nil
            return nil
        }

        if Date() < suppressFeedResumeUntil {
            pendingRecoverySeekTime = nil
            let currentTime = player.currentTime()
            let currentSeconds = currentTime.seconds
            if currentTime.isValid,
               currentSeconds.isFinite,
               currentSeconds > 0.25 {
                return .zero
            }
            return nil
        }

        let currentTime = player.currentTime()
        let currentSeconds = currentTime.seconds
        if let resumeTime = savedFeedResumeTime(for: mid, player: player),
           resumeTime.isValid,
           resumeTime.seconds.isFinite {
            if lastActualPlaybackDate == .distantPast,
               !hasEstablishedDecodedPlayback(for: player),
               attachment?.type == .hls_video {
                pendingRecoverySeekTime = nil
                return .zero
            }

            if resumeTime.seconds == 0,
               currentTime.isValid,
               currentSeconds.isFinite,
               currentSeconds > 0.25 {
                pendingRecoverySeekTime = nil
                return .zero
            }

            if currentTime.isValid,
               currentSeconds.isFinite,
               currentSeconds > 0.25 {
                if resumeTime.seconds > currentSeconds + 0.75 {
                    return resumeTime
                }
                pendingRecoverySeekTime = nil
                return nil
            }

            return resumeTime
        }

        if currentTime.isValid,
           currentSeconds.isFinite,
           currentSeconds > 0.25 {
            pendingRecoverySeekTime = nil
            if lastActualPlaybackDate == .distantPast,
               !hasEstablishedDecodedPlayback(for: player) {
                return .zero
            }
            return nil
        }

        if let recoveryTime = pendingRecoverySeekTime,
           recoveryTime.isValid,
           recoveryTime.seconds.isFinite,
           recoveryTime.seconds > 0.25 {
            return recoveryTime
        }
        return nil
    }

    @discardableResult
    private func playPlayerWithResumeIfNeeded(
        _ player: AVPlayer,
        reason: String,
        afterPlay: @escaping (AVPlayer) -> Void = { _ in }
    ) -> Bool {
        let playAction: (AVPlayer) -> Void = { [weak self] player in
            guard let self else { return }
            guard self.canDriveForegroundPlayback else { return }
            player.play()
            self.resetPlaybackProgressTracking(to: player.currentTime())
            afterPlay(player)
        }

        if seekToFeedResumeTimeIfNeeded(player, reason: reason, completion: playAction) {
            return true
        }

        playAction(player)
        return false
    }

    @discardableResult
    private func seekToFeedResumeTimeIfNeeded(
        _ player: AVPlayer,
        reason: String,
        completion: @escaping (AVPlayer) -> Void
    ) -> Bool {
        guard let mid = attachment?.mid,
              let resumeTime = feedResumeSeekTargetIfNeeded(for: mid, player: player) else {
            return false
        }

        pendingRecoverySeekTime = nil
        updateLoadingSpinnerForPlayback(player)
        player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
            DispatchQueue.main.async {
                guard let self,
                      let player,
                      self.player === player,
                      self.attachment?.mid == mid,
                      self.coordinatorWantsToPlay else { return }
                self.logVerbose("🔄 feed resume seek (\(reason)) restored \(String(format: "%.1f", resumeTime.seconds))s")
                completion(player)
            }
        }
        return true
    }

    private func clearFeedResumeState(for mid: String) {
        FeedVideoResumeStore.clear(mid: mid)
        VideoPlaybackSessionStore.shared.reset(mediaID: mid)
        resetDecodedPlaybackTracking()
    }

    private func isVideoAtEnd(_ player: AVPlayer, tolerance: Double = 0.5) -> Bool {
        guard let item = player.currentItem else { return false }
        let duration = item.duration
        guard duration.isValid,
              !duration.isIndefinite,
              duration.seconds.isFinite,
              duration.seconds > 0 else { return false }
        let currentTime = player.currentTime()
        guard currentTime.isValid, currentTime.seconds.isFinite else { return false }
        let diff = CMTimeSubtract(duration, currentTime)
        return CMTimeCompare(diff, CMTime(seconds: tolerance, preferredTimescale: duration.timescale)) <= 0
    }

    // MARK: - Mute Button

    private func setupMuteButton() {
        muteButton.isHidden = false
        updateMuteButtonIcon()

        // Observe mute state changes for icon
        MuteState.shared.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMuteButtonIcon()
            }
            .store(in: &cancellables)
    }

    private func updateMuteButtonIcon() {
        let iconName = MuteState.shared.isMuted ? "speaker.slash" : "speaker.wave.2"
        let config = UIImage.SymbolConfiguration(pointSize: 14)
        muteButton.setImage(UIImage(systemName: iconName, withConfiguration: config), for: .normal)
    }

    @objc private func muteTapped() {
        MuteState.shared.toggleMute()
    }

    // MARK: - Video Timer

    private func setupVideoTimer(videoMid: String) {
        let isNewTimerVideo = timerLabelVideoMid != videoMid
        timerLabelVideoMid = videoMid
        timerLabel.isHidden = false

        if updateTimerLabelIfPossible(videoMid: videoMid) {
            updateTimerLabelLayout()
            return
        }

        if isNewTimerVideo || timerLabel.text?.isEmpty != false {
            timerLabel.text = "0:00"
        }
        updateTimerLabelLayout()
    }

    private func layoutTimerLabel(in bounds: CGRect) {
        guard !timerLabel.isHidden,
              bounds.width > 0,
              bounds.height > 0 else {
            timerLabel.frame = .zero
            return
        }

        let timerH: CGFloat = 24
        let horizontalPadding: CGFloat = 6
        let maxWidth = max(44, bounds.width - horizontalPadding * 2)
        let textWidth = timerLabel.sizeThatFits(
            CGSize(width: maxWidth - 16, height: timerH)
        ).width
        let timerW = min(maxWidth, ceil(textWidth) + 16)
        timerLabel.frame = CGRect(
            x: horizontalPadding,
            y: max(horizontalPadding, bounds.maxY - timerH - horizontalPadding),
            width: timerW,
            height: timerH
        )
    }

    private func updateTimerLabelLayout() {
        setNeedsLayout()
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        layoutIfNeeded()
    }

    /// Attach a periodic time observer to track visible playback progress and
    /// drive the timer label for single-media videos.
    private func startPlayerTimeObserver() {
        removePlayerTimeObserver()

        guard let player = player else { return }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverPlayer = player
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.recordPlaybackProgress(currentTime: time)
            if self.isSingleMedia {
                self.updateTimerLabel(currentTime: time)
            }
        }
    }

    private func removePlayerTimeObserver() {
        if let token = timeObserverToken, let player = timeObserverPlayer {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        timeObserverPlayer = nil
    }

    private func resetPlaybackProgressTracking(to time: CMTime = .zero) {
        let currentSeconds = seconds(from: time)
        lastPlaybackProgressDate = .distantPast
        lastObservedPlaybackSeconds = currentSeconds.isFinite ? currentSeconds : 0
        lastPlaybackRequestPositionSeconds = lastObservedPlaybackSeconds
    }

    private func resetDecodedPlaybackTracking() {
        lastDecodedPlaybackProgressDate = .distantPast
        lastDecodedPlaybackSeconds = 0
    }

    private func decodedPlaybackSnapshot(for player: AVPlayer) -> VideoPlaybackSessionStore.DecodedFrameSnapshot? {
        guard let mid = attachment?.mid else { return nil }
        return VideoPlaybackSessionStore.shared.decodedFrameSnapshot(for: mid, beforeOrAt: player.currentTime())
    }

    private func hasEstablishedDecodedPlayback(for player: AVPlayer) -> Bool {
        if lastDecodedPlaybackSeconds > 0.25 {
            return true
        }
        guard let snapshot = decodedPlaybackSnapshot(for: player) else { return false }
        return seconds(from: snapshot.time) > 0.25
    }

    private func hasRecentDecodedPlayback(for player: AVPlayer, maxAge: TimeInterval) -> Bool {
        if let snapshot = decodedPlaybackSnapshot(for: player) {
            return Date().timeIntervalSince(snapshot.updatedAt) <= maxAge
        }
        guard lastDecodedPlaybackProgressDate != .distantPast else { return false }
        return Date().timeIntervalSince(lastDecodedPlaybackProgressDate) <= maxAge
    }

    private func trustedRecoverySeekTime(for player: AVPlayer) -> CMTime? {
        if let mid = attachment?.mid,
           let decodedTime = VideoPlaybackSessionStore.shared.trustedVisibleTime(
            for: mid,
            beforeOrAt: player.currentTime()
           ) {
            return decodedTime
        }

        let currentSeconds = seconds(from: player.currentTime())
        if lastPlaybackRequestPositionSeconds > 0.25,
           lastPlaybackRequestPositionSeconds <= currentSeconds + 0.25 {
            return CMTime(seconds: lastPlaybackRequestPositionSeconds, preferredTimescale: 600)
        }

        return nil
    }

    private func decodedFrameTimeIfAvailable(for player: AVPlayer) -> CMTime? {
        guard let item = player.currentItem else { return nil }
        if videoOutputAttachedItem !== item || videoOutput == nil {
            ensureVideoOutputAttached(for: player)
        }
        guard videoOutputAttachedItem === item,
              let output = videoOutput else { return nil }

        let hostItemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        if hostItemTime.isValid, output.hasNewPixelBuffer(forItemTime: hostItemTime) {
            return hostItemTime
        }

        let currentTime = player.currentTime()
        if currentTime.isValid, output.hasNewPixelBuffer(forItemTime: currentTime) {
            return currentTime
        }

        return nil
    }

    private func recordPlaybackProgress(currentTime: CMTime) {
        let currentSeconds = seconds(from: currentTime)
        guard currentSeconds.isFinite else { return }

        if let player,
           let mid = attachment?.mid,
           let decodedTime = decodedFrameTimeIfAvailable(for: player) {
            VideoPlaybackSessionStore.shared.noteDecodedFrame(mediaID: mid, time: decodedTime)
            let decodedSeconds = seconds(from: decodedTime)
            if decodedSeconds.isFinite,
               decodedSeconds >= 0,
               (lastDecodedPlaybackProgressDate == .distantPast
                || abs(decodedSeconds - lastDecodedPlaybackSeconds) > 0.03) {
                lastDecodedPlaybackSeconds = decodedSeconds
                lastDecodedPlaybackProgressDate = Date()
                hasRenderedFrameForCurrentPlayer = true
                if !didLogFirstDecodedPlayback {
                    didLogFirstDecodedPlayback = true
                    automaticTransientRetryTask?.cancel()
                    automaticTransientRetryTask = nil
                    automaticTransientRetryCount = 0
                    print("\(logPrefix) ✅ decoded playback started: t=\(String(format: "%.1f", decodedSeconds))s, itemStatus=\(player.currentItem?.status.rawValue ?? -1), timeControl=\(player.timeControlStatus.rawValue)")
                }
            }
        }

        if currentSeconds > lastObservedPlaybackSeconds + 0.05 {
            lastObservedPlaybackSeconds = currentSeconds
            lastPlaybackProgressDate = Date()
            if !didLogFirstPlaybackProgress {
                didLogFirstPlaybackProgress = true
                print("\(logPrefix) ▶️ playback clock advancing: t=\(String(format: "%.1f", currentSeconds))s, itemStatus=\(player?.currentItem?.status.rawValue ?? -1), timeControl=\(player?.timeControlStatus.rawValue ?? -1)")
            }
            if let player {
                reconcileReplayButtonWithPlaybackState(for: player, reason: "playbackProgress")
            }
            if let player, coordinatorWantsToPlay {
                updateLoadingSpinnerForPlayback(player)
                if removeVideoCoverIfLoadedAndDisplayable(player, reason: "playbackProgress") ||
                    isVisibleVideoFrameReady(player),
                   videoCellState == .playing || videoCellState == .playerReady {
                    resetFeedPlayerRebuildBudget()
                    if imageView.image != nil {
                        fadeOutVideoCoverForPlayback()
                    }
                }
                schedulePlaybackProgressWatchdog(for: player, reason: "playbackProgress")
            }
        }
    }

    private func schedulePlaybackProgressWatchdog(for player: AVPlayer, reason: String) {
        playbackProgressWatchdogTask?.cancel()
        playbackProgressWatchdogTask = Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self,
                  let player else { return }

            self.playbackProgressWatchdogTask = nil

            guard
                  self.player === player,
                  self.coordinatorWantsToPlay,
                  self.canDriveForegroundPlayback,
                  self.videoCellState == .playing,
                  !self.fullscreenOverlayOwnsCurrentVideo,
                  !self.isVideoAtEnd(player) else { return }

            let now = Date()
            let noRecentClockProgress = self.lastPlaybackProgressDate == .distantPast
                || now.timeIntervalSince(self.lastPlaybackProgressDate) >= 4.0
            let noRecentDecodedProgress = !self.hasRecentDecodedPlayback(for: player, maxAge: 4.0)
            let nextReason = self.progressWatchdogReason(after: reason)
            guard noRecentClockProgress && noRecentDecodedProgress else {
                self.schedulePlaybackProgressWatchdog(for: player, reason: nextReason)
                return
            }

            let bufferedAhead = self.bufferedTimeAhead(for: player)
            let position = self.seconds(from: player.currentTime())
            let status = player.currentItem?.status.rawValue ?? -1

            if self.releaseStartupBufferIfReady(player, bufferedAhead: bufferedAhead, reason: nextReason) {
                return
            }

            if now.timeIntervalSince(self.lastSlowLoadWaitLogDate) >= 5.0 {
                print("\(self.logPrefix) ⏳ progress watchdog (\(reason)): no playback progress, pos=\(String(format: "%.1f", position))s, buffered=\(String(format: "%.1f", bufferedAhead))s, itemStatus=\(status), timeControl=\(player.timeControlStatus.rawValue)")
                self.lastSlowLoadWaitLogDate = now
            }

            guard player.currentItem?.status == .readyToPlay,
                  player.timeControlStatus != .playing,
                  bufferedAhead < 0.5,
                  let mid = self.attachment?.mid,
                  !self.shouldSuppressPositionRestore(for: player, mid: mid) else {
                self.applyAVPlayerBufferDefaults(to: player)
                player.play()
                self.updateLoadingSpinnerForPlayback(player)
                self.schedulePlaybackProgressWatchdog(for: player, reason: nextReason)
                return
            }

            if self.attachment?.type == .video {
                player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
                self.applyAVPlayerBufferDefaults(to: player)
                player.play()
                self.updateLoadingSpinnerForPlayback(player)
                self.schedulePlaybackProgressWatchdog(for: player, reason: nextReason)
                return
            }

            let currentTime = player.currentTime()
            if let resumeTime = self.trustedRecoverySeekTime(for: player) ?? (currentTime.seconds.isFinite && currentTime.seconds > 0.25 ? currentTime : nil),
               resumeTime.isValid,
               resumeTime.seconds.isFinite {
                self.pendingRecoverySeekTime = resumeTime
            }

            guard self.reserveFeedPlayerRebuild(player: player, mid: mid, reason: nextReason) else { return }
            print("\(self.logPrefix) 🔄 progress watchdog (\(reason)): ready player stalled with \(String(format: "%.1f", bufferedAhead))s buffered — rebuilding feed player from proxy cache")
            _ = self.rebuildCurrentFeedPlayerFromProxyCache(
                mid: mid,
                reacquireReason: "progressWatchdogRecovery",
                transitionState: self.imageView.image != nil ? .thumbnail : .playerLoading
            )
        }
    }

    private func updateTimerLabel(currentTime: CMTime) {
        guard let videoMid = attachment?.mid else { return }
        updateTimerLabelIfPossible(videoMid: videoMid, currentTime: currentTime)
    }

    @discardableResult
    private func updateTimerLabelIfPossible(videoMid: String, currentTime: CMTime? = nil) -> Bool {
        guard let item = player?.currentItem else { return false }
        let duration = item.duration
        let durationSeconds = seconds(from: duration)
        guard duration.isValid, !duration.isIndefinite, durationSeconds > 0 else { return false }

        let displayTime: CMTime
        if let currentTime,
           currentTime.isValid,
           currentTime.seconds.isFinite {
            displayTime = currentTime
        } else {
            let playerTime = player?.currentTime() ?? .invalid
            if playerTime.isValid,
               playerTime.seconds.isFinite {
                displayTime = playerTime
            } else if let resumeTime = FeedVideoResumeStore.resumeTime(for: videoMid, player: player) {
                displayTime = resumeTime
            } else {
                return false
            }
        }

        let remaining = max(0, durationSeconds - seconds(from: displayTime))
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        let newText = "\(minutes):\(String(format: "%02d", seconds))"
        if timerLabel.text != newText {
            timerLabel.text = newText
            updateTimerLabelLayout()
        }
        return true
    }

    // scheduleTimerHide removed — timer label stays visible while video is loaded.

    // MARK: - Audio

    private func setupAudioCell(url: URL) {
        imageView.isHidden = true
        removeAudioHosting()

        let audioView = SimpleAudioPlayer(url: url, autoPlay: isVisible)
            .environmentObject(MuteState.shared)

        let hostingController = UIHostingController(rootView: AnyView(audioView))
        hostingController.view.backgroundColor = .clear
        hostingController.view.insetsLayoutMarginsFromSafeArea = false
        hostingController.view.layer.cornerRadius = 8
        hostingController.view.clipsToBounds = true
        hostingController.view.frame = bounds

        parentViewController?.addChild(hostingController)
        addSubview(hostingController.view)
        hostingController.didMove(toParent: parentViewController)

        audioHostingController = hostingController
    }

    // MARK: - Tap Handling

    @objc private func retryTapped() {
        if isVideoAttachment {
            retryVideoLoad()
        } else {
            retryImageLoad()
        }
    }

    @objc private func replayTapped() {
        replayFinishedVideo()
    }

    private func replayFinishedVideo() {
        guard isVideoAttachment,
              let att = attachment,
              let url = att.getUrl(effectiveBaseUrl),
              let parentTweet = parentTweet else { return }

        let mid = att.mid
        print("\(logPrefix) 🔁 Manual video replay")
        if let id = videoIdentifier {
            VideoStateCache.shared.clearVideoFinished(id)
        }
        VideoStateCache.shared.clearStoppedByCoordinator(mid)
        VideoStateCache.shared.clearCache(for: mid, force: true)
        clearFeedResumeState(for: mid)

        replayButton.isHidden = true
        retryButton.isHidden = true
        isHandlingFinishEvent = false

        if let id = videoIdentifier,
           (videoCoordinator ?? .shared).replayFinishedVideo(identifier: id) {
            return
        }

        // Fallback for rare cases where the coordinator has not rebuilt its video list yet.
        if let player, isActuallyPlayerReady(player) {
            (videoCoordinator ?? .shared).stopAllVideos()
            LocalHTTPServer.shared.setPrimaryMediaID(mid)
            coordinatorWantsToPlay = true
            transitionTo(.playerReady)
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.coordinatorWantsToPlay, self.player === player else { return }
                    self.requestPlaybackStartIfNeeded(player, reason: "replayButton")
                }
            }
        } else {
            (videoCoordinator ?? .shared).stopAllVideos()
            LocalHTTPServer.shared.setPrimaryMediaID(mid)
            coordinatorWantsToPlay = true
            restoreCachedPosterForFailureIfNeeded()
            transitionTo(imageView.image != nil ? .thumbnail : .noContent)
            acquirePlayer(attachment: att, url: url, parentTweet: parentTweet)
        }
    }

    private func retryVideoLoad(isAutomatic: Bool = false) {
        guard isVideoAttachment else { return }

        print("\(logPrefix) 🔄 \(isAutomatic ? "Automatic" : "Manual") video retry")
        if !isAutomatic {
            automaticTransientRetryTask?.cancel()
            automaticTransientRetryTask = nil
            automaticTransientRetryCount = 0
        }
        let retryReason = isAutomatic ? "automaticTransientRetry" : "manualRetry"
        preserveReleaseCoverForCurrentVideo(reason: retryReason, showCover: isVisible)
        restoreCachedPosterForFailureIfNeeded()
        retryButton.isHidden = true
        replayButton.isHidden = true
        _ = reacquirePlayerForCurrentVideo(
            reason: retryReason,
            clearCachedPlayer: true,
            transitionState: imageView.image != nil ? .playerLoading : .noContent,
            wantsPlayback: true
        )
    }

    @objc private func retryImageLoad() {
        guard let attachment, attachment.type == .image,
              let url = attachment.getUrl(effectiveBaseUrl) else { return }
        retryButton.isHidden = true
        // Clear permanently-failed status so GlobalImageLoadManager will retry
        GlobalImageLoadManager.shared.retryLoad(id: attachment.mid)
        loadImage(attachment: attachment, url: url)
    }

    /// Nil player, stop spinner, clear loading flags after a failure.
    private func cleanupFailedPlayerState() {
        cancelDelayedPrimarySpinner()
        playbackStartupRecoveryTask?.cancel()
        playbackStartupRecoveryTask = nil
        playbackStartupRecoveryRequestDate = nil
        playbackStartupRecoveryDelay = nil
        statusUnknownFallbackTask?.cancel()
        statusUnknownFallbackTask = nil
        setupPlayerTask?.cancel()
        setupPlayerTask = nil
        slowLoadingRecoveryTask?.cancel()
        slowLoadingRecoveryTask = nil
        loadingSpinner.stopAnimating()
        removePlayerObservers()
        removePlayerTimeObserver()
        videoPlayerView.setPlayer(nil)
        if let player {
            player.pause()
            player.currentItem?.asset.cancelLoading()
            player.replaceCurrentItem(with: nil)
        }
        player = nil
    }

    /// Transition to an idle visual state (thumbnail or noContent) after failure.
    private func transitionToIdleAfterFailure() {
        restoreCachedPosterForFailureIfNeeded()

        if imageView.image != nil {
            transitionTo(.thumbnail)
        } else {
            transitionTo(.noContent)
            loadingSpinner.stopAnimating()
        }
    }

    private func restoreCachedPosterForFailureIfNeeded() {
        if imageView.image == nil,
           let mid = attachment?.mid,
           let cached = SharedAssetCache.shared.cachedThumbnail(for: mid) {
            imageView.image = cached
        }
    }

    @discardableResult
    private func restoreForegroundRecoveryPosterIfNeeded(reason: String) -> Bool {
        guard isVideoAttachment,
              let mid = attachment?.mid else { return false }

        if let player, isVisibleVideoFrameReady(player) {
            return false
        }

        if videoThumbnailObserver == nil {
            observeCachedVideoThumbnail(for: mid)
        }

        if imageView.image == nil {
            if let transitionPoster = FullScreenVideoManager.shared.transitionPoster(for: mid) {
                imageView.image = transitionPoster
            } else if let cached = SharedAssetCache.shared.cachedThumbnail(for: mid) {
                imageView.image = cached
            }
        }

        guard imageView.image != nil else {
            requestFallbackVideoThumbnailIfNeeded(for: mid)
            return false
        }

        // Detail/fullscreen can cover the feed during backgrounding, so the feed
        // cell may miss prepareVideoForBackground(). Promote any cached poster into
        // the protected foreground cover state before rebuilding AVPlayer.
        isHoldingBackgroundVideoCover = true
        backgroundVideoCoverMid = mid
        foregroundRecoveryLoadingDeadline = Date().addingTimeInterval(5.0)
        SharedAssetCache.shared.protectBackgroundPoster(for: mid)

        switch videoCellState {
        case .noContent, .thumbnail:
            transitionTo(.thumbnail)
        case .playerLoading, .playerReady, .playing, .paused, .failed:
            transitionTo(videoCellState)
        }

        logVerbose("🖼️ restored foreground recovery poster (\(reason))")
        return true
    }

    /// Central handler for all video loading failures. Preserves frame, cleans up player,
    /// shows retry button if visible and coordinator wants play, otherwise goes idle.
    private func handleVideoLoadFailure(reason: String) {
        guard isVideoAttachment else { return }
        guard !deferVideoWorkUntilInfrastructureReady(reason: "loadFailure.\(reason)", wantsPlayback: coordinatorWantsToPlay) else {
            return
        }

        // Capture frame BEFORE cleanup — for partially-played videos,
        // this preserves the last rendered frame as thumbnail behind the retry button.
        preserveReleaseCoverForCurrentVideo(reason: "loadFailure.\(reason)", showCover: isVisible)
        let failedMid = attachment?.mid
        cleanupFailedPlayerState()
        if let failedMid {
            if !fullscreenOverlayOwnsCurrentVideo {
                VideoStateCache.shared.clearCachedState(for: failedMid)
                SharedAssetCache.shared.clearPlayerForMediaID(failedMid, deleteDiskCache: false)
            }
        }

        // Only the actively selected playback should surface a retry button.
        // coordinatorWantsToPlay can be cleared before AVPlayer reports a timeout,
        // so also trust the coordinator's current primary selection.
        let isPrimaryFailure = coordinatorWantsToPlay || isCurrentCoordinatorPrimary
        let shouldShowRetry = isVisible && isPrimaryFailure
        let wasPrimary = isPrimaryFailure
        let failedIdentifier = videoIdentifier

        if wasPrimary, let failedIdentifier {
            (videoCoordinator ?? .shared).notifyPrimaryVideoFailed(identifier: failedIdentifier)
        }

        guard shouldShowRetry else {
            print("\(logPrefix) ❌ \(reason) - going idle")
            transitionToIdleAfterFailure()
            return
        }

        let hasAutomaticRetryPending = automaticTransientRetryTask != nil
        print("\(logPrefix) ❌ \(reason) - \(hasAutomaticRetryPending ? "automatic retry pending" : "showing retry button")")
        coordinatorWantsToPlay = false
        restoreCachedPosterForFailureIfNeeded()
        transitionTo(.failed)
    }

    @objc private func mediaTapped() {
        guard let attachment else { return }
        switch attachment.type {
        case .image:
            imageTapped()
        case .video, .hls_video:
            handleVideoTap()
        default:
            break
        }
    }

    @objc private func imageTapped() {
        guard let parentTweet, let parentVC = parentViewController else { return }
        // Mark overlay BEFORE present to prevent setVisible(false) race (see handleVideoTap)
        OverlayVisibilityCoordinator.shared.beginOverlay(id: "mediaBrowserView", source: "MediaCellUIView.imageTapped")
        let browserView = MediaBrowserView(
            tweet: parentTweet,
            initialIndex: attachmentIndex,
            cellTweetId: cellTweetId ?? parentTweet.mid
        )
        let hostingVC = UIHostingController(rootView: browserView)
        hostingVC.modalPresentationStyle = .fullScreen
        hostingVC.modalTransitionStyle = .crossDissolve
        parentVC.present(hostingVC, animated: true)
    }

    private func handleVideoTap() {
        guard let parentTweet, let parentVC = parentViewController else { return }

        // Save video position before fullscreen
        saveVideoPositionForFullscreen()
        captureLastFrameIfPossible(reason: "openFullscreen")

        // Build video list from the feed's coordinator and pass to fullscreen manager
        let coordinator = videoCoordinator ?? VideoPlaybackCoordinator.shared
        let fullscreenList = coordinator.getVideoListForFullscreen()
        let myMid = attachment?.mid
        let myMediaTweetId = parentTweet.mid
        let myOuterTweetId = cellTweetId ?? parentTweet.mid
        let startIndex = fullscreenList.firstIndex(where: {
            $0.videoMid == myMid &&
            $0.contextTweetId == myOuterTweetId &&
            $0.mediaTweetId == myMediaTweetId &&
            $0.attachmentIndex == attachmentIndex
        }) ?? fullscreenList.firstIndex(where: {
            $0.videoMid == myMid &&
            $0.cellTweetId == myOuterTweetId &&
            $0.attachmentIndex == attachmentIndex
        }) ?? 0
        FullScreenVideoManager.shared.setVideoList(fullscreenList, startIndex: startIndex)

        // CRITICAL: Mark overlay BEFORE presenting the modal. The .fullScreen presentation
        // triggers didMoveToWindow(nil) → setVisible(false) on feed cells, which checks
        // isCovered to skip aggressive cleanup (delegate unregister, network cancel).
        // If beginOverlay waits until onAppear, there's a race where setVisible(false)
        // fires first with isCovered=false → delegate unregistered → coordinator can't
        // find the video after dismiss → spinner stuck permanently.
        OverlayVisibilityCoordinator.shared.beginOverlay(id: "mediaBrowserView", source: "MediaCellUIView.handleVideoTap")

        DispatchQueue.main.async { [weak self] in
            let browserView = MediaBrowserView(
                tweet: parentTweet,
                initialIndex: self?.attachmentIndex ?? 0,
                cellTweetId: self?.cellTweetId ?? parentTweet.mid
            )
            let hostingVC = UIHostingController(rootView: browserView)
            hostingVC.modalPresentationStyle = .fullScreen
            hostingVC.modalTransitionStyle = .crossDissolve

            parentVC.present(hostingVC, animated: true)

        }
    }

    private func saveVideoPositionForFullscreen() {
        guard let attachment else { return }

        // Try to save directly from our player first
        if let player = player, player.currentItem != nil {
            let isNearEnd = isVideoAtEnd(player, tolerance: 3.0)
            let currentTime = isNearEnd ? .zero : player.currentTime()
            let wasPlaying = player.rate > 0
            PersistentVideoStateManager.shared.saveState(
                videoMid: attachment.mid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .fullScreen
            )
        } else if let cachedState = VideoStateCache.shared.getCachedState(for: attachment.mid) {
            let isNearEnd = isVideoAtEnd(cachedState.player, tolerance: 3.0)
            let currentTime = isNearEnd ? .zero : cachedState.player.currentTime()
            let wasPlaying = cachedState.player.rate > 0
            PersistentVideoStateManager.shared.saveState(
                videoMid: attachment.mid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .fullScreen
            )
        } else if let playbackInfo = VideoStateCache.shared.getCachedPlaybackInfo(for: attachment.mid) {
            PersistentVideoStateManager.shared.saveState(
                videoMid: attachment.mid,
                currentTime: playbackInfo.time,
                wasPlaying: playbackInfo.wasPlaying,
                context: .fullScreen
            )
        }
    }

    // MARK: - Visibility

    func setVisible(_ visible: Bool, shouldAcquirePlayer: Bool = true) {
        let wasVisible = isVisible
        let wasAcquiring = self.shouldAcquirePlayer
        self.shouldAcquirePlayer = shouldAcquirePlayer

        // Detect transition from "not acquiring" to "acquiring" while staying visible
        let shouldStartAcquiring = visible && wasVisible && !wasAcquiring && shouldAcquirePlayer

        // Recovery case: visible, infra ready, but no player (post-background state)
        let needsRecovery = visible &&
                            wasVisible &&
                            isVideoAttachment &&
                            shouldAcquirePlayer &&
                            player == nil &&
                            setupPlayerTask == nil &&
                            videoCellState != .failed &&
                            AppDelegate.isVideoInfrastructureReady

        // needsRecovery covers the post-background case: visible with infrastructure
        // ready but the player was torn down on background, so the cell has no player
        // to resume. It must fall through to acquisition even though visibility is
        // unchanged.
        guard isVisible != visible || shouldStartAcquiring || needsRecovery else {
            return
        }
        isVisible = visible

        guard let attachment else { return }

        if visible, wasVisible, isVideoAttachment {
            if resumeSurfaceReturnHandoffIfNeeded(reason: "setVisible(true)") {
                return
            }
        }

        if visible {
            // Update base URL
            updateEffectiveBaseUrl()

            // Boost priority for pending image loads or load if needed
            if attachment.type == .image {
                setupImageCacheObserver()
                if applyCachedImageIfAvailable(for: attachment) {
                    GlobalImageLoadManager.shared.boostPriority(id: attachment.mid, to: .critical)
                } else if imageView.image == nil {
                    if let url = attachment.getUrl(effectiveBaseUrl) {
                        // Boost priority if already in queue - use critical for all visible images
                        GlobalImageLoadManager.shared.boostPriority(id: attachment.mid, to: .critical)
                        loadImage(attachment: attachment, url: url)
                    }
                } else {
                    // Image already loaded, but boost priority in case it's in retry queue
                    GlobalImageLoadManager.shared.boostPriority(id: attachment.mid, to: .critical)
                }
            }

            // Mark video as visible for cache preservation
            if isVideoAttachment {
                // Visibility preserves the cell/delegate immediately, but AVPlayer
                // creation is held until the media is close to autoplay range.
                if attachment.getUrl(effectiveBaseUrl) != nil {
                    SharedAssetCache.shared.markAsVisible(attachment.mid)
                    VideoStateCache.shared.markAsVisible(attachment.mid)
                }
                if shouldAcquirePlayer {
                    _ = attachCachedPlayerIfAvailable(reason: "becameVisible")
                }
                if shouldAcquirePlayer,
                   player == nil,
                   setupPlayerTask == nil,
                   videoCellState != .failed {
                    transitionTo(.playerLoading)
                }

                if !shouldAcquirePlayer {
                    restoreForegroundRecoveryPosterIfNeeded(reason: "visibleWithoutInfrastructure")
                }
            }

            // Register delegate for video coordination (keyed by identifier so
            // the same video in a tweet + retweet gets separate delegates)
            if let id = videoIdentifier {
                (videoCoordinator ?? .shared).registerDelegate(self, forIdentifier: id)
            }
            updateReplayButtonVisibility()

            // If video was in failed state, trigger a fresh retry on becoming visible again.
            // Don't call clearPlayerForMediaID — disk cache is preserved for faster recovery.
            if isVideoAttachment && shouldAcquirePlayer && videoCellState == .failed {
                print("\(logPrefix) 🔄 Became visible with failed video - retrying")
                retryButton.isHidden = true
                if let url = attachment.getUrl(effectiveBaseUrl), let parentTweet = parentTweet {
                    transitionTo(imageView.image != nil ? .thumbnail : .noContent)
                    acquirePlayer(attachment: attachment, url: url, parentTweet: parentTweet)
                }
            }

            restoreVisibleLoadingStateIfNeeded(reason: "becameVisible")

            if isVideoAttachment && shouldAcquirePlayer {
                schedulePlayerAcquireIfNeeded()
            }

            // Setup foreground observer for images and videos
            setupForegroundObserver()
        } else {
            // Fullscreen and detail both borrow the feed's shared AVPlayer. During
            // those transitions UIKit may report the feed cell as windowless/invisible,
            // but tearing down the feed surface forces a pause/reattach cycle on return.
            if OverlayVisibilityCoordinator.shared.isCovered ||
                NavigationStateManager.shared.shouldPreserveFeedForDetailTransition {
                // Revert the isVisible flag — the cell is logically still visible
                isVisible = true
                return
            }
            if isVideoAttachment,
               let mid = self.attachment?.mid,
               let player,
               isSurfaceReturnHandoffPlayer(player, mid: mid) {
                // Revert before rebinding so the handoff path sees the feed cell as
                // the active surface again.
                isVisible = true
                resumeSurfaceReturnHandoffIfNeeded(reason: "setVisible(false)")
                return
            }
            replayButton.isHidden = true
            if let id = videoIdentifier {
                VideoStateCache.shared.clearVideoFinished(id)
            }
            if isHandlingFinishEvent, let player, isActuallyPlayerReady(player) {
                player.pause()
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                isHandlingFinishEvent = false
                cancelDelayedPrimarySpinner()
                loadingSpinner.stopAnimating()
            }

            // Cancel image loads
            imageLoadTask?.cancel()
            imageLoadTask = nil
            GlobalImageLoadManager.shared.cancelLoad(id: attachment.mid)

            // Clean up foreground observer
            if let observer = foregroundObserver {
                NotificationCenter.default.removeObserver(observer)
                foregroundObserver = nil
            }
            if let observer = imageCacheObserver {
                NotificationCenter.default.removeObserver(observer)
                imageCacheObserver = nil
            }

            // Unregister delegate (by identifier — won't accidentally remove another cell's delegate)
            if let id = videoIdentifier {
                (videoCoordinator ?? .shared).unregisterDelegate(forIdentifier: id)
            }

            // Cancel in-flight player acquisition task
            playerAcquireDebounceTask?.cancel()
            playerAcquireDebounceTask = nil
            setupPlayerTask?.cancel()
            setupPlayerTask = nil

            // Video-specific invisible handling
            if isVideoAttachment {
                if attachment.getUrl(effectiveBaseUrl) != nil {
                    SharedAssetCache.shared.markAsNotVisible(attachment.mid)
                    VideoStateCache.shared.markAsNotVisible(attachment.mid)
                    SharedAssetCache.shared.cancelLoadingForOutOfSightTweet(parentTweet?.mid ?? "")
                }

                // Capture frame, save position, pause, stop buffering
                if let player = player {
                    captureLastFrameIfPossible(reason: "becameInvisible", async: true)
                    if player.rate > 0 || coordinatorWantsToPlay {
                        saveCurrentPosition(player: player, wasPlaying: player.rate > 0)
                    }
                    player.pause()
                    player.isMuted = MuteState.shared.isMuted

                }
                releaseCurrentIndependentPlayer(reason: "becameInvisible", showCover: true)
                coordinatorWantsToPlay = false
            }
        }
    }

    var isActuallyPlaying: Bool {
        guard let player = player,
              player.currentItem != nil else { return false }
        // timeControlStatus == .playing means frames are actually rendering
        if player.timeControlStatus == .playing { return true }
        guard let item = player.currentItem else { return false }

        // rate > 0 + waitingToPlayAtSpecifiedRate = play() was called but buffering.
        // AVPlayer can also report a proxy/HLS buffer gap as paused while keeping a
        // healthy ready item, so keep coordinator ownership during the same grace.
        // Count this as active for a longer grace window so slow IPFS/proxy segments
        // can recover through AVPlayer's own stall handling instead of fighting the
        // coordinator restart loop while data is already arriving.
        if player.rate > 0
            || (coordinatorWantsToPlay && player.timeControlStatus == .waitingToPlayAtSpecifiedRate) {
            let bufferedAhead = bufferedTimeAhead(for: player)
            let keepUp = item.isPlaybackLikelyToKeepUp
            let requestGrace: TimeInterval = (bufferedAhead < 1.0 && !keepUp) ? 6.0 : 15.0
            let actualGrace: TimeInterval = 30.0
            return Date().timeIntervalSince(lastPlaybackRequestDate) < requestGrace
                || Date().timeIntervalSince(lastActualPlaybackDate) < actualGrace
        }

        if coordinatorWantsToPlay,
           videoCellState == .playing,
           item.status == .readyToPlay,
           player.timeControlStatus == .paused,
           !isVideoAtEnd(player) {
            let bufferedAhead = bufferedTimeAhead(for: player)
            return bufferedAhead > 0.25
                || Date().timeIntervalSince(lastPlaybackRequestDate) < 45.0
        }
        return false
    }

    var isVisiblePlaybackActive: Bool {
        guard coordinatorWantsToPlay,
              let player = player,
              player.currentItem != nil else { return false }
        return isVisibleVideoFrameReady(player)
            || hasRecentDecodedPlayback(for: player, maxAge: 1.5)
    }

    private func restoreVisibleLoadingStateIfNeeded(reason: String) {
        guard isVisible,
              isVideoAttachment,
              shouldAcquirePlayer,
              let mid = attachment?.mid else { return }

        let activePlayer: AVPlayer
        if let player {
            activePlayer = player
        } else if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: mid),
                  cachedPlayer.currentItem != nil {
            attachSharedPlayerForHandoff(cachedPlayer, reason: "restoreVisibleLoadingState-\(reason)")
            activePlayer = cachedPlayer
        } else {
            restoreForegroundRecoveryPosterIfNeeded(reason: "restoreVisibleLoadingState-\(reason)")
            return
        }

        guard let item = activePlayer.currentItem,
              !isVideoAtEnd(activePlayer),
              !isVisibleVideoFrameReady(activePlayer) else { return }

        if shouldSuppressPositionRestore(for: activePlayer, mid: mid) {
            requestPlaybackStartIfNeeded(activePlayer, reason: "restoreVisibleLoadingState-\(reason)-handoff")
            if coordinatorWantsToPlay,
               !isVisibleVideoFrameReady(activePlayer),
               !isVideoAtEnd(activePlayer) {
                showPrimarySpinnerAfterDebounce(for: activePlayer)
            }
            return
        }

        let isStillLoading = item.status == .unknown
            || activePlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
            || activePlayer.timeControlStatus == .paused
            || activePlayer.rate > 0

        guard isStillLoading else { return }

        restoreCachedPosterForFailureIfNeeded()
        let canKeepCurrentVisual = videoCellState == .paused
            || videoCellState == .playerReady
            || videoCellState == .playing

        if videoCellState != .playerLoading && !canKeepCurrentVisual {
            transitionTo(.playerLoading)
        }

        if coordinatorWantsToPlay {
            requestPlaybackStartIfNeeded(activePlayer, reason: "restoreVisibleLoadingState-\(reason)")
            updateLoadingSpinnerForPlayback(activePlayer)
        } else {
            loadingSpinner.startAnimating()
        }
    }

    private func shouldDeleteDiskCacheAfterPlayerFailure(_ error: NSError?) -> Bool {
        guard let error else { return true }
        guard error.domain == NSURLErrorDomain else { return true }

        let transientNetworkCodes: Set<Int> = [
            NSURLErrorUnknown,
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorDataNotAllowed,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorCallIsActive,
            NSURLErrorResourceUnavailable
        ]
        return !transientNetworkCodes.contains(error.code)
    }

    private var isCurrentCoordinatorPrimary: Bool {
        guard let videoIdentifier else { return false }
        return (videoCoordinator ?? .shared).primaryVideoId == videoIdentifier
    }

    @discardableResult
    private func scheduleAutomaticTransientRetryIfNeeded(errorMsg: String) -> Bool {
        let isPrimaryFailure = coordinatorWantsToPlay || isCurrentCoordinatorPrimary
        guard isVisible,
              isVideoAttachment,
              isPrimaryFailure,
              shouldAcquirePlayer,
              automaticTransientRetryTask == nil,
              automaticTransientRetryCount < 1 else { return false }

        automaticTransientRetryCount += 1
        let attempt = automaticTransientRetryCount
        print("\(logPrefix) 🔄 Scheduling immediate automatic transient video retry #\(attempt) (\(errorMsg))")

        automaticTransientRetryTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            defer { self.automaticTransientRetryTask = nil }
            guard !Task.isCancelled,
                  self.isVisible,
                  self.isVideoAttachment,
                  (self.coordinatorWantsToPlay || self.isCurrentCoordinatorPrimary),
                  self.shouldAcquirePlayer,
                  [
                    VideoCellState.failed,
                    .playerLoading,
                    .thumbnail,
                    .noContent
                  ].contains(self.videoCellState) else { return }

            print("\(self.logPrefix) 🔄 Automatic transient video retry #\(attempt)")
            self.retryVideoLoad(isAutomatic: true)
        }
        return true
    }

    /// True when coordinator commanded play but the player/item is still being acquired or loaded.
    /// Prevents false stall detection: IPFS/HLS can take >3s before play() is even callable.
    /// Returns false once item fails (.failed) or becomes ready (.readyToPlay), so genuine stalls
    /// (item never transitions out of .unknown) are eventually caught by the stall detector's
    /// buffering timeout in isActuallyPlaying.
    var isLoadingForCoordinator: Bool {
        guard coordinatorWantsToPlay else { return false }
        if !AppDelegate.isVideoInfrastructureReady {
            return true
        }
        if let deadline = foregroundRecoveryLoadingDeadline,
           Date() > deadline {
            print("\(logPrefix) ⏱️ foreground recovery loading deadline exceeded - allowing coordinator restart")
            return false
        }
        if setupPlayerTask != nil || playerAcquireDebounceTask != nil {
            return true
        }
        guard let item = player?.currentItem else { return false }
        if item.status == .unknown {
            return true
        }
        return false
    }

    var isRecentlyPlaying: Bool {
        coordinatorWantsToPlay
            && videoCellState == .playing
            && Date().timeIntervalSince(lastActualPlaybackDate) < 5.0
    }

    var isVideoAttachment: Bool {
        guard let attachment else { return false }
        return attachment.type == .video || attachment.type == .hls_video
    }

    private func updateEffectiveBaseUrl() {
        let newBaseUrl = parentTweet?.author?.baseUrl
            ?? HproseInstance.shared.appUser.baseUrl
            ?? HproseInstance.baseUrl
        if effectiveBaseUrl != newBaseUrl {
            effectiveBaseUrl = newBaseUrl
        }
    }

    private func setupForegroundObserver() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isVisible, let att = self.attachment else { return }

            if att.type == .image {
                // Reload image if it was purged during background
                if self.imageView.image == nil, let url = att.getUrl(self.effectiveBaseUrl) {
                    self.loadImage(attachment: att, url: url)
                }
            } else if self.isVideoAttachment {
                self.suppressFeedResumeUntil = Date().addingTimeInterval(Self.foregroundFeedResumeSuppressionDuration)
                // During backgrounding, clearVideoPlayersForBackgroundRecovery() calls
                // replaceCurrentItem(with: nil) on all players and clears the cache.
                // Our self.player still references the now-dead player (no currentItem).
                // We must discard it and let the coordinator re-acquire a fresh player.
                if let player = self.player,
                   player.currentItem == nil || player.currentTime().seconds.isNaN {
                    // Re-acquire a fresh player — coordinator will send play
                    // command via updateVisibleTweets if this is the primary video.
                    // Not calling handleCoordinatorPlayCommand() here prevents
                    // non-primary videos from briefly playing then getting stopped
                    // before they can render a frame (which causes black screen).
                    _ = self.reacquirePlayerForCurrentVideo(
                        reason: "willEnterForeground.invalidPlayer",
                        runFullSetup: true,
                        wantsPlayback: false
                    )
                } else {
                    // Player is still valid (short background). AVPlayerLayer's render
                    // pipeline is suspended — handled by TVC's didBecomeActive observer
                    // which calls refreshVideoLayerAfterForeground() when GPU is ready.
                }
            }
        }
    }

    private var hasPlaybackCoverForCurrentVideo: Bool {
        imageView.image != nil
            || hasRenderedFrameForCurrentPlayer
            || videoPlayerView.isLayerReadyForDisplay
            || lastActualPlaybackDate != .distantPast
            || lastPlaybackProgressDate != .distantPast
            || lastDecodedPlaybackProgressDate != .distantPast
    }

    private var canShowCachedCoverForCurrentVideo: Bool {
        if player != nil,
           currentPlayerCanReplaceCover {
            return false
        }
        if videoPlayerView.isLayerReadyForDisplay || hasRenderedFrameForCurrentPlayer {
            return false
        }
        if hasPlaybackCoverForCurrentVideo { return true }
        guard let mid = attachment?.mid else { return false }
        if SharedAssetCache.shared.hasPreloadedThumbnail(for: mid) { return true }
        guard SharedAssetCache.shared.cachedThumbnail(for: mid) != nil else { return false }

        switch videoCellState {
        case .noContent, .thumbnail, .playerLoading, .playerReady, .playing, .paused, .failed:
            return true
        }
    }

    /// Release foreground media state before the global background cleanup runs.
    /// Video cells keep a poster, and image cells keep only a small cover image for the app switcher.
    func prepareForBackground() {
        if isVideoAttachment {
            prepareVideoForBackground()
        } else if attachment?.type == .image {
            prepareImageForBackground()
        }
    }

    /// Save playback state, cover the cell with a poster, and release local player state.
    /// Background cleanup drops every AVPlayer; the onscreen snapshot should be an image.
    private func prepareVideoForBackground() {
        guard isVideoAttachment, isVisible else { return }
        guard videoCellState == .playing || videoCellState == .paused || videoCellState == .playerReady else { return }
        guard let mid = attachment?.mid else { return }

        if let player {
            saveCurrentPosition(player: player, wasPlaying: player.rate > 0 || coordinatorWantsToPlay)
            player.pause()
            player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        }

        let didCaptureCover = preserveReleaseCoverForCurrentVideo(reason: "background", showCover: true)
        if didCaptureCover || restoreCachedPosterForBackgroundIfNeeded(mid: mid) {
            isHoldingBackgroundVideoCover = true
            backgroundVideoCoverMid = mid
            SharedAssetCache.shared.protectBackgroundPoster(for: mid)
            transitionTo(.thumbnail)
        } else if videoPlayerView.isLayerReadyForDisplay {
            hasRenderedFrameForCurrentPlayer = true
            videoPlayerView.isHidden = false
            hideImageViewImmediately()
        }
        coordinatorWantsToPlay = false
        playbackStartupRecoveryTask?.cancel()
        playbackStartupRecoveryTask = nil
        playbackStartupRecoveryRequestDate = nil
        playbackStartupRecoveryDelay = nil
        statusUnknownFallbackTask?.cancel()
        statusUnknownFallbackTask = nil
        cancelDelayedPrimarySpinner()
        loadingSpinner.stopAnimating()
        teardownPlayerAndObservers()
    }

    private func prepareImageForBackground() {
        guard isVisible, let attachment, attachment.type == .image else { return }

        imageLoadTask?.cancel()
        imageLoadTask = nil
        GlobalImageLoadManager.shared.cancelLoad(id: attachment.mid)
        loadingSpinner.stopAnimating()
        retryButton.isHidden = true

        guard let image = imageView.image else { return }
        let displayedMaxDimension = max(bounds.width, bounds.height) * UIScreen.main.scale
        let coverMaxDimension = max(240, min(480, displayedMaxDimension))
        imageView.image = VideoFrameExtractor.downscale(image, maxDimension: coverMaxDimension)
        imageView.isHidden = false
    }

    private func restoreCachedPosterForBackgroundIfNeeded(mid: String) -> Bool {
        guard imageView.image == nil,
              let cached = SharedAssetCache.shared.cachedThumbnail(for: mid) else {
            return imageView.image != nil
        }
        imageView.image = cached
        return true
    }

    /// Refresh visible playback after foreground without tearing down a healthy layer.
    /// Called from didBecomeActive when GPU is guaranteed ready.
    func refreshVideoLayerAfterForeground() {
        guard isVideoAttachment else { return }
        guard let player else {
            if coordinatorWantsToPlay {
                restoreForegroundRecoveryPosterIfNeeded(reason: "foreground-layer.missingPlayer")
                _ = reacquirePlayerForCurrentVideo(reason: "foreground-layer.missingPlayer")
            }
            return
        }

        guard videoCellState == .playerLoading ||
              videoCellState == .playerReady ||
              videoCellState == .paused ||
              videoCellState == .playing else { return }

        if player.currentItem == nil || !player.currentTime().seconds.isFinite {
            _ = reacquirePlayerForCurrentVideo(
                reason: "foreground-layer.invalidPlayer",
                runFullSetup: true,
                wantsPlayback: coordinatorWantsToPlay
            )
            return
        }

        let didSettleCachedPlayer = settleForegroundCachedPlayerIfReady(player, reason: "foreground-layer-start")

        let expectedMid = attachment?.mid
        let currentTime = player.currentTime()
        let isLiveHandoff: Bool
        if let expectedMid {
            isLiveHandoff = shouldSuppressPositionRestore(for: player, mid: expectedMid)
        } else {
            isLiveHandoff = false
        }
        let savedResumeTime = isLiveHandoff ? nil : expectedMid.flatMap { savedFeedResumeTime(for: $0, player: player) }
        let needsResumeSeek = !(currentTime.isValid && currentTime.seconds.isFinite && currentTime.seconds > 0.25)
        if needsResumeSeek, let savedResumeTime {
            pendingRecoverySeekTime = savedResumeTime
        }

        if videoPlayerView.isLayerReadyForDisplay {
            hasRenderedFrameForCurrentPlayer = true
        } else {
            videoPlayerView.onReadyForDisplay = { [weak self, weak player] in
                guard let self,
                      let player,
                      self.player === player,
                      self.attachment?.mid == expectedMid else { return }
                self.hasRenderedFrameForCurrentPlayer = true
                if self.coordinatorWantsToPlay {
                    self.requestPlaybackStartIfNeeded(player, reason: "foreground-layer-ready")
                    self.updateLoadingSpinnerForPlayback(player)
                    if self.isVisibleVideoFrameReady(player) {
                        self.fadeOutVideoCoverForPlayback()
                    }
                } else if self.videoCellState == .playerLoading {
                    self.transitionTo(.playerReady)
                }
            }
            videoPlayerView.observeReadyForDisplay()
        }

        if needsResumeSeek, let savedResumeTime {
            player.seek(to: savedResumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        if coordinatorWantsToPlay {
            if isVisibleVideoFrameReady(player) {
                fadeOutVideoCoverForPlayback()
            } else {
                requestPlaybackStartIfNeeded(player, reason: "foreground-layer-refresh")
            }
            if !didSettleCachedPlayer {
                updateLoadingSpinnerForPlayback(player)
            }
        }

        Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self,
                  let player,
                  self.player === player,
                  self.attachment?.mid == expectedMid,
                  self.isActuallyPlayerReady(player) else { return }

            if self.videoPlayerView.isLayerReadyForDisplay {
                self.hasRenderedFrameForCurrentPlayer = true
            }

            let didSettleCachedPlayer = self.settleForegroundCachedPlayerIfReady(player, reason: "foreground-layer-delayed")

            if self.coordinatorWantsToPlay {
                if self.isVisibleVideoFrameReady(player) {
                    self.fadeOutVideoCoverForPlayback()
                    self.updateLoadingSpinnerForPlayback(player)
                    return
                }
                self.requestPlaybackStartIfNeeded(player, reason: "foreground-layer-refresh-fallback")
                if !didSettleCachedPlayer {
                    self.updateLoadingSpinnerForPlayback(player)
                }
            } else if self.videoCellState == .playerLoading {
                self.transitionTo(.playerReady)
                self.loadingSpinner.stopAnimating()
            }
        }
    }

    // MARK: - MediaCellDelegate

    func shouldPlayVideo(withMid mid: String) {
        guard mid == attachment?.mid else { return }
        handleCoordinatorPlayCommand()
    }

    func shouldPauseVideo(withMid mid: String) {
        guard mid == attachment?.mid else { return }
        handleCoordinatorPauseCommand()
    }

    func shouldStopVideo(withMid mid: String) {
        guard mid == attachment?.mid else { return }
        handleCoordinatorStopCommand()
    }

    func shouldStopAllVideos() {
        guard isVideoAttachment else { return }
        handleStopAllVideos()
    }

    func updateVideoTimer(withMid mid: String, timeRemaining: String) {
        // Handled by notification listener
    }

    func appDidBecomeActive() {
        updateEffectiveBaseUrl()
    }

    func userDidUpdate(userId: String) {
        if userId == parentTweet?.authorId {
            updateEffectiveBaseUrl()
        }
    }

    // MARK: - Cleanup

    private func releaseDetachedPlayer(_ player: AVPlayer) {
        player.pause()
        player.rate = 0

        if let item = player.currentItem {
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            item.asset.cancelLoading()
            NotificationCenter.default.removeObserver(item)
        }

        player.replaceCurrentItem(with: nil)
    }

    private func releaseCurrentIndependentPlayer(
        reason: String,
        showCover: Bool,
        expectedPlayer: AVPlayer? = nil
    ) {
        guard usesIndependentPlayerInstance,
              let currentPlayer = player else { return }
        if let expectedPlayer, currentPlayer !== expectedPlayer {
            return
        }

        if isVideoAttachment {
            preserveReleaseCoverForCurrentVideo(reason: reason, showCover: showCover)
        }

        removePlayerObservers()
        removePlayerTimeObserver()

        if let item = videoOutputAttachedItem, let output = videoOutput {
            item.remove(output)
        }
        videoOutput = nil
        videoOutputAttachedItem = nil

        videoPlayerView.onReadyForDisplay = nil
        videoPlayerView.setPlayer(nil)
        hasRenderedFrameForCurrentPlayer = false
        player = nil
        Self.unregisterIndependentFeedPlayer(owner: self)

        releaseDetachedPlayer(currentPlayer)

        if showCover {
            if imageView.image != nil {
                transitionTo(.thumbnail)
            } else {
                transitionTo(.noContent)
                loadingSpinner.stopAnimating()
            }
        }
    }

    private func cleanupVideoPlayer(reason: String, preserveBackgroundCover: Bool = false) {
        if isVideoAttachment {
            preserveReleaseCoverForCurrentVideo(reason: reason, showCover: isVisible)
        }

        // Cancel any pending debounce — prevents player acquisition after cleanup.
        playerAcquireDebounceTask?.cancel()
        playerAcquireDebounceTask = nil

        let hasWork =
            setupPlayerTask != nil ||
            slowLoadingRecoveryTask != nil ||
            playbackStartupRecoveryTask != nil ||
            playbackProgressWatchdogTask != nil ||
            videoOutput != nil ||
            videoOutputAttachedItem != nil ||
            timeObserverToken != nil ||
            player != nil ||
            playerItemStatusObserver != nil ||
            playerItemLoadedTimeRangesObserver != nil ||
            timeControlStatusObserver != nil ||
            videoCompletionObserver != nil ||
            stopAllObserver != nil ||
            playerClaimedObserver != nil ||
            videoThumbnailObserver != nil ||
            videoPlayerPreloadedObserver != nil ||
            videoPlayerItemReplacedObserver != nil ||
            shouldPlayObserver != nil ||
            shouldPauseObserver != nil ||
            shouldStopObserver != nil ||
            !(videoPlayerView.gestureRecognizers?.isEmpty ?? true) ||
            !(imageView.gestureRecognizers?.isEmpty ?? true)


        if hasWork {
            teardownPlayerAndObservers()
        }
        resetVideoState(preserveBackgroundCover: preserveBackgroundCover)
    }

    /// Cancel tasks, remove all observers, detach player from layer, nil player.
    private func teardownPlayerAndObservers() {
        setupPlayerTask?.cancel()
        setupPlayerTask = nil
        slowLoadingRecoveryTask?.cancel()
        slowLoadingRecoveryTask = nil
        statusUnknownFallbackTask?.cancel()
        statusUnknownFallbackTask = nil
        automaticTransientRetryTask?.cancel()
        automaticTransientRetryTask = nil
        cancelDelayedPrimarySpinner()
        playbackStartupRecoveryTask?.cancel()
        playbackStartupRecoveryTask = nil
        playbackStartupRecoveryRequestDate = nil
        playbackStartupRecoveryDelay = nil
        playbackProgressWatchdogTask?.cancel()
        playbackProgressWatchdogTask = nil

        videoPlayerView.onReadyForDisplay = nil

        removePlayerObservers()

        if let o = stopAllObserver { NotificationCenter.default.removeObserver(o) }
        stopAllObserver = nil
        if let o = playerClaimedObserver { NotificationCenter.default.removeObserver(o) }
        playerClaimedObserver = nil
        if let o = videoThumbnailObserver { NotificationCenter.default.removeObserver(o) }
        videoThumbnailObserver = nil
        if let o = videoPlayerPreloadedObserver { NotificationCenter.default.removeObserver(o) }
        videoPlayerPreloadedObserver = nil
        if let o = videoPlayerItemReplacedObserver { NotificationCenter.default.removeObserver(o) }
        videoPlayerItemReplacedObserver = nil
        if let o = shouldPlayObserver { NotificationCenter.default.removeObserver(o) }
        shouldPlayObserver = nil
        if let o = shouldPauseObserver { NotificationCenter.default.removeObserver(o) }
        shouldPauseObserver = nil
        if let o = shouldStopObserver { NotificationCenter.default.removeObserver(o) }
        shouldStopObserver = nil

        // Detach video output on background queue to avoid blocking main thread
        if let item = videoOutputAttachedItem, let output = videoOutput {
            DispatchQueue.global(qos: .utility).async {
                item.remove(output)
            }
        }
        videoOutput = nil
        videoOutputAttachedItem = nil

        removePlayerTimeObserver()

        videoPlayerView.setPlayer(nil)
        hasRenderedFrameForCurrentPlayer = false
        videoPlayerView.isHidden = true
        videoPlayerView.gestureRecognizers?.forEach { videoPlayerView.removeGestureRecognizer($0) }
        imageView.gestureRecognizers?.forEach { imageView.removeGestureRecognizer($0) }
        let detachedPlayer = player
        player = nil
        Self.unregisterIndependentFeedPlayer(owner: self)
        if usesIndependentPlayerInstance, let detachedPlayer {
            releaseDetachedPlayer(detachedPlayer)
        }
    }

    /// Reset all video-related flags and counters to initial values.
    private func resetVideoState(preserveBackgroundCover: Bool = false) {
        coordinatorWantsToPlay = false
        isHandlingFinishEvent = false
        videoCellState = .noContent
        cancelDelayedPrimarySpinner()
        replayButton.isHidden = true
        lastFrameCaptureAt = .distantPast
        lastActualPlaybackDate = .distantPast
        hasRenderedFrameForCurrentPlayer = false
        lastPlaybackRequestDate = .distantPast
        bufferingWaitCount = 0
        lastBufferingWaitDate = .distantPast
        lastBufferingWaitPositionBucket = -1
        lastBufferingWaitLogKey = nil
        lastBufferingWaitLogDate = .distantPast
        lastSlowLoadWaitLogDate = .distantPast
        didLogFirstDecodedPlayback = false
        didLogFirstPlaybackProgress = false
        slowLoadingRecoveryTask?.cancel()
        slowLoadingRecoveryTask = nil
        lastSlowLoadingNudgeDate = .distantPast
        lastStartupBufferReleaseDate = .distantPast
        startupBufferReleaseUntil = .distantPast
        hlsBufferedUnknownStartDate = .distantPast
        hlsEmptyWaitingStartDate = .distantPast
        hlsActiveSegmentWaitStartDate = .distantPast
        hlsActiveSegmentWaitMediaID = nil
        if !preserveBackgroundCover {
            clearBackgroundVideoCoverHold()
        }
        requestedFallbackThumbnailMid = nil
        resetFeedPlayerRebuildBudget()
        resetPlaybackProgressTracking()
        resetDecodedPlaybackTracking()
        lastLoggedTimeControlStatus = nil
        lastLoggedTimeControlBucket = -1
        lastLoggedTimeControlDate = .distantPast
    }

    private func removeAudioHosting() {
        if let hc = audioHostingController {
            hc.willMove(toParent: nil)
            hc.view.removeFromSuperview()
            hc.removeFromParent()
            audioHostingController = nil
        }
    }

    func prepareForReuse() {
        // Cancel loads
        imageLoadTask?.cancel()
        imageLoadTask = nil
        timerHideTask?.cancel()
        timerHideTask = nil
        statusUnknownFallbackTask?.cancel()
        statusUnknownFallbackTask = nil
        automaticTransientRetryTask?.cancel()
        automaticTransientRetryTask = nil
        automaticTransientRetryCount = 0
        playbackStartupRecoveryTask?.cancel()
        playbackStartupRecoveryTask = nil
        playbackStartupRecoveryRequestDate = nil
        cancellables.removeAll()

        if let att = attachment {
            GlobalImageLoadManager.shared.cancelLoad(id: att.mid)
            if let id = videoIdentifier {
                (videoCoordinator ?? .shared).unregisterDelegate(forIdentifier: id)
            }
        }

        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
        if let observer = imageCacheObserver {
            NotificationCenter.default.removeObserver(observer)
            imageCacheObserver = nil
        }
        if let observer = videoThumbnailObserver {
            NotificationCenter.default.removeObserver(observer)
            videoThumbnailObserver = nil
        }
        if let observer = videoPlayerPreloadedObserver {
            NotificationCenter.default.removeObserver(observer)
            videoPlayerPreloadedObserver = nil
        }

        // Clean up video BEFORE clearing imageView — preserveFrameToCache can use
        // imageView.image (Priority 1) and videoPlayerView visibility (Priority 3)
        // to keep a valid cover frame during teardown.
        cleanupVideoPlayer(reason: "prepareForReuse")
        removeAudioHosting()

        // Reset UI (after video cleanup so frame is preserved in cache)
        imageView.image = nil
        imageView.isHidden = true
        imageView.gestureRecognizers?.forEach { imageView.removeGestureRecognizer($0) }
        loadingSpinner.stopAnimating()
        retryButton.isHidden = true
        replayButton.isHidden = true
        muteButton.isHidden = true
        timerLabel.isHidden = true
        timerLabelVideoMid = nil
        // Reset state
        pendingRecoverySeekTime = nil
        videoCellState = .noContent
        isEmbeddedMedia = false
        attachment = nil
        parentTweet = nil
        isVisible = false
        shouldAcquirePlayer = true
    }

    deinit {
        if let id = videoIdentifier {
            let coordinator = videoCoordinator
            Task { @MainActor in
                (coordinator ?? .shared).unregisterDelegate(forIdentifier: id)
            }
        }
        if let att = attachment {
            let mid = att.mid
            Task { @MainActor in
                GlobalImageLoadManager.shared.cancelLoad(id: mid)
            }
        }
        imageLoadTask?.cancel()
        imageLoadTask = nil
        timerHideTask?.cancel()
        timerHideTask = nil
        cancellables.removeAll()

        cleanupVideoPlayer(reason: "deinit")
        removeAudioHosting()

        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
        if let o = imageCacheObserver {
            NotificationCenter.default.removeObserver(o)
            imageCacheObserver = nil
        }
    }
}
