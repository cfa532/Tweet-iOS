//
//  MediaCell.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI
import AVKit
import CryptoKit

struct MediaCell: View {
    let attachment: MimeiFileType
    let baseUrl: String
    var play: Bool = false

    var body: some View {
        if attachment.type.lowercased() == "video", let url = attachment.getUrl(baseUrl) {
            VideoPlayerCacheView(url: url, play: play)
        } else {
            AsyncImage(url: attachment.getUrl(baseUrl)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.gray
            }
            .clipped()
        }
    }
}

struct VideoPlayerCacheView: View {
    let url: URL
    var play: Bool

    @State private var localUrl: URL?
    @State private var player: AVPlayer?
    @State private var isPlaying: Bool = false
    @State private var isMuted: Bool = PreferenceHelper().getSpeakerMute()
    @State private var isVisible: Bool = false
    private let preferenceHelper = PreferenceHelper()

    var body: some View {
        Group {
            if let localUrl = localUrl {
                ZStack {
                    VideoPlayer(player: player)
                        .onAppear {
                            if player == nil {
                                player = AVPlayer(url: localUrl)
                                player?.isMuted = isMuted
                            }
                            handlePlayback()
                        }
                        .onDisappear {
                            player?.pause()
                            player = nil
                            isPlaying = false
                        }
                        .clipped()
                        .onVisibilityChanged { visible in
                            isVisible = visible
                            handlePlayback()
                        }
                    HStack(spacing: 20) {
                        Button(action: {
                            if isPlaying {
                                player?.pause()
                            } else {
                                player?.play()
                            }
                            isPlaying.toggle()
                        }) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .foregroundColor(.white)
                                .padding()
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        Button(action: {
                            isMuted.toggle()
                            player?.isMuted = isMuted
                            preferenceHelper.setSpeakerMute(isMuted)
                        }) {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .foregroundColor(.white)
                                .padding()
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            } else {
                ProgressView()
                    .onAppear {
                        cacheOrDownloadVideo()
                    }
            }
        }
        .clipped()
    }

    private func handlePlayback() {
        if isVisible && play {
            player?.play()
            isPlaying = true
        } else {
            player?.pause()
            isPlaying = false
        }
    }

    private func cacheOrDownloadVideo() {
        let cacheKey = url.lastPathComponent
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(cacheKey)
        if FileManager.default.fileExists(atPath: tempFile.path) {
            localUrl = tempFile
            return
        }
        let task = URLSession.shared.downloadTask(with: url) { tempUrl, response, error in
            guard let tempUrl = tempUrl else { return }
            do {
                try FileManager.default.moveItem(at: tempUrl, to: tempFile)
                DispatchQueue.main.async {
                    localUrl = tempFile
                }
            } catch {
                print("Failed to move video file: \(error)")
            }
        }
        task.resume()
    }
}

// ViewModifier to detect visibility
struct VisibilityModifier: ViewModifier {
    let onChange: (Bool) -> Void
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .background(
                    Color.clear
                        .preference(key: VisibilityPreferenceKey.self, value: geometry.frame(in: .global))
                )
        }
        .onPreferenceChange(VisibilityPreferenceKey.self) { frame in
            let screen = UIScreen.main.bounds
            let isVisible = screen.intersects(frame)
            onChange(isVisible)
        }
    }
}

struct VisibilityPreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

extension View {
    func onVisibilityChanged(_ perform: @escaping (Bool) -> Void) -> some View {
        self.modifier(VisibilityModifier(onChange: perform))
    }
}
