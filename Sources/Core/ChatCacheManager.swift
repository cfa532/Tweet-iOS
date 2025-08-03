import CoreData
import Foundation
import UIKit

class ChatCacheManager {
    static let shared = ChatCacheManager()
    private let coreDataManager = CoreDataManager.shared
    private let maxCacheAge: TimeInterval = 30 * 24 * 60 * 60 // 30 days for chat data
    private let maxCacheSize: Int = 5000 // Maximum number of messages to cache
    private var cleanupTimer: Timer?

    private init() {
        // Set up periodic cleanup
        setupPeriodicCleanup()
        
        // Register for memory warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    deinit {
        cleanupTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupPeriodicCleanup() {
        // Clean up every 6 hours
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 21600, repeats: true) { [weak self] _ in
            self?.performPeriodicCleanup()
        }
    }
    
    @objc private func handleMemoryWarning() {
        performPeriodicCleanup()
    }
    
    private func performPeriodicCleanup() {
        context.performAndWait {
            // Delete expired messages
            deleteExpiredMessages()
            
            // Limit total number of messages
            let request: NSFetchRequest<CDChatMessage> = CDChatMessage.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "timeCached", ascending: false)]
            request.fetchLimit = maxCacheSize
            
            if let allMessages = try? context.fetch(request) {
                if allMessages.count > maxCacheSize {
                    let messagesToDelete = Array(allMessages[maxCacheSize...])
                    for message in messagesToDelete {
                        context.delete(message)
                    }
                    try? context.save()
                }
            }
        }
    }
    
    var context: NSManagedObjectContext { coreDataManager.context }
}

// MARK: - Chat Session Caching
extension ChatCacheManager {
    func saveChatSession(_ session: ChatSession) {
        context.performAndWait {
            let request: NSFetchRequest<CDChatSession> = CDChatSession.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", session.id)
            let cdSession = (try? context.fetch(request).first) ?? CDChatSession(context: context)
            
            cdSession.id = session.id
            cdSession.userId = session.userId
            cdSession.receiptId = session.receiptId
            cdSession.lastMessageId = session.lastMessage.id
            cdSession.timestamp = Date(timeIntervalSince1970: session.timestamp)
            cdSession.hasNews = session.hasNews
            cdSession.timeCached = Date()
            
            try? context.save()
        }
    }
    
    func fetchChatSessions(for userId: String) -> [ChatSession] {
        var sessions: [ChatSession] = []
        context.performAndWait {
            let request: NSFetchRequest<CDChatSession> = CDChatSession.fetchRequest()
            request.predicate = NSPredicate(format: "userId == %@", userId)
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            
            if let cdSessions = try? context.fetch(request) {
                for cdSession in cdSessions {
                    if let session = convertToChatSession(cdSession) {
                        sessions.append(session)
                    }
                }
            }
        }
        return sessions
    }
    
    func deleteChatSession(id: String) {
        context.performAndWait {
            let request: NSFetchRequest<CDChatSession> = CDChatSession.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id)
            
            if let cdSession = try? context.fetch(request).first {
                // Delete all associated messages (cascade delete)
                if let messages = cdSession.messages?.allObjects as? [CDChatMessage] {
                    for message in messages {
                        context.delete(message)
                    }
                }
                
                context.delete(cdSession)
                try? context.save()
                print("[ChatCacheManager] Deleted chat session and all associated messages for id: \(id)")
            }
        }
    }
    
    func deleteChatSessionByReceiptId(userId: String, receiptId: String) {
        context.performAndWait {
            let request: NSFetchRequest<CDChatSession> = CDChatSession.fetchRequest()
            request.predicate = NSPredicate(format: "userId == %@ AND receiptId == %@", userId, receiptId)
            
            if let cdSession = try? context.fetch(request).first {
                // Delete all associated messages (cascade delete)
                if let messages = cdSession.messages?.allObjects as? [CDChatMessage] {
                    for message in messages {
                        context.delete(message)
                    }
                }
                
                context.delete(cdSession)
                try? context.save()
                print("[ChatCacheManager] Deleted chat session and all associated messages for userId: \(userId), receiptId: \(receiptId)")
            }
        }
    }
    
    private func convertToChatSession(_ cdSession: CDChatSession) -> ChatSession? {
        guard let id = cdSession.id,
              let userId = cdSession.userId,
              let receiptId = cdSession.receiptId,
              let lastMessageId = cdSession.lastMessageId,
              let timestamp = cdSession.timestamp else {
            return nil
        }
        
        // Create a placeholder message for the session
        let placeholderMessage = ChatMessage(
            id: lastMessageId,
            authorId: "", // Will be filled by actual message data
            receiptId: receiptId,
            chatSessionId: ChatMessage.generateSessionId(userId: userId, receiptId: receiptId),
            content: nil,
            timestamp: timestamp.timeIntervalSince1970,
            attachments: nil
        )
        
        return ChatSession(
            id: id,
            userId: userId,
            receiptId: receiptId,
            lastMessage: placeholderMessage,
            timestamp: timestamp.timeIntervalSince1970,
            hasNews: cdSession.hasNews
        )
    }
}

