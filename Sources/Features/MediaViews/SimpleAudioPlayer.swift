import SwiftUI
import AVFoundation

struct SimpleAudioPlayer: View {
    let url: URL
    var autoPlay: Bool = true
    
    @State private var player: AVPlayer?
    @State private var isPlaying: Bool = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @StateObject private var muteState = MuteState.shared
    private let preferenceHelper = PreferenceHelper()
    
    var body: some View {
        VStack(spacing: 12) {
            // Waveform visualization (placeholder for now)
            HStack(spacing: 2) {
                ForEach(0..<30) { _ in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.themeAccent.opacity(0.6))
                        .frame(width: 3, height: CGFloat.random(in: 4...20))
                }
            }
            .frame(height: 40)
            .padding(.horizontal)
            
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    Rectangle()
                        .fill(Color.themeSecondaryText.opacity(0.3))
                        .frame(height: 4)
                        .cornerRadius(2)
                    
                    // Progress
                    Rectangle()
                        .fill(Color.themeAccent)
                        .frame(width: geometry.size.width * CGFloat(currentTime / max(duration, 1)), height: 4)
                        .cornerRadius(2)
                }
            }
            .frame(height: 4)
            .padding(.horizontal)
            
            // Time labels and controls
            HStack {
                // Current time
                Text(formatTime(currentTime))
                    .font(.caption)
                    .foregroundColor(.themeSecondaryText)
                
                Spacer()
                
                // Play/Pause button
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.themeAccent)
                }
                
                Spacer()
                
                // Duration
                Text(formatTime(duration))
                    .font(.caption)
                    .foregroundColor(.themeSecondaryText)
                
                // Mute/Unmute button
                Button(action: toggleMute) {
                    Image(systemName: muteState.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundColor(.themeSecondaryText)
                        .padding(.leading, 8)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 12)
        .background(Color.themeCardBackground)
        .cornerRadius(12)
        .shadow(radius: 2)
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            player?.pause()
        }
        .onChange(of: muteState.isMuted) { _, newMuteState in
            // Update player mute state when global mute state changes
            player?.isMuted = newMuteState
            print("DEBUG: [AUDIO PLAYER] Global mute state changed to: \(newMuteState)")
        }
    }
    
    private func setupPlayer() {
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        player?.isMuted = muteState.isMuted
        print("DEBUG: [AUDIO PLAYER] Setting initial mute state: \(muteState.isMuted)")
        
        // Get duration using the new load(.duration) method
        Task {
            do {
                let durationTime = try await playerItem.asset.load(.duration)
                await MainActor.run {
                    self.duration = durationTime.seconds
                }
            } catch {
                print("Error loading duration: \(error)")
                await MainActor.run {
                    self.duration = 0
                }
            }
        }
        
        // Add time observer
        player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
            currentTime = time.seconds
        }
        
        if autoPlay {
            // Activate audio session for audio playback
            AudioSessionManager.shared.activateForVideoPlayback()
            player?.play()
            isPlaying = true
        }
    }
    
    private func togglePlayback() {
        if isPlaying {
            player?.pause()
        } else {
            // Activate audio session for audio playback
            AudioSessionManager.shared.activateForVideoPlayback()
            player?.play()
        }
        isPlaying.toggle()
    }
    
    private func toggleMute() {
        print("DEBUG: [AUDIO PLAYER] Toggling mute state from: \(muteState.isMuted)")
        muteState.toggleMute()
        print("DEBUG: [AUDIO PLAYER] Mute state toggled to: \(muteState.isMuted)")
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
} 