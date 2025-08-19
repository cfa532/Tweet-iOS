import SwiftUI

@available(iOS 16.0, *)
struct TweetItemView: View, Equatable {
    @ObservedObject var tweet: Tweet
    let embedded: Bool = false
    var isPinned: Bool = false
    var isInProfile: Bool = false
    var showDeleteButton: Bool = false
    var onAvatarTap: ((User) -> Void)? = nil
    var onTap: ((Tweet) -> Void)? = nil
    var onAvatarTapInProfile: ((User) -> Void)? = nil
    var currentProfileUser: User? = nil
    var hideActions: Bool = false
    var backgroundColor: Color = Color(.systemBackground)
    @State private var showDetail = false
    @State private var detailTweet: Tweet = Tweet(mid: Constants.GUEST_ID, authorId: Constants.GUEST_ID)   //place holder
    @State private var originalTweet: Tweet?
    @State private var isVisible = false
    @EnvironmentObject private var hproseInstance: HproseInstance
    var onRemove: ((String) -> Void)? = nil
    @State private var showBrowser = false
    @State private var selectedMediaIndex = 0
    @State private var showEmbeddedBrowser = false
    @State private var selectedEmbeddedMediaIndex = 0
    @State private var hasLoadedOriginalTweet = false

    private func mediaGrid(for tweet: Tweet) -> some View {
        Group {
            if let attachments = tweet.attachments, !attachments.isEmpty {
                MediaGridView(
                    parentTweet: tweet,
                    attachments: attachments
                )
                .padding(.top, 8)
            }
        }
    }

