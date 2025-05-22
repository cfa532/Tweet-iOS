import SwiftUI

struct TweetItemView: View {
    @Binding var tweet: Tweet
    let retweet: (Tweet) async -> Void
    let deleteTweet: (Tweet) async -> Void
    let embedded: Bool = false
    
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
                    if tweet.content?.isEmpty ?? true, ((tweet.attachments?.isEmpty) == nil) {
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
                                    HStack(alignment: .top) {
                                        TweetItemHeaderView(tweet: .constant(originalTweet))
                                        Spacer()
                                        TweetMenu(tweet: $tweet, deleteTweet: deleteTweet)
                                    }
                                    TweetItemBodyView(tweet: .constant(originalTweet), retweet: retweet, enableTap: false)
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
                                HStack {
                                    TweetItemHeaderView(tweet: $tweet)
                                    Spacer()
                                    TweetMenu(tweet: $tweet, deleteTweet: deleteTweet)
                                }
                                TweetItemBodyView(tweet: $tweet, retweet: retweet, embedded: true, enableTap: false)
                                
                                // Embedded original tweet
                                VStack(alignment: .leading, spacing: 8) {
                                    TweetItemView(tweet: .constant(originalTweet), retweet: retweet, deleteTweet: deleteTweet)
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
                        HStack {
                            TweetItemHeaderView(tweet: $tweet)
                            Spacer()
                            TweetMenu(tweet: $tweet, deleteTweet: deleteTweet)
                        }
                        TweetItemBodyView(tweet: $tweet, retweet: retweet, enableTap: false)
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
