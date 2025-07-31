import Foundation

class ChatRepository: ObservableObject {
    @Published var chatSessions: [ChatSession] = []
    @Published var chatMessages: [ChatMessage] = []
    
    private let hproseInstance = HproseInstance.shared
    private let chatSessionManager = ChatSessionManager.shared
    private let userDefaults = UserDefaults.standard
    private let messagesKey = "chat_messages"
    
    /// Load chat sessions for the current user
    func loadChatSessions() async {
        await chatSessionManager.loadChatSessions()
        await MainActor.run {
            self.chatSessions = chatSessionManager.chatSessions
        }
    }
    
    /// Load messages for a specific chat conversation
    func loadMessages(for receiptId: String) async {
        do {
            // Fetch messages from the sender (receiptId is the sender's ID)
            let messages = try await hproseInstance.fetchMessages(senderId: receiptId)
            await MainActor.run {
                self.chatMessages = messages
            }
            
            // Save messages to local storage
            addMessagesToLocalStorage(messages)
            
            print("[ChatRepository] Loaded \(messages.count) messages from sender \(receiptId)")
        } catch {
            print("[ChatRepository] Error loading messages: \(error)")
        }
    }
    
    /// Send a message to a recipient
    func sendMessage(_ message: ChatMessage) async {
        do {
            try await hproseInstance.sendMessage(receiptId: message.receiptId, message: message)
            
            // Add the message to the local messages array
            await MainActor.run {
                self.chatMessages.append(message)
            }
            
            // Save to local storage
            addMessagesToLocalStorage([message])
            
            // Update chat session with the sent message
            await chatSessionManager.updateOrCreateChatSession(
                senderId: message.receiptId,
                message: message,
                hasNews: false
            )
            
            // Update the chat sessions in the repository
            await MainActor.run {
                self.chatSessions = chatSessionManager.chatSessions
            }
            
            print("[ChatRepository] Message sent successfully to \(message.receiptId)")
        } catch {
            print("[ChatRepository] Error sending message: \(error)")
        }
    }
    
    /// Update chat session status
    func updateSession(receiptId: String, hasNews: Bool) async {
        // TODO: Implement updating chat session
        // This would typically update the session in the backend
        print("[ChatRepository] Updating session for \(receiptId), hasNews: \(hasNews)")
    }
    
    /// Fetch new messages from the server
    func fetchNewMessages() async {
        do {
            let newMessages = try await hproseInstance.checkNewMessages()
            await MainActor.run {
                // Merge new messages with existing ones
                for message in newMessages {
                    if !self.chatMessages.contains(where: { $0.id == message.id }) {
                        self.chatMessages.append(message)
                    }
                }
            }
            print("[ChatRepository] Fetched \(newMessages.count) new messages")
        } catch {
            print("[ChatRepository] Error fetching new messages: \(error)")
        }
    }
    
    /// Get messages for a specific conversation
    func getMessages(for receiptId: String) -> [ChatMessage] {
        return chatMessages.filter { $0.authorId == receiptId || $0.receiptId == receiptId }
    }
    
    /// Clear messages for a specific conversation
    func clearMessages(for receiptId: String) {
        chatMessages.removeAll { $0.authorId == receiptId || $0.receiptId == receiptId }
        saveMessagesToLocalStorage()
    }
    
    // MARK: - Local Storage Methods
    
    /// Save messages to local storage
    private func saveMessagesToLocalStorage() {
        do {
            let data = try JSONEncoder().encode(chatMessages)
            userDefaults.set(data, forKey: messagesKey)
            print("[ChatRepository] Saved \(chatMessages.count) messages to local storage")
        } catch {
            print("[ChatRepository] Error saving messages to local storage: \(error)")
        }
    }
    
    /// Load messages from local storage
    private func loadMessagesFromLocalStorage() {
        guard let data = userDefaults.data(forKey: messagesKey) else {
            chatMessages = []
            return
        }
        
        do {
            let messages = try JSONDecoder().decode([ChatMessage].self, from: data)
            chatMessages = messages
            print("[ChatRepository] Loaded \(messages.count) messages from local storage")
        } catch {
            print("[ChatRepository] Error loading messages from local storage: \(error)")
            chatMessages = []
        }
    }
    
    /// Get the last N messages for a specific conversation from local storage
    func getLastMessages(for receiptId: String, limit: Int = 50) -> [ChatMessage] {
        let conversationMessages = chatMessages.filter { message in
            message.authorId == receiptId || message.receiptId == receiptId
        }
        
        // Sort by timestamp (oldest first) and get the last N messages
        let sortedMessages = conversationMessages.sorted { $0.timestamp < $1.timestamp }
        return Array(sortedMessages.suffix(limit))
    }
    
    /// Add messages to local storage
    func addMessagesToLocalStorage(_ newMessages: [ChatMessage]) {
        for message in newMessages {
            if !chatMessages.contains(where: { $0.id == message.id }) {
                chatMessages.append(message)
            }
        }
        saveMessagesToLocalStorage()
    }
    
    /// Initialize the repository
    init() {
        loadMessagesFromLocalStorage()
    }
} 