    var body: some View {
        Group {
            if onTap == nil {
                // Use NavigationLink when no onTap callback is provided
                // For retweets with no content, navigate to the original tweet
                let navigationValue = (originalTweet != nil && (tweet.content?.isEmpty ?? true) && (tweet.attachments?.isEmpty ?? true)) ? originalTweet! : tweet
                NavigationLink(value: navigationValue) {
                    tweetContent
                }
                .buttonStyle(PlainButtonStyle())


            } else {
                // Use tap gesture when onTap callback is provided
                tweetContent
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // For retweets with no content, pass the original tweet to the callback
                        let callbackValue = (originalTweet != nil && (tweet.content?.isEmpty ?? true) && (tweet.attachments?.isEmpty ?? true)) ? originalTweet! : tweet
                        onTap?(callbackValue)
                    }
            }
        }
        .fullScreenCover(isPresented: $showBrowser) {
            MediaBrowserView(
                tweet: tweet,
                initialIndex: selectedMediaIndex
            )
        }
        .fullScreenCover(isPresented: $showEmbeddedBrowser) {
            MediaBrowserView(
                tweet: originalTweet ?? tweet,
                initialIndex: selectedEmbeddedMediaIndex
            )
        }
        .task {
            isVisible = true
            tweet.isVisible = true
            // Usually TweetDetailView is not orignalTweet
            detailTweet = tweet
        }
        .onAppear {
            // Defer original tweet loading to reduce async operations during scrolling
            if !hasLoadedOriginalTweet, 
               let originalTweetId = tweet.originalTweetId, 
               let originalAuthorId = tweet.originalAuthorId {
                hasLoadedOriginalTweet = true
                // TweetCacheManager already handles caching, so this will be fast
                Task {
                    if let t = try? await hproseInstance.getTweet(
                        tweetId: originalTweetId,
                        authorId: originalAuthorId
                    ) {
                        await MainActor.run {
                            originalTweet = t
                            detailTweet = t
                        }
                    } else {
                        // Could not fetch original tweet, remove this tweet from the list
                        await MainActor.run {
                            onRemove?(tweet.mid)
                        }
                    }
                }
            }
        }
        .onDisappear {
            isVisible = false
            tweet.isVisible = false
        }
        // Add stable identity to prevent unnecessary re-composition
        .id("\(tweet.mid)_\(originalTweet?.mid ?? "none")")
    }
    
    private var tweetContent: some View {
        HStack(alignment: .top, spacing: 8) {
            if let originalTweet = originalTweet {
                // This is a retweet
                if tweet.content?.isEmpty ?? true, ((tweet.attachments?.isEmpty) == nil) {
                    if let user = originalTweet.author {
                        if isInProfile {
                            // Check if this is the same user as the profile being viewed
                            if let currentProfileUser = currentProfileUser, currentProfileUser.mid == user.mid {
                                // Same user - scroll to top (handled by onAvatarTapInProfile)
                                Avatar(user: user)
                                    .onTapGesture {
                                        onAvatarTapInProfile?(user)
                                    }
                            } else {
                                // Different user - navigate to their profile
                                NavigationLink(value: user) {
                                    Avatar(user: user)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        } else {
                            Button {
                                onAvatarTap?(user)
                            } label: {
                                Avatar(user: user)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }

                    // Show original tweet with retweet menu.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.2.squarepath")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(String(format: NSLocalizedString("Forwarded by %@", comment: "Tweet forwarded by user"), tweet.author?.name ?? tweet.author?.username ?? ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, -8)
                        
                        HStack(alignment: .top) {
                            TweetItemHeaderView(tweet: originalTweet)
                            TweetMenu(tweet: tweet, isPinned: isPinned, showDeleteButton: showDeleteButton)
                                .padding(.top, -8)
                        }
                        
                        TweetItemBodyView(tweet: originalTweet, isVisible: isVisible)
                        .padding(.top, -12)
                        
                        TweetActionButtonsView(tweet: originalTweet)
                            .padding(.top, 8)
                    }
                } else {
                    // Show retweet with content and embedded original tweet
                    if let user = tweet.author {
                        if isInProfile {
                            Avatar(user: user)
                                .onTapGesture {
                                    onAvatarTapInProfile?(user)
                                }
                        } else {
                            NavigationLink(value: user) {
                                Avatar(user: user)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            TweetItemHeaderView(tweet: tweet)
                            TweetMenu(tweet: tweet, isPinned: isPinned, showDeleteButton: showDeleteButton)
                        }
                        .padding(.top, -8)
                        TweetItemBodyView(tweet: tweet, enableTap: false, isVisible: isVisible)
                        .padding(.top, -12)
                        
                        // Embedded original tweet with darker background, no left border, and aligned avatar
                        EmbeddedTweetView(
                            tweet: originalTweet,
                            isPinned: isPinned,
                            onTap: onTap, // Pass onTap directly (nil when using NavigationLink)
                            backgroundColor: Color(.systemGray4).opacity(0.7)
                        )
                        .cornerRadius(6)
                        .padding(.leading, -16)
                        
                        if !hideActions {
                            TweetActionButtonsView(tweet: tweet)
                                .padding(.top, 8)
                        }
                    }
                }
            } else {
                // Regular tweet
                if let user = tweet.author {
                                            if isInProfile {
                            Avatar(user: user)
                                .onTapGesture {
                                    onAvatarTapInProfile?(user)
                                }
                    } else {
                        NavigationLink(value: user) {
                            Avatar(user: user)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                VStack(alignment: .leading) {
                    HStack {
                        TweetItemHeaderView(tweet: tweet)
                        TweetMenu(tweet: tweet, isPinned: isPinned, showDeleteButton: showDeleteButton)
                    }
                    .padding(.top, -8)
                    TweetItemBodyView(tweet: tweet, enableTap: false, isVisible: isVisible)
                    .padding(.top, -12)
                    if !hideActions {
                        TweetActionButtonsView(tweet: tweet)
                            .padding(.top, 8)
                    }
                }
            }
        }
        .padding()
        .padding(.horizontal, -8)
        .background(backgroundColor)
        .if(backgroundColor != Color(.systemBackground)) { view in
            view.shadow(color: Color(.sRGB, white: 0, opacity: 0.18), radius: 8, x: 0, y: 2)
        }
    }
    
    // MARK: - Equatable Implementation
    static func == (lhs: TweetItemView, rhs: TweetItemView) -> Bool {
        return lhs.tweet.mid == rhs.tweet.mid &&
               lhs.isPinned == rhs.isPinned &&
               lhs.isInProfile == rhs.isInProfile &&
               lhs.showDeleteButton == rhs.showDeleteButton &&
               lhs.hideActions == rhs.hideActions &&
               lhs.backgroundColor == rhs.backgroundColor &&
               lhs.originalTweet?.mid == rhs.originalTweet?.mid
    }
}

// MARK: - Optimized Embedded Tweet View
@available(iOS 16.0, *)
struct EmbeddedTweetView: View, Equatable {
    @ObservedObject var tweet: Tweet
    var isPinned: Bool = false
    var onTap: ((Tweet) -> Void)? = nil
    var backgroundColor: Color = Color(.systemBackground)
    @State private var isVisible = false
    @EnvironmentObject private var hproseInstance: HproseInstance

    var body: some View {
        Group {
            if onTap == nil {
                // Use NavigationLink when no onTap callback is provided
                NavigationLink(value: tweet) {
                    embeddedContent
                }
                .buttonStyle(PlainButtonStyle())

            } else {
                // Use tap gesture when onTap callback is provided
                embeddedContent
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onTap?(tweet)
                    }
            }
        }
        .onAppear {
            isVisible = true
            tweet.isVisible = true
        }
        .onDisappear {
            isVisible = false
            tweet.isVisible = false
        }
        // Add stable identity for embedded tweets
        .id("embedded_\(tweet.mid)")
    }
    
    private var embeddedContent: some View {
        HStack(alignment: .top, spacing: 8) {
            if let user = tweet.author {
                Avatar(user: user)
            }
            VStack(alignment: .leading) {
                HStack {
                    TweetItemHeaderView(tweet: tweet)
                    Spacer()
                }
                .padding(.top, -8)
                
                TweetItemBodyView(tweet: tweet, enableTap: false, isVisible: isVisible)
                .padding(.top, -12)
            }
        }
        .padding(8)
        .background(backgroundColor)
    }
    
    // MARK: - Equatable Implementation
    static func == (lhs: EmbeddedTweetView, rhs: EmbeddedTweetView) -> Bool {
        return lhs.tweet.mid == rhs.tweet.mid &&
               lhs.isPinned == rhs.isPinned &&
               lhs.backgroundColor == rhs.backgroundColor
    }
}
