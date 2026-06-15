import SwiftUI

@available(iOS 16.0, *)
struct TweetItemView: View, Equatable {
    @ObservedObject var tweet: Tweet
    var isPinned: Bool = false
    var isInProfile: Bool = false
    var showDeleteButton: Bool = false
    var isLastItem: Bool = false  // Hide separator on last item
    var onAvatarTap: ((User) -> Void)? = nil
    var onTap: ((Tweet) -> Void)? = nil
    var onAvatarTapInProfile: ((User) -> Void)? = nil
    var currentProfileUser: User? = nil
    var hideActions: Bool = false
    var backgroundColor: Color = XTheme.backgroundColor
    var quotingTweetId: String? = nil // For embedded tweets: ID of the tweet that quotes this tweet
    @State private var originalTweet: Tweet?
    @State private var isVisible = false
    @EnvironmentObject private var hproseInstance: HproseInstance
    var onRemove: ((String) -> Void)? = nil
    @State private var showBrowser = false
    @State private var selectedMediaIndex = 0
    @State private var hasLoadedOriginalTweet = false
    @State private var hasRegisteredRetweetRelationship = false

    // Check if this is a retweet or quoted tweet
    private var isRetweetOrQuotedTweet: Bool {
        return tweet.originalTweetId != nil && tweet.originalAuthorId != nil
    }

    // Get embedded tweet - either from @State or from singleton cache (pre-loaded by TableViewController)
    private var embeddedTweet: Tweet? {
        if let cached = originalTweet {
            return cached
        }
        // Check if it was pre-loaded into singleton cache by TweetTableViewController
        if let originalTweetId = tweet.originalTweetId {
            return Tweet.getInstance(for: originalTweetId)
        }
        return nil
    }
    
