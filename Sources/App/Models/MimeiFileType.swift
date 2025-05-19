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
    
    func getUrl(_ baseUrl: String) -> URL? {
        let path = mid.count > 27 ? "\(baseUrl)/ipfs/\(mid)" : "\(baseUrl)/mm/\(mid)"
        return URL(string: path)
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
