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
                    Avatar(user: receiptUser, size: 32)
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 32, height: 32)
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
                            if attachment.type.lowercased().contains("image") {
                                ChatImageViewWithPlaceholder(
                                    attachment: attachment, 
                                    isFromCurrentUser: isFromCurrentUser,
                                    senderUser: isFromCurrentUser ? HproseInstance.shared.appUser : receiptUser
                                )
                            } else if attachment.type.lowercased().contains("video") {
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
                    .frame(maxWidth: 280)
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
                Avatar(user: HproseInstance.shared.appUser, size: 32)
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
            if attachment.type.lowercased().contains("image") {
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

// MARK: - Chat Image View With Placeholder

struct ChatImageViewWithPlaceholder: View {
    let attachment: MimeiFileType
    let isFromCurrentUser: Bool
    let senderUser: User?
    
    @State private var showFullScreen = false
    @State private var isImageLoaded = false
    @State private var hasLoadError = false
    
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
            if let url = attachment.getUrl(baseUrl) {
                chatImageView(url: url)
            } else {
                chatImageFallback
            }
        }
        .sheet(isPresented: $showFullScreen) {
            if let url = attachment.getUrl(baseUrl) {
                FullScreenImageView(
                    imageURL: url,
                    placeholderImage: getCachedPlaceholder(),
                    isPresented: $showFullScreen
                )
            }
        }
    }
    
    @ViewBuilder
    private func chatImageView(url: URL) -> some View {
        let aspectRatio = CGFloat(max(attachment.aspectRatio ?? 1.0, 0.8))
        let maxWidth = UIScreen.main.bounds.width * 0.7
        
        WebImage(url: url, options: [.progressiveLoad])
            .onSuccess { image, data, cacheType in
                // Image loaded successfully
                Task { @MainActor in
                    isImageLoaded = true
                    hasLoadError = false
                }
            }
            .onFailure { error in
                // Handle error state
                Task { @MainActor in
                    hasLoadError = true
                    isImageLoaded = false
                }
            }
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: maxWidth)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay(
                Group {
                    if !isImageLoaded && !hasLoadError {
                        if let placeholderImage = getCachedPlaceholder() {
                            Image(uiImage: placeholderImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .foregroundColor(.gray)
                        } else {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        }
                    } else if hasLoadError {
                        // Show error state
                        VStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                                .font(.system(size: 20))
                            Text(NSLocalizedString("Failed to load image", comment: "Image loading error"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(Color(.systemGray6).opacity(0.8))
                        .cornerRadius(6)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture {
                showFullScreen = true
            }
            .onAppear {
                // Reset state when view appears
                isImageLoaded = false
                hasLoadError = false
            }
    }
    
    @ViewBuilder
    private var chatImageFallback: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(.systemGray6))
            .frame(width: 100, height: 100)
            .overlay(
                Image(systemName: "photo")
                    .foregroundColor(.gray)
            )
    }
    
    private func getCachedPlaceholder() -> UIImage? {
        return ImageCacheManager.shared.getCompressedImage(for: attachment, baseUrl: baseUrl)
    }
}

// MARK: - Chat Video Player

struct ChatVideoPlayer: View {
    let attachment: MimeiFileType
    let isFromCurrentUser: Bool
    let senderUser: User?
    
    @State private var showFullScreen = false
    
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
            if let url = attachment.getUrl(baseUrl) {
                SimpleVideoPlayer(
                    url: url,
                    mid: attachment.mid,
                    isVisible: true,
                    cellAspectRatio: CGFloat(1.0),
                    videoAspectRatio: CGFloat(attachment.aspectRatio ?? 16.0/9.0),
                    showNativeControls: false,
                    isMuted: MuteState.shared.isMuted,
                    onVideoTap: {
                        showFullScreen = true
                    },
                    disableAutoRestart: true
                )
                .frame(maxWidth: UIScreen.main.bounds.width)
                .aspectRatio(CGFloat(attachment.aspectRatio ?? 16.0/9.0), contentMode: .fit)
                .clipped()
                .contentShape(Rectangle())
                .fullScreenCover(isPresented: $showFullScreen) {
                    // Create a temporary tweet-like structure for the video
                    let tempTweet = Tweet(
                        mid: "chat_video_\(attachment.mid)",
                        authorId: "chat_author",
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

