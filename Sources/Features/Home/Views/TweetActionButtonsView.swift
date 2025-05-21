import SwiftUI

enum UserActions: Int {
    case FAVORITE = 0
    case BOOKMARK = 1
    case RETWEET = 2
}

struct TweetActionButtonsView: View {
    @Binding var tweet: Tweet
    var retweet: (Tweet) async -> Void

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
            if let count = tweet.commentCount, count > 0 {
                Text("\(count)")
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
                        await retweet(tweet)
                    }
                }
            )
            if  let count = tweet.retweetCount, count > 0 {
                Text("\(count)")
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
                        if let updatedTweet = try await hproseInstance.toggleFavorite(tweet.mid) {
                            tweet = updatedTweet
                        } else {
                            print(("Toggle favorite failed.\(tweet)"))
                        }
                    }
                }
            )
            if let count = tweet.favoriteCount, count > 0 {
                Text("\(count)")
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
                        if let updatedTweet = try await hproseInstance.toggleBookmark(tweet.mid) {
                            tweet = updatedTweet
                        } else {
                            print(("Toggle bookmark failed.\(tweet)"))
                        }
                    }
                }
            )
            if let count = tweet.bookmarkCount, count > 0 {
                Text("\(count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 24, alignment: .leading)
            }
            Spacer()
            
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
