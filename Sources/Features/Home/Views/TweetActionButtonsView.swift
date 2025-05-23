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
    var onGuestAction: () -> Void
    @State private var showCommentCompose = false
    @State private var showShareSheet = false
    @ObservedObject private var hproseInstance = HproseInstance.shared
    
    var body: some View {
        HStack(spacing: 0) {
            // Comment button
            Button(action: {
                if hproseInstance.appUser.isGuest {
                    onGuestAction()
                } else {
                    showCommentCompose = true
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left")
                        .frame(width: 20)
                    if let count = tweet.commentCount, count > 0 {
                        Text("\(count)")
                            .frame(minWidth: 20, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity)
                .foregroundColor(.secondary)
            }
            
            // Retweet button
            Button(action: {
                if hproseInstance.appUser.isGuest {
                    onGuestAction()
                } else {
                    Task {
                        await retweet(tweet)
                    }
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.2.squarepath")
                        .frame(width: 20)
                    if let count = tweet.retweetCount, count > 0 {
                        Text("\(count)")
                            .frame(minWidth: 20, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity)
                .foregroundColor(.secondary)
            }
            
            // Like button
            Button(action: {
                if hproseInstance.appUser.isGuest {
                    onGuestAction()
                } else {
                    Task {
                        if let updatedTweet = try? await hproseInstance.toggleFavorite(tweet) {
                            tweet = updatedTweet
                        }
                    }
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: tweet.favorites?[UserActions.FAVORITE.rawValue] == true ? "heart.fill" : "heart")
                        .frame(width: 20)
                    if let count = tweet.favoriteCount, count > 0 {
                        Text("\(count)")
                            .frame(minWidth: 20, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity)
                .foregroundColor(.secondary)
            }
            
            // Bookmark button
            Button(action: {
                if hproseInstance.appUser.isGuest {
                    onGuestAction()
                } else {
                    Task {
                        if let updatedTweet = try? await hproseInstance.toggleBookmark(tweet) {
                            tweet = updatedTweet
                        }
                    }
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: tweet.favorites?[UserActions.BOOKMARK.rawValue] == true ? "bookmark.fill" : "bookmark")
                        .frame(width: 20)
                    if let count = tweet.bookmarkCount, count > 0 {
                        Text("\(count)")
                            .frame(minWidth: 20, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity)
                .foregroundColor(.secondary)
            }
            
            // Share button
            Button(action: {
                showShareSheet = true
            }) {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 20)
                    .frame(maxWidth: .infinity)
            }
            .padding(.leading, 40)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 4)
        .sheet(isPresented: $showCommentCompose) {
            CommentComposeView(tweet: $tweet)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: [tweetShareText()])
        }
    }

    private func tweetShareText() -> String {
        var text = ""
        if let author = tweet.author {
            text += "@\(author.username ?? author.name ?? "")\n"
        }
        if let content = tweet.content {
            text += content + "\n"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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

struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
