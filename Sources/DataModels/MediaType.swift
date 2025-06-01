//
//  MediaType.swift
//  Tweet
//
//  Created by 超方 on 2025/5/17.
//

enum MediaType: String, Codable {
    case image = "Image"
    case video = "Video"
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
