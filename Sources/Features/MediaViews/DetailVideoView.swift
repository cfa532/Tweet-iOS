//
//  DetailVideoView.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  Independent video player for detail views using new architecture
//

import SwiftUI
import AVKit

/// Independent video player view for detail contexts
/// Uses DetailVideoContext + VideoAssetCache for conflict-free playback
struct DetailVideoView: View {
    let videoMid: String
    let url: URL
    let contentType: String
    let aspectRatio: CGFloat
    let isSelected: Bool
    
    @ObservedObject var context: DetailVideoContext
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var showControls = false
    
    var body: some View {
        Group {
            if let player = player {
                VideoPlayer(player: player)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .onTapGesture {
                        // Toggle play/pause on tap
                        context.togglePlayback(for: videoMid)
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
                    .aspectRatio(aspectRatio, contentMode: .fit)
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
            // Set initial selection state after player is created
            await MainActor.run {
                context.setVideoSelected(videoMid, isSelected: isSelected)
            }
        }
        .onDisappear {
            // Clean up when view disappears
            context.setVideoSelected(videoMid, isSelected: false)
        }
        .onChange(of: isSelected) { newIsSelected in
            // Handle selection changes from TabView
            context.setVideoSelected(videoMid, isSelected: newIsSelected)
        }
    }
    
    private func createPlayer() async {
        guard player == nil else { return }
        
        print("DEBUG: [DETAIL VIDEO VIEW] Creating player for: \(videoMid)")
        
        if let newPlayer = await context.getPlayer(for: videoMid, url: url, contentType: contentType) {
            await MainActor.run {
                self.player = newPlayer
                print("DEBUG: [DETAIL VIDEO VIEW] Player created for: \(videoMid)")
            }
        } else {
            print("ERROR: [DETAIL VIDEO VIEW] Failed to create player for: \(videoMid)")
        }
    }
}

// MARK: - DetailMediaView (Handles both images and videos)

/// Media view that handles both images and videos for detail contexts
struct DetailMediaView: View {
    let attachment: MimeiFileType
    let parentTweet: Tweet
    let isSelected: Bool
    let aspectRatio: CGFloat
    let onImageTap: () -> Void
    
    @ObservedObject var context: DetailVideoContext
    @State private var image: UIImage?
    @State private var loading = false
    
    private var baseUrl: URL {
        return parentTweet.author?.baseUrl ?? HproseInstance.baseUrl
    }
    
    var body: some View {
        Group {
            if let url = attachment.getUrl(baseUrl) {
                switch attachment.type.lowercased() {
                case "video", "hls_video":
                    DetailVideoView(
                        videoMid: attachment.mid,
                        url: url,
                        contentType: attachment.type,
                        aspectRatio: aspectRatio,
                        isSelected: isSelected,
                        context: context
                    )
                    .overlay(
                        // Mute button overlay for videos
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                DetailMuteButton(
                                    videoMid: attachment.mid,
                                    context: context
                                )
                                .padding(.trailing, 12)
                                .padding(.bottom, 12)
                            }
                        }
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
                        onImageTap()
                    }
                    .onAppear {
                        if image == nil && !loading {
                            loadImage()
                        }
                    }
                    
                default:
                    Color.gray.opacity(0.2)
                        .aspectRatio(aspectRatio, contentMode: .fit)
                }
            } else {
                Color.gray.opacity(0.2)
                    .aspectRatio(aspectRatio, contentMode: .fit)
            }
        }
        .background(Color.black)
    }
    
    private func loadImage() {
        guard let url = attachment.getUrl(baseUrl) else { return }
        
        loading = true
        
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                
                await MainActor.run {
                    self.image = UIImage(data: data)
                    self.loading = false
                }
            } catch {
                print("ERROR: [DETAIL MEDIA VIEW] Failed to load image: \(error)")
                await MainActor.run {
                    self.loading = false
                }
            }
        }
    }
}

// MARK: - DetailMuteButton (Independent mute button for detail views)

/// Independent mute button for detail view videos
struct DetailMuteButton: View {
    let videoMid: String
    @ObservedObject var context: DetailVideoContext
    
    var body: some View {
        Button(action: {
            context.toggleMute(for: videoMid)
        }) {
            Image(systemName: context.isMuted(for: videoMid) ? "speaker.slash.fill" : "speaker.2.fill")
                .foregroundColor(.white)
                .font(.title2)
                .padding(8)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.6))
                )
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 16.0, *)
struct DetailVideoView_Previews: PreviewProvider {
    static var previews: some View {
        let context = DetailVideoContext()
        let sampleURL = URL(string: "https://example.com/video.mp4")!
        
        DetailVideoView(
            videoMid: "sample_video",
            url: sampleURL,
            contentType: "video",
            aspectRatio: 16.0/9.0,
            isSelected: true,
            context: context
        )
        .frame(height: 200)
        .previewLayout(.sizeThatFits)
    }
}
#endif
