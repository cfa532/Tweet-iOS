//
//  GridVideoView.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  Grid video view component using the new video architecture
//

import SwiftUI
import AVKit

/// Grid video view that uses GridVideoContext for playback management
struct GridVideoView: View {
    let url: URL
    let videoMid: String
    let contentType: String
    let aspectRatio: CGFloat
    let onVideoFinished: (() -> Void)?
    let onVideoTap: (() -> Void)?
    
    @ObservedObject var context: GridVideoContext // Injected context
    @State private var player: AVPlayer?
    @State private var isLoading: Bool = true
    @State private var currentTime: TimeInterval = 0.0
    @State private var duration: TimeInterval = 0.0
    @State private var playerItemStatusObserver: NSKeyValueObservation?
    @State private var playerDidFinishObserver: NSObjectProtocol?
    @State private var timeObserverToken: Any?
    @Environment(\.scenePhase) private var scenePhase
    
    init(url: URL, videoMid: String, contentType: String, aspectRatio: CGFloat, onVideoFinished: (() -> Void)? = nil, onVideoTap: (() -> Void)? = nil, context: GridVideoContext) {
        self.url = url
        self.videoMid = videoMid
        self.contentType = contentType
        self.aspectRatio = aspectRatio
        self.onVideoFinished = onVideoFinished
        self.onVideoTap = onVideoTap
        self.context = context
    }
    
    var body: some View {
        Group {
            if let player = player {
                VideoPlayer(player: player)
                    .aspectRatio(aspectRatio, contentMode: .fill)
                    .onTapGesture {
                        onVideoTap?()
                    }
                    .overlay(
                        // Loading indicator
                        Group {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(1.5)
                            }
                        }
                    )
                    .onReceive(player.publisher(for: \.currentItem?.status)) { status in
                        DispatchQueue.main.async {
                            isLoading = (status != .readyToPlay)
                        }
                    }
            } else {
                // Loading placeholder
                Color.black
                    .aspectRatio(aspectRatio, contentMode: .fill)
                    .overlay(
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                    )
            }
        }
        .background(Color.black)
        .task {
            // Create player when view appears
            await createPlayer()
        }
        .onDisappear {
            // Clean up when view disappears
            cleanupPlayer()
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onReceive(MuteState.shared.$isMuted) { isMuted in
            // Update player mute state when global mute changes
            player?.isMuted = isMuted
        }
    }
    
    private func createPlayer() async {
        guard player == nil else { return }
        
        print("DEBUG: [GRID VIDEO VIEW] Creating player for: \(videoMid)")
        
        if let newPlayer = await context.getPlayer(for: videoMid, url: url, contentType: contentType) {
            await MainActor.run {
                self.player = newPlayer
                setupPlayerObservers(newPlayer)
                print("DEBUG: [GRID VIDEO VIEW] Player created for: \(videoMid)")
            }
        } else {
            print("ERROR: [GRID VIDEO VIEW] Failed to create player for: \(videoMid)")
        }
    }
    
    private func setupPlayerObservers(_ player: AVPlayer) {
        // Observe player item status for loading state
        playerItemStatusObserver = player.observe(\.currentItem?.status, options: [.new]) { player, change in
            DispatchQueue.main.async {
                if let status = change.newValue {
                    isLoading = (status != .readyToPlay)
                    
                    if status == .readyToPlay {
                        // Get duration when ready
                        if let item = player.currentItem {
                            duration = item.duration.seconds
                        }
                    }
                }
            }
        }
        
        // Observe when video finishes playing
        playerDidFinishObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            print("DEBUG: [GRID VIDEO VIEW] Video finished: \(videoMid)")
            onVideoFinished?()
            context.onVideoFinished(for: videoMid)
        }
        
        // Add time observer for progress tracking
        let timeInterval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: timeInterval, queue: .main) { time in
            currentTime = time.seconds
        }
    }
    
    private func cleanupPlayer() {
        // Remove observers
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = nil
        
        if let observer = playerDidFinishObserver {
            NotificationCenter.default.removeObserver(observer)
            playerDidFinishObserver = nil
        }
        
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        
        print("DEBUG: [GRID VIDEO VIEW] Cleaned up observers for: \(videoMid)")
    }
    
    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            print("DEBUG: [GRID VIDEO VIEW] Scene entered background for: \(videoMid)")
            // GridVideoContext will handle pausing
        case .active:
            print("DEBUG: [GRID VIDEO VIEW] Scene became active for: \(videoMid)")
            // GridVideoContext will handle resuming
        default:
            break
        }
    }
}

// MARK: - Grid Media View (for both images and videos)

/// Grid media view that handles both images and videos using new architecture
struct GridMediaView: View {
    let attachment: MimeiFileType
    let parentTweet: Tweet
    let aspectRatio: CGFloat
    let onVideoFinished: (() -> Void)?
    let onTap: (() -> Void)?
    
    @ObservedObject var context: GridVideoContext // Injected context
    @State private var image: UIImage?
    @State private var loading: Bool = false
    
    init(attachment: MimeiFileType, parentTweet: Tweet, aspectRatio: CGFloat, onVideoFinished: (() -> Void)? = nil, onTap: (() -> Void)? = nil, context: GridVideoContext) {
        self.attachment = attachment
        self.parentTweet = parentTweet
        self.aspectRatio = aspectRatio
        self.onVideoFinished = onVideoFinished
        self.onTap = onTap
        self.context = context
    }
    
    private var baseUrl: URL {
        return parentTweet.author?.baseUrl ?? HproseInstance.baseUrl
    }
    
    var body: some View {
        Group {
            if let url = attachment.getUrl(baseUrl) {
                switch attachment.type.lowercased() {
                case "video", "hls_video":
                    GridVideoView(
                        url: url,
                        videoMid: attachment.mid,
                        contentType: attachment.type,
                        aspectRatio: aspectRatio,
                        onVideoFinished: onVideoFinished,
                        onVideoTap: onTap,
                        context: context
                    )
                    
                case "image":
                    Group {
                        if let image = image {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                        } else if loading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.gray.opacity(0.2))
                        } else {
                            Color.gray.opacity(0.2)
                        }
                    }
                    .onTapGesture {
                        onTap?()
                    }
                    .onAppear {
                        loadImage()
                    }
                    
                default:
                    Color.gray.opacity(0.2)
                        .onTapGesture {
                            onTap?()
                        }
                }
            } else {
                Color.gray.opacity(0.2)
                    .onTapGesture {
                        onTap?()
                    }
            }
        }
    }
    
    private func loadImage() {
        guard let url = attachment.getUrl(baseUrl),
              attachment.type.lowercased() == "image" else { return }
        
        loading = true
        
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let uiImage = UIImage(data: data) {
                    await MainActor.run {
                        self.image = uiImage
                        self.loading = false
                    }
                }
            } catch {
                print("ERROR: Failed to load image from \(url): \(error)")
                await MainActor.run {
                    self.loading = false
                }
            }
        }
    }
}