    @ViewBuilder
    private func avatarView(for user: User, context: String) -> some View {
        if isInProfile {
            // Check if this is the same user as the profile being viewed
            if let currentProfileUser = currentProfileUser, currentProfileUser.mid == user.mid {
                // Same user - scroll to top
                Avatar(user: user, size: 40)
                    .onTapGesture {
                        onAvatarTapInProfile?(user)
                    }
            } else {
                // Different user - navigate to their profile
                NavigationLink(value: user) {
                    Avatar(user: user, size: 40)
                }
                .buttonStyle(PlainButtonStyle())
            }
        } else {
            if onAvatarTap != nil {
                // Use callback when provided
                Button {
                    print("⭐ [TweetItemView] Avatar button tapped (\(context)) - user: \(user.username ?? "nil")")
                    onAvatarTap?(user)
                } label: {
                    Avatar(user: user, size: 40)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                // Use NavigationLink when no callback
                NavigationLink(value: user) {
                    Avatar(user: user, size: 40)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                // Hide retweets/quoted tweets if their original tweets failed to load
                if isRetweetOrQuotedTweet && embeddedTweet == nil && hasLoadedOriginalTweet {
                    // This is a retweet/quoted tweet but original tweet failed to load - don't show it
                    EmptyView()
                } else if onTap == nil {
                    // Use NavigationLink when no onTap callback is provided
                    // For retweets with no content, navigate to the original tweet
                    let navigationValue = (embeddedTweet != nil && (tweet.content?.isEmpty ?? true) && (tweet.attachments?.isEmpty ?? true)) ? embeddedTweet! : tweet
                    NavigationLink(value: navigationValue) {
                        tweetContent
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    // Use tap gesture when onTap callback is provided
                    tweetContent
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // For retweets with no content, pass the original tweet to the callback
                            let callbackValue = (embeddedTweet != nil && (tweet.content?.isEmpty ?? true) && (tweet.attachments?.isEmpty ?? true)) ? embeddedTweet! : tweet
                            onTap?(callbackValue)
                        }
                }
            }
            
            // Bottom separator with shadow (hidden on last item)
            if !isLastItem {
                Rectangle()
                    .fill(Color(.systemGray).opacity(0.2))
                    .frame(height: 1)
                    .padding(.horizontal, 2)
            }
        }
        .fullScreenCover(isPresented: $showBrowser) {
            MediaBrowserView(
                tweet: tweet,
                initialIndex: selectedMediaIndex,
                cellTweetId: tweet.mid // Pass visible tweet ID for feed navigation
            )
        }
        .task {
            isVisible = true
            tweet.isVisible = true
            
            // Load author if not already loaded
            if tweet.author == nil {
                // No author at all - try to load from cache first, then fetch in background
                let cachedAuthor = await TweetCacheManager.shared.fetchUser(mid: tweet.authorId)
                await MainActor.run {
                    if cachedAuthor.username != nil {
                        // Use cached user as placeholder until refresh succeeds
                        tweet.author = cachedAuthor
                        print("⚡ [RENDER] Tweet rendering with cached author (@\(cachedAuthor.username ?? "?")), fetching in background")
                    } else {
                        // No cached user, use skeleton as last resort
                        tweet.author = User.getInstance(mid: tweet.authorId)
                        print("⚡ [RENDER] Tweet rendering with placeholder (no author), fetching in background")
                    }
                }
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
                // Author exists but no baseUrl (old cache data or new user) - resolve IP in background
                Task.detached(priority: .background) {
                    _ = try? await hproseInstance.fetchUser(tweet.authorId)
                }
            } else {
                // Tweet has complete author data (username + baseUrl)
                // This happens when app init completed before tweet started rendering
                // Comment out in production to reduce log noise
                // print("⚡ [RENDER] Tweet ready (@\(tweet.author?.username ?? "?"))")
            }
        }
        // CRITICAL: Pre-load original tweet from cache synchronously on appear
        // This ensures the original tweet is available immediately if cached, preventing layout delays
        .onAppear {
            // Try to load from cache synchronously first (fast if cached)
            if let originalTweetId = tweet.originalTweetId,
               originalTweet == nil,
               let cachedTweet = TweetCacheManager.shared.fetchTweetSync(mid: originalTweetId) {
                originalTweet = cachedTweet
                hasLoadedOriginalTweet = true
                
                // Keep coordinator's canonical list updated:
                // - Quoted tweet: embedded tweet videos belong to the quoting cell.
                // - Pure retweet: original tweet videos belong to the retweet cell.
                let hasContentText = tweet.content != nil && !(tweet.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let hasAttachments = tweet.attachments != nil && !(tweet.attachments?.isEmpty ?? true)
                let hasOwnContent = hasContentText || hasAttachments
                if hasOwnContent {
                    VideoPlaybackCoordinator.shared.addEmbeddedTweetVideos(
                        quotingTweetId: tweet.mid,
                        embeddedTweet: cachedTweet
                    )
                } else {
                    VideoPlaybackCoordinator.shared.addRetweetVideos(
                        retweetId: tweet.mid,
                        originalTweet: cachedTweet
                    )
                }
                
                // Register retweet relationship ASAP from cache
                if !hasRegisteredRetweetRelationship {
                    VideoLoadingManager.shared.registerRetweetRelationship(
                        retweetId: tweet.mid,
                        originalTweetId: cachedTweet.mid
                    )
                    hasRegisteredRetweetRelationship = true
                }
            }
        }
        // Use .task(id:) instead of onAppear for stable async loading (like Android's LaunchedEffect)
        // This ensures the task only runs when originalTweetId changes, preventing duplicate loads
        .task(id: tweet.originalTweetId, priority: .userInitiated) {
            // Load original tweet if this is a retweet/quoted tweet
            // Use .userInitiated priority for faster loading of visible content
            guard let originalTweetId = tweet.originalTweetId,
                  let originalAuthorId = tweet.originalAuthorId else {
                return
            }
            
            // Skip cache load if already loaded synchronously in onAppear
            if originalTweet == nil {
                // First, try to restore from cache immediately to prevent layout shifts
                if let cachedTweet = await TweetCacheManager.shared.fetchTweet(mid: originalTweetId) {
                    await MainActor.run {
                        originalTweet = cachedTweet
                        hasLoadedOriginalTweet = true

                        // Keep coordinator's canonical list updated (quoted vs pure retweet).
                        let hasContentText = tweet.content != nil && !(tweet.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                        let hasAttachments = tweet.attachments != nil && !(tweet.attachments?.isEmpty ?? true)
                        let hasOwnContent = hasContentText || hasAttachments
                        if hasOwnContent {
                            VideoPlaybackCoordinator.shared.addEmbeddedTweetVideos(
                                quotingTweetId: tweet.mid,
                                embeddedTweet: cachedTweet
                            )
                        } else {
                            VideoPlaybackCoordinator.shared.addRetweetVideos(
                                retweetId: tweet.mid,
                                originalTweet: cachedTweet
                            )
                        }

                        // Register retweet relationship ASAP from cache for immediate priority boost
                        if !hasRegisteredRetweetRelationship {
                            VideoLoadingManager.shared.registerRetweetRelationship(
                                retweetId: tweet.mid,
                                originalTweetId: cachedTweet.mid
                            )
                            hasRegisteredRetweetRelationship = true
                        }
                    }
                }
            }
            
            // Then fetch from server to get the latest version
            if let t = try? await hproseInstance.getTweet(
                tweetId: originalTweetId,
                authorId: originalAuthorId
            ) {
                // Register relationship from server fetch only if not already registered
                // (handles case where cache miss but server fetch succeeds)
                if !hasRegisteredRetweetRelationship {
                    VideoLoadingManager.shared.registerRetweetRelationship(
                        retweetId: tweet.mid,
                        originalTweetId: t.mid
                    )
                    hasRegisteredRetweetRelationship = true
                }

                await MainActor.run {
                    hasLoadedOriginalTweet = true

                    // Keep coordinator's canonical list updated (quoted vs pure retweet).
                    let hasContentText = tweet.content != nil && !(tweet.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    let hasAttachments = tweet.attachments != nil && !(tweet.attachments?.isEmpty ?? true)
                    let hasOwnContent = hasContentText || hasAttachments
                    if hasOwnContent {
                        VideoPlaybackCoordinator.shared.addEmbeddedTweetVideos(
                            quotingTweetId: tweet.mid,
                            embeddedTweet: t
                        )
                    } else {
                        VideoPlaybackCoordinator.shared.addRetweetVideos(
                            retweetId: tweet.mid,
                            originalTweet: t
                        )
                    }

                    // CRITICAL: Only update originalTweet state if it wasn't already loaded
                    // If embeddedTweet computed property already found the tweet via singleton cache,
                    // don't trigger a re-render by setting originalTweet state
                    // This prevents late layout shifts after server fetch completes
                    if originalTweet == nil {
                        // Was not in cache initially, update state to show fetched tweet
                        originalTweet = t
                        print("DEBUG: [TweetItemView] Updated originalTweet state after server fetch")
                    } else {
                        // Already rendered from cache, don't trigger re-layout
                        print("DEBUG: [TweetItemView] Skipping state update - already rendered from cache")
                    }
                }
            } else {
                // Server fetch failed - check if we have cache
                await MainActor.run {
                    if originalTweet == nil {
                        // No cache either - remove this tweet from the list
                        hasLoadedOriginalTweet = true  // Mark as loaded to prevent infinite placeholder
                        onRemove?(tweet.mid)
                    } else {
                        // We have cache, but server fetch failed - mark as loaded to use cached version
                        hasLoadedOriginalTweet = true
                    }
                }
            }
        }
        .onDisappear {
            isVisible = false
            tweet.isVisible = false
        }
    }
    
    private var tweetContent: some View {
        HStack(alignment: .top, spacing: 4) {
            if let originalTweet = embeddedTweet {
                // This is a retweet
                if tweet.content?.isEmpty ?? true, ((tweet.attachments?.isEmpty) == nil) {
                    // Use Group to force re-evaluation when originalTweet.author changes (@Published)
                    Group {
                        if let user = originalTweet.author {
                            avatarView(for: user, context: "retweet-no-content")
                        } else {
                            // Show placeholder while author loads
                            Circle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 42, height: 42)
                        }
                    }
                    // STABILITY: Fixed avatar size prevents layout shifts
                    .frame(width: 42, height: 42)
                    .padding(.leading, 3)
                    
                    // Show original tweet with retweet menu.
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.2.squarepath")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if let author = tweet.author, author.mid == hproseInstance.appUser.mid {
                                // If the forwarder is the appUser, show "Forwarded by you"
                                Text(NSLocalizedString("Forwarded by you", comment: "Tweet forwarded by appUser"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                // Otherwise, show "Forwarded by [username]"
                                Text(String(format: NSLocalizedString("Forwarded by %@", comment: "Tweet forwarded by user"), tweet.author?.name ?? tweet.author?.username ?? ""))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack(alignment: .top, spacing: 0) {
                            TweetItemHeaderView(tweet: originalTweet)
                            Spacer(minLength: 0)
                            TweetMenu(tweet: tweet, isPinned: isPinned, showDeleteButton: showDeleteButton)
                                .padding(.trailing, -20)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        TweetItemBodyView(
                            tweet: originalTweet,
                            isVisible: isVisible,
                            cellTweetId: tweet.mid,
                            onTweetBodyTap: {
                                // Navigate to original tweet detail when body is tapped
                                if let callback = onTap {
                                    callback(originalTweet)
                                }
                            }
                        )
                        // STABILITY: Layout priority for tweet body prevents shifting
                        .layoutPriority(1)
                        
                        TweetActionButtonsView(tweet: originalTweet)
                            .padding(.top, 8)
                            .padding(.trailing, 4)
                    }
                    // STABILITY: Fixed size maintains consistent vertical spacing
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Show retweet with content and embedded original tweet
                    // Use Group to force re-evaluation when tweet.author changes (@Published)
                    Group {
                        if let user = tweet.author {
                            avatarView(for: user, context: "retweet-with-content")
                        } else {
                            // Show placeholder while author loads
                            Circle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 42, height: 42)
                        }
                    }
                    // STABILITY: Fixed avatar size prevents layout shifts
                    .frame(width: 42, height: 42)
                    .padding(.leading, 3)
                    
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 0) {
                            TweetItemHeaderView(tweet: tweet)
                            Spacer(minLength: 0)
                            TweetMenu(tweet: tweet, isPinned: isPinned, showDeleteButton: showDeleteButton)
                                .padding(.trailing, -20)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        TweetItemBodyView(
                            tweet: tweet,
                            enableTap: false,
                            isVisible: isVisible,
                            onTweetBodyTap: {
                                // Navigate to tweet detail when body is tapped
                                if let callback = onTap {
                                    callback(tweet)
                                }
                            }
                        )
                        // STABILITY: Layout priority for tweet body prevents shifting
                        .layoutPriority(1)
                        
                        // Embedded original tweet styled to match Android's quoted tweet card.
                        EmbeddedTweetView(
                            tweet: originalTweet,
                            isPinned: isPinned,
                            onTap: onTap, // Pass onTap directly (nil when using NavigationLink)
                            isEmbedded: true,
                            isInProfile: isInProfile,
                            currentProfileUser: currentProfileUser,
                            onAvatarTapInProfile: onAvatarTapInProfile,
                            quotingTweetId: tweet.mid  // The current tweet is quoting the originalTweet
                        )
                        .padding(.leading, -4)
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                        .frame(minHeight: 60)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                        
                        if !hideActions {
                            TweetActionButtonsView(tweet: tweet)
                                .padding(.top, 8)
                                .padding(.trailing, 4)
                        }
                    }
                    // STABILITY: Fixed size maintains consistent vertical spacing
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else if isRetweetOrQuotedTweet && !hasLoadedOriginalTweet {
                // originalTweet is nil and hasn't loaded yet - show placeholder
                Group {
                    if let user = tweet.author {
                        avatarView(for: user, context: "retweet-loading")
                    } else {
                        // Show placeholder while author loads
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 42, height: 42)
                    }
                }
                // STABILITY: Fixed avatar size prevents layout shifts
                .frame(width: 42, height: 42)
                .padding(.leading, 3)
                
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        TweetItemHeaderView(tweet: tweet)
                        Spacer(minLength: 0)
                        TweetMenu(tweet: tweet, isPinned: isPinned, showDeleteButton: showDeleteButton)
                            .padding(.trailing, -12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // Show tweet content if available
                    if let content = tweet.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        TweetItemBodyView(
                            tweet: tweet,
                            enableTap: false,
                            isVisible: isVisible,
                            onTweetBodyTap: {
                                // Navigate to tweet detail when body is tapped
                                if let callback = onTap {
                                    callback(tweet)
                                }
                            }
                        )
                        // STABILITY: Layout priority for tweet body prevents shifting
                        .layoutPriority(1)
                    }
                    
                    // STABILITY: Placeholder for embedded tweet with fixed height
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Rectangle()
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 20)
                                .cornerRadius(4)
                            Rectangle()
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 16)
                                .cornerRadius(4)
                        }
                    }
                    .padding(8)
                    .background(Color(.systemGray4).opacity(0.3))
                    .cornerRadius(8)
                    .frame(height: 60)
                    .padding(.top, (tweet.content?.isEmpty ?? true) ? 0 : 8)
                    .fixedSize(horizontal: false, vertical: true)
                    
                    if !hideActions {
                        TweetActionButtonsView(tweet: tweet)
                            .padding(.top, 8)
                            .padding(.trailing, 4)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            } else {
                // Regular tweet
                Group {
                    if let user = tweet.author {
                        avatarView(for: user, context: "regular-tweet")
                    } else {
                        // Show placeholder while author loads
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 42, height: 42)
                            .overlay(
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .tint(.white)
                            )
                    }
                }
                // STABILITY: Fixed avatar size prevents layout shifts
                .frame(width: 42, height: 42)
                .padding(.leading, 3)
                
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        TweetItemHeaderView(tweet: tweet)
                        Spacer(minLength: 0)
                        TweetMenu(tweet: tweet, isPinned: isPinned, showDeleteButton: showDeleteButton)
                            .padding(.trailing, -20)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    TweetItemBodyView(
                        tweet: tweet,
                        enableTap: false,
                        isVisible: isVisible,
                        onTweetBodyTap: {
                            // Navigate to tweet detail when body is tapped
                            if let callback = onTap {
                                callback(tweet)
                            }
                        }
                    )
                    // STABILITY: Layout priority for tweet body prevents shifting
                    .layoutPriority(1)
                    
                    if !hideActions {
                        TweetActionButtonsView(tweet: tweet)
                            .padding(.top, 8)
                            .padding(.trailing, 4)
                    }
                }
                // STABILITY: Fixed size maintains consistent vertical spacing
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top)
        .padding(.bottom)
        .background(backgroundColor)
        .if(backgroundColor != XTheme.backgroundColor) { view in
            view.shadow(color: Color(.sRGB, white: 0, opacity: 0.18), radius: 8, x: 0, y: 2)
        }
        // STABILITY: Stable ID prevents view recreation during recomposition
        .id("tweet_\(tweet.mid)")
    }
    
    // MARK: - Equatable Implementation
    static func == (lhs: TweetItemView, rhs: TweetItemView) -> Bool {
        return lhs.tweet.mid == rhs.tweet.mid &&
               lhs.isPinned == rhs.isPinned &&
               lhs.isInProfile == rhs.isInProfile &&
               lhs.showDeleteButton == rhs.showDeleteButton &&
               lhs.isLastItem == rhs.isLastItem &&
               lhs.hideActions == rhs.hideActions &&
               lhs.backgroundColor == rhs.backgroundColor &&
               lhs.originalTweet?.mid == rhs.originalTweet?.mid &&
               lhs.tweet.originalTweetId == rhs.tweet.originalTweetId
    }
}

// MARK: - Optimized Embedded Tweet View
@available(iOS 16.0, *)
struct EmbeddedTweetView: View, Equatable {
    @ObservedObject var tweet: Tweet
    var isPinned: Bool = false
    var onTap: ((Tweet) -> Void)? = nil
    var backgroundColor: Color = Color(uiColor: XTheme.quotedTweetSurface)
    var isEmbedded: Bool = false // Flag to indicate this is an embedded tweet (prevents video loading)
    var isInProfile: Bool = false
    var currentProfileUser: User? = nil
    var onAvatarTapInProfile: ((User) -> Void)? = nil
    var quotingTweetId: String? = nil // For embedded videos, ID of the tweet that quotes this tweet
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
        // Add identity for embedded tweets
        .id("embedded_\(tweet.mid)")
    }
    
