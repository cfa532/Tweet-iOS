//
//  MediaCellUIView.swift
//  Tweet
//
//  Pure UIKit media cell replacing SwiftUI MediaCell in the feed.
//  Handles image, video, and audio attachments.
//  Video uses SimpleVideoPlayer hosted in a small UIHostingController with explicit frame.
//  A VideoStateBridge (ObservableObject) passes reactive state from UIKit to SwiftUI.
//
import UIKit
import SwiftUI
import Combine
import AVFoundation

// MARK: - Video State Bridge (UIKit → SwiftUI)

/// Bridges reactive state from UIKit MediaCellUIView to SwiftUI SimpleVideoPlayer.
/// SimpleVideoPlayer reads these as plain values but uses `.onChange(of:)` internally,
/// which fires when this ObservableObject's published properties cause the parent
/// VideoPlayerWrapper to re-render with new values.
class VideoStateBridge: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var shouldAutoPlay: Bool = false
    @Published var shouldLoadVideo: Bool = true
    @Published var isMuted: Bool = true
}

/// Thin SwiftUI wrapper that observes VideoStateBridge and forwards changing values
/// to SimpleVideoPlayer, ensuring `.onChange(of:)` fires when UIKit updates state.
struct VideoPlayerWrapper: View {
    @ObservedObject var state: VideoStateBridge
    let url: URL
    let mid: String
    let parentTweetId: String
    let mediaType: MediaType
    let authorId: String?
    let cellAspectRatio: CGFloat
    let videoAspectRatio: CGFloat
    let isEmbedded: Bool
    let onVideoTap: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black
            SimpleVideoPlayer(
                url: url,
                mid: mid,
                parentTweetId: parentTweetId,
                isVisible: state.isVisible,
                mediaType: mediaType,
                authorId: authorId,
                autoPlay: state.shouldAutoPlay,
                onVideoFinished: nil,
                cellAspectRatio: cellAspectRatio,
                videoAspectRatio: videoAspectRatio,
                showNativeControls: false,
                isMuted: state.isMuted,
                onVideoTap: onVideoTap,
                disableAutoRestart: true,
                shouldLoadVideo: state.shouldLoadVideo,
                mode: isEmbedded ? .embeddedDetail : .mediaCell
            )
        }
    }
}

// MARK: - MediaCellUIView

class MediaCellUIView: UIView, MediaCellDelegate {

    // MARK: - Subviews

