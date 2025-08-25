//
//  MediaType.swift
//  Tweet
//
//  Created by 超方 on 2025/5/17.
//

enum MediaType: String, Codable {
    case image = "Image"
    case video = "Video"
    case hls_video = "hls_video"
    case audio = "Audio"
    case pdf = "PDF"
    case word = "Word"
    case excel = "Excel"
    case ppt = "PPT"
    case zip = "Zip"
    case txt = "Txt"
    case html = "Html"
    case unknown = "Unknown"
}

// Extension to MediaType for string conversion
extension MediaType {
    
    // Convert string to MediaType with fallback to unknown
    static func fromString(_ string: String) -> MediaType {
        return MediaType(rawValue: string) ?? .unknown
    }
    
    // Convert MediaType to string
    var stringValue: String {
        return self.rawValue
    }
}
