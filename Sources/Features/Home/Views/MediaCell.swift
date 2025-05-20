//
//  MediaCell.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI
import AVKit

struct MediaCell: View {
    let attachment: MimeiFileType
    let baseUrl: String
    var play: Bool = false // default false, set true for the first video

    var body: some View {
        if attachment.type.lowercased() == "video", let url = attachment.getUrl(baseUrl) {
            VideoPlayerWrapper(
                url: url,
                fileName: attachment.fileName,
                mimeType: attachment.type,
                play: play
            )
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

struct VideoPlayerWrapper: View {
    let url: URL
    let fileName: String?
    let mimeType: String?
    var play: Bool

    @State private var localUrl: URL?
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let localUrl = localUrl {
                VideoPlayer(player: player)
                    .onAppear {
                        if player == nil {
                            player = AVPlayer(url: localUrl)
                        }
                        if play {
                            player?.play()
                        }
                    }
                    .onDisappear {
                        player?.pause()
                        player = nil
                    }
            } else {
                ProgressView()
                    .onAppear {
                        downloadToTempIfNeeded()
                    }
            }
        }
        .clipped()
    }

    private func downloadToTempIfNeeded() {
        // If the URL has an extension, use it directly
        if !url.pathExtension.isEmpty {
            DispatchQueue.main.async {
                localUrl = url
            }
            return
        }
        // Otherwise, download and save as .mp4
        let ext = "mp4" // or guess from mimeType/fileName
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
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
