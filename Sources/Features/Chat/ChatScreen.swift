import SwiftUI
import PhotosUI

struct ChatScreen: View {
    let receiptId: MimeiId
    @StateObject private var chatRepository = ChatRepository()
    @StateObject private var chatSessionManager = ChatSessionManager.shared
    @State private var messages: [ChatMessage] = []
    @State private var messageText = ""
    @State private var user: User?
    @State private var selectedAttachment: MimeiFileType?
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var attachmentData: Data?
    @State private var keyboardHeight: CGFloat = 0
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var messageRefreshTimer: Timer?
    
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
        VStack(spacing: 0) {
            // Debug info
            if messages.isEmpty && user == nil {
                ChatLoadingView(receiptId: receiptId)
            }
            // Header
            ChatHeaderView(user: user, dismiss: dismiss)
            
            // Messages - Take remaining space
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            // Add time divider if there's a 5+ minute gap
                            if index > 0 {
                                let timeDiff = message.timestamp - messages[index - 1].timestamp
                                if timeDiff > 3600 { // 1 hour
                                    TimeDividerView(timestamp: message.timestamp)
                                }
                            }
                            
                            ChatMessageView(
                                message: message, 
                                isFromCurrentUser: message.authorId == HproseInstance.globalCurrentUserId,
                                isLastMessage: index == messages.count - 1,
                                isLastFromSender: isLastMessageFromSender(index: index, messages: messages),
                                showTimestamp: isLastMessageFromSender(index: index, messages: messages) // Show timestamp for last message from each party
                            )
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let lastMessage = messages.last {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: keyboardHeight) { _, newHeight in
                    // Scroll to bottom when keyboard appears/disappears
                    print("[ChatScreen] Keyboard height changed to: \(newHeight)")
                    if let lastMessage = messages.last {
                        // Add a delay to ensure keyboard animation is complete
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            print("[ChatScreen] Scrolling to message: \(lastMessage.id)")
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
                .navigationBarHidden(true)
                .onAppear {
                    // Scroll to bottom when view appears
                    if let lastMessage = messages.last {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                    
                    // Clear badge count when chat is opened
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
            
            // Message Input - Fixed at bottom
            VStack(spacing: 0) {
                // Attachment preview
                if let attachment = selectedAttachment {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: getAttachmentIcon(for: attachment.type))
                                    .foregroundColor(.blue)
                                Text(attachment.fileName ?? "Attachment")
                                    .font(.caption)
                                    .foregroundColor(.primary)
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
                            attachmentData = nil
                            selectedPhotos = []
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                }
                
                // Message input bar
                HStack(spacing: 12) {
                    // Attachment button
                    PhotosPicker(
                        selection: $selectedPhotos,
                        maxSelectionCount: 1,
                        matching: .any(of: [.images, .videos])
                    ) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 20))
                            .foregroundColor(.blue)
                    }
                    
                    // Text input
                    TextField(NSLocalizedString("Type a message...", comment: "Chat message input placeholder"), text: $messageText, axis: .vertical)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12) // Increased vertical padding for taller touchable area
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                        .lineLimit(1...5)
                        .focused($isTextFieldFocused)
                        .foregroundColor(.primary)
                        .onTapGesture {
                            // Focus the text field when tapped anywhere in its area
                            isTextFieldFocused = true
                        }
                        .onSubmit {
                            // Hide keyboard when user submits
                            hideKeyboard()
                        }
                    
                    // Send button
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
                .padding()
                .background(Color(.systemBackground))
                .overlay(
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundColor(Color(.separator)),
                    alignment: .top
                )
            }
            .background(Color(.systemBackground))
        }
        .onTapGesture {
            // Hide keyboard when tapping outside input area
            hideKeyboard()
        }
        .toolbar(.hidden, for: .tabBar)
        .overlay(
            // Toast message overlay
            VStack {
                Spacer()
                if showToast {
                    ToastView(message: toastMessage, type: toastType)
                        .padding(.bottom, 100)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
                .animation(.easeInOut(duration: 0.3), value: showToast)
        )
        
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = keyboardFrame.height
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatMessageSendFailed)) { notification in
            if let error = notification.userInfo?["error"] as? Error {
                showToastMessage(error.localizedDescription, type: .error)
            } else {
                showToastMessage(NSLocalizedString("Failed to send message", comment: "Chat error"), type: .error)
            }
        }

