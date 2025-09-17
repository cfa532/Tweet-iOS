//
//  Constants.swift
//  Tweet
//
//  Created by 超方 on 2025/7/3.
//


enum Constants {
    static let GUEST_ID = "000000000000000000000000000"
    static let MAX_TWEET_SIZE = 28000
    static let MIMEI_ID_LENGTH = 27
    static let DEFAULT_CLOUD_PORT = 8010
    static let VIDEO_CACHE_POOL_SIZE = 50
    static let MAX_FILE_SIZE = 120 * 1024 * 1024 // 120MB in bytes - applies to all file types
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
