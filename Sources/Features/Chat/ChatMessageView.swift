//
//  ChatMessageView.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/6/27.
//

import SwiftUI
import AVKit
import SDWebImageSwiftUI
import QuickLook

// MARK: - Chat Message View

struct ChatMessageView: View {
    let message: ChatMessage
    let isFromCurrentUser: Bool
    let isLastMessage: Bool
    let isLastFromSender: Bool
    let showTimestamp: Bool
    let isChatScreenVisible: Bool
    let onResendMessage: ((ChatMessage) -> Void)?
    @State private var receiptUser: User?
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !isFromCurrentUser {
                // Avatar for received messages (LEFT) - use receipt's avatar
                if let receiptUser = receiptUser {
                    Avatar(user: receiptUser, size: 36)
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "person")
                                .foregroundColor(.gray)
                        )
                }
            }
            
            // Message content
            VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: 4) {
                // Row 1: Message text (if any)
                if let content = message.content, !content.isEmpty {
                    HStack(spacing: 4) {
                        Text(content)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                isFromCurrentUser ? Color.blue : Color(.systemGray5)
                            )
                            .foregroundColor(
                                isFromCurrentUser ? .white : .primary
                            )
                            .clipShape(isLastFromSender ? AnyShape(ChatBubbleShape(isFromCurrentUser: isFromCurrentUser)) : AnyShape(RoundedRectangle(cornerRadius: 12)))
                        
                        // Show failure icon for sent messages that failed
                        if isFromCurrentUser && message.success == false {
                            Button(action: {
                                onResendMessage?(message)
                            }) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.system(size: 16))
                            }
                            .help(message.errorMsg ?? "Message failed to send")
                        }
                    }
                }
                
                // Row 2: Attachments
                if let attachments = message.attachments, !attachments.isEmpty {
                    HStack(spacing: 4) {
                        if attachments.count == 1, let attachment = attachments.first {
                            // Single attachment
                            if attachment.type == .image {
                                ChatImageThumbnail(
                                    attachment: attachment, 
                                    isFromCurrentUser: isFromCurrentUser,
                                    senderUser: isFromCurrentUser ? HproseInstance.shared.appUser : receiptUser
                                )
                            } else if attachment.type == .video || attachment.type == .hls_video {
                                ChatVideoPlayer(
                                    attachment: attachment, 
                                    isFromCurrentUser: isFromCurrentUser,
                                    senderUser: isFromCurrentUser ? HproseInstance.shared.appUser : receiptUser,
                                    isChatScreenVisible: isChatScreenVisible
                                )
                            } else {
                                // Document attachments - use DocumentAttachmentsView
                                let documentAttachments = [attachment]
                                let baseUrl = isFromCurrentUser 
                                    ? (HproseInstance.shared.appUser.baseUrl ?? HproseInstance.baseUrl)
                                    : (receiptUser?.baseUrl ?? HproseInstance.baseUrl)
                                DocumentAttachmentsView(
                                    documents: documentAttachments,
                                    baseUrl: baseUrl,
                                    maxDocuments: nil
                                )
                            }
                        } else {
                            // Multiple attachments
                            ChatMultipleAttachmentsLoader(attachments: attachments, isFromCurrentUser: isFromCurrentUser)
                        }
                        
                        // Show failure icon for sent messages with attachments that failed
                        if isFromCurrentUser && message.success == false {
                            Button(action: {
                                onResendMessage?(message)
                            }) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.system(size: 16))
                            }
                            .help(message.errorMsg ?? "Message failed to send")
                        }
                    }
                    .frame(maxWidth: 280, alignment: .leading)
                    .clipped()
                    .contentShape(Rectangle())
                }
                
                // Timestamp - show for last message from each party
                if showTimestamp {
                    Text(formatTime(message.timestamp))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: isFromCurrentUser ? .trailing : .leading)
            
            if isFromCurrentUser {
                // Avatar for sent messages (RIGHT)
                Avatar(user: HproseInstance.shared.appUser, size: 36)
            }
        }
        .task {
            if !isFromCurrentUser {
                // Load receipt user for received messages
                receiptUser = try? await HproseInstance.shared.fetchUser(message.authorId)
            }
        }
    }
    
    private func formatTime(_ timestamp: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Attachment View

struct AttachmentView: View {
    let attachment: MimeiFileType
    let isFromCurrentUser: Bool
    let isLastMessage: Bool
    let isLastFromSender: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Attachment preview
            if attachment.type == .image {
                // Image preview
                if let url = attachment.url, let imageUrl = URL(string: url) {
                    AsyncImage(url: imageUrl) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 200, maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 200, height: 150)
                            .overlay(
                                ProgressView()
                            )
                    }
                } else {
                    // Placeholder for image
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 200, height: 150)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(.gray)
                        )
                }
            } else {
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
                .padding(12)
                .background(Color(.systemGray6))
                .cornerRadius(8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isFromCurrentUser ? Color.blue.opacity(0.1) : Color(.systemGray6)
        )
        .clipShape(isLastFromSender ? AnyShape(ChatBubbleShape(isFromCurrentUser: isFromCurrentUser)) : AnyShape(RoundedRectangle(cornerRadius: 12)))
    }
    
    private func getAttachmentIcon(for type: MediaType) -> String {
        switch type {
        case .image:
            return "photo"
        case .video, .hls_video:
            return "video"
        case .audio:
            return "music.note"
        case .pdf, .word, .excel, .ppt:
            return "doc.text"
        case .zip, .txt, .html:
            return "paperclip"
        case .unknown:
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

// MARK: - Chat Image Thumbnail

struct ChatImageThumbnail: View {
    let attachment: MimeiFileType
    let isFromCurrentUser: Bool
    let senderUser: User?
    
    @State private var showFullScreen = false
    @State private var image: UIImage?
    @State private var isLoading = false
    
    private var baseUrl: URL {
        if isFromCurrentUser {
            // For messages sent by current user, use app user's baseUrl
            return HproseInstance.shared.appUser.baseUrl ?? HproseInstance.baseUrl
        } else {
            // For messages received from other users, use sender's baseUrl
            return senderUser?.baseUrl ?? HproseInstance.baseUrl
        }
    }
    
    var body: some View {
        Group {
            if attachment.getUrl(baseUrl) != nil {
                chatImageThumbnail()
            } else {
                chatImageFallback
            }
        }
        .onAppear {
            // Load image if not already loaded
            if image == nil {
                loadImage()
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            // Use MediaBrowserView for full-screen viewing (same as MediaCell)
            if attachment.getUrl(baseUrl) != nil {
                // Create a mock Tweet for MediaBrowserView
                let mockTweet = createMockTweet(for: attachment)
                MediaBrowserView(
                    tweet: mockTweet,
                    initialIndex: 0
                )
            }
        }
    }
    
    @ViewBuilder
    private func chatImageThumbnail() -> some View {
        let maxWidth = UIScreen.main.bounds.width * 0.7
        let maxHeight = maxWidth * 1.1 // Standard height for chat images
        
        // Use the same approach as MediaCell
        if let image = image {
            // Show loaded image
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture {
                    showFullScreen = true
                }
        } else if isLoading {
            // Show loading state with cached placeholder
            if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: attachment) {
                Image(uiImage: cachedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                            .background(Color.gray.opacity(0.3))
                            .clipShape(Circle())
                            .padding(4),
                        alignment: .topTrailing
                    )
                    .onTapGesture {
                        showFullScreen = true
                    }
            } else {
                // Show loading placeholder
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(1.2)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .background(Color(.systemGray6).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture {
                        showFullScreen = true
                    }
            }
        } else {
            // Show cached placeholder if available, otherwise fallback
            if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: attachment) {
                Image(uiImage: cachedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture {
                        showFullScreen = true
                    }
            } else {
                // Show fallback placeholder
                Color(.systemGray6)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.system(size: 24))
                                .foregroundColor(.gray)
                            Text(NSLocalizedString("Image", comment: "Image placeholder text"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    )
                    .onTapGesture {
                        showFullScreen = true
                    }
            }
        }
    }
    
    @ViewBuilder
    private var chatImageFallback: some View {
        let aspectRatio = CGFloat(max(attachment.aspectRatio ?? 1.0, 0.8))
        let maxWidth = UIScreen.main.bounds.width * 0.7
        
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(.systemGray6))
            .frame(maxWidth: maxWidth)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 24))
                        .foregroundColor(.gray)
                    Text(NSLocalizedString("Image", comment: "Image placeholder text"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            )
    }
    

    
    private func loadImage() {
        guard let url = attachment.getUrl(baseUrl) else { return }
        
        // First, try to get cached image immediately
        if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: attachment) {
            self.image = cachedImage
            return
        }
        
        // If no cached image, start loading
        isLoading = true
        Task {
            if let loadedImage = await ImageCacheManager.shared.loadAndCacheImage(from: url, for: attachment) {
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
    
    private func createMockTweet(for attachment: MimeiFileType) -> Tweet {
        // Create a minimal Tweet object for MediaBrowserView using singletons
        let authorId = isFromCurrentUser ? HproseInstance.shared.appUser.mid : (senderUser?.mid ?? "")
        let mockAuthor = User.getInstance(mid: authorId)
        // Update author properties if needed
        if mockAuthor.baseUrl != baseUrl {
            mockAuthor.baseUrl = baseUrl
        }
        if isFromCurrentUser {
            mockAuthor.name = HproseInstance.shared.appUser.name
            mockAuthor.avatar = HproseInstance.shared.appUser.avatar
        } else if let senderUser = senderUser {
            mockAuthor.name = senderUser.name
            mockAuthor.avatar = senderUser.avatar
        }
        
        return Tweet.getInstance(
            mid: MimeiId("chat_message_\(attachment.mid)"),
            authorId: MimeiId(authorId),
            content: "",
            timestamp: Date(timeIntervalSince1970: Date().timeIntervalSince1970),
            author: mockAuthor,
            attachments: [attachment]
        )
    }
}

// MARK: - Chat Video Player

struct ChatVideoPlayer: View {
    let attachment: MimeiFileType
    let isFromCurrentUser: Bool
    let senderUser: User?
    let isChatScreenVisible: Bool
    
    @State private var showFullScreen = false
    @State private var isPlaying = true  // Start with autoplay enabled
    
    private var baseUrl: URL {
        if isFromCurrentUser {
            // For messages sent by current user, use app user's baseUrl
            return HproseInstance.shared.appUser.baseUrl ?? HproseInstance.baseUrl
        } else {
            // For messages received from other users, use sender's baseUrl
            return senderUser?.baseUrl ?? HproseInstance.baseUrl
        }
    }
    
    var body: some View {
        Group {
            // Compact layout to minimize spacing
            if let url = attachment.getUrl(baseUrl) {
                // Calculate grid aspect ratio same as MediaGridViewModel
                let videoAR = attachment.aspectRatio ?? 1.0
                let isPortrait = videoAR < 0.9
                let gridAspectRatio = isPortrait ? 0.9 : videoAR
                
                // Calculate grid dimensions (max width 70% of screen like images)
                let maxWidth = UIScreen.main.bounds.width * 0.7
                let gridHeight = maxWidth / CGFloat(gridAspectRatio)
                
                ChatVideoPlayerContent(
                    url: url,
                    attachment: attachment,
                    videoAR: CGFloat(videoAR),
                    gridAspectRatio: CGFloat(gridAspectRatio),
                    maxWidth: maxWidth,
                    gridHeight: gridHeight,
                    showFullScreen: $showFullScreen,
                    isPlaying: $isPlaying,
                    isChatScreenVisible: isChatScreenVisible
                )
                .frame(width: maxWidth, height: gridHeight) // Constrain ZStack to grid size
                .onChange(of: isChatScreenVisible) { _, visible in
                    if !visible {
                        // Stop playing when chat screen becomes invisible
                        isPlaying = false
                    }
                }
                .fullScreenCover(isPresented: $showFullScreen, onDismiss: {
                    // Resume playing when returning from fullscreen
                    isPlaying = true
                }) {
                    // Create a temporary tweet-like structure for the video using singleton
                    let authorId = isFromCurrentUser ? HproseInstance.shared.appUser.mid : (senderUser?.mid ?? Constants.GUEST_ID)
                    let videoAuthor = User.getInstance(mid: authorId)
                    let tempTweet = Tweet.getInstance(
                        mid: "chat_video_\(attachment.mid)",
                        authorId: authorId,
                        content: "",
                        author: videoAuthor,
                        attachments: [attachment]
                    )
                    
                    MediaBrowserView(
                        tweet: tempTweet,
                        initialIndex: 0
                    )
                }
            } else {
                // Fallback if no URL
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray6))
                    .frame(width: 200, height: 150)
                    .overlay(
                        Image(systemName: "video")
                            .foregroundColor(.gray)
                    )
            }
        }
    }
}

// MARK: - Chat Video Player Content

private struct ChatVideoPlayerContent: View {
    let url: URL
    let attachment: MimeiFileType
    let videoAR: CGFloat
    let gridAspectRatio: CGFloat
    let maxWidth: CGFloat
    let gridHeight: CGFloat
    @Binding var showFullScreen: Bool
    @Binding var isPlaying: Bool
    let isChatScreenVisible: Bool
    
    var body: some View {
        ZStack {
            CachingVideoPlayer(
                url: url,
                mid: attachment.mid,
                isVisible: !showFullScreen && isChatScreenVisible, // Hide when full-screen is open or chat screen is not visible
                mediaType: attachment.type,
                autoPlay: isPlaying, // Control playback based on state
                loopOnCompletion: false, // Don't auto-replay when video finishes
                videoAspectRatio: CGFloat(videoAR),
                showNativeControls: false,
                isMuted: MuteState.shared.isMuted,
                onVideoTap: {
                    // This is handled by the overlay below
                },
                onVideoFinished: {
                    // Reset play button to triangle when video finishes
                    isPlaying = false
                }
            )
            .aspectRatio(CGFloat(videoAR), contentMode: .fill) // Use fill like MediaCell
            .frame(width: maxWidth, height: gridHeight) // Fixed grid size
            .clipped() // Clip overflow
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            
            // Clear overlay to capture taps for full-screen
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    // Only open fullscreen if not tapping on play/mute buttons
                    showFullScreen = true
                }
            
             // Bottom overlay with play and mute buttons
             VStack {
                 Spacer()
                 HStack {
                     // Play/Pause button (bottom left, small and compact)
                     Button {
                         isPlaying.toggle()
                     } label: {
                         Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                             .font(.system(size: 24))
                             .foregroundColor(.white)
                             .background(
                                 Circle()
                                     .fill(Color.black.opacity(0.3))
                                     .frame(width: 32, height: 32)
                             )
                     }
                     .buttonStyle(PlainButtonStyle())
                     .padding(.leading, 8)
                     .padding(.bottom, 8)
                     
                     Spacer()
                     
                     // Mute button (bottom right)
                     MuteButton()
                         .padding(.trailing, 8)
                         .padding(.bottom, 8)
                 }
             }
        }
    }
}

