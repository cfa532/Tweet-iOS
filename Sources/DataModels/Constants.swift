//
//  Constants.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/7/3.
//
import Foundation
import CoreGraphics

enum Constants {
    static let GUEST_ID = "000000000000000000000000000"
    static let MAX_TWEET_SIZE = 28000
    static let MIMEI_ID_LENGTH = 27
    static let USER_BATCH_SIZE = 20
    static let USER_VISIBLE_BATCH_SIZE = 6
    
    // Localhost Configuration
    static let LOCAL_HOST = "http://127.0.0.1"
    
    // Cache Configuration - RESTORED to original limits for better performance
    static let MAX_ASSET_CACHE_SIZE = 40
    static let MAX_PLAYER_CACHE_SIZE = 8 // number of players to cache (players released on background)
    static let MAX_CONCURRENT_PLAYER_CREATIONS = 2 // Conservative: 1 slot reserved for visible content, preloads only when idle
    static let CACHE_EXPIRATION_SECONDS: TimeInterval = 300 // 5 minutes - reasonable balance of memory vs performance
    
    // File Upload Limits
    static let MAX_FILE_SIZE = 512 * 1024 * 1024 // 512MB in bytes - applies to all file types
    
    // Video Processing Thresholds
    static let PROGRESSIVE_VIDEO_THRESHOLD_BYTES: Int64 = 32 * 1024 * 1024  // 32MB
    
    // Image Loading Timeout
    static let IMAGE_LOAD_TIMEOUT: TimeInterval = 15.0  // 15 seconds for all image loading requests
}

enum FeedPlaybackTuning {
    // Directional preloading
    static let directionalVideoPreloadCount = 1
    static let directionalImagePreloadRowCount = 2
    static let oppositeStopImagePreloadRowCount = 1
    static let maxDirectionalImagePreloadsInFlight = 4
    static let directionalVideoPreloadRefreshInterval: CFTimeInterval = 0.35

    // Scroll visibility
    static let videoVisibilityThrottleInterval: TimeInterval = 0.15
    static let tweetVisibleRatio: CGFloat = 0.50

    // Video playback visibility
    static let videoWarmVisibilityRatio: CGFloat = 0.50
    static let videoStartVisibilityRatio: CGFloat = 0.50
    static let videoContinueVisibilityRatio: CGFloat = 0.70

    // Overlay/layout settling
    static let overlayDismissSettleDelay: TimeInterval = 0.35
    static let barAppearanceCompensationTimeout: TimeInterval = 0.15
}

enum UserContentType: String {
    case FAVORITES = "favorite_list"     // get favorite tweet list of an user
    case BOOKMARKS = "bookmark_list"     // get bookmarks
    case COMMENTS = "comment_list"       // comments made by an user
    case FOLLOWER = "get_followers_sorted"      // follower list of an user
    case FOLLOWING = "get_followings_sorted"    // following list
    case BLACK_LIST = "get_black_list"          // blocked user list
}
