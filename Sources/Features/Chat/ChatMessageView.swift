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
import Combine

// MARK: - Chat Message View

struct ChatMessageView: View {
    let message: ChatMessage
    let allMessages: [ChatMessage] // Stable reference to compute properties
    let currentIndex: Int          // Stable index to compute properties
    let isChatScreenVisible: Bool
    let receiptId: String
    let chatUser: User?
    let senderBaseUrl: URL?
    let onResendMessage: ((ChatMessage) -> Void)?

    // Computed properties based on stable data
    private var isFromCurrentUser: Bool {
        message.authorId == HproseInstance.shared.appUser.mid
    }

    private var isLastMessage: Bool {
        currentIndex == allMessages.count - 1
    }

    private var isLastFromSender: Bool {
        isLastMessageFromSender(index: currentIndex, messages: allMessages)
    }

    private var showTimestamp: Bool {
        isLastFromSender
    }

    private var messageSenderUser: User? {
        isFromCurrentUser ? HproseInstance.shared.appUser : (chatUser ?? receiptUser)
    }

    private var messageSenderBaseUrl: URL? {
        isFromCurrentUser ? HproseInstance.shared.appUser.baseUrl : (senderBaseUrl ?? chatUser?.baseUrl ?? receiptUser?.baseUrl)
    }

