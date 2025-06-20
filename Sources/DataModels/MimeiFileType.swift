import Foundation

struct MimeiFileType: Identifiable, Codable, Hashable { // Conform to Hashable
    var id: String { mid }  // Computed property that returns mid
    var mid: String
    var type: String    // Image
    let size: Int64?
    let fileName: String?
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
    
    init(mid: String, type: String, size: Int64? = nil, fileName: String? = nil, timestamp: Date = Date(), aspectRatio: Float? = nil, url: String? = nil) {
        self.mid = mid
        self.type = type
        self.size = size
        self.fileName = fileName
        self.timestamp = timestamp
        self.aspectRatio = aspectRatio
        self.url = url
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mid = try container.decode(String.self, forKey: .mid)
        type = try container.decode(String.self, forKey: .type)
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