        .task {
            print("[ChatScreen] Starting to load chat for receiptId: \(receiptId)")
            
            // Mark session as read when opened
            chatSessionManager.markSessionAsRead(receiptId: receiptId)
            
            await loadUser()
            await loadMessages()
            
            // Start periodic message refresh after initial load
            startPeriodicMessageRefresh()
            
            print("[ChatScreen] Finished loading chat. User: \(user?.name ?? "nil"), Messages: \(messages.count)")
        }
        .onChange(of: selectedPhotos) { _, items in
            Task {
                await handlePhotoSelection(items)
            }
        }
        .onDisappear {
            // Stop the periodic message refresh timer when leaving the screen
            stopPeriodicMessageRefresh()
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
                            authorId: HproseInstance.globalCurrentUserId,
            receiptId: receiptId,
                            chatSessionId: ChatMessage.generateSessionId(userId: HproseInstance.globalCurrentUserId, receiptId: receiptId),
            content: trimmedContent,
            attachments: nil
        )
        
        // Clear input immediately
        messageText = ""
        
        // Add message to UI immediately
        messages.append(message)
        
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
                        errorMsg: error.localizedDescription
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
        // Store current values for background processing
        let currentMessageText = messageText
        let currentAttachment = selectedAttachment
        let currentAttachmentData = attachmentData
        
        // Clear input immediately
        messageText = ""
        selectedAttachment = nil
        attachmentData = nil
        selectedPhotos = []
        
        // Show toast message for background upload
        showToastMessage(NSLocalizedString("Uploading attachment...", comment: "Chat status"), type: .info)
        
