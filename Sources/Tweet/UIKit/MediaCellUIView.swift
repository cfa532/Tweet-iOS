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
    private var shouldPlayObserver: NSObjectProtocol?
    private var shouldPauseObserver: NSObjectProtocol?
    private var shouldStopObserver: NSObjectProtocol?

    /// Async player acquisition / wait tasks
    private var setupPlayerTask: Task<Void, Never>?
    private var waitingForPlayerTask: Task<Void, Never>?
    private var isWaitingForPlayerReady: Bool = false

    /// Periodic time observer token for the video timer label
    private var timeObserverToken: Any?

    /// Frame capture throttle
    private var lastFrameCaptureAt: Date = .distantPast

    /// Whether the player item is loaded and ready to play
    private var isPlayerLoaded: Bool = false

    /// Prevent duplicate finish handling
    private var isHandlingFinishEvent: Bool = false

    /// Track if we've already hidden the spinner (prevent hiding it multiple times)
    private var hasHiddenLoadingSpinner: Bool = false

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
    private var videoIdentifier: String? {
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

        addSubview(imageView)
        addSubview(videoPlayerView)
        addSubview(loadingSpinner)
        addSubview(fullscreenOverlay)
        fullscreenOverlay.addSubview(fullscreenSpinner)
        addSubview(muteButton)
        addSubview(timerLabel)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        imageView.frame = b
        videoPlayerView.frame = b
        loadingSpinner.center = CGPoint(x: b.midX, y: b.midY)
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
        bringSubviewToFront(loadingSpinner)
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
                        } else {
                            // Image failed/cancelled - stop spinner but keep trying on next appearance
                            self?.loadingSpinner.stopAnimating()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Video

    private func setupVideoCell(attachment: MimeiFileType, url: URL, parentTweet: Tweet) {
        // Show cached last frame as instant placeholder (pure UIKit, no render delay)
        if let cachedFrame = VideoLastFrameCache.shared.image(for: attachment.mid) {
            imageView.image = cachedFrame
            imageView.isHidden = false
        } else {
            imageView.isHidden = true
        }

        // Reset any previous video state
        cleanupVideoPlayer()

        // Show the player view container (black background until player delivers frames)
        videoPlayerView.isHidden = false

        // Tap gesture for fullscreen (all media — including embedded tweets — opens fullscreen)
        let tap = UITapGestureRecognizer(target: self, action: #selector(videoTapped))
        videoPlayerView.addGestureRecognizer(tap)
        videoPlayerView.isUserInteractionEnabled = true

        // Listen for .stopAllVideos (posted by non-coordinator code like handleVideoTap)
        stopAllObserver = NotificationCenter.default.addObserver(
            forName: .stopAllVideos, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleStopAllVideos()
        }

        // Coordinator commands arrive via MediaCellDelegate methods (shouldPlayVideo/shouldPauseVideo/shouldStopVideo)
        // — no notification observers needed. This prevents cross-feed interference.

        // Observe MuteState changes → forward to player
        MuteState.shared.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] muted in
                self?.player?.isMuted = muted
            }
            .store(in: &cancellables)

        // Show spinner while player is loading (white for visibility on dark video background)
        hasHiddenLoadingSpinner = false
        loadingSpinner.color = .white.withAlphaComponent(0.7)
        loadingSpinner.startAnimating()
        bringSubviewToFront(loadingSpinner)

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
                SharedAssetCache.shared.removeInvalidPlayer(for: mid, force: true)
                VideoStateCache.shared.clearCachedState(for: mid)
                acquirePlayerAsync(attachment: attachment, url: url, parentTweet: parentTweet)
                return
            }

            // Reset finished videos to beginning
            if isVideoAtEnd(cachedPlayer) {
                VideoStateCache.shared.clearCachedState(for: mid)
                cachedPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            }

            // Pause if playing (prevent audio bleed in feed)
            if cachedPlayer.rate > 0 { cachedPlayer.pause() }

            configurePlayer(cachedPlayer)
            return
        }

        // TIER 2: Async loading
        acquirePlayerAsync(attachment: attachment, url: url, parentTweet: parentTweet)
    }

    private func acquirePlayerAsync(attachment: MimeiFileType, url: URL, parentTweet: Tweet) {
        guard shouldLoadVideo else { return }
        isPlayerLoaded = false
        hasHiddenLoadingSpinner = false
        loadingSpinner.startAnimating()

        let uniqueURL = buildUniquePlayerURL(url: url, parentTweetId: parentTweet.mid)
        let tweetId = parentTweet.mid
        let mediaType = attachment.type

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
                    newPlayer.isMuted = MuteState.shared.isMuted
                    self.configurePlayer(newPlayer)
                    self.setupPlayerTask = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.loadingSpinner.stopAnimating()
                    self?.setupPlayerTask = nil
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
        // Configure automatic waiting based on type
        if attachment?.type == .video {
            newPlayer.automaticallyWaitsToMinimizeStalling = true
        } else {
            newPlayer.automaticallyWaitsToMinimizeStalling = false
        }

        // Pause if playing (prevent audio bleed in feed)
        if newPlayer.rate > 0 { newPlayer.pause() }

        // Apply mute state
        newPlayer.isMuted = MuteState.shared.isMuted

        // Clean up old observers before setting new player
        removePlayerObservers()

        // Assign to player view
        self.player = newPlayer

        // Set callback for when first frame is rendered — use as fallback to hide spinner
        // if player doesn't reach .playing state (e.g., due to buffering or coordinator timing)
        videoPlayerView.onReadyForDisplay = { [weak self] in
            guard let self else { return }
            // Only hide if player has sufficient buffer or is already playing
            if let player = self.player,
               let item = player.currentItem,
               item.status == .readyToPlay,
               (!item.loadedTimeRanges.isEmpty || player.timeControlStatus == .playing) {
                self.hideLoadingSpinner()
            }
        }

        // Disable implicit CALayer animations during player attachment to avoid main-thread hitch
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoPlayerView.setPlayer(newPlayer)
        CATransaction.commit()

        // Set up KVO + notification observers
        setupPlayerObservers(newPlayer)

        // Mark player as logically loaded if item is ready (for coordinator play commands)
        if let item = newPlayer.currentItem,
           item.status == .readyToPlay {
            isPlayerLoaded = true
        }

        // Defer video output attachment — AVPlayerItemVideoOutput creation causes
        // expensive AVFoundation pipeline reconfiguration that blocks the main thread
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === newPlayer else { return }
            self.ensureVideoOutputAttached(for: newPlayer)
        }
    }

    // MARK: - Coordinator Command Handlers

    private func handleCoordinatorPlayCommand() {
        guard let mid = attachment?.mid else { return }

        isHandlingFinishEvent = false
        VideoStateCache.shared.clearStoppedByCoordinator(mid)
        coordinatorWantsToPlay = true

        // If player not ready, wait for it
        guard let player = player, isPlayerLoaded else {
            // Trigger player setup if needed
            if player == nil, shouldLoadVideo, isVisible,
               let att = attachment, let url = att.getUrl(effectiveBaseUrl),
               let parentTweet = parentTweet {
                acquirePlayer(attachment: att, url: url, parentTweet: parentTweet)
            }

            // Wait for player to become ready (max 3s)
            guard !isWaitingForPlayerReady else { return }
            isWaitingForPlayerReady = true
            waitingForPlayerTask = Task { @MainActor [weak self] in
                defer {
                    self?.isWaitingForPlayerReady = false
                    self?.waitingForPlayerTask = nil
                }
                var attempts = 0
                while (self?.player == nil || self?.isPlayerLoaded != true) && attempts < 30 {
                    do {
                        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                    } catch { return }
                    attempts += 1
                }
                guard let self, self.coordinatorWantsToPlay else { return }
                if self.isPlayerLoaded, let player = self.player, player.currentItem != nil {
                    self.playWithVolumeFadeIn(player)
                }
            }
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
        coordinatorWantsToPlay = false
        waitingForPlayerTask?.cancel()
        waitingForPlayerTask = nil
        isWaitingForPlayerReady = false

        if let player = player {
            if player.rate > 0 {
                saveCurrentPosition(player: player, wasPlaying: true)
            }
            captureLastFrameIfPossible(reason: "coordinatorPause")
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
        coordinatorWantsToPlay = false
        waitingForPlayerTask?.cancel()
        waitingForPlayerTask = nil
        isWaitingForPlayerReady = false

        if let player = player {
            if player.rate > 0 {
                saveCurrentPosition(player: player, wasPlaying: true)
            }
            captureLastFrameIfPossible(reason: "coordinatorStop")
            player.pause()
        }
        VideoStateCache.shared.markAsStoppedByCoordinator(mid)
    }

    private func handleStopAllVideos() {
        guard isVideoAttachment else { return }
        coordinatorWantsToPlay = false
        waitingForPlayerTask?.cancel()
        waitingForPlayerTask = nil
        isWaitingForPlayerReady = false

        if let player = player {
            if player.rate > 0 {
                saveCurrentPosition(player: player, wasPlaying: true)
            }
            captureLastFrameIfPossible(reason: "stopAllVideos")
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
                    player.seek(to: info.time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        self?.startPlaybackWithFade(player)
                    }
                    return
                }
            }
        }

        startPlaybackWithFade(player)
    }

    private func startPlaybackWithFade(_ player: AVPlayer) {
        player.isMuted = MuteState.shared.isMuted
        player.volume = 0
        player.play()
        UIView.animate(withDuration: 0.3) {
            player.volume = 1.0
        }

        // Show timer when playback actually starts
        if isSingleMedia, let mid = attachment?.mid {
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
        playerItemStatusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if item.status == .readyToPlay {
                    // Mark as loaded when status is ready, even if no data buffered yet
                    // (player will buffer as needed when play() is called)
                    self.isPlayerLoaded = true
                } else if item.status == .failed {
                    self.hideLoadingSpinner()
                }
            }
        }

        // KVO: timeControlStatus — hide spinner when video actually starts playing
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                // Hide spinner when playback actually starts (most reliable indicator)
                if player.timeControlStatus == .playing {
                    self.hideLoadingSpinner()
                }
            }
        }
    }

    /// Hides the loading spinner (only once to prevent redundant calls)
    private func hideLoadingSpinner() {
        guard !hasHiddenLoadingSpinner else { return }
        hasHiddenLoadingSpinner = true
        loadingSpinner.stopAnimating()
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
        defer { isHandlingFinishEvent = false }

        guard let player = player, let item = player.currentItem,
              let mid = attachment?.mid else { return }

        let duration = item.duration
        guard duration.isValid, duration.seconds > 0 else { return }

        let timeUntilEnd = duration.seconds - player.currentTime().seconds
        guard timeUntilEnd < 0.5 else { return }

        // Pause immediately
        player.pause()
        player.isMuted = MuteState.shared.isMuted
        VideoStateCache.shared.clearCachedState(for: mid)
        captureLastFrameIfPossible(reason: "videoFinished")

        // Notify coordinator to advance to next video
        NotificationCenter.default.post(
            name: .videoDidFinishPlaying,
            object: nil,
            userInfo: ["videoMid": mid, "tweetId": parentTweet?.mid ?? ""]
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
        bringSubviewToFront(muteButton)

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
        bringSubviewToFront(timerLabel)

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

        // Show loading overlay
        fullscreenOverlay.isHidden = false
        fullscreenSpinner.startAnimating()

        // Post stop all to pause feed videos
        NotificationCenter.default.post(name: .stopAllVideos, object: nil)
        OverlayVisibilityCoordinator.shared.beginOverlay(
            id: "mediaBrowserFullScreen",
            source: "MediaCellUIView"
        )

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

            // Setup foreground observer for images and videos
            setupForegroundObserver()
        } else {
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

                    // Stop buffering to prevent background network usage
                    if let playerItem = player.currentItem {
                        playerItem.preferredForwardBufferDuration = 0.0
                    }
                }
                coordinatorWantsToPlay = false
            }
        }
    }

    private var isVideoAttachment: Bool {
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
                if let player = self.player, player.currentItem == nil {
                    self.cleanupVideoPlayer()
                    self.isPlayerLoaded = false
                    // Show cached last frame so the cell isn't black while a new player loads
                    if let cachedFrame = VideoLastFrameCache.shared.image(for: att.mid) {
                        self.imageView.image = cachedFrame
                        self.imageView.isHidden = false
                    }
                    // Re-acquire a fresh player and auto-play once ready
                    if let url = att.getUrl(self.effectiveBaseUrl), let parentTweet = self.parentTweet {
                        self.setupVideoCell(attachment: att, url: url, parentTweet: parentTweet)
                        self.handleCoordinatorPlayCommand()
                    }
                } else if let player = self.player {
                    // Player is still valid — just re-attach to force AVPlayerLayer to re-render
                    self.videoPlayerView.setPlayer(nil)
                    self.videoPlayerView.setPlayer(player)
                }
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

    private func cleanupVideoPlayer() {
        // Cancel async tasks
        setupPlayerTask?.cancel()
        setupPlayerTask = nil
        waitingForPlayerTask?.cancel()
        waitingForPlayerTask = nil
        isWaitingForPlayerReady = false

        // Clear first-frame callback
        videoPlayerView.onReadyForDisplay = nil

        // Remove observers
        removePlayerObservers()

        if let o = stopAllObserver { NotificationCenter.default.removeObserver(o) }
        stopAllObserver = nil
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
        player = nil

        // Reset state
        coordinatorWantsToPlay = false
        isPlayerLoaded = false
        isHandlingFinishEvent = false
        hasHiddenLoadingSpinner = false
        lastFrameCaptureAt = .distantPast
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
        muteButton.isHidden = true
        timerLabel.isHidden = true
        fullscreenOverlay.isHidden = true
        fullscreenSpinner.stopAnimating()

        cleanupVideoPlayer()
        removeAudioHosting()

        // Reset state
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
        waitingForPlayerTask?.cancel()
    }
}
