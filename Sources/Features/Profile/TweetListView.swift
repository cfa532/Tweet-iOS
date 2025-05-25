import SwiftUI

@available(iOS 16.0, *)
struct TweetListView: View {
    let user: User
    let type: UserContentType
    @State private var tweets: [Tweet] = []
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var hasMoreTweets: Bool = true
    @State private var currentPage: Int = 0
    private let pageSize: Int = 20
    @State private var error: String? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("top")
                    ForEach($tweets) { $tweet in
                        TweetItemView(
                            tweet: $tweet,
                            retweet: { _ in },
                            deleteTweet: { _ in },
                            isInProfile: false
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
        }
        .navigationTitle(type == .BOOKMARKS ? "Bookmarks" : "Favorites")
    }

    func refreshTweets() async {
        isLoading = true
        currentPage = 0
        hasMoreTweets = true
        do {
            let newTweets = try await HproseInstance.shared.getUserTweetsByType(
                user: user, type: type
            )
            await MainActor.run {
                tweets = Array(newTweets.prefix(pageSize))
                hasMoreTweets = newTweets.count > pageSize
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
                let allTweets = try await HproseInstance.shared.getUserTweetsByType(
                    user: user, type: type
                )
                await MainActor.run {
                    let start = nextPage * pageSize
                    let end = min(start + pageSize, allTweets.count)
                    if start < end {
                        let moreTweets = Array(allTweets[start..<end])
                        // Prevent duplicates
                        let existingIds = Set(tweets.map { $0.id })
                        let uniqueNew = moreTweets.filter { !existingIds.contains($0.id) }
                        tweets.append(contentsOf: uniqueNew)
                        hasMoreTweets = end < allTweets.count
                        currentPage = nextPage
                    } else {
                        hasMoreTweets = false
                    }
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
} 
