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
    
    // Check if this is a retweet or quoted tweet
    private var isRetweetOrQuotedTweet: Bool {
        return tweet.originalTweetId != nil && tweet.originalAuthorId != nil
    }

    private func mediaGrid(for tweet: Tweet) -> some View {
        Group {
            if let attachments = tweet.attachments, !attachments.isEmpty {
                MediaGridView(
                    parentTweet: tweet,
                    attachments: attachments,
                    visibleTweetId: tweet.mid
                )
                .padding(.top, 8)
            }
        }
    }

    var body: some View {
        Group {
            // Hide retweets/quoted tweets if their original tweets failed to load
            if isRetweetOrQuotedTweet && originalTweet == nil && hasLoadedOriginalTweet {
                // This is a retweet/quoted tweet but original tweet failed to load - don't show it
                EmptyView()
            } else if onTap == nil {
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
                initialIndex: selectedMediaIndex,
                sourceTweetId: tweet.mid // Pass visible tweet ID for feed navigation
            )
        }
        .fullScreenCover(isPresented: $showEmbeddedBrowser) {
            MediaBrowserView(
                tweet: originalTweet ?? tweet,
                initialIndex: selectedEmbeddedMediaIndex,
                sourceTweetId: tweet.mid // Pass visible tweet ID (the retweet)
            )
        }
        .task {
            let taskStartTime = Date()
            isVisible = true
            tweet.isVisible = true
            // Usually TweetDetailView is not orignalTweet
            detailTweet = tweet
            
            // Load author if not already loaded
            if tweet.author == nil {
                // No author at all - create placeholder and fetch in background
                await MainActor.run {
                    tweet.author = User.getInstance(mid: tweet.authorId)
                }
                print("⚡ [RENDER] Tweet rendering with placeholder (no author), fetching in background")
                Task.detached(priority: .background) {
                    _ = try? await hproseInstance.fetchUser(tweet.authorId)
                }
            } else if tweet.author?.username == nil {
                print("⚡ [RENDER] Tweet rendering with placeholder (no username), fetching in background")
                // Author exists but has no username - render with placeholder and fetch in background
                Task.detached(priority: .background) {
                    _ = try? await hproseInstance.fetchUser(tweet.authorId)
                }
            } else if tweet.author?.baseUrl == nil {
                print("⚡ [RENDER] Tweet rendering immediately (@\(tweet.author?.username ?? "?")) - fetching baseUrl in background")
                // Author exists with username but no baseUrl - resolve IP in background
                Task.detached(priority: .background) {
                    _ = try? await hproseInstance.fetchUser(tweet.authorId)
                }
            } else {
                // Only log once on app start for first few tweets
                // print("⚡ [RENDER] Tweet ready (@\(tweet.author?.username ?? "?"))")
            }
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
                        // CRITICAL: Register relationship IMMEDIATELY before setting originalTweet
                        // This ensures MediaGridView (which may appear via TweetItemBodyView) 
                        // already knows about the relationship when it checks shouldLoadVideos
                        VideoLoadingManager.shared.registerRetweetRelationship(
                            retweetId: tweet.mid,
                            originalTweetId: t.mid
                        )
                        
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
        HStack(alignment: .top, spacing: 4) {
            if let originalTweet = originalTweet {
                // This is a retweet
                if tweet.content?.isEmpty ?? true, ((tweet.attachments?.isEmpty) == nil) {
                    // Use Group to force re-evaluation when originalTweet.author changes (@Published)
                    Group {
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
                        } else {
                            // Show placeholder while author loads (same size as Avatar default: 40)
                            Circle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 40, height: 40)
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
                        
                        TweetItemBodyView(tweet: originalTweet, isVisible: isVisible, visibleTweetId: tweet.mid)
                            .padding(.top, -12)
                        
                        TweetActionButtonsView(tweet: originalTweet)
                            .padding(.top, 8)
                    }
                } else {
                    // Show retweet with content and embedded original tweet
                    // Use Group to force re-evaluation when tweet.author changes (@Published)
                    Group {
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
                        } else {
                            // Show placeholder while author loads (same size as Avatar default: 40)
                            Circle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 40, height: 40)
                        }
                    }
                    
                    VStack(alignment: .leading) {
                        HStack {
                            TweetItemHeaderView(tweet: tweet)
                            TweetMenu(tweet: tweet, isPinned: isPinned, showDeleteButton: showDeleteButton)
                        }
                        .padding(.top, -8)
                        TweetItemBodyView(tweet: tweet, enableTap: false, isVisible: isVisible, visibleTweetId: tweet.mid)
                            .padding(.top, -12)
                        
                        // Embedded original tweet with darker background, no left border, and aligned avatar
                        EmbeddedTweetView(
                            tweet: originalTweet,
                            isPinned: isPinned,
                            onTap: onTap, // Pass onTap directly (nil when using NavigationLink)
                            backgroundColor: Color(.systemGray4).opacity(0.6)
                        )
                        .cornerRadius(8)
                        .padding(.leading, -4)
                        
                        if !hideActions {
                            TweetActionButtonsView(tweet: tweet)
                                .padding(.top, 8)
                        }
                    }
                }
            } else {
                // Regular tweet
                // Use Group to force re-evaluation when tweet.author changes (@Published)
                Group {
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
                    } else {
                        // Show placeholder while author loads
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 40, height: 40)
                            .overlay(
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .tint(.white)
                            )
                    }
                }
                VStack(alignment: .leading) {
                    HStack {
                        TweetItemHeaderView(tweet: tweet)
                        TweetMenu(tweet: tweet, isPinned: isPinned, showDeleteButton: showDeleteButton)
                    }
                    .padding(.top, -8)
                    TweetItemBodyView(tweet: tweet, enableTap: false, isVisible: isVisible, visibleTweetId: tweet.mid)
                        .padding(.top, -12)
                    if !hideActions {
                        TweetActionButtonsView(tweet: tweet)
                            .padding(.top, 8)
                    }
                }
            }
        }
        .padding()
        .padding(.leading, -4)
        .padding(.trailing, -8)
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
            
            // Mark tweet as accessed for cache management
            TweetCacheManager.shared.markTweetAccessed(tweet.mid)
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
            // Use Group to force re-evaluation when tweet.author changes (@Published)
            Group {
                if let user = tweet.author {
                    Avatar(user: user)
                } else {
                    // Placeholder (same size as Avatar default: 40)
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 40, height: 40)
                }
            }
            VStack(alignment: .leading) {
                HStack {
                    TweetItemHeaderView(tweet: tweet)
                    Spacer()
                }
                .padding(.top, 0)
                
                TweetItemBodyView(tweet: tweet, enableTap: false, isVisible: isVisible, visibleTweetId: tweet.mid)
                .padding(.top, 0)
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
