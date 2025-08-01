import Foundation

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: String
    let authorId: String
    let receiptId: String
    let chatSessionId: String
    let content: String?
    let timestamp: TimeInterval
    let attachments: [MimeiFileType]?
    
    /// Generate a unique session ID based on user IDs
    /// This ensures consistent sessionId for the same chat participants
    /// Note: sessionId is only stored locally, not in backend
    static func generateSessionId(userId: String, receiptId: String) -> String {
        // Create a deterministic hash based on sorted user IDs to ensure consistency
        // This allows us to recreate the same sessionId when loading from backend
        let sortedIds = [userId, receiptId].sorted()
        let combinedString = "\(sortedIds[0])_\(sortedIds[1])"
        return String(combinedString.hash)
    }
    
    init(id: String = UUID().uuidString, authorId: String, receiptId: String, chatSessionId: String, content: String? = nil, timestamp: TimeInterval = Date().timeIntervalSince1970, attachments: [MimeiFileType]? = nil) {
        // Validate that either content or attachments (or both) are present
        guard content != nil || (attachments != nil && !attachments!.isEmpty) else {
            fatalError("ChatMessage must have either content or attachments (or both)")
        }
        self.id = id
        self.authorId = authorId
        self.receiptId = receiptId
        self.chatSessionId = chatSessionId
        self.content = content
        self.timestamp = timestamp
        self.attachments = attachments
    }
    
    // Custom decoding to ignore id and chatSessionId from backend
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Create id locally, ignore any values from backend
        self.id = UUID().uuidString
        
        // Decode other fields from backend first
        self.authorId = try container.decode(String.self, forKey: .authorId)
        self.receiptId = try container.decode(String.self, forKey: .receiptId)
        
        // Generate chatSessionId using the same algorithm as Kotlin
        // We need the authorId and receiptId first to generate the sessionId
        self.chatSessionId = ChatMessage.generateSessionId(userId: self.authorId, receiptId: self.receiptId)
        
        // Decode other fields from backend
        self.content = try container.decodeIfPresent(String.self, forKey: .content)
        self.timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        
        // Handle attachments - decode as array
        self.attachments = try? container.decode([MimeiFileType].self, forKey: .attachments)
        
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
    }
    
    private enum CodingKeys: String, CodingKey {
        case authorId, receiptId, content, timestamp, attachments
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
    let userId: String
    let receiptId: String
    let lastMessage: ChatMessage
    let timestamp: TimeInterval
    let hasNews: Bool
    
    /// Generate a unique session ID based on user IDs
    /// This ensures consistent sessionId for the same chat participants
    /// Note: sessionId is only stored locally, not in backend
    static func generateSessionId(userId: String, receiptId: String) -> String {
        // Create a deterministic hash based on sorted user IDs to ensure consistency
        // This allows us to recreate the same sessionId when loading from backend
        let sortedIds = [userId, receiptId].sorted()
        let combinedString = "\(sortedIds[0])_\(sortedIds[1])"
        return String(combinedString.hash)
    }
    
    init(id: String = UUID().uuidString, userId: String, receiptId: String, lastMessage: ChatMessage, timestamp: TimeInterval, hasNews: Bool = false) {
        self.id = id
        self.userId = userId
        self.receiptId = receiptId
        self.lastMessage = lastMessage
        self.timestamp = timestamp
        self.hasNews = hasNews
    }
    
    /// Create a new chat session with auto-generated session ID
    static func createSession(
        userId: String,
        receiptId: String,
        lastMessage: ChatMessage,
        hasNews: Bool = false
    ) -> ChatSession {
        let sessionId = generateSessionId(userId: userId, receiptId: receiptId)
        return ChatSession(
            id: sessionId,
            userId: userId,
            receiptId: receiptId,
            lastMessage: lastMessage,
            timestamp: lastMessage.timestamp,
            hasNews: hasNews
        )
    }
} 