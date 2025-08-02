import Foundation
import Combine
import SwiftUI

// MARK: - Chat Session Manager
@MainActor
class ChatSessionManager: ObservableObject {
    static let shared = ChatSessionManager()
    
    @Published var chatSessions: [ChatSession] = []
    @Published var unreadMessageCount: Int = 0
    
    private let chatCacheManager = ChatCacheManager.shared
    private let hproseInstance = HproseInstance.shared
    
    private init() {
        loadChatSessionsFromCoreData()
        updateUnreadMessageCount()
    }
    
    // MARK: - Core Data Methods
    
    /// Load chat sessions from Core Data
    private func loadChatSessionsFromCoreData() {
        let sessions = chatCacheManager.fetchChatSessions(for: hproseInstance.appUser.mid)
        chatSessions = sessions
        print("[ChatSessionManager] Loaded \(sessions.count) chat sessions from Core Data")
    }
    
    /// Save chat session to Core Data
    private func saveChatSessionToCoreData(_ session: ChatSession) {
        chatCacheManager.saveChatSession(session)
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
                
                // Group messages by conversation partner
                let messagesByPartner = Dictionary(grouping: newMessages) { message in
                    message.authorId == hproseInstance.appUser.mid ? message.receiptId : message.authorId
                }
                
                // Update or create chat sessions
                for (partnerId, messages) in messagesByPartner {
                    if let latestMessage = messages.max(by: { $0.timestamp < $1.timestamp }) {
                        await updateOrCreateChatSession(senderId: partnerId, message: latestMessage, hasNews: true)
                    }
                }
                
                            // Save updated sessions to Core Data
            for session in chatSessions {
                saveChatSessionToCoreData(session)
            }
            
            // Update unread message count after processing new messages
            updateUnreadMessageCount()
            } else {
                print("[ChatSessionManager] No new messages found")
            }
        } catch {
            print("[ChatSessionManager] Error checking backend for new messages: \(error)")
        }
    }
    
    /// Validates if a chat message has a valid chatSessionId
    private func isValidChatMessage(_ message: ChatMessage) -> Bool {
        // Check if chatSessionId is not empty and not just whitespace
        let isValidSessionId = !message.chatSessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        if !isValidSessionId {
            print("[ChatSessionManager] Ignoring message with invalid chatSessionId: \(message.id)")
        }
        
        return isValidSessionId
    }
    
    /// Update or create a chat session
    func updateOrCreateChatSession(senderId: String, message: ChatMessage, hasNews: Bool = false) async {
        // Validate the message before processing
        guard isValidChatMessage(message) else {
            print("[ChatSessionManager] Skipping session update for invalid message: \(message.id)")
            return
        }
        await MainActor.run {
            // Determine the receiptId (the other person in the conversation)
            let receiptId: String
            if message.authorId == hproseInstance.appUser.mid {
                // Message sent by current user, receiptId is the recipient
                receiptId = message.receiptId
            } else {
                // Message received by current user, receiptId is the sender
                receiptId = message.authorId
            }
            
            if let existingIndex = chatSessions.firstIndex(where: { session in
                session.userId == hproseInstance.appUser.mid && session.receiptId == receiptId
            }) {
                // Update existing session
                let existingSession = chatSessions[existingIndex]
                let updatedSession = ChatSession(
                    id: existingSession.id,
                    userId: hproseInstance.appUser.mid,
                    receiptId: receiptId,
                    lastMessage: message,
                    timestamp: message.timestamp,
                    hasNews: hasNews || existingSession.hasNews
                )
                chatSessions[existingIndex] = updatedSession
                print("[ChatSessionManager] Updated existing chat session for \(receiptId)")
            } else {
                // Create new session
                let newSession = ChatSession.createSession(
                    userId: hproseInstance.appUser.mid,
                    receiptId: receiptId,
                    lastMessage: message,
                    hasNews: hasNews
                )
                chatSessions.append(newSession)
                print("[ChatSessionManager] Created new chat session for \(receiptId)")
            }
            
            // Save updated sessions to Core Data
            for session in chatSessions {
                saveChatSessionToCoreData(session)
            }
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
            saveChatSessionToCoreData(updatedSession)
            updateUnreadMessageCount()
            print("[ChatSessionManager] Marked session as read for \(receiptId)")
        }
    }
    
    /// Get chat session for a specific user
    func getChatSession(for receiptId: String) -> ChatSession? {
        return chatSessions.first { session in
            session.receiptId == receiptId
        }
    }
    
    /// Remove a chat session and all associated messages
    func removeChatSession(receiptId: String) {
        // Remove the chat session from Core Data (this will cascade delete messages)
        chatCacheManager.deleteChatSessionByReceiptId(userId: hproseInstance.appUser.mid, receiptId: receiptId)
        
        // Remove from local array
        chatSessions.removeAll { $0.receiptId == receiptId }
        
        print("[ChatSessionManager] Removed chat session and messages for \(receiptId)")
    }
    
    /// Clear all chat sessions
    func clearAllChatSessions() {
        // Delete all sessions from Core Data
        for session in chatSessions {
            chatCacheManager.deleteChatSession(id: session.id)
        }
        
        // Clear local array
        chatSessions.removeAll()
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
            let validMessages = messages.filter { isValidChatMessage($0) }
            
            // Update the session with the latest valid message if available
            if let latestMessage = validMessages.max(by: { $0.timestamp < $1.timestamp }) {
                await updateOrCreateChatSession(senderId: receiptId, message: latestMessage, hasNews: false)
            }
            
            if validMessages.count != messages.count {
                print("[ChatSessionManager] Filtered out \(messages.count - validMessages.count) invalid messages from conversation")
            }
            
            return validMessages
        } catch {
            print("[ChatSessionManager] Error fetching messages for conversation: \(error)")
            return []
        }
    }
    
    // MARK: - Unread Message Management
    
    func updateUnreadMessageCount() {
        let totalUnread = chatSessions.reduce(0) { count, session in
            count + (session.hasNews ? 1 : 0)
        }
        unreadMessageCount = totalUnread
        print("[ChatSessionManager] Updated unread message count: \(unreadMessageCount)")
    }
    
    func markAllMessagesAsRead() {
        for session in chatSessions {
            if session.hasNews {
                markSessionAsRead(receiptId: session.receiptId)
            }
        }
        updateUnreadMessageCount()
    }
} 