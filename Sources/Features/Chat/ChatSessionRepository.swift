import Foundation
import Combine

// MARK: - Chat Session Entity (Database Model)
struct ChatSessionEntity: Codable {
    let userId: String
    let receiptId: String
    let lastMessageId: String
    let timestamp: TimeInterval
    let hasNews: Bool
}

// MARK: - Chat Message Entity (Database Model)
struct ChatMessageEntity: Codable {
    let id: String
    let authorId: String
    let receiptId: String
    let content: String
    let timestamp: TimeInterval
}

// MARK: - Data Access Objects (DAO)
protocol ChatSessionDao {
    func getAllSessions(for userId: String) async -> [ChatSessionEntity]
    func getSession(userId: String, receiptId: String) async -> ChatSessionEntity?
    func updateSession(userId: String, receiptId: String, timestamp: TimeInterval, lastMessageId: String, hasNews: Bool) async
    func insertSession(_ session: ChatSessionEntity) async
}

protocol ChatMessageDao {
    func getMessageById(_ id: String) async -> ChatMessageEntity?
    func getLatestMessage(userId: String, receiptId: String) async -> ChatMessageEntity?
}

// MARK: - Chat Session Repository
class ChatSessionRepository: ObservableObject {
    private let chatSessionDao: ChatSessionDao
    private let chatMessageDao: ChatMessageDao
    private let hproseInstance = HproseInstance.shared
    
    @Published var chatSessions: [ChatSession] = []
    
    init(chatSessionDao: ChatSessionDao, chatMessageDao: ChatMessageDao) {
        self.chatSessionDao = chatSessionDao
        self.chatMessageDao = chatMessageDao
    }
    
    // MARK: - Public Methods
    
    /// Get all chat sessions for the current user
    func getAllSessions() async -> [ChatSession] {
        let sessionEntities = await chatSessionDao.getAllSessions(for: hproseInstance.appUser.mid)
        
        var sessions: [ChatSession] = []
        
        for sessionEntity in sessionEntities {
            if let lastMessageEntity = await chatMessageDao.getMessageById(sessionEntity.lastMessageId) {
                let chatMessage = lastMessageEntity.toChatMessage()
                let chatSession = sessionEntity.toChatSession(chatMessage)
                sessions.append(chatSession)
            }
        }
        
        await MainActor.run {
            self.chatSessions = sessions
        }
        
        return sessions
    }
    
    /// Update chat session with new message information
    func updateChatSession(userId: String, receiptId: String, hasNews: Bool) async {
        let sessionEntity = await chatSessionDao.getSession(userId: userId, receiptId: receiptId)
        let lastMessageEntity = await chatMessageDao.getLatestMessage(userId: userId, receiptId: receiptId)
        
        guard let messageEntity = lastMessageEntity else { return }
        
        if sessionEntity != nil {
            await chatSessionDao.updateSession(
                userId: userId,
                receiptId: receiptId,
                timestamp: messageEntity.timestamp,
                lastMessageId: messageEntity.id,
                hasNews: hasNews
            )
        } else {
            let newSession = ChatSessionEntity(
                userId: userId,
                receiptId: receiptId,
                lastMessageId: messageEntity.id,
                timestamp: messageEntity.timestamp,
                hasNews: hasNews
            )
            await chatSessionDao.insertSession(newSession)
        }
    }
    
    /**
     * Update existing chat sessions with incoming chat messages.
     * Chat message is identified by its normalized pair of authorId and receiptId.
     * The session's author is always the current app user, and its receipt is the one
     * engaging in conversation with the appUser.
     */
    func mergeMessagesWithSessions(
        existingSessions: [ChatSession],
        newMessages: [ChatMessage]
    ) -> [ChatSession] {
        
        // A map using senderId and receiptId as key, and ChatMessage as value
        var messageMap: [Pair<String, String>: ChatMessage] = [:]
        
        func normalizedKey(message: ChatMessage) -> Pair<String, String> {
            if message.receiptId < message.authorId {
                return Pair(message.receiptId, message.authorId)
            } else {
                return Pair(message.authorId, message.receiptId)
            }
        }
        
        // Add existing messages to the map
        for session in existingSessions {
            let message = session.lastMessage
            let key = normalizedKey(message: message)
            messageMap[key] = message
        }
        
        // Merge new messages into the map, by replacing old last messages
        for message in newMessages {
            let key = normalizedKey(message: message)
            let existingMessage = messageMap[key]
            if existingMessage == nil || message.timestamp > existingMessage!.timestamp {
                messageMap[key] = message
            }
        }
        
        var updatedSessions = existingSessions
        
        for (key, message) in messageMap {
            let existingSession = existingSessions.first { session in
                session.receiptId == key.first || session.receiptId == key.second
            }
            
            if existingSession == nil {
                // A new session is created
                let newSession = ChatSession(
                    userId: hproseInstance.appUser.mid,
                    receiptId: key.first == hproseInstance.appUser.mid ? key.second : key.first,
                    lastMessage: message,
                    timestamp: message.timestamp,
                    hasNews: true
                )
                updatedSessions.append(newSession)
            } else if message.timestamp > existingSession!.lastMessage.timestamp {
                // Existing session is updated with new message
                if let index = updatedSessions.firstIndex(where: { $0.id == existingSession!.id }) {
                    updatedSessions[index] = existingSession!.copy(
                        lastMessage: message,
                        timestamp: message.timestamp,
                        hasNews: true
                    )
                }
            }
        }
        
        return updatedSessions
    }
}

// MARK: - Extensions

extension ChatMessageEntity {
    func toChatMessage() -> ChatMessage {
        return ChatMessage(
            id: id,
            authorId: authorId,
            receiptId: receiptId,
            content: content,
            timestamp: timestamp
        )
    }
}

extension ChatSessionEntity {
    func toChatSession(_ lastMessage: ChatMessage) -> ChatSession {
        return ChatSession(
            userId: userId,
            receiptId: receiptId,
            lastMessage: lastMessage,
            timestamp: timestamp,
            hasNews: hasNews
        )
    }
}

extension ChatSession {
    func copy(
        id: String? = nil,
        userId: String? = nil,
        receiptId: String? = nil,
        lastMessage: ChatMessage? = nil,
        timestamp: TimeInterval? = nil,
        hasNews: Bool? = nil
    ) -> ChatSession {
        return ChatSession(
            id: id ?? self.id,
            userId: userId ?? self.userId,
            receiptId: receiptId ?? self.receiptId,
            lastMessage: lastMessage ?? self.lastMessage,
            timestamp: timestamp ?? self.timestamp,
            hasNews: hasNews ?? self.hasNews
        )
    }
}

// MARK: - Pair Helper
struct Pair<T: Hashable, U: Hashable>: Hashable {
    let first: T
    let second: U
    
    init(_ first: T, _ second: U) {
        self.first = first
        self.second = second
    }
} 
