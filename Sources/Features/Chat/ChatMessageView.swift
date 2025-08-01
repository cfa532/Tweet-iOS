import SwiftUI
import AVFoundation

// MARK: - Chat Media Components

struct ChatMediaPreviewGrid: View {
    let attachments: [MimeiFileType]
    let isFromCurrentUser: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(attachments, id: \.id) { attachment in
                ChatMediaItemView(
                    attachment: attachment,
                    isFromCurrentUser: isFromCurrentUser
                )
            }
        }
    }
}

struct ChatMediaItemView: View {
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
                    ChatVideoPlayer(
                        url: url,
                        mid: attachment.mid,
                        aspectRatio: attachment.aspectRatio ?? 1.0
                    )
                    .onTapGesture(count: 2) {
                        showFullScreen = true
                    }
                    
                case "image":
                    if let image = image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipped()
                            .onTapGesture(count: 2) {
                                showFullScreen = true
                            }
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
                    
                default:
                    // File attachment
                    HStack {
                        Image(systemName: getAttachmentIcon(for: attachment.type))
                            .font(.system(size: 24))
                            .foregroundColor(.blue)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.fileName ?? "Attachment")
                                .font(.caption)
                                .foregroundColor(.primary)
                            
                            if let size = attachment.size {
                                Text(formatFileSize(size))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Spacer()
                    }
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
            } else {
                // Placeholder when no URL
                Color.gray.opacity(0.3)
                    .overlay(
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.gray)
                    )
            }
        }
        .frame(maxWidth: 200, maxHeight: 200)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            await loadImageIfNeeded()
        }
        .sheet(isPresented: $showFullScreen) {
            if let url = attachment.getUrl(baseUrl) {
                ChatMediaBrowserView(
                    attachments: [attachment],
                    initialIndex: 0,
                    baseUrl: baseUrl
                )
            }
        }
    }
    
    private func loadImageIfNeeded() async {
        guard attachment.type.lowercased().contains("image"),
              let url = attachment.getUrl(baseUrl) else { return }
        
        isLoading = true
        
        do {
            if let cachedImage = imageCache.getImage(for: url.absoluteString) {
                await MainActor.run {
                    self.image = cachedImage
                    self.isLoading = false
                }
            } else {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let downloadedImage = UIImage(data: data) {
                    imageCache.setImage(downloadedImage, for: url.absoluteString)
                    await MainActor.run {
                        self.image = downloadedImage
                        self.isLoading = false
                    }
                }
            }
        } catch {
            print("[ChatMediaItemView] Error loading image: \(error)")
            await MainActor.run {
                self.isLoading = false
            }
        }
    }
    
    private func getAttachmentIcon(for type: String) -> String {
        switch type.lowercased() {
        case "image", "jpg", "jpeg", "png", "gif", "webp":
            return "photo"
        case "video", "mp4", "mov", "avi":
            return "video"
        case "audio", "mp3", "wav", "m4a":
            return "music.note"
        case "document", "pdf", "doc", "docx":
            return "doc.text"
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

struct ChatVideoPlayer: View {
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
                    .aspectRatio(contentMode: .fill)
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
    }
}

struct ChatMediaBrowserView: View {
    let attachments: [MimeiFileType]
    let initialIndex: Int
    let baseUrl: URL
    
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    
    init(attachments: [MimeiFileType], initialIndex: Int, baseUrl: URL) {
        self.attachments = attachments
        self.initialIndex = initialIndex
        self.baseUrl = baseUrl
        self._currentIndex = State(initialValue: initialIndex)
    }
    
    var body: some View {
        NavigationView {
            TabView(selection: $currentIndex) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                    ChatMediaItemView(
                        attachment: attachment,
                        isFromCurrentUser: false
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .automatic))
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