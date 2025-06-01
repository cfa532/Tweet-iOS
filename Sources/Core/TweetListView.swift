import SwiftUI

@available(iOS 16.0, *)
struct TweetListView<RowView: View>: View {
    // MARK: - Properties
    let title: String
    let tweetFetcher: @Sendable (Int, Int) async throws -> [Tweet?]
    let showTitle: Bool
    let rowView: (Tweet) -> RowView
    
    @EnvironmentObject private var hproseInstance: HproseInstance
    @State private var tweets: [Tweet?] = []
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var hasMoreTweets: Bool = true
    @State private var currentPage: Int = 0
    private let pageSize: Int = 10
    @State private var errorMessage: String? = nil
    @State private var showDeleteResult = false
    @State private var deleteResultMessage = ""
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info
    @State private var initialLoadComplete = false
    @State private var deletedTweetIds = Set<String>()

    // MARK: - Initialization
    init(
        title: String,
        tweetFetcher: @escaping @Sendable (Int, Int) async throws -> [Tweet?],
        showTitle: Bool = true,
        rowView: @escaping (Tweet) -> RowView
    ) {
        self.title = title
        self.tweetFetcher = tweetFetcher
        self.showTitle = showTitle
        self.rowView = rowView
    }

    // MARK: - Body
    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                ScrollView {
                    TweetListContentView(
                        tweets: $tweets,
                        rowView: { tweet in
                            rowView(tweet)
                        },
                        hasMoreTweets: hasMoreTweets,
                        isLoadingMore: isLoadingMore,
                        isLoading: isLoading,
                        initialLoadComplete: initialLoadComplete,
                        loadMoreTweets: { loadMoreTweets() }
                    )
                }
                if showToast {
                    VStack {
                        Spacer()
                        ToastView(message: toastMessage, type: toastType)
                            .padding(.bottom, 40)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut, value: showToast)
                }
            }
            .refreshable {
                await refreshTweets()
            }
            .task {
                if tweets.isEmpty {
                    await refreshTweets()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .userDidLogin)) { _ in
                Task {
                    await refreshTweets()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .newTweetCreated)) { notification in
                if let newTweet = notification.userInfo?["tweet"] as? Tweet {
                    withAnimation {
                        insertTweet(newTweet)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .tweetDeleted)) { notification in
                if let deletedTweetId = notification.object as? String {
                    withAnimation {
                        tweets.removeAll { $0?.mid == deletedTweetId }
                    }
                }
            }
        }
    }

    // MARK: - Methods
    func performInitialLoad() async {
        isLoading = true
        initialLoadComplete = false
        hasMoreTweets = true
        currentPage = 0
        tweets = []
        var page = 0
        var totalValidTweets = 0
        var keepLoading = true
        while keepLoading {
            do {
                let moreTweets = try await tweetFetcher(page, pageSize)
                let validTweets = moreTweets.compactMap { $0 }
                let allNil = moreTweets.allSatisfy { $0 == nil }
                let existingIds = Set(tweets.compactMap { $0?.id })
                let uniqueNew = validTweets.filter { !existingIds.contains($0.id) }
                tweets.append(contentsOf: uniqueNew)
                totalValidTweets = tweets.compactMap { $0 }.count
                currentPage = page
                if totalValidTweets > 4 {
                    hasMoreTweets = moreTweets.count == pageSize && !allNil
                    keepLoading = false
                } else if moreTweets.count < pageSize || allNil {
                    hasMoreTweets = moreTweets.count == pageSize && !allNil
                    keepLoading = false
                } else {
                    page += 1
                }
            } catch {
                print("[TweetListView] Error during initial load: \(error)")
                errorMessage = error.localizedDescription
                break
            }
        }
        isLoading = false
        initialLoadComplete = true
    }

    func refreshTweets() async {
        guard !isLoading else { return }
        initialLoadComplete = false
        await performInitialLoad()
    }

    func loadMoreTweets(page: Int? = nil) {
        print("loadMoreTweets called: isLoadingMore=\(isLoadingMore), initialLoadComplete=\(initialLoadComplete), hasMoreTweets=\(hasMoreTweets), currentPage=\(currentPage)")
        guard hasMoreTweets, !isLoadingMore, initialLoadComplete else { return }
        isLoadingMore = true
        let nextPage = page ?? (currentPage + 1)

        Task {
            do {
                let moreTweets = try await tweetFetcher(nextPage, pageSize)
                await MainActor.run {
                    let validTweets = moreTweets.compactMap { $0 }
                    let allNil = moreTweets.allSatisfy { $0 == nil }
                    let existingIds = Set(tweets.compactMap { $0?.id })
                    let uniqueNew = validTweets.filter { !existingIds.contains($0.id) }

                    if allNil || uniqueNew.isEmpty {
                        if moreTweets.count < pageSize {
                            hasMoreTweets = false
                            isLoadingMore = false
                            currentPage = nextPage
                            return
                        } else {
                            // Auto-retry: load next page
                            isLoadingMore = false
                            currentPage = nextPage
                            loadMoreTweets(page: nextPage + 1)
                            return
                        }
                    }

                    tweets.append(contentsOf: uniqueNew)
                    currentPage = nextPage

                    if moreTweets.count < pageSize {
                        hasMoreTweets = false
                    }
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

    private func showToastWith(message: String, type: ToastView.ToastType) {
        toastMessage = message
        toastType = type
        showToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { showToast = false }
        }
    }

    // MARK: - Optimistic UI Methods
    func insertTweet(_ tweet: Tweet) {
        tweets.insert(tweet, at: 0)
    }
    
    func removeTweet(_ tweet: Tweet) async -> Void {
    }
}

@available(iOS 16.0, *)
struct TweetListContentView<RowView: View>: View {
    @Binding var tweets: [Tweet?]
    let rowView: (Tweet) -> RowView
    let hasMoreTweets: Bool
    let isLoadingMore: Bool
    let isLoading: Bool
    let initialLoadComplete: Bool
    let loadMoreTweets: () -> Void
    var body: some View {
        LazyVStack(spacing: 0) {
            Color.clear.frame(height: 0).id("top")
            ForEach(tweets.indices, id: \ .self) { index in
                if let tweet = tweets[index] {
                    rowView(tweet)
                        .id(tweet.id)
                }
            }
            // Sentinel view for infinite scroll
            if hasMoreTweets {
                ProgressView()
                    .frame(height: 40)
                    .onAppear {
                        if initialLoadComplete && !isLoadingMore {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                if initialLoadComplete && !isLoadingMore {
                                    loadMoreTweets()
                                }
                            }
                        }
                    }
            }
        }
    }
}

