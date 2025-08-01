import SwiftUI
import PhotosUI

struct ChatScreen: View {
    let receiptId: String
    @StateObject private var chatRepository = ChatRepository()
    @StateObject private var chatSessionManager = ChatSessionManager.shared
    @State private var messages: [ChatMessage] = []
    @State private var messageText = ""
    @State private var user: User?
    @State private var selectedAttachment: MimeiFileType?
    @State private var showingAttachmentPicker = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var isSendingMessage = false
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var messageRefreshTimer: Timer?
    
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
            // Header
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
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                }
                
                // Message input bar
                HStack(spacing: 12) {
                    // Attachment button
                    Button(action: {
                        showingAttachmentPicker = true
                    }) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 20))
                            .foregroundColor(isSendingMessage ? .gray : .blue)
                    }
                    .disabled(isSendingMessage)
                    
                    // Text input
                    TextField("Type a message...", text: $messageText, axis: .vertical)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12) // Increased vertical padding for taller touchable area
                        .background(isSendingMessage ? Color(.systemGray5) : Color(.systemGray6))
                        .cornerRadius(12)
                        .lineLimit(1...5)
                        .focused($isTextFieldFocused)
                        .disabled(isSendingMessage)
                        .foregroundColor(isSendingMessage ? .gray : .primary)
                        .onTapGesture {
                            // Focus the text field when tapped anywhere in its area
                            if !isSendingMessage {
                                isTextFieldFocused = true
                            }
                        }
                        .onSubmit {
                            // Hide keyboard when user submits
                            hideKeyboard()
                        }
                    
                    // Send button
                    Button(action: sendMessage) {
                        if isSendingMessage {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .background(
                        canSendMessage && !isSendingMessage ? Color.blue : Color.gray
                    )
                    .clipShape(Circle())
                    .disabled(!canSendMessage || isSendingMessage)
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
            }
            .background(Color(.systemBackground))
        }
        .onTapGesture {
            // Hide keyboard when tapping outside input area
            hideKeyboard()
        }
        .toolbar(.hidden, for: .tabBar)

        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = keyboardFrame.height
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
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
        .sheet(isPresented: $showingAttachmentPicker) {
            AttachmentPickerSheet(selectedAttachment: $selectedAttachment)
        }
        .onDisappear {
            // Stop the periodic message refresh timer when leaving the screen
            stopPeriodicMessageRefresh()
        }
    }
    
    private func sendMessage() {
        guard canSendMessage && !isSendingMessage else { return }
        
        let message = ChatMessage(
            authorId: HproseInstance.shared.appUser.mid,
            receiptId: receiptId,
            chatSessionId: ChatMessage.generateSessionId(userId: HproseInstance.shared.appUser.mid, receiptId: receiptId),
            content: messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : messageText.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: selectedAttachment != nil ? [selectedAttachment!] : nil
        )
        
        // Set sending state
        isSendingMessage = true
        
        Task {
            do {
                try await HproseInstance.shared.sendMessage(receiptId: receiptId, message: message)
                
                // Update the chat session
                await chatSessionManager.updateOrCreateChatSession(
                    senderId: receiptId,
                    message: message,
                    hasNews: false
                )
                
                // Add message to local messages
                await MainActor.run {
                    messages.append(message)
                    messageText = ""
                    selectedAttachment = nil
                    isSendingMessage = false
                }
                
                // Save message to local storage
                chatRepository.addMessagesToLocalStorage([message])
                
                print("[ChatScreen] Message sent successfully")
            } catch {
                print("[ChatScreen] Error sending message: \(error)")
                
                // Reset sending state on error
                await MainActor.run {
                    isSendingMessage = false
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
            
            // Save new messages to local storage
            chatRepository.addMessagesToLocalStorage(backendMessages)
            
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
                
                // Save new messages to local storage
                chatRepository.addMessagesToLocalStorage(newMessages)
                
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

// MARK: - Attachment Picker Sheet
struct AttachmentPickerSheet: View {
    @Binding var selectedAttachment: MimeiFileType?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isUploading = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Header
                Text("Add Attachment")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .padding(.top)
                
                // Attachment options
                VStack(spacing: 16) {
                    // Photo/Video picker
                    PhotosPicker(
                        selection: $selectedPhotos,
                        maxSelectionCount: 1,
                        matching: .any(of: [.images, .videos])
                    ) {
                        AttachmentOptionView(
                            icon: "photo.on.rectangle",
                            title: "Photo or Video",
                            subtitle: "Select from your library"
                        )
                    }
                    
                    // Document picker
                    Button(action: {
                        // TODO: Implement document picker
                        print("Document picker not implemented yet")
                    }) {
                        AttachmentOptionView(
                            icon: "doc.text",
                            title: "Document",
                            subtitle: "Select a file"
                        )
                    }
                    
                    // Camera
                    Button(action: {
                        // TODO: Implement camera
                        print("Camera not implemented yet")
                    }) {
                        AttachmentOptionView(
                            icon: "camera",
                            title: "Camera",
                            subtitle: "Take a photo or video"
                        )
                    }
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .onChange(of: selectedPhotos) { items in
            Task {
                await handlePhotoSelection(items)
            }
        }
    }
    
    private func handlePhotoSelection(_ items: [PhotosPickerItem]) async {
        guard let item = items.first else { return }
        
        isUploading = true
        
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
                    selectedAttachment = tempAttachment
                    dismiss()
                }
            }
        } catch {
            print("[AttachmentPickerSheet] Error loading photo: \(error)")
        }
        
        isUploading = false
    }
}

struct AttachmentOptionView: View {
    let icon: String
    let title: String
    let subtitle: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(.blue)
                .frame(width: 40, height: 40)
                .background(Color.blue.opacity(0.1))
                .clipShape(Circle())
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .foregroundColor(.gray)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
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
                // Message text
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
                
                // Attachments
                if let attachments = message.attachments, !attachments.isEmpty {
                    ForEach(attachments, id: \.id) { attachment in
                        AttachmentView(attachment: attachment, isFromCurrentUser: isFromCurrentUser, isLastMessage: isLastMessage, isLastFromSender: isLastFromSender)
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
