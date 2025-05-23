import SwiftUI

@available(iOS 16.0, *)
struct TweetItemView: View {
    @Binding var tweet: Tweet
    let retweet: (Tweet) async -> Void
    let deleteTweet: (Tweet) async -> Void
    let embedded: Bool = false
    
    var isInProfile: Bool = false
    var onAvatarTap: ((User) -> Void)? = nil
    @State private var showDetail = false
    @State private var originalTweet: Tweet? = nil
    
    private let hproseInstance = HproseInstance.shared
    @State private var detailTweet: Tweet = Tweet(mid: Constants.GUEST_ID, authorId: Constants.GUEST_ID)   //place holder
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            //            VStack(alignment: .leading, content: {
            //                TweetItemHeaderView(tweet: $tweet, deleteTweet: deleteTweet)
            //                    .contentShape(Rectangle())
            //                    .onTapGesture { showDetail = true }
            //                TweetItemBodyView(tweet: $tweet, enableTap: false, retweet: retweet)
            //                    .contentShape(Rectangle())
            //                    .onTapGesture { showDetail = true }
            //            })
            if let _ = tweet.originalTweetId, let _ = tweet.originalAuthorId {
                // This is a retweet
                if let originalTweet = originalTweet {
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
                    if tweet.content?.isEmpty ?? true, ((tweet.attachments?.isEmpty) == nil) {
                        // Show original tweet with retweet header
                        VStack(alignment: .leading, spacing: 8) {
                            // Original tweet content
                            HStack(alignment: .top, spacing: 8) {
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
                                        TweetMenu(tweet: $tweet, deleteTweet: deleteTweet)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        detailTweet = originalTweet
                                        showDetail = true
                                    }
                                    TweetItemBodyView(tweet: .constant(originalTweet), retweet: retweet)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            detailTweet = originalTweet
                                            showDetail = true
                                        }
                                }
                            }
                        }
                    } else {
                        // Show retweet with content and embedded original tweet
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
                                    TweetMenu(tweet: $tweet, deleteTweet: deleteTweet)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { showDetail = true }
                                TweetItemBodyView(tweet: $tweet, retweet: retweet, embedded: true, enableTap: false)
                                    .contentShape(Rectangle())
                                    .onTapGesture { showDetail = true }
                                
                                // Embedded original tweet
                                VStack(alignment: .leading, spacing: 8) {
                                    TweetItemView(tweet: .constant(originalTweet), retweet: retweet, deleteTweet: deleteTweet)
                                }
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(8)
                            }
                        }
                }
            } else {
                // Regular tweet
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
//                        Spacer()
                        TweetMenu(tweet: $tweet, deleteTweet: deleteTweet)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { showDetail = true }
                    TweetItemBodyView(tweet: $tweet, retweet: retweet, enableTap: false)
                    .contentShape(Rectangle())
                    .onTapGesture { showDetail = true }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .background(
            NavigationLink(destination: TweetDetailView(
                tweet: .constant(detailTweet),
                retweet: retweet,
                deleteTweet: deleteTweet
            ), isActive: $showDetail) {
                EmptyView()
            }
                .hidden()
        )
        .task {
            // most likely target of TweetDetailView is not orignalTweet
            detailTweet = tweet
            if let originalTweetId = tweet.originalTweetId,
               let originalAuthorId = tweet.originalAuthorId {
                do {
                    originalTweet = try await hproseInstance.getTweet(
                        tweetId: originalTweetId,
                        authorId: originalAuthorId
                    )
                } catch {
                    print("Error loading original tweet: \(error)")
                }
            }
        }
    }
}
