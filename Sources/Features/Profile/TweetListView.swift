import SwiftUI

@available(iOS 16.0, *)
struct TweetListView<RowView: View>: View {
    // MARK: - Properties
    @EnvironmentObject private var hproseInstance: HproseInstance
    let title: String
    let tweetFetcher: @Sendable (Int, Int) async throws -> [Tweet?]
    let onRetweet: ((Tweet) async -> Void)?
    let onDeleteTweet: ((Tweet) async -> Void)?
    let onAvatarTap: ((User) -> Void)?
    let showTitle: Bool
    let rowView: (Tweet) -> RowView
    
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
    @State private var toastType: TweetListView<TweetItemView>.ToastType = .info
    @State private var initialLoadComplete = false
    enum ToastType { case success, error, info }

    // MARK: - Initialization
    init(
        title: String,
        tweetFetcher: @escaping @Sendable (Int, Int) async throws -> [Tweet?],
        onRetweet: ((Tweet) async -> Void)? = nil,
        onDeleteTweet: ((Tweet) async -> Void)? = nil,
        onAvatarTap: ((User) -> Void)? = nil,
        showTitle: Bool = true,
        rowView: @escaping (Tweet) -> RowView
    ) {
        self.title = title
        self.tweetFetcher = tweetFetcher
        self.onRetweet = onRetweet
        self.onDeleteTweet = onDeleteTweet
        self.onAvatarTap = onAvatarTap
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
                        rowView: rowView,
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
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("UserDidLogin"))) { _ in
                Task {
                    await refreshTweets()
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

    private func showToastWith(message: String, type: TweetListView<TweetItemView>.ToastType) {
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
    func removeTweet(_ tweet: Tweet) {
        tweets.removeAll { $0?.mid == tweet.mid }
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

@available(iOS 16.0, *)
struct ToastView: View {
    let message: String
    let type: TweetListView<TweetItemView>.ToastType
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundColor(.white)
                .font(.system(size: 20, weight: .bold))
            Text(message)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color(red: 0.22, green: 0.32, blue: 0.48, opacity: 0.95))
        .cornerRadius(22)
        .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(borderColor, lineWidth: 1.5)
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    private var borderColor: Color {
        switch type {
        case .success: return Color.green.opacity(0.7)
        case .error: return Color.red.opacity(0.7)
        case .info: return Color.blue.opacity(0.7)
        }
    }
    private var iconName: String {
        switch type {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "arrow.2.squarepath"
        }
    }
}

#if DEBUG
@available(iOS 16.0, *)
struct TweetListView_Previews: PreviewProvider {
    static var previews: some View {
        TweetListView<TweetItemView>(
            title: "Preview",
            tweetFetcher: { _, _ in [] },
            rowView: { tweet in
                TweetItemView(
                    tweet: tweet,
                    retweet: { _ in },
                    deleteTweet: { _ in }
                )
            }
        )
    }
}
#endif

