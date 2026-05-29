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

// MARK: - MediaCellUIView

class MediaCellUIView: UIView, MediaCellDelegate {

    // MARK: - Subviews

    private let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = .systemGray6
        return iv
    }()

    /// Pure UIKit video player (AVPlayerLayer) — replaces UIHostingController<SimpleVideoPlayer>
    private let videoPlayerView: LightweightVideoPlayerView = {
        let v = LightweightVideoPlayerView()
        v.backgroundColor = .black
        v.clipsToBounds = true
        v.isHidden = true
        // Fill container (clip overflow) — matches SimpleVideoPlayer's .resizeAspectFill for feed cells
        v.setVideoGravity(.resizeAspectFill)
        return v
    }()

    private let loadingSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.hidesWhenStopped = true
        return spinner
    }()

    /// Retry button shown when image download fails
    private lazy var retryButton: UIButton = {
        let btn = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        btn.setImage(UIImage(systemName: "arrow.clockwise.circle", withConfiguration: config), for: .normal)
        btn.tintColor = .white.withAlphaComponent(0.7)
        btn.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        btn.isHidden = true
        return btn
    }()

    /// Mute button background circle (26pt visual, inside 44pt touch area)
    private let muteCircleLayer: CALayer = {
        let layer = CALayer()
        layer.backgroundColor = UIColor.black.withAlphaComponent(0.2).cgColor
        layer.cornerRadius = 13
        return layer
    }()

    /// Mute button (only for single-video tweets) — 44pt touch area, 26pt visual circle
    private lazy var muteButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.tintColor = .white.withAlphaComponent(0.6)
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
        label.textColor = .white.withAlphaComponent(0.4)
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        label.layer.cornerRadius = 13
        label.clipsToBounds = true
        label.isHidden = true
        return label
    }()

    /// Fullscreen loading overlay
    private let fullscreenSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        return spinner
    }()
    private let fullscreenOverlay: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        v.clipsToBounds = true
        v.isHidden = true
        return v
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
    private var timeControlStatusObserver: NSKeyValueObservation?
    /// Buffer-recovery observer. AVPlayer normally resumes from short buffer drains,
    /// but HLS/proxy delivery can still leave it waiting; keep this as a backup so
    /// the selected video gets another play command when data catches up.
    private var playbackLikelyToKeepUpObserver: NSKeyValueObservation?

    /// Notification observers
    private var videoCompletionObserver: NSObjectProtocol?
    private var stopAllObserver: NSObjectProtocol?
    private var playerLoanedObserver: NSObjectProtocol?
    private var playerClaimedObserver: NSObjectProtocol?
    private var videoThumbnailObserver: NSObjectProtocol?
    private var videoPlayerPreloadedObserver: NSObjectProtocol?
    private var shouldPlayObserver: NSObjectProtocol?
    private var shouldPauseObserver: NSObjectProtocol?
    private var shouldStopObserver: NSObjectProtocol?

    /// Async player acquisition task
    private var setupPlayerTask: Task<Void, Never>?

    /// Debounce task that delays player acquisition during fast scroll.
    /// Cancelled if the cell scrolls off-screen within 0.3s of configure().
    private var playerAcquireDebounceTask: Task<Void, Never>?

    /// Fallback task: if item.status stays .unknown after deferring to statusKVO,
    /// enable network and kick playback after a delay (same as deadlock fix).
    private var statusUnknownFallbackTask: Task<Void, Never>?
    /// Defers the primary spinner for cached/covered videos so instant starts do
    /// not flash loading chrome over an already-present frame.
    private var delayedPrimarySpinnerTask: Task<Void, Never>?
    /// Recovery for ready players that were promoted from preload but remain
    /// stuck at the first buffer gap after play() was requested.
    private var playbackStartupRecoveryTask: Task<Void, Never>?
    private var playbackStartupRecoveryRequestDate: Date?

    /// Periodic time observer token for the video timer label
    private var timeObserverToken: Any?
    /// The player that owns timeObserverToken — must remove from the same instance.
    private weak var timeObserverPlayer: AVPlayer?

    /// Frame capture throttle
    private var lastFrameCaptureAt: Date = .distantPast

    /// Last time AVPlayer confirmed playing (timeControlStatus == .playing).
    /// Used by stall-check to distinguish HLS buffer gaps from genuine stalls.
    private var lastActualPlaybackDate: Date = .distantPast
    /// True after the current AVPlayerLayer has rendered a frame for this player.
    /// This lets visible non-primary videos stop their spinner once they have
    /// something real to show, even if frame capture did not produce a poster.
    private var hasRenderedFrameForCurrentPlayer: Bool = false
    /// Last time this cell asked AVPlayer to play. This is intent only; it is
    /// intentionally separate from lastActualPlaybackDate.
    private var lastPlaybackRequestDate: Date = .distantPast
    private var lastPlaybackNudgeDate: Date = .distantPast
    private var pendingRecoverySeekTime: CMTime?
    private var lastLoggedTimeControlStatus: AVPlayer.TimeControlStatus?
    private var lastLoggedTimeControlBucket: Int = -1
    private var lastLoggedTimeControlDate: Date = .distantPast


    /// Prevent duplicate finish handling
    private var isHandlingFinishEvent: Bool = false

    /// Tracks when the player was loaned to detail view; enables fast-path reclaim on return
    private var playerWasLoaned: Bool = false

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
    private var shouldLoadVideo: Bool = true
    private var isVisible: Bool = false
    private var effectiveBaseUrl: URL = HproseInstance.baseUrl
    private var isSingleMedia: Bool = false
    private weak var parentViewController: UIViewController?
    private var shouldAcquirePlayerWhenVisible: Bool = true

    /// Matches VideoPlaybackInfo.identifier format: cellTweetId_videoMid_attachmentIndex.
    /// Used to register/unregister delegate independently per feed cell, so the same video
    /// appearing in both a tweet and its retweet gets separate delegates.
    var videoIdentifier: String? {
        guard let attachment else { return nil }
        let cell = cellTweetId ?? parentTweet?.mid ?? ""
        return "\(cell)_\(attachment.mid)_\(attachmentIndex)"
    }

    private var imageLoadTask: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var timerHideTask: DispatchWorkItem?

    private let imageCache = ImageCacheManager.shared

    // Logging helper
    private var logPrefix: String {
        let mid = attachment?.mid ?? "nil"
        let shortMid = mid.count > 8 ? String(mid.prefix(8)) : mid
        return "[VIDEO-\(shortMid)]"
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
        addSubview(fullscreenOverlay)
        fullscreenOverlay.addSubview(fullscreenSpinner)
        addSubview(muteButton)
        addSubview(timerLabel)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil && isVisible {
            setVisible(false)
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
        fullscreenOverlay.frame = b
        fullscreenSpinner.center = CGPoint(x: b.midX, y: b.midY)

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

        // Timer label: bottom-left, 6pt padding
        if !timerLabel.isHidden {
            let timerSize = timerLabel.sizeThatFits(CGSize(width: 100, height: 24))
            let timerW = timerSize.width + 16
            let timerH: CGFloat = 24
            timerLabel.frame = CGRect(
                x: 6,
                y: b.maxY - timerH - 6,
                width: timerW, height: timerH
            )
        }

        audioHostingController?.view.frame = b
    }

    // MARK: - Video Cell State Machine

    /// Single source of truth for video cell visibility.
    /// imageView is NEVER shown with nil image — either it has content or it's hidden.
    private func transitionTo(_ state: VideoCellState) {
        let oldState = videoCellState
        videoCellState = state

        // Log state transitions
        if oldState != state {
            print("\(logPrefix) State: \(oldState) → \(state)")
        }

        // Hide retry button when leaving .failed state
        if state != .failed {
            retryButton.isHidden = true
        }

        switch state {
        case .noContent:
            imageView.isHidden = true
            videoPlayerView.isHidden = false  // black backdrop for spinner
            if coordinatorWantsToPlay || shouldShowVisibleVideoCoverSpinner(hasCover: false) {
                loadingSpinner.startAnimating()
            } else {
                loadingSpinner.stopAnimating()
            }
        case .thumbnail:
            imageView.isHidden = false  // caller must set imageView.image before this
            videoPlayerView.isHidden = true
            // If this is the selected video, a newly captured cover frame should not
            // briefly dismiss loading feedback before AVPlayer is actually playing.
            if coordinatorWantsToPlay {
                loadingSpinner.startAnimating()
            } else {
                loadingSpinner.stopAnimating()
            }
        case .playerLoading:
            let hasThumbnail = imageView.image != nil
            imageView.isHidden = !hasThumbnail
            // Hide videoPlayerView when thumbnail exists — the player hasn't rendered
            // a frame yet so it would show black on top of the thumbnail. The layer
            // still decodes in the background; onReadyForDisplay → .playerReady will
            // show it once the first frame is available.
            videoPlayerView.isHidden = hasThumbnail
            // Primary videos always show loading chrome. Visible non-primary videos
            // also show it until their cover frame arrives; off-screen preloads stay quiet.
            if coordinatorWantsToPlay || shouldShowVisibleVideoCoverSpinner() {
                loadingSpinner.startAnimating()
            } else {
                loadingSpinner.stopAnimating()
            }
        case .playerReady:
            let hasThumbnail = imageView.image != nil
            let hasDisplayableCover = hasVideoCoverForSpinner
            // Always keep thumbnail visible as cover — prevents black flash during buffering.
            // Thumbnail is hidden only when smooth playback begins (timeControlStatus KVO).
            imageView.isHidden = !hasThumbnail
            if hasThumbnail && !coordinatorWantsToPlay {
                // Non-primary video: hide player layer (no need to decode yet)
                    videoPlayerView.isHidden = true
            } else {
                // Primary video or no thumbnail: show player layer (decodes underneath thumbnail)
                videoPlayerView.isHidden = false
            }
            // With streaming, the first frame can render before playback can continue.
            // Keep primary feedback on, and keep visible non-primary feedback on until
            // a cover frame exists. Off-screen preloads should not show spinner chrome.
            if coordinatorWantsToPlay && !shouldDelayPrimarySpinner(for: player) {
                loadingSpinner.startAnimating()
            } else if shouldShowVisibleVideoCoverSpinner(hasCover: hasDisplayableCover) {
                loadingSpinner.startAnimating()
            } else {
                loadingSpinner.stopAnimating()
            }
        case .playing, .paused:
            videoPlayerView.isHidden = false
            // Spinner stays on as long as the video is supposed to be playing but isn't
            // actually rendering frames yet — covers the transient .paused window between
            // play() and the first .waitingToPlayAtSpecifiedRate / .playing KVO callback.
            if state == .playing,
               let player = self.player,
               player.timeControlStatus != .playing,
               !isVideoAtEnd(player) {
                loadingSpinner.startAnimating()
            } else {
                loadingSpinner.stopAnimating()
            }
            // Keep thumbnail as cover until player is confirmed smooth-playing.
            // This prevents black flash during buffering, retries, and fullscreen return.
            // Always keep thumbnail as cover during state transitions.
            // timeControlStatus KVO is the sole authority for hiding it
            // once smooth playback is confirmed — prevents stale isLayerReadyForDisplay
            // from prematurely revealing wrong frames during seek/resume.
            imageView.isHidden = (imageView.image == nil)
        case .failed:
            // Prefer thumbnail (captured from last rendered frame) over black backdrop.
            // cleanupFailedPlayerState nils the player before we get here, so rely on
            // imageView which was set by preserveFrameToCache() earlier in the failure path.
            if imageView.image != nil {
                imageView.isHidden = false
                videoPlayerView.isHidden = true
            } else {
                // No thumbnail — show videoPlayerView as black backdrop
                imageView.isHidden = true
                videoPlayerView.isHidden = false
            }
            loadingSpinner.stopAnimating()
            retryButton.isHidden = false
        }
    }

    private var hasVideoCoverForSpinner: Bool {
        imageView.image != nil || hasRenderedFrameForCurrentPlayer
    }

    private func shouldShowVisibleVideoCoverSpinner(hasCover: Bool? = nil) -> Bool {
        isVisible && isVideoAttachment && shouldLoadVideo && !(hasCover ?? hasVideoCoverForSpinner)
    }

    // MARK: - Configure

    func configure(
        parentTweet: Tweet,
        attachmentIndex: Int,
        aspectRatio: Float,
        shouldLoadVideo: Bool,
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
            self.parentViewController = parentViewController
            return
        }

        self.parentTweet = parentTweet
        self.attachmentIndex = attachmentIndex
        self.aspectRatio = aspectRatio
        self.shouldLoadVideo = shouldLoadVideo
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

        // Tap gesture (all media — including embedded tweets — opens fullscreen)
        let tap = UITapGestureRecognizer(target: self, action: #selector(imageTapped))
        imageView.addGestureRecognizer(tap)
        imageView.isUserInteractionEnabled = true

        if isVisible {
            loadImage(attachment: attachment, url: url)
        } else if let cached = imageCache.getCompressedImageFromMemory(for: attachment) {
            imageView.image = cached
        }
    }

    private func loadImage(attachment: MimeiFileType, url: URL) {
        guard isVisible else { return }

        // 1. Memory cache (synchronous)
        if let cached = imageCache.getCompressedImageFromMemory(for: attachment) {
            imageView.image = cached
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
        pendingRecoverySeekTime = nil
        cleanupVideoPlayer(reason: "setupVideoCell")

        // Set spinner color for video (white on dark background)
        loadingSpinner.color = .white.withAlphaComponent(0.7)

        // Set initial state from cached-media thumbnail source.
        if let cachedFrame = SharedAssetCache.shared.cachedThumbnail(for: attachment.mid) {
            imageView.image = cachedFrame
            transitionTo(.thumbnail)
        } else {
            transitionTo(.noContent)
            // Try to generate thumbnail from cached asset
            SharedAssetCache.shared.generateThumbnailIfNeeded(for: attachment.mid) { [weak self] image in
                guard let self, self.attachment?.mid == attachment.mid else { return }
                self.applyCachedVideoThumbnail(image)
            }
        }
        observeCachedVideoThumbnail(for: attachment.mid)
        observePreloadedVideoPlayer(for: attachment.mid)

        // Tap gesture for fullscreen — on both videoPlayerView and imageView so that
        // any visible video is tappable (thumbnail state or non-primary use imageView).
        let tap = UITapGestureRecognizer(target: self, action: #selector(videoTapped))
        videoPlayerView.addGestureRecognizer(tap)
        videoPlayerView.isUserInteractionEnabled = true
        let imageTap = UITapGestureRecognizer(target: self, action: #selector(videoTapped))
        imageView.addGestureRecognizer(imageTap)
        imageView.isUserInteractionEnabled = true

        // Listen for .stopAllVideos (posted by non-coordinator code like handleVideoTap)
        stopAllObserver = NotificationCenter.default.addObserver(
            forName: .stopAllVideos, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleStopAllVideos()
        }

        // Listen for player loan: detail view borrowed our AVPlayer — nil our reference
        // so MuteState forwarding and other handlers become no-ops on the shared instance.
        // IMPORTANT: Do NOT call videoPlayerView.setPlayer(nil) here — keep the player
        // attached to the feed cell's AVPlayerLayer so it continues displaying during the
        // push animation. The detail view's AVPlayerViewController naturally takes over.
        // On return, the feed cell's layer resumes rendering automatically.
        playerLoanedObserver = NotificationCenter.default.addObserver(
            forName: .videoPlayerLoaned, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let loanedMid = notification.userInfo?["videoMid"] as? String,
                  loanedMid == self.attachment?.mid else { return }
            // Remove time observer while self.player still references the correct AVPlayer,
            // otherwise the token survives and a different player instance would crash
            // trying to remove it ("cannot remove a time observer added by a different instance")
            self.removePlayerTimeObserver()
            self.playerWasLoaned = true
            self.player = nil
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
                  let claimedMid = notification.userInfo?["videoMid"] as? String,
                  let claimerHash = notification.userInfo?["claimerIdentity"] as? Int,
                  claimedMid == self.attachment?.mid,
                  claimerHash != myIdentity,
                  self.player != nil else { return }
            // Another cell took the player — release KVO observers and nil our reference.
            // Time observer must go first (removePlayerTimeObserver uses timeObserverPlayer,
            // not self.player, so it's safe to call before nilling).
            self.removePlayerTimeObserver()
            self.removePlayerObservers()
            self.player = nil
            if self.videoCellState == .playing || self.videoCellState == .playerReady {
                self.transitionTo(self.imageView.image != nil ? .thumbnail : .noContent)
            }
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
        imageView.image = image
        switch videoCellState {
        case .noContent:
            transitionTo(.thumbnail)
        case .thumbnail, .playerLoading, .playerReady, .paused:
            // Re-evaluate visibility now that the poster exists. For non-primary
            // preload cells this hides the black layer and stops the spinner.
            transitionTo(videoCellState)
        default:
            break
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
                  self.player == nil,
                  self.setupPlayerTask == nil,
                  self.attachment?.mid == mediaID,
                  notification.userInfo?["mediaID"] as? String == mediaID,
                  let att = self.attachment,
                  let url = att.getUrl(self.effectiveBaseUrl),
                  let parentTweet = self.parentTweet else {
                return
            }
            self.playerAcquireDebounceTask?.cancel()
            self.playerAcquireDebounceTask = nil
            self.acquirePlayer(attachment: att, url: url, parentTweet: parentTweet)
        }
    }

    // MARK: - Player Acquisition

    private func schedulePlayerAcquireIfNeeded() {
        guard isVisible,
              isVideoAttachment,
              player == nil,
              setupPlayerTask == nil,
              playerAcquireDebounceTask == nil else { return }

        if let att = attachment,
           SharedAssetCache.shared.getCachedPlayer(for: att.mid) != nil,
           let url = att.getUrl(effectiveBaseUrl),
           let parentTweet = parentTweet {
            acquirePlayer(attachment: att, url: url, parentTweet: parentTweet)
            return
        }

        playerAcquireDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            guard !Task.isCancelled,
                  let self else { return }
            defer { self.playerAcquireDebounceTask = nil }

            guard self.isVisible,
                  let att = self.attachment,
                  att.type == .video || att.type == .hls_video,
                  let url = att.getUrl(self.effectiveBaseUrl),
                  let parentTweet = self.parentTweet else { return }

            // Skip if a player is already configured (coordinator may have acquired one
            // during the 0.3s window). Without this guard, the debounce reconfigures
            // an already-playing player — causing a playing→playerLoading state reset.
            guard self.player == nil, self.setupPlayerTask == nil else { return }
            self.acquirePlayer(attachment: att, url: url, parentTweet: parentTweet)
        }
    }

    private func acquirePlayer(attachment: MimeiFileType, url: URL, parentTweet: Tweet) {
        guard isVisible else { return }

        let mid = attachment.mid

        // TIER 1: Synchronous cache hit (VideoStateCache)
        if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
            let cachedPlayer = cachedState.player
            cachedPlayer.isMuted = MuteState.shared.isMuted

            // Validate cached player
            guard cachedPlayer.currentItem != nil else {
                print("\(logPrefix) ⚠️ Cached player invalid - falling back to async")
                SharedAssetCache.shared.removeInvalidPlayer(for: mid, force: true)
                VideoStateCache.shared.clearCachedState(for: mid)
                acquirePlayerAsync(attachment: attachment, url: url, parentTweet: parentTweet)
                return
            }

            let isAtEnd = isVideoAtEnd(cachedPlayer)

            // Reset finished videos to beginning
            if isAtEnd {
                VideoStateCache.shared.clearCachedState(for: mid)
                cachedPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
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
            if isVideoAtEnd(cachedPlayer) {
                cachedPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            }
            if cachedPlayer.rate > 0 { cachedPlayer.pause() }
            configurePlayer(cachedPlayer)
            return
        }

        // TIER 3: Async loading
        acquirePlayerAsync(attachment: attachment, url: url, parentTweet: parentTweet)
    }

    private func acquirePlayerAsync(attachment: MimeiFileType, url: URL, parentTweet: Tweet) {
        guard shouldLoadVideo else { return }

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
                    for: uniqueURL, tweetId: tweetId, mediaType: mediaType
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
        handleAlreadyReadyPlayer(newPlayer)
        deferVideoOutputAttachment(newPlayer)
    }

    /// Pause, mute, assign player, transition to .playerLoading.
    private func preparePlayerForConfiguration(_ newPlayer: AVPlayer) {
        if newPlayer.rate > 0 { newPlayer.pause() }
        newPlayer.isMuted = MuteState.shared.isMuted
        if isVisible {
            newPlayer.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        }
        hasRenderedFrameForCurrentPlayer = false
        removePlayerObservers()
        self.player = newPlayer
        // Notify other feed cells that may hold the same player (tweet + retweet case)
        // to release their KVO observers. Must post after self.player = newPlayer so that
        // when the notification fires synchronously, this cell is already the owner.
        if let mid = attachment?.mid {
            NotificationCenter.default.post(
                name: .videoPlayerClaimedByCell,
                object: nil,
                userInfo: ["videoMid": mid, "claimerIdentity": ObjectIdentifier(self).hashValue]
            )
        }
        // Pick up preload-generated thumbnail if the cell missed it during setupVideoCell
        if imageView.image == nil, let mid = attachment?.mid,
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
            // Defer capture by one run-loop cycle: isReadyForDisplay fires before
            // the GPU composites the frame into the layer's backing store.
            if self.imageView.image == nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.imageView.image == nil else { return }
                    self.preserveFrameToCache()
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
                self.updateLoadingSpinnerForPlayback(player)
                if self.isVisibleVideoFrameReady(player),
                   self.videoCellState == .playing || self.videoCellState == .playerReady {
                    self.imageView.isHidden = true
                }
            }

            // If coordinator already told us to play, attempt now — covers the case
            // where KVO fired before onReadyForDisplay (or didn't fire for preloaded players).
            if self.coordinatorWantsToPlay, let player = self.player {
                print("\(self.logPrefix) 🖼️ onReadyForDisplay: coordinatorWants=true, calling requestPlayback")
                self.requestPlaybackStartIfNeeded(player, reason: "onReadyForDisplay-coordinatorWaiting")
            } else {
                // Notify coordinator — video is ready. If idle, start; if primary is
                // stuck (not actually playing), reset and pick a new primary.
                print("\(self.logPrefix) 🖼️ onReadyForDisplay: coordinatorWants=false, checking stall")
                (self.videoCoordinator ?? .shared).requestStartPlaybackIfStalled()
            }
        }
    }

    /// Attach player to the AVPlayerLayer, suppressing implicit CALayer animations.
    private func attachPlayerToLayer(_ newPlayer: AVPlayer) {
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
            let seekTarget: CMTime
            if let info = VideoStateCache.shared.getCachedPlaybackInfo(for: mid),
               info.time.seconds.isFinite, info.time.seconds > 0.25 {
                seekTarget = info.time
            } else {
                seekTarget = CMTime(seconds: 0.01, preferredTimescale: 600)
            }
            newPlayer.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Defer video output attachment to next run-loop cycle.
    private func deferVideoOutputAttachment(_ newPlayer: AVPlayer) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === newPlayer else { return }
            self.ensureVideoOutputAttached(for: newPlayer)
        }
    }

    /// Canonical readiness check from AVPlayerItem status.
    private func isActuallyPlayerReady(_ player: AVPlayer?) -> Bool {
        guard let status = player?.currentItem?.status else { return false }
        return status == .readyToPlay
    }

    /// A video is visually ready only once playback has started and the layer can display frames.
    private func isVisibleVideoFrameReady(_ player: AVPlayer) -> Bool {
        player.timeControlStatus == .playing && videoPlayerView.isLayerReadyForDisplay
    }

    /// Keep the spinner up until the user can actually see moving video content.
    private func updateLoadingSpinnerForPlayback(_ player: AVPlayer) {
        let shouldShowSpinner = coordinatorWantsToPlay
            && !isVideoAtEnd(player)
            && !isVisibleVideoFrameReady(player)
        if shouldShowSpinner {
            if delayedPrimarySpinnerTask != nil {
                return
            }
            loadingSpinner.startAnimating()
        } else {
            cancelDelayedPrimarySpinner()
            loadingSpinner.stopAnimating()
        }
    }

    private func shouldDelayPrimarySpinner(for player: AVPlayer?) -> Bool {
        guard coordinatorWantsToPlay,
              let player,
              isActuallyPlayerReady(player),
              !isVideoAtEnd(player) else { return false }
        return hasVideoCoverForSpinner || videoPlayerView.isLayerReadyForDisplay
    }

    private func showPrimarySpinnerWithOptionalDelay(for player: AVPlayer) {
        cancelDelayedPrimarySpinner()

        guard shouldDelayPrimarySpinner(for: player) else {
            loadingSpinner.startAnimating()
            return
        }

        loadingSpinner.stopAnimating()
        delayedPrimarySpinnerTask = Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self,
                  let player,
                  self.player === player,
                  self.coordinatorWantsToPlay,
                  self.videoCellState == .playing,
                  !self.isVideoAtEnd(player),
                  !self.isVisibleVideoFrameReady(player) else {
                self?.delayedPrimarySpinnerTask = nil
                return
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

    /// AVPlayer can report rate > 0 while still waiting on a tiny startup
    /// buffer. Keep loading, keep the spinner visible, and briefly let it start
    /// without AVPlayer's stall-minimizing wait so the first frames can render.
    private func nudgePlaybackIfWaiting(_ player: AVPlayer, reason: String) {
        guard coordinatorWantsToPlay,
              player.currentItem?.status == .readyToPlay,
              player.timeControlStatus != .playing,
              !isVideoAtEnd(player) else { return }

        let bufferedAhead = bufferedTimeAhead(for: player)
        let keepUp = player.currentItem?.isPlaybackLikelyToKeepUp ?? false
        let shouldBypassStartupWait = bufferedAhead > 0
            && ((bufferedAhead < 1.5 && !keepUp) || (bufferedAhead >= 2.0 && keepUp))
        let now = Date()
        let nudgeCooldown: TimeInterval = shouldBypassStartupWait ? 0.8 : 2.0

        if now.timeIntervalSince(lastPlaybackNudgeDate) < nudgeCooldown {
            scheduleStartupRecovery(for: player, reason: reason)
            return
        }

        if shouldBypassStartupWait {
            player.automaticallyWaitsToMinimizeStalling = false
        }
        player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        if lastPlaybackRequestDate == .distantPast {
            lastPlaybackRequestDate = Date()
        }
        player.play()
        updateLoadingSpinnerForPlayback(player)

        lastPlaybackNudgeDate = now
        print("\(logPrefix) 🔄 playback nudge (\(reason)): timeControl=\(player.timeControlStatus.rawValue), buffered=\(String(format: "%.1f", bufferedAhead))s, keepUp=\(keepUp), bypassWait=\(shouldBypassStartupWait)")

        scheduleStartupRecovery(for: player, reason: reason)
    }

    private func scheduleStartupRecovery(for player: AVPlayer, reason: String) {
        let requestDate = lastPlaybackRequestDate
        let requestPosition = player.currentTime()
        let hasActuallyPlayed = lastActualPlaybackDate != .distantPast
        let requestSeconds = seconds(from: requestPosition)
        let isStartupRecovery = !hasActuallyPlayed && requestSeconds < 8.0
        let recoveryDelay: UInt64 = isStartupRecovery ? 4_000_000_000 : 12_000_000_000
        if playbackStartupRecoveryTask != nil,
           playbackStartupRecoveryRequestDate == requestDate {
            return
        }

        playbackStartupRecoveryTask?.cancel()
        playbackStartupRecoveryRequestDate = requestDate

        playbackStartupRecoveryTask = Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(nanoseconds: recoveryDelay)
            guard let self else { return }
            defer {
                if self.playbackStartupRecoveryRequestDate == requestDate {
                    self.playbackStartupRecoveryTask = nil
                    self.playbackStartupRecoveryRequestDate = nil
                }
            }
            guard !Task.isCancelled,
                  let player,
                  self.player === player,
                  self.coordinatorWantsToPlay,
                  self.videoCellState == .playing,
                  self.lastPlaybackRequestDate == requestDate,
                  player.timeControlStatus != .playing,
                  !self.isVideoAtEnd(player),
                  let mid = self.attachment?.mid else { return }

            let fullscreenOwnsMid = OverlayVisibilityCoordinator.shared.isCovered
                && FullScreenVideoManager.shared.currentVideoMid == mid
            guard !fullscreenOwnsMid else { return }

            let bufferedAhead = self.bufferedTimeAhead(for: player)
            let keepUp = player.currentItem?.isPlaybackLikelyToKeepUp ?? false
            if bufferedAhead >= 1.0 && keepUp {
                if player.automaticallyWaitsToMinimizeStalling {
                    player.automaticallyWaitsToMinimizeStalling = false
                }
                player.play()
                self.updateLoadingSpinnerForPlayback(player)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled,
                      self.player === player,
                      self.coordinatorWantsToPlay,
                      player.timeControlStatus != .playing,
                      !self.isVideoAtEnd(player) else { return }
            }

            let recoveryTime = player.currentTime()
            let recoverySeconds = self.seconds(from: recoveryTime)
            let canRestorePosition = recoverySeconds.isFinite
                && recoverySeconds > 0.5
                && !self.isVideoAtEnd(player, tolerance: 2.0)
            self.pendingRecoverySeekTime = canRestorePosition ? recoveryTime : nil
            if canRestorePosition {
                self.preserveFrameToCache()
            }

            let label = isStartupRecovery ? "startup recovery" : "playback recovery"
            print("\(self.logPrefix) 🔄 \(label) (\(reason)): rebuilding stuck player, pos=\(String(format: "%.1f", recoverySeconds))s, buffered=\(String(format: "%.1f", bufferedAhead))s, keepUp=\(keepUp)")
            SharedAssetCache.shared.clearPlayerForMediaID(mid, deleteDiskCache: false)
            self.cleanupVideoPlayer(reason: "startupRecovery.stuckWaiting")
            self.coordinatorWantsToPlay = true
            if let att = self.attachment,
               let url = att.getUrl(self.effectiveBaseUrl),
               let parentTweet = self.parentTweet {
                self.transitionTo(self.imageView.image != nil ? .thumbnail : .playerLoading)
                self.acquirePlayer(attachment: att, url: url, parentTweet: parentTweet)
            }
        }
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

    private func handleCoordinatorPlayCommand() {
        guard let mid = attachment?.mid else { return }

        let hasPlayer = player != nil
        let itemStatus = player?.currentItem?.status.rawValue ?? -1
        let rate = player?.rate ?? -1
        print("\(logPrefix) 🎬 shouldPlayVideo: state=\(videoCellState), hasPlayer=\(hasPlayer), itemStatus=\(itemStatus), rate=\(rate)")

        isHandlingFinishEvent = false
        VideoStateCache.shared.clearStoppedByCoordinator(mid)
        coordinatorWantsToPlay = true

        // Don't auto-replay a video that already played to completion this session.
        // The user can still tap to watch it fullscreen; this only suppresses coordinator autoplay.
        if let id = videoIdentifier, VideoStateCache.shared.isVideoFinished(id) {
            coordinatorWantsToPlay = false
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
            nudgePlaybackIfWaiting(player, reason: "coordinatorPlay-alreadyPlayingState")
            return
        }

        // If video is in failed state, always clean up and retry regardless of player health.
        // Buffering timeout transitions to .failed but preserves the player — simply calling
        // play() on the same player won't fix the underlying network issue.
        if videoCellState == .failed {
            print("\(logPrefix) 🔄 Coordinator play on failed video - cleaning up and retrying")
            cleanupVideoPlayer(reason: "coordinatorPlay.failedStateRetry")
            retryButton.isHidden = true
            if let att = attachment, let url = att.getUrl(effectiveBaseUrl),
               let parentTweet = parentTweet {
                transitionTo(imageView.image != nil ? .thumbnail : .noContent)
                // Restore: cleanupVideoPlayer resets coordinatorWantsToPlay via resetVideoState().
                // Without this, onReadyForDisplay takes the stall-check path instead of auto-playing.
                coordinatorWantsToPlay = true
                acquirePlayer(attachment: att, url: url, parentTweet: parentTweet)
            }
            return
        }

        // Fast path: reclaim loaned player returning from detail view.
        // Bypasses configurePlayer() which would transition to .playerLoading and defer
        // playback via onReadyForDisplay — but the layer already has the player attached
        // (never detached during loan), so onReadyForDisplay would never fire.
        if playerWasLoaned, self.player == nil {
            playerWasLoaned = false
            if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
                let player = cachedState.player
                player.isMuted = MuteState.shared.isMuted
                self.player = player

                // Disown from DetailVideoManager BEFORE playing — prevents the pending
                // deactivate()/endDetailViewSession() from pausing our reclaimed player.
                DetailVideoManager.shared.disownLoanedPlayer()

                // Update VideoStateCache with current position (detail view's exit position)
                let currentTime = player.currentTime()
                VideoStateCache.shared.cacheVideoState(
                    for: mid, player: player,
                    time: currentTime,
                    wasPlaying: false,
                    originalMuteState: MuteState.shared.isMuted
                )

                print("\(logPrefix) ♻️ Reclaimed loaned player at \(currentTime.seconds)s")
                actuallyStartPlayback(player)
                return
            }
            // Cache miss — fall through to normal flow
        }

        // If player not ready, let KVO trigger play when ready
        guard let player = player, isActuallyPlayerReady(player) else {

            // Show loading state whenever primary and not yet playing.
            // IMPORTANT: do not downgrade .playerReady back to .playerLoading;
            // that causes unnecessary spinner loops on partially loaded videos.
            if videoCellState == .noContent || videoCellState == .thumbnail || videoCellState == .playerLoading {
                transitionTo(.playerLoading)
            }

            // Trigger player setup if needed.
            // Guard against re-triggering when setupPlayerTask is already in flight —
            // doing so would cancel the in-flight creation and start a duplicate one,
            // causing multiple AVPlayers for the same mediaID during fast scroll.
            if self.player == nil, setupPlayerTask == nil, shouldLoadVideo, isVisible,
               let att = attachment, let url = att.getUrl(effectiveBaseUrl),
               let parentTweet = parentTweet {
                acquirePlayer(attachment: att, url: url, parentTweet: parentTweet)
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
            cleanupVideoPlayer(reason: "coordinatorPlay.invalidPlayerHealth")
            if let att = attachment, let url = att.getUrl(effectiveBaseUrl), let parentTweet = parentTweet {
                setupVideoCell(attachment: att, url: url, parentTweet: parentTweet)
            }
            // Restore after setupVideoCell — both cleanupVideoPlayer() calls reset it,
            // but we need it so the new player auto-plays once ready
            coordinatorWantsToPlay = true
            return
        }

        // If near the end (within 5s), restart from the beginning rather than resuming
        // at an awkward near-end position. Videos that finished naturally are already
        // gated above by the finishedVideoIdentifiers check.
        if isVideoAtEnd(player, tolerance: 5.0) {
            VideoStateCache.shared.clearCachedState(for: mid)
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

        if let recoveryTime = pendingRecoverySeekTime,
           recoveryTime.seconds.isFinite,
           recoveryTime.seconds > 0.25 {
            pendingRecoverySeekTime = nil
            player.seek(to: recoveryTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard self.attachment?.mid == mid else { return }
                    print("\(self.logPrefix) 🔄 recovery seek restored \(String(format: "%.1f", recoveryTime.seconds))s")
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
        if let info = VideoStateCache.shared.getCachedPlaybackInfo(for: mid) {
            let targetSeconds = info.time.seconds
            if targetSeconds.isFinite, targetSeconds > 0.25 {
                player.seek(to: info.time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                    guard let self, let _ = self.attachment?.mid else { return }
                    self.startPlaybackWithFade(player)
                }
                return
            }
        }

        startPlaybackWithFade(player)
    }

    /// Start playback if coordinator wants to play and player isn't already playing.
    private func requestPlaybackStartIfNeeded(_ player: AVPlayer, reason: String) {
        guard coordinatorWantsToPlay else {
            print("\(logPrefix) ⏸️ requestPlayback(\(reason)): skipped, coordinatorWantsToPlay=false")
            return
        }
        guard isVisible else {
            print("\(logPrefix) 👻 requestPlayback(\(reason)): skipped, cell not visible")
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
            print("\(logPrefix) ⏸️ requestPlayback(\(reason)): item not ready (status=\(itemStatus?.rawValue ?? -1)), deferring to statusKVO")
            // If item is in a terminal failure state or has no currentItem, statusKVO will
            // never fire .readyToPlay. Clean up and re-acquire instead of spinning forever.
            if itemStatus == .failed || player.currentItem == nil {
                print("\(logPrefix) 🔄 Item terminal — cleaning up for re-acquisition")
                if (attachment?.mid) != nil {
                    cleanupVideoPlayer(reason: "requestPlayback.terminalItem")
                    coordinatorWantsToPlay = true
                    if let att = attachment, let url = att.getUrl(effectiveBaseUrl), let parentTweet = parentTweet {
                        acquirePlayer(attachment: att, url: url, parentTweet: parentTweet)
                    }
                }
                return
            }
            // Show spinner so the user sees loading feedback while waiting for statusKVO.
            loadingSpinner.startAnimating()

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
                          player.currentItem?.status == .unknown else { return }
                    print("\(self.logPrefix) ⏰ statusKVO fallback: item still .unknown after 2s, enabling network + play")
                    player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
                    self.actuallyStartPlayback(player)
                }
            }
            return
        }

        print("\(logPrefix) ▶️ requestPlayback(\(reason)): rate=\(player.rate), timeControl=\(player.timeControlStatus.rawValue), state=\(videoCellState)")

        if player.rate > 0 {
            // Already told to play — sync UI state.
            videoPlayerView.isHidden = false
            if videoCellState != .playing {
                print("\(logPrefix) State: \(videoCellState) → playing")
                videoCellState = .playing
            }
            // Only stop spinner if actually rendering frames. rate > 0 just means
            // play() was called; the player may still be buffering (timeControlStatus
            // == .waitingToPlayAtSpecifiedRate) with no frames to show.
            updateLoadingSpinnerForPlayback(player)
            retryButton.isHidden = true
            player.automaticallyWaitsToMinimizeStalling = true
            player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            player.isMuted = MuteState.shared.isMuted
            player.volume = 1.0
            if isSingleMedia, let mid = attachment?.mid {
                setupVideoTimer(videoMid: mid)
                startPlayerTimeObserver()
            }
            if player.timeControlStatus != .playing {
                nudgePlaybackIfWaiting(player, reason: "\(reason)-rateAlreadyPositive")
            }
            return
        }

        playWithVolumeFadeIn(player)
    }

    private func startPlaybackWithFade(_ player: AVPlayer) {
        // No deferral needed: actuallyStartPlayback() keeps the thumbnail visible
        // and timeControlStatus KVO hides it when smooth playback starts.
        actuallyStartPlayback(player)
    }

    private func actuallyStartPlayback(_ player: AVPlayer) {
        guard let mid = attachment?.mid else { return }

        // Show player layer (may have been hidden for non-primary .playerReady)
        videoPlayerView.isHidden = false

        // Update state directly — skip transitionTo() to avoid touching imageView.
        // The layer already has content from preload; just let the player play.
        // imageView stays as-is: visible (thumbnail cover) or hidden (layer showing).
        // timeControlStatus KVO will hide the thumbnail when smooth playback starts.
        if videoCellState != .playing {
            print("\(logPrefix) State: \(videoCellState) → playing")
        }
        videoCellState = .playing
        retryButton.isHidden = true

        // Show loading feedback only if playback does not start quickly. Cached
        // videos already have a poster/frame, so a 0.5s grace period avoids a
        // distracting spinner flash on instant starts.
        showPrimarySpinnerWithOptionalDelay(for: player)

        // Primary playback must own network recovery. Preloaded players may be
        // paused with background-friendly settings, so restore AVPlayer's normal
        // stall handling before issuing play().
        player.automaticallyWaitsToMinimizeStalling = true
        player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        player.isMuted = MuteState.shared.isMuted
        lastPlaybackRequestDate = Date()
        player.play()
        scheduleStartupRecovery(for: player, reason: "actuallyStartPlayback")

        // Show timer when playback starts
        if isSingleMedia {
            setupVideoTimer(videoMid: mid)
            startPlayerTimeObserver()
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
    private func preserveFrameToCache(useVideoOutput: Bool = true, async: Bool = false, skipImageView: Bool = false) -> Bool {
        guard let mid = attachment?.mid else { return false }

        // Priority 1: imageView already has a frame — save to cache and we're done.
        // Skipped during active playback captures (skipImageView=true) because imageView
        // may hold a stale first-frame thumbnail, not the current video frame.
        if !skipImageView, let existingImage = imageView.image {
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
                        if VideoFrameExtractor.isMostlyBlack(image) { return }
                        await MainActor.run {
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
                           !VideoFrameExtractor.isMostlyBlack(image) {
                            imageView.image = image
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
            if !VideoFrameExtractor.isMostlyBlack(snapshot) {
                imageView.image = snapshot
                SharedAssetCache.shared.updateCachedThumbnail(snapshot, for: mid)
                return true
            }
        }

        // Priority 4: Restore cached-media thumbnail poster if available.
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

        preserveFrameToCache(async: async, skipImageView: true)
    }

    // MARK: - Player Observers

    private func setupPlayerObservers(_ player: AVPlayer) {
        guard let playerItem = player.currentItem else { return }
        removePlayerObservers()

        // Video finished
        videoCompletionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleVideoFinished()
            }
        }

        // KVO: player item status — tracks logical readiness (for coordinator play commands)
        // NOTE: .initial removed — it fires the callback synchronously during observe() setup,
        // causing a main-thread hitch. Initial state is checked manually in configurePlayer().
        playerItemStatusObserver = playerItem.observe(\.status, options: [.old, .new]) { [weak self] item, change in
            DispatchQueue.main.async {
                guard let self else { return }
                guard (self.attachment?.mid) != nil else { return }

                if item.status == .readyToPlay {
                    // Cancel the fallback task — statusKVO arrived before the timeout.
                    self.statusUnknownFallbackTask?.cancel()
                    self.statusUnknownFallbackTask = nil

                    let firstReadyTransition = change.oldValue != .readyToPlay
                    print("\(self.logPrefix) 📺 statusKVO: readyToPlay (first=\(firstReadyTransition), coordWants=\(self.coordinatorWantsToPlay), state=\(self.videoCellState))")

                    // If playback already started before status reached readyToPlay,
                    // reveal player layer now (safe point) instead of relying on an
                    // earlier .playing callback that may have fired while still unknown.
                    // Also stop the spinner: requestPlaybackStartIfNeeded may have started
                    // it while waiting for statusKVO, but since rate > 0 the rate==0 guard
                    // at firstReadyTransition skips requestPlaybackStartIfNeeded, leaving
                    // the spinner running forever.
                    if let player = self.player,
                       player.timeControlStatus == .playing,
                       (self.videoCellState == .playing || self.videoCellState == .playerReady) {
                        self.updateLoadingSpinnerForPlayback(player)
                        if self.videoPlayerView.isLayerReadyForDisplay {
                            self.imageView.isHidden = true
                        } else {
                            self.addReadyForDisplayAction { [weak self] in
                                guard let self, let player = self.player else { return }
                                self.updateLoadingSpinnerForPlayback(player)
                                self.imageView.isHidden = true
                            }
                        }
                    }

                    if firstReadyTransition {
                        if self.coordinatorWantsToPlay, let player = self.player {
                            if self.isVideoAtEnd(player, tolerance: 5.0) {
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
                            let seekTarget = CMTime(seconds: 0.01, preferredTimescale: 600)
                            player.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: .zero)
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
                    // Release the failed player from SharedAssetCache. Guard: don't clear
                    // if fullscreen player owns this video (would kill its streaming).
                    if let mid = self.attachment?.mid {
                        let fullscreenOwnsMid = OverlayVisibilityCoordinator.shared.isCovered
                            && FullScreenVideoManager.shared.currentVideoMid == mid
                        if !fullscreenOwnsMid {
                            // Delete disk cache so corrupt/partial IPFS data isn't re-served on retry.
                            SharedAssetCache.shared.clearPlayerForMediaID(mid, deleteDiskCache: true)
                        }
                    }
                    self.handleVideoLoadFailure(reason: "playerItem.status == .failed (\(errorMsg))")
                }
            }
        }

        // KVO: timeControlStatus — show spinner while buffering, stop when actually playing
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self else { return }

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
                print(logMsg)

                if player.timeControlStatus == .playing {
                    self.lastActualPlaybackDate = Date()
                    self.playbackStartupRecoveryTask?.cancel()
                    self.playbackStartupRecoveryTask = nil
                    self.playbackStartupRecoveryRequestDate = nil
                    if !player.automaticallyWaitsToMinimizeStalling {
                        player.automaticallyWaitsToMinimizeStalling = true
                    }
                    self.updateLoadingSpinnerForPlayback(player)
                    // Smooth playback confirmed — hide thumbnail cover to reveal actual video
                    if self.isActuallyPlayerReady(player) && (self.videoCellState == .playing || self.videoCellState == .playerReady) {
                        if self.videoPlayerView.isLayerReadyForDisplay {
                            self.imageView.isHidden = true
                        } else {
                            self.addReadyForDisplayAction { [weak self] in
                                guard let self, let player = self.player else { return }
                                self.updateLoadingSpinnerForPlayback(player)
                                self.imageView.isHidden = true
                            }
                        }
                    }
                } else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                          self.videoCellState == .playing || self.videoCellState == .playerReady {
                    guard !self.isVideoAtEnd(player) else { return }
                    self.updateLoadingSpinnerForPlayback(player)
                    self.nudgePlaybackIfWaiting(player, reason: "timeControl-waiting")
                } else if player.timeControlStatus == .paused
                            && self.coordinatorWantsToPlay
                            && self.videoCellState == .playing
                            && !self.isVideoAtEnd(player) {
                    self.updateLoadingSpinnerForPlayback(player)
                    self.nudgePlaybackIfWaiting(player, reason: "timeControl-paused")
                }
            }
        }

        // KVO: isPlaybackLikelyToKeepUp — backup resume after a buffer-drain stall.
        // AVPlayer should auto-resume, but if it remains paused or waiting while the
        // coordinator still wants this primary, nudge it once data is available.
        playbackLikelyToKeepUpObserver = playerItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self,
                      item.isPlaybackLikelyToKeepUp,
                      let player = self.player,
                      self.coordinatorWantsToPlay,
                      self.videoCellState == .playing,
                      player.timeControlStatus != .playing,
                      !self.isVideoAtEnd(player) else { return }
                print("\(self.logPrefix) 🔄 buffer recovered — resuming at \(String(format: "%.1f", player.currentTime().seconds))s")
                player.automaticallyWaitsToMinimizeStalling = true
                player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
                player.play()
                self.lastPlaybackRequestDate = Date()
                self.updateLoadingSpinnerForPlayback(player)
            }
        }
    }

    private func removePlayerObservers() {
        if let o = videoCompletionObserver { NotificationCenter.default.removeObserver(o) }
        videoCompletionObserver = nil
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = nil
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        playbackLikelyToKeepUpObserver?.invalidate()
        playbackLikelyToKeepUpObserver = nil
    }


    // MARK: - Video Finished

    private func handleVideoFinished() async {
        guard !isHandlingFinishEvent else { return }
        isHandlingFinishEvent = true
        // Note: flag stays true until cell is reused (cleanupVideoPlayer)
        // or coordinator sends a new play command (handleCoordinatorPlayCommand)

        guard let player = player, let item = player.currentItem,
              let mid = attachment?.mid else { return }

        let duration = item.duration
        guard duration.isValid, duration.seconds > 0 else { return }

        let currentTime = player.currentTime().seconds
        let timeUntilEnd = duration.seconds - currentTime

        guard timeUntilEnd < 0.5 else {
            return
        }

        // Pause immediately
        player.pause()
        player.isMuted = MuteState.shared.isMuted
        VideoStateCache.shared.clearCachedState(for: mid)
        // Sync capture with skipImageView: imageView may hold a stale first-frame thumbnail,
        // so we go directly to video output to capture the actual last rendered frame.
        preserveFrameToCache(skipImageView: true)

        // Notify coordinator to advance to next video (include full identifier: tweet id + video id + index)
        var userInfo: [String: Any] = ["videoMid": mid, "tweetId": parentTweet?.mid ?? ""]
        if let id = videoIdentifier { userInfo["videoIdentifier"] = id }
        NotificationCenter.default.post(
            name: .videoDidFinishPlaying,
            object: nil,
            userInfo: userInfo
        )

        VideoStateCache.shared.clearCache(for: mid, force: true)

        // Prevent coordinator from auto-replaying this video when it scrolls back into view.
        if let id = videoIdentifier {
            VideoStateCache.shared.markVideoFinished(identifier: id)
        }
    }

    // MARK: - Utilities

    private func saveCurrentPosition(player: AVPlayer, wasPlaying: Bool) {
        guard let mid = attachment?.mid else { return }
        guard player.currentItem != nil else { return }
        let currentTime = player.currentTime()
        guard currentTime.seconds.isFinite, currentTime.seconds > 0.25 else { return }
        // Don't save position when near the end — resuming from there is jarring;
        // the video will restart from the beginning on next play instead.
        guard !isVideoAtEnd(player, tolerance: 5.0) else { return }

        VideoStateCache.shared.cacheVideoState(
            for: mid,
            player: player,
            time: currentTime,
            wasPlaying: wasPlaying,
            originalMuteState: player.isMuted
        )
    }

    private func isVideoAtEnd(_ player: AVPlayer, tolerance: Double = 0.5) -> Bool {
        guard let item = player.currentItem else { return false }
        let duration = item.duration
        guard duration.isValid, !duration.isIndefinite else { return false }
        let diff = CMTimeSubtract(duration, player.currentTime())
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
        timerLabel.isHidden = false
        timerLabel.text = "0:00"
    }

    /// Attach a periodic time observer to the player to drive the timer label.
    /// Called from configurePlayer() once we have a valid AVPlayer.
    private func startPlayerTimeObserver() {
        guard isSingleMedia else { return }
        removePlayerTimeObserver()

        guard let player = player else { return }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverPlayer = player
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.updateTimerLabel(currentTime: time)
        }
    }

    private func removePlayerTimeObserver() {
        if let token = timeObserverToken, let player = timeObserverPlayer {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        timeObserverPlayer = nil
    }

    private func updateTimerLabel(currentTime: CMTime) {
        guard let item = player?.currentItem else { return }
        let duration = item.duration
        let durationSeconds = seconds(from: duration)
        guard duration.isValid, !duration.isIndefinite, durationSeconds > 0 else { return }

        let remaining = max(0, durationSeconds - seconds(from: currentTime))
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        timerLabel.text = "\(minutes):\(String(format: "%02d", seconds))"
        setNeedsLayout()
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

    private func retryVideoLoad() {
        guard isVideoAttachment,
              let att = attachment,
              let url = att.getUrl(effectiveBaseUrl),
              let parentTweet = parentTweet else { return }

        print("\(logPrefix) 🔄 Manual video retry")
        retryButton.isHidden = true
        coordinatorWantsToPlay = false
        if let player = player, isActuallyPlayerReady(player) {
            // Reload button restores the preview only. If this cell later becomes
            // primary, handleCoordinatorPlayCommand(.failed/playerReady) will
            // promote/reload it with playback priority.
            transitionTo(.playerReady)
            player.pause()
        } else {
            // Player was cleared (initial load failure / item.status == .failed).
            // acquirePlayer creates a fresh player that reuses preserved disk cache.
            transitionTo(imageView.image != nil ? .thumbnail : .noContent)
            acquirePlayer(attachment: att, url: url, parentTweet: parentTweet)
        }
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
        loadingSpinner.stopAnimating()
        player = nil
        setupPlayerTask = nil
    }

    /// Transition to an idle visual state (thumbnail or noContent) after failure.
    private func transitionToIdleAfterFailure() {
        // On timeout/retry paths imageView may be nil even though we have a cached
        // thumbnail poster. Restore it first to avoid black flash/noContent state.
        if imageView.image == nil,
           let mid = attachment?.mid,
           let cached = SharedAssetCache.shared.cachedThumbnail(for: mid) {
            imageView.image = cached
        }

        if imageView.image != nil {
            transitionTo(.thumbnail)
        } else {
            transitionTo(.noContent)
            loadingSpinner.stopAnimating()
        }
    }

    /// Central handler for all video loading failures. Preserves frame, cleans up player,
    /// shows retry button if visible and coordinator wants play, otherwise goes idle.
    private func handleVideoLoadFailure(reason: String) {
        guard isVideoAttachment else { return }

        // Capture frame BEFORE cleanup — for partially-played videos,
        // this preserves the last rendered frame as thumbnail behind the retry button.
        preserveFrameToCache()
        cleanupFailedPlayerState()

        // Visible media failures should be actionable even when the cell is not
        // the autoplay primary; otherwise a timed-out preview can collapse into
        // a black square with no recovery affordance.
        let shouldShowRetry = isVisible && (coordinatorWantsToPlay || shouldLoadVideo)
        let wasPrimary = coordinatorWantsToPlay

        guard shouldShowRetry else {
            print("\(logPrefix) ❌ \(reason) - going idle")
            transitionToIdleAfterFailure()
            return
        }

        // Visible failure → show retry button over current frame/black backdrop.
        print("\(logPrefix) ❌ \(reason) - showing retry button")
        coordinatorWantsToPlay = false
        transitionTo(.failed)
        if wasPrimary, let id = videoIdentifier {
            (videoCoordinator ?? .shared).notifyPrimaryVideoFailed(identifier: id)
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
        parentVC.present(hostingVC, animated: true)
    }

    @objc private func videoTapped() {
        handleVideoTap()
    }

    private func handleVideoTap() {
        guard let parentTweet, let parentVC = parentViewController else { return }

        // Save video position before fullscreen
        saveVideoPositionForFullscreen()

        // Build video list from the feed's coordinator and pass to fullscreen manager
        let coordinator = videoCoordinator ?? VideoPlaybackCoordinator.shared
        let fullscreenList = coordinator.getVideoListForFullscreen()
        let myMid = attachment?.mid
        let myCellTweetId = cellTweetId
        let startIndex = fullscreenList.firstIndex(where: {
            $0.videoMid == myMid && $0.cellTweetId == myCellTweetId
        }) ?? fullscreenList.firstIndex(where: {
            $0.videoMid == myMid
        }) ?? 0
        FullScreenVideoManager.shared.setVideoList(fullscreenList, startIndex: startIndex)

        // Show loading overlay
        fullscreenOverlay.isHidden = false
        fullscreenSpinner.startAnimating()

        // Post stop all to pause feed videos
        NotificationCenter.default.post(name: .stopAllVideos, object: nil)

        // CRITICAL: Mark overlay BEFORE presenting the modal. The .fullScreen presentation
        // triggers didMoveToWindow(nil) → setVisible(false) on feed cells, which checks
        // isCovered to skip aggressive cleanup (delegate unregister, network cancel).
        // If beginOverlay waits until onAppear, there's a race where setVisible(false)
        // fires first with isCovered=false → delegate unregistered → coordinator can't
        // find the video after dismiss → spinner stuck permanently.
        OverlayVisibilityCoordinator.shared.beginOverlay(id: "mediaBrowserView", source: "MediaCellUIView.handleVideoTap")

        // Delay to allow spinner to render
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            let browserView = MediaBrowserView(
                tweet: parentTweet,
                initialIndex: self?.attachmentIndex ?? 0,
                cellTweetId: self?.cellTweetId ?? parentTweet.mid
            )
            let hostingVC = UIHostingController(rootView: browserView)
            hostingVC.modalPresentationStyle = .fullScreen
            hostingVC.modalTransitionStyle = .crossDissolve

            parentVC.present(hostingVC, animated: true) {
                self?.fullscreenOverlay.isHidden = true
                self?.fullscreenSpinner.stopAnimating()
            }

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
        let previousShouldAcquirePlayer = shouldAcquirePlayerWhenVisible
        shouldAcquirePlayerWhenVisible = shouldAcquirePlayer
        let shouldStartAcquiring = visible &&
            wasVisible &&
            !previousShouldAcquirePlayer &&
            shouldAcquirePlayer

        if visible, wasVisible, isVideoAttachment {
            shouldLoadVideo = shouldAcquirePlayer
        }

        guard isVisible != visible || shouldStartAcquiring else { return }
        isVisible = visible

        guard let attachment else { return }


        if visible {
            // Update base URL
            updateEffectiveBaseUrl()

            // Boost priority for pending image loads or load if needed
            if attachment.type == .image {
                if imageView.image == nil {
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
                shouldLoadVideo = shouldAcquirePlayer
                if attachment.getUrl(effectiveBaseUrl) != nil {
                    SharedAssetCache.shared.markAsVisible(attachment.mid)
                    VideoStateCache.shared.markAsVisible(attachment.mid)
                }
            }

            // Register delegate for video coordination (keyed by identifier so
            // the same video in a tweet + retweet gets separate delegates)
            if let id = videoIdentifier {
                (videoCoordinator ?? .shared).registerDelegate(self, forIdentifier: id)
            }

            // If video was in failed state, trigger a fresh retry on becoming visible again.
            // Don't call clearPlayerForMediaID — disk cache is preserved for faster recovery.
            if isVideoAttachment && videoCellState == .failed {
                print("\(logPrefix) 🔄 Became visible with failed video - retrying")
                retryButton.isHidden = true
                if let url = attachment.getUrl(effectiveBaseUrl), let parentTweet = parentTweet {
                    transitionTo(imageView.image != nil ? .thumbnail : .noContent)
                    acquirePlayer(attachment: attachment, url: url, parentTweet: parentTweet)
                }
            }

            if isVideoAttachment && shouldAcquirePlayer {
                schedulePlayerAcquireIfNeeded()
            }

            // Setup foreground observer for images and videos
            setupForegroundObserver()
        } else {
            // When a .fullScreen modal (MediaBrowserView) is presented, iOS removes the
            // presenting VC from the window, triggering didMoveToWindow(nil) → setVisible(false).
            // But these cells are still "logically visible" — the overlay handler will resume
            // playback on dismiss. Skip aggressive cleanup (network cancel, delegate unregister)
            // to keep the cell ready for instant resume. stopAllVideos() already paused players.
            if OverlayVisibilityCoordinator.shared.isCovered {
                // Revert the isVisible flag — the cell is logically still visible
                isVisible = true
                return
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
        let isCoordinatorOwnedReadyItem = coordinatorWantsToPlay
            && videoCellState == .playing
            && item.status == .readyToPlay

        // rate > 0 + waitingToPlayAtSpecifiedRate = play() was called but buffering.
        // AVPlayer can also report a proxy/HLS buffer gap as paused while keeping a
        // healthy ready item, so keep coordinator ownership during the same grace.
        // Count this as active for a longer grace window so slow IPFS/proxy segments
        // can recover through AVPlayer's own stall handling instead of fighting the
        // coordinator restart loop while data is already arriving.
        if player.rate > 0
            || (coordinatorWantsToPlay && player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
            || isCoordinatorOwnedReadyItem {
            let bufferedAhead = bufferedTimeAhead(for: player)
            let keepUp = item.isPlaybackLikelyToKeepUp
            let requestGrace: TimeInterval = (bufferedAhead < 1.0 && !keepUp) ? 6.0 : 15.0
            let actualGrace: TimeInterval = 30.0
            return Date().timeIntervalSince(lastPlaybackRequestDate) < requestGrace
                || Date().timeIntervalSince(lastActualPlaybackDate) < actualGrace
        }
        return false
    }

    /// True when coordinator commanded play but AVPlayerItem is still loading (status=.unknown).
    /// Prevents false stall detection: IPFS/HLS can take >3s before play() is even callable.
    /// Returns false once item fails (.failed) or becomes ready (.readyToPlay), so genuine stalls
    /// (item never transitions out of .unknown) are eventually caught by the stall detector's
    /// buffering timeout in isActuallyPlaying.
    var isLoadingForCoordinator: Bool {
        guard coordinatorWantsToPlay,
              let item = player?.currentItem else { return false }
        return item.status == .unknown
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
                // During backgrounding, clearVideoPlayersForBackgroundRecovery() calls
                // replaceCurrentItem(with: nil) on all players and clears the cache.
                // Our self.player still references the now-dead player (no currentItem).
                // We must discard it and let the coordinator re-acquire a fresh player.
                if let player = self.player,
                   player.currentItem == nil || player.currentTime().seconds.isNaN {
                    self.cleanupVideoPlayer(reason: "willEnterForeground.invalidPlayer")
                    // Re-acquire a fresh player — coordinator will send play
                    // command via updateVisibleTweets if this is the primary video.
                    // Not calling handleCoordinatorPlayCommand() here prevents
                    // non-primary videos from briefly playing then getting stopped
                    // before they can render a frame (which causes black screen).
                    if let url = att.getUrl(self.effectiveBaseUrl), let parentTweet = self.parentTweet {
                        self.setupVideoCell(attachment: att, url: url, parentTweet: parentTweet)
                    }
                } else {
                    // Player is still valid (short background). AVPlayerLayer's render
                    // pipeline is suspended — handled by TVC's didBecomeActive observer
                    // which calls refreshVideoLayerAfterForeground() when GPU is ready.
                }
            }
        }
    }

    /// Show cached thumbnail over the video player layer before background cleanup.
    /// Called by TweetTableViewController for all visible cells before video memory is released.
    func showThumbnailForBackground() {
        guard isVideoAttachment, isVisible else { return }
        guard videoCellState == .playing || videoCellState == .paused || videoCellState == .playerReady else { return }
        guard let mid = attachment?.mid,
              let thumbnail = SharedAssetCache.shared.cachedThumbnail(for: mid) else { return }
        imageView.image = thumbnail
        // Detach player from layer so isReadyForDisplay resets to false.
        // This ensures the thumbnail stays as cover until the layer actually
        // renders a frame after foreground return.
        videoPlayerView.setPlayer(nil)
        hasRenderedFrameForCurrentPlayer = false
        transitionTo(.thumbnail)
    }

    /// Re-attach player and seek to force AVPlayerLayer to render after foreground.
    /// Called from didBecomeActive when GPU is guaranteed ready.
    /// Skips currently playing videos to avoid disrupting playback.
    func refreshVideoLayerAfterForeground() {
        guard isVideoAttachment, let player = player, player.rate == 0 else { return }
        // Only refresh if videoPlayerView was previously rendering content
        guard videoCellState == .playerReady || videoCellState == .paused else { return }


        // Temporarily show cached thumbnail while AVPlayerLayer re-initializes.
        // This prevents a black flash if the layer takes time to resume rendering.
        if let mid = attachment?.mid,
           let cachedFrame = SharedAssetCache.shared.cachedThumbnail(for: mid) {
            imageView.image = cachedFrame
        }
        transitionTo(.playerLoading)

        // Transition to playerReady when the layer renders its first frame
        videoPlayerView.onReadyForDisplay = { [weak self] in
            guard let self else { return }
            self.hasRenderedFrameForCurrentPlayer = true
            if self.videoCellState == .playerLoading {
                self.transitionTo(.playerReady)
            }
        }

        // Re-attach player to force layer re-initialization
        videoPlayerView.setPlayer(nil)
        hasRenderedFrameForCurrentPlayer = false
        videoPlayerView.setPlayer(player)
        let t = player.currentTime()
        let target = (t.isValid && !t.seconds.isNaN) ? t : .zero
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
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

    private func cleanupVideoPlayer(reason: String) {
        if isVideoAttachment {
            preserveFrameToCache()
        }

        // Cancel any pending debounce — prevents player acquisition after cleanup.
        playerAcquireDebounceTask?.cancel()
        playerAcquireDebounceTask = nil

        let hasWork =
            setupPlayerTask != nil ||
            playbackStartupRecoveryTask != nil ||
            videoOutput != nil ||
            videoOutputAttachedItem != nil ||
            timeObserverToken != nil ||
            player != nil ||
            playerItemStatusObserver != nil ||
            timeControlStatusObserver != nil ||
            playbackLikelyToKeepUpObserver != nil ||
            videoCompletionObserver != nil ||
            stopAllObserver != nil ||
            playerLoanedObserver != nil ||
            playerClaimedObserver != nil ||
            videoThumbnailObserver != nil ||
            videoPlayerPreloadedObserver != nil ||
            shouldPlayObserver != nil ||
            shouldPauseObserver != nil ||
            shouldStopObserver != nil ||
            !(videoPlayerView.gestureRecognizers?.isEmpty ?? true) ||
            !(imageView.gestureRecognizers?.isEmpty ?? true)


        if hasWork {
            teardownPlayerAndObservers()
        }
        resetVideoState()
    }

    /// Cancel tasks, remove all observers, detach player from layer, nil player.
    private func teardownPlayerAndObservers() {
        setupPlayerTask?.cancel()
        setupPlayerTask = nil
        statusUnknownFallbackTask?.cancel()
        statusUnknownFallbackTask = nil
        cancelDelayedPrimarySpinner()
        playbackStartupRecoveryTask?.cancel()
        playbackStartupRecoveryTask = nil
        playbackStartupRecoveryRequestDate = nil

        videoPlayerView.onReadyForDisplay = nil

        removePlayerObservers()

        if let o = stopAllObserver { NotificationCenter.default.removeObserver(o) }
        stopAllObserver = nil
        if let o = playerLoanedObserver { NotificationCenter.default.removeObserver(o) }
        playerLoanedObserver = nil
        if let o = playerClaimedObserver { NotificationCenter.default.removeObserver(o) }
        playerClaimedObserver = nil
        if let o = videoThumbnailObserver { NotificationCenter.default.removeObserver(o) }
        videoThumbnailObserver = nil
        if let o = videoPlayerPreloadedObserver { NotificationCenter.default.removeObserver(o) }
        videoPlayerPreloadedObserver = nil
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
        player = nil
    }

    /// Reset all video-related flags and counters to initial values.
    private func resetVideoState() {
        coordinatorWantsToPlay = false
        isHandlingFinishEvent = false
        playerWasLoaned = false
        videoCellState = .noContent
        cancelDelayedPrimarySpinner()
        lastFrameCaptureAt = .distantPast
        lastActualPlaybackDate = .distantPast
        hasRenderedFrameForCurrentPlayer = false
        lastPlaybackRequestDate = .distantPast
        lastPlaybackNudgeDate = .distantPast
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
        muteButton.isHidden = true
        timerLabel.isHidden = true
        fullscreenOverlay.isHidden = true
        fullscreenSpinner.stopAnimating()

        // Reset state
        pendingRecoverySeekTime = nil
        videoCellState = .noContent
        attachment = nil
        parentTweet = nil
        isVisible = false
        shouldAcquirePlayerWhenVisible = true
    }

    deinit {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let o = stopAllObserver {
            NotificationCenter.default.removeObserver(o)
        }
        if let o = videoCompletionObserver {
            NotificationCenter.default.removeObserver(o)
        }
        if let o = videoThumbnailObserver {
            NotificationCenter.default.removeObserver(o)
        }
        if let o = videoPlayerPreloadedObserver {
            NotificationCenter.default.removeObserver(o)
        }
        if let o = shouldPlayObserver {
            NotificationCenter.default.removeObserver(o)
        }
        if let o = shouldPauseObserver {
            NotificationCenter.default.removeObserver(o)
        }
        if let o = shouldStopObserver {
            NotificationCenter.default.removeObserver(o)
        }
        playerItemStatusObserver?.invalidate()
        timeControlStatusObserver?.invalidate()
        playbackLikelyToKeepUpObserver?.invalidate()
        removePlayerTimeObserver()
        timerHideTask?.cancel()
        playerAcquireDebounceTask?.cancel()
        setupPlayerTask?.cancel()
        imageLoadTask?.cancel()
    }
}
