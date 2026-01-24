//
//  VideoPlayerContainerView.swift
//  Tweet
//
//  Created by Assistant on 2026-01-23.
//  Phase 1: Coordinated Multi-Player Architecture
//  UIKit UIView subclass with AVPlayerLayer for SharedVideoPlayerManager integration
//

import UIKit
import AVFoundation
import SwiftUI

// MARK: - VideoPlayerContainerView (UIKit)

/// UIKit UIView subclass that uses AVPlayerLayer as main layer
/// Integrates with SharedVideoPlayerManager for coordinated playback
public class VideoPlayerContainerView: UIView, VideoPlayerContainerProtocol, VideoPlayerContainerDelegate {
    // MARK: - Properties

    /// The video identifier this view represents
    public var videoId: String?

    /// Current player assigned to this view
    private var currentPlayer: AVPlayer?

    /// Observer for player status changes
    private var playerStatusObserver: NSKeyValueObservation?

    /// Observer for player rate changes (play/pause)
    private var playerRateObserver: NSKeyValueObservation?

    /// Observer for player item status changes
    private var playerItemStatusObserver: NSKeyValueObservation?

    /// Flag to track if view is ready for player assignment
    private var isReadyForPlayer = false

    /// Delegate for video events
    weak var delegate: VideoPlayerContainerDelegate?

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        // Set up AVPlayerLayer as the main layer
        let playerLayer = AVPlayerLayer()
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(playerLayer)

        // Configure view
        backgroundColor = .black
        clipsToBounds = true

