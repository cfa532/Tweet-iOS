import SwiftUI

private struct TweetListScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

@available(iOS 16.0, *)
struct ProfileTweetsSection: View {
    let isLoading: Bool
    let pinnedTweets: [Tweet] // sorted, from state
    let pinnedTweetIds: Set<String> // from state
    let user: User
    let hproseInstance: HproseInstance
    let onUserSelect: (User) -> Void
    let onPinnedTweetsRefresh: () async -> Void
    let onScroll: (CGFloat) -> Void
    
    var body: some View {
        if isLoading {
            ProgressView("Loading tweets...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack(alignment: .top) {
                ScrollView {
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: TweetListScrollOffsetKey.self, value: geo.frame(in: .global).minY)
                    }
                    .frame(height: 0)
                    VStack(spacing: 0) {
                        if !pinnedTweets.isEmpty {
                            Text("Pinned")
                                .font(.subheadline)
                                .bold()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color(UIColor.systemBackground))
                        }
                        TweetListView<TweetItemView>(
                            title: "",
                            tweetFetcher: { page, size in
                                if page == 0 {
                                    // Use pinnedTweets from state (already sorted)
                                    let regularTweets = try await hproseInstance.fetchUserTweet(
                                        user: user,
                                        startRank: 0,
                                        endRank: UInt(size - 1)
                                    )
                                    let filteredRegular = regularTweets.filter { !pinnedTweetIds.contains($0.mid) }
                                    return pinnedTweets + filteredRegular
                                } else {
                                    let start = UInt(page * size)
                                    let end = UInt((page + 1) * size - 1)
                                    let regularTweets = try await hproseInstance.fetchUserTweet(
                                        user: user,
                                        startRank: start,
                                        endRank: end
                                    )
                                    return regularTweets.filter { !pinnedTweetIds.contains($0.mid) }
                                }
                            },
                            showTitle: false,
                            rowView: { tweet in
                                TweetItemView(
                                    tweet: tweet,
                                    retweet: { tweet in
                                        do {
                                            let currentCount = tweet.retweetCount ?? 0
                                            tweet.retweetCount = currentCount + 1

                                            if let retweet = try await hproseInstance.retweet(tweet) {
                                                NotificationCenter.default.post(name: .newTweetCreated,
                                                                                object: nil,
                                                                                userInfo: ["tweet": retweet])
                                                // Update retweet count of the original tweet in backend.
                                                // tweet, the original tweet now, is updated in the following function.
                                                try? await hproseInstance.updateRetweetCount(tweet: tweet, retweetId: retweet.mid)
                                            }
                                        } catch {
                                            print("Retweet failed in ProfileTweetsSection")
                                        }
                                    },
                                    deleteTweet: { tweet in
                                        // Post notification for optimistic UI update
                                        NotificationCenter.default.post(
                                            name: .tweetDeleted,
                                            object: tweet.mid
                                        )
                                        
                                        // Attempt actual deletion
                                        if let tweetId = try? await hproseInstance.deleteTweet(tweet.mid) {
                                            print("Successfully deleted tweet: \(tweetId)")
                                            if pinnedTweetIds.contains(tweet.mid) {
                                                await onPinnedTweetsRefresh()
                                            }
                                            if let originalTweetId = tweet.originalTweetId,
                                               let originalAuthorId = tweet.originalAuthorId,
                                               let originalTweet = try? await hproseInstance.getTweet(tweetId: originalTweetId,
                                                                                                      authorId: originalAuthorId)
                                            {
                                                // originalTweet is loaded in cache, which is visible to user.
                                                let currentCount = originalTweet.retweetCount ?? 0
                                                originalTweet.retweetCount = max(0, currentCount - 1)
                                                try? await hproseInstance.updateRetweetCount(tweet: originalTweet,
                                                                                             retweetId: tweet.mid,
                                                                                             direction: false)
                                            }
                                        } else {
                                            // If deletion fails, post restoration notification
                                            NotificationCenter.default.post(
                                                name: .tweetRestored,
                                                object: tweet.mid
                                            )
                                        }
                                    },
                                    isPinned: pinnedTweetIds.contains(tweet.mid),
                                    isInProfile: true,
                                    onAvatarTap: { user in onUserSelect(user) }
                                )
                            }
                        )
                    }
                }
                .onPreferenceChange(TweetListScrollOffsetKey.self) { value in
                    onScroll(value)
                }
                .refreshable {
                    await onPinnedTweetsRefresh()
                }
            }
        }
    }
} 