        // Process attachment upload in background, then send message directly
        Task.detached(priority: .background) {
            // Get app user ID once at the beginning
            let appUserId = HproseInstance.globalCurrentUserId
            
            do {
                // Use the same tweet upload routine for attachments
                var uploadedAttachments: [MimeiFileType]? = nil
                
                if let attachment = currentAttachment, let photoData = currentAttachmentData {
                    print("[ChatScreen] Uploading attachment using tweet upload routine...")
                    
                    // Upload attachment directly using the same method as tweet uploads
                    if let uploadedAttachment = try await HproseInstance.shared.uploadToIPFS(
                        data: photoData,
                        typeIdentifier: attachment.type == .image ? "public.image" : "public.movie",
                        fileName: attachment.fileName ?? "attachment"
                    ) {
                        uploadedAttachments = [uploadedAttachment]
                        print("[ChatScreen] Attachment uploaded successfully using tweet routine")
                    }
                }
                
                // Create final message with uploaded attachments
                let finalMessage = ChatMessage(
                    authorId: appUserId,
                    receiptId: receiptId,
                    chatSessionId: ChatMessage.generateSessionId(userId: appUserId, receiptId: receiptId),
                    content: currentMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : currentMessageText.trimmingCharacters(in: .whitespacesAndNewlines),
                    attachments: uploadedAttachments
                )
                
                // Send message directly (not in background)
                print("[ChatScreen] Sending message directly...")
                let resultMessage = try await HproseInstance.shared.sendMessage(receiptId: receiptId, message: finalMessage)
                
                // Update the chat session with the result message
                await chatSessionManager.updateOrCreateChatSession(
                    senderId: receiptId,
                    message: resultMessage,
                    hasNews: false
                )
                
                // Add message to UI and save to Core Data
                await MainActor.run {
                    messages.append(resultMessage)
                    chatRepository.addMessagesToCoreData([resultMessage])
                    
                    if resultMessage.success == true {
                        print("[ChatScreen] Message sent successfully")
                    } else {
                        print("[ChatScreen] Message failed to send: \(resultMessage.errorMsg ?? "Unknown error")")
                    }
                }
                
            } catch {
                print("[ChatScreen] Error uploading attachment or sending message: \(error)")
                
                // Handle network exceptions
                await MainActor.run {
                    // Create a failed message with error details
                    let failedMessage = ChatMessage(
                        authorId: appUserId,
                        receiptId: receiptId,
                        chatSessionId: ChatMessage.generateSessionId(userId: appUserId, receiptId: receiptId),
                        content: currentMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : currentMessageText.trimmingCharacters(in: .whitespacesAndNewlines),
                        attachments: nil,
                        success: false,
                        errorMsg: error.localizedDescription
                    )
                    
                    // Add failed message to UI and save to Core Data
                    messages.append(failedMessage)
                    chatRepository.addMessagesToCoreData([failedMessage])
                    
                    print("[ChatScreen] Message failed to send: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func loadUser() async {
        do {
            let fetchedUser = try await HproseInstance.shared.fetchUser(receiptId)
            await MainActor.run {
                user = fetchedUser
            }
        } catch {
            print("[ChatScreen] Error loading user: \(error)")
        }
    }
    
    private func loadMessages() async {
        // First, load the last 50 messages from local storage
        let localMessages = chatRepository.getLastMessages(for: receiptId, limit: 50)
        let validLocalMessages = localMessages.filter { isValidChatMessage($0) }
        await MainActor.run {
            messages = validLocalMessages
        }
        
        print("[ChatScreen] Loaded \(validLocalMessages.count) valid messages from local storage (filtered from \(localMessages.count) total)")
        
        // Then, fetch new messages from backend
        do {
            let backendMessages = try await HproseInstance.shared.fetchMessages(senderId: receiptId)
            let validBackendMessages = backendMessages.filter { isValidChatMessage($0) }
            
            // Merge new messages with existing ones, avoiding duplicates
            var allMessages = Set(messages)
            for message in validBackendMessages {
                allMessages.insert(message)
            }
            
            // Convert back to array and sort by timestamp
            let sortedMessages = Array(allMessages).sorted { $0.timestamp < $1.timestamp }
            
            await MainActor.run {
                messages = sortedMessages
            }
            
            // Save new messages to Core Data
            chatRepository.addMessagesToCoreData(backendMessages)
            
            // Update session timestamp if there are new messages
            if let latestMessage = sortedMessages.last, latestMessage.timestamp > messages.first?.timestamp ?? 0 {
                await chatSessionManager.updateOrCreateChatSession(
                    senderId: receiptId,
                    message: latestMessage,
                    hasNews: false
                )
            }
            
            print("[ChatScreen] Fetched \(backendMessages.count) messages from backend, total: \(sortedMessages.count)")
        } catch {
            print("[ChatScreen] Error fetching messages from backend: \(error)")
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
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedAttachment != nil
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
    
    // MARK: - Periodic Message Refresh
    
    private func startPeriodicMessageRefresh() {
        // Stop any existing timer first
        stopPeriodicMessageRefresh()
        
        // Start timer to refresh messages every 10 seconds
        messageRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            Task {
                await refreshMessagesFromBackend()
            }
        }
        
        print("[ChatScreen] Started periodic message refresh timer (10 seconds)")
    }
    
    private func stopPeriodicMessageRefresh() {
        messageRefreshTimer?.invalidate()
        messageRefreshTimer = nil
        print("[ChatScreen] Stopped periodic message refresh timer")
    }
    
    // MARK: - Photo Selection
    
    private func handlePhotoSelection(_ items: [PhotosPickerItem]) async {
        guard let item = items.first else { return }
        
        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                // Get the type identifier from the PhotosPickerItem
                let typeIdentifier = item.supportedContentTypes.first?.identifier ?? "public.image"
                print("[ChatScreen] Type identifier: \(typeIdentifier)")
                
                // Detect media type and set appropriate file extension
                let mediaType: MediaType
                let fileExtension: String
                
                // Determine media type and extension from type identifier
                if typeIdentifier.contains("movie") || typeIdentifier.contains("video") || typeIdentifier.contains("mpeg") || typeIdentifier.contains("mp4") || typeIdentifier.contains("mov") || typeIdentifier.contains("avi") || typeIdentifier.contains("wmv") || typeIdentifier.contains("flv") || typeIdentifier.contains("webm") {
                    mediaType = .video
                    if typeIdentifier.contains("mp4") || typeIdentifier.contains("mpeg-4") {
                        fileExtension = "mp4"
                    } else if typeIdentifier.contains("mov") || typeIdentifier.contains("quicktime") {
                        fileExtension = "mov"
                    } else if typeIdentifier.contains("avi") {
                        fileExtension = "avi"
                    } else if typeIdentifier.contains("wmv") {
                        fileExtension = "wmv"
                    } else if typeIdentifier.contains("flv") {
                        fileExtension = "flv"
                    } else if typeIdentifier.contains("webm") {
                        fileExtension = "webm"
                    } else {
                        fileExtension = "mp4" // Default for videos
                    }
                    print("[ChatScreen] Detected video with extension: \(fileExtension)")
                } else {
                    mediaType = .image
                    if typeIdentifier.contains("jpeg") || typeIdentifier.contains("jpg") {
                        fileExtension = "jpg"
                    } else if typeIdentifier.contains("png") {
                        fileExtension = "png"
                    } else if typeIdentifier.contains("heic") || typeIdentifier.contains("heif") {
                        fileExtension = "heic"
                    } else if typeIdentifier.contains("gif") {
                        fileExtension = "gif"
                    } else if typeIdentifier.contains("webp") {
                        fileExtension = "webp"
                    } else {
                        fileExtension = "jpg" // Default for images
                    }
                    print("[ChatScreen] Detected image with extension: \(fileExtension)")
                }
                
                // Use item identifier for uniqueness, fallback to timestamp
                let uniqueId = item.itemIdentifier ?? String(Int(Date().timeIntervalSince1970))
                // Sanitize the uniqueId to make it safe for filenames
                let sanitizedId = uniqueId.replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: ":", with: "_")
                    .replacingOccurrences(of: "\\", with: "_")
                    .replacingOccurrences(of: "*", with: "_")
                    .replacingOccurrences(of: "?", with: "_")
                    .replacingOccurrences(of: "\"", with: "_")
                    .replacingOccurrences(of: "<", with: "_")
                    .replacingOccurrences(of: ">", with: "_")
                    .replacingOccurrences(of: "|", with: "_")
                
                let fileName = "\(mediaType == .image ? "photo" : "video")_\(sanitizedId).\(fileExtension)"
                print("[ChatScreen] Generated filename: \(fileName)")
                
                // Create a temporary MimeiFileType for the selected media
                let tempAttachment = MimeiFileType(
                    mid: UUID().uuidString,
                    mediaType: mediaType,
                    size: Int64(data.count),
                    fileName: fileName,
                    url: nil
                )
                
                await MainActor.run {
                    // Replace current attachment with new one
                    selectedAttachment = tempAttachment
                    attachmentData = data // Store the actual file data
                    selectedPhotos = [] // Clear selection
                }
            }
        } catch {
            print("[ChatScreen] Error loading media: \(error)")
        }
    }
    
    
    
    private func refreshMessagesFromBackend() async {
        do {
            let backendMessages = try await HproseInstance.shared.fetchMessages(senderId: receiptId)
            let validBackendMessages = backendMessages.filter { isValidChatMessage($0) }
            
            // Check if we have new messages
            let currentMessageIds = Set(messages.map { $0.id })
            let newMessages = validBackendMessages.filter { !currentMessageIds.contains($0.id) }
            
            if !newMessages.isEmpty {
                print("[ChatScreen] Found \(newMessages.count) new messages from backend")
                
                // Merge new messages with existing ones
                var allMessages = Set(messages)
                for message in validBackendMessages {
                    allMessages.insert(message)
                }
                
                // Convert back to array and sort by timestamp
                let sortedMessages = Array(allMessages).sorted { $0.timestamp < $1.timestamp }
                
                await MainActor.run {
                    messages = sortedMessages
                }
                
                // Save new messages to Core Data
                chatRepository.addMessagesToCoreData(newMessages)
                
                // Update session timestamp if there are new messages
                if let latestMessage = sortedMessages.last {
                    await chatSessionManager.updateOrCreateChatSession(
                        senderId: receiptId,
                        message: latestMessage,
                        hasNews: false
                    )
                }
                print("[ChatScreen] Updated message list with \(newMessages.count) new messages, total: \(sortedMessages.count)")
            } else {
                print("[ChatScreen] No new messages found in periodic refresh")
            }
        } catch {
            print("[ChatScreen] Error refreshing messages from backend: \(error)")
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
