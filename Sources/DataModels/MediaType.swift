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
        // First try exact match
        if let mediaType = MediaType(rawValue: string) {
            return mediaType
        }
        
        // Try case-insensitive match for common variations
        let lowercased = string.lowercased()
        switch lowercased {
        case "hls_video":
            return .hls_video
        case "image":
            return .image
        case "video":
            return .video
        case "audio":
            return .audio
        case "pdf":
            return .pdf
        case "word":
            return .word
        case "excel":
            return .excel
        case "ppt":
            return .ppt
        case "zip":
            return .zip
        case "txt":
            return .txt
        case "html":
            return .html
        default:
            return .unknown
        }
    }
    
    // Convert MediaType to string
    var stringValue: String {
        return self.rawValue
    }
}
