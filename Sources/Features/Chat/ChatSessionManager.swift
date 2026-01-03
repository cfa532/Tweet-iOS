import Foundation
import Combine
import SwiftUI

// MARK: - Chat Session Manager
@MainActor
class ChatSessionManager: ObservableObject {
    static let shared = ChatSessionManager()
    
    @Published var chatSessions: [ChatSession] = []
    @Published var unreadMessageCount: Int = 0
    
    // Private property to track badge count since UNUserNotificationCenter doesn't provide a way to read it
    private var currentBadgeCount: Int = 0

    // Track which messages have already been notified to prevent duplicates
    private var notifiedMessageIds: Set<String> = []
    
    // Track deleted sessions to prevent them from being recreated by checkBackendForNewMessages
    private var deletedSessionIds: Set<String> = []

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
    /// - Parameter suppressNotifications: If true, only updates badge, doesn't trigger notifications
    func checkBackendForNewMessages(suppressNotifications: Bool = false) async {
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
                    // Skip if this session was explicitly deleted by the user
                    if deletedSessionIds.contains(partnerId) {
                        print("[ChatSessionManager] Skipping session creation for \(partnerId) - user deleted this session")
                        continue
                    }
                    
                    // Use the last message from the array (newest message)
                    if let lastMessage = messages.last {
                        // Check if session already exists using the other party's ID
                        let existingSession = chatSessions.first { session in
                            session.receiptId == partnerId
                        }
                        
                        if let existingSession = existingSession {
                            // Update session with the new last message (don't worry about duplicates)
                            if let index = chatSessions.firstIndex(where: { $0.receiptId == partnerId }) {
                                let updatedSession = ChatSession(
                                    id: partnerId,  // sessionId is the receiver's mid
                                    userId: existingSession.userId,
                                    receiptId: existingSession.receiptId,
                                    lastMessage: lastMessage,
                                    timestamp: lastMessage.timestamp,
                                    hasNews: true
                                )
                                chatSessions[index] = updatedSession
                                saveChatSessionToCoreData(updatedSession)
                                print("[ChatSessionManager] Updated session with new last message for \(partnerId): \(lastMessage.id)")
                                
                                // Trigger notification for new message (unless suppressed)
                                if !suppressNotifications {
                                    await triggerNotificationForMessage(lastMessage, partnerId: partnerId)
                                }
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
                            
                            // Trigger notification for new message (unless suppressed)
                            if !suppressNotifications {
                                await triggerNotificationForMessage(lastMessage, partnerId: partnerId)
                            }
                        }
                    }
                }
                
                // Update unread message count
                updateUnreadMessageCount()
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
        let displayMessage = summarizedMessage(for: message)
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
            
            // If this session was previously deleted, remove it from the deleted set
            // since the user is now starting a new conversation
            if deletedSessionIds.contains(otherPartyId) {
                deletedSessionIds.remove(otherPartyId)
                print("[ChatSessionManager] Removed \(otherPartyId) from deleted sessions - starting new conversation")
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
                    id: otherPartyId,  // sessionId is the receiver's mid
                    userId: hproseInstance.appUser.mid,
                    receiptId: otherPartyId,
                    lastMessage: displayMessage,
                    timestamp: displayMessage.timestamp,
                    hasNews: hasNews || existingSession.hasNews
                )
                chatSessions[existingIndex] = updatedSession
                print("[ChatSessionManager] Updated existing chat session for \(otherPartyId) with new message: \(message.id)")
            } else {
                // Create new session
                let newSession = ChatSession.createSession(
                    userId: hproseInstance.appUser.mid,
                    receiptId: otherPartyId,
                    lastMessage: displayMessage,
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
                id: receiptId,  // sessionId is the receiver's mid
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
        let userId = hproseInstance.appUser.mid
        
        // First, explicitly delete all messages for this conversation
        // This handles both linked and orphaned messages
        chatCacheManager.deleteMessagesForConversation(authorId: userId, receiptId: receiptId)
        print("[ChatSessionManager] Deleted messages for conversation between \(userId) and \(receiptId)")
        
        // Then remove the chat session from Core Data
        chatCacheManager.deleteChatSessionByReceiptId(userId: userId, receiptId: receiptId)
        
        // Remove from local array
        chatSessions.removeAll { $0.receiptId == receiptId }
        
        // Mark this session as deleted to prevent recreation from backend messages
        deletedSessionIds.insert(receiptId)
        
        // Update unread count after deletion
        updateUnreadMessageCount()
        
        print("[ChatSessionManager] Removed chat session and all messages for \(receiptId), marked as deleted")
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
        // Prevent duplicate notifications for the same message
        guard !notifiedMessageIds.contains(message.id) else {
            print("[ChatSessionManager] ⚠️ Message \(message.id) already notified, skipping duplicate")
            return
        }

        // Check if app is in background or inactive
        let appState = UIApplication.shared.applicationState
        print("[ChatSessionManager] 📱 App state: \(appState.rawValue) (0=active, 1=inactive, 2=background)")
        guard appState == .background || appState == .inactive else {
            print("[ChatSessionManager] ⚠️ App is in foreground, skipping notification and badge update for message: \(message.id)")
            // Don't update badge when app is in foreground - user can already see messages
            return
        }

        // Check notification permission
        let center = UNUserNotificationCenter.current()
        // Set delegate to NotificationManager so notifications are handled properly
        center.delegate = NotificationManager.shared

        let settings = await center.notificationSettings()
        print("[ChatSessionManager] 🔔 Notification permission status: \(settings.authorizationStatus.rawValue) (0=notDetermined, 1=denied, 2=authorized, 3=provisional, 4=ephemeral)")
        guard settings.authorizationStatus == .authorized else {
            print("[ChatSessionManager] ⚠️ No notification permission, updating badge only")
            // Update badge even without notification permission (app is in background)
            currentBadgeCount += 1
            let newBadge = currentBadgeCount > 9 ? -1 : currentBadgeCount
            DispatchQueue.main.async {
                UNUserNotificationCenter.current().setBadgeCount(newBadge) { error in
                    if let error = error {
                        print("[ChatSessionManager] Error setting badge count: \(error)")
                    } else {
                        print("[ChatSessionManager] Updated badge count to: \(newBadge > 9 ? "N" : "\(newBadge)")")
                    }
                }
            }
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
        
        // Update badge count BEFORE creating notification
        currentBadgeCount += 1
        let newBadge = currentBadgeCount > 9 ? -1 : currentBadgeCount

        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = senderName
        content.body = message.content ?? "New message"
        content.sound = .default
        content.badge = NSNumber(value: newBadge)

        // Set thread identifier to group messages from the same conversation
        content.threadIdentifier = message.chatSessionId

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
        let notificationIdentifier = "chat_message_\(message.id)"
        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: trigger
        )

        // Remove any pending notification with the same identifier to prevent duplicates
        // Don't remove delivered notifications - let them show naturally
        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])

