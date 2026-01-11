//
//  Constants.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/7/3.
//
import Foundation

enum Constants {
    static let GUEST_ID = "000000000000000000000000000"
    static let MAX_TWEET_SIZE = 28000
    static let MIMEI_ID_LENGTH = 27
    
    // Localhost Configuration
    static let LOCAL_HOST = "http://127.0.0.1"
    
    // Cache Configuration  
    static let MAX_ASSET_CACHE_SIZE = 40 // Maximum number of cached assets (lightweight - just metadata)
    static let MAX_PLAYER_CACHE_SIZE = 30 // Research-backed: Safe on modern devices (iPhone SE ~1.5GB limit, iPhone 14 Pro ~2.5GB limit)
    static let MAX_CONCURRENT_PLAYER_CREATIONS = 2 // Reduced to 2 to prevent thread exhaustion and logging deadlocks
    static let CACHE_EXPIRATION_SECONDS: TimeInterval = 600 // 10 minutes (reduced from 30 minutes)
    
    // File Upload Limits
    static let MAX_FILE_SIZE = 512 * 1024 * 1024 // 512MB in bytes - applies to all file types
    
    // Video Processing Thresholds
    static let PROGRESSIVE_VIDEO_THRESHOLD_BYTES: Int64 = 32 * 1024 * 1024  // 32MB
    static let HLS_ROUTE_2_THRESHOLD_BYTES: Int64 = 128 * 1024 * 1024  // 128MB
}

enum UserContentType: String {
    case FAVORITES = "favorite_list"     // get favorite tweet list of an user
    case BOOKMARKS = "bookmark_list"     // get bookmarks
    case COMMENTS = "comment_list"       // comments made by an user
    case FOLLOWER = "get_followers_sorted"      // follower list of an user
    case FOLLOWING = "get_followings_sorted"    // following list
    case BLACK_LIST = "get_black_list"          // blocked user list
}
