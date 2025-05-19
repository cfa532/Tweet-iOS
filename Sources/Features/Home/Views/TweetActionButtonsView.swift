import SwiftUI

enum UserActions: Int {
    case FAVORITE = 0
    case BOOKMARK = 1
    case RETWEET = 2
}

struct TweetActionButtonsView: View {
    let tweet: Tweet
    private let hproseInstance = HproseInstance.shared
    
    var body: some View {
        HStack(spacing: 16) {
            TweetActionButton(
                icon: "message",
                count: tweet.commentCount,
                isSelected: false,
                action: {
                    Task {
                        try await hproseInstance.bookmarkTweet(tweet.mid)
                    }
                }
            )
            
            TweetActionButton(
                icon: "arrow.2.squarepath",
                count: tweet.retweetCount,
                isSelected: tweet.favorites?[UserActions.RETWEET.rawValue] == true,
                action: {
                    Task {
                        try await hproseInstance.retweet(tweet.mid)
                    }
                }
            )
            
            TweetActionButton(
                icon: "heart",
                count: tweet.favoriteCount,
                isSelected: tweet.favorites?[UserActions.FAVORITE.rawValue] == true,
                action: {
                    Task {
                        try await hproseInstance.likeTweet(tweet.mid)
                    }
                }
            )
            
            TweetActionButton(
                icon: "bookmark",
                count: tweet.bookmarkCount,
                isSelected: tweet.favorites?[UserActions.BOOKMARK.rawValue] == true,
                action: {
                    Task {
                        try await hproseInstance.bookmarkTweet(tweet.mid)
                    }
                }
            )
        }
    }
}

struct TweetActionButton: View {
    let icon: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundColor(isSelected ? .blue : .secondary)
                if count > 0 {
                    Text("\(count)")
                        .font(.subheadline)
                        .foregroundColor(isSelected ? .blue : .secondary)
                }
            }
        }
    }
}
