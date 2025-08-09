//
//  NewMediaGridView.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  New simplified media grid using the new video architecture
//

import SwiftUI
import AVKit

/// New simplified media grid view using the new video architecture
struct NewMediaGridView: View {
    let parentTweet: Tweet
    let attachments: [MimeiFileType]
    let onItemTap: ((Int) -> Void)?
    
    @StateObject private var gridVideoContext = GridVideoContext()
    @State private var isVisible = false
    
    init(parentTweet: Tweet, attachments: [MimeiFileType], onItemTap: ((Int) -> Void)? = nil) {
        self.parentTweet = parentTweet
        self.attachments = attachments
        self.onItemTap = onItemTap
    }
    
    var body: some View {
        GeometryReader { geometry in
            let gridWidth: CGFloat = max(geometry.size.width, 1)
            let aspectRatio = calculateAspectRatio(for: attachments)
            let gridHeight = max(gridWidth / aspectRatio, 1)
            
            ZStack {
                switch attachments.count {
                case 1:
                    singleMediaView(attachment: attachments[0], width: gridWidth, height: gridHeight)
                case 2:
                    twoMediaLayout(width: gridWidth, height: gridHeight)
                case 3:
                    threeMediaLayout(width: gridWidth, height: gridHeight)
                case 4:
                    fourMediaLayout(width: gridWidth, height: gridHeight)
                default:
                    fourPlusMediaLayout(width: gridWidth, height: gridHeight)
                }
            }
            .frame(width: gridWidth, height: gridHeight)
            .clipped()
        }
        .onAppear {
            isVisible = true
            setupVideoPlayback()
        }
        .onDisappear {
            isVisible = false
            stopVideoPlayback()
        }
        .onReceive(MuteState.shared.$isMuted) { isMuted in
            gridVideoContext.updateMuteState(isMuted)
        }
    }
    
    // MARK: - Layout Components
    
    private func singleMediaView(attachment: MimeiFileType, width: CGFloat, height: CGFloat) -> some View {
        GridMediaView(
            attachment: attachment,
            parentTweet: parentTweet,
            aspectRatio: CGFloat(attachment.aspectRatio ?? 1.0),
            onVideoFinished: { handleVideoFinished(attachment.mid) },
            onTap: { onItemTap?(0) },
            shouldLoadVideo: true,
            showMuteButton: true,
            context: gridVideoContext
        )
        .frame(width: width, height: height)
        .clipped()
    }
    
    private func twoMediaLayout(width: CGFloat, height: CGFloat) -> some View {
        let isFirstPortrait = (attachments[0].aspectRatio ?? 1.0) < 1.0
        
        return Group {
            if isFirstPortrait {
                // Portrait layout: vertical stack
                VStack(spacing: 2) {
                    ForEach(0..<2, id: \.self) { index in
                        createMediaView(index: index, width: width, height: height/2 - 1)
                    }
                }
            } else {
                // Landscape layout: horizontal stack
                HStack(spacing: 2) {
                    ForEach(0..<2, id: \.self) { index in
                        createMediaView(index: index, width: width/2 - 1, height: height)
                    }
                }
            }
        }
    }
    
    private func threeMediaLayout(width: CGFloat, height: CGFloat) -> some View {
        let isFirstPortrait = (attachments[0].aspectRatio ?? 1.0) < 1.0
        
        return Group {
            if isFirstPortrait {
                // Portrait first: left column tall, right column two stacked
                HStack(spacing: 2) {
                    createMediaView(index: 0, width: width/2 - 1, height: height)
                    
                    VStack(spacing: 2) {
                        ForEach(1..<3, id: \.self) { index in
                            createMediaView(index: index, width: width/2 - 1, height: height/2 - 1)
                        }
                    }
                }
            } else {
                // Landscape first: top row wide, bottom row two images
                VStack(spacing: 2) {
                    createMediaView(index: 0, width: width, height: height * 0.618) // Golden ratio
                    
                    HStack(spacing: 2) {
                        ForEach(1..<3, id: \.self) { index in
                            createMediaView(index: index, width: width/2 - 1, height: height * 0.382 - 1)
                        }
                    }
                }
            }
        }
    }
    
