import SwiftUI

enum UserActions: Int {
    case FAVORITE = 0
    case BOOKMARK = 1
    case RETWEET = 2
}

@available(iOS 16.0, *)
struct TweetActionButtonsView: View {
    @ObservedObject var tweet: Tweet
    var commentsVM: CommentsViewModel? = nil
    @State private var showCommentCompose = false
    @State private var showShareSheet = false
    @State private var showLoginSheet = false
    @EnvironmentObject private var hproseInstance: HproseInstance

    private func handleGuestAction() {
        if hproseInstance.appUser.isGuest {
            showLoginSheet = true
        }
    }
    
    private func retweet(_ tweet: Tweet) async throws {
        do {
            let currentCount = tweet.retweetCount ?? 0
            tweet.retweetCount = currentCount + 1

            if let retweet = try await hproseInstance.retweet(tweet) {
                NotificationCenter.default.post(name: .newTweetCreated,
                                                object: nil,
                                                userInfo: ["tweet": retweet])
                // Update retweet count of the original tweet in backend.
                // tweet, the original tweet now, is updated in the following function.
                try? await hproseInstance.updateRetweetCount(tweet: tweet, retweetId: retweet.mid)
            }
        } catch {
            print("Retweet failed in FollowingsTweetView")
        }
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Comment button
            Button(action: {
                if hproseInstance.appUser.isGuest {
                    handleGuestAction()
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
                .frame(width: 48, alignment: .leading)
            }
            Spacer(minLength: 12)
            // Retweet button
            Button(action: {
                if hproseInstance.appUser.isGuest {
                    handleGuestAction()
                } else {
                    Task {
                        do {
                            try await retweet(tweet)
                        } catch {
                            print("reTweet failed. \(tweet)")
                        }
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
                .frame(width: 48, alignment: .leading)
            }
            Spacer(minLength: 12)
            // Like button
            Button(action: {
                if hproseInstance.appUser.isGuest {
                    handleGuestAction()
                } else {
                    Task {
                        // Optimistic UI update
                        let wasFavorite = tweet.favorites?[UserActions.FAVORITE.rawValue] ?? false
                        var newFavorites = tweet.favorites ?? [false, false, false]
                        newFavorites[UserActions.FAVORITE.rawValue] = !wasFavorite
                        await MainActor.run {
                            tweet.favorites = newFavorites
                            tweet.favoriteCount = (tweet.favoriteCount ?? 0) + (wasFavorite ? -1 : 1)
                        }
                        _ = try? await hproseInstance.toggleFavorite(tweet)
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
                .frame(width: 48, alignment: .leading)
            }
            Spacer(minLength: 12)
            // Bookmark button
            Button(action: {
                if hproseInstance.appUser.isGuest {
                    handleGuestAction()
                } else {
                    Task {
                        // Optimistic UI update
                        let wasBookmarked = tweet.favorites?[UserActions.BOOKMARK.rawValue] ?? false
                        var newFavorites = tweet.favorites ?? [false, false, false]
                        newFavorites[UserActions.BOOKMARK.rawValue] = !wasBookmarked
                        
                        await MainActor.run {
                            self.tweet.favorites = newFavorites
                            self.tweet.bookmarkCount = (self.tweet.bookmarkCount ?? 0) + (wasBookmarked ? -1 : 1)
                        }
                        _ = try? await hproseInstance.toggleBookmark(tweet)
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
                .frame(width: 48, alignment: .leading)
            }
            // Share button
            Spacer(minLength: 16)
            Button(action: {
                showShareSheet = true
            }) {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 20)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .foregroundColor(.themeSecondaryText)
        .padding(.trailing, 4)
        .padding(.leading, 0)
        .sheet(isPresented: $showCommentCompose) {
            if let commentsVM = commentsVM {
                CommentComposeView(tweet: tweet, commentsVM: commentsVM)
            } else {
                CommentComposeView(tweet: tweet, commentsVM: CommentsViewModel(hproseInstance: hproseInstance, parentTweet: tweet))
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: [tweetShareText()])
        }
        .sheet(isPresented: $showLoginSheet) {
            LoginView()
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

struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
