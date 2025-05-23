import SwiftUI

enum UserActions: Int {
    case FAVORITE = 0
    case BOOKMARK = 1
    case RETWEET = 2
}

@available(iOS 16.0, *)
struct TweetActionButtonsView: View {
    @Binding var tweet: Tweet
    var retweet: (Tweet) async -> Void
    @State private var showCommentCompose = false

    private let hproseInstance = HproseInstance.shared
    
    var body: some View {
        HStack(spacing: 0) {
            // Comment
            TweetActionButton(
                icon: "message",
                isSelected: false,
                action: {
                    showCommentCompose = true
                }
            )
            if let count = tweet.commentCount, count > 0 {
                Text("\(count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 24, alignment: .leading)
                    .padding(.leading, 2)
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
                    if let hasRetweeted = tweet.favorites?[UserActions.RETWEET.rawValue] {
                        tweet.favorites?[UserActions.RETWEET.rawValue] = !hasRetweeted
                    } else {
                        tweet.favorites?[UserActions.RETWEET.rawValue] = true
                    }
                    if let count = tweet.retweetCount {
                        tweet.retweetCount = count + 1
                    } else {
                        tweet.retweetCount = 1
                    }
                }
            )
            if  let count = tweet.retweetCount, count > 0 {
                Text("\(count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 24, alignment: .leading)
                    .padding(.leading, 2)
            }
            Spacer()
            
            // Heart
            TweetActionButton(
                icon: "heart",
                isSelected: tweet.favorites?[UserActions.FAVORITE.rawValue] == true,
                action: {
                    if let isFavorite = tweet.favorites?[UserActions.FAVORITE.rawValue] {
                        tweet.favorites?[UserActions.FAVORITE.rawValue] = !isFavorite
                    } else {
                        tweet.favorites?[UserActions.FAVORITE.rawValue] = true
                    }
                    if let isFavorite = tweet.favorites?[UserActions.FAVORITE.rawValue], isFavorite {
                        if let count = tweet.favoriteCount {
                            tweet.favoriteCount = count + 1
                        } else {
                            tweet.favoriteCount = 0
                        }
                    } else {
                        if let count = tweet.favoriteCount {
                            tweet.favoriteCount = max(0, count - 1)
                        }
                    }
                    Task {
                        if let updatedTweet = try await hproseInstance.toggleFavorite(tweet) {
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
                    .padding(.leading, 2)
            }
            Spacer()
            
            // Bookmark
            TweetActionButton(
                icon: "bookmark",
                isSelected: tweet.favorites?[UserActions.BOOKMARK.rawValue] == true,
                action: {
                    if let isFavorite = tweet.favorites?[UserActions.BOOKMARK.rawValue] {
                        tweet.favorites?[UserActions.BOOKMARK.rawValue] = !isFavorite
                    } else {
                        tweet.favorites?[UserActions.BOOKMARK.rawValue] = true
                    }
                    if let isFavorite = tweet.favorites?[UserActions.BOOKMARK.rawValue], isFavorite {
                        if let count = tweet.bookmarkCount {
                            tweet.bookmarkCount = count + 1
                        } else {
                            tweet.bookmarkCount = 0
                        }
                    } else {
                        if let count = tweet.bookmarkCount {
                            tweet.bookmarkCount = max(0, count - 1)
                        }
                    }
                    Task {
                        if let updatedTweet = try await hproseInstance.toggleBookmark(tweet) {
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
                    .padding(.leading, 2)
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
        .sheet(isPresented: $showCommentCompose) {
            CommentComposeView(tweet: $tweet)
        }
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
