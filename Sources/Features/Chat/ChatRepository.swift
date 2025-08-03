import Foundation
import CoreData

class ChatRepository: ObservableObject {
    @Published var chatSessions: [ChatSession] = []
    @Published var chatMessages: [ChatMessage] = []
    
    private let hproseInstance = HproseInstance.shared
    @MainActor private let chatSessionManager = ChatSessionManager.shared
    private let chatCacheManager = ChatCacheManager.shared
    
    /// Load chat sessions for the current user
    func loadChatSessions() async {
        await chatSessionManager.loadChatSessions()
        await MainActor.run {
            self.chatSessions = chatSessionManager.chatSessions
        }
    }
    
    /// Load messages for a specific chat conversation
    func loadMessages(for receiptId: MimeiId) async {
        do {
            // Fetch messages from the sender (receiptId is the sender's ID)
            let messages = try await hproseInstance.fetchMessages(senderId: receiptId)
            await MainActor.run {
                self.chatMessages = messages
            }
            
            // Save messages to Core Data
            for message in messages {
                saveMessageToCoreData(message)
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
            
            // Save to Core Data
            saveMessageToCoreData(message)
            
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
            let validMessages = newMessages.filter { isValidChatMessage($0) }
            
            await MainActor.run {
                // Merge new messages with existing ones
                for message in validMessages {
                    if !self.chatMessages.contains(where: { $0.id == message.id }) {
                        self.chatMessages.append(message)
                    }
                }
            }
            
            if validMessages.count != newMessages.count {
                print("[ChatRepository] Filtered out \(newMessages.count - validMessages.count) invalid messages from new messages")
            }
            
            print("[ChatRepository] Fetched \(validMessages.count) valid new messages (filtered from \(newMessages.count) total)")
        } catch {
            print("[ChatRepository] Error fetching new messages: \(error)")
        }
    }
    
    /// Get messages for a specific conversation
    func getMessages(for receiptId: String) -> [ChatMessage] {
        return chatCacheManager.fetchMessages(for: receiptId, userId: hproseInstance.appUser.mid)
    }
    
    /// Clear messages for a specific conversation
    func clearMessages(for receiptId: String) {
        chatCacheManager.deleteMessagesForConversation(authorId: hproseInstance.appUser.mid, receiptId: receiptId)
        // Update local array
        chatMessages.removeAll { $0.authorId == receiptId || $0.receiptId == receiptId }
    }
    
    /// Delete all messages for a conversation using authorId and receiptId pair
    func deleteMessagesForConversation(authorId: String, receiptId: String) async {
        await MainActor.run {
            // Delete from Core Data
            chatCacheManager.deleteMessagesForConversation(authorId: authorId, receiptId: receiptId)
            
            // Update local array
            let messagesToRemove = chatMessages.filter { message in
                (message.authorId == authorId && message.receiptId == receiptId) ||
                (message.authorId == receiptId && message.receiptId == authorId)
            }
            
            for message in messagesToRemove {
                chatMessages.removeAll { $0.id == message.id }
            }
        }
    }
    
    // MARK: - Core Data Methods
    
    /// Save message to Core Data
    private func saveMessageToCoreData(_ message: ChatMessage) {
        chatCacheManager.saveChatMessage(message)
    }
    
    /// Load messages from Core Data
    private func loadMessagesFromCoreData() {
        // This will be called when needed for specific conversations
        chatMessages = []
    }
    
    /// Get the last N messages for a specific conversation from Core Data
    func getLastMessages(for receiptId: String, limit: Int = 50) -> [ChatMessage] {
        let allMessages = chatCacheManager.fetchMessages(for: receiptId, userId: hproseInstance.appUser.mid)
        return Array(allMessages.suffix(limit))
    }
    
    /// Validates if a chat message has a valid chatSessionId
    private func isValidChatMessage(_ message: ChatMessage) -> Bool {
        // Check if chatSessionId is not empty and not just whitespace
        let isValidSessionId = !message.chatSessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        if !isValidSessionId {
            print("[ChatRepository] Ignoring message with invalid chatSessionId: \(message.id)")
        }
        
        return isValidSessionId
    }
    
    /// Add messages to Core Data
    func addMessagesToCoreData(_ newMessages: [ChatMessage]) {
        let validMessages = newMessages.filter { isValidChatMessage($0) }
        
        for message in validMessages {
            saveMessageToCoreData(message)
        }
        
        if validMessages.count != newMessages.count {
            print("[ChatRepository] Filtered out \(newMessages.count - validMessages.count) invalid messages")
        }
        
        print("[ChatRepository] Added \(validMessages.count) messages to Core Data")
    }
    
    /// Initialize the repository
    init() {
        loadMessagesFromCoreData()
    }
} 
