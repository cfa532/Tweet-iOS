//
//  ChatMessageView.swift
//  Tweet
//
//  Created by 超方 on 2025/6/27.
//

import SwiftUI
import AVKit
import SDWebImageSwiftUI

// MARK: - Chat Message View

struct ChatMessageView: View {
    let message: ChatMessage
    let isFromCurrentUser: Bool
    let isLastMessage: Bool
    let isLastFromSender: Bool
    let showTimestamp: Bool
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
                                // TODO: Implement retry functionality
                                print("Retry sending message: \(message.errorMsg ?? "Unknown error")")
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
                                    senderUser: isFromCurrentUser ? HproseInstance.shared.appUser : receiptUser
                                )
                            } else {
                                // Other file types
                                ChatAttachmentLoader(attachment: attachment, isFromCurrentUser: isFromCurrentUser)
                            }
                        } else {
                            // Multiple attachments
                            ChatMultipleAttachmentsLoader(attachments: attachments, isFromCurrentUser: isFromCurrentUser)
                        }
                        
                        // Show failure icon for sent messages with attachments that failed
                        if isFromCurrentUser && message.success == false {
                            Button(action: {
                                // TODO: Implement retry functionality
                                print("Retry sending message with attachments: \(message.errorMsg ?? "Unknown error")")
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
            if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: attachment, baseUrl: baseUrl) {
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
            if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: attachment, baseUrl: baseUrl) {
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
        if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: attachment, baseUrl: baseUrl) {
            self.image = cachedImage
            return
        }
        
        // If no cached image, start loading
        isLoading = true
        Task {
            if let loadedImage = await ImageCacheManager.shared.loadAndCacheImage(from: url, for: attachment, baseUrl: baseUrl) {
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
        // Create a minimal Tweet object for MediaBrowserView
        let mockAuthor = User(
            mid: isFromCurrentUser ? HproseInstance.shared.appUser.mid : (senderUser?.mid ?? ""),
            baseUrl: baseUrl,
            name: isFromCurrentUser ? HproseInstance.shared.appUser.name : (senderUser?.name ?? ""),
            avatar: isFromCurrentUser ? HproseInstance.shared.appUser.avatar : (senderUser?.avatar ?? "")
        )
        
        return Tweet(
            mid: MimeiId("chat_message_\(attachment.mid)"),
            authorId: MimeiId(isFromCurrentUser ? HproseInstance.shared.appUser.mid : (senderUser?.mid ?? "")),
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
    
    @State private var showFullScreen = false
    @State private var showPlayButton = true
    
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
                ZStack {
                    SimpleVideoPlayer(
                        url: url,
                        mid: attachment.mid,
                        isVisible: true,
                        cellAspectRatio: CGFloat(1.0),
                        videoAspectRatio: CGFloat(attachment.aspectRatio ?? 16.0/9.0),
                        showNativeControls: false,
                        isMuted: MuteState.shared.isMuted,
                        onVideoTap: {
                            // This is handled by the overlay below
                        },
                        disableAutoRestart: true
                    )
                    .aspectRatio(max(CGFloat(attachment.aspectRatio ?? 16.0/9.0), 0.9), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    
                    // Play button overlay
                    if showPlayButton {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.white)
                            .background(
                                Circle()
                                    .fill(Color.black.opacity(0.3))
                                    .frame(width: 60, height: 60)
                            )
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.2), value: showPlayButton)
                            .allowsHitTesting(false) // Allow taps to pass through to the overlay
                    }
                    
                    // Clear overlay to capture taps for full-screen (like MediaCell)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showFullScreen = true
                        }
                    
                    // Mute button overlay (bottom right corner)
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            MuteButton()
                                .padding(.trailing, 8)
                                .padding(.bottom, 8)
                        }
                    }
                }
                .onAppear {
                    // Auto-hide play button after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showPlayButton = false
                        }
                    }
                }
                .fullScreenCover(isPresented: $showFullScreen) {
                    // Create a temporary tweet-like structure for the video
                    let tempTweet = Tweet(
                        mid: "chat_video_\(attachment.mid)",
                        authorId: isFromCurrentUser ? HproseInstance.shared.appUser.mid : (senderUser?.mid ?? Constants.GUEST_ID),
                        content: "",
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

// MARK: - Chat Attachment Loader

struct ChatAttachmentLoader: View {
    let attachment: MimeiFileType
    let isFromCurrentUser: Bool
    
    @State private var isLoading = true
    @State private var loadError = false
    
    private let baseUrl = HproseInstance.baseUrl
    
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
                HStack {
                    Image(systemName: getAttachmentIcon(for: attachment.type))
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.fileName ?? "Attachment")
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
                .frame(maxWidth: UIScreen.main.bounds.width * 0.7)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
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



