//
//  CachingVideoPlayer.swift
//  Tweet
//
//  Simple CachingVideoPlayer for MediaBrowserView and chat screens
//

import SwiftUI
import AVKit
import AVFoundation

struct CachingVideoPlayer: View {
    let url: URL
    let mid: String
    let isVisible: Bool
    let mediaType: MediaType
    let autoPlay: Bool
    let loopOnCompletion: Bool
    let videoAspectRatio: CGFloat
    let showNativeControls: Bool
    let isMuted: Bool
    let startTime: Double?
    let onVideoTap: (() -> Void)?
    let onVideoFinished: (() -> Void)?
    let onManualRestart: (() -> Void)?
    let onPlaybackStateChanged: ((Bool) -> Void)?
    
    @State private var player: AVPlayer?
    @State private var cachingPlayerItem: CachingPlayerItem?
    @State private var playerDelegate: CachingVideoPlayerDelegate?
    @State private var isLoading = true
    @State private var hasFinishedPlaying = false
    @State private var loadFailed = false
    @State private var videoCompletionObserver: NSObjectProtocol?
    @State private var savedPlaybackState: (wasPlaying: Bool, time: CMTime)?
    @State private var hasRecoveredThisCycle = false
    @State private var playerRefreshID = UUID()
    @State private var recoveryTask: Task<Void, Never>?
    @State private var isRecovering = false
    @State private var playbackStateObserver: NSKeyValueObservation?
    
    init(
        url: URL,
        mid: String,
        isVisible: Bool,
        mediaType: MediaType,
        autoPlay: Bool = true,
        loopOnCompletion: Bool = true,
        videoAspectRatio: CGFloat = 16.0/9.0,
        showNativeControls: Bool = true,
        isMuted: Bool = false,
        startTime: Double? = nil,
        onVideoTap: (() -> Void)? = nil,
        onVideoFinished: (() -> Void)? = nil,
        onManualRestart: (() -> Void)? = nil,
        onPlaybackStateChanged: ((Bool) -> Void)? = nil
    ) {
        self.url = url
        self.mid = mid
        self.isVisible = isVisible
        self.mediaType = mediaType
        self.autoPlay = autoPlay
        self.loopOnCompletion = loopOnCompletion
        self.videoAspectRatio = videoAspectRatio
        self.showNativeControls = showNativeControls
        self.isMuted = isMuted
        self.startTime = startTime
        self.onVideoTap = onVideoTap
        self.onVideoFinished = onVideoFinished
        self.onManualRestart = onManualRestart
        self.onPlaybackStateChanged = onPlaybackStateChanged
    }
    
