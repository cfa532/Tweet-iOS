import SwiftUI
import AVKit
import Combine

/// One surface and PiP controller per browser. Keeping the layer alive across
/// page/item changes lets autoplay continue without replacing the PiP session.
@MainActor
final class BrowserVideoSession: NSObject, ObservableObject, @preconcurrency AVPictureInPictureControllerDelegate {
    let surface = BrowserVideoSurface()
    @Published private(set) var isReady = false
    @Published private(set) var canStartPictureInPicture = false
    @Published private(set) var isPictureInPictureActive = false
    @Published var pictureInPictureError: String?
    private var pictureInPicture: AVPictureInPictureController?
    private var readyObserver: NSKeyValueObservation?
    private var possibleObserver: NSKeyValueObservation?
    private var externalPlaybackObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?
    private weak var player: AVPlayer?
    private var item: AVPlayerItem?
    private var mid: String?

    override init() {
        super.init()
        if AVPictureInPictureController.isPictureInPictureSupported() {
            pictureInPicture = AVPictureInPictureController(playerLayer: surface.playerLayer)
            pictureInPicture?.delegate = self
            // Explicit activation avoids racing the app's normal background cleanup.
            pictureInPicture?.canStartPictureInPictureAutomaticallyFromInline = false
            possibleObserver = pictureInPicture?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, change in
                let possible = change.newValue ?? false
                Task { @MainActor [weak self] in self?.canStartPictureInPicture = possible }
            }
        }
        readyObserver = surface.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshReadyState() }
        }
    }

    func attach(player: AVPlayer, mid: String) {
        guard self.player !== player || item !== player.currentItem || self.mid != mid else { return }
        if self.player !== player {
            // PiP can advance while SwiftUI is suspended. The existing layer follows
            // the player's new item, so authorize it without waiting for a page render.
            itemObserver = player.observe(\.currentItem, options: [.new]) { [weak self, weak player] _, _ in
                Task { @MainActor [weak self, weak player] in
                    guard let self, let player, self.player === player,
                          let mid = FullScreenVideoManager.shared.currentVideoMid else { return }
                    self.attach(player: player, mid: mid)
                }
            }
        }
        self.player = player
        item = player.currentItem
        self.mid = mid
        pictureInPicture?.delegate = self
        surface.playerLayer.player = player
        externalPlaybackObserver = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self, weak player] _, change in
            guard change.newValue == false else { return }
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                FullScreenVideoManager.shared.externalPlaybackDidEnd()
            }
        }
        // Mounting authorizes startup; first-frame readiness separately removes the poster.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === player, self.mid == mid else { return }
            FullScreenVideoManager.shared.markPlaybackSurfaceReady(player: player, mid: mid)
            self.refreshReadyState()
        }
    }

    private func refreshReadyState() {
        isReady = surface.playerLayer.isReadyForDisplay
    }

    func isReady(for player: AVPlayer, mid: String) -> Bool {
        self.player === player && self.mid == mid && item === player.currentItem && isReady
    }

    func togglePictureInPicture() {
        guard let pictureInPicture else { return }
        if pictureInPicture.isPictureInPictureActive {
            pictureInPicture.stopPictureInPicture()
        } else if pictureInPicture.isPictureInPicturePossible {
            AudioSessionManager.shared.activateForVideoPlayback()
            FullScreenVideoManager.shared.isPictureInPictureActive = true
            pictureInPicture.startPictureInPicture()
        }
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        FullScreenVideoManager.shared.isPictureInPictureActive = true
        isPictureInPictureActive = true
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        pictureInPictureError = error.localizedDescription
        endPictureInPicture()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        endPictureInPicture()
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // The fullscreen browser stays presented beneath PiP, ready for restoration.
        completionHandler(surface.window != nil)
    }

    private func endPictureInPicture() {
        isPictureInPictureActive = false
        FullScreenVideoManager.shared.isPictureInPictureActive = false
        FullScreenVideoManager.shared.externalPlaybackDidEnd()
    }

    func close() {
        pictureInPicture?.stopPictureInPicture()
        pictureInPicture?.delegate = nil
        surface.playerLayer.player = nil
        externalPlaybackObserver = nil
        itemObserver = nil
        item = nil
        player = nil
        mid = nil
        isReady = false
        endPictureInPicture()
    }
}

final class BrowserVideoSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// UIScrollView supplies continuous, anchored pinch zoom and inertial panning.
/// Only the video layer moves; SwiftUI playback controls remain outside this view.
final class BrowserVideoScrollView: UIScrollView, UIScrollViewDelegate {
    private let surface: BrowserVideoSurface
    private var fitted = CGSize.zero
    private var presentationSize = CGSize.zero
    private var presentationObserver: NSKeyValueObservation?
    private var item: AVPlayerItem?
    var onNavigationLockChange: (Bool) -> Void = { _ in }
    var onTap: () -> Void = {}
    private(set) var locksNavigation = false

