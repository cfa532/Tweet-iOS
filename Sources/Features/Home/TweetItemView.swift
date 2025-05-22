import SwiftUI

struct TweetItemView: View {
    @Binding var tweet: Tweet
    let retweet: (Tweet) async -> Void
    let deleteTweet: (Tweet) async -> Void
    var isInProfile: Bool = false
    var onAvatarTap: ((User) -> Void)? = nil
    @State private var showDetail = false
    @State private var originalTweet: Tweet? = nil
    @State private var isLoadingOriginal = false

    private let hproseInstance = HproseInstance.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let _ = tweet.originalTweetId, let _ = tweet.originalAuthorId {
                // This is a retweet
                if isLoadingOriginal {
                    ProgressView()
                        .padding()
                } else if let originalTweet = originalTweet {
                    if tweet.content?.isEmpty ?? true {
                        // Show original tweet with retweet header
                        VStack(alignment: .leading, spacing: 8) {
                            // Original tweet content
                            HStack(alignment: .top, spacing: 8) {
                                if let user = originalTweet.author {
                                    Button(action: {
                                        if !isInProfile {
                                            onAvatarTap?(user)
                                        }
                                    }) {
                                        Avatar(user: user)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    // Retweet header
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.2.squarepath")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text("Forwarded by \(tweet.author?.username ?? "")")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    TweetItemHeaderView(tweet: $tweet, deleteTweet: deleteTweet)
                                    TweetItemBodyView(tweet: .constant(originalTweet), enableTap: false, retweet: retweet)
                                }
                            }
                            .padding()
                        }
                    } else {
                        // Show retweet with content and embedded original tweet
                        HStack(alignment: .top, spacing: 8) {
                            if let user = tweet.author {
                                Button(action: {
                                    if !isInProfile {
                                        onAvatarTap?(user)
                                    }
                                }) {
                                    Avatar(user: user)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            VStack(alignment: .leading) {
                                TweetItemHeaderView(tweet: $tweet, deleteTweet: deleteTweet)
                                TweetItemBodyView(tweet: $tweet, enableTap: false, retweet: retweet)
                                
                                // Embedded original tweet
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.2.squarepath")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text("Forwarded by \(tweet.author?.username ?? "")")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    HStack(alignment: .top, spacing: 8) {
                                        if let user = originalTweet.author {
                                            Button(action: {
                                                if !isInProfile {
                                                    onAvatarTap?(user)
                                                }
                                            }) {
                                                Avatar(user: user)
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                        }
                                        VStack(alignment: .leading) {
                                            TweetItemHeaderView(tweet: .constant(originalTweet), deleteTweet: { _ in })
                                            TweetItemBodyView(tweet: .constant(originalTweet), enableTap: false, retweet: retweet)
                                        }
                                    }
                                }
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(8)
                            }
                        }
                        .padding()
                    }
                }
            } else {
                // Regular tweet
                HStack(alignment: .top, spacing: 8) {
                    if let user = tweet.author {
                        Button(action: {
                            if !isInProfile {
                                onAvatarTap?(user)
                            }
                        }) {
                            Avatar(user: user)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    VStack(alignment: .leading) {
                        TweetItemHeaderView(tweet: $tweet, deleteTweet: deleteTweet)
                        TweetItemBodyView(tweet: $tweet, enableTap: false, retweet: retweet)
                    }
                }
                .padding()
            }
        }
        .background(Color(.systemBackground))
        .background(
            NavigationLink(destination: TweetDetailView(
                tweet: $tweet,
                retweet: retweet,
                deleteTweet: deleteTweet
            ), isActive: $showDetail) {
                EmptyView()
            }
            .hidden()
        )
        .task {
            if let originalTweetId = tweet.originalTweetId,
               let originalAuthorId = tweet.originalAuthorId {
                isLoadingOriginal = true
                do {
                    originalTweet = try await hproseInstance.getTweet(
                        tweetId: originalTweetId,
                        authorId: originalAuthorId
                    )
                } catch {
                    print("Error loading original tweet: \(error)")
                }
                isLoadingOriginal = false
            }
        }
    }
}
