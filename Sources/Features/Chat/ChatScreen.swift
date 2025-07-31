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
                if let user = user {
                    Avatar(user: user, size: 32)
                    VStack(alignment: .leading) {
                        Text("\(user.name ?? "")@\(user.username ?? "")")
                            .font(.headline)
                        if let profile = user.profile {
                            Text(profile)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
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
                        ForEach(messages) { message in
                            ChatMessageView(message: message, isFromCurrentUser: message.authorId == HproseInstance.shared.appUser.mid)
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
                            .foregroundColor(.blue)
                    }
                    
                    // Text input
                    TextField("Type a message...", text: $messageText, axis: .vertical)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .lineLimit(1...5)
                        .focused($isTextFieldFocused)
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
            
            print("[ChatScreen] Finished loading chat. User: \(user?.name ?? "nil"), Messages: \(messages.count)")
        }
        .sheet(isPresented: $showingAttachmentPicker) {
            AttachmentPickerSheet(selectedAttachment: $selectedAttachment)
        }
    }
    
    private func sendMessage() {
        guard canSendMessage && !isSendingMessage else { return }
        
        let message = ChatMessage(
            authorId: HproseInstance.shared.appUser.mid,
            receiptId: receiptId,
            content: messageText.trimmingCharacters(in: .whitespacesAndNewlines),
            attachment: selectedAttachment
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
        await MainActor.run {
            messages = localMessages
        }
        
        print("[ChatScreen] Loaded \(localMessages.count) messages from local storage")
        
        // Then, fetch new messages from backend
        do {
            let backendMessages = try await HproseInstance.shared.fetchMessages(senderId: receiptId)
            
            // Merge new messages with existing ones, avoiding duplicates
            var allMessages = Set(messages)
            for message in backendMessages {
                allMessages.insert(message)
            }
            
            // Convert back to array and sort by timestamp
            let sortedMessages = Array(allMessages).sorted { $0.timestamp < $1.timestamp }
            
            await MainActor.run {
                messages = sortedMessages
            }
            
            // Save new messages to local storage
            chatRepository.addMessagesToLocalStorage(backendMessages)
            
            print("[ChatScreen] Fetched \(backendMessages.count) messages from backend, total: \(sortedMessages.count)")
        } catch {
            print("[ChatScreen] Error fetching messages from backend: \(error)")
        }
    }
    
    // MARK: - Helper Methods
    
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

struct ChatMessageView: View {
    let message: ChatMessage
    let isFromCurrentUser: Bool
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !isFromCurrentUser {
                // Avatar for received messages (LEFT)
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "person")
                            .foregroundColor(.gray)
                    )
            }
            
            // Message content
            VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: 4) {
                // Message text
                if !message.content.isEmpty {
                    Text(message.content)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            isFromCurrentUser ? Color.blue : Color(.systemGray5)
                        )
                        .foregroundColor(
                            isFromCurrentUser ? .white : .primary
                        )
                        .clipShape(ChatBubbleShape(isFromCurrentUser: isFromCurrentUser))
                }
                
                // Attachment
                if let attachment = message.attachment {
                    AttachmentView(attachment: attachment, isFromCurrentUser: isFromCurrentUser)
                }
                
                // Timestamp
                Text(formatTime(message.timestamp))
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity, alignment: isFromCurrentUser ? .trailing : .leading)
            
            if isFromCurrentUser {
                // Avatar for sent messages (RIGHT)
                Avatar(user: HproseInstance.shared.appUser, size: 32)
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
        .clipShape(ChatBubbleShape(isFromCurrentUser: isFromCurrentUser))
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