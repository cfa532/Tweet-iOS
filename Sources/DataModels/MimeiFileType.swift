import Foundation
import Combine

class MimeiFileType: Identifiable, Codable, Hashable, ObservableObject, @unchecked Sendable { // Conform to Hashable and ObservableObject
    var id: String { mid }  // Computed property that returns mid
    var mid: MimeiId
    var type: MediaType    // Image
    let size: Int64?
    var fileName: String?
    let timestamp: Date
    let aspectRatio: Float?
    
    // Make url a computed property that updates when author's baseUrl changes
    @Published private var _cachedUrl: String?
    private var baseUrlCancellable: AnyCancellable?
    private weak var author: User? {
        didSet {
            // Cancel previous subscription if any
            baseUrlCancellable?.cancel()
            
            // Subscribe to author's baseUrl changes
            if let author = author {
                baseUrlCancellable = author.$baseUrl
                    .sink { [weak self] newBaseUrl in
                        self?.updateUrl(with: newBaseUrl)
                    }
                // Initial URL update
                updateUrl(with: author.baseUrl)
            }
        }
    }
    
    var url: String? {
        get { _cachedUrl }
        set { _cachedUrl = newValue }
    }
    
    /// Update the URL based on the author's baseUrl
    private func updateUrl(with baseUrl: URL?) {
        guard let baseUrl = baseUrl else {
            _cachedUrl = nil
            return
        }
        
        // Only videos (HLS) need the full URL with baseUrl
        // Images use the getUrl() method when rendering
        if type == .hls_video {
            let path = mid.count > Constants.MIMEI_ID_LENGTH ? "ipfs/\(mid)" : "mm/\(mid)"
            _cachedUrl = baseUrl.appendingPathComponent(path).absoluteString
        } else {
            _cachedUrl = nil
        }
    }
    
    /// Set the author for this attachment to enable reactive URL updates
    func setAuthor(_ author: User) {
        self.author = author
    }
    
    enum CodingKeys: String, CodingKey {
        case mid
        case type
        case size
        case fileName
        case timestamp
        case aspectRatio
        case url
    }
    
    init(mid: MimeiId, mediaType: MediaType, size: Int64? = nil, fileName: String? = nil, timestamp: Date = Date(timeIntervalSince1970: Date().timeIntervalSince1970), aspectRatio: Float? = nil, url: String? = nil, author: User? = nil) {
        self.mid = mid
        self.type = mediaType
        self.size = size
        self.fileName = fileName
        self.timestamp = timestamp
        self.aspectRatio = aspectRatio
        self._cachedUrl = url
        
        // Set author and start observing if provided
        if let author = author {
            self.author = author
            // Initial URL update
            updateUrl(with: author.baseUrl)
            // Subscribe to baseUrl changes
            baseUrlCancellable = author.$baseUrl
                .sink { [weak self] newBaseUrl in
                    self?.updateUrl(with: newBaseUrl)
                }
        }
    }
    
    // Convenience initializer that accepts String for backward compatibility during transition
    init(mid: String, type: String, size: Int64? = nil, fileName: String? = nil, timestamp: Date = Date(timeIntervalSince1970: Date().timeIntervalSince1970), aspectRatio: Float? = nil, url: String? = nil, author: User? = nil) {
        self.mid = mid
        self.type = MediaType.fromString(type)
        self.size = size
        self.fileName = fileName
        self.timestamp = timestamp
        self.aspectRatio = aspectRatio
        self._cachedUrl = url
        
        // Set author and start observing if provided
        if let author = author {
            self.author = author
            // Initial URL update
            updateUrl(with: author.baseUrl)
            // Subscribe to baseUrl changes
            baseUrlCancellable = author.$baseUrl
                .sink { [weak self] newBaseUrl in
                    self?.updateUrl(with: newBaseUrl)
                }
        }
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mid = try container.decode(String.self, forKey: .mid)
        
        // Handle both String and MediaType decoding for backward compatibility
        if let mediaType = try? container.decode(MediaType.self, forKey: .type) {
            type = mediaType
        } else if let typeString = try? container.decode(String.self, forKey: .type) {
            type = MediaType.fromString(typeString)
        } else {
            type = .unknown
        }
        
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        aspectRatio = try container.decodeIfPresent(Float.self, forKey: .aspectRatio)
        _cachedUrl = try container.decodeIfPresent(String.self, forKey: .url)

        // Robust timestamp decoding
        if let doubleValue = try? container.decode(Double.self, forKey: .timestamp) {
            timestamp = Date(timeIntervalSince1970: doubleValue / 1000)
        } else if let stringValue = try? container.decode(String.self, forKey: .timestamp),
                  let doubleValue = Double(stringValue) {
            timestamp = Date(timeIntervalSince1970: doubleValue / 1000)
        } else {
            timestamp = Date(timeIntervalSince1970: Date().timeIntervalSince1970)
        }
        
        // Note: author is not decoded - it must be set after decoding via setAuthor()
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mid, forKey: .mid)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(fileName, forKey: .fileName)
        try container.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
        try container.encodeIfPresent(_cachedUrl, forKey: .url)
        
        // Encode timestamp as Unix timestamp in milliseconds
        let timestampMillis = Int64(timestamp.timeIntervalSince1970 * 1000)
        try container.encode(timestampMillis, forKey: .timestamp)
    }
    
    func getUrl(_ baseUrl: URL) -> URL? {
        let path = mid.count > Constants.MIMEI_ID_LENGTH ? "ipfs/\(mid)" : "mm/\(mid)"
        return baseUrl.appendingPathComponent(path)
    }
    
    // Implement the hash(into:) method for Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(mid) // Use the unique identifier (mid) for hashing
    }
    
    // Implement the == operator for Hashable conformance
    static func == (lhs: MimeiFileType, rhs: MimeiFileType) -> Bool {
        return lhs.mid == rhs.mid // Compare based on the unique identifier (mid)
    }
}