        // Schedule the notification
        do {
            try await center.add(request)
            // Mark this message as notified to prevent duplicates
            notifiedMessageIds.insert(message.id)
            print("[ChatSessionManager] ✅ Chat notification scheduled for message: \(message.id), badge: \(newBadge)")
        } catch {
            print("[ChatSessionManager] ❌ Error scheduling notification: \(error)")
            // Don't mark as notified if scheduling failed, so it can be retried
        }

        // Update badge count on the app icon (also set in notification content above)
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().setBadgeCount(newBadge) { error in
                if let error = error {
                    print("[ChatSessionManager] Error setting badge count: \(error)")
                } else {
                    print("[ChatSessionManager] Updated app badge count to: \(newBadge > 9 ? "N" : "\(newBadge)")")
                }
            }
        }
        
        print("[ChatSessionManager] Triggered notification for message from \(senderName)")
    }

    // MARK: - Session Display Helpers
    private func summarizedMessage(for message: ChatMessage) -> ChatMessage {
        guard let summary = message.previewText(for: hproseInstance.appUser.mid) else {
            return message
        }
        let trimmedContent = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if summary == trimmedContent {
            return message
        }
        return ChatMessage(
            id: message.id,
            authorId: message.authorId,
            receiptId: message.receiptId,
            chatSessionId: message.chatSessionId,
            content: summary,
            timestamp: message.timestamp,
            attachments: message.attachments,
            success: message.success,
            errorMsg: message.errorMsg
        )
    }
}