        print("🎬 [VIDEO CONTAINER] Initialized VideoPlayerContainerView")
    }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()

        // Ensure player layer fills the entire view
        if let playerLayer = layer.sublayers?.first as? AVPlayerLayer {
            playerLayer.frame = bounds
        }
    }

    // MARK: - Player Management

    /// Assign a player to this view for playback
    /// - Parameter player: The AVPlayer to display
    /// - Parameter videoId: The video identifier
    public func assignPlayer(_ player: AVPlayer, for videoId: String) {
        guard isReadyForPlayer else {
            print("⚠️ [VIDEO CONTAINER] View not ready for player assignment: \(videoId)")
            return
        }

        print("🎬 [VIDEO CONTAINER] Assigning player for video: \(videoId)")

        // Remove existing player if any
        removeCurrentPlayer()

        // Assign new player
        self.currentPlayer = player
        self.videoId = videoId

        // Set player on the layer
        if let playerLayer = layer.sublayers?.first as? AVPlayerLayer {
            playerLayer.player = player
        }

        // Set up observers
        setupPlayerObservers()

        // Notify delegate on main actor
        Task { @MainActor in
            delegate?.videoPlayerContainerDidAssignPlayer(videoId: videoId)
        }
    }

    /// Remove the current player from this view
    public func removePlayer() {
        guard let videoId = videoId else { return }

        print("🎬 [VIDEO CONTAINER] Removing player for video: \(videoId)")

        removeCurrentPlayer()

        // Clear video ID
        self.videoId = nil

        // Notify delegate on main actor
        Task { @MainActor in
            delegate?.videoPlayerContainerDidRemovePlayer(videoId: videoId)
        }
    }

    private func removeCurrentPlayer() {
        // Remove observers
        removePlayerObservers()

        // Clear player from layer
        if let playerLayer = layer.sublayers?.first as? AVPlayerLayer {
            playerLayer.player = nil
        }

        // Clear player reference
        currentPlayer = nil
    }

    // MARK: - Player Observers

    private func setupPlayerObservers() {
        guard let player = currentPlayer else { return }

        // Observe player status
        playerStatusObserver = player.observe(\.status) { [weak self] player, _ in
            self?.handlePlayerStatusChange(player.status)
        }

        // Observe player rate (play/pause)
        playerRateObserver = player.observe(\.rate) { [weak self] player, _ in
            self?.handlePlayerRateChange(player.rate)
        }

        // Observe current item status
        playerItemStatusObserver = player.currentItem?.observe(\.status) { [weak self] item, _ in
            self?.handlePlayerItemStatusChange(item.status)
        }
    }

    private func removePlayerObservers() {
        playerStatusObserver?.invalidate()
        playerStatusObserver = nil

        playerRateObserver?.invalidate()
        playerRateObserver = nil

        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = nil
    }

    private func handlePlayerStatusChange(_ status: AVPlayer.Status) {
        guard let videoId = videoId else { return }

        switch status {
        case .readyToPlay:
            print("🎬 [VIDEO CONTAINER] Player ready for video: \(videoId)")
            Task { @MainActor in
                delegate?.videoPlayerContainerPlayerReady(videoId: videoId)
            }
        case .failed:
            print("❌ [VIDEO CONTAINER] Player failed for video: \(videoId)")
            if let error = currentPlayer?.error {
                Task { @MainActor in
                    delegate?.videoPlayerContainerPlayerFailed(videoId: videoId, error: error)
                }
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func handlePlayerRateChange(_ rate: Float) {
        guard let videoId = videoId else { return }

        if rate > 0 {
            print("▶️ [VIDEO CONTAINER] Player started playing: \(videoId)")
            Task { @MainActor in
                delegate?.videoPlayerContainerPlayerDidStart(videoId: videoId)
            }
        } else {
            print("⏸️ [VIDEO CONTAINER] Player paused: \(videoId)")
            Task { @MainActor in
                delegate?.videoPlayerContainerPlayerDidPause(videoId: videoId)
            }
        }
    }

    private func handlePlayerItemStatusChange(_ status: AVPlayerItem.Status) {
        guard let videoId = videoId else { return }

        switch status {
        case .readyToPlay:
            print("🎬 [VIDEO CONTAINER] Player item ready for video: \(videoId)")
        case .failed:
            print("❌ [VIDEO CONTAINER] Player item failed for video: \(videoId)")
            if let error = currentPlayer?.currentItem?.error {
                Task { @MainActor in
                    delegate?.videoPlayerContainerPlayerItemFailed(videoId: videoId, error: error)
                }
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    // MARK: - View Lifecycle

    /// Mark view as ready for player assignment (called when view appears)
    public func viewDidAppear() {
        isReadyForPlayer = true
        print("🎬 [VIDEO CONTAINER] View ready for player assignment")
    }

    /// Mark view as not ready for player assignment (called when view disappears)
    public func viewDidDisappear() {
        isReadyForPlayer = false
        removePlayer()
        print("🎬 [VIDEO CONTAINER] View no longer ready for players")
    }

    // MARK: - Deallocation

    deinit {
        removePlayerObservers()
        removePlayer()
        print("🗑️ [VIDEO CONTAINER] Deallocated VideoPlayerContainerView")
    }
}

// MARK: - VideoPlayerContainerDelegate Implementation

extension VideoPlayerContainerView {
    func videoPlayerContainerDidAssignPlayer(videoId: String) {
        print("🎬 [VIDEO CONTAINER] Player assigned for video: \(videoId)")
    }

    func videoPlayerContainerDidRemovePlayer(videoId: String) {
        print("🎬 [VIDEO CONTAINER] Player removed for video: \(videoId)")
    }

    func videoPlayerContainerPlayerReady(videoId: String) {
        print("🎬 [VIDEO CONTAINER] Player ready for video: \(videoId)")
    }

    func videoPlayerContainerPlayerDidStart(videoId: String) {
        print("▶️ [VIDEO CONTAINER] Player started for video: \(videoId)")
    }

    func videoPlayerContainerPlayerDidPause(videoId: String) {
        print("⏸️ [VIDEO CONTAINER] Player paused for video: \(videoId)")
    }

    func videoPlayerContainerPlayerFailed(videoId: String, error: Error) {
        print("❌ [VIDEO CONTAINER] Player failed for video: \(videoId), error: \(error)")
    }

    func videoPlayerContainerPlayerItemFailed(videoId: String, error: Error) {
        print("❌ [VIDEO CONTAINER] Player item failed for video: \(videoId), error: \(error)")
    }
}

// VideoPlayerContainerDelegate protocol is now defined in SharedVideoPlayerManager.swift

// MARK: - UIViewRepresentable Wrapper

/// SwiftUI wrapper for VideoPlayerContainerView
public struct VideoPlayerContainerRepresentable: UIViewRepresentable {
    let videoId: String
    weak var delegate: VideoPlayerContainerDelegate?

    public func makeUIView(context: Context) -> VideoPlayerContainerView {
        let view = VideoPlayerContainerView()
        view.delegate = delegate

        // Set the video ID for the view
        view.videoId = videoId

        // Register with SharedVideoPlayerManager
        SharedVideoPlayerManager.shared.registerVideoContainer(view, for: videoId)

        // Mark as ready for player assignment
        view.viewDidAppear()

        return view
    }

    public func updateUIView(_ uiView: VideoPlayerContainerView, context: Context) {
        // Update delegate if changed
        uiView.delegate = delegate
    }

    public static func dismantleUIView(_ uiView: VideoPlayerContainerView, coordinator: ()) {
        // Mark as not ready before dismantling
        uiView.viewDidDisappear()

        // Unregister when view is dismantled
        SharedVideoPlayerManager.shared.unregisterVideoContainer(for: uiView.videoId ?? "")
    }
}

// MARK: - Preview

#if DEBUG
struct VideoPlayerContainerRepresentable_Previews: PreviewProvider {
    static var previews: some View {
        VideoPlayerContainerRepresentable(videoId: "preview_video", delegate: nil)
            .frame(width: 300, height: 200)
            .background(Color.gray.opacity(0.2))
    }
}
#endif