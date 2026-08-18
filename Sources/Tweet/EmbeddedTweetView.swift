import SwiftUI

// MARK: - Optimized Embedded Tweet View
@available(iOS 16.0, *)
struct EmbeddedTweetView: View, @MainActor Equatable {
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