    private func isLastMessageFromSender(index: Int, messages: [ChatMessage]) -> Bool {
        guard index < messages.count else { return false }
        let currentMessage = messages[index]
        let currentSenderId = currentMessage.authorId

        // Check if this is the last message from this sender
        for i in (index + 1)..<messages.count {
            if messages[i].authorId == currentSenderId {
                return false // Found a later message from the same sender
            }
        }
        return true // No later messages from this sender
    }
    @State private var receiptUser: User?
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !isFromCurrentUser {
                // Avatar for received messages (LEFT) - use receipt's avatar
                if let senderUser = messageSenderUser {
                    Avatar(user: senderUser, size: 36)
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
                                    .font(.system(size: 22))
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
                                    senderUser: messageSenderUser,
                                    senderBaseUrl: messageSenderBaseUrl
                                )
                            } else if attachment.type == .video || attachment.type == .hls_video {
                                // Display the video player with chat-specific UI
                                ChatVideoContainer(
                                    messageId: message.id,
                                    attachment: attachment,
                                    isFromCurrentUser: isFromCurrentUser,
                                    senderUser: messageSenderUser,
                                    senderBaseUrl: messageSenderBaseUrl,
                                    isChatScreenVisible: isChatScreenVisible,
                                    receiptId: receiptId
                                )
                            } else {
                                // Document attachments - use DocumentAttachmentsView
                                let documentAttachments = [attachment]
                                let baseUrl = messageSenderBaseUrl ?? HproseInstance.baseUrl
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
                                    .font(.system(size: 22))
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
            if !isFromCurrentUser, chatUser == nil {
                // Load sender user for received messages if the chat screen has not provided it yet.
                receiptUser = try? await HproseInstance.shared.fetchUser(message.authorId, baseUrl: "")
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
    let senderBaseUrl: URL?
    
    @State private var showFullScreen = false
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var foregroundObserver: NSObjectProtocol? = nil // Observer for app foreground events
    
    private var baseUrl: URL {
        if isFromCurrentUser {
            // For messages sent by current user, use app user's baseUrl
            return HproseInstance.shared.appUser.baseUrl ?? HproseInstance.baseUrl
        } else {
            // For messages received from other users, use sender's resolved baseUrl.
            return senderBaseUrl ?? senderUser?.baseUrl ?? HproseInstance.baseUrl
        }
    }
    
    var body: some View {
        Group {
            let imageUrl = attachment.getUrl(baseUrl)
            if imageUrl != nil {
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

            // Setup foreground observer to reload resources if released during background
            setupForegroundObserver()
        }
        .onDisappear {
            // Clean up foreground observer
            if let observer = foregroundObserver {
                NotificationCenter.default.removeObserver(observer)
                foregroundObserver = nil
            }
        }
        .onChange(of: baseUrl) { _, newBaseUrl in
            // Reload image when baseUrl changes (e.g., when senderUser loads)
            loadImage()
        }
        .onChange(of: attachment.url) { _, newUrl in
            // Reload image when attachment URL becomes available
            if newUrl != nil && image == nil {
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
            // CRITICAL: Use memory-only cache check to avoid blocking disk I/O in view body
            if let cachedImage = ImageCacheManager.shared.getCompressedImageFromMemory(for: attachment) {
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
            // CRITICAL: Use memory-only cache check to avoid blocking disk I/O in view body
            if let cachedImage = ImageCacheManager.shared.getCompressedImageFromMemory(for: attachment) {
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
    
    /// Setup observer to detect foreground return and reload image if released
    private func setupForegroundObserver() {
        // Avoid duplicate observers
        guard foregroundObserver == nil else { return }
        
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // Only reload if image was released
                guard self.image == nil else { return }
                
                print("DEBUG: [ChatImageThumbnail] App returned to foreground, image released - reloading: \(self.attachment.mid)")
                self.loadImage()
            }
        }
    }
    
    private func loadImage() {
        guard let url = attachment.getUrl(baseUrl) else {
            return
        }
        
        // First, try to get cached image immediately (disk check is OK in async context)
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
        
        // Defer property updates to avoid "Publishing changes from within view updates" warning
        DispatchQueue.main.async {
            // Update author properties if needed
            if mockAuthor.baseUrl != self.baseUrl {
                mockAuthor.baseUrl = self.baseUrl
            }
            if self.isFromCurrentUser {
                mockAuthor.name = HproseInstance.shared.appUser.name
                mockAuthor.avatar = HproseInstance.shared.appUser.avatar
            } else if let senderUser = self.senderUser {
                mockAuthor.name = senderUser.name
                mockAuthor.avatar = senderUser.avatar
            }
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


// MARK: - Chat Video Container

struct ChatVideoContainer: View {
    let messageId: String
    let attachment: MimeiFileType
    let isFromCurrentUser: Bool
    let senderUser: User?
    let senderBaseUrl: URL?
    let isChatScreenVisible: Bool
    let receiptId: String

    @State private var player: AVPlayer?
    @State private var showFullScreen = false
    @State private var isPlaying = false
    @State private var isLoading = true
    @State private var wasPlayingBeforeFullscreen = false
    @State private var videoCompletionObserver: NSObjectProtocol?
    @State private var cancellables = Set<AnyCancellable>()
    @ObservedObject private var muteState = MuteState.shared

    // Cache expensive calculations
    private static let maxWidth = UIScreen.main.bounds.width * 0.7

    private var baseUrl: URL {
        if isFromCurrentUser {
            return HproseInstance.shared.appUser.baseUrl ?? HproseInstance.baseUrl
        } else {
            return senderBaseUrl ?? senderUser?.baseUrl ?? HproseInstance.baseUrl
        }
    }

    private var videoAR: CGFloat {
        CGFloat(attachment.aspectRatio ?? 1.0)
    }

    private var gridAspectRatio: CGFloat {
        videoAR < 0.9 ? 0.9 : videoAR
    }

    private var gridHeight: CGFloat {
        Self.maxWidth / gridAspectRatio
    }

    var body: some View {
        ZStack {
            // Layer 1: Video player or loading placeholder (no hit testing)
            if let player = player {
                VideoPlayer(player: player)
                    .aspectRatio(videoAR, contentMode: .fill)
                    .frame(width: Self.maxWidth, height: gridHeight)
                    .clipped()
                    .disabled(true) // Disable built-in controls to prevent tap interception
                    .onAppear {
                        player.isMuted = muteState.isMuted
                        let shouldPlay = ChatVideoManager.shared.shouldPlayVideo(mid: attachment.mid, receiptId: receiptId)
                        if shouldPlay && isChatScreenVisible {
                            player.play()
                            isPlaying = true
                            isLoading = player.timeControlStatus != .playing
                        }
                        setupVideoCompletionObserver(for: player)
                    }
                    .onDisappear {
                        player.pause()
                        isPlaying = false
                        removeVideoCompletionObserver()
                    }
                    .onReceive(MuteState.shared.$isMuted) { isMuted in
                        player.isMuted = isMuted
                    }

                if isLoading {
                    Color.black.opacity(0.5)
                        .overlay(
                            VStack(spacing: 12) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(1.5)
                                Text("Loading video...")
                                    .font(.caption)
                                    .foregroundColor(.white)
                            }
                        )
                }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .frame(width: Self.maxWidth, height: gridHeight)
                    .overlay(
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .gray))
                                .scaleEffect(1.5)
                            Text("Loading video...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    )
            }

            // Layer 2: Interactive overlay — fullscreen tap area and button bar separated
            VStack(spacing: 0) {
                // Upper area: tap for fullscreen (does NOT overlap buttons)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        openFullscreen()
                    }

                // Bottom bar: play/mute buttons (separate from fullscreen tap)
                HStack {
                    Button {
                        guard let player = player else { return }
                        if isPlaying {
                            player.pause()
                            isLoading = false
                        } else {
                            player.play()
                            isLoading = player.timeControlStatus != .playing
                        }
                        isPlaying.toggle()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.5))
                                .frame(width: 32, height: 32)
                            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(player == nil)

                    Spacer()

                    MuteButton()
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(width: Self.maxWidth, height: gridHeight)
        }
        .frame(width: Self.maxWidth, height: gridHeight)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
        )
        .onAppear {
            if player == nil {
                loadVideoPlayer(reason: "onAppear", delayNanoseconds: 150_000_000)
            }
        }
        .onChange(of: baseUrl) { _, newBaseUrl in
            // Reload video player when sender's baseUrl becomes available.
            guard !isFromCurrentUser else { return }
            let oldPlayer = player
            player = nil
            isLoading = true
            oldPlayer?.pause()
            cancellables.removeAll()
            ChatVideoManager.shared.removeVideoPlayer(mediaID: attachment.mid)
            loadVideoPlayer(reason: "baseUrlChanged")
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatVideoShouldRecover)) { notification in
            guard notification.userInfo?["videoMid"] as? String == attachment.mid,
                  notification.userInfo?["receiptId"] as? String == receiptId else { return }
            let reason = notification.userInfo?["reason"] as? String ?? "chatRecovery"
            recoverVideoPlayer(reason: reason)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ChatVideoShouldPlay"))) { notification in
            guard notification.userInfo?["videoMid"] as? String == attachment.mid,
                  notification.userInfo?["receiptId"] as? String == receiptId,
                  let shouldPlay = notification.userInfo?["shouldPlay"] as? Bool else { return }
            handleChatPlaybackCommand(shouldPlay: shouldPlay)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ChatVideoShouldStop"))) { notification in
            guard notification.userInfo?["videoMid"] as? String == attachment.mid,
                  notification.userInfo?["receiptId"] as? String == receiptId else { return }
            player?.pause()
            isPlaying = false
            isLoading = false
        }
        .fullScreenCover(isPresented: $showFullScreen, onDismiss: {
            if let player, wasPlayingBeforeFullscreen {
                player.play()
                isPlaying = true
                isLoading = player.timeControlStatus != .playing
            }
            wasPlayingBeforeFullscreen = false
        }) {
            // Create a temporary tweet-like structure for the video
            let tempTweet = createFullScreenVideoTweet()

            MediaBrowserView(
                tweet: tempTweet,
                initialIndex: 0
            )
        }
    }
    
    // MARK: - Helper Functions

    private func openFullscreen() {
        saveVideoPositionForFullscreen()

        if let player {
            wasPlayingBeforeFullscreen = isPlaying ||
                player.rate > 0 ||
                player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            if wasPlayingBeforeFullscreen {
                player.pause()
                isPlaying = false
                isLoading = false
            }
        } else {
            wasPlayingBeforeFullscreen = false
        }
        showFullScreen = true
    }

    private func saveVideoPositionForFullscreen() {
        let sourcePlayer = player ?? SharedAssetCache.shared.getCachedPlayer(for: attachment.mid)

        if let sourcePlayer, sourcePlayer.currentItem != nil {
            let currentTime = handoffTime(for: sourcePlayer)
            let wasPlaying = isPlaying ||
                sourcePlayer.rate > 0 ||
                sourcePlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
            saveHandoffState(currentTime: currentTime, wasPlaying: wasPlaying, duration: sourcePlayer.currentItem?.duration)
            return
        }

        if let playbackInfo = VideoStateCache.shared.getCachedPlaybackInfo(for: attachment.mid) {
            saveHandoffState(currentTime: playbackInfo.time, wasPlaying: playbackInfo.wasPlaying, duration: nil)
        }
    }

    private func handoffTime(for player: AVPlayer) -> CMTime {
        guard let item = player.currentItem else {
            return player.currentTime()
        }

        let duration = item.duration
        guard duration.isValid,
              !duration.isIndefinite,
              duration.seconds.isFinite,
              duration.seconds > 0 else {
            return player.currentTime()
        }

        let currentTime = player.currentTime()
        guard currentTime.isValid,
              currentTime.seconds.isFinite else {
            return currentTime
        }

        return duration.seconds - currentTime.seconds <= 3.0 ? .zero : currentTime
    }

    private func saveHandoffState(currentTime: CMTime, wasPlaying: Bool, duration: CMTime?) {
        if let duration,
           duration.isValid,
           !duration.isIndefinite,
           duration.seconds.isFinite,
           duration.seconds > 0 {
            PersistentVideoStateManager.shared.saveState(
                videoMid: attachment.mid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .mediaCell,
                duration: duration
            )
            PersistentVideoStateManager.shared.saveState(
                videoMid: attachment.mid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .fullScreen,
                duration: duration
            )
        } else {
            PersistentVideoStateManager.shared.saveState(
                videoMid: attachment.mid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .mediaCell
            )
            PersistentVideoStateManager.shared.saveState(
                videoMid: attachment.mid,
                currentTime: currentTime,
                wasPlaying: wasPlaying,
                context: .fullScreen
            )
        }
    }

    private func isPlayerBroken(_ player: AVPlayer?) -> Bool {
        guard let player else { return true }
        guard let item = player.currentItem else { return true }
        return item.status == .failed || item.error != nil || player.error != nil
    }

    private func loadVideoPlayer(reason: String, delayNanoseconds: UInt64 = 0) {
        Task {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }

            let loadedPlayer = await ChatVideoManager.shared.getOrCreateVideoPlayer(
                messageId: messageId,
                attachment: attachment,
                isFromCurrentUser: isFromCurrentUser,
                senderUser: senderUser,
                senderBaseUrl: senderBaseUrl,
                isChatScreenVisible: isChatScreenVisible,
                receiptId: receiptId
            )

            await MainActor.run {
                installLoadedPlayer(loadedPlayer, reason: reason)
            }
        }
    }

    private func installLoadedPlayer(_ loadedPlayer: AVPlayer?, reason: String) {
        player = loadedPlayer
        cancellables.removeAll()
        removeVideoCompletionObserver()

        guard let loadedPlayer, let playerItem = loadedPlayer.currentItem else {
            isPlaying = false
            isLoading = false
            return
        }

        loadedPlayer.isMuted = muteState.isMuted
        setupVideoCompletionObserver(for: loadedPlayer)
        setupPlayerPlaybackObserver(for: loadedPlayer)
        if playerItem.status == .readyToPlay {
            isLoading = false
        } else {
            setupPlayerReadyObserver(for: loadedPlayer)
            isLoading = true
        }

        if isChatScreenVisible,
           ChatVideoManager.shared.shouldPlayVideo(mid: attachment.mid, receiptId: receiptId) {
            loadedPlayer.play()
            isPlaying = true
            isLoading = loadedPlayer.timeControlStatus != .playing
        } else {
            isPlaying = false
        }

        print("DEBUG: [ChatVideoContainer] Installed player for \(attachment.mid) after \(reason)")
    }

    private func recoverVideoPlayer(reason: String) {
        guard isChatScreenVisible else { return }

        if let player, !isPlayerBroken(player) {
            if ChatVideoManager.shared.shouldPlayVideo(mid: attachment.mid, receiptId: receiptId) {
                player.play()
                isPlaying = true
                isLoading = player.timeControlStatus != .playing
            }
            return
        }

        player?.pause()
        player = nil
        isPlaying = false
        isLoading = true
        cancellables.removeAll()
        removeVideoCompletionObserver()
        ChatVideoManager.shared.removeVideoPlayer(mediaID: attachment.mid)
        loadVideoPlayer(reason: reason)
    }

    private func handleChatPlaybackCommand(shouldPlay: Bool) {
        guard shouldPlay else {
            player?.pause()
            isPlaying = false
            isLoading = false
            return
        }

        guard isChatScreenVisible else { return }
        if isPlayerBroken(player) {
            recoverVideoPlayer(reason: "playCommand")
            return
        }

        player?.play()
        isPlaying = true
        isLoading = player?.timeControlStatus != .playing
    }
    
    private func createFullScreenVideoTweet() -> Tweet {
        let authorId = isFromCurrentUser ? HproseInstance.shared.appUser.mid : (senderUser?.mid ?? HproseInstance.shared.appUser.mid)
        let videoAuthor = User.getInstance(mid: authorId)
        // Ensure the author's baseUrl is set correctly for MediaBrowserView.
        if videoAuthor.baseUrl == nil {
            videoAuthor.baseUrl = baseUrl
        }

        return Tweet.getInstance(
            mid: "chat_video_\(attachment.mid)",
            authorId: authorId,
            content: "",
            author: videoAuthor,
            attachments: [attachment]
        )
    }

    private func setupVideoCompletionObserver(for player: AVPlayer) {
        // Remove existing observer if any
        removeVideoCompletionObserver()
        
        // Observe when video finishes playing
        videoCompletionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // Video finished — seek back to start so next tap replays
                isPlaying = false
                player.seek(to: .zero)
            }
        }
    }
    
    private func removeVideoCompletionObserver() {
        if let observer = videoCompletionObserver {
            NotificationCenter.default.removeObserver(observer)
            videoCompletionObserver = nil
        }
    }

    private func setupPlayerPlaybackObserver(for player: AVPlayer) {
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { status in
                if status == .playing {
                    isLoading = false
                } else if status == .waitingToPlayAtSpecifiedRate && isPlaying {
                    isLoading = true
                } else if !isPlaying {
                    isLoading = false
                }
            }
            .store(in: &cancellables)
    }

    private func setupPlayerReadyObserver(for player: AVPlayer) {
        // Observe player item status to hide loading spinner when ready
        guard let playerItem = player.currentItem else {
            isLoading = false
            return
        }
        playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak playerItem, weak player] status in
                guard playerItem != nil else { return }

                if status == .readyToPlay {
                    // Keep loading only if this chat video is actively trying to play
                    // and AVPlayer is still waiting to render.
                    isLoading = isPlaying && player?.timeControlStatus != .playing
                    print("DEBUG: [ChatVideoContainer] Video ready for \(attachment.mid)")
                } else if status == .failed {
                    // Hide spinner on failure too
                    isLoading = false
                    print("DEBUG: [ChatVideoContainer] Video failed to load for \(attachment.mid)")
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: - Chat Attachment Loader

// MARK: - Chat Attachment Loader

struct ChatAttachmentLoader: View {
    let attachment: MimeiFileType
    let isFromCurrentUser: Bool
    let senderUser: User?
    let senderBaseUrl: URL?

    @State private var isLoading = true
    @State private var loadError = false
    @State private var documentURLItem: DocumentURLItem?
    @State private var isDownloading = false
    @State private var isDownloadingForShare = false

    private var baseUrl: URL {
        if isFromCurrentUser {
            return HproseInstance.shared.appUser.baseUrl ?? HproseInstance.baseUrl
        } else {
            return senderBaseUrl ?? senderUser?.baseUrl ?? HproseInstance.baseUrl
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
    
    nonisolated private func getDefaultFileName() -> String {
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
