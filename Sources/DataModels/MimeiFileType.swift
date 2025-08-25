import Foundation

class MimeiFileType: Identifiable, Codable, Hashable { // Conform to Hashable
    var id: String { mid }  // Computed property that returns mid
    var mid: MimeiId
    var type: MediaType    // Image
    let size: Int64?
    var fileName: String?
    let timestamp: Date
    let aspectRatio: Float?
    var url: String?
    
    enum CodingKeys: String, CodingKey {
        case mid
        case type
        case size
        case fileName
        case timestamp
        case aspectRatio
        case url
    }
    
    init(mid: MimeiId, mediaType: MediaType, size: Int64? = nil, fileName: String? = nil, timestamp: Date = Date(), aspectRatio: Float? = nil, url: String? = nil) {
        self.mid = mid
        self.type = mediaType
        self.size = size
        self.fileName = fileName
        self.timestamp = timestamp
        self.aspectRatio = aspectRatio
        self.url = url
    }
    
    // Convenience initializer that accepts String for backward compatibility during transition
    init(mid: String, type: String, size: Int64? = nil, fileName: String? = nil, timestamp: Date = Date(), aspectRatio: Float? = nil, url: String? = nil) {
        self.mid = mid
        self.type = MediaType.fromString(type)
        self.size = size
        self.fileName = fileName
        self.timestamp = timestamp
        self.aspectRatio = aspectRatio
        self.url = url
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
        url = try container.decodeIfPresent(String.self, forKey: .url)

        // Robust timestamp decoding
        if let doubleValue = try? container.decode(Double.self, forKey: .timestamp) {
            timestamp = Date(timeIntervalSince1970: doubleValue / 1000)
        } else if let stringValue = try? container.decode(String.self, forKey: .timestamp),
                  let doubleValue = Double(stringValue) {
            timestamp = Date(timeIntervalSince1970: doubleValue / 1000)
        } else {
            timestamp = Date()
        }
    }
    
    func getUrl(_ baseUrl: URL) -> URL? {
        // If we have a cached URL path, use it directly
        if let cachedUrlPath = url, !cachedUrlPath.isEmpty {
            print("[MimeiFileType] Using cached URL path for \(mid): \(cachedUrlPath)")
            return URL(string: cachedUrlPath)
        }
        
        // Otherwise, construct the standard path
        let path = mid.count > Constants.MIMEI_ID_LENGTH ? "ipfs/\(mid)" : "mm/\(mid)"
        let constructedUrl = baseUrl.appendingPathComponent(path)
        print("[MimeiFileType] Using constructed URL for \(mid): \(constructedUrl)")
        return constructedUrl
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
