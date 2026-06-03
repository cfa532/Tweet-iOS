import SwiftUI
import AVFoundation
import Combine

private let audioPlaybackStartupTimeoutNanoseconds: UInt64 = 5_000_000_000

private func isAudioResourceUnavailableError(_ error: Error?) -> Bool {
    guard let error else { return true }

    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        switch nsError.code {
        case NSURLErrorResourceUnavailable,
             NSURLErrorBadServerResponse,
             NSURLErrorFileDoesNotExist,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorTimedOut:
            return true
        default:
            break
        }
    }

    if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
        return isAudioResourceUnavailableError(underlyingError)
    }

    return false
}

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
    @State private var wantsPlayback = false
    @State private var playbackLoadFailed = false
    @State private var isPlaybackLoading = false
    @State private var lastPlaybackWarningDate = Date.distantPast
    @State private var startupTimeoutTask: Task<Void, Never>?
    
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
                // Remove GeometryReader - use frame-based approach that fills available width
                ZStack(alignment: .leading) {
                    // Background track - fills available width
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.themeSecondaryText.opacity(0.2))
                        .frame(height: 6)
                    
                    // Progress - use scaleEffect to scale based on progress ratio
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.themeAccent)
                        .frame(height: 6)
                        .scaleEffect(x: CGFloat(currentTime / max(duration, 1)), anchor: .leading)
                }
                .frame(height: 6)
                .frame(maxWidth: .infinity) // Fill available width
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
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.themeSecondaryText)
                
                Spacer()
                
                // Play/Pause button
                Button(action: togglePlayback) {
                    if isPlaybackLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.themeAccent)
                            .frame(width: 50, height: 50)
                    } else {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.themeAccent)
                    }
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
        .onChange(of: muteState.isMuted) { _, _ in
            player?.isMuted = false
            player?.volume = 1
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
        
        // Audio should always play through when the user explicitly starts it.
        player?.isMuted = false
        player?.volume = 1
        
        // Set up observers
        setupPlayerObservers()
        
        // Get duration
        Task {
            await loadDuration()
        }
        
        if autoPlay {
            print("DEBUG: [AUDIO PLAYER] Auto-playing audio")
            wantsPlayback = true
            scheduleStartupTimeout(for: playerItem)
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
            
            // Check if playback finished using helper function
            if self.isAudioAtEnd() {
                self.isPlaying = false
                self.wantsPlayback = false
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
                    self.startupTimeoutTask?.cancel()
                    self.isPlaybackLoading = false
                case .failed:
                    print("DEBUG: [AUDIO PLAYER] Player item failed: \(playerItem.error?.localizedDescription ?? "Unknown error")")
                    self.startupTimeoutTask?.cancel()
                    let shouldWarn = self.wantsPlayback
                    self.playbackLoadFailed = true
                    self.wantsPlayback = false
                    self.isPlaybackLoading = false
                    self.isPlaying = false
                    if shouldWarn {
                        self.showAudioUnavailableToast()
                    }
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
                guard self.playerItem === playerItem else { return }
                self.duration = duration.seconds
                print("DEBUG: [AUDIO PLAYER] Loaded duration: \(self.duration)")
            }
        } catch {
            print("DEBUG: [AUDIO PLAYER] Failed to load duration: \(error)")
            guard isAudioResourceUnavailableError(error) else { return }
            await MainActor.run {
                guard self.playerItem === playerItem else { return }
                self.startupTimeoutTask?.cancel()
                let shouldWarn = self.wantsPlayback
                self.playbackLoadFailed = true
                self.wantsPlayback = false
                self.isPlaybackLoading = false
                self.isPlaying = false
                if shouldWarn {
                    self.showAudioUnavailableToast()
                }
            }
        }
    }
    
    private func togglePlayback() {
        guard let player = player else { return }
        
        if isPlaying {
            print("DEBUG: [AUDIO PLAYER] Pausing playback")
            player.pause()
            startupTimeoutTask?.cancel()
            wantsPlayback = false
            isPlaybackLoading = false
            isPlaying = false
        } else {
            if playbackLoadFailed || player.currentItem == nil || player.currentItem?.status == .failed {
                reloadCurrentItemAndPlay()
                return
            }

            print("DEBUG: [AUDIO PLAYER] Starting playback")
            wantsPlayback = true
            isPlaybackLoading = true
            player.isMuted = false
            player.volume = 1
            scheduleStartupTimeout(for: player.currentItem)
            player.play()
            isPlaying = true
        }
    }

    private func reloadCurrentItemAndPlay() {
        guard let player else { return }

        startupTimeoutTask?.cancel()
        cancellables.removeAll()
        currentTime = 0
        duration = 0
        playbackLoadFailed = false
        wantsPlayback = true
        isPlaybackLoading = true

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        playerItem = item
        player.replaceCurrentItem(with: item)
        player.isMuted = false
        player.volume = 1
        setupPlayerObservers()

        Task {
            await loadDuration()
        }

        scheduleStartupTimeout(for: item)
        player.play()
        isPlaying = true
    }

    private func scheduleStartupTimeout(for item: AVPlayerItem?) {
        startupTimeoutTask?.cancel()
        guard let item else { return }

        startupTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: audioPlaybackStartupTimeoutNanoseconds)
            guard !Task.isCancelled,
                  self.wantsPlayback,
                  self.playerItem === item,
                  item.status != .readyToPlay,
                  self.player?.timeControlStatus != .playing else { return }

            print("DEBUG: [AUDIO PLAYER] Playback startup timed out")
            self.playbackLoadFailed = true
            self.wantsPlayback = false
            self.isPlaybackLoading = false
            self.isPlaying = false
            self.player?.pause()
            self.player?.replaceCurrentItem(with: nil)
            self.showAudioUnavailableToast()
        }
    }

    private func showAudioUnavailableToast() {
        let now = Date()
        guard now.timeIntervalSince(lastPlaybackWarningDate) > 1 else { return }
        lastPlaybackWarningDate = now

        NotificationCenter.default.post(
            name: .audioPlaybackWarning,
            object: nil,
            userInfo: [
                "message": NSLocalizedString("This audio is not available.", comment: "Audio playback unavailable warning")
            ]
        )
    }
    
    private func toggleMute() {
        player?.isMuted = false
        player?.volume = 1
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    /// Helper function to check if audio is at the end
    /// Uses a 0.1 second tolerance to handle timing edge cases
    private func isAudioAtEnd() -> Bool {
        guard let player = player else { return false }
        guard duration > 0 else { return false }
        
        let currentTime = player.currentTime()
        
        // Check if current time is very close to the end (within 0.1 seconds)
        let timeDifference = duration - currentTime.seconds
        return timeDifference <= 0.1
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
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        
        // Stop and cleanup player
        player?.pause()
        player = nil
        playerItem = nil
        wantsPlayback = false
        isPlaybackLoading = false
        playbackLoadFailed = false
    }
}

