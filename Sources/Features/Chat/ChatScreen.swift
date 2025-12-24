import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatScreen: View {
    let receiptId: MimeiId
    @Binding var navigationPath: NavigationPath
    let onProfileNavigate: (() -> Void)?
    @StateObject private var chatRepository = ChatRepository()
    @StateObject private var chatSessionManager = ChatSessionManager.shared
    @State private var messages: [ChatMessage] = []
    @State private var allCachedMessages: [ChatMessage] = [] // All messages from cache for pagination
    @State private var messageText = ""
    @State private var user: User?
    @State private var selectedAttachment: MimeiFileType?
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedDocuments: [DocumentFile] = []
    @State private var showDocumentPicker = false
    @State private var isLongPressingAttachment = false
    @State private var attachmentItemData: HproseInstance.PendingTweetUpload.ItemData?
    @State private var isProcessingAttachment = false
    @State private var keyboardHeight: CGFloat = 0
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var messageRefreshTimer: Timer?
    
    init(receiptId: MimeiId, navigationPath: Binding<NavigationPath> = .constant(NavigationPath()), onProfileNavigate: (() -> Void)? = nil) {
        self.receiptId = receiptId
        self._navigationPath = navigationPath
        self.onProfileNavigate = onProfileNavigate
    }
    
    // Pagination states
    @State private var currentOffset = 0
    @State private var hasMoreMessages = true
    @State private var isLoadingMore = false
    @State private var shouldScrollToBottom = false
    @State private var isLoadMoreEnabled = false
    @State private var shouldAnimateScroll = true
    
    // Toast message states
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info
    
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
    
    var body: some View {
        mainContentView
            .onTapGesture {
                hideKeyboard()
            }
            .toolbar(.hidden, for: .tabBar)
            .navigationDestination(for: User.self) { user in
                ProfileView(user: user, onLogout: nil, navigationPath: $navigationPath)
            }
            .overlay(toastOverlay)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
                if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                    keyboardHeight = keyboardFrame.height
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardHeight = 0
            }
            .onReceive(NotificationCenter.default.publisher(for: .chatMessageSent)) { notification in
                handleMessageSent(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .chatMessageSendFailed)) { notification in
                handleMessageSendFailed(notification)
            }
            .task {
                print("[ChatScreen] Starting to load chat for receiptId: \(receiptId)")
                chatSessionManager.markSessionAsRead(receiptId: receiptId)
                await loadUser()
                await loadMessages()
                startPeriodicMessageRefresh()
                print("[ChatScreen] Finished loading chat. User: \(user?.name ?? "nil"), Messages: \(messages.count)")
            }
            .onDisappear {
                stopPeriodicMessageRefresh()
            }
            .sheet(isPresented: $showDocumentPicker) {
                DocumentPicker(
                    selectedDocuments: $selectedDocuments,
                    allowedTypes: [
                        .pdf,
                        .text,
                        .plainText,
                        .rtf,
                        .zip,
                        .data,
                        .content,
                        .item  // Allow any file type (DocumentPicker will determine type from extension)
                    ],
                    allowsMultipleSelection: false
                )
            }
            .onChange(of: selectedDocuments) { oldDocuments, newDocuments in
                guard !newDocuments.isEmpty, !isProcessingAttachment else {
                    return
                }
                Task {
                    await handleDocumentSelection(newDocuments)
                }
            }
    }
    
    private var mainContentView: some View {
        VStack(spacing: 0) {
            if messages.isEmpty && user == nil {
                ChatLoadingView(receiptId: receiptId)
            }
            ChatHeaderView(
                user: user,
                dismiss: dismiss,
                onAvatarTap: {
                    if let user = user {
                        navigationPath.append(user)
                        onProfileNavigate?()
                    }
                }
            )
            messagesScrollView
            messageInputView
        }
    }
    
    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if hasMoreMessages && !messages.isEmpty && isLoadMoreEnabled {
                        if isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .padding()
                                Spacer()
                            }
                        } else {
                            Color.clear
                                .frame(height: 1)
                                .onAppear {
                                    loadMoreMessages()
                                }
                        }
                    }
                    
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if index > 0 {
                            let timeDiff = message.timestamp - messages[index - 1].timestamp
                            if timeDiff > 3600 {
                                TimeDividerView(timestamp: message.timestamp)
                            }
                        }
                        
                        ChatMessageView(
                            message: message,
                            isFromCurrentUser: message.authorId == HproseInstance.shared.appUser.mid,
                            isLastMessage: index == messages.count - 1,
                            isLastFromSender: isLastMessageFromSender(index: index, messages: messages),
                            showTimestamp: isLastMessageFromSender(index: index, messages: messages)
                        )
                        .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: shouldScrollToBottom) { _, newValue in
                guard newValue, let lastMessage = messages.last else { return }
                if shouldAnimateScroll {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                } else {
                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                }
                shouldScrollToBottom = false
                shouldAnimateScroll = true
            }
            .onChange(of: keyboardHeight) { _, newHeight in
                if let lastMessage = messages.last {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let lastMessage = messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
                DispatchQueue.main.async {
                    UNUserNotificationCenter.current().setBadgeCount(0) { error in
                        if let error = error {
                            print("[ChatScreen] Error clearing badge count: \(error)")
                        }
                    }
                }
            }
        }
        .background(Color(.systemBackground))
    }
    
    private var messageInputView: some View {
        VStack(spacing: 0) {
            attachmentPreviewView
            messageInputBar
        }
        .background(Color(.systemBackground))
    }
    
    @ViewBuilder
    private var attachmentPreviewView: some View {
        if isProcessingAttachment {
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text(NSLocalizedString("Preparing attachment...", comment: "Chat attachment loading"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
        } else if let attachment = selectedAttachment {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: getAttachmentIcon(for: attachment.type))
                            .foregroundColor(.blue)
                        Text(attachment.fileName ?? "Attachment")
                            .font(.caption)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    if let size = attachment.size {
                        Text(formatFileSize(size))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Button(action: {
                    selectedAttachment = nil
                    attachmentItemData = nil
                    selectedPhotos = []
                    selectedDocuments = []
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
        }
    }
    
    private var messageInputBar: some View {
        HStack(spacing: 12) {
            attachmentButton
            textInputField
            sendButton
        }
        .padding()
        .background(Color(.systemBackground))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color(.separator)),
            alignment: .top
        )
    }
    
    private var attachmentButton: some View {
        AttachmentButtonView(
            selectedPhotos: $selectedPhotos,
            showDocumentPicker: $showDocumentPicker,
            isLongPressing: $isLongPressingAttachment,
            onPhotoSelected: { items in
                guard !items.isEmpty, !isProcessingAttachment else { return }
                Task {
                    await handlePhotoSelection(items)
                }
            }
        )
    }
    
    private var textInputField: some View {
        TextField(NSLocalizedString("Type a message...", comment: "Chat message input placeholder"), text: $messageText, axis: .vertical)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .lineLimit(1...5)
            .focused($isTextFieldFocused)
            .foregroundColor(.primary)
            .onTapGesture {
                isTextFieldFocused = true
            }
            .onSubmit {
                hideKeyboard()
            }
    }
    
    private var sendButton: some View {
        DebounceButton(
            cooldownDuration: 0.3,
            enableAnimation: true,
            enableVibration: false
        ) {
            sendMessage()
        } label: {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 18))
                .foregroundColor(.white)
        }
        .frame(width: 32, height: 32)
        .background(canSendMessage ? Color.blue : Color.gray)
        .clipShape(Circle())
        .disabled(!canSendMessage)
    }
    
    private var toastOverlay: some View {
        VStack {
            Spacer()
            if showToast {
                ToastView(message: toastMessage, type: toastType)
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showToast)
    }
    
    private func handleMessageSent(_ notification: Notification) {
        if let sentMessage = notification.userInfo?["message"] as? ChatMessage {
            print("[ChatScreen] Received notification for sent message: \(sentMessage.id)")
            if !messages.contains(where: { $0.id == sentMessage.id }) {
                messages.append(sentMessage)
                allCachedMessages.append(sentMessage)
                chatRepository.addMessagesToCoreData([sentMessage])
                shouldAnimateScroll = true
                shouldScrollToBottom = true
                Task {
                    await chatSessionManager.updateOrCreateChatSession(
                        senderId: receiptId,
                        message: sentMessage,
                        hasNews: false
                    )
                }
            }
        }
    }
    
    private func handleMessageSendFailed(_ notification: Notification) {
        if let error = notification.userInfo?["error"] as? Error {
            showToastMessage(ErrorMessageHelper.userFriendlyMessage(from: error), type: .error)
        } else {
            showToastMessage(NSLocalizedString("Failed to send message", comment: "Chat error"), type: .error)
        }
    }
    
    private func sendMessage() {
        guard canSendMessage else { return }
        
        // Check if message has attachments
        let hasAttachments = selectedAttachment != nil
        
        if hasAttachments {
            // Send message with attachments in background
            sendMessageWithAttachments()
        } else {
            // Send text-only message directly
            sendTextMessageDirectly()
        }
    }
    
    private func sendTextMessageDirectly() {
        // Guard against creating ChatMessage without content or attachments
        let trimmedContent = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            print("[ChatScreen] Cannot send empty message")
            showToastMessage(NSLocalizedString("Message cannot be empty", comment: "Chat validation error"), type: .error)
            return
        }
        
        // Create message for immediate sending
        let message = ChatMessage(
            authorId: HproseInstance.shared.appUser.mid,
            receiptId: receiptId,
            chatSessionId: ChatMessage.generateSessionId(userId: HproseInstance.shared.appUser.mid, receiptId: receiptId),
            content: trimmedContent,
            attachments: nil
        )
        
        // Clear input immediately
        messageText = ""
        
        // Add message to UI and cache immediately
        messages.append(message)
        allCachedMessages.append(message)
        
        // Scroll to bottom for sent message
        shouldAnimateScroll = true
        shouldScrollToBottom = true
        
        // Send message directly (synchronously)
        Task {
            do {
                // Send message to backend
                let resultMessage = try await HproseInstance.shared.sendMessage(receiptId: receiptId, message: message)
                
                // Update the chat session with the result message
                await chatSessionManager.updateOrCreateChatSession(
                    senderId: receiptId,
                    message: resultMessage,
                    hasNews: false
                )
                
                // Save message to Core Data and update UI
                await MainActor.run {
                    // Replace the original message with the result message that has status
                    if let index = messages.firstIndex(where: { $0.id == message.id }) {
                        messages[index] = resultMessage
                    }
                    chatRepository.addMessagesToCoreData([resultMessage])
                    
                    if resultMessage.success == true {
                        print("[ChatScreen] Text message sent successfully")
                    } else {
                        print("[ChatScreen] Text message failed to send: \(resultMessage.errorMsg ?? "Unknown error")")
                    }
                }
                
            } catch {
                print("[ChatScreen] Error sending text message: \(error)")
                
                // Handle network exceptions the same as backend failures
                await MainActor.run {
                    // Create a failed message with error details
                    // Guard against creating ChatMessage without content or attachments
                    guard message.content != nil || (message.attachments != nil && !message.attachments!.isEmpty) else {
                        print("[ChatScreen] Cannot create failed message without content or attachments")
                        showToastMessage(NSLocalizedString("Failed to create error message", comment: "Chat error"), type: .error)
                        return
                    }
                    
                    let failedMessage = ChatMessage(
                        id: message.id,
                        authorId: message.authorId,
                        receiptId: message.receiptId,
                        chatSessionId: message.chatSessionId,
                        content: message.content,
                        timestamp: message.timestamp,
                        attachments: message.attachments,
                        success: false,
                        errorMsg: ErrorMessageHelper.userFriendlyMessage(from: error)
                    )
                    
                    // Replace the original message with the failed message
                    if let index = messages.firstIndex(where: { $0.id == message.id }) {
                        messages[index] = failedMessage
                    }
                    
                    // Save failed message to Core Data
                    chatRepository.addMessagesToCoreData([failedMessage])
                    
                    print("[ChatScreen] Text message failed to send (network error): \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func sendMessageWithAttachments() {
        // Check if attachment is still being processed
        guard !isProcessingAttachment else {
            print("[ChatScreen] Cannot send message - attachment is still being processed")
            showToastMessage(NSLocalizedString("Please wait while the attachment is being prepared...", comment: "Chat attachment loading"), type: .info)
            return
        }
        
        guard let itemData = attachmentItemData else {
            print("[ChatScreen] No attachment data available - cannot send message with attachment")
            showToastMessage(NSLocalizedString("Attachment not ready. Please try selecting the media again.", comment: "Chat attachment error"), type: .error)
            return
        }
        
        // Store current values for background processing
        let currentMessageText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Clear input immediately
        messageText = ""
        selectedAttachment = nil
        attachmentItemData = nil
        selectedPhotos = []
        selectedDocuments = []
        
        // Create message to send
        let message = ChatMessage(
            authorId: HproseInstance.shared.appUser.mid,
            receiptId: receiptId,
            chatSessionId: ChatMessage.generateSessionId(userId: HproseInstance.shared.appUser.mid, receiptId: receiptId),
            content: currentMessageText.isEmpty ? nil : currentMessageText,
            attachments: nil  // Will be filled by TweetUploadManager
        )
        
        // Delegate to TweetUploadManager - same as tweet attachments!
        HproseInstance.shared.scheduleChatMessageUpload(message: message, itemData: [itemData])
    }
    
    private func loadUser() async {
        do {
            let fetchedUser = try await HproseInstance.shared.fetchUser(receiptId)
            await MainActor.run {
                user = fetchedUser
            }
        } catch {
            print("[ChatScreen] Error loading user: \(error)")
            await MainActor.run {
                showToastMessage(ErrorMessageHelper.userFriendlyMessage(from: error), type: .error)
            }
        }
    }
    
    private func loadMessages() async {
        // First, fetch new messages from backend
        do {
            let backendMessages = try await HproseInstance.shared.fetchMessages(senderId: receiptId)
            let validBackendMessages = backendMessages.filter { isValidChatMessage($0) }
            
            // Save new messages to Core Data
            chatRepository.addMessagesToCoreData(validBackendMessages)
            
            print("[ChatScreen] Fetched \(validBackendMessages.count) messages from backend")
        } catch {
            print("[ChatScreen] Error fetching messages from backend: \(error)")
        }
        
        // Load all messages from local storage for pagination
        let localMessages = chatRepository.getMessages(for: receiptId)
        let validLocalMessages = localMessages.filter { isValidChatMessage($0) }
        let sortedMessages = validLocalMessages.sorted { $0.timestamp < $1.timestamp }
        
        await MainActor.run {
            allCachedMessages = sortedMessages
            
            // Load only the most recent 20 messages initially
            currentOffset = max(0, sortedMessages.count - 20)
            let initialMessages = Array(sortedMessages.suffix(20))
            messages = initialMessages
            hasMoreMessages = currentOffset > 0
            isLoadMoreEnabled = false
            
            print("[ChatScreen] Loaded \(initialMessages.count) initial messages (total cached: \(sortedMessages.count), hasMore: \(hasMoreMessages))")
            
            // Scroll to bottom after messages are set
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    shouldAnimateScroll = false
                    shouldScrollToBottom = true
                    
                    // Allow loading older messages only after initial scroll completes
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        isLoadMoreEnabled = true
                    }
                }
        }
        
        // Update session timestamp if there are messages
        if let latestMessage = messages.last {
            await chatSessionManager.updateOrCreateChatSession(
                senderId: receiptId,
                message: latestMessage,
                hasNews: false
            )
        }
    }
    
    private func loadMoreMessages() {
        guard hasMoreMessages && !isLoadingMore else { return }
        
        isLoadingMore = true
        
        Task {
            await MainActor.run {
                // Calculate how many more messages to load
                let messagesToLoad = min(20, currentOffset)
                guard messagesToLoad > 0 else {
                    hasMoreMessages = false
                    isLoadingMore = false
                    return
                }
                
                // Get the next 20 older messages
                let newOffset = currentOffset - messagesToLoad
                let olderMessages = Array(allCachedMessages[newOffset..<currentOffset])
                
                // Prepend older messages to the current list
                messages = olderMessages + messages
                currentOffset = newOffset
                hasMoreMessages = currentOffset > 0
                
                print("[ChatScreen] Loaded \(messagesToLoad) more messages (offset: \(currentOffset), total: \(messages.count), hasMore: \(hasMoreMessages))")
                
                isLoadingMore = false
            }
        }
    }
    
    // MARK: - Helper Methods
    
    /// Validates if a chat message has a valid chatSessionId
    private func isValidChatMessage(_ message: ChatMessage) -> Bool {
        // Check if chatSessionId is not empty and not just whitespace
        let isValidSessionId = !message.chatSessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        if !isValidSessionId {
            print("[ChatScreen] Ignoring message with invalid chatSessionId: \(message.id)")
        }
        
        print("[ChatScreen] Message validation for \(message.id): sessionId=\(message.chatSessionId), isValid=\(isValidSessionId)")
        return isValidSessionId
    }
    
    private var canSendMessage: Bool {
        // If there's text, allow sending
        if !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        
        // If there's an attachment, only allow sending if:
        // 1. Attachment is not currently being processed
        // 2. Attachment data is ready
        if let _ = selectedAttachment {
            return !isProcessingAttachment && attachmentItemData != nil
        }
        
        return false
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
    
    private func hideKeyboard() {
        isTextFieldFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    
    private func showToastMessage(_ message: String, type: ToastView.ToastType) {
        toastMessage = message
        toastType = type
        showToast = true
        
        // Auto-dismiss toast after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation {
                showToast = false
            }
        }
    }
    
    private func getFileTypeDescription(from typeIdentifier: String) -> String {
        if typeIdentifier.contains("movie") || typeIdentifier.contains("video") || 
            typeIdentifier.contains("mpeg") || typeIdentifier.contains("mp4") || 
            typeIdentifier.contains("mov") || typeIdentifier.contains("avi") || 
            typeIdentifier.contains("wmv") || typeIdentifier.contains("flv") || 
            typeIdentifier.contains("webm") {
            return "Video"
        } else if typeIdentifier.contains("image") || typeIdentifier.contains("jpeg") || 
                    typeIdentifier.contains("png") || typeIdentifier.contains("gif") || 
                    typeIdentifier.contains("heic") || typeIdentifier.contains("heif") {
            return "Image"
        } else if typeIdentifier.contains("audio") || typeIdentifier.contains("mp3") || 
                    typeIdentifier.contains("wav") || typeIdentifier.contains("m4a") {
            return "Audio"
        } else if typeIdentifier.contains("pdf") {
            return "PDF"
        } else if typeIdentifier.contains("zip") {
            return "ZIP"
        } else if typeIdentifier.contains("doc") || typeIdentifier.contains("word") {
            return "Document"
        } else {
            return "File"
        }
    }
    
    // MARK: - Periodic Message Refresh
    
    private func startPeriodicMessageRefresh() {
        // Stop any existing timer first
        stopPeriodicMessageRefresh()
        
        // Start timer to refresh messages every 15 seconds
        messageRefreshTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { _ in
            Task {
                await refreshMessagesFromBackend()
            }
        }
        
        print("[ChatScreen] Started periodic message refresh timer (15 seconds)")
    }
    
    private func stopPeriodicMessageRefresh() {
        messageRefreshTimer?.invalidate()
        messageRefreshTimer = nil
        print("[ChatScreen] Stopped periodic message refresh timer")
    }
    
    // MARK: - Photo Selection
    
    private func handlePhotoSelection(_ items: [PhotosPickerItem]) async {
        guard let item = items.first else { return }
        
        // Set processing flag to prevent concurrent selections
        await MainActor.run {
            isProcessingAttachment = true
        }
        
        do {
            print("[ChatScreen] Starting to prepare attachment data...")
            
            // Use MediaUploadHelper to properly prepare the item data (same as tweet attachments)
            let itemDataArray = try await MediaUploadHelper.prepareItemData(
                selectedItems: [item],
                selectedImages: [],
                selectedVideos: []
            )
            
            guard let itemData = itemDataArray.first else {
                print("[ChatScreen] Failed to prepare item data")
                await MainActor.run {
                    isProcessingAttachment = false
                }
                return
            }
            
            // Get the type identifier to determine media type
            let typeIdentifier = itemData.typeIdentifier
            print("[ChatScreen] Type identifier: \(typeIdentifier), data size: \(itemData.data.count) bytes")
            
            // Determine media type from type identifier
            let typeIdLower = typeIdentifier.lowercased()
            let isVideo = typeIdLower.contains("video") || 
                          typeIdLower.contains("movie") || 
                          typeIdLower.contains("mpeg") ||
                          typeIdLower.contains("mp4") ||
                          typeIdLower.contains("m4v") ||
                          typeIdLower.contains("quicktime") ||
                          typeIdLower.contains("avi") ||
                          typeIdLower.contains("mov")
            
            let mediaType: MediaType = isVideo ? .video : .image
            
            print("[ChatScreen] Detected \(isVideo ? "video" : "image") with filename: \(itemData.fileName)")
            
            // Create a temporary MimeiFileType for the selected media
            let tempAttachment = MimeiFileType(
                mid: UUID().uuidString,
                mediaType: mediaType,
                size: Int64(itemData.data.count),
                fileName: itemData.fileName,
                url: nil
            )
            
            // Set attachment and itemData atomically on main thread
            await MainActor.run {
                selectedAttachment = tempAttachment
                attachmentItemData = itemData // Store the prepared item data - CRITICAL: set this before clearing photos
                print("[ChatScreen] Attachment data prepared successfully. attachmentItemData is now set.")
                
                // Clear processing flag AFTER everything is set
                isProcessingAttachment = false
                
                // Clear selection AFTER a small delay to ensure state is fully set
                // This prevents onChange from being triggered while attachmentItemData is still nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    selectedPhotos = []
                }
            }
            
            print("[ChatScreen] Attachment selection completed successfully")
        } catch {
            print("[ChatScreen] Error loading media: \(error)")
            await MainActor.run {
                isProcessingAttachment = false
                showToastMessage(ErrorMessageHelper.userFriendlyMessage(from: error), type: .error)
            }
        }
    }
    
    private func handleDocumentSelection(_ documents: [DocumentFile]) async {
        guard let document = documents.first else { return }
        
        // Set processing flag to prevent concurrent selections
        await MainActor.run {
            isProcessingAttachment = true
        }
        
        do {
            print("[ChatScreen] Starting to prepare document attachment data...")
            
            // Use MediaUploadHelper to properly prepare the item data (same as tweet attachments)
            let itemDataArray = try await MediaUploadHelper.prepareItemData(
                selectedItems: [],
                selectedImages: [],
                selectedVideos: [],
                selectedDocuments: [document]
            )
            
            guard let itemData = itemDataArray.first else {
                print("[ChatScreen] Failed to prepare document item data")
                await MainActor.run {
                    isProcessingAttachment = false
                }
                return
            }
            
            print("[ChatScreen] Document prepared: \(document.fileName), size: \(itemData.data.count) bytes, type: \(itemData.typeIdentifier)")
            
            // Create a temporary MimeiFileType for the selected document
            let tempAttachment = MimeiFileType(
                mid: UUID().uuidString,
                mediaType: document.mediaType,
                size: Int64(itemData.data.count),
                fileName: document.fileName,
                url: nil
            )
            
            // Set attachment and itemData atomically on main thread
            await MainActor.run {
                selectedAttachment = tempAttachment
                attachmentItemData = itemData // Store the prepared item data - CRITICAL: set this before clearing documents
                print("[ChatScreen] Document attachment data prepared successfully. attachmentItemData is now set.")
                
                // Clear processing flag AFTER everything is set
                isProcessingAttachment = false
                
                // Clear selection AFTER a small delay to ensure state is fully set
                // This prevents onChange from being triggered while attachmentItemData is still nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    selectedDocuments = []
                }
            }
            
            print("[ChatScreen] Document selection completed successfully")
        } catch {
            print("[ChatScreen] Error loading document: \(error)")
            await MainActor.run {
                isProcessingAttachment = false
                showToastMessage(ErrorMessageHelper.userFriendlyMessage(from: error), type: .error)
            }
        }
    }
    
    
    
    private func refreshMessagesFromBackend() async {
        do {
            let backendMessages = try await HproseInstance.shared.fetchMessages(senderId: receiptId)
            let validBackendMessages = backendMessages.filter { isValidChatMessage($0) }
            
            // Check if we have new messages
            let currentCachedIds = Set(allCachedMessages.map { $0.id })
            let newMessages = validBackendMessages.filter { !currentCachedIds.contains($0.id) }
            
            if !newMessages.isEmpty {
                print("[ChatScreen] Found \(newMessages.count) new messages from backend")
                
                // Save new messages to Core Data
                chatRepository.addMessagesToCoreData(newMessages)
                
                await MainActor.run {
                    // Add new messages to allCachedMessages
                    var updatedCache = allCachedMessages + newMessages
                    updatedCache.sort { $0.timestamp < $1.timestamp }
                    allCachedMessages = updatedCache
                    
                    // Append new messages to displayed messages
                    messages.append(contentsOf: newMessages)
                    messages.sort { $0.timestamp < $1.timestamp }
                    
                    // Update offset to account for new messages
                    currentOffset = max(0, allCachedMessages.count - messages.count)
                    hasMoreMessages = currentOffset > 0
                    
                    // Scroll to bottom for new messages
                    shouldAnimateScroll = true
                    shouldScrollToBottom = true
                }
                
                // Update session timestamp if there are new messages
                if let latestMessage = messages.last {
                    await chatSessionManager.updateOrCreateChatSession(
                        senderId: receiptId,
                        message: latestMessage,
                        hasNews: false
                    )
                }
                print("[ChatScreen] Updated message list with \(newMessages.count) new messages, total displayed: \(messages.count), total cached: \(allCachedMessages.count)")
            } else {
                print("[ChatScreen] No new messages found in periodic refresh")
            }
        } catch {
            print("[ChatScreen] Error refreshing messages from backend: \(error)")
        }
    }
}

