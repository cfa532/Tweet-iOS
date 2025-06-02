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
