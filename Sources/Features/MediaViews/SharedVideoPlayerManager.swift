//
//  SharedVideoPlayerManager.swift
//  Tweet
//
//  Created by Assistant on 2026-01-23.
//  Phase 1: Coordinated Multi-Player Architecture
//  Singleton manager for shared AVPlayer instances with container delegation
//

import AVFoundation
import UIKit
import SwiftUI

// MARK: - SharedVideoPlayerManager

/// Singleton manager for coordinated video playback across multiple MediaCell instances
/// Manages a pool of AVPlayer instances and assigns them to VideoPlayerContainerView instances
@MainActor
class SharedVideoPlayerManager {
    // MARK: - Singleton
    static let shared = SharedVideoPlayerManager()

    // MARK: - Properties

    /// Currently playing video ID
    private(set) var currentlyPlayingVideoId: String?

    /// Current video mid
    private(set) var currentVideoMid: String?

    /// Current video URL
    private(set) var currentVideoURL: URL?

    /// Active players keyed by video ID
    private var activePlayers: [String: AVPlayer] = [:]

    /// Registered video containers keyed by video ID
    private var videoContainers: [String: AnyObject] = [:]

    /// Delegates for video events
    private var delegates: NSHashTable<AnyObject> = NSHashTable.weakObjects()

    /// Playback history for analytics
    private var playbackHistory: [String] = []

    // MARK: - Initialization

    private init() {
        print("🎬 [SHARED PLAYER] Initialized - Coordinating single video playback")
    }

    // MARK: - Public API

    /// Play a video with the specified parameters
    /// - Parameters:
    ///   - videoId: The video identifier
    ///   - videoMid: The video media ID (IPFS hash)
    ///   - cellTweetId: The cell tweet ID
    ///   - videoURL: Optional video URL
    func playVideo(videoId: String, videoMid: String, cellTweetId: String, videoURL: URL? = nil) {
        // If already playing this video instance, no action needed
        if currentlyPlayingVideoId == videoId {
            print("🎬 [SHARED PLAYER] Already coordinating playback for \(videoId) - ignoring duplicate request")
            return
        }

        print("🎬 [SHARED PLAYER] Coordinating playback for video: \(videoId) (mid: \(videoMid), cell: \(cellTweetId))")

        // Stop current video if different
        if let currentId = currentlyPlayingVideoId, currentId != videoId {
            pauseCurrentVideo()
        }

        // Update state
        currentlyPlayingVideoId = videoId
        currentVideoMid = videoMid
        currentVideoURL = videoURL

        // Track playback
        playbackHistory.append(videoId)
        if playbackHistory.count > 100 {
            playbackHistory.removeFirst(playbackHistory.count - 100)
        }

        // Create or get player and assign to container
        Task {
            do {
                let player = try await getOrCreatePlayer(for: videoId, videoMid: videoMid, videoURL: videoURL)

                // Assign player to container if available
                if let container = videoContainers[videoId] as? VideoPlayerContainerProtocol {
                    container.assignPlayer(player, for: videoId)

                    // Notify container delegate
                    if let containerDelegate = videoContainers[videoId] as? VideoPlayerContainerDelegate {
                        containerDelegate.videoPlayerContainerDidAssignPlayer(videoId: videoId)
                    }

                    // Start playback
                    player.play()
                    print("🎬 [SHARED PLAYER] Started coordinated playback for: \(videoId)")
                } else {
                    print("⚠️ [SHARED PLAYER] No container registered for video: \(videoId)")
                }
            } catch {
                print("❌ [SHARED PLAYER] Failed to create player for \(videoId): \(error)")
                // Reset state on failure
                currentlyPlayingVideoId = nil
                currentVideoMid = nil
            }
        }
    }

    /// Pause the currently playing video
    func pauseCurrentVideo() {
        guard let currentId = currentlyPlayingVideoId else { return }

        print("⏸️ [SHARED PLAYER] Pausing current video: \(currentId)")

        // Pause the player
        if let player = activePlayers[currentId] {
            player.pause()
        }

        // Notify delegates
        for delegate in delegates.allObjects {
            if let sharedDelegate = delegate as? SharedVideoPlayerDelegate {
                sharedDelegate.videoPlayerDidPause(videoId: currentId)
            }
        }

        // Clear current state
        currentlyPlayingVideoId = nil
        currentVideoMid = nil
        currentVideoURL = nil
    }