/// Custom attachment button that handles both tap (photo picker) and long press (document picker)
struct AttachmentButtonView: View {
    @Binding var selectedPhotos: [PhotosPickerItem]
    @Binding var showDocumentPicker: Bool
    @Binding var isLongPressing: Bool
    let onPhotoSelected: ([PhotosPickerItem]) -> Void
    
    @State private var hasLongPressed = false
    
    var body: some View {
        PhotosPicker(
            selection: $selectedPhotos,
            maxSelectionCount: 1,
            matching: .any(of: [.images, .videos])
        ) {
            Image(systemName: "paperclip")
                .font(.system(size: 20))
                .foregroundColor(.blue)
        }
        .disabled(hasLongPressed)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5, maximumDistance: 50)
                .onEnded { _ in
                    hasLongPressed = true
                    isLongPressing = true
                    showDocumentPicker = true
                }
        )
        .onChange(of: selectedPhotos) { oldItems, newItems in
            guard !newItems.isEmpty, !hasLongPressed else {
                // Clear selection if it was triggered after long press
                if hasLongPressed {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        selectedPhotos = []
                    }
                }
                return
            }
            onPhotoSelected(newItems)
        }
        .onChange(of: showDocumentPicker) { _, newValue in
            if !newValue {
                // Reset states when document picker is dismissed
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isLongPressing = false
                    hasLongPressed = false
                }
            }
        }
    }
}