    private var embeddedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Row 1: avatar + header
            HStack(alignment: .center, spacing: 6) {
                Group {
                    if let user = tweet.author {
                        NavigationLink(value: user) {
                            Avatar(user: user, size: 32)
                        }
                        .buttonStyle(PlainButtonStyle())
                    } else {
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 32, height: 32)
                    }
                }
                .frame(width: 32, height: 32)

                TweetItemHeaderView(tweet: tweet)
                Spacer()
            }

            // Row 2: body (full width, flush with card edge)
            TweetItemBodyView(
                tweet: tweet,
                enableTap: false,
                isVisible: isVisible,
                isEmbedded: isEmbedded,
                cellTweetId: quotingTweetId,
                onTweetBodyTap: onTap.map { callback in { callback(tweet) } }
            )
            .layoutPriority(1)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    // MARK: - Equatable Implementation
    static func == (lhs: EmbeddedTweetView, rhs: EmbeddedTweetView) -> Bool {
        return lhs.tweet.mid == rhs.tweet.mid &&
               lhs.isPinned == rhs.isPinned &&
               lhs.backgroundColor == rhs.backgroundColor &&
               lhs.isEmbedded == rhs.isEmbedded &&
               lhs.isInProfile == rhs.isInProfile &&
               lhs.currentProfileUser?.mid == rhs.currentProfileUser?.mid &&
               lhs.quotingTweetId == rhs.quotingTweetId
    }
}
