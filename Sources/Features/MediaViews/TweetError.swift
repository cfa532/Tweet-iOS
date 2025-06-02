//
//  TweetError.swift
//  Tweet
//
//  Created by 超方 on 2025/6/2.
//


@available(iOS 16.0, *)
enum TweetError: LocalizedError {
    case emptyTweet
    case uploadFailed
    case deleteFailed
    
    var errorDescription: String? {
        switch self {
        case .emptyTweet:
            return "Tweet cannot be empty."
        case .uploadFailed:
            return "Failed to upload. Please try again."
        case .deleteFailed:
            return "Faild to delete. Please try again"
        }
    }
}
