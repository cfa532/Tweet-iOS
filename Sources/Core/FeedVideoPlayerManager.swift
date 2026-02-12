//
//  FeedVideoPlayerManager.swift
//  Tweet
//
//  Owns a single shared AVPlayer for all feed video playback.
//  The VideoPlaybackCoordinator decides WHICH video to play;
//  this manager owns THE player, swaps AVPlayerItems, and
//  attaches/detaches from cells' AVPlayerLayer.
//
import UIKit
import AVFoundation

@MainActor
class FeedVideoPlayerManager {
    static let shared = FeedVideoPlayerManager()

    // MARK: - Properties

    /// The single shared AVPlayer
    private(set) var player: AVPlayer?

    /// Currently active video mid (attachment mid)
    private(set) var activeVideoMid: String?

    /// Currently active video identifier (cellTweetId_videoMid_attachmentIndex)
    private(set) var activeVideoIdentifier: String?

    /// Currently attached cell
    private(set) weak var activeCell: MediaCellUIView?

    /// Position cache: saves playback position when swapping away from a video
    private var positionCache: [String: (time: CMTime, wasPlaying: Bool)] = [:]

    /// Frame capture output (attached to current player item)
    private var videoOutput: AVPlayerItemVideoOutput?
    private weak var videoOutputAttachedItem: AVPlayerItem?

    /// KVO / notification observers on the shared player
    private var statusObserver: NSKeyValueObservation?
    private var completionObserver: NSObjectProtocol?
    private var stopAllObserver: NSObjectProtocol?

    /// Periodic time observer for timer label
    private var timeObserverToken: Any?

    /// Whether the current item is ready to play
    private var isPlayerLoaded: Bool = false

    /// Frame capture throttle
    private var lastFrameCaptureAt: Date = .distantPast

    /// Async task for loading a new player item
    private var loadItemTask: Task<Void, Never>?

    /// Prevent duplicate finish handling
    private var isHandlingFinishEvent: Bool = false

    // MARK: - Init

    private init() {
        // Listen for .stopAllVideos (posted by handleVideoTap, AudioSessionManager, etc.)
        stopAllObserver = NotificationCenter.default.addObserver(
            forName: .stopAllVideos, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopVideo()
            }
        }