    var body: some View {
        Group {
            if let player = player {
                ZStack {
                    if showNativeControls {
                        VideoPlayer(player: player)
                            .aspectRatio(videoAspectRatio, contentMode: .fit)
                            .clipped()
                            .id(playerRefreshID) // Force view refresh when player is recreated
                            .onTapGesture {
                                onVideoTap?()
                            }
                    } else {
                        VideoPlayer(player: player)
                            .aspectRatio(videoAspectRatio, contentMode: .fit)
                            .clipped()
                            .id(playerRefreshID) // Force view refresh when player is recreated
                            .onTapGesture {
                                onVideoTap?()
                            }
                    }
                    
                    // Show subtle loading indicator while buffering
                    if isLoading {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                                    .padding(8)
                                    .background(Color.black.opacity(0.5))
                                    .clipShape(Circle())
                                    .padding(8)
                            }
                        }
                    }
                }
            } else if isLoading {
                // Show black background with white spinner while loading for first time (no text)
                Color.black
                    .overlay(
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.2)
                    )
            } else if loadFailed {
                // Show broken icon only, no text
                Color.black
                    .overlay(
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.white)
                    )
            } else {
                Color.black
                    .overlay(
                        Image(systemName: "play.circle")
                            .font(.system(size: 40))
                            .foregroundColor(.white)
                    )
            }
        }
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            cleanupPlayer()
        }
        .onChange(of: isVisible) { _, visible in
            if visible {
                // CRITICAL FIX: Restore buffering settings when video becomes visible again
                // This allows videos to buffer properly when they come back into view
                if let playerItem = player?.currentItem {
                    if let cachingPlayerItem = playerItem as? CachingPlayerItem {
                        cachingPlayerItem.preferredForwardBufferDuration = 15.0  // Restore normal buffering
                        cachingPlayerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
                        print("DEBUG: [CachingVideoPlayer] Restored buffering settings for visible video: \(mid)")
                    } else {
                        // For progressive videos, restore buffer duration
                        playerItem.preferredForwardBufferDuration = 30.0
                        print("DEBUG: [CachingVideoPlayer] Restored buffering settings for visible progressive video: \(mid)")
                    }
                }

                // When view becomes visible, always attempt recovery to ensure video works properly
                // Videos that have been scrolled out of view may need recovery even if they appear healthy
                print("DEBUG: [CachingVideoPlayer] View became visible for \(mid), attempting recovery...")
                recoverFromBackground()

                // If autoPlay is enabled, start playing after recovery
                if autoPlay {
                    // Small delay to allow recovery to complete
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if self.isVisible { // Double-check we're still visible
                            self.player?.play()
                        }
                    }
                }
            } else {
                player?.pause()
            }
        }
        .onChange(of: autoPlay) { _, shouldPlay in
            if shouldPlay {
                // Check if video is at the end and needs to seek to beginning first
                if let player = player, let currentItem = player.currentItem {
                    let duration = currentItem.duration.seconds
                    let currentTime = player.currentTime().seconds
                    // If duration and currentTime are valid and we're within 0.5 seconds of the end
                    if duration.isFinite && duration > 0 && currentTime.isFinite {
                        let timeRemaining = duration - currentTime
                        // If we're within 0.5 seconds of the end, seek to beginning before playing
                        if timeRemaining <= 0.5 {
                            player.seek(to: .zero) { finished in
                                if finished {
                                    player.play()
                                    onManualRestart?() // Notify that we manually restarted
                                }
                            }
                            return
                        }
                    }
                }
                player?.play()
            } else {
                player?.pause()
            }
        }
        .onChange(of: isMuted) { _, muted in
            player?.isMuted = muted
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            handleWillResignActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            handleDidEnterBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            handleWillEnterForeground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            handleDidBecomeActive()
        }
    }
    
    private func setupPlayer() {
        Task {
            do {
                print("DEBUG: [CachingVideoPlayer] Setting up player for \(mid)")
                
                
                // Use SharedAssetCache.getOrCreatePlayer to get cached player or create new one
                // Cache key is always the video's mediaID (mid); do not pass tweetId.
                let newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(for: url, mediaType: mediaType)
                
                await MainActor.run {
                    // Store references
                    self.player = newPlayer
                    
                    // Configure player
                    newPlayer.isMuted = isMuted
                    
                    // Set up delegate for CachingPlayerItem if it exists
                    if let cachingPlayerItem = newPlayer.currentItem as? CachingPlayerItem {
                        self.cachingPlayerItem = cachingPlayerItem
                        
                        let delegate = CachingVideoPlayerDelegate(
                            onReadyToPlay: { [weak newPlayer] in
                                DispatchQueue.main.async {
                                    self.isLoading = false

                                    // Seek to start time if provided
                                    if let startTime = self.startTime, startTime > 0 {
                                        newPlayer?.seek(to: CMTime(seconds: startTime, preferredTimescale: 600)) { finished in
                                            if finished && self.autoPlay && self.isVisible {
                                                newPlayer?.play()
                                            }
                                        }
                                    } else if self.autoPlay && self.isVisible {
                                        newPlayer?.play()
                                    }
                                }
                            },
                            onPlaybackStalled: {
                                print("DEBUG: [CachingVideoPlayer] Playback stalled for \(self.mid)")
                            },
                            onDidFailToPlay: { error in
                                DispatchQueue.main.async {
                                    print("DEBUG: [CachingVideoPlayer] Failed to play \(self.mid): \(error?.localizedDescription ?? "Unknown error")")
                                    self.handleLoadFailure()
                                }
                            },
                            onDidFinishDownloading: { filePath in
                                print("DEBUG: [CachingVideoPlayer] Finished downloading \(self.mid) to \(filePath)")
                            },
                            onDidDownloadBytes: { bytesDownloaded, bytesExpected in
                                print("DEBUG: [CachingVideoPlayer] Downloaded \(bytesDownloaded)/\(bytesExpected) bytes for \(self.mid)")
                            },
                            onDownloadingFailed: { error in
                                DispatchQueue.main.async {
                                    print("DEBUG: [CachingVideoPlayer] Download failed for \(self.mid): \(error.localizedDescription)")
                                    self.handleLoadFailure()
                                }
                            }
                        )
                        
                        // Store the delegate to prevent deallocation
                        self.playerDelegate = delegate
                        cachingPlayerItem.delegate = delegate
                        
                        // Check if player item is already ready
                        if cachingPlayerItem.status == .readyToPlay {
                            print("DEBUG: [CachingVideoPlayer] Player item already ready for \(self.mid)")
                            self.isLoading = false
                            if self.autoPlay && self.isVisible {
                                newPlayer.play()
                            }
                        } else {
                            // Poll status asynchronously to hide loading indicator ASAP
                            Task {
                                while cachingPlayerItem.status != .readyToPlay && cachingPlayerItem.status != .failed {
                                    try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
                                }
                                
                                await MainActor.run {
                                    if cachingPlayerItem.status == .readyToPlay {
                                        print("DEBUG: [CachingVideoPlayer] Player item became ready for \(self.mid)")
                                        self.isLoading = false
                                        if self.autoPlay && self.isVisible {
                                            newPlayer.play()
                                        }
                                    } else if cachingPlayerItem.status == .failed {
                                        print("DEBUG: [CachingVideoPlayer] Player item failed for \(self.mid)")
                                        self.handleLoadFailure()
                                    }
                                }
                            }
                        }
                    } else {
                        // For regular AVPlayerItem, check status
                        if let playerItem = newPlayer.currentItem {
                            if playerItem.status == .readyToPlay {
                                self.isLoading = false
                                if self.autoPlay && self.isVisible {
                                    newPlayer.play()
                                }
                            } else {
                                // Poll status for non-caching player items
                                Task {
                                    while playerItem.status != .readyToPlay && playerItem.status != .failed {
                                        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
                                    }
                                    
                                    await MainActor.run {
                                        if playerItem.status == .readyToPlay {
                                            self.isLoading = false
                                            if self.autoPlay && self.isVisible {
                                                newPlayer.play()
                                            }
                                        } else {
                                            self.handleLoadFailure()
                                        }
                                    }
                                }
                            }
                        } else {
                            // No player item, set loading to false
                            self.isLoading = false
                        }
                    }
                    
                    // Set up video completion observer
                    self.setupVideoCompletionObserver(newPlayer)
                    
                    // Set up playback state observer
                    self.setupPlaybackStateObserver(newPlayer)
                    
                    // Start playback if needed - don't automatically rewind
                    if self.autoPlay && self.isVisible {
                        newPlayer.play()
                    }
                }
            } catch {
                await MainActor.run {
                    print("DEBUG: [CachingVideoPlayer] Failed to setup player for \(mid): \(error)")
                    handleLoadFailure()
                }
            }
        }
    }
    
    
    private func handleLoadFailure() {
        isLoading = false
        loadFailed = true
    }
    
    private func isVideoAtEnd(_ player: AVPlayer) -> Bool {
        guard let playerItem = player.currentItem else { return false }
        let currentTime = player.currentTime()
        let duration = playerItem.duration
        
        // Check if current time is very close to the end (within 0.1 seconds)
        if duration.isValid && !duration.isIndefinite {
            let timeRemaining = CMTimeSubtract(duration, currentTime)
            return timeRemaining.seconds <= 0.1
        }
        
        return false
    }
    
    private func setupVideoCompletionObserver(_ player: AVPlayer) {
        print("DEBUG: [CachingVideoPlayer] Setting up video completion observer for \(mid)")
        
        // Remove existing observer if any
        if let observer = videoCompletionObserver {
            print("DEBUG: [CachingVideoPlayer] Removing existing video completion observer for \(mid)")
            NotificationCenter.default.removeObserver(observer)
        }
        
        // Add new observer for video completion
        videoCompletionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [onVideoFinished, loopOnCompletion] notification in
            print("DEBUG: [CachingVideoPlayer] Video completion notification received for \(mid)")
            print("DEBUG: [CachingVideoPlayer] Notification object: \(notification.object ?? "nil")")
            print("DEBUG: [CachingVideoPlayer] Player current item: \(player.currentItem?.description ?? "nil")")
            
            // Notify that video finished
            onVideoFinished?()
            
            // Auto-restart only if looping is enabled
            if loopOnCompletion {
                print("DEBUG: [CachingVideoPlayer] Auto-restarting video (loop enabled) for \(mid)")
                // Only rewind if looping
                player.seek(to: .zero) { finished in
                    guard finished else { 
                        print("DEBUG: [CachingVideoPlayer] Seek to zero failed for \(mid)")
                        return 
                    }
                    print("DEBUG: [CachingVideoPlayer] Successfully seeked to zero for \(mid)")
                    player.play()
                }
            } else {
                print("DEBUG: [CachingVideoPlayer] Video finished, not looping for \(mid)")
            }
        }
        
        print("DEBUG: [CachingVideoPlayer] Video completion observer setup complete for \(mid)")
    }
    
    private func setupPlaybackStateObserver(_ player: AVPlayer) {
        // Remove existing observer if any
        playbackStateObserver?.invalidate()
        
        // Capture values we need to avoid capturing self
        let callback = self.onPlaybackStateChanged
        
        // Report initial state immediately to sync button with actual player state
        DispatchQueue.main.async {
            let initialIsPlaying = player.timeControlStatus == .playing
            callback?(initialIsPlaying)
        }
        
        // Observe the timeControlStatus to track actual playback state changes
        playbackStateObserver = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            DispatchQueue.main.async {
                let isPlaying = player.timeControlStatus == .playing
                callback?(isPlaying)
            }
        }
    }
    
    private func cleanupPlayer() {
        // Cancel any ongoing recovery task
        recoveryTask?.cancel()
        recoveryTask = nil
        isRecovering = false
        
        // Remove video completion observer
        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
        
        // Remove playback state observer
        playbackStateObserver?.invalidate()
        playbackStateObserver = nil
        
        // Restore mute state to global state before exiting fullscreen
        // This ensures the player instance is properly muted when returning to MediaCell
        if let player = player {
            player.isMuted = MuteState.shared.isMuted
            print("DEBUG: [CachingVideoPlayer] Restored mute state to global state (\(MuteState.shared.isMuted)) before exiting fullscreen for \(mid)")
        }
        
        // Don't pause or nullify the player - let it continue for MediaCell
        // The player is managed by SharedAssetCache and should persist
        print("DEBUG: [CachingVideoPlayer] Cleaning up observers but preserving player for \(mid)")
        
        // Clear local references but keep the player alive
        cachingPlayerItem = nil
        playerDelegate = nil
    }
    
    // MARK: - Background Recovery
    
    private func handleWillResignActive() {
        print("DEBUG: [CachingVideoPlayer] App will resign active for \(mid)")
        hasRecoveredThisCycle = false
        
        // Cancel any ongoing recovery task
        recoveryTask?.cancel()
        recoveryTask = nil
        isRecovering = false
        
        // Save playback state
        if let player = player {
            let wasPlaying = player.rate > 0
            let currentTime = player.currentTime()
            savedPlaybackState = (wasPlaying: wasPlaying, time: currentTime)
            
            // Pause the player
            player.pause()
            
            print("DEBUG: [CachingVideoPlayer] Saved state - wasPlaying: \(wasPlaying), time: \(currentTime.seconds)")
        }
    }
    
    private func handleDidEnterBackground() {
        print("DEBUG: [CachingVideoPlayer] App entering background for \(mid)")
        // State already saved in willResignActive
    }
    
    private func handleWillEnterForeground() {
        print("DEBUG: [CachingVideoPlayer] App entering foreground for \(mid)")
        recoverFromBackground()
    }
    
    private func handleDidBecomeActive() {
        print("DEBUG: [CachingVideoPlayer] App became active for \(mid)")
        // Recover from screen lock if we haven't already recovered
        if !hasRecoveredThisCycle {
            print("DEBUG: [CachingVideoPlayer] Recovering from screen lock for \(mid)")
            recoverFromBackground()
        }
    }
    
    private func recoverFromBackground() {
        // Cancel any ongoing recovery task first
        recoveryTask?.cancel()
        
        // Check if we're already recovering
        if isRecovering {
            print("DEBUG: [CachingVideoPlayer] Recovery already in progress for \(mid), skipping")
            return
        }
        
        // Always check if player is broken, even if we don't have one yet
        if let player = player, !isPlayerBroken() {
            // Player is healthy, restore state
            if let state = savedPlaybackState {
                print("DEBUG: [CachingVideoPlayer] Restoring playback state for \(mid) - wasPlaying: \(state.wasPlaying)")
                
                // Seek to saved position
                player.seek(to: state.time) { finished in
                    if finished && state.wasPlaying && self.isVisible {
                        player.play()
                        print("DEBUG: [CachingVideoPlayer] Resumed playback for \(self.mid)")
                    }
                }
                
                savedPlaybackState = nil
            }
            hasRecoveredThisCycle = true
            return
        }
        
        // Player is broken or doesn't exist - recreate it
        print("DEBUG: [CachingVideoPlayer] Player is broken or missing for \(mid), recreating...")
        
        // Mark as recovering
        isRecovering = true
        
        // Create recovery task that can be cancelled
        recoveryTask = Task { @MainActor in
            // Check if cancelled before proceeding
            guard !Task.isCancelled else {
                print("DEBUG: [CachingVideoPlayer] Recovery cancelled before starting for \(mid)")
                isRecovering = false
                return
            }
            
            // Clear broken player
            if let observer = videoCompletionObserver {
                NotificationCenter.default.removeObserver(observer)
                videoCompletionObserver = nil
            }
            
            player?.pause()
            self.player = nil
            isLoading = true
            loadFailed = false
            
            // Force view refresh when recreating player
            playerRefreshID = UUID()
            
            // Check if cancelled before recreating player
            guard !Task.isCancelled else {
                print("DEBUG: [CachingVideoPlayer] Recovery cancelled during cleanup for \(mid)")
                isRecovering = false
                return
            }
            
            // Recreate player
            setupPlayer()
            
            savedPlaybackState = nil
            hasRecoveredThisCycle = true
            isRecovering = false
            recoveryTask = nil
            
            print("DEBUG: [CachingVideoPlayer] Recovery completed for \(mid)")
        }
    }
    
    private func isPlayerBroken() -> Bool {
        guard let player = player else { return true }
        guard let playerItem = player.currentItem else { return true }
        
        // Check if player item is in failed state
        if playerItem.status == .failed {
            print("DEBUG: [CachingVideoPlayer] Player item status is failed for \(mid)")
            return true
        }
        
        // Check if player item is in unknown state (common after backgrounding)
        if playerItem.status == .unknown {
            print("DEBUG: [CachingVideoPlayer] Player item status is unknown for \(mid) - likely broken after backgrounding")
            return true
        }
        
        // Check if player has invalid time
        let currentTime = player.currentTime()
        if !currentTime.isValid || currentTime.isIndefinite {
            print("DEBUG: [CachingVideoPlayer] Player has invalid time for \(mid)")
            return true
        }
        
        // Check if player item error exists
        if let error = playerItem.error {
            print("DEBUG: [CachingVideoPlayer] Player item has error for \(mid): \(error.localizedDescription)")
            return true
        }
        
        return false
    }
}