    private func fourMediaLayout(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(0..<2, id: \.self) { index in
                    createMediaView(index: index, width: width/2 - 1, height: height/2 - 1)
                }
            }
            HStack(spacing: 2) {
                ForEach(2..<4, id: \.self) { index in
                    createMediaView(index: index, width: width/2 - 1, height: height/2 - 1)
                }
            }
        }
    }
    
    private func fourPlusMediaLayout(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(0..<2, id: \.self) { index in
                    createMediaView(index: index, width: width/2 - 1, height: height/2 - 1)
                }
            }
            HStack(spacing: 2) {
                createMediaView(index: 2, width: width/2 - 1, height: height/2 - 1)
                
                // Last cell with overlay for remaining count
                ZStack {
                    createMediaView(index: 3, width: width/2 - 1, height: height/2 - 1)
                    
                    if attachments.count > 4 {
                        Color.black.opacity(0.6)
                            .overlay(
                                Text("+\(attachments.count - 4)")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                            )
                    }
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func createMediaView(index: Int, width: CGFloat, height: CGFloat) -> some View {
        GridMediaView(
            attachment: attachments[index],
            parentTweet: parentTweet,
            aspectRatio: CGFloat(attachments[index].aspectRatio ?? 1.0),
            onVideoFinished: { handleVideoFinished(attachments[index].mid) },
            onTap: { onItemTap?(index) },
            shouldLoadVideo: true,
            showMuteButton: true,
            context: gridVideoContext
        )
        .frame(width: width, height: height)
        .clipped()
        .contentShape(Rectangle())
    }
    
    private func calculateAspectRatio(for attachments: [MimeiFileType]) -> CGFloat {
        // Simplified aspect ratio calculation based on attachment count and types
        switch attachments.count {
        case 1:
            return CGFloat(attachments[0].aspectRatio ?? 1.0)
        case 2:
            let isFirstPortrait = (attachments[0].aspectRatio ?? 1.0) < 1.0
            return isFirstPortrait ? 1.0 : 2.0
        case 3:
            return 1.618 // Golden ratio
        default:
            return 1.0 // Square for 4+ items
        }
    }
    
    private func setupVideoPlayback() {
        // Get all video attachments
        let videoMids = attachments.compactMap { attachment in
            if attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video" {
                return attachment.mid
            }
            return nil
        }
        
        guard !videoMids.isEmpty else { return }
        
        print("DEBUG: [NEW MEDIA GRID] Setting up playback for \(videoMids.count) videos")
        
        // Setup sequential playback
        gridVideoContext.setupSequentialPlayback(for: videoMids)
        
        // Mark all videos as visible
        for mid in videoMids {
            gridVideoContext.setVideoVisible(mid, isVisible: true)
        }
    }
    
    private func stopVideoPlayback() {
        // Get all video attachments
        let videoMids = attachments.compactMap { attachment in
            if attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video" {
                return attachment.mid
            }
            return nil
        }
        
        print("DEBUG: [NEW MEDIA GRID] Stopping playback for \(videoMids.count) videos")
        
        // Stop sequential playback
        gridVideoContext.stopSequentialPlayback()
        
        // Mark all videos as not visible
        for mid in videoMids {
            gridVideoContext.setVideoVisible(mid, isVisible: false)
        }
    }
    
    private func handleVideoFinished(_ videoMid: String) {
        print("DEBUG: [NEW MEDIA GRID] Video finished: \(videoMid)")
        // GridVideoContext automatically handles sequential playback
    }
}

// MARK: - Preview
struct NewMediaGridView_Previews: PreviewProvider {
    static var previews: some View {
        let sampleTweet = Tweet(mid: "sample", authorId: "author")
        let sampleAttachments = [
            MimeiFileType(mid: "video1", type: "video"),
            MimeiFileType(mid: "image1", type: "image")
        ]
        
        NewMediaGridView(
            parentTweet: sampleTweet,
            attachments: sampleAttachments
        ) { index in
            print("Tapped item \(index)")
        }
        .frame(width: 300, height: 200)
        .padding()
    }
}