    /// Stop all videos and reset state
    func stopCurrentVideo() {
        guard let currentId = currentlyPlayingVideoId else { return }

        print("🛑 [SHARED PLAYER] Stopping current video: \(currentId)")

        // Stop the player
        if let player = activePlayers[currentId] {
            player.pause()
            player.seek(to: .zero)
        }

        // Remove from containers
        if let container = videoContainers[currentId] as? VideoPlayerContainerProtocol {
            container.removePlayer()

            // Notify container delegate
            if let containerDelegate = videoContainers[currentId] as? VideoPlayerContainerDelegate {
                containerDelegate.videoPlayerContainerDidRemovePlayer(videoId: currentId)
            }
        }

        // Notify delegates
        for delegate in delegates.allObjects {
            if let sharedDelegate = delegate as? SharedVideoPlayerDelegate {
                sharedDelegate.videoPlayerDidStop(videoId: currentId)
            }
        }

        // Clear current state
        currentlyPlayingVideoId = nil
        currentVideoMid = nil
        currentVideoURL = nil
    }

    /// Register a video container for a specific video ID
    /// - Parameters:
    ///   - container: The container to register
    ///   - videoId: The video ID
    func registerVideoContainer(_ container: AnyObject, for videoId: String) {
        videoContainers[videoId] = container
        print("🎬 [SHARED PLAYER] Registered video container for: \(videoId)")
    }

    /// Unregister a video container for a specific video ID
    /// - Parameter videoId: The video ID
    func unregisterVideoContainer(for videoId: String) {
        videoContainers.removeValue(forKey: videoId)
        print("🎬 [SHARED PLAYER] Unregistered video container for: \(videoId)")
    }

    /// Add a delegate for video events
    /// - Parameter delegate: The delegate to add
    func addDelegate(_ delegate: SharedVideoPlayerDelegate) {
        delegates.add(delegate)
    }

    /// Remove a delegate
    /// - Parameter delegate: The delegate to remove
    func removeDelegate(_ delegate: SharedVideoPlayerDelegate) {
        delegates.remove(delegate)
    }

    // MARK: - Private Methods

    /// Get or create an AVPlayer for the specified video
    /// - Parameters:
    ///   - videoId: The video identifier
    ///   - videoMid: The video media ID (IPFS hash)
    ///   - videoURL: Optional video URL
    /// - Returns: An AVPlayer ready for playback
    private func getOrCreatePlayer(for videoId: String, videoMid: String, videoURL: URL?) async throws -> AVPlayer {
        // Check if we already have a player for this video
        if let existingPlayer = activePlayers[videoId] {
            print("🎬 [SHARED PLAYER] Reusing existing player for: \(videoId)")
            return existingPlayer
        }

        print("🎬 [SHARED PLAYER] Creating new player for: \(videoId)")

        // Use videoMid directly as mediaID to get asset from SharedAssetCache
        let asset = try await SharedAssetCache.shared.getAsset(forMediaID: videoMid, videoURL: videoURL)

        // Create player item with the cached asset
        let playerItem = AVPlayerItem(asset: asset)

        // Configure for aggressive buffering (Twitter-style playback)
        playerItem.preferredForwardBufferDuration = 5.0
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        // Create player
        let player = AVPlayer(playerItem: playerItem)

        // Minimize stalling for smooth playback
        player.automaticallyWaitsToMinimizeStalling = false

        // Store player
        activePlayers[videoId] = player

        // Clean up old players if we have too many
        if activePlayers.count > 5 {
            let oldestKeys = activePlayers.keys.prefix(activePlayers.count - 5)
            for key in oldestKeys {
                activePlayers.removeValue(forKey: key)
            }
        }

        return player
    }
}

// MARK: - SharedVideoPlayerDelegate Protocol

/// Protocol for receiving video player events
@MainActor
protocol SharedVideoPlayerDelegate: AnyObject {
    func videoPlayerDidStart(videoId: String)
    func videoPlayerDidPause(videoId: String)
    func videoPlayerDidStop(videoId: String)
    func videoPlayerDidFail(videoId: String, error: Error)
}

// MARK: - VideoPlayerContainerDelegate Protocol

/// Protocol for VideoPlayerContainerView to receive events
@MainActor
protocol VideoPlayerContainerDelegate: AnyObject {
    func videoPlayerContainerDidAssignPlayer(videoId: String)
    func videoPlayerContainerDidRemovePlayer(videoId: String)
    func videoPlayerContainerPlayerReady(videoId: String)
    func videoPlayerContainerPlayerDidStart(videoId: String)
    func videoPlayerContainerPlayerDidPause(videoId: String)
    func videoPlayerContainerPlayerFailed(videoId: String, error: Error)
    func videoPlayerContainerPlayerItemFailed(videoId: String, error: Error)
}

