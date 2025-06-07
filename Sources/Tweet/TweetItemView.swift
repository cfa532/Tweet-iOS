import SwiftUI

@available(iOS 16.0, *)
struct TweetItemView: View {
    @ObservedObject var tweet: Tweet
    let embedded: Bool = false
    var isPinned: Bool = false
    var isInProfile: Bool = false
    var onAvatarTap: ((User) -> Void)? = nil
    @State private var showDetail = false
    @State private var detailTweet: Tweet = Tweet(mid: Constants.GUEST_ID, authorId: Constants.GUEST_ID)   //place holder
    @State private var originalTweet: Tweet?
    @State private var refreshTimer: Timer?
    @EnvironmentObject private var hproseInstance: HproseInstance

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let originalTweetId = tweet.originalTweetId, let originalAuthorId = tweet.originalAuthorId {
                // This is a retweet
                if let originalTweet = originalTweet, let user = originalTweet.author {
                    Button(action: {
                        if !isInProfile {
                            onAvatarTap?(user)
                        }
                    }) {
                        Avatar(user: user)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                if let originalTweet = originalTweet, tweet.content?.isEmpty ?? true, ((tweet.attachments?.isEmpty) == nil) {
                    // Show original tweet with retweet menu.
                    VStack(alignment: .leading, spacing: 8) {
                        // Original tweet content
                        HStack(alignment: .top, spacing: 8) {
                            Group {
                                TweetItemHeaderView(tweet: originalTweet)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                detailTweet = originalTweet
                                showDetail = true
                            }
                            Spacer(minLength: 0)
                        }
                        .overlay(
                            TweetMenu(tweet: tweet, isPinned: isPinned)
                                .zIndex(1),
                            alignment: .trailing
                        )
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
                } else {
                    if let originalTweet = originalTweet {
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
                                Group {
                                    TweetItemHeaderView(tweet: tweet)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { showDetail = true }
                                Spacer(minLength: 0)
                            }
                            .overlay(
                                TweetMenu(tweet: tweet, isPinned: isPinned)
                                    .zIndex(1),
                                alignment: .trailing
                            )
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
                        Group {
                            TweetItemHeaderView(tweet: tweet)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { showDetail = true }
                        Spacer(minLength: 0)
                    }
                    .overlay(
                        TweetMenu(tweet: tweet, isPinned: isPinned)
                            .zIndex(1),
                        alignment: .trailing
                    )
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
            // Usually TweetDetailView is not orignalTweet
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
            
            // Start refresh timer
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
                Task {
                    do {
                        if let refreshedTweet = try await hproseInstance.refreshTweet(
                            tweetId: tweet.mid,
                            authorId: tweet.authorId
                        ) {
                            // Update the tweet with refreshed data
                            try await MainActor.run {
                                try tweet.update(from: refreshedTweet)
                            }
                        }
                    } catch {
                        print("Error refreshing tweet: \(error)")
                    }
                }
            }
        }
        .onDisappear {
            // Cancel timer when view disappears
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }
}