// MARK: - CachingPlayerItem Delegate
private class CachingVideoPlayerDelegate: NSObject, CachingPlayerItemDelegate {
    private let onReadyToPlay: () -> Void
    private let onPlaybackStalled: () -> Void
    private let onDidFailToPlay: (Error?) -> Void
    private let onDidFinishDownloading: (String) -> Void
    private let onDidDownloadBytes: (Int, Int) -> Void
    private let onDownloadingFailed: (Error) -> Void
    
    init(
        onReadyToPlay: @escaping () -> Void,
        onPlaybackStalled: @escaping () -> Void,
        onDidFailToPlay: @escaping (Error?) -> Void,
        onDidFinishDownloading: @escaping (String) -> Void,
        onDidDownloadBytes: @escaping (Int, Int) -> Void,
        onDownloadingFailed: @escaping (Error) -> Void
    ) {
        self.onReadyToPlay = onReadyToPlay
        self.onPlaybackStalled = onPlaybackStalled
        self.onDidFailToPlay = onDidFailToPlay
        self.onDidFinishDownloading = onDidFinishDownloading
        self.onDidDownloadBytes = onDidDownloadBytes
        self.onDownloadingFailed = onDownloadingFailed
    }
    
    func playerItemReadyToPlay(_ playerItem: CachingPlayerItem) {
        onReadyToPlay()
    }
    
    func playerItemPlaybackStalled(_ playerItem: CachingPlayerItem) {
        onPlaybackStalled()
    }
    
    func playerItemDidFailToPlay(_ playerItem: CachingPlayerItem, withError error: Error?) {
        onDidFailToPlay(error)
    }
    
    func playerItem(_ playerItem: CachingPlayerItem, didFinishDownloadingFileAt filePath: String) {
        onDidFinishDownloading(filePath)
    }
    
    func playerItem(_ playerItem: CachingPlayerItem, didDownloadBytesSoFar bytesDownloaded: Int, outOf bytesExpected: Int) {
        onDidDownloadBytes(bytesDownloaded, bytesExpected)
    }
    
    func playerItem(_ playerItem: CachingPlayerItem, downloadingFailedWith error: Error) {
        onDownloadingFailed(error)
    }
}
