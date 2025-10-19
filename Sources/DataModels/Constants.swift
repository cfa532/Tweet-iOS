//
//  Constants.swift
//  Tweet
//
//  Created by 超方 on 2025/7/3.
//
import Foundation

enum Constants {
    static let GUEST_ID = "000000000000000000000000000"
    static let MAX_TWEET_SIZE = 28000
    static let MIMEI_ID_LENGTH = 27
    
    // Cache Configuration
    static let MAX_ASSET_CACHE_SIZE = 30 // Maximum number of cached assets
    static let MAX_PLAYER_CACHE_SIZE = 25 // Maximum number of cached players
    static let CACHE_EXPIRATION_SECONDS: TimeInterval = 1800 // 30 minutes
    static let MAX_VIDEO_FILE_CACHE_SIZE: Int64 = 50 * 1024 * 1024 // 50MB per video file
    
    // File Upload Limits
    static let MAX_FILE_SIZE = 240 * 1024 * 1024 // 240MB in bytes - applies to all file types
    static let MAX_VIDEO_FILE_SIZE = MAX_FILE_SIZE // Keep for backward compatibility
}

enum UserContentType: String {
    case FAVORITES = "favorite_list"     // get favorite tweet list of an user
    case BOOKMARKS = "bookmark_list"     // get bookmarks
    case COMMENTS = "comment_list"       // comments made by an user
    case FOLLOWER = "get_followers_sorted"      // follower list of an user
    case FOLLOWING = "get_followings_sorted"    // following list
    case BLACK_LIST = "get_black_list"          // blocked user list
}
