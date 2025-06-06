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
    let isPinned: Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var appUser = HproseInstance.shared.appUser
    @EnvironmentObject private var hproseInstance: HproseInstance
    @State private var isCurrentlyPinned: Bool

    init(tweet: Tweet, isPinned: Bool) {
        self.tweet = tweet
        self.isPinned = isPinned
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
                        do {
                            try await deleteTweet(tweet)
                        } catch {
                            print("Tweet deletion failed. \(tweet)")
                        }
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundColor(.secondary)
                .padding(12)
                .contentShape(Rectangle())
        }
    }
    
    private func deleteTweet(_ tweet: Tweet) async throws {
        // Post notification for optimistic UI update
        NotificationCenter.default.post(
            name: .tweetDeleted,
            object: tweet.mid
        )
        
        // Attempt actual deletion
        if let tweetId = try? await hproseInstance.deleteTweet(tweet.mid) {
            print("Successfully deleted tweet: \(tweetId)")
            if let originalTweetId = tweet.originalTweetId,
               let originalAuthorId = tweet.originalAuthorId,
               let originalTweet = try? await hproseInstance.getTweet(
                tweetId: originalTweetId,
                authorId: originalAuthorId)
            {
                // originalTweet is loaded in cache, which is visible to user.
                let currentCount = originalTweet.retweetCount ?? 0
                originalTweet.retweetCount = max(0, currentCount - 1)
                try? await hproseInstance.updateRetweetCount(tweet: originalTweet, retweetId: tweet.mid, direction: false)
            }
        } else {
            // If deletion fails, post restoration notification
            NotificationCenter.default.post(
                name: .tweetRestored,
                object: tweet.mid
            )
        }
    }
}