        // Observe mute state changes
        MuteState.shared.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] muted in
                self?.player?.isMuted = muted
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    deinit {
        if let o = stopAllObserver { NotificationCenter.default.removeObserver(o) }
        if let o = completionObserver { NotificationCenter.default.removeObserver(o) }
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
    }

    // MARK: - Play Video

    /// Play a video in a cell. Handles item swap, position resume, and layer attachment.
    /// Called by VideoPlaybackCoordinator when it identifies the primary video.
    func playVideo(identifier: String, mid: String, cell: MediaCellUIView) {
        // Already playing this exact video in this cell — no-op
        if activeVideoIdentifier == identifier, activeCell === cell, player?.rate ?? 0 > 0 {
            return
        }

        // Save state from current video before switching
        saveCurrentState()

        // Detach from old cell
        activeCell?.detachSharedPlayer()

        // Update tracking
        let oldMid = activeVideoMid
        activeVideoIdentifier = identifier
        activeVideoMid = mid
        activeCell = cell

        // Cancel any in-flight item load
        loadItemTask?.cancel()
        loadItemTask = nil

        // Get video load info from the cell
        guard let loadInfo = cell.videoLoadInfo() else {
            print("⚠️ [FEED PLAYER] No video load info for \(mid.prefix(10))")
            return
        }

        // Show loading spinner on the new cell
        cell.showVideoLoading()

        // Try to reuse existing player item if same video mid
        if mid == oldMid, let existingItem = player?.currentItem, existingItem.status != .failed {
            // Same video — just reattach to new cell (e.g., retweet of same video)
            handlePlayerItemReady(existingItem, cell: cell, mid: mid, isReuse: true)
            return
        }

        // Load new AVPlayerItem (async)
        let url = loadInfo.url
        let mediaType = loadInfo.mediaType
        let mediaID = SharedAssetCache.shared.extractMediaID(from: url) ?? mid

        loadItemTask = Task { [weak self] in
            // Retry up to 2 times on transient network failures (e.g. "Connection reset by peer"
            // that occurs when LocalHTTPServer isn't ready at app launch)
            var lastError: Error?
            for attempt in 0..<3 {
                guard !Task.isCancelled else { return }
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                }
                do {
                    let newItem = try await SharedAssetCache.shared.getOrCreatePlayerItem(
                        for: url, mediaID: mediaID, mediaType: mediaType
                    )
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self, self.activeVideoMid == mid else { return }
                        self.handleNewPlayerItem(newItem, cell: cell, mid: mid)
                    }
                    return  // Success — exit retry loop
                } catch {
                    lastError = error
                    guard !Task.isCancelled else { return }
                }
            }
            // All retries exhausted
            await MainActor.run {
                self?.activeCell?.hideVideoLoading()
                print("⚠️ [FEED PLAYER] Failed to load item for \(mid.prefix(10)) after retries: \(lastError?.localizedDescription ?? "unknown")")
            }
        }
    }

    /// Pause the shared player and save position.
    func pauseVideo() {
        guard let player, let mid = activeVideoMid else { return }
        if player.rate > 0 {
            savePosition(player: player, mid: mid, wasPlaying: true)
        }
        captureLastFrame()
        UIView.animate(withDuration: 0.2, animations: {
            player.volume = 0
        }, completion: { _ in
            player.pause()
        })
    }

    /// Stop playback, save state, detach from cell.
    func stopVideo() {
        guard let player else { return }
        saveCurrentState()
        player.pause()
        detachVideoOutput()
        removeObservers()
        removeTimeObserver()

        // Release the player item to free network/cache resources
        // (fullscreen will load its own item from the cached asset)
        player.replaceCurrentItem(with: nil)

        // Detach from cell
        activeCell?.detachSharedPlayer()
        activeCell = nil
        activeVideoIdentifier = nil
        activeVideoMid = nil
        isPlayerLoaded = false
    }

    /// Save current position for fullscreen transition.
    func savePositionForFullscreen() {
        guard let player, let mid = activeVideoMid, player.currentItem != nil else { return }
        let currentTime = player.currentTime()
        let wasPlaying = player.rate > 0
        PersistentVideoStateManager.shared.saveState(
            videoMid: mid,
            currentTime: currentTime,
            wasPlaying: wasPlaying,
            context: .fullScreen
        )
    }

    /// Called when active cell is about to be reused or goes invisible.
    func detachIfActiveCell(_ cell: MediaCellUIView) {
        guard activeCell === cell else { return }
        saveCurrentState()
        player?.pause()
        cell.detachSharedPlayer()
        removeObservers()
        removeTimeObserver()
        activeCell = nil
        activeVideoIdentifier = nil
        activeVideoMid = nil
        isPlayerLoaded = false
    }

    // MARK: - Private: Player Item Handling

    private func handleNewPlayerItem(_ item: AVPlayerItem, cell: MediaCellUIView, mid: String) {
        // Remove observers from old item
        removeObservers()
        removeTimeObserver()
        detachVideoOutput()

        // Cache the asset so FullScreenVideoManager.getAsset() finds it instantly
        let mediaID = SharedAssetCache.shared.extractMediaID(
            from: (item.asset as? AVURLAsset)?.url ?? URL(fileURLWithPath: "/")
        ) ?? mid
        SharedAssetCache.shared.cacheAsset(item.asset, for: mediaID)

        if let player {
            player.replaceCurrentItem(with: item)
        } else {
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.automaticallyWaitsToMinimizeStalling = true
            self.player = newPlayer
        }

        guard let player else { return }
        player.isMuted = MuteState.shared.isMuted
        player.pause()  // Don't start until ready

        handlePlayerItemReady(item, cell: cell, mid: mid, isReuse: false)
    }

    private func handlePlayerItemReady(_ item: AVPlayerItem, cell: MediaCellUIView, mid: String, isReuse: Bool) {
        guard let player else { return }

        // Attach to cell's layer
        cell.attachSharedPlayer(player)

        // Setup observers on the item
        setupObservers(item: item, mid: mid)

        // Attach video output for frame capture
        attachVideoOutput(to: item)

        // Check if already ready
        if item.status == .readyToPlay, !item.loadedTimeRanges.isEmpty {
            isPlayerLoaded = true
            startPlayback(player: player, mid: mid)
        } else {
            isPlayerLoaded = false
            // statusObserver will trigger playback when ready
        }
    }

    private func startPlayback(player: AVPlayer, mid: String) {
        // Check for cached position to resume from
        if let cached = positionCache[mid] {
            let targetSeconds = cached.time.seconds
            if targetSeconds.isFinite, targetSeconds > 0.25 {
                let currentSeconds = player.currentTime().seconds
                if currentSeconds.isFinite, abs(currentSeconds - targetSeconds) > 0.25 {
                    player.seek(to: cached.time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        Task { @MainActor in self?.beginPlaybackWithFade(player) }
                    }
                    return
                }
            }
        }

        // Also check VideoStateCache for position from previous session
        if let info = VideoStateCache.shared.getCachedPlaybackInfo(for: mid) {
            let targetSeconds = info.time.seconds
            if targetSeconds.isFinite, targetSeconds > 0.25 {
                let currentSeconds = player.currentTime().seconds
                if currentSeconds.isFinite, abs(currentSeconds - targetSeconds) > 0.25 {
                    player.seek(to: info.time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        Task { @MainActor in self?.beginPlaybackWithFade(player) }
                    }
                    return
                }
            }
        }

        // Check if video finished — seek to beginning
        if isVideoAtEnd(player) {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in self?.beginPlaybackWithFade(player) }
            }
            return
        }

        beginPlaybackWithFade(player)
    }

    private func beginPlaybackWithFade(_ player: AVPlayer) {
        player.isMuted = MuteState.shared.isMuted
        player.volume = 0
        player.play()
        UIView.animate(withDuration: 0.3) {
            player.volume = 1.0
        }

        // Start timer for single-media cells
        if let cell = activeCell, cell.isSingleMediaCell {
            cell.showVideoTimer()
            startTimeObserver()
        }

        activeCell?.hideVideoLoading()
    }

    // MARK: - Observers

    private func setupObservers(item: AVPlayerItem, mid: String) {
        removeObservers()

        // Video finished
        completionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleVideoFinished(mid: mid)
            }
        }

        // Item status → start playback when ready
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.activeVideoMid == mid else { return }
                if item.status == .readyToPlay, !item.loadedTimeRanges.isEmpty {
                    self.isPlayerLoaded = true
                    self.activeCell?.hideVideoLoading()
                    if let player = self.player, player.rate == 0 {
                        self.startPlayback(player: player, mid: mid)
                    }
                } else if item.status == .failed {
                    self.activeCell?.hideVideoLoading()
                }
            }
        }
    }

    private func removeObservers() {
        if let o = completionObserver { NotificationCenter.default.removeObserver(o) }
        completionObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
    }

    // MARK: - Time Observer

    private func startTimeObserver() {
        removeTimeObserver()
        guard let player else { return }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in self?.updateTimerOnActiveCell(currentTime: time) }
        }
    }

    private func removeTimeObserver() {
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
    }

    private func updateTimerOnActiveCell(currentTime: CMTime) {
        guard let item = player?.currentItem else { return }
        let duration = item.duration
        guard duration.isValid, !duration.isIndefinite, duration.seconds > 0 else { return }
        let remaining = max(0, duration.seconds - currentTime.seconds)
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        activeCell?.updateTimerText("\(minutes):\(String(format: "%02d", seconds))")
    }

    // MARK: - Video Finished

    private func handleVideoFinished(mid: String) {
        guard !isHandlingFinishEvent else { return }
        isHandlingFinishEvent = true
        defer { isHandlingFinishEvent = false }

        guard let player, let item = player.currentItem else { return }
        let duration = item.duration
        guard duration.isValid, duration.seconds > 0 else { return }
        let timeUntilEnd = duration.seconds - player.currentTime().seconds
        guard timeUntilEnd < 0.5 else { return }

        player.pause()
        player.isMuted = MuteState.shared.isMuted
        positionCache.removeValue(forKey: mid)

        // Synchronous frame capture — must complete before coordinator advances
        // so detachSharedPlayer() can show the cached frame instead of black
        captureLastFrameSync()

        // Notify coordinator to advance
        NotificationCenter.default.post(
            name: .videoDidFinishPlaying,
            object: nil,
            userInfo: ["videoMid": mid, "tweetId": activeCell?.parentTweetMid ?? ""]
        )
    }

    // MARK: - State Management

    private func saveCurrentState() {
        guard let player, let mid = activeVideoMid else { return }
        guard player.currentItem != nil else { return }
        let wasPlaying = player.rate > 0
        if wasPlaying || positionCache[mid] != nil {
            savePosition(player: player, mid: mid, wasPlaying: wasPlaying)
        }
        captureLastFrame()
    }

    private func savePosition(player: AVPlayer, mid: String, wasPlaying: Bool) {
        let currentTime = player.currentTime()
        guard currentTime.seconds.isFinite, currentTime.seconds > 0.25 else { return }
        guard !isVideoAtEnd(player) else { return }
        positionCache[mid] = (time: currentTime, wasPlaying: wasPlaying)
    }

    private func isVideoAtEnd(_ player: AVPlayer, tolerance: Double = 0.5) -> Bool {
        guard let item = player.currentItem else { return false }
        let duration = item.duration
        guard duration.isValid, !duration.isIndefinite else { return false }
        let diff = CMTimeSubtract(duration, player.currentTime())
        return CMTimeCompare(diff, CMTime(seconds: tolerance, preferredTimescale: duration.timescale)) <= 0
    }

    // MARK: - Frame Capture

    private func attachVideoOutput(to item: AVPlayerItem) {
        detachVideoOutput()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        item.add(output)
        videoOutput = output
        videoOutputAttachedItem = item
    }

    private func detachVideoOutput() {
        if let item = videoOutputAttachedItem, let output = videoOutput {
            DispatchQueue.global(qos: .utility).async {
                item.remove(output)
            }
        }
        videoOutput = nil
        videoOutputAttachedItem = nil
    }

    /// Synchronous frame capture — extracts pixel buffer and converts to UIImage on the calling thread.
    /// Used when the frame MUST be in VideoLastFrameCache before the next line executes
    /// (e.g., before posting .videoDidFinishPlaying which triggers coordinator advance + detach).
    private func captureLastFrameSync() {
        guard let player, let item = player.currentItem, let output = videoOutput else { return }
        guard item.status == .readyToPlay, !item.loadedTimeRanges.isEmpty else { return }
        guard let mid = activeVideoMid else { return }

        let playerTime = player.currentTime()
        let hostTime = CACurrentMediaTime()
        let hostItemTime = output.itemTime(forHostTime: hostTime)

        // Try multiple time offsets to find a valid pixel buffer
        let backoffs: [Double] = [0.0, -0.08, -0.20, -0.40]
        var candidateTimes: [CMTime] = backoffs.compactMap { d in
            let t = CMTime(seconds: max(0, playerTime.seconds + d), preferredTimescale: 600)
            return t.isValid ? t : nil
        }
        if hostItemTime.isValid { candidateTimes.append(hostItemTime) }

        var pixelBuffer: CVPixelBuffer?
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

        VideoLastFrameCache.shared.set(image, for: mid)
        lastFrameCaptureAt = Date()
    }

    /// Async frame capture — used during normal playback (pause, swap) where slight delay is fine
    private func captureLastFrame() {
        guard let player, let item = player.currentItem, let output = videoOutput else { return }
        guard item.status == .readyToPlay, !item.loadedTimeRanges.isEmpty else { return }
        guard let mid = activeVideoMid else { return }

        let now = Date()
        guard now.timeIntervalSince(lastFrameCaptureAt) >= 0.75 else { return }
        lastFrameCaptureAt = now

        let playerTimeNow = player.currentTime()
        let hostTimeNow = CACurrentMediaTime()
        let hostItemTimeNow = output.itemTime(forHostTime: hostTimeNow)

        Task.detached(priority: .utility) {
            let base = playerTimeNow
            let backoffs: [Double] = [0.0, -0.08, -0.20, -0.40]
            var candidateTimes: [CMTime] = []
            for d in backoffs {
                let t = CMTime(seconds: max(0, base.seconds + d), preferredTimescale: 600)
                if t.isValid { candidateTimes.append(t) }
            }
            if hostItemTimeNow.isValid { candidateTimes.append(hostItemTimeNow) }

            var pixelBuffer: CVPixelBuffer?
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

    // MARK: - Background/Foreground

    /// Called when app enters background — release player item to free memory
    func releaseForBackground() {
        saveCurrentState()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        detachVideoOutput()
        removeObservers()
        removeTimeObserver()
        isPlayerLoaded = false
    }

    /// Called when app returns to foreground — coordinator will trigger re-playback
    func recoverFromBackground() {
        // Player shell still exists; coordinator will call playVideo() which loads a new item
    }
}

// Import Combine for MuteState observation
import Combine
