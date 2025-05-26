import SwiftUI

@available(iOS 16.0, *)
struct TweetListView: View {
    // MARK: - Properties
    let title: String
    let tweetFetcher: @Sendable (Int, Int) async throws -> [Tweet]
    let onRetweet: ((Tweet) async -> Void)?
    let onDeleteTweet: ((Tweet) async -> Void)?
    let onAvatarTap: ((User) -> Void)?
    let showTitle: Bool
    
    @State private var tweets: [Tweet] = []
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var hasMoreTweets: Bool = true
    @State private var currentPage: Int = 0
    private let pageSize: Int = 10
    @State private var errorMessage: String? = nil

    // MARK: - Initialization
    init(
        title: String,
        tweetFetcher: @escaping @Sendable (Int, Int) async throws -> [Tweet],
        onRetweet: ((Tweet) async -> Void)? = nil,
        onDeleteTweet: ((Tweet) async -> Void)? = nil,
        onAvatarTap: ((User) -> Void)? = nil,
        showTitle: Bool = true
    ) {
        self.title = title
        self.tweetFetcher = tweetFetcher
        self.onRetweet = onRetweet
        self.onDeleteTweet = onDeleteTweet
        self.onAvatarTap = onAvatarTap
        self.showTitle = showTitle
    }

    // MARK: - Body
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("top")
                    ForEach($tweets) { $tweet in
                        TweetItemView(
                            tweet: $tweet,
                            retweet: { tweet in
                                if let onRetweet = onRetweet {
                                    Task {
                                        await onRetweet(tweet)
                                    }
                                }
                            },
                            deleteTweet: { tweet in
                                if let onDeleteTweet = onDeleteTweet {
                                    Task {
                                        await onDeleteTweet(tweet)
                                    }
                                }
                            },
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
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("UserDidLogin"))) { _ in
                Task {
                    await refreshTweets()
                }
            }
        }
    }

    // MARK: - Methods
    func refreshTweets() async {
        isLoading = true
        currentPage = 0
        hasMoreTweets = true
        do {
            let newTweets = try await tweetFetcher(0, pageSize)
            await MainActor.run {
                tweets = newTweets
                hasMoreTweets = newTweets.count == pageSize
                isLoading = false
            }
        } catch {
            print("Error refreshing tweets: \(error)")
            await MainActor.run {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadMoreTweets() {
        guard hasMoreTweets, !isLoadingMore else { return }
        isLoadingMore = true
        let nextPage = currentPage + 1

        Task {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay for spinner visibility
                let moreTweets = try await tweetFetcher(nextPage, pageSize)

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
                print("[TweetListView] Error loading more tweets: \(error)")
                await MainActor.run {
                    isLoadingMore = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
} 