struct TimeDividerView: View {
    let timestamp: TimeInterval
    
    var body: some View {
        HStack {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
            
            Text(formatTime(timestamp))
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.systemBackground))
                .cornerRadius(8)
            
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
        }
        .padding(.vertical, 4)
    }
    
    private func formatTime(_ timestamp: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Helper Components

struct ChatLoadingView: View {
    let receiptId: String
    
    var body: some View {
        VStack {
                            Text(NSLocalizedString("Loading chat...", comment: "Loading chat message"))
                .font(.headline)
                          Text(String(format: NSLocalizedString("Receipt ID: %@", comment: "Receipt ID display"), receiptId))
                .font(.caption)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

struct ChatHeaderView: View {
    let user: User?
    let dismiss: DismissAction
    let onAvatarTap: (() -> Void)?
    
    var body: some View {
        HStack {
            // Back button
            Button(action: {
                dismiss()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.blue)
                    Text(NSLocalizedString("Back", comment: "Back button in navigation"))
                        .foregroundColor(.blue)
                }
            }
            
            Spacer()
            
            if let user = user {
                HStack(spacing: 8) {
                    Avatar(user: user, size: 36)
                        .contentShape(Circle())
                        .highPriorityGesture(
                            TapGesture().onEnded { _ in
                                onAvatarTap?()
                            }
                        )
                    Text(user.name ?? "@\(user.username ?? "")")
                        .font(.headline)
                }
            } else {
                Text(NSLocalizedString("Loading...", comment: "Loading message"))
                    .font(.headline)
            }
            
            Spacer()
        }
        .padding()
        .background(Color(.systemBackground))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color(.separator)),
            alignment: .bottom
        )
    }
}
