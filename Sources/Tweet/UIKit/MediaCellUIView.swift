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
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        return spinner
    }()

    /// Retry button shown when image download fails
    private lazy var retryButton: UIButton = {
        let btn = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        btn.setImage(UIImage(systemName: "arrow.clockwise.circle", withConfiguration: config), for: .normal)
        btn.tintColor = .secondaryLabel
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
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white.withAlphaComponent(0.6)
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        label.layer.cornerRadius = 10
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
    private var resumeObserver: NSKeyValueObservation?
    private var timeControlStatusObserver: NSKeyValueObservation?

    /// Notification observers
    private var videoCompletionObserver: NSObjectProtocol?
    private var stopAllObserver: NSObjectProtocol?
    private var playerLoanedObserver: NSObjectProtocol?
    private var shouldPlayObserver: NSObjectProtocol?
    private var shouldPauseObserver: NSObjectProtocol?
    private var shouldStopObserver: NSObjectProtocol?

    /// Async player acquisition task
    private var setupPlayerTask: Task<Void, Never>?

    /// Periodic time observer token for the video timer label
    private var timeObserverToken: Any?

    /// Frame capture throttle
    private var lastFrameCaptureAt: Date = .distantPast

    /// Whether the player item is loaded and ready to play
    private var isPlayerLoaded: Bool = false

    /// Prevent duplicate finish handling
    private var isHandlingFinishEvent: Bool = false

    /// Tracks when the player was loaned to detail view; enables fast-path reclaim on return
    private var playerWasLoaned: Bool = false

    /// Video cell state machine — controls imageView/videoPlayerView/spinner visibility
    private var videoCellState: VideoCellState = .noContent

    /// Video retry count for automatic retry with backoff (max 2 auto-retries)
    private var videoRetryCount: Int = 0

    /// Scheduled automatic retry task (cancelled on reuse/visibility change)
    private var videoRetryTask: DispatchWorkItem?

    /// Maximum automatic retries before showing manual retry button
    private static let maxAutoRetries = 2

    /// Retry delays: 2s for first auto-retry, 5s for second
    private static let retryDelays: [TimeInterval] = [2.0, 5.0]

    /// Buffering timeout — triggers recovery if player stays in waitingToPlayAtSpecifiedRate for 15s
    private var bufferingTimeoutTask: DispatchWorkItem?

    /// Track when player configuration started (for timing logs)
    private var playerConfigureStartTime: Date?

    // MARK: - General State

    /// Per-feed video coordinator (set by MediaGridUIView during configure)
    weak var videoCoordinator: VideoPlaybackCoordinator?

    private var attachment: MimeiFileType?
    private weak var parentTweet: Tweet?
    private var attachmentIndex: Int = 0
    private var aspectRatio: Float = 1.0
    private var isEmbedded: Bool = false
    private var cellTweetId: String?
    private var shouldLoadVideo: Bool = true
    private var isVisible: Bool = false
    private var effectiveBaseUrl: URL = HproseInstance.baseUrl
    private var isSingleMedia: Bool = false
    private weak var parentViewController: UIViewController?

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
    private var isShowingFullscreen: Bool = false

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
        // Automatically detect visibility based on window presence and frame size
        // This replaces relying on MediaGridUIView's isGridVisible
        if window != nil && bounds.width > 0 {
            // Cell is in window with valid layout → visible
            if !isVisible {
                setVisible(true)
            }
        } else {
            // Cell removed from window or no layout yet → hidden
            if isVisible {
                setVisible(false)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        imageView.frame = b
        videoPlayerView.frame = b
        loadingSpinner.center = CGPoint(x: b.midX, y: b.midY)

        // After layout, check visibility (frame might have just become valid)
        if window != nil && b.width > 0 && !isVisible {
            setVisible(true)
        }
        retryButton.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        retryButton.center = CGPoint(x: b.midX, y: b.midY)
        fullscreenOverlay.frame = b
        fullscreenSpinner.center = CGPoint(x: b.midX, y: b.midY)

        // Mute button: 44pt touch area centered on 26pt visual circle, bottom-right
        let visualSize: CGFloat = 26
        let touchSize: CGFloat = 44
        let inset = (touchSize - visualSize) / 2  // 9pt
        muteButton.frame = CGRect(
            x: b.maxX - visualSize - 12 - inset,
            y: b.maxY - visualSize - 12 - inset,
            width: touchSize, height: touchSize
        )
        muteCircleLayer.frame = CGRect(x: inset, y: inset, width: visualSize, height: visualSize)

        // Timer label: bottom-left, 12pt padding
        if !timerLabel.isHidden {
            let timerSize = timerLabel.sizeThatFits(CGSize(width: 100, height: 20))
            let timerW = timerSize.width + 16
            let timerH: CGFloat = 20
            timerLabel.frame = CGRect(
                x: 12,
                y: b.maxY - timerH - 12,
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
            loadingSpinner.startAnimating()
        case .thumbnail:
            imageView.isHidden = false  // caller must set imageView.image before this
            videoPlayerView.isHidden = true
            loadingSpinner.stopAnimating()
        case .playerLoading:
            let hasThumbnail = imageView.image != nil
            imageView.isHidden = !hasThumbnail
            // Hide videoPlayerView when thumbnail exists — the player hasn't rendered
            // a frame yet so it would show black on top of the thumbnail. The layer
            // still decodes in the background; onReadyForDisplay → .playerReady will
            // show it once the first frame is available.
            videoPlayerView.isHidden = hasThumbnail
            // Show spinner when coordinator wants to play (primary video) even if
            // a thumbnail is already visible — the thumbnail is just a cover while
            // the player initialises, and the user needs feedback that loading is
            // in progress.  For non-primary videos preloading in the background,
            // keep the spinner off to avoid distracting chrome.
            if coordinatorWantsToPlay || !hasThumbnail {
                loadingSpinner.startAnimating()
            } else {
                loadingSpinner.stopAnimating()
            }
        case .playerReady:
            // Keep showing thumbnail for non-primary videos to avoid black screen
            // Only hide thumbnail when video is about to play (coordinatorWantsToPlay)
            let hasThumbnail = imageView.image != nil
            if hasThumbnail && !coordinatorWantsToPlay {
                // Non-primary video: keep thumbnail visible, hide player layer
                print("\(logPrefix) 🖼️ Keeping thumbnail for non-primary video")
                imageView.isHidden = false
                videoPlayerView.isHidden = true
            } else {
                // Primary video or no thumbnail: show player layer
                imageView.isHidden = true
                videoPlayerView.isHidden = false
            }
            // With streaming, the first frame can render before the player has buffered
            // enough data to start continuous playback.  Keep the spinner on if the
            // coordinator has already sent a play command so the user knows it's still loading.
            if coordinatorWantsToPlay {
                loadingSpinner.startAnimating()
            } else {
                loadingSpinner.stopAnimating()
            }
        case .playing, .paused:
            videoPlayerView.isHidden = false
            // Show spinner while player is buffering (told to play but waiting for data)
            if state == .playing && player?.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                loadingSpinner.startAnimating()
            } else {
                loadingSpinner.stopAnimating()
            }
            // Pre-load the cached last frame into imageView so it can serve as cover
            // if the AVPlayerLayer's GPU pipeline is suspended.  This happens when a
            // full-screen modal (fullscreen video browser) covers the feed and iOS
            // suspends the layer rendering — on return the layer briefly shows black
            // before it resumes, and imageView (if set) hides the flash.
            if imageView.image == nil,
               let mid = attachment?.mid,
               let cachedFrame = VideoLastFrameCache.shared.image(for: mid) {
                imageView.image = cachedFrame
            }
            // Keep thumbnail as cover until player layer is actually rendering frames.
            // This prevents black flash when resuming from background or fullscreen.
            if state == .paused {
                // Paused: always keep imageView as cover — the player layer's GPU
                // pipeline may be suspended (e.g., during fullscreen overlay) causing
                // black screen. imageView will be hidden when playback resumes (.playing).
                imageView.isHidden = (imageView.image == nil)
            } else if videoPlayerView.isLayerReadyForDisplay {
                imageView.isHidden = true
            } else {
                imageView.isHidden = (imageView.image == nil)
                videoPlayerView.onReadyForDisplay = { [weak self] in
                    guard let self else { return }
                    self.imageView.isHidden = true
                }
                videoPlayerView.observeReadyForDisplay()
            }
        case .failed:
            if player != nil {
                // Video was playing — keep showing the paused frame in videoPlayerView
                videoPlayerView.isHidden = false
                imageView.isHidden = true
            } else {
                let hasThumbnail = imageView.image != nil
                imageView.isHidden = !hasThumbnail
                videoPlayerView.isHidden = true
            }
            loadingSpinner.stopAnimating()
            retryButton.isHidden = false
        }
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
        self.isEmbedded = isEmbedded
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

        loadImage(attachment: attachment, url: url)
    }

    private func loadImage(attachment: MimeiFileType, url: URL) {
        // 1. Memory cache (synchronous)
        if let cached = imageCache.getCompressedImageFromMemory(for: attachment) {
            imageView.image = cached
            return
        }

        // 2. Disk cache (background) → network (default gray color for light image background)
        loadingSpinner.color = nil  // reset to system default (gray, visible on .systemGray6)
        loadingSpinner.startAnimating()
        let attachmentCopy = attachment
        let baseUrlCopy = effectiveBaseUrl

        imageLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let cachedImage = self.imageCache.getCompressedImage(for: attachmentCopy)

            await MainActor.run {
                // Guard: cell may have been reused for a different attachment
                guard self.attachment?.mid == attachmentCopy.mid else { return }

                if let cachedImage {
                    self.imageView.image = cachedImage
                    self.loadingSpinner.stopAnimating()
                } else {
                    // Use critical priority for ALL visible images (single or grid)
                    GlobalImageLoadManager.shared.loadImageCriticalPriority(
                        id: attachmentCopy.mid,
                        url: url,
                        attachment: attachmentCopy,
                        baseUrl: baseUrlCopy
                    ) { [weak self] loadedImage in
                        // Guard: cell may have been reused while network load was in flight
                        guard self?.attachment?.mid == attachmentCopy.mid else { return }
                        if let loadedImage = loadedImage {
                            self?.imageView.image = loadedImage
                            self?.loadingSpinner.stopAnimating()
                            self?.retryButton.isHidden = true
                        } else {
                            // Image failed/cancelled - show retry button if not cancelled
                            self?.loadingSpinner.stopAnimating()
                            if !Task.isCancelled {
                                self?.retryButton.isHidden = false
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Video

    private func setupVideoCell(attachment: MimeiFileType, url: URL, parentTweet: Tweet) {
        print("\(logPrefix) Setup video cell")

        // Reset any previous video state
        cleanupVideoPlayer()

        // Set spinner color for video (white on dark background)
        loadingSpinner.color = .white.withAlphaComponent(0.7)

        // Set initial state based on cached thumbnail availability
        let hasCachedThumbnail = VideoLastFrameCache.shared.image(for: attachment.mid) != nil
        print("\(logPrefix) Cached thumbnail: \(hasCachedThumbnail)")

        if let cachedFrame = VideoLastFrameCache.shared.image(for: attachment.mid) {
            imageView.image = cachedFrame
            transitionTo(.thumbnail)
        } else {
            transitionTo(.noContent)
            // Try to generate thumbnail from cached asset
            if let mediaID = SharedAssetCache.shared.extractMediaID(from: url) {
                SharedAssetCache.shared.generateThumbnailIfNeeded(for: mediaID) { [weak self] image in
                    guard let self, self.attachment?.mid == attachment.mid else { return }
                    self.imageView.image = image
                    switch self.videoCellState {
                    case .noContent:
                        self.transitionTo(.thumbnail)
                    case .playerLoading:
                        self.transitionTo(.playerLoading)  // re-evaluate: shows thumbnail, stops spinner
                    default:
                        break  // player already rendering
                    }
                }
            }
        }

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

        // Observe MuteState changes → forward to player
        MuteState.shared.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] muted in
                self?.player?.isMuted = muted
            }
            .store(in: &cancellables)

        // Acquire player (sync from cache or async from SharedAssetCache)
        acquirePlayer(attachment: attachment, url: url, parentTweet: parentTweet)

        // Mute button for single video (timer shown when playback starts)
        if isSingleMedia {
            setupMuteButton()
        }
    }

    // MARK: - Player Acquisition

    private func acquirePlayer(attachment: MimeiFileType, url: URL, parentTweet: Tweet) {
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

            let itemStatus = cachedPlayer.currentItem?.status.rawValue ?? -1
            let isAtEnd = isVideoAtEnd(cachedPlayer)
            print("\(logPrefix) ✓ Cache hit (sync) - itemStatus: \(itemStatus), atEnd: \(isAtEnd)")

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

        print("\(logPrefix) Cache miss - loading async")
        // TIER 2: Async loading
        acquirePlayerAsync(attachment: attachment, url: url, parentTweet: parentTweet)
    }

    private func acquirePlayerAsync(attachment: MimeiFileType, url: URL, parentTweet: Tweet) {
        guard shouldLoadVideo else { return }
        isPlayerLoaded = false

        let uniqueURL = buildUniquePlayerURL(url: url, parentTweetId: parentTweet.mid)
        let tweetId = parentTweet.mid
        let mediaType = attachment.type

        setupPlayerTask?.cancel()
        setupPlayerTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try Task.checkCancellation()
                let startTime = Date()
                let newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(
                    for: uniqueURL, tweetId: tweetId, mediaType: mediaType
                )
                try Task.checkCancellation()

                let loadTime = Date().timeIntervalSince(startTime)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    print("\(self.logPrefix) ✓ Player created (async) - loadTime: \(String(format: "%.2f", loadTime))s")
                }

                // Apply mute state immediately after creation
                let muteState = await MainActor.run { MuteState.shared.isMuted }
                newPlayer.isMuted = muteState

                await MainActor.run { [weak self] in
                    guard !Task.isCancelled, let self else { return }
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
                    self.handleVideoLoadFailure(reason: "Player creation failed: \(error.localizedDescription)")
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
        playerConfigureStartTime = Date()

        let itemStatus = newPlayer.currentItem?.status.rawValue ?? -1
        let assetURL = (newPlayer.currentItem?.asset as? AVURLAsset)?.url.absoluteString ?? "no-url"
        print("\(logPrefix) Configure player - itemStatus: \(itemStatus), url: \(assetURL)")


        // Pause if playing (prevent audio bleed in feed)
        if newPlayer.rate > 0 { newPlayer.pause() }

        // Apply mute state
        newPlayer.isMuted = MuteState.shared.isMuted

        // Clean up old observers before setting new player
        removePlayerObservers()

        // Assign player
        self.player = newPlayer

        // Transition to playerLoading — shows thumbnail if available, spinner if not
        transitionTo(.playerLoading)

        // When player layer renders its first frame, transition to playerReady
        videoPlayerView.onReadyForDisplay = { [weak self] in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(self.playerConfigureStartTime ?? Date())
            print("\(self.logPrefix) ✓ Player layer ready - time: \(String(format: "%.2f", elapsed))s")

            // onReadyForDisplay means the item decoded a frame — it MUST be readyToPlay.
            // Set isPlayerLoaded in case the KVO observer hasn't fired yet (race condition).
            if !self.isPlayerLoaded {
                self.isPlayerLoaded = true
            }

            // If no thumbnail yet, capture one now to avoid spinner on future visibility
            if self.imageView.image == nil {
                print("\(self.logPrefix) 📸 No thumbnail - capturing from player layer")
                self.captureLastFrameIfPossible(reason: "firstFrameReady")
                // Re-transition to update visibility (might show thumbnail now)
                if self.videoCellState == .playerLoading {
                    self.transitionTo(.playerLoading)
                }
            }

            if self.videoCellState == .playerLoading {
                self.transitionTo(.playerReady)
            }

            // Safety net: if coordinator wants to play but KVO hasn't triggered it, play now.
            if self.coordinatorWantsToPlay, let player = self.player, player.rate == 0,
               self.videoCellState == .playerReady {
                print("\(self.logPrefix) ▶️ Safety net: starting playback from onReadyForDisplay")
                self.playWithVolumeFadeIn(player)
            }
        }

        // Disable implicit CALayer animations during player attachment
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoPlayerView.setPlayer(newPlayer)
        CATransaction.commit()

        // Set up KVO + notification observers
        setupPlayerObservers(newPlayer)

        // If item is already ready (e.g. cached player, or returning from fullscreen), update UI immediately.
        // Otherwise we stay in .playerLoading until onReadyForDisplay fires, which may not fire for re-attached layers.
        if let item = newPlayer.currentItem,
           item.status == .readyToPlay {
            isPlayerLoaded = true
            transitionTo(.playerReady)
            if coordinatorWantsToPlay {
                if isVideoAtEnd(newPlayer) {
                    newPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        guard let self, self.coordinatorWantsToPlay, let player = self.player else { return }
                        self.playWithVolumeFadeIn(player)
                    }
                } else {
                    playWithVolumeFadeIn(newPlayer)
                }
            } else {
                // Not going to play — seek to force AVPlayerLayer to decode a frame.
                // onReadyForDisplay will fire → .playerReady (if not already)
                let seekTarget = CMTime(seconds: 0.01, preferredTimescale: 600)
                newPlayer.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }

        // Defer video output attachment
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === newPlayer else { return }
            self.ensureVideoOutputAttached(for: newPlayer)
        }

        // Stuck player detector — recover if player stays in .playerLoading beyond 15 seconds.
        // This handles cases where CachingPlayerItem's resource loader stalls (server reachable
        // for HEAD but never delivers the m3u8 data), leaving the item in .unknown forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self, self.player === newPlayer, self.isVisible else { return }
            guard !self.isPlayerLoaded && self.videoCellState == .playerLoading else { return }
            let status = newPlayer.currentItem?.status.rawValue ?? -1
            let url = (newPlayer.currentItem?.asset as? AVURLAsset)?.url.absoluteString ?? "no-url"
            print("\(self.logPrefix) ⚠️ STUCK PLAYER recovery - 15s timeout, status: \(status), url: \(url)")
            // Release the stuck player but keep disk cache — server was slow, not corrupt.
            if let mid = self.attachment?.mid {
                SharedAssetCache.shared.clearPlayerForMediaID(mid, deleteDiskCache: false)
            }
            self.handleVideoLoadFailure(reason: "15s stuck player timeout, status: \(status)")
        }
    }

    // MARK: - Coordinator Command Handlers

    private func handleCoordinatorPlayCommand() {
        guard let mid = attachment?.mid else { return }

        print("\(logPrefix) ▶️ Coordinator play command - state: \(videoCellState), hasPlayer: \(player != nil), isLoaded: \(isPlayerLoaded)")

        isHandlingFinishEvent = false
        VideoStateCache.shared.clearStoppedByCoordinator(mid)
        coordinatorWantsToPlay = true

        // If video is in failed state, always clean up and retry regardless of player health.
        // Buffering timeout transitions to .failed but preserves the player — simply calling
        // play() on the same player won't fix the underlying network issue.
        if videoCellState == .failed {
            print("\(logPrefix) 🔄 Coordinator play on failed video - cleaning up and retrying")
            cleanupVideoPlayer()
            isPlayerLoaded = false
            videoRetryCount = 0
            retryButton.isHidden = true
            if let att = attachment, let url = att.getUrl(effectiveBaseUrl),
               let parentTweet = parentTweet {
                transitionTo(imageView.image != nil ? .thumbnail : .noContent)
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
                isPlayerLoaded = true

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

        // If player not ready, set flag and let KVO trigger play when ready
        guard let player = player, isPlayerLoaded else {
            print("\(logPrefix) Player not ready - will play when ready")

            // Show loading state whenever primary and not yet playing. Re-evaluate .playerLoading
            // so spinner is on (coordinatorWantsToPlay is true). Include .playerReady so that when
            // we scroll back and the cell was in .playerReady with spinner off, we show spinner again.
            if videoCellState == .noContent || videoCellState == .thumbnail || videoCellState == .playerLoading || videoCellState == .playerReady {
                transitionTo(.playerLoading)
            }

            // Trigger player setup if needed
            if self.player == nil, shouldLoadVideo, isVisible,
               let att = attachment, let url = att.getUrl(effectiveBaseUrl),
               let parentTweet = parentTweet {
                acquirePlayer(attachment: att, url: url, parentTweet: parentTweet)
            }

            // coordinatorWantsToPlay is already set — KVO observer will call
            // playWhenReady() when playerItem.status becomes .readyToPlay
            return
        }

        // Validate player health — after background, currentItem may have been stripped
        // while isPlayerLoaded remained true (cell was not visible during foreground recovery)
        if player.currentItem == nil || player.currentTime().seconds.isNaN {
            cleanupVideoPlayer()
            isPlayerLoaded = false
            if let att = attachment, let url = att.getUrl(effectiveBaseUrl), let parentTweet = parentTweet {
                setupVideoCell(attachment: att, url: url, parentTweet: parentTweet)
            }
            // Restore after setupVideoCell — both cleanupVideoPlayer() calls reset it,
            // but we need it so the new player auto-plays once ready
            coordinatorWantsToPlay = true
            return
        }

        // Reset finished videos to beginning before playing
        if isVideoAtEnd(player) {
            VideoStateCache.shared.clearCachedState(for: mid)
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self, self.coordinatorWantsToPlay, let player = self.player else { return }
                self.playWithVolumeFadeIn(player)
            }
            return
        }

        // Player is ready — play
        playWithVolumeFadeIn(player)
    }

    private func handleCoordinatorPauseCommand() {
        guard let mid = attachment?.mid else { return }
        print("\(logPrefix) ⏸️ Coordinator pause command")
        coordinatorWantsToPlay = false
        bufferingTimeoutTask?.cancel()
        bufferingTimeoutTask = nil

        if let player = player {
            if player.rate > 0 {
                saveCurrentPosition(player: player, wasPlaying: true)
            }
            captureLastFrameIfPossible(reason: "coordinatorPause")
            if videoCellState == .playing {
                transitionTo(.paused)
            }
            // Volume fade-out then pause
            UIView.animate(withDuration: 0.2, animations: {
                player.volume = 0
            }, completion: { _ in
                player.pause()
            })
        }
        VideoStateCache.shared.markAsStoppedByCoordinator(mid)
    }

    private func handleCoordinatorStopCommand() {
        guard let mid = attachment?.mid else { return }
        print("\(logPrefix) ⏹️ Coordinator stop command")
        coordinatorWantsToPlay = false
        bufferingTimeoutTask?.cancel()
        bufferingTimeoutTask = nil
        videoRetryTask?.cancel()
        videoRetryTask = nil

        if let player = player {
            if player.rate > 0 {
                saveCurrentPosition(player: player, wasPlaying: true)
            }
            captureLastFrameIfPossible(reason: "coordinatorStop")

            if !isPlayerLoaded && videoCellState == .playerLoading {
                // Player still loading (itemStatus unknown) — release it immediately
                // to free network resources instead of waiting for the 15s stuck timer.
                // Remove observers BEFORE nilling player to prevent memory leak
                // (observers hold strong references to the player item).
                removePlayerObservers()
                SharedAssetCache.shared.clearPlayerForMediaID(mid, deleteDiskCache: false)
                self.player = nil
                isPlayerLoaded = false
                setupPlayerTask = nil
                videoRetryCount = 0
                if imageView.image != nil {
                    transitionTo(.thumbnail)
                } else {
                    transitionTo(.noContent)
                    loadingSpinner.stopAnimating()
                }
            } else if videoCellState == .playing {
                transitionTo(.paused)
                player.pause()
            } else {
                player.pause()
            }
        }
        VideoStateCache.shared.markAsStoppedByCoordinator(mid)
    }

    private func handleStopAllVideos() {
        guard isVideoAttachment else { return }
        coordinatorWantsToPlay = false
        bufferingTimeoutTask?.cancel()
        bufferingTimeoutTask = nil

        if let player = player {
            if player.rate > 0 {
                saveCurrentPosition(player: player, wasPlaying: true)
            }
            captureLastFrameIfPossible(reason: "stopAllVideos")
            if videoCellState == .playing {
                transitionTo(.paused)
            }
            player.pause()
            player.isMuted = MuteState.shared.isMuted
        }
    }

    // MARK: - Playback

    private func playWithVolumeFadeIn(_ player: AVPlayer) {
        guard let mid = attachment?.mid else { return }

        // Check for cached position to resume from
        if let info = VideoStateCache.shared.getCachedPlaybackInfo(for: mid) {
            let targetSeconds = info.time.seconds
            if targetSeconds.isFinite, targetSeconds > 0.25 {
                let currentSeconds = player.currentTime().seconds
                if currentSeconds.isFinite, abs(currentSeconds - targetSeconds) > 0.25 {
                    player.seek(to: info.time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                        guard let self, let _ = self.attachment?.mid else { return }
                        self.startPlaybackWithFade(player)
                    }
                    return
                }
            }
        }

        startPlaybackWithFade(player)
    }

    private func startPlaybackWithFade(_ player: AVPlayer) {
        guard (attachment?.mid) != nil else { return }

        // If we have a thumbnail, defer until the layer decodes its first frame so the
        // thumbnail covers the layer during decode (prevents black flash).
        // Do NOT defer when there is no thumbnail: isReadyForDisplay only fires after
        // play() or seek(), so deferring with no thumbnail creates a deadlock (stuck black screen).
        if videoCellState == .playerLoading && imageView.image != nil {
            print("\(logPrefix) ⏳ Deferring playback - waiting for layer (have thumbnail)")
            videoPlayerView.onReadyForDisplay = { [weak self] in
                guard let self, self.coordinatorWantsToPlay else { return }
                print("\(self.logPrefix) ✓ Layer ready - starting deferred playback")
                self.actuallyStartPlayback(player)
            }
            return
        }

        print("\(logPrefix) ▶️ Starting playback")
        actuallyStartPlayback(player)
    }

    private func actuallyStartPlayback(_ player: AVPlayer) {
        guard let mid = attachment?.mid else { return }

        // Re-attach player to layer if it was detached for background.
        // In normal flow this is a no-op (same player already attached).
        videoPlayerView.setPlayer(player)

        // Transition to playing — keeps thumbnail as cover until layer confirms rendering
        transitionTo(.playing)

        player.isMuted = MuteState.shared.isMuted
        player.volume = 0
        player.play()
        UIView.animate(withDuration: 0.3) {
            player.volume = 1.0
        }

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

    private func captureLastFrameIfPossible(reason: String) {
        guard isVideoAttachment else { return }
        guard let player = player, let item = player.currentItem else { return }

        ensureVideoOutputAttached(for: player)
        guard let output = videoOutput else { return }
        guard item.status == .readyToPlay, !item.loadedTimeRanges.isEmpty else { return }

        // Throttle: 0.75s minimum between captures
        let now = Date()
        guard now.timeIntervalSince(lastFrameCaptureAt) >= 0.75 else { return }
        lastFrameCaptureAt = now

        guard let mid = attachment?.mid else { return }
        let playerTimeNow = player.currentTime()
        let hostTimeNow = CACurrentMediaTime()
        let hostItemTimeNow = output.itemTime(forHostTime: hostTimeNow)

        Task.detached(priority: .utility) {
            // Build candidate times with backoffs
            let base = playerTimeNow
            let backoffs: [Double] = [0.0, -0.08, -0.20, -0.40]
            var candidateTimes: [CMTime] = []
            for d in backoffs {
                let t = CMTime(seconds: max(0, base.seconds + d), preferredTimescale: 600)
                if t.isValid { candidateTimes.append(t) }
            }
            if hostItemTimeNow.isValid { candidateTimes.append(hostItemTimeNow) }

            var pixelBuffer: CVPixelBuffer? = nil
            var displayTime = CMTime.zero
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
                VideoLastFrameCache.shared.set(image, for: mid)
            }
        }
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
        print("\(logPrefix) 👀 Setting up playerItem.status KVO observer")
        playerItemStatusObserver = playerItem.observe(\.status, options: [.old, .new]) { [weak self] item, change in
            DispatchQueue.main.async {
                guard let self else { return }
                guard (self.attachment?.mid) != nil else { return }

                let oldStatus = change.oldValue?.rawValue ?? -1
                let newStatus = item.status.rawValue
                let statusName: String = {
                    switch item.status {
                    case .unknown: return "unknown"
                    case .readyToPlay: return "readyToPlay"
                    case .failed: return "failed"
                    @unknown default: return "unknown-\(newStatus)"
                    }
                }()
                print("\(self.logPrefix) 📊 Status change: \(oldStatus) → \(newStatus) (\(statusName))")

                if item.status == .readyToPlay {
                    let wasAlreadyLoaded = self.isPlayerLoaded
                    self.isPlayerLoaded = true

                    if !wasAlreadyLoaded {
                        print("\(self.logPrefix) ✓ Item ready to play - coordinatorWantsToPlay: \(self.coordinatorWantsToPlay)")
                        if self.coordinatorWantsToPlay, let player = self.player {
                            if self.isVideoAtEnd(player) {
                                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                                    guard let self, self.coordinatorWantsToPlay, let player = self.player else { return }
                                    self.playWithVolumeFadeIn(player)
                                }
                            } else {
                                self.playWithVolumeFadeIn(player)
                            }
                        } else if let player = self.player {
                            // Not going to play — seek to force AVPlayerLayer to decode a frame.
                            // onReadyForDisplay will fire → .playerReady
                            // Seek to 0.01s to force decode (seeking to current position is no-op)
                            let seekTarget = CMTime(seconds: 0.01, preferredTimescale: 600)
                            player.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    }
                } else if item.status == .failed {
                    let errorMsg = item.error?.localizedDescription ?? "Unknown error"
                    print("\(self.logPrefix) ❌ Player failed: \(errorMsg)")
                    if let error = item.error {
                        let nsError = error as NSError
                        print("\(self.logPrefix) ❌ Error detail: domain=\(nsError.domain), code=\(nsError.code)")
                    }
                    // Release the failed player from SharedAssetCache. Guard: don't clear
                    // if fullscreen player owns this video (would kill its streaming).
                    if let mid = self.attachment?.mid {
                        let fullscreenOwnsMid = OverlayVisibilityCoordinator.shared.isCovered
                            && FullScreenVideoManager.shared.currentVideoMid == mid
                        if !fullscreenOwnsMid {
                            SharedAssetCache.shared.clearPlayerForMediaID(mid, deleteDiskCache: false)
                        }
                    }
                    self.handleVideoLoadFailure(reason: "playerItem.status == .failed: \(errorMsg)")
                } else if item.status == .unknown {
                    // Log unknown status to diagnose why player is stuck
                    if let asset = item.asset as? AVURLAsset {
                        print("\(self.logPrefix) ⏳ Status unknown - url: \(asset.url.absoluteString)")
                    } else {
                        print("\(self.logPrefix) ⏳ Status unknown")
                    }
                }
            }
        }

        // KVO: timeControlStatus — show spinner while buffering, stop when actually playing
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if player.timeControlStatus == .playing {
                    self.loadingSpinner.stopAnimating()
                    self.bufferingTimeoutTask?.cancel()
                    self.bufferingTimeoutTask = nil
                } else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                          self.videoCellState == .playing || self.videoCellState == .playerReady {
                    // Player was told to play but is buffering — show spinner.
                    // Also covers .playerReady: streaming can render the first frame before
                    // the player has buffered enough to actually start playback.
                    self.loadingSpinner.startAnimating()
                    // Start buffering timeout — if stuck for 15s, trigger recovery
                    self.bufferingTimeoutTask?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.isVisible,
                              self.player === player,
                              player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
                        print("\(self.logPrefix) ⚠️ BUFFERING TIMEOUT - stuck waiting 15s, keeping player paused")
                        // Keep the player paused at current position — don't clear it.
                        // The video frame stays visible. Retry will call play() to resume.
                        player.pause()
                        self.coordinatorWantsToPlay = false
                        self.transitionTo(.failed)
                        // Tell coordinator to pick a new primary video
                        if let id = self.videoIdentifier {
                            (self.videoCoordinator ?? .shared).notifyPrimaryVideoFailed(identifier: id)
                        }
                    }
                    self.bufferingTimeoutTask = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: work)
                }
            }
        }
    }

    private func removePlayerObservers() {
        if let o = videoCompletionObserver { NotificationCenter.default.removeObserver(o) }
        videoCompletionObserver = nil
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = nil
        resumeObserver?.invalidate()
        resumeObserver = nil
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
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
        captureLastFrameIfPossible(reason: "videoFinished")

        // Notify coordinator to advance to next video (include full identifier: tweet id + video id + index)
        var userInfo: [String: Any] = ["videoMid": mid, "tweetId": parentTweet?.mid ?? ""]
        if let id = videoIdentifier { userInfo["videoIdentifier"] = id }
        NotificationCenter.default.post(
            name: .videoDidFinishPlaying,
            object: nil,
            userInfo: userInfo
        )

        VideoStateCache.shared.clearCache(for: mid, force: true)
    }

    // MARK: - Utilities

    private func saveCurrentPosition(player: AVPlayer, wasPlaying: Bool) {
        guard let mid = attachment?.mid else { return }
        guard player.currentItem != nil else { return }
        let currentTime = player.currentTime()
        guard currentTime.seconds.isFinite, currentTime.seconds > 0.25 else { return }
        guard !isVideoAtEnd(player) else { return }

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

        // Auto-hide timer after 5 seconds
        scheduleTimerHide()
    }

    /// Attach a periodic time observer to the player to drive the timer label.
    /// Called from configurePlayer() once we have a valid AVPlayer.
    private func startPlayerTimeObserver() {
        guard isSingleMedia else { return }
        removePlayerTimeObserver()

        guard let player = player else { return }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.updateTimerLabel(currentTime: time)
        }
    }

    private func removePlayerTimeObserver() {
        if let token = timeObserverToken, let player = player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
    }

    private func updateTimerLabel(currentTime: CMTime) {
        guard let item = player?.currentItem else { return }
        let duration = item.duration
        guard duration.isValid, !duration.isIndefinite, duration.seconds > 0 else { return }

        let remaining = max(0, duration.seconds - currentTime.seconds)
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        timerLabel.text = "\(minutes):\(String(format: "%02d", seconds))"
        setNeedsLayout()
    }

    private func scheduleTimerHide() {
        timerHideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.timerLabel.isHidden = true
            self?.removePlayerTimeObserver()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
        timerHideTask = task
    }

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
        videoRetryCount = 0

        if let player = player, isPlayerLoaded {
            // Player still exists (buffering failure) — just resume playback.
            // AVPlayer will re-request the failed segments from LocalHTTPServer.
            coordinatorWantsToPlay = true
            transitionTo(.playing)
            player.play()
        } else {
            // Player was cleared (initial load failure / item.status == .failed).
            // acquirePlayer creates a fresh player that reuses preserved disk cache.
            isPlayerLoaded = false
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

    /// Central handler for all video loading failures. Manages automatic retry
    /// with backoff (2s, 5s), then shows retry button when exhausted.
    private func handleVideoLoadFailure(reason: String) {
        guard isVideoAttachment, let mid = attachment?.mid else { return }

        // Cancel any pending retry
        videoRetryTask?.cancel()
        videoRetryTask = nil

        // Preserve the last displayed frame before releasing the player.
        // This prevents blank squares when playerItem.status == .failed mid-stream.
        if let player = player, imageView.image == nil {
            if let output = videoOutput,
               let item = player.currentItem, item.status == .readyToPlay {
                let currentTime = player.currentTime()
                var displayTime = CMTime.zero
                if let pb = output.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: &displayTime),
                   let image = VideoFrameExtractor.makeDownscaledUIImage(from: pb, maxDimension: 720),
                   !VideoFrameExtractor.isMostlyBlack(image) {
                    imageView.image = image
                    VideoLastFrameCache.shared.set(image, for: mid)
                }
            }
            // Fallback: use previously cached frame
            if imageView.image == nil,
               let cached = VideoLastFrameCache.shared.image(for: mid) {
                imageView.image = cached
            }
        }

        // Clean up player state
        loadingSpinner.stopAnimating()
        player = nil
        isPlayerLoaded = false
        setupPlayerTask = nil

        // Don't auto-retry if cell is not visible
        guard isVisible else {
            print("\(logPrefix) ❌ \(reason) - cell not visible, skipping retry")
            if imageView.image != nil {
                transitionTo(.thumbnail)
            } else {
                videoPlayerView.isHidden = true
                videoCellState = .thumbnail
            }
            return
        }

        // Don't auto-retry if coordinator has stopped this video — save retries for
        // when the coordinator actually wants to play it (scrolls back to it).
        if !coordinatorWantsToPlay {
            print("\(logPrefix) ❌ \(reason) - coordinator stopped, skipping retry")
            videoRetryCount = 0  // Fresh retry budget when coordinator plays again
            if imageView.image != nil {
                transitionTo(.thumbnail)
            } else {
                transitionTo(.noContent)
                loadingSpinner.stopAnimating()
            }
            return
        }

        if videoRetryCount < Self.maxAutoRetries {
            let delay = Self.retryDelays[videoRetryCount]
            videoRetryCount += 1
            print("\(logPrefix) 🔄 Auto-retry #\(videoRetryCount) in \(delay)s after: \(reason)")

            // Show thumbnail while waiting (not .failed state yet)
            if imageView.image != nil {
                transitionTo(.thumbnail)
            } else {
                transitionTo(.noContent)
                loadingSpinner.stopAnimating()  // Don't spin during wait
            }

            let retryWork = DispatchWorkItem { [weak self] in
                guard let self, self.isVisible,
                      self.attachment?.mid == mid,
                      let att = self.attachment,
                      let url = att.getUrl(self.effectiveBaseUrl),
                      let parentTweet = self.parentTweet else { return }

                print("\(self.logPrefix) 🔄 Executing auto-retry #\(self.videoRetryCount)")
                // Don't call clearPlayerForMediaID — the original failure handler already
                // cleared the player. Calling it again would cancel any disk-cache-backed
                // downloads and wipe in-memory state unnecessarily. acquirePlayer will
                // create a fresh player that picks up from the preserved disk cache.
                self.acquirePlayer(attachment: att, url: url, parentTweet: parentTweet)
            }
            videoRetryTask = retryWork
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retryWork)
        } else {
            // All auto-retries exhausted — show retry button
            print("\(logPrefix) ❌ \(reason) - showing retry button after \(videoRetryCount) auto-retries")
            coordinatorWantsToPlay = false
            transitionTo(.failed)
            // Tell coordinator to pick a new primary video
            if let id = videoIdentifier {
                (videoCoordinator ?? .shared).notifyPrimaryVideoFailed(identifier: id)
            }
        }
    }

    @objc private func imageTapped() {
        guard let parentTweet, let parentVC = parentViewController else { return }
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

            self?.isShowingFullscreen = true
        }
    }

    private func saveVideoPositionForFullscreen() {
        guard let attachment else { return }

        // Try to save directly from our player first
        if let player = player, player.currentItem != nil {
            let currentTime = player.currentTime()
            let wasPlaying = player.rate > 0
            PersistentVideoStateManager.shared.saveState(
                videoMid: attachment.mid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .fullScreen
            )
        } else if let cachedState = VideoStateCache.shared.getCachedState(for: attachment.mid) {
            let currentTime = cachedState.player.currentTime()
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

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible

        guard let attachment else { return }

        if isVideoAttachment {
            print("\(logPrefix) Visibility: \(visible ? "visible" : "hidden")")
        }

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
                if let url = attachment.getUrl(effectiveBaseUrl) {
                    let mediaID = SharedAssetCache.shared.extractMediaID(from: url) ?? attachment.mid
                    SharedAssetCache.shared.markAsVisible(mediaID)
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
                print("\(logPrefix) 🔄 Became visible with failed video - auto-retrying")
                videoRetryCount = 0
                retryButton.isHidden = true
                if let url = attachment.getUrl(effectiveBaseUrl), let parentTweet = parentTweet {
                    transitionTo(imageView.image != nil ? .thumbnail : .noContent)
                    acquirePlayer(attachment: attachment, url: url, parentTweet: parentTweet)
                }
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
                if isVideoAttachment {
                    print("\(logPrefix) Skipping aggressive cleanup — overlay is covering")
                }
                // Revert the isVisible flag — the cell is logically still visible
                isVisible = true
                return
            }

            // Cancel image loads
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

            // Cancel in-flight player acquisition task and pending retry
            setupPlayerTask?.cancel()
            setupPlayerTask = nil
            videoRetryTask?.cancel()
            videoRetryTask = nil

            // Video-specific invisible handling
            if isVideoAttachment {
                if let url = attachment.getUrl(effectiveBaseUrl) {
                    let mediaID = SharedAssetCache.shared.extractMediaID(from: url) ?? attachment.mid
                    SharedAssetCache.shared.markAsNotVisible(mediaID)
                    VideoStateCache.shared.markAsNotVisible(attachment.mid)
                    SharedAssetCache.shared.cancelLoadingForOutOfSightTweet(parentTweet?.mid ?? "")
                }

                // Capture frame, save position, pause, stop buffering
                if let player = player {
                    captureLastFrameIfPossible(reason: "becameInvisible")
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
                    self.cleanupVideoPlayer()
                    self.isPlayerLoaded = false
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
              let thumbnail = VideoLastFrameCache.shared.image(for: mid) else { return }
        imageView.image = thumbnail
        // Detach player from layer so isReadyForDisplay resets to false.
        // This ensures the thumbnail stays as cover until the layer actually
        // renders a frame after foreground return.
        videoPlayerView.setPlayer(nil)
        transitionTo(.thumbnail)
    }

    /// Re-attach player and seek to force AVPlayerLayer to render after foreground.
    /// Called from didBecomeActive when GPU is guaranteed ready.
    /// Skips currently playing videos to avoid disrupting playback.
    func refreshVideoLayerAfterForeground() {
        guard isVideoAttachment, let player = player, player.rate == 0 else { return }
        // Only refresh if videoPlayerView was previously rendering content
        guard videoCellState == .playerReady || videoCellState == .paused else { return }

        print("\(logPrefix) 🔄 Foreground recovery - refreshing player layer")

        // Temporarily show cached thumbnail while AVPlayerLayer re-initializes.
        // This prevents a black flash if the layer takes time to resume rendering.
        if let mid = attachment?.mid,
           let cachedFrame = VideoLastFrameCache.shared.image(for: mid) {
            imageView.image = cachedFrame
        }
        transitionTo(.playerLoading)

        // Transition to playerReady when the layer renders its first frame
        videoPlayerView.onReadyForDisplay = { [weak self] in
            guard let self else { return }
            if self.videoCellState == .playerLoading {
                self.transitionTo(.playerReady)
            }
        }

        // Re-attach player to force layer re-initialization
        videoPlayerView.setPlayer(nil)
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

    private func cleanupVideoPlayer() {
        // Capture last frame synchronously before tearing down the player,
        // so re-rendered cells show the cached thumbnail instead of a black screen.
        if isVideoAttachment,
           let player = player,
           let output = videoOutput,
           let item = player.currentItem,
           item.status == .readyToPlay,
           let mid = attachment?.mid {
            let playerTime = player.currentTime()
            let hostItemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            var pixelBuffer: CVPixelBuffer?
            var displayTime = CMTime.zero
            for d in [0.0, -0.08, -0.20, -0.40] {
                let t = CMTime(seconds: max(0, playerTime.seconds + d), preferredTimescale: 600)
                if t.isValid, let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &displayTime) {
                    pixelBuffer = pb
                    break
                }
            }
            if pixelBuffer == nil, hostItemTime.isValid {
                pixelBuffer = output.copyPixelBuffer(forItemTime: hostItemTime, itemTimeForDisplay: &displayTime)
            }
            if let pixelBuffer {
                Task.detached(priority: .utility) {
                    let width = CVPixelBufferGetWidth(pixelBuffer)
                    let height = CVPixelBufferGetHeight(pixelBuffer)
                    guard width > 0, height > 0, width < 10000, height < 10000 else { return }
                    guard let image = VideoFrameExtractor.makeDownscaledUIImage(from: pixelBuffer, maxDimension: 720) else { return }
                    if VideoFrameExtractor.isMostlyBlack(image) { return }
                    await MainActor.run {
                        VideoLastFrameCache.shared.set(image, for: mid)
                    }
                }
            }
        }

        if isVideoAttachment {
            print("\(logPrefix) 🧹 Cleanup video player")
        }

        // Cancel async tasks
        setupPlayerTask?.cancel()
        setupPlayerTask = nil

        // Clear first-frame callback
        videoPlayerView.onReadyForDisplay = nil

        // Remove observers
        removePlayerObservers()

        if let o = stopAllObserver { NotificationCenter.default.removeObserver(o) }
        stopAllObserver = nil
        if let o = playerLoanedObserver { NotificationCenter.default.removeObserver(o) }
        playerLoanedObserver = nil
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

        // Remove periodic time observer before releasing player
        removePlayerTimeObserver()

        // Detach player from view
        videoPlayerView.setPlayer(nil)
        videoPlayerView.isHidden = true
        videoPlayerView.gestureRecognizers?.forEach { videoPlayerView.removeGestureRecognizer($0) }
        imageView.gestureRecognizers?.forEach { imageView.removeGestureRecognizer($0) }
        player = nil

        // Reset state
        coordinatorWantsToPlay = false
        isPlayerLoaded = false
        isHandlingFinishEvent = false
        playerWasLoaned = false
        videoCellState = .noContent
        lastFrameCaptureAt = .distantPast
        videoRetryCount = 0
        videoRetryTask?.cancel()
        videoRetryTask = nil
        bufferingTimeoutTask?.cancel()
        bufferingTimeoutTask = nil
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

        // Reset UI
        imageView.image = nil
        imageView.isHidden = true
        imageView.gestureRecognizers?.forEach { imageView.removeGestureRecognizer($0) }
        loadingSpinner.stopAnimating()
        retryButton.isHidden = true
        muteButton.isHidden = true
        timerLabel.isHidden = true
        fullscreenOverlay.isHidden = true
        fullscreenSpinner.stopAnimating()

        cleanupVideoPlayer()
        removeAudioHosting()

        // Reset state
        videoCellState = .noContent
        attachment = nil
        parentTweet = nil
        isVisible = false
        isShowingFullscreen = false
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
        resumeObserver?.invalidate()
        timeControlStatusObserver?.invalidate()
        removePlayerTimeObserver()
        timerHideTask?.cancel()
        setupPlayerTask?.cancel()
    }
}
