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
                        print("[ProfileTweetsSection] tweetFetcher called: page=\(page), size=\(size)")
                        if page == 0 {
                            let regularTweets = try await hproseInstance.fetchUserTweet(
                                user: user,
                                startRank: 0,
                                endRank: UInt(size - 1)
                            )
                            let filteredRegular = regularTweets.filter { !pinnedTweetIds.contains($0.mid) }
                            let combined = pinnedTweets + filteredRegular
                            let result = Array(combined.prefix(size))
                            print("[ProfileTweetsSection] Returning page 0: pinned=\(pinnedTweets.count), filteredRegular=\(filteredRegular.count), total=\(result.count)")
                            return result
                        } else {
                            let start = UInt(page * size)
                            let end = UInt((page + 1) * size - 1)
                            let regularTweets = try await hproseInstance.fetchUserTweet(
                                user: user,
                                startRank: start,
                                endRank: end
                            )
                            let filtered = regularTweets.filter { !pinnedTweetIds.contains($0.mid) }
                            print("[ProfileTweetsSection] Returning page \(page): filtered=\(filtered.count)")
                            return filtered
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
                                        try? await hproseInstance.updateRetweetCount(tweet: tweet, retweetId: retweet.mid)
                                    }
                                } catch {
                                    print("Retweet failed in ProfileTweetsSection")
                                }
                            },
                            deleteTweet: { tweet in
                                NotificationCenter.default.post(
                                    name: .tweetDeleted,
                                    object: tweet.mid
                                )
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
                                        let currentCount = originalTweet.retweetCount ?? 0
                                        originalTweet.retweetCount = max(0, currentCount - 1)
                                        try? await hproseInstance.updateRetweetCount(tweet: originalTweet,
                                                                                     retweetId: tweet.mid,
                                                                                     direction: false)
                                    }
                                } else {
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
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            .refreshable {
                await onPinnedTweetsRefresh()
            }
        }
    }
} 