// MARK: - Chat Attachment Loader

struct ChatAttachmentLoader: View {
    let attachment: MimeiFileType
    let isFromCurrentUser: Bool
    
    @State private var isLoading = true
    @State private var loadError = false
    @State private var documentURLItem: DocumentURLItem?
    @State private var isDownloading = false
    @State private var isDownloadingForShare = false
    
    private var baseUrl: URL {
        if isFromCurrentUser {
            return HproseInstance.shared.appUser.baseUrl ?? HproseInstance.baseUrl
        } else {
            return HproseInstance.baseUrl
        }
    }
    
    var body: some View {
        Group {
            if isLoading {
                // Loading state
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(NSLocalizedString("Loading attachment...", comment: "Loading attachment message"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: UIScreen.main.bounds.width * 0.7)
                .aspectRatio(1.618, contentMode: .fit)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onAppear {
                    simulateLoading()
                }
            } else if loadError {
                // Error state
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text(NSLocalizedString("Failed to load attachment", comment: "Attachment loading error"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: UIScreen.main.bounds.width * 0.7)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                // Loaded state - show file info
                ZStack {
                    HStack {
                        Image(systemName: getAttachmentIcon(for: attachment.type))
                            .foregroundColor(getIconColor(for: attachment.type))
                            .font(.system(size: 20))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(truncateFileName(attachment.fileName ?? getDefaultFileName()))
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
                        // Download/share button for all document types
                        Button(action: {
                            downloadAndShare()
                        }) {
                            if isDownloadingForShare {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.down.circle")
                                    .foregroundColor(getIconColor(for: attachment.type))
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(isDownloadingForShare)
                    }
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.7)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .opacity(isDownloading ? 0.5 : 1.0)
                    .disabled(isDownloading || isDownloadingForShare)
                    
                    // Spinner overlay when downloading for preview
                    if isDownloading {
                        ProgressView()
                            .scaleEffect(1.2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(.systemGray6).opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .onTapGesture {
                    // Tap on document row - open preview
                    if !isDownloading && !isDownloadingForShare {
                        downloadAndShowDocument()
                    }
                }
            }
        }
        .sheet(item: $documentURLItem) { item in
            PDFQuickLookView(url: item.url)
        }
    }
    
    private func simulateLoading() {
        // Simulate loading time for non-media attachments
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeInOut(duration: 0.3)) {
                isLoading = false
            }
        }
    }
    
    private func downloadAndShowDocument() {
        // Prevent duplicate taps while downloading
        guard !isDownloading else {
            print("DEBUG: [ChatAttachmentLoader] Already downloading, ignoring tap")
            return
        }
        
        guard let url = attachment.getUrl(baseUrl) else {
            print("ERROR: [ChatAttachmentLoader] Invalid document URL")
            return
        }
        
        // Create consistent filename based on document CID
        let tempDirectory = FileManager.default.temporaryDirectory
        let originalFileName = attachment.fileName ?? getDefaultFileName()
        let fileExtension = (originalFileName as NSString).pathExtension
        let baseName = (originalFileName as NSString).deletingPathExtension
        let ext = fileExtension.isEmpty ? "pdf" : fileExtension
        
        // Use document ID for unique but consistent filename
        let uniqueFileName = "\(baseName)_\(attachment.mid.prefix(8)).\(ext)"
        let cachedURL = tempDirectory.appendingPathComponent(uniqueFileName)
        
        // Check if file already exists in cache
        if FileManager.default.fileExists(atPath: cachedURL.path),
           let attributes = try? FileManager.default.attributesOfItem(atPath: cachedURL.path),
           let fileSize = attributes[.size] as? Int64,
           fileSize > 0,
           FileManager.default.isReadableFile(atPath: cachedURL.path),
           (try? FileHandle(forReadingFrom: cachedURL)) != nil {
            
            // File exists and is valid - use cached version
            print("DEBUG: [ChatAttachmentLoader] Using cached file: \(uniqueFileName) (\(fileSize) bytes)")
            
            // Show spinner briefly while presenting
            isDownloading = true
            
            // Present sheet with URL item after a small delay to ensure file system is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Double-check file is still accessible before presenting
                guard FileManager.default.fileExists(atPath: cachedURL.path),
                      FileManager.default.isReadableFile(atPath: cachedURL.path),
                      (try? FileHandle(forReadingFrom: cachedURL)) != nil else {
                    print("ERROR: [ChatAttachmentLoader] Cached file became inaccessible before presentation")
                    self.isDownloading = false
                    return
                }
                
                self.documentURLItem = DocumentURLItem(id: self.attachment.mid, url: cachedURL)
                print("DEBUG: [ChatAttachmentLoader] Presenting document viewer (cached) with URL: \(cachedURL.lastPathComponent)")
                
                // Hide spinner after sheet is presented
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.isDownloading = false
                }
            }
            return
        }
        
        // If cached file exists but is invalid, remove it and download fresh
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            print("DEBUG: [ChatAttachmentLoader] Cached file exists but is invalid, removing and re-downloading")
            try? FileManager.default.removeItem(at: cachedURL)
        }
        
        // File doesn't exist or is invalid - need to download
        documentURLItem = nil
        
        print("DEBUG: [ChatAttachmentLoader] Downloading file from server...")
        isDownloading = true
        
        let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
            // CRITICAL: Copy file IMMEDIATELY before URLSession deletes the temp file
            // Do NOT dispatch to main queue until after file is copied!
            
            if let error = error {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    print("ERROR: [ChatAttachmentLoader] Failed to download: \(error)")
                }
                return
            }
            
            guard let localURL = localURL else {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    print("ERROR: [ChatAttachmentLoader] No local URL")
                }
                return
            }
            
