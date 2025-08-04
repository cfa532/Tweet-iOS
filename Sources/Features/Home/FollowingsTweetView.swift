import SwiftUI

@available(iOS 16.0, *)
struct FollowingsTweetView: View {
    @Binding var isLoading: Bool
    let onAvatarTap: (User) -> Void
    @Binding var selectedTweet: Tweet?
    let onScroll: ((CGFloat) -> Void)?
    @EnvironmentObject private var hproseInstance: HproseInstance
    @StateObject private var viewModel: FollowingsTweetViewModel

    init(isLoading: Binding<Bool>, onAvatarTap: @escaping (User) -> Void, selectedTweet: Binding<Tweet?>, onScroll: ((CGFloat) -> Void)? = nil) {
        self._isLoading = isLoading
        self.onAvatarTap = onAvatarTap
        self._selectedTweet = selectedTweet
        self.onScroll = onScroll
        self._viewModel = StateObject(wrappedValue: FollowingsTweetViewModel(hproseInstance: HproseInstance.shared))
    }

    var body: some View {
        ScrollViewReader { proxy in
            TweetListView<TweetItemView>(
                title: "Timeline",
                tweets: $viewModel.tweets,
                tweetFetcher: { page, size, isFromCache in
                    if isFromCache {
                        // Fetch from cache - don't merge here, let TweetListView handle it
                        let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
                            for: hproseInstance.appUser.mid, page: page, pageSize: size, currentUserId: hproseInstance.appUser.mid)
                        // Filter out private tweets from cache for following view
                        let filteredCachedTweets = cachedTweets.compactMap { $0 }.filter { !($0.isPrivate ?? false) }
                        return filteredCachedTweets.map { Optional($0) }
                    } else {
                        // Fetch from server
                        return await viewModel.fetchTweets(page: page, pageSize: size)
                    }
                },
                showTitle: false,
                notifications: [
                    TweetListNotification(
                        name: .newTweetCreated,
                        key: "tweet",
                        shouldAccept: { _ in true },
                        action: { tweet in viewModel.handleNewTweet(tweet) }
                    ),
                    TweetListNotification(
                        name: .tweetDeleted,
                        key: "tweetId",
                        shouldAccept: { _ in true },
                        action: { tweet in viewModel.handleDeletedTweet(tweet.mid) }
                    )
                ],
                onScroll: onScroll,
                rowView: { tweet in
                    TweetItemView(
                        tweet: tweet,
                        isPinned: false,
                        isInProfile: false,
                        onAvatarTap: { user in
                            onAvatarTap(user)
                        },
                        onTap: { tweet in
                            selectedTweet = tweet
                        },
                        onRemove: { tweetId in
                            if let idx = viewModel.tweets.firstIndex(where: { $0.id == tweetId }) {
                                viewModel.tweets.remove(at: idx)
                            }
                        }
                    )
                }
            )
            .onDisappear {
                // Pause all videos when FollowingsTweetView disappears
                print("DEBUG: [FollowingsTweetView] View disappeared, pausing all videos")
                pauseAllVideos()
            }
        }
    }
    
    /// Pause all videos in the tweets list
    private func pauseAllVideos() {
        print("DEBUG: [FollowingsTweetView] Pausing all videos in tweets list")
        
        // Pause all videos in tweets
        for tweet in viewModel.tweets {
            if let attachments = tweet.attachments {
                for attachment in attachments {
                    if attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video" {
                        let mid = attachment.mid
                        print("DEBUG: [FollowingsTweetView] Pausing video with mid: \(mid)")
                        VideoCacheManager.shared.pauseVideoPlayer(for: mid)
                    }
                }
            }
        }
    }
}
