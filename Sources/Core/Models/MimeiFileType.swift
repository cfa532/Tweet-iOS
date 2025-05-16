import Foundation

struct MimeiFileType: Identifiable, Codable {
    let id: String // mid
    var mid: String
    var type: MediaType
    let size: Int64?
    let fileName: String?
    let timestamp: Date
    let aspectRatio: Float?
    var url: String?
    
    enum CodingKeys: String, CodingKey {
        case id = "000000000000000000000000000"
        case mid
        case type
        case size
        case fileName
        case timestamp
        case aspectRatio
        case url
    }
    
    init(id: String, mid: String, type: MediaType, size: Int64? = nil, fileName: String? = nil, timestamp: Date = Date(), aspectRatio: Float? = nil, url: String? = nil) {
        self.id = id
        self.mid = mid
        self.type = type
        self.size = size
        self.fileName = fileName
        self.timestamp = timestamp
        self.aspectRatio = aspectRatio
        self.url = url
    }
} 