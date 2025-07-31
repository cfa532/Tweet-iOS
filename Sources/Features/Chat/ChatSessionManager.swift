import Foundation
import Combine

// MARK: - Chat Session Manager
class ChatSessionManager: ObservableObject {
    static let shared = ChatSessionManager()
    
    @Published var chatSessions: [ChatSession] = []
    private let userDefaults = UserDefaults.standard
    private let chatSessionsKey = "chat_sessions"
    private let hproseInstance = HproseInstance.shared
    
    private init() {
        loadChatSessionsFromLocalStorage()
    }
    
    // MARK: - Local Storage Methods
    
    /// Load chat sessions from local storage
    private func loadChatSessionsFromLocalStorage() {
        guard let data = userDefaults.data(forKey: chatSessionsKey) else {
            chatSessions = []
            return
        }
        
        do {
            let sessions = try JSONDecoder().decode([ChatSession].self, from: data)
            chatSessions = sessions
            print("[ChatSessionManager] Loaded \(sessions.count) chat sessions from local storage")
        } catch {
            print("[ChatSessionManager] Error loading chat sessions from local storage: \(error)")
            chatSessions = []
        }
    }
    
    /// Save chat sessions to local storage
    private func saveChatSessionsToLocalStorage() {
        do {
            let data = try JSONEncoder().encode(chatSessions)
            userDefaults.set(data, forKey: chatSessionsKey)
            print("[ChatSessionManager] Saved \(chatSessions.count) chat sessions to local storage")
        } catch {
            print("[ChatSessionManager] Error saving chat sessions to local storage: \(error)")
        }
    }
    
    // MARK: - Public Methods
    
    /// Load chat sessions from local storage first, then check backend for updates
    func loadChatSessions() async {
        // Load from local storage first (already done in init)
        print("[ChatSessionManager] Loading chat sessions from local storage")
        
        // Check backend for new messages and update sessions
        await checkBackendForNewMessages()
    }
    
    /// Check backend for new messages and update chat sessions
    func checkBackendForNewMessages() async {
        do {
            let newMessages = try await hproseInstance.checkNewMessages()
            
            if !newMessages.isEmpty {
                print("[ChatSessionManager] Found \(newMessages.count) new messages from backend")
                
                // Group messages by sender
                let messagesBySender = Dictionary(grouping: newMessages) { message in
                    message.authorId == hproseInstance.appUser.mid ? message.receiptId : message.authorId
                }
                
                // Update or create chat sessions
                for (senderId, messages) in messagesBySender {
                    if let latestMessage = messages.max(by: { $0.timestamp < $1.timestamp }) {
                        await updateOrCreateChatSession(senderId: senderId, message: latestMessage, hasNews: true)
                    }
                }
                
                // Save updated sessions to local storage
                saveChatSessionsToLocalStorage()
            } else {
                print("[ChatSessionManager] No new messages found")
            }
        } catch {
            print("[ChatSessionManager] Error checking backend for new messages: \(error)")
        }
    }
    
    /// Update or create a chat session
    func updateOrCreateChatSession(senderId: String, message: ChatMessage, hasNews: Bool = false) async {
        await MainActor.run {
            if let existingIndex = chatSessions.firstIndex(where: { session in
                session.receiptId == senderId || session.receiptId == message.authorId
            }) {
                // Update existing session
                let existingSession = chatSessions[existingIndex]
                let updatedSession = ChatSession(
                    id: existingSession.id,
                    userId: existingSession.userId,
                    receiptId: existingSession.receiptId,
                    lastMessage: message,
                    timestamp: message.timestamp,
                    hasNews: hasNews || existingSession.hasNews
                )
                chatSessions[existingIndex] = updatedSession
                print("[ChatSessionManager] Updated existing chat session for \(senderId)")
            } else {
                // Create new session
                let newSession = ChatSession(
                    userId: hproseInstance.appUser.mid,
                    receiptId: senderId,
                    lastMessage: message,
                    timestamp: message.timestamp,
                    hasNews: hasNews
                )
                chatSessions.append(newSession)
                print("[ChatSessionManager] Created new chat session for \(senderId)")
            }
            
            // Save updated sessions to local storage
            saveChatSessionsToLocalStorage()
        }
    }
    
    /// Mark a chat session as read (no new messages)
    func markSessionAsRead(receiptId: String) {
        if let index = chatSessions.firstIndex(where: { $0.receiptId == receiptId }) {
            let session = chatSessions[index]
            let updatedSession = ChatSession(
                id: session.id,
                userId: session.userId,
                receiptId: session.receiptId,
                lastMessage: session.lastMessage,
                timestamp: session.timestamp,
                hasNews: false
            )
            chatSessions[index] = updatedSession
            saveChatSessionsToLocalStorage()
            print("[ChatSessionManager] Marked session as read for \(receiptId)")
        }
    }
    
    /// Get chat session for a specific user
    func getChatSession(for receiptId: String) -> ChatSession? {
        return chatSessions.first { session in
            session.receiptId == receiptId
        }
    }
    
    /// Remove a chat session
    func removeChatSession(receiptId: String) {
        chatSessions.removeAll { $0.receiptId == receiptId }
        saveChatSessionsToLocalStorage()
        print("[ChatSessionManager] Removed chat session for \(receiptId)")
    }
    
    /// Clear all chat sessions
    func clearAllChatSessions() {
        chatSessions.removeAll()
        saveChatSessionsToLocalStorage()
        print("[ChatSessionManager] Cleared all chat sessions")
    }
    
    /// Get unread message count
    func getUnreadMessageCount() -> Int {
        return chatSessions.filter { $0.hasNews }.count
    }
    
    /// Fetch messages for a specific conversation and update the session
    func fetchMessagesForConversation(receiptId: String) async -> [ChatMessage] {
        do {
            let messages = try await hproseInstance.fetchMessages(senderId: receiptId)
            
            // Update the session with the latest message if available
            if let latestMessage = messages.max(by: { $0.timestamp < $1.timestamp }) {
                await updateOrCreateChatSession(senderId: receiptId, message: latestMessage, hasNews: false)
            }
            
            return messages
        } catch {
            print("[ChatSessionManager] Error fetching messages for conversation: \(error)")
            return []
        }
    }
} 