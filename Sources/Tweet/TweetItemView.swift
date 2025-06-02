import SwiftUI

@available(iOS 16.0, *)
struct TweetItemView: View {
    @ObservedObject var tweet: Tweet
    let embedded: Bool = false
    var isPinned: Bool = false
    
    var isInProfile: Bool = false
    var onAvatarTap: ((User) -> Void)? = nil
    @State private var showDetail = false
    @State private var originalTweet: Tweet = Tweet(mid: Constants.GUEST_ID, authorId: Constants.GUEST_ID)
    @State private var detailTweet: Tweet = Tweet(mid: Constants.GUEST_ID, authorId: Constants.GUEST_ID)   //place holder
    @EnvironmentObject private var hproseInstance: HproseInstance

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let _ = tweet.originalTweetId {
                // This is a retweet
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
                    // Show original tweet with retweet menu.
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
                                    TweetItemHeaderView(tweet: originalTweet)
                                    TweetMenu(tweet: tweet, isPinned: isPinned)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    detailTweet = originalTweet
                                    showDetail = true
                                }
                                TweetItemBodyView(tweet: originalTweet)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        detailTweet = originalTweet
                                        showDetail = true
                                    }
                                    .padding(.top, 4)
                                TweetActionButtonsView(tweet: originalTweet)
                                    .padding(.top, 8)
                                    .padding(.leading, -20)
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
                            TweetItemHeaderView(tweet: tweet)
                            TweetMenu(tweet: tweet, isPinned: isPinned)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { showDetail = true }
                        TweetItemBodyView(tweet: tweet, enableTap: false)
                            .contentShape(Rectangle())
                            .onTapGesture { showDetail = true }
                        
                        // Embedded original tweet
                        VStack(alignment: .leading, spacing: 8) {
                            TweetItemView(tweet: originalTweet, isPinned: isPinned)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                        
                        TweetActionButtonsView(tweet: tweet)
                            .padding(.top, 8)
                            .padding(.leading, -8)
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
                        TweetItemHeaderView(tweet: tweet)
                        TweetMenu(tweet: tweet, isPinned: isPinned)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { showDetail = true }
                    TweetItemBodyView(tweet: tweet, enableTap: false)
                        .contentShape(Rectangle())
                        .onTapGesture { showDetail = true }
                        .padding(.top, 4)
                    
                    TweetActionButtonsView(tweet: tweet)
                        .padding(.top, 8)
                        .padding(.leading, -8)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .background(
            NavigationLink(destination: TweetDetailView(
                tweet: detailTweet,
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
                
                // should have checked if originalTweet is in the tweets already
                do {
                    if let t = try await hproseInstance.getTweet(
                        tweetId: originalTweetId,
                        authorId: originalAuthorId
                    ) {
                        originalTweet = t
                    }
                } catch {
                    print("Error loading original tweet: \(error)")
                }
            }
        }
    }
}
