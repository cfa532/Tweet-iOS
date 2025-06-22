import SwiftUI
import AVFoundation

struct SimpleAudioPlayer: View {
    let url: URL
    var autoPlay: Bool = true
    
    @State private var player: AVPlayer?
    @State private var isPlaying: Bool = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isMuted: Bool = PreferenceHelper().getSpeakerMute()
    private let preferenceHelper = PreferenceHelper()
    
    var body: some View {
        VStack(spacing: 12) {
            // Waveform visualization (placeholder for now)
            HStack(spacing: 2) {
                ForEach(0..<30) { _ in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue.opacity(0.6))
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
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 4)
                        .cornerRadius(2)
                    
                    // Progress
                    Rectangle()
                        .fill(Color.blue)
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
                    .foregroundColor(.gray)
                
                Spacer()
                
                // Play/Pause button
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.blue)
                }
                
                Spacer()
                
                // Duration
                Text(formatTime(duration))
                    .font(.caption)
                    .foregroundColor(.gray)
                
                // Mute/Unmute button
                Button(action: toggleMute) {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundColor(.gray)
                        .padding(.leading, 8)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
    
    private func setupPlayer() {
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        player?.isMuted = isMuted
        
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
            player?.play()
            isPlaying = true
        }
    }
    
    private func togglePlayback() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
    }
    
    private func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
        preferenceHelper.setSpeakerMute(isMuted)
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
} 