    init(surface: BrowserVideoSurface) {
        self.surface = surface
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(revealControls))
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func attach(item: AVPlayerItem) {
        if surface.superview !== self {
            surface.removeFromSuperview()
            surface.transform = .identity
            addSubview(surface)
            fitted = .zero
            DispatchQueue.main.async { [weak self] in
                guard let self, self.surface.superview === self else { return }
                self.onNavigationLockChange(self.locksNavigation)
            }
        }
        guard self.item !== item else { return }
        self.item = item
        presentationSize = item.presentationSize
        presentationObserver = item.observe(\.presentationSize, options: [.new]) { [weak self] _, change in
            let size = change.newValue ?? .zero
            Task { @MainActor [weak self] in
                self?.presentationSize = size
                self?.setNeedsLayout()
            }
        }
        setNeedsLayout()
    }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === panGestureRecognizer && zoomScale <= minimumZoomScale + 0.001 { return false }
        return super.gestureRecognizerShouldBegin(recognizer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard surface.superview === self, presentationSize.width > 0, presentationSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / presentationSize.width, bounds.height / presentationSize.height)
        let target = CGSize(width: presentationSize.width * scale, height: presentationSize.height * scale)
        if abs(target.width - fitted.width) > 0.5 || abs(target.height - fitted.height) > 0.5 {
            zoomScale = 1
            fitted = target
            surface.frame = CGRect(origin: .zero, size: target)
            contentSize = target
            updateNavigationLock()
        }
        centerContent()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { surface.superview === self ? surface : nil }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { setNavigationLock(true) }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent(); updateNavigationLock() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { updateNavigationLock() }

    private func centerContent() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    private func updateNavigationLock() {
        setNavigationLock(isZooming || zoomScale > minimumZoomScale + 0.001)
    }

    private func setNavigationLock(_ locked: Bool) {
        guard locksNavigation != locked else { return }
        locksNavigation = locked
        // Layout can reset zoom. Don't publish SwiftUI state inside that update.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.surface.superview === self else { return }
            self.onNavigationLockChange(self.locksNavigation)
        }
    }

    @objc private func revealControls() { onTap() }
    @objc private func toggleZoom(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = recognizer.location(in: surface)
            let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}

private struct BrowserVideoCanvas: UIViewRepresentable {
    let session: BrowserVideoSession
    let player: AVPlayer
    let mid: String
    let onNavigationLockChange: (Bool) -> Void
    let onTap: () -> Void

    func makeUIView(context: Context) -> BrowserVideoScrollView { BrowserVideoScrollView(surface: session.surface) }
    func updateUIView(_ view: BrowserVideoScrollView, context: Context) {
        view.onNavigationLockChange = onNavigationLockChange
        view.onTap = onTap
        if let item = player.currentItem { view.attach(item: item) }
        session.attach(player: player, mid: mid)
    }
}

private struct BrowserAirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        view.prioritizesVideoDevices = true
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

struct BrowserVideoPlayer: View {
    let player: AVPlayer
    let mid: String
    @ObservedObject var session: BrowserVideoSession
    let showControls: Bool
    let onNavigationLockChange: (Bool) -> Void
    let onUserInteraction: () -> Void
    @ObservedObject private var manager = FullScreenVideoManager.shared
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isSeeking = false
    @State private var resumeAfterSeeking = false
    private let clock = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            BrowserVideoCanvas(session: session, player: player, mid: mid,
                               onNavigationLockChange: onNavigationLockChange, onTap: onUserInteraction)
            if showControls || isSeeking {
                VStack {
                    Spacer()
                    VStack(spacing: 4) {
                        HStack(spacing: 12) {
                            Button {
                                if manager.isPlaying { manager.pause() } else { manager.play() }
                                onUserInteraction()
                            } label: { Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }
                                .accessibilityLabel(manager.isPlaying ? "Pause video" : "Play video")
                            Button {
                                manager.isUserMuted.toggle()
                                onUserInteraction()
                            } label: { Image(systemName: manager.isUserMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 44, height: 44) }
                                .accessibilityLabel(manager.isUserMuted ? "Unmute video" : "Mute video")
                            Spacer()
                            BrowserAirPlayButton().frame(width: 44, height: 44)
                                .accessibilityLabel("AirPlay")
                            if AVPictureInPictureController.isPictureInPictureSupported() {
                                Button { session.togglePictureInPicture(); onUserInteraction() } label: {
                                    Image(systemName: session.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                                        .frame(width: 44, height: 44)
                                }
                                .disabled(!session.canStartPictureInPicture && !session.isPictureInPictureActive)
                                .accessibilityLabel("Picture in Picture")
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(height: 44)
                        HStack(spacing: 8) {
                            Text(formatted(currentTime)).monospacedDigit()
                            Slider(value: $currentTime, in: 0...max(duration, 1), onEditingChanged: seekChanged)
                                .disabled(duration <= 0)
                                .accessibilityLabel("Video position")
                            Text(formatted(duration)).monospacedDigit()
                        }
                        .font(.caption)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 38) // Leave the browser's page indicator reachable.
                    .background(.black.opacity(0.65))
                }
                .foregroundStyle(.white)
                .tint(.white)
            }
        }
        .onAppear { refreshTime() }
        .onReceive(clock) { _ in refreshTime() }
        .alert("Picture in Picture unavailable", isPresented: Binding(
            get: { session.pictureInPictureError != nil },
            set: { if !$0 { session.pictureInPictureError = nil } }
        )) { Button("OK", role: .cancel) { session.pictureInPictureError = nil } }
        message: { Text(session.pictureInPictureError ?? "") }
    }

    private func refreshTime() {
        guard !isSeeking else { return }
        let time = player.currentTime().seconds
        if time.isFinite { currentTime = max(0, time) }
        let length = player.currentItem?.duration.seconds ?? 0
        duration = length.isFinite ? max(0, length) : 0
    }

    private func seekChanged(_ editing: Bool) {
        onUserInteraction()
        if editing {
            isSeeking = true
            resumeAfterSeeking = manager.isPlaying
            manager.pause()
        } else {
            let resume = resumeAfterSeeking
            player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                Task { @MainActor in
                    isSeeking = false
                    if finished, resume, manager.singletonPlayer === player, manager.currentVideoMid == mid { manager.play() }
                }
            }
            resumeAfterSeeking = false
        }
    }

    private func formatted(_ time: Double) -> String {
        let seconds = Int(max(0, time))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
