import Foundation

struct ChatMessage: Identifiable, Codable {
    let id: String
    let authorId: String
    let receiptId: String
    let content: String
    let timestamp: TimeInterval
    
    init(id: String = UUID().uuidString, authorId: String, receiptId: String, content: String, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.id = id
        self.authorId = authorId
        self.receiptId = receiptId
        self.content = content
        self.timestamp = timestamp
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
    
    init(id: String = UUID().uuidString, userId: String, receiptId: String, lastMessage: ChatMessage, timestamp: TimeInterval, hasNews: Bool = false) {
        self.id = id
        self.userId = userId
        self.receiptId = receiptId
        self.lastMessage = lastMessage
        self.timestamp = timestamp
        self.hasNews = hasNews
    }
} 