import SwiftUI

@available(iOS 16.0, *)
struct TweetItemView: View {
    @ObservedObject var tweet: Tweet
    let embedded: Bool = false
    var isPinned: Bool = false
    var isInProfile: Bool = false
    var onAvatarTap: ((User) -> Void)? = nil
    var onTap: ((Tweet) -> Void)? = nil
    var hideActions: Bool = false
    var backgroundColor: Color = Color(.systemBackground)
    @State private var showDetail = false
    @State private var detailTweet: Tweet = Tweet(mid: Constants.GUEST_ID, authorId: Constants.GUEST_ID)   //place holder
    @State private var originalTweet: Tweet?
    @State private var refreshTimer: Timer?
    @State private var periodicRefreshTimer: Timer?
    @State private var isVisible = false
    @EnvironmentObject private var hproseInstance: HproseInstance
    var onRemove: ((String) -> Void)? = nil
    @State private var showBrowser = false
    @State private var selectedMediaIndex = 0

    private func mediaGrid(for tweet: Tweet) -> some View {
        Group {
            if let attachments = tweet.attachments, !attachments.isEmpty {
                MediaGridView(
                    parentTweet: tweet,
                    attachments: attachments,
                    onItemTap: { idx in
                        selectedMediaIndex = idx
                        showBrowser = true
                    }
                )
                .padding(.top, 8)
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let originalTweet = originalTweet {
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
                            TweetMenu(tweet: tweet, isPinned: isPinned)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onTap?(tweet)
                        }
                        
                        TweetItemBodyView(tweet: originalTweet, isVisible: isVisible)
                            .padding(.top, -12)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onTap?(tweet)
                            }
                        
                        TweetActionButtonsView(tweet: originalTweet)
                            .padding(.top, 8)
                    }
                } else {
                    // Show retweet with content and embedded original tweet
                    VStack(alignment: .leading) {
                        HStack {
                            TweetItemHeaderView(tweet: tweet)
                            TweetMenu(tweet: tweet, isPinned: isPinned)
                        }
                        .padding(.top, -8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onTap?(tweet)
                        }
                        TweetItemBodyView(tweet: tweet, enableTap: false, isVisible: isVisible, onItemTap: { idx in
                            selectedMediaIndex = idx
                            showBrowser = true
                        })
                            .padding(.top, -12)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onTap?(tweet)
                            }
                        
                        // Embedded original tweet with darker background, no left border, and aligned avatar
                        TweetItemView(
                            tweet: originalTweet,
                            isPinned: isPinned,
                            onTap: { t in onTap?(t) },
                            hideActions: true,
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
                    .padding(.top, -8)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onTap?(tweet)
                    }
                    TweetItemBodyView(tweet: tweet, enableTap: false, isVisible: isVisible, onItemTap: { idx in
                        selectedMediaIndex = idx
                        showBrowser = true
                    })
                        .padding(.top, -12)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onTap?(tweet)
                        }
                    if !hideActions {
                        TweetActionButtonsView(tweet: tweet)
                            .padding(.top, 8)
                    }
                }
            }
        }
        .padding()
        .padding(.horizontal, -4)
        .background(backgroundColor)
        .if(backgroundColor != Color(.systemBackground)) { view in
            view.shadow(color: Color(.sRGB, white: 0, opacity: 0.18), radius: 8, x: 0, y: 2)
        }
        .fullScreenCover(isPresented: $showBrowser) {
            MediaBrowserView(
                tweet: tweet,
                initialIndex: selectedMediaIndex
            )
        }
        .task {
            isVisible = true
            tweet.isVisible = true
            // Usually TweetDetailView is not orignalTweet
            detailTweet = tweet
            if let originalTweetId = tweet.originalTweetId, let originalAuthorId = tweet.originalAuthorId {
                if let t = try? await hproseInstance.getTweet(
                    tweetId: originalTweetId,
                    authorId: originalAuthorId
                ) {
                    originalTweet = t
                    detailTweet = t
                } else {
                    // Could not fetch original tweet, remove this tweet from the list
                    onRemove?(tweet.mid)
                    return
                }
            }
            
            // Start initial refresh timer (3 seconds)
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
            
            // Start periodic refresh timer (every 5 minutes)
            periodicRefreshTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { _ in
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
            isVisible = false
            tweet.isVisible = false
            // Cancel timer when view disappears
            refreshTimer?.invalidate()
            refreshTimer = nil
            periodicRefreshTimer?.invalidate()
            periodicRefreshTimer = nil
        }
    }
}
