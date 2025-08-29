import Foundation

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: String
    let authorId: MimeiId
    let receiptId: MimeiId
    let chatSessionId: String
    let content: String?
    let timestamp: TimeInterval
    let attachments: [MimeiFileType]?
    let success: Bool?
    let errorMsg: String?
    
    /// Generate a consistent session ID for a pair of users
    /// This ensures the same session ID is used for all messages between the same users
    static func generateSessionId(userId: MimeiId, receiptId: MimeiId) -> String {
        // Create a deterministic hash based on sorted user IDs to ensure consistency
        let sortedIds = [userId, receiptId].sorted()
        let combinedString = "\(sortedIds[0])_\(sortedIds[1])"
        return String(combinedString.hash)
    }
    
    init(id: String = UUID().uuidString, authorId: MimeiId, receiptId: MimeiId, chatSessionId: String, content: String? = nil, timestamp: TimeInterval = Date().timeIntervalSince1970, attachments: [MimeiFileType]? = nil, success: Bool? = nil, errorMsg: String? = nil) {
        self.id = id
        self.authorId = authorId
        self.receiptId = receiptId
        self.chatSessionId = chatSessionId
        self.content = content
        self.timestamp = timestamp
        self.attachments = attachments
        self.success = success
        self.errorMsg = errorMsg
    }
    
    // Custom decoding to ignore id and chatSessionId from backend
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Create id locally, ignore any values from backend
        self.id = UUID().uuidString
        
        // Decode other fields from backend first
        self.authorId = try container.decode(MimeiId.self, forKey: .authorId)
        self.receiptId = try container.decode(MimeiId.self, forKey: .receiptId)
        
        // Generate consistent session ID based on user IDs
        self.chatSessionId = ChatMessage.generateSessionId(userId: self.authorId, receiptId: self.receiptId)
        
        // Decode other fields from backend
        self.content = try container.decodeIfPresent(String.self, forKey: .content)
        self.timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        
        // Handle attachments - decode as array
        self.attachments = try? container.decode([MimeiFileType].self, forKey: .attachments)
        
        // Decode new fields
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success)
        self.errorMsg = try container.decodeIfPresent(String.self, forKey: .errorMsg)
        
        // Validate that either content or attachments (or both) are present
        guard self.content != nil || (self.attachments != nil && !self.attachments!.isEmpty) else {
            throw DecodingError.dataCorruptedError(forKey: .content, in: container, debugDescription: "ChatMessage must have either content or attachments (or both)")
        }
    }
    
    // Custom encoding to handle optional content and attachments
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(authorId, forKey: .authorId)
        try container.encode(receiptId, forKey: .receiptId)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(attachments, forKey: .attachments)
        try container.encodeIfPresent(success, forKey: .success)
        try container.encodeIfPresent(errorMsg, forKey: .errorMsg)
    }
    
    private enum CodingKeys: String, CodingKey {
        case authorId, receiptId, content, timestamp, attachments, success, errorMsg
    }
    
    /// Convert ChatMessage to JSON string
    func toJSONString() -> String {
        do {
            let jsonData = try JSONEncoder().encode(self)
            return String(data: jsonData, encoding: .utf8) ?? "{}"
        } catch {
            print("[ChatMessage] Error encoding to JSON: \(error)")
            return "{}"
        }
    }
}

struct ChatSession: Identifiable, Codable {
    let id: String
    let userId: MimeiId
    let receiptId: MimeiId
    let lastMessage: ChatMessage
    let timestamp: TimeInterval
    let hasNews: Bool
    
    init(id: String = UUID().uuidString, userId: MimeiId, receiptId: MimeiId, lastMessage: ChatMessage, timestamp: TimeInterval, hasNews: Bool = false) {
        self.id = id
        self.userId = userId
        self.receiptId = receiptId
        self.lastMessage = lastMessage
        self.timestamp = timestamp
        self.hasNews = hasNews
    }
    
    /// Create a new chat session using the other party's ID as the session ID
    static func createSession(
        userId: MimeiId,
        receiptId: MimeiId,
        lastMessage: ChatMessage,
        hasNews: Bool = false
    ) -> ChatSession {
        return ChatSession(
            id: receiptId,  // receiptId is already the other party's ID
            userId: userId,
            receiptId: receiptId,
            lastMessage: lastMessage,
            timestamp: lastMessage.timestamp,
            hasNews: hasNews
        )
    }
} 