struct CompactAudioPlaylistPlayer: View {
    let parentTweet: Tweet
    let attachments: [MimeiFileType]
    var autoPlay: Bool = false

    @State private var player: AVPlayer?
    @State private var currentIndex = 0
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var timeObserver: Any?
    @State private var cancellables = Set<AnyCancellable>()
    @State private var wantsPlayback = false
    @State private var playbackLoadFailed = false
    @State private var isPlaybackLoading = false
    @State private var lastPlaybackWarningDate = Date.distantPast
    @State private var startupTimeoutTask: Task<Void, Never>?

    private var baseUrl: URL {
        parentTweet.author?.baseUrl
            ?? HproseInstance.shared.appUser.baseUrl
            ?? HproseInstance.baseUrl
    }

    private var playableAttachments: [MimeiFileType] {
        attachments.filter { $0.type == .audio && $0.getUrl(baseUrl) != nil }
    }

    private var currentAttachment: MimeiFileType? {
        guard playableAttachments.indices.contains(currentIndex) else { return nil }
        return playableAttachments[currentIndex]
    }

    private var currentTitle: String {
        guard let attachment = currentAttachment else {
            return NSLocalizedString("Audio", comment: "Audio attachment fallback title")
        }
        return displayName(for: attachment)
    }

    var body: some View {
        if !playableAttachments.isEmpty {
            VStack(spacing: 8) {
                playlistMenu

                HStack(spacing: 10) {
                    controlButton(systemName: "backward.fill", action: playPrevious)
                        .opacity(playableAttachments.count > 1 ? 1 : 0.35)
                        .disabled(playableAttachments.count <= 1)

                    primaryControlButton

                    controlButton(systemName: "forward.fill", action: playNext)
                        .opacity(playableAttachments.count > 1 ? 1 : 0.35)
                        .disabled(playableAttachments.count <= 1)
                }

                VStack(spacing: 5) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.16))

                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.themeAccent)
                                .frame(width: proxy.size.width * CGFloat(progress))
                        }
                    }
                    .frame(height: 8)

                    HStack {
                        Text(formatTime(currentTime))
                        Spacer()
                        Text(formatTime(duration))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(UIColor.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .onAppear {
                setupPlayerIfNeeded()
            }
            .onDisappear {
                cleanupCompactPlayer()
            }
            .onChange(of: playableAttachments.map(\.mid)) { _, _ in
                if currentIndex >= playableAttachments.count {
                    currentIndex = 0
                }
                if isPlaying || autoPlay {
                    loadCurrentItem(shouldPlay: true)
                } else {
                    resetCurrentItem()
                }
            }
        }
    }

    private var playlistMenu: some View {
        Menu {
            ForEach(Array(playableAttachments.enumerated()), id: \.element.mid) { index, attachment in
                Button {
                    selectItem(index)
                } label: {
                    if index == currentIndex {
                        Label(displayName(for: attachment), systemImage: "checkmark")
                    } else {
                        Text(displayName(for: attachment))
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(currentTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if playableAttachments.count > 1 {
                    Text("\(currentIndex + 1)/\(playableAttachments.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func controlButton(systemName: String, action: @escaping () -> Void, isPrimary: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: isPrimary ? 23 : 18, weight: .semibold))
                .foregroundColor(isPrimary ? .white : .primary)
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill(isPrimary ? Color.themeAccent : Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }

    private var primaryControlButton: some View {
        Button(action: togglePlayback) {
            ZStack {
                Circle()
                    .fill(Color.themeAccent)
                    .frame(width: 48, height: 48)

                if isPlaybackLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }

    private var progress: Double {
        guard duration.isFinite, duration > 0, currentTime.isFinite else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    private func setupPlayerIfNeeded() {
        guard player == nil else { return }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("DEBUG: [COMPACT AUDIO] Failed to configure audio session: \(error)")
        }

        player = AVPlayer()
        player?.isMuted = false
        player?.volume = 1
        addTimeObserver()
        if autoPlay {
            loadCurrentItem(shouldPlay: true)
        }
    }

    private func loadCurrentItem(shouldPlay: Bool) {
        guard let player,
              let attachment = currentAttachment,
              let url = attachment.getUrl(baseUrl) else { return }

        cancellables.removeAll()
        startupTimeoutTask?.cancel()
        currentTime = 0
        duration = 0
        playbackLoadFailed = false
        wantsPlayback = shouldPlay
        isPlaybackLoading = shouldPlay
        player.isMuted = false
        player.volume = 1

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        player.replaceCurrentItem(with: item)
        observe(item: item)

        Task {
            do {
                let loadedDuration = try await item.asset.load(.duration)
                await MainActor.run {
                    guard let currentItem = player.currentItem, currentItem === item else { return }
                    if loadedDuration.isValid && !loadedDuration.isIndefinite {
                        duration = loadedDuration.seconds
                    }
                }
            } catch {
                print("DEBUG: [COMPACT AUDIO] Failed to load duration: \(error)")
                guard isAudioResourceUnavailableError(error) else { return }
                await MainActor.run {
                    guard let currentItem = player.currentItem, currentItem === item else { return }
                    startupTimeoutTask?.cancel()
                    let shouldWarn = wantsPlayback
                    playbackLoadFailed = true
                    wantsPlayback = false
                    isPlaybackLoading = false
                    isPlaying = false
                    if shouldWarn {
                        showAudioUnavailableToast()
                    }
                }
            }
        }

        if shouldPlay {
            player.isMuted = false
            player.volume = 1
            scheduleStartupTimeout(for: item)
            player.play()
            isPlaying = false
        } else {
            isPlaying = false
        }
    }

    private func observe(item: AVPlayerItem) {
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { status in
                if status == .readyToPlay {
                    startupTimeoutTask?.cancel()
                    isPlaybackLoading = false
                    if wantsPlayback {
                        isPlaying = true
                    }
                } else if status == .failed {
                    print("DEBUG: [COMPACT AUDIO] Player item failed: \(item.error?.localizedDescription ?? "Unknown error")")
                    startupTimeoutTask?.cancel()
                    let shouldWarn = wantsPlayback
                    playbackLoadFailed = true
                    wantsPlayback = false
                    isPlaybackLoading = false
                    isPlaying = false
                    if shouldWarn {
                        showAudioUnavailableToast()
                    }
                }
            }
            .store(in: &cancellables)

        item.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { newDuration in
                if newDuration.isValid && !newDuration.isIndefinite {
                    duration = newDuration.seconds
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                if playableAttachments.count > 1 {
                    playNext()
                } else {
                    isPlaying = false
                    wantsPlayback = false
                    isPlaybackLoading = false
                    currentTime = 0
                    player?.seek(to: .zero)
                }
            }
            .store(in: &cancellables)
    }

    private func addTimeObserver() {
        guard let player else { return }
        let interval = CMTime(seconds: 0.2, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            currentTime = time.seconds.isFinite ? time.seconds : 0
        }
    }

    private func togglePlayback() {
        setupPlayerIfNeeded()
        guard let player else { return }

        if isPlaying {
            player.pause()
            startupTimeoutTask?.cancel()
            isPlaybackLoading = false
            isPlaying = false
            wantsPlayback = false
        } else {
            if playbackLoadFailed || player.currentItem == nil || player.currentItem?.status == .failed {
                loadCurrentItem(shouldPlay: true)
                return
            }

            wantsPlayback = true
            isPlaybackLoading = true
            player.isMuted = false
            player.volume = 1
            scheduleStartupTimeout(for: player.currentItem)
            player.play()
            isPlaying = false
        }
    }

    private func scheduleStartupTimeout(for item: AVPlayerItem?) {
        startupTimeoutTask?.cancel()
        guard let item else { return }

        startupTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: audioPlaybackStartupTimeoutNanoseconds)
            guard !Task.isCancelled,
                  self.wantsPlayback,
                  self.player?.currentItem === item,
                  item.status != .readyToPlay,
                  self.player?.timeControlStatus != .playing else { return }

            print("DEBUG: [COMPACT AUDIO] Playback startup timed out")
            self.playbackLoadFailed = true
            self.wantsPlayback = false
            self.isPlaybackLoading = false
            self.isPlaying = false
            self.player?.pause()
            self.player?.replaceCurrentItem(with: nil)
            self.showAudioUnavailableToast()
        }
    }

    private func selectItem(_ index: Int, shouldPlay: Bool = false) {
        guard playableAttachments.indices.contains(index) else { return }
        currentIndex = index
        if shouldPlay {
            loadCurrentItem(shouldPlay: true)
        } else {
            resetCurrentItem()
        }
    }

    private func resetCurrentItem() {
        startupTimeoutTask?.cancel()
        cancellables.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        currentTime = 0
        duration = 0
        isPlaying = false
        wantsPlayback = false
        isPlaybackLoading = false
        playbackLoadFailed = false
    }

    private func playPrevious() {
        guard playableAttachments.count > 1 else { return }
        let nextIndex = (currentIndex - 1 + playableAttachments.count) % playableAttachments.count
        selectItem(nextIndex, shouldPlay: true)
    }

    private func playNext() {
        guard playableAttachments.count > 1 else { return }
        let nextIndex = (currentIndex + 1) % playableAttachments.count
        selectItem(nextIndex, shouldPlay: true)
    }

    private func cleanupCompactPlayer() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        cancellables.removeAll()
        isPlaying = false
        wantsPlayback = false
        isPlaybackLoading = false
        playbackLoadFailed = false
    }

    private func showAudioUnavailableToast() {
        let now = Date()
        guard now.timeIntervalSince(lastPlaybackWarningDate) > 1 else { return }
        lastPlaybackWarningDate = now

        NotificationCenter.default.post(
            name: .audioPlaybackWarning,
            object: nil,
            userInfo: [
                "message": NSLocalizedString("This audio is not available.", comment: "Audio playback unavailable warning")
            ]
        )
    }

    private func displayName(for attachment: MimeiFileType) -> String {
        if let fileName = attachment.fileName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fileName.isEmpty {
            return fileName
        }
        return NSLocalizedString("Audio", comment: "Audio attachment fallback title")
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
