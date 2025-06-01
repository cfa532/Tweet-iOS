import SwiftUI

struct TweetItemHeaderView: View {
    @ObservedObject var tweet: Tweet
    
    var body: some View {
        HStack {
            HStack(alignment: .top) {
                Text(tweet.author?.name ?? "No one")
                    .font(.headline)
                Text("@\(tweet.author?.username ?? "")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}

struct TweetMenu: View {
    @ObservedObject var tweet: Tweet
    let deleteTweet: (Tweet) async -> Void
    let isPinned: Bool
    let isComment: Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var appUser = HproseInstance.shared.appUser
    @EnvironmentObject private var hproseInstance: HproseInstance
    @State private var isCurrentlyPinned: Bool

    init(tweet: Tweet, deleteTweet: @escaping (Tweet) async -> Void, isPinned: Bool, isComment: Bool = false) {
        self.tweet = tweet
        self.deleteTweet = deleteTweet
        self.isPinned = isPinned
        self.isComment = isComment
        self._isCurrentlyPinned = State(initialValue: isPinned)
    }

    var body: some View {
        Menu {
            if tweet.authorId == appUser.mid {
                Button(action: {
                    Task {
                        if let isPinned = try? await hproseInstance.togglePinnedTweet(tweetId: tweet.mid) {
                            isCurrentlyPinned = isPinned
                            NotificationCenter.default.post(
                                name: .tweetPinStatusChanged,
                                object: nil,
                                userInfo: [
                                    "tweetId": tweet.mid,
                                    "isPinned": isPinned
                                ]
                            )
                        }
                    }
                }) {
                    if isCurrentlyPinned {
                        Label("Unpin", systemImage: "pin.slash")
                    } else {
                        Label("Pin", systemImage: "pin")
                    }
                }
                Button(role: .destructive) {
                    // Start deletion in background
                    Task {
                        await deleteTweet(tweet)
                        // Post notification for successful deletion
                        NotificationCenter.default.post(
                            name: .tweetDeleted,
                            object: tweet.mid
                        )
                    }
                    // Dismiss only if this is not a comment
                    if !isComment {
                        dismiss()
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundColor(.secondary)
        }
    }
}
