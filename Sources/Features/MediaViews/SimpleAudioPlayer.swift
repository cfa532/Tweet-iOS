import SwiftUI
import AVFoundation

struct SimpleAudioPlayer: View {
    let url: URL
    var autoPlay: Bool = true
    
    @State private var player: AVAudioPlayer?
    @State private var isPlaying: Bool = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @StateObject private var muteState = MuteState.shared
    private let preferenceHelper = PreferenceHelper()
    @State private var timer: Timer?
    
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
            cleanup()
        }
        .onChange(of: muteState.isMuted) { _, newMuteState in
            // Update player mute state when global mute state changes
            player?.volume = newMuteState ? 0.0 : 1.0
            print("DEBUG: [AUDIO PLAYER] Global mute state changed to: \(newMuteState)")
        }
        .onReceive(MuteState.shared.$isMuted) { globalMuteState in
            // Always sync with global mute state changes
            player?.volume = globalMuteState ? 0.0 : 1.0
            print("DEBUG: [AUDIO PLAYER] Synced with global mute state: \(globalMuteState)")
        }
    }
    
    private func setupPlayer() {
        do {
            // Ensure mute state is refreshed from preferences before setting up player
            muteState.refreshFromPreferences()
            
            // Configure audio session for playback
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            
            // Initialize AVAudioPlayer
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.volume = muteState.isMuted ? 0.0 : 1.0
            
            // Get duration
            duration = player?.duration ?? 0
            
            print("DEBUG: [AUDIO PLAYER] Setting initial mute state: \(muteState.isMuted)")
            
            // Start timer for progress updates
            startProgressTimer()
            
            if autoPlay {
                player?.play()
                isPlaying = true
            }
        } catch {
            print("Error setting up audio player: \(error)")
        }
    }
    
    private func togglePlayback() {
        if isPlaying {
            player?.pause()
            stopProgressTimer()
        } else {
            player?.play()
            startProgressTimer()
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
    
    private func startProgressTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if let player = player {
                currentTime = player.currentTime
                
                // Check if playback finished
                if !player.isPlaying && isPlaying {
                    isPlaying = false
                    currentTime = 0
                    stopProgressTimer()
                }
            }
        }
    }
    
    private func stopProgressTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func cleanup() {
        stopProgressTimer()
        player?.stop()
        player = nil
    }
} 