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
        HStack(spacing: 0) {
            // Comment
            TweetActionButton(
                icon: "message",
                isSelected: false,
                action: {
                    // Comment action
                }
            )
            if tweet.commentCount > 0 {
                Text("\(tweet.commentCount)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 24, alignment: .leading)
            }
            Spacer()
            // Retweet
            TweetActionButton(
                icon: "arrow.2.squarepath",
                isSelected: tweet.favorites?[UserActions.RETWEET.rawValue] == true,
                action: {
                    Task {
                        try await hproseInstance.retweet(tweet.mid)
                    }
                }
            )
            if tweet.retweetCount > 0 {
                Text("\(tweet.retweetCount)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 24, alignment: .leading)
            }
            Spacer()
            // Heart
            TweetActionButton(
                icon: "heart",
                isSelected: tweet.favorites?[UserActions.FAVORITE.rawValue] == true,
                action: {
                    Task {
                        try await hproseInstance.likeTweet(tweet.mid)
                    }
                }
            )
            if tweet.favoriteCount > 0 {
                Text("\(tweet.favoriteCount)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 24, alignment: .leading)
            }
            Spacer()
            // Bookmark
            TweetActionButton(
                icon: "bookmark",
                isSelected: tweet.favorites?[UserActions.BOOKMARK.rawValue] == true,
                action: {
                    Task {
                        try await hproseInstance.bookmarkTweet(tweet.mid)
                    }
                }
            )
            if tweet.bookmarkCount > 0 {
                Text("\(tweet.bookmarkCount)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 24, alignment: .leading)
            }
            Spacer() // Extra space before share button
            TweetActionButton(
                icon: "square.and.arrow.up",
                isSelected: false,
                action: {
                    // Share action
                }
            )
            .padding(.leading, 40)
        }
        .padding(.horizontal, 4)
    }
}

struct TweetActionButton: View {
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundColor(isSelected ? .blue : .secondary)
        }
    }
}
