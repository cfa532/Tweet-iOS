import CoreData
import Foundation
import UIKit

class ChatCacheManager {
    static let shared = ChatCacheManager()
    private let coreDataManager = CoreDataManager.shared

    private init() {
        // No periodic cleanup needed - messages are only removed manually by user
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
            
            // Encode the entire lastMessage as JSON and store it
            if let messageData = try? JSONEncoder().encode(session.lastMessage) {
                cdSession.lastMessageData = messageData
            }
            
            print("[ChatCacheManager] Saving chat session: id=\(session.id), userId=\(session.userId), receiptId=\(session.receiptId), lastMessageId=\(session.lastMessage.id)")
            
            do {
                try context.save()
                print("[ChatCacheManager] Successfully saved chat session to Core Data")
            } catch {
                print("[ChatCacheManager] Error saving chat session: \(error)")
            }
        }
    }
    
    func fetchChatSessions(for userId: String) -> [ChatSession] {
        var sessions: [ChatSession] = []
        context.performAndWait {
            let request: NSFetchRequest<CDChatSession> = CDChatSession.fetchRequest()
            request.predicate = NSPredicate(format: "userId == %@", userId)
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            
            print("[ChatCacheManager] Fetching chat sessions for userId: \(userId)")
            
            if let cdSessions = try? context.fetch(request) {
                print("[ChatCacheManager] Found \(cdSessions.count) CDChatSession objects")
                for cdSession in cdSessions {
                    print("[ChatCacheManager] CDSession: id=\(cdSession.id ?? "nil"), userId=\(cdSession.userId ?? "nil"), receiptId=\(cdSession.receiptId ?? "nil"), lastMessageId=\(cdSession.lastMessageId ?? "nil")")
                    if let session = convertToChatSession(cdSession) {
                        sessions.append(session)
                        print("[ChatCacheManager] Successfully converted session for \(session.receiptId)")
                    } else {
                        print("[ChatCacheManager] Failed to convert session")
                    }
                }
            } else {
                print("[ChatCacheManager] No CDChatSession objects found")
            }
        }
        print("[ChatCacheManager] Returning \(sessions.count) chat sessions")
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
              let timestamp = cdSession.timestamp else {
            print("[ChatCacheManager] Failed to convert session - missing required fields: id=\(cdSession.id ?? "nil"), userId=\(cdSession.userId ?? "nil"), receiptId=\(cdSession.receiptId ?? "nil"), timestamp=\(cdSession.timestamp?.description ?? "nil")")
            return nil
        }
        
        // Try to decode the lastMessage from lastMessageData first
        if let messageData = cdSession.lastMessageData,
           let lastMessage = try? JSONDecoder().decode(ChatMessage.self, from: messageData) {
            print("[ChatCacheManager] Successfully decoded lastMessage from lastMessageData for session: \(id)")
            return ChatSession(
                id: id,
                userId: userId,
                receiptId: receiptId,
                lastMessage: lastMessage,
                timestamp: timestamp.timeIntervalSince1970,
                hasNews: cdSession.hasNews
            )
        }
        
        // Fallback: try to fetch from lastMessageId (for backward compatibility)
        if let lastMessageId = cdSession.lastMessageId {
            print("[ChatCacheManager] Converting session with lastMessageId: \(lastMessageId)")
            let lastMessage = fetchLastMessage(for: lastMessageId)
            return ChatSession(
                id: id,
                userId: userId,
                receiptId: receiptId,
                lastMessage: lastMessage,
                timestamp: timestamp.timeIntervalSince1970,
                hasNews: cdSession.hasNews
            )
        } else {
            print("[ChatCacheManager] Failed to convert session - missing lastMessageId for session: \(id)")
            return nil
        }
    }
    
    private func fetchLastMessage(for messageId: String) -> ChatMessage {
        var lastMessage: ChatMessage?
        
        context.performAndWait {
            let request: NSFetchRequest<CDChatMessage> = CDChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", messageId)
            
            if let cdMessage = try? context.fetch(request).first {
                lastMessage = convertToChatMessage(cdMessage)
            }
        }
        
        // If we can't find the actual message, create a fallback
        if let message = lastMessage {
            return message
        } else {
            // Fallback message if the actual message is not found
            // Use the session's receiptId as the authorId for the fallback
            return ChatMessage(
                id: messageId,
                authorId: "unknown", // Use a valid placeholder
                receiptId: "unknown", // Use a valid placeholder
                chatSessionId: "unknown", // Use a valid placeholder
                content: "Message",
                timestamp: Date().timeIntervalSince1970,
                attachments: nil
            )
        }
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
    
    /// Fetch all message IDs from Core Data
    func fetchAllMessageIds() -> [String] {
        var messageIds: [String] = []
        
        context.performAndWait {
            let request: NSFetchRequest<CDChatMessage> = CDChatMessage.fetchRequest()
            request.propertiesToFetch = ["id"]
            request.resultType = .dictionaryResultType
            
            do {
                let results = try context.fetch(request) as? [[String: Any]] ?? []
                messageIds = results.compactMap { $0["id"] as? String }
            } catch {
                print("[ChatCacheManager] Error fetching message IDs: \(error)")
            }
        }
        
        return messageIds
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