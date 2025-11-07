import Foundation

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: String
    let authorId: MimeiId
    let receiptId: MimeiId
    let chatSessionId: String
    let content: String?
    let timestamp: TimeInterval
    var attachments: [MimeiFileType]?
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

// MARK: - Display Helpers
extension ChatMessage {
    func previewText(for currentUserId: MimeiId) -> String? {
        let trimmedContent = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedContent.isEmpty && !isAttachmentPlaceholder(trimmedContent) {
            return trimmedContent
        }
        guard let attachments = attachments, !attachments.isEmpty else {
            return trimmedContent.isEmpty ? nil : trimmedContent
        }
        let description = Self.attachmentDescription(for: attachments)
        let directionText = authorId == currentUserId ? NSLocalizedString("sent", comment: "Attachment sent label") : NSLocalizedString("received", comment: "Attachment received label")
        return "\(description) \(directionText)"
    }
    
    private func isAttachmentPlaceholder(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower == "attachment" || lower.contains("attachment sent") || lower.contains("attachment received")
    }
    
    private static func attachmentDescription(for attachments: [MimeiFileType]) -> String {
        guard !attachments.isEmpty else {
            return NSLocalizedString("Attachment", comment: "Generic attachment label")
        }
        let groups = Dictionary(grouping: attachments) { normalizedType(effectiveType(for: $0)) }
        if groups.count == 1, let (type, items) = groups.first {
            return mediaTypeDisplayName(for: type, count: items.count)
        }
        if attachments.count == 1, let first = attachments.first {
            return mediaTypeDisplayName(for: normalizedType(effectiveType(for: first)), count: 1)
        }
        if groups.count == 2 {
            let parts = groups.keys.map { mediaTypeDisplayName(for: $0, count: groups[$0]?.count ?? 1) }
            return parts.sorted().joined(separator: " & ")
        }
        let total = attachments.count
        return String(format: NSLocalizedString("%d attachments", comment: "Multiple attachment label"), total)
    }
    
    private static func effectiveType(for attachment: MimeiFileType) -> MediaType {
        if attachment.type != .unknown {
            return attachment.type
        }
        if let inferred = inferType(from: attachment.fileName) {
            return inferred
        }
        if let urlString = attachment.url, let inferred = inferType(from: URL(string: urlString)?.lastPathComponent) {
            return inferred
        }
        return .unknown
    }
    
    private static func inferType(from fileName: String?) -> MediaType? {
        guard let name = fileName?.lowercased() else { return nil }
        if name.hasSuffix(".png") || name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") || name.hasSuffix(".gif") || name.hasSuffix(".webp") || name.hasSuffix(".heic") || name.hasSuffix(".heif") {
            return .image
        }
        if name.hasSuffix(".mp4") || name.hasSuffix(".mov") || name.hasSuffix(".m4v") || name.hasSuffix(".avi") || name.hasSuffix(".wmv") || name.hasSuffix(".flv") || name.hasSuffix(".webm") {
            return .video
        }
        if name.hasSuffix(".mp3") || name.hasSuffix(".wav") || name.hasSuffix(".m4a") || name.hasSuffix(".aac") || name.hasSuffix(".ogg") {
            return .audio
        }
        if name.hasSuffix(".pdf") {
            return .pdf
        }
        if name.hasSuffix(".doc") || name.hasSuffix(".docx") {
            return .word
        }
        if name.hasSuffix(".xls") || name.hasSuffix(".xlsx") {
            return .excel
        }
        if name.hasSuffix(".ppt") || name.hasSuffix(".pptx") {
            return .ppt
        }
        if name.hasSuffix(".zip") || name.hasSuffix(".rar") || name.hasSuffix(".7z") || name.hasSuffix(".tar") || name.hasSuffix(".gz") {
            return .zip
        }
        if name.hasSuffix(".txt") || name.hasSuffix(".md") {
            return .txt
        }
        if name.hasSuffix(".html") || name.hasSuffix(".htm") {
            return .html
        }
        return nil
    }
    
    private static func normalizedType(_ type: MediaType) -> MediaType {
        switch type {
        case .hls_video:
            return .video
        default:
            return type
        }
    }
    
    private static func mediaTypeDisplayName(for type: MediaType, count: Int) -> String {
        let isPlural = count > 1
        switch type {
        case .image:
            return isPlural ? NSLocalizedString("Images", comment: "Images plural") : NSLocalizedString("Image", comment: "Image singular")
        case .video, .hls_video:
            return isPlural ? NSLocalizedString("Videos", comment: "Videos plural") : NSLocalizedString("Video", comment: "Video singular")
        case .audio:
            return isPlural ? NSLocalizedString("Audio clips", comment: "Audio plural") : NSLocalizedString("Audio clip", comment: "Audio singular")
        case .pdf:
            return isPlural ? NSLocalizedString("PDFs", comment: "PDF plural") : NSLocalizedString("PDF", comment: "PDF singular")
        case .word:
            return isPlural ? NSLocalizedString("Word documents", comment: "Word plural") : NSLocalizedString("Word document", comment: "Word singular")
        case .excel:
            return isPlural ? NSLocalizedString("Excel sheets", comment: "Excel plural") : NSLocalizedString("Excel sheet", comment: "Excel singular")
        case .ppt:
            return isPlural ? NSLocalizedString("Presentations", comment: "Presentation plural") : NSLocalizedString("Presentation", comment: "Presentation singular")
        case .zip:
            return isPlural ? NSLocalizedString("Archives", comment: "Archive plural") : NSLocalizedString("Archive", comment: "Archive singular")
        case .txt, .html:
            return isPlural ? NSLocalizedString("Documents", comment: "Documents plural") : NSLocalizedString("Document", comment: "Document singular")
        case .unknown:
            return isPlural ? NSLocalizedString("Attachments", comment: "Attachments plural") : NSLocalizedString("Attachment", comment: "Attachment singular")
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