// MARK: - SharedDisplayLinkManager

/// Singleton manager for CADisplayLink updates with observer pattern
@MainActor
class SharedDisplayLinkManager {
    // MARK: - Singleton
    static let shared = SharedDisplayLinkManager()

    // MARK: - Properties

    /// Display link for 30fps updates
    private var displayLink: CADisplayLink?

    /// Registered observer closures
    private var observers: [() -> Void] = []

    /// Whether the display link is currently running
    private var isRunning = false

    // MARK: - Initialization

    private init() {
        setupDisplayLink()
    }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Public API

    /// Add an observer closure to receive display link updates
    /// - Parameter observer: The closure to call on each display link update
    func addObserver(_ observer: @escaping () -> Void) {
        observers.append(observer)
        updateDisplayLinkState()
        print("⏱️ [DISPLAY LINK] Added observer, total: \(observers.count)")
    }

    /// Remove all observers
    func removeAllObservers() {
        observers.removeAll()
        updateDisplayLinkState()
        print("⏱️ [DISPLAY LINK] Removed all observers")
    }

    // MARK: - Private Methods

    private func setupDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired(_:)))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 30)
        displayLink?.isPaused = true
    }

    private func updateDisplayLinkState() {
        let shouldRun = observers.count > 0

        if shouldRun && !isRunning {
            // Start the display link
            displayLink?.isPaused = false
            isRunning = true
            print("⏱️ [DISPLAY LINK] Started (targeting 30fps)")
        } else if !shouldRun && isRunning {
            // Stop the display link
            displayLink?.isPaused = true
            isRunning = false
            print("⏱️ [DISPLAY LINK] Stopped")
        }
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        // Call all observer closures
        for observer in observers {
            observer()
        }
    }
}


// MARK: - VideoPlayerContainerDelegate Implementation

extension SharedVideoPlayerManager: VideoPlayerContainerDelegate {
    func videoPlayerContainerDidAssignPlayer(videoId: String) {
        print("🎬 [SHARED PLAYER] Container assigned player for: \(videoId)")
    }

    func videoPlayerContainerDidRemovePlayer(videoId: String) {
        print("🎬 [SHARED PLAYER] Container removed player for: \(videoId)")
    }

    func videoPlayerContainerPlayerReady(videoId: String) {
        print("🎬 [SHARED PLAYER] Container player ready for: \(videoId)")
        // Player is ready to play
    }

    func videoPlayerContainerPlayerDidStart(videoId: String) {
        print("▶️ [SHARED PLAYER] Container player started for: \(videoId)")
        // Notify other delegates
        for delegate in delegates.allObjects {
            if let sharedDelegate = delegate as? SharedVideoPlayerDelegate {
                sharedDelegate.videoPlayerDidStart(videoId: videoId)
            }
        }
    }

    func videoPlayerContainerPlayerDidPause(videoId: String) {
        print("⏸️ [SHARED PLAYER] Container player paused for: \(videoId)")
        // Notify other delegates
        for delegate in delegates.allObjects {
            if let sharedDelegate = delegate as? SharedVideoPlayerDelegate {
                sharedDelegate.videoPlayerDidPause(videoId: videoId)
            }
        }
    }

    func videoPlayerContainerPlayerFailed(videoId: String, error: Error) {
        print("❌ [SHARED PLAYER] Container player failed for: \(videoId): \(error)")
        // Clean up on failure
        activePlayers.removeValue(forKey: videoId)
        if currentlyPlayingVideoId == videoId {
            currentlyPlayingVideoId = nil
            currentVideoMid = nil
            currentVideoURL = nil
        }

        // Notify other delegates
        for delegate in delegates.allObjects {
            if let sharedDelegate = delegate as? SharedVideoPlayerDelegate {
                sharedDelegate.videoPlayerDidFail(videoId: videoId, error: error)
            }
        }
    }

    func videoPlayerContainerPlayerItemFailed(videoId: String, error: Error) {
        print("❌ [SHARED PLAYER] Container player item failed for: \(videoId): \(error)")
        // Handle player item failure
        videoPlayerContainerPlayerFailed(videoId: videoId, error: error)
    }
}