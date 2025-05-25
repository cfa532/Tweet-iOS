import SwiftUI

@available(iOS 16.0, *)
struct FollowingsTweetView: View {
    @State private var tweets: [Tweet] = []
    @Binding var isLoading: Bool
    let onAvatarTap: (User) -> Void
    @Binding var resetTrigger: Bool
    @Binding var scrollToTopTrigger: Bool

    @State private var currentPage: Int = 0
    @State private var hasMoreTweets: Bool = true
    @State private var isLoadingMore: Bool = false
    private let pageSize: Int = 20

    @EnvironmentObject private var hproseInstance: HproseInstance

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("top")
                    ForEach($tweets) { $tweet in
                        TweetItemView(
                            tweet: $tweet,
                            retweet: { tweet in
                                await retweet(tweet)
                            },
                            deleteTweet: deleteTweet,
                            isInProfile: false,
                            onAvatarTap: onAvatarTap
                        )
                        .id(tweet.id)
                    }
                    if hasMoreTweets {
                        ProgressView()
                            .padding()
                            .onAppear {
                                if !isLoadingMore {
                                    loadMoreTweets()
                                }
                            }
                    } else if isLoading || isLoadingMore {
                        ProgressView()
                            .padding()
                    }
                }
            }
            .refreshable {
                await refreshTweets()
            }
            .onAppear {
                if tweets.isEmpty {
                    Task {
                        await refreshTweets()
                    }
                }
            }
            .onChange(of: resetTrigger) { _ in
                Task {
                    tweets = []
                    await refreshTweets()
                }
            }
            .onChange(of: scrollToTopTrigger) { _ in
                withAnimation {
                    proxy.scrollTo("top", anchor: .top)
                }
                Task {
                    await refreshTweets()
                }
            }
        }
    }
    
    func refreshTweets() async {
        isLoading = true
        currentPage = 0
        hasMoreTweets = true
        do {
            let newTweets = try await hproseInstance.fetchTweetFeed(
                user: hproseInstance.appUser, startRank: 0, endRank: UInt(pageSize)
            )
            await MainActor.run {
                tweets = newTweets
                hasMoreTweets = newTweets.count == pageSize
                isLoading = false
            }
        } catch {
            print("Error refreshing tweets: \(error)")
            await MainActor.run {
                isLoading = false
            }
        }
    }

    func loadMoreTweets() {
        guard hasMoreTweets, !isLoadingMore else { return }
        isLoadingMore = true
        let nextPage = currentPage + 1
        Task {
            do {
                let startRank = UInt(nextPage * pageSize)
                let endRank = UInt(startRank + UInt(pageSize))
                let moreTweets = try await hproseInstance.fetchTweetFeed(
                    user: hproseInstance.appUser, startRank: startRank, endRank: endRank
                )
                await MainActor.run {
                    // Prevent duplicates
                    let existingIds = Set(tweets.map { $0.id })
                    let uniqueNew = moreTweets.filter { !existingIds.contains($0.id) }
                    tweets.append(contentsOf: uniqueNew)
                    hasMoreTweets = moreTweets.count == pageSize
                    currentPage = nextPage
                    isLoadingMore = false
                }
            } catch {
                print("Error loading more tweets: \(error)")
                await MainActor.run {
                    isLoadingMore = false
                }
            }
        }
    }
    
    func retweet(_ tweet: Tweet) async {
        do {
            if let retweet = try await hproseInstance.retweet(tweet) {
                // Insert retweet at the beginning of the array
                tweets.insert(retweet, at: 0)
                
                // update retweet count of the original tweet
                if let updatedOriginalTweet = try await hproseInstance.updateRetweetCount(tweet: tweet, retweetId: retweet.mid) {
                    if let index = tweets.firstIndex(where: { $0.id == updatedOriginalTweet.mid }) {
                        tweets[index] = updatedOriginalTweet
                    }
                } else {
                    print("Update of the original tweet failed. \(tweet) \(retweet)")
                }
            } else {
                print("Retweet failed. \(tweet)")
            }
        } catch {
            print("Error retweeting: \(error) \(tweet)")
        }
    }

    func deleteTweet(_ tweet: Tweet) async {
        // Remove from UI immediately
        tweets.removeAll { $0.id == tweet.mid }
        
        // Handle deletion in background
        Task.detached {
            do {
                if let tweetId = try await hproseInstance.deleteTweet(tweet.mid) {
                    print("Successfully deleted tweet: \(tweetId)")
                } else {
                    print("Error deleting tweet: \(tweet)")
                    // Optionally, you could add the tweet back to the UI here if deletion failed
                    await MainActor.run {
                        tweets.append(tweet)
                    }
                }
            } catch {
                print("Error deleting tweet: \(error)")
                // Optionally, you could add the tweet back to the UI here if deletion failed
                await MainActor.run {
                    tweets.append(tweet)
                }
            }
        }
    }
}