// MARK: - Chat Message Caching
extension ChatCacheManager {
    func saveChatMessage(_ message: ChatMessage) {
        context.performAndWait {
            let request: NSFetchRequest<CDChatMessage> = CDChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", message.id)
            let cdMessage = (try? context.fetch(request).first) ?? CDChatMessage(context: context)
            
            cdMessage.id = message.id
            cdMessage.authorId = message.authorId
            cdMessage.receiptId = message.receiptId
            cdMessage.chatSessionId = message.chatSessionId
            cdMessage.content = message.content
            cdMessage.timestamp = Date(timeIntervalSince1970: message.timestamp)
            cdMessage.timeCached = Date()
            
            // Handle attachments
            if let attachments = message.attachments, !attachments.isEmpty {
                if let attachmentData = try? JSONEncoder().encode(attachments) {
                    cdMessage.attachmentData = attachmentData
                }
            }
            
            try? context.save()
        }
    }
    
    func fetchMessages(for receiptId: String, userId: String) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        context.performAndWait {
            let request: NSFetchRequest<CDChatMessage> = CDChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "(authorId == %@ AND receiptId == %@) OR (authorId == %@ AND receiptId == %@)", 
                                          userId, receiptId, receiptId, userId)
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            
            if let cdMessages = try? context.fetch(request) {
                for cdMessage in cdMessages {
                    if let message = convertToChatMessage(cdMessage) {
                        messages.append(message)
                    }
                }
            }
        }
        return messages
    }
    
    func deleteMessagesForConversation(authorId: String, receiptId: String) {
        context.performAndWait {
            let request: NSFetchRequest<CDChatMessage> = CDChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "(authorId == %@ AND receiptId == %@) OR (authorId == %@ AND receiptId == %@)", 
                                          authorId, receiptId, receiptId, authorId)
            
            if let cdMessages = try? context.fetch(request) {
                for message in cdMessages {
                    context.delete(message)
                }
                try? context.save()
                print("[ChatCacheManager] Deleted \(cdMessages.count) messages for conversation between \(authorId) and \(receiptId)")
            }
        }
    }
    
    private func convertToChatMessage(_ cdMessage: CDChatMessage) -> ChatMessage? {
        guard let id = cdMessage.id,
              let authorId = cdMessage.authorId,
              let receiptId = cdMessage.receiptId,
              let chatSessionId = cdMessage.chatSessionId,
              let timestamp = cdMessage.timestamp else {
            return nil
        }
        
        // Handle attachments
        var attachments: [MimeiFileType]? = nil
        if let attachmentData = cdMessage.attachmentData {
            attachments = try? JSONDecoder().decode([MimeiFileType].self, from: attachmentData)
        }
        
        return ChatMessage(
            id: id,
            authorId: authorId,
            receiptId: receiptId,
            chatSessionId: chatSessionId,
            content: cdMessage.content,
            timestamp: timestamp.timeIntervalSince1970,
            attachments: attachments
        )
    }
    
    private func deleteExpiredMessages() {
        let request: NSFetchRequest<CDChatMessage> = CDChatMessage.fetchRequest()
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        request.predicate = NSPredicate(format: "timeCached < %@", thirtyDaysAgo as NSDate)
        
        if let expiredMessages = try? context.fetch(request) {
            for message in expiredMessages {
                context.delete(message)
            }
            try? context.save()
            print("[ChatCacheManager] Deleted \(expiredMessages.count) expired messages")
        }
    }
} 