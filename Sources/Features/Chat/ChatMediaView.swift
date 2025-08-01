import SwiftUI
import AVFoundation

struct ChatMediaView: View {
    let attachment: MimeiFileType
    let isFromCurrentUser: Bool
    
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var showFullScreen = false
    
    private let imageCache = ImageCacheManager.shared
    private let baseUrl = HproseInstance.baseUrl
    
    var body: some View {
        Group {
            if let url = attachment.getUrl(baseUrl) {
                switch attachment.type.lowercased() {
                case "video", "hls_video":
                    ChatVideoView(url: url, mid: attachment.mid, aspectRatio: attachment.aspectRatio ?? 16.0/9.0)
                        .onTapGesture(count: 2) {
                            showFullScreen = true
                        }
                    
                case "image":
                    ChatImageView(
                        url: url,
                        image: image,
                        isLoading: isLoading,
                        aspectRatio: attachment.aspectRatio ?? 1.0
                    )
                    .onTapGesture(count: 2) {
                        showFullScreen = true
                    }
                    .task {
                        await loadImage()
                    }
                    
                case "audio":
                    ChatAudioView(url: url, fileName: attachment.fileName ?? "Audio")
                    
                default:
                    ChatFileView(attachment: attachment)
                }
            } else {
                // Placeholder when no URL
                ChatPlaceholderView(type: attachment.type)
            }
        }
        .frame(maxWidth: UIScreen.main.bounds.width * 0.7)
        .sheet(isPresented: $showFullScreen) {
            if let url = attachment.getUrl(baseUrl) {
                ChatFullScreenView(url: url, type: attachment.type)
            }
        }
    }
    
    private func loadImage() async {
        guard !isLoading else { return }
        
        isLoading = true
        
        // Try to get cached image first
        if let cachedImage = imageCache.getCompressedImage(for: attachment, baseUrl: baseUrl) {
            await MainActor.run {
                self.image = cachedImage
                self.isLoading = false
            }
        } else if let url = attachment.getUrl(baseUrl) {
            // Load and cache the image
            if let loadedImage = await imageCache.loadAndCacheImage(from: url, for: attachment, baseUrl: baseUrl) {
                await MainActor.run {
                    self.image = loadedImage
                    self.isLoading = false
                }
            } else {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - Individual Media Components

struct ChatImageView: View {
    let url: URL
    let image: UIImage?
    let isLoading: Bool
    let aspectRatio: Float
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipped()
            } else if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.gray.opacity(0.3)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.gray)
                    )
            }
        }
        .aspectRatio(CGFloat(aspectRatio), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ChatVideoView: View {
    let url: URL
    let mid: String
    let aspectRatio: Float
    
    @State private var shouldLoadVideo = false
    @State private var play = false
    
    var body: some View {
        Group {
            if shouldLoadVideo {
                SimpleVideoPlayer(
                    url: url,
                    mid: mid,
                    autoPlay: play,
                    onVideoFinished: nil,
                    isVisible: true,
                    contentType: "video",
                    cellAspectRatio: CGFloat(aspectRatio),
                    videoAspectRatio: CGFloat(aspectRatio),
                    showNativeControls: true,
                    showCustomControls: false
                )
                .environmentObject(MuteState.shared)
            } else {
                // Placeholder for videos that haven't been loaded yet
                Color.black
                    .aspectRatio(CGFloat(aspectRatio), contentMode: .fit)
                    .overlay(
                        Image(systemName: "play.circle")
                            .font(.system(size: 40))
                            .foregroundColor(.white)
                    )
                    .onTapGesture {
                        shouldLoadVideo = true
                        play = true
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ChatAudioView: View {
    let url: URL
    let fileName: String
    
    @State private var isPlaying = false
    @State private var audioPlayer: AVAudioPlayer?
    
    var body: some View {
        HStack(spacing: 12) {
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                Text("Audio File")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
        .onDisappear {
            stopAudio()
        }
    }
    
    private func togglePlayback() {
        if isPlaying {
            stopAudio()
        } else {
            playAudio()
        }
    }
    
    private func playAudio() {
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                audioPlayer = try AVAudioPlayer(data: data)
                audioPlayer?.delegate = AudioPlayerDelegate(isPlaying: $isPlaying)
                audioPlayer?.play()
                await MainActor.run {
                    isPlaying = true
                }
            } catch {
                print("Error playing audio: \(error)")
            }
        }
    }
    
    private func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
    }
}

struct ChatFileView: View {
    let attachment: MimeiFileType
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: getFileIcon(for: attachment.type))
                .font(.system(size: 24))
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName ?? "File")
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                if let size = attachment.size {
                    Text(formatFileSize(size))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
    
    private func getFileIcon(for type: String) -> String {
        switch type.lowercased() {
        case "pdf":
            return "doc.text"
        case "doc", "docx":
            return "doc.richtext"
        case "xls", "xlsx":
            return "chart.bar.doc.horizontal"
        case "ppt", "pptx":
            return "chart.bar"
        case "txt":
            return "doc.plaintext"
        default:
            return "paperclip"
        }
    }
    
    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

struct ChatPlaceholderView: View {
    let type: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundColor(.orange)
            
            Text("Unable to load \(type)")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

struct ChatFullScreenView: View {
    let url: URL
    let type: String
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Group {
                if type.lowercased().contains("image") {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } placeholder: {
                        ProgressView()
                    }
                } else if type.lowercased().contains("video") {
                    SimpleVideoPlayer(
                        url: url,
                        mid: "",
                        autoPlay: true,
                        onVideoFinished: nil,
                        isVisible: true,
                        contentType: "video",
                        cellAspectRatio: 16.0/9.0,
                        videoAspectRatio: 16.0/9.0,
                        showNativeControls: true,
                        showCustomControls: false
                    )
                    .environmentObject(MuteState.shared)
                } else {
                    Text("Full screen not supported for this file type")
                        .foregroundColor(.secondary)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Audio Player Delegate

class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    @Binding var isPlaying: Bool
    
    init(isPlaying: Binding<Bool>) {
        self._isPlaying = isPlaying
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
    }
} 