import SwiftUI
import AVFoundation
import Combine

struct SimpleAudioPlayer: View {
    let url: URL
    var autoPlay: Bool = true
    
    @State private var player: AVPlayer?
    @State private var playerItem: AVPlayerItem?
    @State private var isPlaying: Bool = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @StateObject private var muteState = MuteState.shared
    @State private var timeObserver: Any?
    @State private var cancellables = Set<AnyCancellable>()
    
    var body: some View {
        VStack(spacing: 16) {
            // Audio visualization area with natural aspect ratio
            ZStack {
                // Background with subtle pattern
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.themeCardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.themeAccent.opacity(0.2), lineWidth: 1)
                    )
                
                // Audio waveform visualization
                HStack(spacing: 3) {
                    ForEach(0..<40) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.themeAccent.opacity(isPlaying ? 0.8 : 0.4))
                            .frame(width: 4, height: CGFloat.random(in: 8...32))
                            .animation(.easeInOut(duration: 0.1), value: isPlaying)
                    }
                }
                .frame(height: 60)
            }
            .frame(height: 80)
            .padding(.horizontal)
            
            // Progress bar
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background track
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.themeSecondaryText.opacity(0.2))
                            .frame(height: 6)
                        
                        // Progress
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.themeAccent)
                            .frame(width: geometry.size.width * CGFloat(currentTime / max(duration, 1)), height: 6)
                    }
                }
                .frame(height: 6)
                .padding(.horizontal)
                
                // Time labels
                HStack {
                    Text(formatTime(currentTime))
                        .font(.caption)
                        .foregroundColor(.themeSecondaryText)
                    
                    Spacer()
                    
                    Text(formatTime(duration))
                        .font(.caption)
                        .foregroundColor(.themeSecondaryText)
                }
                .padding(.horizontal)
            }
            
            // Control buttons
            HStack(spacing: 20) {
                // Mute/Unmute button
                Button(action: toggleMute) {
                    Image(systemName: muteState.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.themeSecondaryText)
                }
                
                Spacer()
                
                // Play/Pause button
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.themeAccent)
                }
                
                Spacer()
                
                // Placeholder for future controls
                Image(systemName: "ellipsis")
                    .font(.system(size: 20))
                    .foregroundColor(.themeSecondaryText.opacity(0.5))
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 16)
        .background(Color.themeCardBackground)
        .cornerRadius(16)
        .shadow(radius: 4)
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            cleanup()
        }
        .onChange(of: muteState.isMuted) { _, newMuteState in
            player?.isMuted = newMuteState
        }
    }
    
    private func setupPlayer() {
        print("DEBUG: [AUDIO PLAYER] Setting up AVPlayer for URL: \(url)")
        
        // Ensure mute state is refreshed from preferences
        muteState.refreshFromPreferences()
        
        // Configure audio session for playback
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("DEBUG: [AUDIO PLAYER] Failed to configure audio session: \(error)")
        }
        
        // Create AVPlayerItem and AVPlayer
        let asset = AVURLAsset(url: url)
        playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)
        
        // Configure player
        player?.isMuted = muteState.isMuted
        
        // Set up observers
        setupPlayerObservers()
        
        // Get duration
        Task {
            await loadDuration()
        }
        
        if autoPlay {
            print("DEBUG: [AUDIO PLAYER] Auto-playing audio")
            player?.play()
            isPlaying = true
        }
    }
    
    private func setupPlayerObservers() {
        guard let player = player, let playerItem = playerItem else { return }
        
        // Time observer for progress updates
        let timeScale = CMTimeScale(NSEC_PER_SEC)
        let time = CMTime(seconds: 0.1, preferredTimescale: timeScale)
        
        timeObserver = player.addPeriodicTimeObserver(forInterval: time, queue: .main) { time in
            self.currentTime = time.seconds
            
            // Check if playback finished
            if time.seconds >= self.duration && self.duration > 0 {
                self.isPlaying = false
                self.currentTime = 0
                self.player?.seek(to: .zero)
            }
        }
        
        // Use Combine to observe player item status
        playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { status in
                switch status {
                case .readyToPlay:
                    print("DEBUG: [AUDIO PLAYER] Player item ready to play")
                case .failed:
                    print("DEBUG: [AUDIO PLAYER] Player item failed: \(playerItem.error?.localizedDescription ?? "Unknown error")")
                case .unknown:
                    print("DEBUG: [AUDIO PLAYER] Player item status unknown")
                @unknown default:
                    break
                }
            }
            .store(in: &cancellables)
        
        // Use Combine to observe duration changes
        playerItem.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { duration in
                if duration.isValid && !duration.isIndefinite {
                    self.duration = duration.seconds
                    print("DEBUG: [AUDIO PLAYER] Duration updated: \(self.duration)")
                }
            }
            .store(in: &cancellables)
    }
    
    private func loadDuration() async {
        guard let playerItem = playerItem else { return }
        
        do {
            let duration = try await playerItem.asset.load(.duration)
            await MainActor.run {
                self.duration = duration.seconds
                print("DEBUG: [AUDIO PLAYER] Loaded duration: \(self.duration)")
            }
        } catch {
            print("DEBUG: [AUDIO PLAYER] Failed to load duration: \(error)")
        }
    }
    
    private func togglePlayback() {
        guard let player = player else { return }
        
        if isPlaying {
            print("DEBUG: [AUDIO PLAYER] Pausing playback")
            player.pause()
        } else {
            print("DEBUG: [AUDIO PLAYER] Starting playback")
            player.play()
        }
        isPlaying.toggle()
    }
    
    private func toggleMute() {
        muteState.toggleMute()
        player?.isMuted = muteState.isMuted
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func cleanup() {
        print("DEBUG: [AUDIO PLAYER] Cleaning up")
        
        // Remove time observer
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        
        // Cancel all Combine subscriptions
        cancellables.removeAll()
        
        // Stop and cleanup player
        player?.pause()
        player = nil
        playerItem = nil
    }
}