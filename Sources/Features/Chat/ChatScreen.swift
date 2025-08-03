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
                                isFromCurrentUser: message.authorId == HproseInstance.shared.appUser.mid,
                                isLastMessage: index == messages.count - 1,
                                isLastFromSender: isLastMessageFromSender(index: index, messages: messages),
                                showTimestamp: isLastMessageFromSender(index: index, messages: messages) // Show timestamp for last message from each party
                            )
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    if let lastMessage = messages.last {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: keyboardHeight) { newHeight in
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
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                        .disabled(false)
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
                    TextField("Type a message...", text: $messageText, axis: .vertical)
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
                    Button(action: sendMessage) {
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
                .padding(.bottom, 49) // Add bottom padding to account for tab bar height
                .background(Color(.systemBackground))
                .overlay(
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundColor(Color(.separator)),
                    alignment: .top
                )
                
                // Attachment preview placeholder
                if selectedAttachment != nil {
                    HStack {
                        Text("📎 Attachment selected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
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
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
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
                showToastMessage("Failed to send message", type: .error)
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
        .onChange(of: selectedPhotos) { items in
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
        // Create message for immediate sending
        let message = ChatMessage(
            authorId: HproseInstance.shared.appUser.mid,
            receiptId: receiptId,
            chatSessionId: ChatMessage.generateSessionId(userId: HproseInstance.shared.appUser.mid, receiptId: receiptId),
            content: messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : messageText.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: nil
        )
        
        // Store current text for background processing
        let currentMessageText = messageText
        
        // Clear input immediately
        messageText = ""
        
        // Add message to UI immediately
        messages.append(message)
        
        // Send message in background task
        Task.detached(priority: .background) {
            do {
                // Send message to backend
                try await HproseInstance.shared.sendMessage(receiptId: receiptId, message: message)
                
                // Update the chat session
                await chatSessionManager.updateOrCreateChatSession(
                    senderId: receiptId,
                    message: message,
                    hasNews: false
                )
                
                // Save message to Core Data
                await MainActor.run {
                    chatRepository.addMessagesToCoreData([message])
                    print("[ChatScreen] Text message sent successfully")
                }
                
            } catch {
                print("[ChatScreen] Error sending text message: \(error)")
                
                // Remove the message on failure
                await MainActor.run {
                    messages.removeAll { $0.id == message.id }
                    
                    // Post notification for failure
                    NotificationCenter.default.post(
                        name: .chatMessageSendFailed,
                        object: nil,
                        userInfo: ["error": error]
                    )
                }
            }
        }
    }
    
    private func sendMessageWithAttachments() {
        // Generate a consistent message ID for both temporary and final messages
        let messageId = UUID().uuidString
        
        // Create a temporary message for immediate UI feedback
        let tempMessage = ChatMessage(
            id: messageId,
            authorId: HproseInstance.shared.appUser.mid,
            receiptId: receiptId,
            chatSessionId: ChatMessage.generateSessionId(userId: HproseInstance.shared.appUser.mid, receiptId: receiptId),
            content: messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : messageText.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: selectedAttachment != nil ? [selectedAttachment!] : nil
        )
        
        print("[ChatScreen] Created temporary message: content=\(tempMessage.content ?? "nil"), attachments=\(tempMessage.attachments?.count ?? 0)")
        
        // Add temporary message to UI immediately
        messages.append(tempMessage)
        print("[ChatScreen] Added temporary message to UI with ID: \(messageId)")
        print("[ChatScreen] Total messages in array: \(messages.count)")
        
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
        showToastMessage("Uploading attachment in background...", type: .info)
        
        // Process message in background
        Task.detached(priority: .background) {
            print("[ChatScreen] Starting background message processing for ID: \(messageId)")
            do {
                var uploadedAttachments: [MimeiFileType]? = nil
                
                // Upload attachment if present
                if let attachment = currentAttachment, let photoData = currentAttachmentData {
                    print("[ChatScreen] Uploading attachment to IPFS in background...")
                    if let uploadedAttachment = try await HproseInstance.shared.uploadToIPFS(
                        data: photoData,
                        typeIdentifier: attachment.type == "image" ? "public.image" : "public.movie",
                        fileName: attachment.fileName
                    ) {
                        uploadedAttachments = [uploadedAttachment]
                        print("[ChatScreen] Attachment uploaded successfully: \(uploadedAttachment.fileName ?? "Unknown")")
                    }
                }
                
                // Create final message with the same ID and uploaded attachment
                let finalMessage = ChatMessage(
                    id: messageId, // Use the same ID as temporary message
                    authorId: HproseInstance.shared.appUser.mid,
                    receiptId: receiptId,
                    chatSessionId: ChatMessage.generateSessionId(userId: HproseInstance.shared.appUser.mid, receiptId: receiptId),
                    content: currentMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : currentMessageText.trimmingCharacters(in: .whitespacesAndNewlines),
                    attachments: uploadedAttachments
                )
                
                // Send message to backend
                print("[ChatScreen] Sending message to backend...")
                try await HproseInstance.shared.sendMessage(receiptId: receiptId, message: finalMessage)
                print("[ChatScreen] Message sent to backend successfully")
                
                // Update the chat session
                await chatSessionManager.updateOrCreateChatSession(
                    senderId: receiptId,
                    message: finalMessage,
                    hasNews: false
                )
                
                // Update the temporary message with the final one
                await MainActor.run {
                    if let index = messages.firstIndex(where: { $0.id == messageId }) {
                        messages[index] = finalMessage
                        print("[ChatScreen] Updated temporary message with final message at index: \(index)")
                    } else {
                        print("[ChatScreen] Warning: Could not find temporary message with ID: \(messageId) to update")
                    }
                    
                    // Save final message to Core Data only after successful upload
                    chatRepository.addMessagesToCoreData([finalMessage])
                    
                    // Show success toast
                    showToastMessage("Message sent successfully", type: .success)
                    
                    print("[ChatScreen] Message sent successfully in background")
                }
                
            } catch {
                print("[ChatScreen] Error sending message in background: \(error)")
                
                // Remove the temporary message on failure
                await MainActor.run {
                    messages.removeAll { $0.id == messageId }
                    
                    // Post notification for failure
                    NotificationCenter.default.post(
                        name: .chatMessageSendFailed,
                        object: nil,
                        userInfo: ["error": error]
                    )
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
                // Create a temporary MimeiFileType for the selected photo
                let tempAttachment = MimeiFileType(
                    mid: UUID().uuidString,
                    type: "image",
                    size: Int64(data.count),
                    fileName: "photo.jpg",
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
            print("[ChatScreen] Error loading photo: \(error)")
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
                }
                
                // Row 2: Attachments
                if let attachments = message.attachments, !attachments.isEmpty {
                    if attachments.count == 1, let attachment = attachments.first {
                        // Single attachment
                        if attachment.type.lowercased().contains("image") {
                            ChatImageViewWithPlaceholder(attachment: attachment, isFromCurrentUser: isFromCurrentUser)
                        } else if attachment.type.lowercased().contains("video") {
                            ChatVideoPlayer(attachment: attachment, isFromCurrentUser: isFromCurrentUser)
                        } else {
                            // Other file types
                            ChatAttachmentLoader(attachment: attachment, isFromCurrentUser: isFromCurrentUser)
                        }
                    } else {
                        // Multiple attachments
                        ChatMultipleAttachmentsLoader(attachments: attachments, isFromCurrentUser: isFromCurrentUser)
                    }
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



// MARK: - Helper Components

struct ChatLoadingView: View {
    let receiptId: String
    
    var body: some View {
        VStack {
            Text("Loading chat...")
                .font(.headline)
            Text("Receipt ID: \(receiptId)")
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
                    Avatar(user: user, size: 32)
                    Text(user.name ?? "@\(user.username ?? "")")
                        .font(.headline)
                }
            } else {
                Text("Loading...")
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

// MARK: - Chat Image View With Placeholder

struct ChatImageViewWithPlaceholder: View {
    let attachment: MimeiFileType
    let isFromCurrentUser: Bool
    
    @State private var imageState: ImageState = .loading
    @State private var showFullScreen = false
    
    private let baseUrl = HproseInstance.baseUrl
    
    var body: some View {
        Group {
            if let url = attachment.getUrl(baseUrl) {
                ImageViewWithPlaceholder(
                    attachment: attachment,
                    baseUrl: baseUrl,
                    url: url,
                    imageState: imageState
                )
                .frame(maxWidth: UIScreen.main.bounds.width * 0.7)
                .aspectRatio(CGFloat(max(attachment.aspectRatio ?? 1.0, 0.8)), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture {
                    showFullScreen = true
                }
                .onAppear {
                    loadImageIfNeeded()
                }
            } else {
                // Fallback if no URL
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray6))
                    .frame(width: 100, height: 100)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.gray)
                    )
            }
        }
        .sheet(isPresented: $showFullScreen) {
            if case .loaded(let image) = imageState {
                FullScreenImageView(image: image)
            }
        }
    }
    
    private func loadImageIfNeeded() {
        // Show compressed image as placeholder first
        if let compressedImage = ImageCacheManager.shared.getCompressedImage(for: attachment, baseUrl: baseUrl) {
            imageState = .placeholder(compressedImage)
        } else {
            imageState = .loading
        }
        
        // Load original image from backend
        guard let url = attachment.getUrl(baseUrl) else { return }
        
        Task {
            if let originalImage = await ImageCacheManager.shared.loadOriginalImage(from: url, for: attachment, baseUrl: baseUrl) {
                await MainActor.run {
                    imageState = .loaded(originalImage)
                }
            } else {
                await MainActor.run {
                    imageState = .error
                }
            }
        }
    }
}

// MARK: - Chat Video Player

struct ChatVideoPlayer: View {
    let attachment: MimeiFileType
    let isFromCurrentUser: Bool
    
    private let baseUrl = HproseInstance.baseUrl
    
    var body: some View {
        Group {
            if let url = attachment.getUrl(baseUrl) {
                SimpleVideoPlayer(
                    url: url,
                    mid: attachment.mid,
                    isVisible: true,
                    cellAspectRatio: CGFloat(max(attachment.aspectRatio ?? 16.0/9.0, 0.8)),
                    disableAutoRestart: true
                )
                .frame(maxWidth: UIScreen.main.bounds.width * 0.7)
                .aspectRatio(CGFloat(max(attachment.aspectRatio ?? 16.0/9.0, 0.8)), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .environmentObject(MuteState.shared)
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
                    Text("Loading attachment...")
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
                    Text("Failed to load attachment")
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
                    Text("Loading \(attachments.count) attachments...")
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
                    Text("\(attachments.count) attachments")
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

struct FullScreenImageView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            GeometryReader { geometry in
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(Color.black)
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
        }
    }
}