            // Copy file synchronously BEFORE URLSession cleans it up
            do {
                    // Remove existing file if present
                    if FileManager.default.fileExists(atPath: cachedURL.path) {
                        try FileManager.default.removeItem(at: cachedURL)
                        print("DEBUG: [ChatAttachmentLoader] Removed existing cached file")
                    }
                    
                    // Copy downloaded file to cache (MUST happen before returning from this handler)
                    try FileManager.default.copyItem(at: localURL, to: cachedURL)
                    print("DEBUG: [ChatAttachmentLoader] File copied to cache: \(uniqueFileName)")
                    
                    // Ensure file is flushed to disk by opening and closing a file handle
                    let fileHandle = try FileHandle(forWritingTo: cachedURL)
                    try fileHandle.synchronize()
                    try fileHandle.close()
                    
                    // Verify file is valid and readable with multiple checks
                    guard FileManager.default.fileExists(atPath: cachedURL.path),
                          let attributes = try? FileManager.default.attributesOfItem(atPath: cachedURL.path),
                          let fileSize = attributes[.size] as? Int64,
                          fileSize > 0,
                          FileManager.default.isReadableFile(atPath: cachedURL.path) else {
                        DispatchQueue.main.async {
                            self.isDownloading = false
                        }
                        print("ERROR: [ChatAttachmentLoader] Downloaded file is empty, invalid, or not readable")
                        try? FileManager.default.removeItem(at: cachedURL)
                        return
                    }
                    
                    print("DEBUG: [ChatAttachmentLoader] File verified and readable: \(fileSize) bytes)")
                    
                    // Present sheet with URL item after a small async delay to ensure file system is ready
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        // Double-check file is still accessible before presenting
                        guard FileManager.default.fileExists(atPath: cachedURL.path),
                              FileManager.default.isReadableFile(atPath: cachedURL.path),
                              (try? FileHandle(forReadingFrom: cachedURL)) != nil else {
                            print("ERROR: [ChatAttachmentLoader] File became inaccessible before presentation")
                            self.isDownloading = false
                            return
                        }
                        
                        self.documentURLItem = DocumentURLItem(id: self.attachment.mid, url: cachedURL)
                        print("DEBUG: [ChatAttachmentLoader] Presenting document viewer (downloaded) with URL: \(cachedURL.lastPathComponent)")
                        
                        // Hide spinner after sheet is presented
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            self.isDownloading = false
                        }
                    }
                } catch {
                DispatchQueue.main.async {
                    self.isDownloading = false
                }
                print("ERROR: [ChatAttachmentLoader] Failed to cache file: \(error.localizedDescription)")
                // Clean up partial file
                try? FileManager.default.removeItem(at: cachedURL)
            }
        }
        
        task.resume()
    }
    
    private func downloadAndShare() {
        guard let url = attachment.getUrl(baseUrl) else {
            print("ERROR: [ChatAttachmentLoader] Invalid document URL")
            return
        }
        
        isDownloadingForShare = true
        
        // Download and present share sheet with original filename
        let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
            guard let localURL = localURL else {
                DispatchQueue.main.async {
                    self.isDownloadingForShare = false
                    print("ERROR: [ChatAttachmentLoader] No local URL for download")
                }
                return
            }
            
            do {
                // Copy to temp directory with original filename
                // IMPORTANT: Do this immediately in the completion handler, not in DispatchQueue.main.async
                // The temporary file from URLSession may be cleaned up if we wait
                let tempDirectory = FileManager.default.temporaryDirectory
                let originalFileName = attachment.fileName ?? getDefaultFileName()
                let destinationURL = tempDirectory.appendingPathComponent(originalFileName)
                
                // Remove existing file if present
                try? FileManager.default.removeItem(at: destinationURL)
                
                // Copy file with original name
                try FileManager.default.copyItem(at: localURL, to: destinationURL)
                
                    DispatchQueue.main.async {
                        // Present share sheet with properly named file
                        let activityVC = UIActivityViewController(
                            activityItems: [destinationURL],
                            applicationActivities: nil
                        )
                        
                        // Exclude some activities that don't make sense for documents
                        activityVC.excludedActivityTypes = [
                            .assignToContact,
                            .addToReadingList,
                            .postToFacebook,
                            .postToTwitter,
                            .postToWeibo,
                            .postToVimeo,
                            .postToFlickr
                        ]
                        
                        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                           let rootViewController = windowScene.windows.first?.rootViewController {
                            var topController = rootViewController
                            while let presented = topController.presentedViewController {
                                topController = presented
                            }
                            
                            // For iPad, need to set source view
                            if let popover = activityVC.popoverPresentationController {
                                popover.sourceView = topController.view
                                popover.sourceRect = CGRect(x: topController.view.bounds.midX,
                                                           y: topController.view.bounds.midY,
                                                           width: 0, height: 0)
                                popover.permittedArrowDirections = []
                            }
                            
                            topController.present(activityVC, animated: true) {
                                // Only hide spinner after share sheet is presented
                                self.isDownloadingForShare = false
                                print("DEBUG: [ChatAttachmentLoader] Share sheet presented with file: \(originalFileName)")
                            }
                        } else {
                            // Fallback: hide spinner if we can't present
                            self.isDownloadingForShare = false
                        }
                    }
            } catch {
                DispatchQueue.main.async {
                    self.isDownloadingForShare = false
                    print("ERROR: [ChatAttachmentLoader] Failed to prepare file for sharing: \(error)")
                }
            }
        }
        
        task.resume()
    }
    
    private func getIconColor(for type: MediaType) -> Color {
        switch type {
        case .pdf:
            return .red
        case .word:
            return .blue
        case .excel:
            return .green
        case .ppt:
            return .orange
        case .zip:
            return .purple
        default:
            return .gray
        }
    }
    
    private func truncateFileName(_ fileName: String, maxLength: Int = 30) -> String {
        guard fileName.count > maxLength else {
            return fileName
        }
        
        let ellipsis = "..."
        let halfLength = (maxLength - ellipsis.count) / 2
        
        let start = String(fileName.prefix(halfLength))
        let end = String(fileName.suffix(halfLength))
        
        return "\(start)\(ellipsis)\(end)"
    }
    
    private func getDefaultFileName() -> String {
        switch attachment.type {
        case .pdf:
            return "Document.pdf"
        case .word:
            return "Document.docx"
        case .excel:
            return "Spreadsheet.xlsx"
        case .ppt:
            return "Presentation.pptx"
        case .zip:
            return "Archive.zip"
        case .txt:
            return "Text.txt"
        case .html:
            return "Page.html"
        default:
            return "Attachment"
        }
    }
    
    private func getAttachmentIcon(for type: MediaType) -> String {
        switch type {
        case .image:
            return "photo"
        case .video, .hls_video:
            return "video"
        case .audio:
            return "music.note"
        case .pdf:
            return "doc.fill"
        case .word, .excel, .ppt:
            return "doc.text"
        case .zip, .txt, .html:
            return "paperclip"
        case .unknown:
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

// MARK: - Chat Multiple Attachments Loader

struct ChatMultipleAttachmentsLoader: View {
    let attachments: [MimeiFileType]
    let isFromCurrentUser: Bool
    
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if isLoading {
                // Loading state for multiple attachments
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(String(format: NSLocalizedString("Loading %d attachments...", comment: "Loading multiple attachments"), attachments.count))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: UIScreen.main.bounds.width * 0.7)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onAppear {
                    simulateLoading()
                }
            } else {
                // Loaded state - show summary
                HStack {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.blue)
                    Text(String(format: NSLocalizedString("%d attachments", comment: "Attachment count"), attachments.count))
                        .font(.caption)
                        .foregroundColor(.primary)
                    Spacer()
                }
                .frame(maxWidth: UIScreen.main.bounds.width * 0.7)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    
    private func simulateLoading() {
        // Simulate loading time for multiple attachments
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.3)) {
                isLoading = false
            }
        }
    }
}