    private let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 8
        iv.backgroundColor = .systemGray6
        return iv
    }()

    private let loadingSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        return spinner
    }()

    /// Mute button (only for single-video tweets)
    private lazy var muteButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.tintColor = .white.withAlphaComponent(0.6)
        btn.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        btn.layer.cornerRadius = 13
        btn.clipsToBounds = true
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
        v.layer.cornerRadius = 8
        v.clipsToBounds = true
        v.isHidden = true
        return v
    }()

    // Video hosting controller (hosts VideoPlayerWrapper)
    private var videoHostingController: UIHostingController<AnyView>?
    private var videoStateBridge: VideoStateBridge?
    // Audio hosting controller (hosts SimpleAudioPlayer)
    private var audioHostingController: UIHostingController<AnyView>?

    // MARK: - State

    private var attachment: MimeiFileType?
    private weak var parentTweet: Tweet?
    private var attachmentIndex: Int = 0
    private var aspectRatio: Float = 1.0
    private var isEmbedded: Bool = false
    private var cellTweetId: String?
    private var shouldLoadVideo: Bool = true
    private var shouldAutoPlay: Bool = false
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
        layer.cornerRadius = 8

        addSubview(imageView)
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
        loadingSpinner.center = CGPoint(x: b.midX, y: b.midY)
        fullscreenOverlay.frame = b
        fullscreenSpinner.center = CGPoint(x: b.midX, y: b.midY)

        // Mute button: bottom-right, 12pt padding
        let muteSize: CGFloat = 26
        muteButton.frame = CGRect(
            x: b.maxX - muteSize - 12,
            y: b.maxY - muteSize - 12,
            width: muteSize, height: muteSize
        )

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

        // Video hosting controller fills bounds
        videoHostingController?.view.frame = b
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
        // after the placeholder 1.0; without this guard, removeVideoHosting() + setupVideoCell()
        // destroys and recreates the UIHostingController, causing a visible black flash.
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

        // Tap gesture
        if !isEmbedded {
            let tap = UITapGestureRecognizer(target: self, action: #selector(imageTapped))
            imageView.addGestureRecognizer(tap)
            imageView.isUserInteractionEnabled = true
        }

        loadImage(attachment: attachment, url: url)
    }

    private func loadImage(attachment: MimeiFileType, url: URL) {
        // 1. Memory cache (synchronous)
        if let cached = imageCache.getCompressedImageFromMemory(for: attachment) {
            imageView.image = cached
            return
        }

        // 2. Disk cache (background) → network
        loadingSpinner.startAnimating()
        let attachmentCopy = attachment
        let baseUrlCopy = effectiveBaseUrl

        imageLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let cachedImage = self.imageCache.getCompressedImage(for: attachmentCopy)

            await MainActor.run {
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
                        self?.imageView.image = loadedImage
                        self?.loadingSpinner.stopAnimating()
                    }
                }
            }
        }
    }

    // MARK: - Video

    private func setupVideoCell(attachment: MimeiFileType, url: URL, parentTweet: Tweet) {
        // Show cached last frame as instant placeholder (pure UIKit, no SwiftUI render delay)
        if let cachedFrame = VideoLastFrameCache.shared.image(for: attachment.mid) {
            imageView.image = cachedFrame
            imageView.isHidden = false
        } else {
            imageView.isHidden = true
        }
        removeVideoHosting()

        // Create reactive state bridge
        let bridge = VideoStateBridge()
        bridge.isVisible = isVisible
        bridge.shouldAutoPlay = false
        bridge.shouldLoadVideo = shouldLoadVideo
        bridge.isMuted = MuteState.shared.isMuted
        self.videoStateBridge = bridge

        // Observe MuteState changes and forward to bridge
        MuteState.shared.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak bridge] muted in
                bridge?.isMuted = muted
            }
            .store(in: &cancellables)

        let wrapper = VideoPlayerWrapper(
            state: bridge,
            url: url,
            mid: attachment.mid,
            parentTweetId: parentTweet.mid,
            mediaType: attachment.type,
            authorId: parentTweet.authorId,
            cellAspectRatio: CGFloat(aspectRatio),
            videoAspectRatio: CGFloat(attachment.aspectRatio ?? 1.0),
            isEmbedded: isEmbedded,
            onVideoTap: isEmbedded ? nil : { [weak self] in
                self?.handleVideoTap()
            }
        )

        let hostingController = UIHostingController(rootView: AnyView(wrapper))
        hostingController.view.backgroundColor = .black
        hostingController.view.insetsLayoutMarginsFromSafeArea = false
        hostingController.view.layer.cornerRadius = 8
        hostingController.view.clipsToBounds = true
        // Explicit frame — no sizingOptions (prevents async sizing mismatch)
        hostingController.view.frame = bounds

        parentViewController?.addChild(hostingController)
        // Insert above imageView (placeholder) but below overlays (mute, timer, fullscreen)
        insertSubview(hostingController.view, aboveSubview: imageView)
        hostingController.didMove(toParent: parentViewController)

        videoHostingController = hostingController

        // Mute button and timer for single video
        if isSingleMedia {
            setupMuteButton()
            setupVideoTimer(videoMid: attachment.mid)
        }
    }

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
        let config = UIImage.SymbolConfiguration(pointSize: 16)
        muteButton.setImage(UIImage(systemName: iconName, withConfiguration: config), for: .normal)
    }

    @objc private func muteTapped() {
        MuteState.shared.toggleMute()
    }

    private func setupVideoTimer(videoMid: String) {
        timerLabel.isHidden = false
        timerLabel.text = "0:00"
        bringSubviewToFront(timerLabel)

        // Listen for timer updates
        NotificationCenter.default.publisher(for: .videoTimerUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let mid = notification.userInfo?["videoMid"] as? String,
                      mid == videoMid,
                      let time = notification.userInfo?["timeRemaining"] as? String else { return }
                self?.timerLabel.text = time
                self?.setNeedsLayout()
            }
            .store(in: &cancellables)

        // Request timer update
        NotificationCenter.default.post(
            name: .requestVideoTimerUpdate,
            object: nil,
            userInfo: ["videoMid": videoMid]
        )

        // Auto-hide timer after 5 seconds
        scheduleTimerHide()
    }

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

        if let cachedState = VideoStateCache.shared.getCachedState(for: attachment.mid) {
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
        isVisible = visible
        // Forward to video state bridge — deferred to avoid SwiftUI re-render conflicts
        // during UIKit layout passes (willDisplay/didEndDisplaying).
        DispatchQueue.main.async { [weak self] in
            self?.videoStateBridge?.isVisible = visible
        }

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

            // Setup foreground observer for images
            if attachment.type == .image {
                setupForegroundObserver()
            }
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

            // Mark video as not visible
            if isVideoAttachment {
                if let url = attachment.getUrl(effectiveBaseUrl) {
                    let mediaID = SharedAssetCache.shared.extractMediaID(from: url) ?? attachment.mid
                    SharedAssetCache.shared.markAsNotVisible(mediaID)
                    VideoStateCache.shared.markAsNotVisible(attachment.mid)
                    SharedAssetCache.shared.cancelLoadingForOutOfSightTweet(parentTweet?.mid ?? "")
                }
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
            guard let self, self.isVisible,
                  self.imageView.image == nil,
                  let att = self.attachment, att.type == .image,
                  let url = att.getUrl(self.effectiveBaseUrl) else { return }
            self.loadImage(attachment: att, url: url)
        }
    }

    // MARK: - MediaCellDelegate

    func shouldPlayVideo(withMid mid: String) {
        guard mid == attachment?.mid else { return }
        guard !shouldAutoPlay else { return }
        shouldAutoPlay = true
        videoStateBridge?.shouldAutoPlay = true
    }

    func shouldPauseVideo(withMid mid: String) {
        guard mid == attachment?.mid else { return }
        guard shouldAutoPlay else { return }
        shouldAutoPlay = false
        videoStateBridge?.shouldAutoPlay = false
    }

    func shouldStopVideo(withMid mid: String) {
        guard mid == attachment?.mid else { return }
        guard shouldAutoPlay else { return }
        shouldAutoPlay = false
        videoStateBridge?.shouldAutoPlay = false
    }

    func shouldStopAllVideos() {
        guard isVideoAttachment else { return }
        shouldAutoPlay = false
        videoStateBridge?.shouldAutoPlay = false
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

    private func removeVideoHosting() {
        if let hc = videoHostingController {
            hc.willMove(toParent: nil)
            hc.view.removeFromSuperview()
            hc.removeFromParent()
            videoHostingController = nil
        }
        videoStateBridge = nil
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

        removeVideoHosting()
        removeAudioHosting()

        // Reset state
        attachment = nil
        parentTweet = nil
        shouldAutoPlay = false
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
