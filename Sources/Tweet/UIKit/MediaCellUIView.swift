//
//  MediaCellUIView.swift
//  Tweet
//
//  Pure UIKit media cell replacing SwiftUI MediaCell in the feed.
//  Handles image, video, and audio attachments.
//  Video uses LightweightVideoPlayerView (pure UIKit AVPlayerLayer) — no UIHostingController.
//  FeedVideoPlayerManager owns the shared AVPlayer; this cell just hosts an AVPlayerLayer.
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

    // MARK: - General State

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
    private var thumbnailTask: Task<Void, Never>?
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
        imageView.backgroundColor = .systemGray6
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
                    GlobalImageLoadManager.shared.loadImageNormalPriority(
                        id: attachmentCopy.mid,
                        url: url,
                        attachment: attachmentCopy,
                        baseUrl: baseUrlCopy
                    ) { [weak self] loadedImage in
                        // Guard: cell may have been reused while network load was in flight
                        guard self?.attachment?.mid == attachmentCopy.mid else { return }
                        self?.imageView.image = loadedImage
                        self?.loadingSpinner.stopAnimating()
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
            // No cached frame — show dark placeholder so spinner is visible,
            // then generate a thumbnail from the video's first frame
            imageView.image = nil
            imageView.backgroundColor = .black
            imageView.isHidden = false
            loadVideoThumbnail(attachment: attachment, url: url, parentTweet: parentTweet)
        }

        // Start spinner immediately so user sees loading feedback
        loadingSpinner.color = .white.withAlphaComponent(0.7)
        loadingSpinner.startAnimating()
        bringSubviewToFront(loadingSpinner)

        // Reset any previous video state
        cleanupVideoPlayer()

        // videoPlayerView stays hidden until FeedVideoPlayerManager attaches the shared player
        // (attachSharedPlayer sets isHidden = false)

        // Tap gesture on self so it works over the thumbnail placeholder
        let tap = UITapGestureRecognizer(target: self, action: #selector(videoTapped))
        self.addGestureRecognizer(tap)
        self.isUserInteractionEnabled = true

        // Mute button for single video (timer shown when playback starts)
        if isSingleMedia {
            setupMuteButton()
        }
    }

    /// Load a thumbnail from the video's first frame using AVAssetImageGenerator.
    /// Lightweight — only downloads enough of the video for one keyframe.
    private func loadVideoThumbnail(attachment: MimeiFileType, url: URL, parentTweet: Tweet) {
        let mid = attachment.mid
        let uniqueURL = buildUniquePlayerURL(url: url, parentTweetId: parentTweet.mid)
        let mediaType = attachment.type

        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            do {
                let asset = try await SharedAssetCache.shared.getAsset(
                    for: uniqueURL, tweetId: parentTweet.mid, mediaType: mediaType
                )
                try Task.checkCancellation()

                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 720, height: 720)

                let time = CMTime(seconds: 0.0, preferredTimescale: 600)
                let cgImage = try await generator.image(at: time).image
                try Task.checkCancellation()

                let image = UIImage(cgImage: cgImage)
                guard !VideoFrameExtractor.isMostlyBlack(image) else { return }

                await MainActor.run { [weak self] in
                    guard let self, self.attachment?.mid == mid else { return }
                    VideoLastFrameCache.shared.set(image, for: mid)
                    // Only show if shared player hasn't already attached to this cell
                    if FeedVideoPlayerManager.shared.activeCell !== self {
                        self.imageView.image = image
                        self.imageView.isHidden = false
                    }
                }
            } catch {
                // Cancelled or failed to generate — cell will show black until player attaches
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

    private func scheduleTimerHide() {
        timerHideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.timerLabel.isHidden = true
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

        // Save video position before fullscreen via shared player manager
        FeedVideoPlayerManager.shared.savePositionForFullscreen()

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

    // MARK: - Visibility

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible

        guard let attachment else { return }

        if visible {
            // Update base URL
            updateEffectiveBaseUrl()

            if attachment.type == .image && imageView.image == nil {
                if let url = attachment.getUrl(effectiveBaseUrl) {
                    loadImage(attachment: attachment, url: url)
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
                VideoPlaybackCoordinator.shared.registerDelegate(self, forIdentifier: id)
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
                VideoPlaybackCoordinator.shared.unregisterDelegate(forIdentifier: id)
            }

            // Video-specific invisible handling
            if isVideoAttachment {
                if let url = attachment.getUrl(effectiveBaseUrl) {
                    let mediaID = SharedAssetCache.shared.extractMediaID(from: url) ?? attachment.mid
                    SharedAssetCache.shared.markAsNotVisible(mediaID)
                    VideoStateCache.shared.markAsNotVisible(attachment.mid)
                    SharedAssetCache.shared.cancelLoadingForOutOfSightTweet(parentTweet?.mid ?? "")
                }

                // Detach shared player if this cell was the active one
                FeedVideoPlayerManager.shared.detachIfActiveCell(self)
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
            }
            // Video foreground recovery is handled by FeedVideoPlayerManager.recoverFromBackground()
        }
    }

    // MARK: - FeedVideoPlayerManager Interface

    /// Called by FeedVideoPlayerManager to attach the shared player to this cell's layer
    func attachSharedPlayer(_ player: AVPlayer) {
        videoPlayerView.isHidden = false
        videoPlayerView.onReadyForDisplay = { [weak self] in
            self?.loadingSpinner.stopAnimating()
            self?.imageView.isHidden = true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoPlayerView.setPlayer(player)
        CATransaction.commit()
    }

    /// Called by FeedVideoPlayerManager when moving the player away from this cell
    func detachSharedPlayer() {
        videoPlayerView.setPlayer(nil)
        videoPlayerView.isHidden = true
        videoPlayerView.onReadyForDisplay = nil
        if let mid = attachment?.mid,
           let frame = VideoLastFrameCache.shared.image(for: mid) {
            imageView.image = frame
            imageView.isHidden = false
        }
        timerLabel.isHidden = true
    }

    /// Returns video URL and metadata for FeedVideoPlayerManager to load a player item
    func videoLoadInfo() -> (url: URL, mid: String, mediaType: MediaType, tweetId: String)? {
        guard let att = attachment, isVideoAttachment,
              let url = att.getUrl(effectiveBaseUrl) else { return nil }
        let uniqueURL = buildUniquePlayerURL(url: url, parentTweetId: parentTweet?.mid ?? "")
        return (url: uniqueURL, mid: att.mid, mediaType: att.type, tweetId: parentTweet?.mid ?? "")
    }

    /// Show loading spinner for video
    func showVideoLoading() {
        loadingSpinner.color = .white.withAlphaComponent(0.7)
        loadingSpinner.startAnimating()
        bringSubviewToFront(loadingSpinner)
    }

    /// Hide loading spinner
    func hideVideoLoading() {
        loadingSpinner.stopAnimating()
    }

    /// Whether this cell displays a single media attachment (for timer display)
    var isSingleMediaCell: Bool { isSingleMedia }

    /// The parent tweet's mid (for coordinator notifications)
    var parentTweetMid: String? { parentTweet?.mid }

    /// Show the video timer label
    func showVideoTimer() {
        timerLabel.isHidden = false
        timerLabel.text = "0:00"
        bringSubviewToFront(timerLabel)
        scheduleTimerHide()
    }

    /// Update the timer label text
    func updateTimerText(_ text: String) {
        timerLabel.text = text
        setNeedsLayout()
    }

    // MARK: - MediaCellDelegate

    func shouldPlayVideo(withMid mid: String) {
        // Handled by FeedVideoPlayerManager via VideoPlaybackCoordinator
    }

    func shouldPauseVideo(withMid mid: String) {
        // Handled by FeedVideoPlayerManager via VideoPlaybackCoordinator
    }

    func shouldStopVideo(withMid mid: String) {
        // Handled by FeedVideoPlayerManager via VideoPlaybackCoordinator
    }

    func shouldStopAllVideos() {
        // Handled by FeedVideoPlayerManager via .stopAllVideos notification
    }

    func updateVideoTimer(withMid mid: String, timeRemaining: String) {
        // Handled by FeedVideoPlayerManager
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
        videoPlayerView.onReadyForDisplay = nil
        FeedVideoPlayerManager.shared.detachIfActiveCell(self)
        videoPlayerView.setPlayer(nil)
        videoPlayerView.isHidden = true
        // Remove video tap gesture from self (added in setupVideoCell)
        self.gestureRecognizers?.forEach { self.removeGestureRecognizer($0) }
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
        thumbnailTask?.cancel()
        thumbnailTask = nil
        timerHideTask?.cancel()
        timerHideTask = nil
        cancellables.removeAll()

        if let att = attachment {
            GlobalImageLoadManager.shared.cancelLoad(id: att.mid)
            if let id = videoIdentifier {
                VideoPlaybackCoordinator.shared.unregisterDelegate(forIdentifier: id)
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
        timerHideTask?.cancel()
    }
}
