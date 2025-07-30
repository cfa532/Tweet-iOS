import Foundation

class ChatRepository: ObservableObject {
    @Published var chatSessions: [ChatSession] = []
    @Published var chatMessages: [ChatMessage] = []
    
    private let hproseInstance = HproseInstance.shared
    private let chatSessionManager = ChatSessionManager.shared
    
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
    }
} 