import AVFoundation
import SwiftUI
import UIKit
import Vision

/// The QR reader behind every scan in the app.
///
/// It reads the camera at full 4K and runs Vision's barcode detector on every frame.
/// The detector is not the weak point: Vision reads a screen-drawn code down to about
/// three pixels per module, even with moire, tilt and noise. The weak point is how many
/// pixels the code gets. A terminal QR held at arm's length fills a quarter of the frame
/// or less, and a 1080p frame gives it only a few pixels per module. At 4K the same
/// code has about 14, which survives soft focus. VisionKit's DataScanner could not be
/// asked for that resolution, and gave up on exactly these codes.
struct CodeScanner: View {
    let isActive: Bool
    let onScan: (String) -> Void

    var body: some View {
        FrameScanner(isActive: isActive, onScan: onScan)
            .background(Color.black)
    }
}

private struct FrameScanner: UIViewControllerRepresentable {
    let isActive: Bool
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        // The callbacks read the screen's current state, so keep the latest one.
        controller.onScan = onScan
        controller.setRunning(isActive)
    }
}

/// AVCaptureSession is not Sendable and DispatchQueue's closures are. Every
/// touch of the scanner's session happens on sessionQueue, so this box states
/// that contract where the capture crosses the boundary.
private struct QueuedSession: @unchecked Sendable {
    let session: AVCaptureSession
}

private final class ScannerController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onScan: ((String) -> Void)?

    // The capture session is configured, started and stopped on sessionQueue only
    // (those calls block), so it is deliberately outside the main actor.
    nonisolated(unsafe) private let session = AVCaptureSession()
    nonisolated(unsafe) private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.tweet.scan.session")
    // Frames arrive, and Vision runs, here: never on the main queue.
    private let frameQueue = DispatchQueue(label: "com.tweet.scan.frames", qos: .userInitiated)
    private var camera: AVCaptureDevice?
    private var preview: AVCaptureVideoPreviewLayer?
    private let guide = CAShapeLayer()
    private let notice = UIStackView()
    private var wantsRunning = false
    private var configured = false
    private var zoomAtPinchStart: CGFloat = 1
    // Touched on frameQueue only.
    nonisolated(unsafe) private var delivered = false
    nonisolated(unsafe) private var lastAttempt: CFTimeInterval = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guide.strokeColor = UIColor.white.withAlphaComponent(0.7).cgColor
        guide.fillColor = UIColor.clear.cgColor
        guide.lineWidth = 3
        view.layer.addSublayer(guide)
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        buildNotice()
        authorize()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        let side = min(view.bounds.width, view.bounds.height) * 0.72
        guide.path = UIBezierPath(roundedRect: CGRect(x: view.bounds.midX - side / 2, y: view.bounds.midY - side / 2,
                                                      width: side, height: side), cornerRadius: 18).cgPath
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        apply()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let queued = QueuedSession(session: session)
        sessionQueue.async { if queued.session.isRunning { queued.session.stopRunning() } }
    }

    func setRunning(_ running: Bool) {
        wantsRunning = running
        if running { frameQueue.async { [weak self] in self?.delivered = false } }
        apply()
    }

    /// startRunning and stopRunning both block, so neither belongs on the main queue.
    private func apply() {
        let run = wantsRunning && configured && view.window != nil
        let queued = QueuedSession(session: session)
        sessionQueue.async {
            if run, !queued.session.isRunning { queued.session.startRunning() }
            if !run, queued.session.isRunning { queued.session.stopRunning() }
        }
    }

    // MARK: Camera access and setup

    private func authorize() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in granted ? self?.configure() : self?.showNotice(denied: true) }
            }
        default:
            showNotice(denied: true)
        }
    }

    private func configure() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                Task { @MainActor in self.showNotice(denied: false) }
                return
            }
            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(.hd4K3840x2160) {
                self.session.sessionPreset = .hd4K3840x2160
            } else if self.session.canSetSessionPreset(.hd1920x1080) {
                self.session.sessionPreset = .hd1920x1080
            }
            if self.session.canAddInput(input) { self.session.addInput(input) }
            self.output.alwaysDiscardsLateVideoFrames = true
            self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            self.output.setSampleBufferDelegate(self, queue: self.frameQueue)
            if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
            self.session.commitConfiguration()
            // A code held at reading distance is close; the default focus range hunts
            // across the whole span. Smooth autofocus is slow on purpose, which is wrong here.
            if (try? device.lockForConfiguration()) != nil {
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
                if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                device.unlockForConfiguration()
            }
            nonisolated(unsafe) let readyCamera = device
            Task { @MainActor in
                self.camera = readyCamera
                let layer = AVCaptureVideoPreviewLayer(session: self.session)
                layer.videoGravity = .resizeAspectFill
                layer.frame = self.view.bounds
                self.view.layer.insertSublayer(layer, at: 0)
                self.preview = layer
                self.configured = true
                self.apply()
            }
        }
    }

    // MARK: Frames

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !delivered, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Vision on a 4K frame takes real time; the frame queue is serial, so this also
        // keeps a slow frame from queueing a backlog.
        let now = CACurrentMediaTime()
        guard now - lastAttempt >= 0.1 else { return }
        lastAttempt = now
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        // The sensor is landscape; the phone is held upright.
        try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right).perform([request])
        guard let text = request.results?.compactMap({ $0.payloadStringValue }).first else { return }
        delivered = true
        Task { @MainActor [weak self] in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self?.onScan?(text)
        }
    }

    // MARK: Zoom and focus

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard let camera else { return }
        if gesture.state == .began { zoomAtPinchStart = camera.videoZoomFactor }
        let wanted = zoomAtPinchStart * gesture.scale
        let limit = min(camera.maxAvailableVideoZoomFactor, 6)
        guard (try? camera.lockForConfiguration()) != nil else { return }
        camera.videoZoomFactor = max(1, min(wanted, limit))
        camera.unlockForConfiguration()
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let camera, let preview, camera.isFocusPointOfInterestSupported else { return }
        let point = preview.captureDevicePointConverted(fromLayerPoint: gesture.location(in: view))
        guard (try? camera.lockForConfiguration()) != nil else { return }
        camera.focusPointOfInterest = point
        camera.focusMode = .continuousAutoFocus
        camera.unlockForConfiguration()
    }

    // MARK: No camera

    private func buildNotice() {
        notice.axis = .vertical
        notice.spacing = 14
        notice.alignment = .center
        notice.isHidden = true
        notice.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            notice.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            notice.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            notice.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
        ])
    }

    private func showNotice(denied: Bool) {
        notice.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.text = denied ? NSLocalizedString("Camera access is needed to scan the pairing code.", comment: "QR scanner") : NSLocalizedString("Camera unavailable", comment: "QR scanner")
        notice.addArrangedSubview(label)
        if denied {
            var configuration = UIButton.Configuration.borderedProminent()
            configuration.title = NSLocalizedString("Allow camera access", comment: "QR scanner")
            let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            })
            notice.addArrangedSubview(button)
        }
        notice.isHidden = false
        guide.isHidden = true
    }
}
