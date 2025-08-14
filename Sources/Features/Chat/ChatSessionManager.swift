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
        // Don't load sessions immediately - wait for user to be available
        // Sessions will be loaded when the user is properly initialized
    }
    
    // MARK: - Core Data Methods
    
    /// Load chat sessions from Core Data
    private func loadChatSessionsFromCoreData() {
        // Check if user ID is available and not guest
        guard hproseInstance.appUser.mid != Constants.GUEST_ID else {
            print("[ChatSessionManager] Cannot load sessions - user is still guest")
            return
        }
        
        print("[ChatSessionManager] Loading sessions for user ID: \(hproseInstance.appUser.mid)")
        let sessions = chatCacheManager.fetchChatSessions(for: hproseInstance.appUser.mid)
        chatSessions = sessions
        print("[ChatSessionManager] Loaded \(sessions.count) chat sessions from Core Data for user: \(hproseInstance.appUser.mid)")
        
        // Debug: Print session details
        for session in sessions {
            print("[ChatSessionManager] Session: \(session.receiptId), timestamp: \(session.timestamp), hasNews: \(session.hasNews)")
        }
    }
    
    /// Save chat session to Core Data
    private func saveChatSessionToCoreData(_ session: ChatSession) {
        chatCacheManager.saveChatSession(session)
    }
    
    // MARK: - Public Methods
    
    /// Load chat sessions from local storage first, then check backend for updates
    func loadChatSessions() async {
        // Load from local storage first
        loadChatSessionsFromCoreData()
        print("[ChatSessionManager] Loading chat sessions from local storage")
        
        // Only check backend for new messages, don't overwrite existing sessions
        await checkBackendForNewMessages()
    }
    
    /// Force reload chat sessions from Core Data (useful for debugging)
    func reloadChatSessionsFromCoreData() {
        loadChatSessionsFromCoreData()
        updateUnreadMessageCount()
        print("[ChatSessionManager] Force reloaded chat sessions from Core Data")
    }
    
    /// Load sessions when user is properly initialized
    func loadSessionsWhenUserAvailable() {
        loadChatSessionsFromCoreData()
        updateUnreadMessageCount()
        print("[ChatSessionManager] Loaded sessions after user initialization")
    }
    
    /// Check backend for new messages (for notification purposes only)
    func checkBackendForNewMessages() async {
        do {
            let newMessages = try await hproseInstance.checkNewMessages()
            
            if !newMessages.isEmpty {
                print("[ChatSessionManager] Found \(newMessages.count) new messages from backend")
                
                // Group messages by conversation partner
                let messagesByPartner = Dictionary(grouping: newMessages) { message in
                    message.authorId == hproseInstance.appUser.mid ? message.receiptId : message.authorId
                }
                
                // Update or create chat sessions (only add new ones, don't overwrite existing)
                for (partnerId, messages) in messagesByPartner {
                    // Use the last message from the array (newest message)
                    if let lastMessage = messages.last {
                        // Check if session already exists using the other party's ID
                        let existingSession = chatSessions.first { session in
                            session.receiptId == partnerId
                        }
                        
                        if let existingSession = existingSession {
                            // Update session with the new last message (don't worry about duplicates)
                            if let index = chatSessions.firstIndex(where: { $0.id == existingSession.id }) {
                                let updatedSession = ChatSession(
                                    id: existingSession.id,
                                    userId: existingSession.userId,
                                    receiptId: existingSession.receiptId,
                                    lastMessage: lastMessage,
                                    timestamp: lastMessage.timestamp,
                                    hasNews: true
                                )
                                chatSessions[index] = updatedSession
                                saveChatSessionToCoreData(updatedSession)
                                print("[ChatSessionManager] Updated session with new last message for \(partnerId): \(lastMessage.id)")
                                
                                // Trigger notification for new message
                                await triggerNotificationForMessage(lastMessage, partnerId: partnerId)
                            }
                        } else {
                            // No existing session - create new session with the actual message
                            // The message is stored as a copy in the session, not saved to Core Data yet
                            print("[ChatSessionManager] Creating new session with user ID: \(hproseInstance.appUser.mid), partner ID: \(partnerId)")
                            let newSession = ChatSession.createSession(
                                userId: hproseInstance.appUser.mid,
                                receiptId: partnerId,
                                lastMessage: lastMessage,
                                hasNews: true
                            )
                            chatSessions.append(newSession)
                            saveChatSessionToCoreData(newSession)
                            print("[ChatSessionManager] Created new session for \(partnerId) with actual message: \(lastMessage.id)")
                            
                            // Trigger notification for new message
                            await triggerNotificationForMessage(lastMessage, partnerId: partnerId)
                        }
                    }
                }
                
                // Update unread message count
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
            // Determine the other party's ID (the person we're chatting with)
            let otherPartyId: MimeiId
            if message.authorId == hproseInstance.appUser.mid {
                // Message sent by current user, other party is the recipient
                otherPartyId = message.receiptId
            } else {
                // Message received by current user, other party is the sender
                otherPartyId = message.authorId
            }
            
            if let existingIndex = chatSessions.firstIndex(where: { session in
                session.receiptId == otherPartyId
            }) {
                // Check if this message ID already exists in the current session to avoid duplicates
                let existingSession = chatSessions[existingIndex]
                
                // Check if this message is already the last message
                if existingSession.lastMessage.id == message.id {
                    print("[ChatSessionManager] Skipping duplicate message for \(otherPartyId), message ID: \(message.id) is already the last message")
                    return
                }
                
                // Always update the session with the new message
                // Don't rely on timestamps as they are not trustworthy across devices
                let updatedSession = ChatSession(
                    id: existingSession.id,
                    userId: hproseInstance.appUser.mid,
                    receiptId: otherPartyId,
                    lastMessage: message,
                    timestamp: message.timestamp,
                    hasNews: hasNews || existingSession.hasNews
                )
                chatSessions[existingIndex] = updatedSession
                print("[ChatSessionManager] Updated existing chat session for \(otherPartyId) with new message: \(message.id)")
            } else {
                // Create new session
                let newSession = ChatSession.createSession(
                    userId: hproseInstance.appUser.mid,
                    receiptId: otherPartyId,
                    lastMessage: message,
                    hasNews: hasNews
                )
                chatSessions.append(newSession)
                print("[ChatSessionManager] Created new chat session for \(otherPartyId)")
            }
            
            // Save updated sessions to Core Data
            for session in chatSessions {
                saveChatSessionToCoreData(session)
            }
            print("[ChatSessionManager] Saved \(chatSessions.count) sessions to Core Data after session update")
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
    func removeChatSession(receiptId: MimeiId) {
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
    
    // MARK: - Notification Handling
    
    private func triggerNotificationForMessage(_ message: ChatMessage, partnerId: String) async {
        // Check if app is in background or inactive
        let appState = UIApplication.shared.applicationState
        guard appState == .background || appState == .inactive else {
            print("[ChatSessionManager] App is in foreground, skipping notification for message: \(message.id)")
            return
        }
        
        // Check notification permission
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else {
            print("[ChatSessionManager] No notification permission, skipping notification")
            return
        }
        
        // Get sender name by fetching user details
        var senderName = partnerId
        do {
            if let user = try await hproseInstance.fetchUser(partnerId) {
                senderName = user.name ?? user.username ?? partnerId
            }
        } catch {
            print("[ChatSessionManager] Error fetching user details for notification: \(error)")
            // Fallback to partnerId if user fetch fails
        }
        
        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = senderName
        content.body = message.content ?? "New message"
        content.sound = .default
        
        // Add custom data for handling notification tap
        content.userInfo = [
            "messageId": message.id,
            "senderId": message.authorId,
            "chatSessionId": message.chatSessionId,
            "type": "chat_message"
        ]
        
        // Create notification trigger (immediate)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        
        // Create notification request
        let request = UNNotificationRequest(
            identifier: "chat_message_\(message.id)",
            content: content,
            trigger: trigger
        )
        
        // Schedule the notification
        do {
            try await center.add(request)
            print("[ChatSessionManager] Chat notification scheduled for message: \(message.id)")
        } catch {
            print("[ChatSessionManager] Error scheduling notification: \(error)")
        }
        
        // Update badge count
        let currentBadge = UIApplication.shared.applicationIconBadgeNumber
        let newBadge = currentBadge > 9 ? -1 : currentBadge + 1
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = newBadge
        }
        
        print("[ChatSessionManager] Triggered notification for message from \(senderName)")
    }
}