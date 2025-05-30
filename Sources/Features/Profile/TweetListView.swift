import SwiftUI

@available(iOS 16.0, *)
struct TweetListView<RowView: View>: View {
    // MARK: - Properties
    @EnvironmentObject private var hproseInstance: HproseInstance
    let title: String
    let tweetFetcher: @Sendable (Int, Int) async throws -> [Tweet]
    let onRetweet: ((Tweet) async -> Void)?
    let onDeleteTweet: ((Tweet) async -> Void)?
    let onAvatarTap: ((User) -> Void)?
    let showTitle: Bool
    let rowView: (Tweet) -> RowView
    
    @State private var tweets: [Tweet] = []
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
    enum ToastType { case success, error, info }

    // MARK: - Initialization
    init(
        title: String,
        tweetFetcher: @escaping @Sendable (Int, Int) async throws -> [Tweet],
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
                        rowView: rowView
                    )
                    LoadingSectionView(hasMoreTweets: hasMoreTweets, isLoading: isLoading, isLoadingMore: isLoadingMore, loadMoreTweets: loadMoreTweets)
                }
                ToastOverlayView(showToast: showToast, toastMessage: toastMessage, toastType: toastType)
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
        tweets.removeAll { $0.mid == tweet.mid }
    }
}

@available(iOS 16.0, *)
struct TweetListContentView<RowView: View>: View {
    @Binding var tweets: [Tweet]
    let rowView: (Tweet) -> RowView
    var body: some View {
        LazyVStack(spacing: 0) {
            Color.clear.frame(height: 0).id("top")
            ForEach(tweets) { tweet in
                rowView(tweet)
                    .id(tweet.id)
            }
        }
    }
}

struct LoadingSectionView: View {
    let hasMoreTweets: Bool
    let isLoading: Bool
    let isLoadingMore: Bool
    let loadMoreTweets: () -> Void
    var body: some View {
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

@available(iOS 16.0, *)
struct ToastOverlayView: View {
    let showToast: Bool
    let toastMessage: String
    let toastType: TweetListView<TweetItemView>.ToastType
    var body: some View {
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
}

@available(iOS 16.0, *)
struct ToastView: View {
    let message: String
    let type: TweetListView<TweetItemView>.ToastType
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .font(.system(size: 20, weight: .bold))
            Text(message)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(backgroundColor)
        .cornerRadius(22)
        .shadow(color: backgroundColor.opacity(0.3), radius: 12, x: 0, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(borderColor, lineWidth: 1.5)
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    private var backgroundColor: Color {
        // Use a gray-blue color for the toast background
        switch type {
        case .success: return Color(red: 0.22, green: 0.32, blue: 0.48, opacity: 0.95) // gray-blue
        case .error: return Color(red: 0.22, green: 0.32, blue: 0.48, opacity: 0.95)
        case .info: return Color(red: 0.22, green: 0.32, blue: 0.48, opacity: 0.95)
        }
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
    private var iconColor: Color {
        switch type {
        case .success: return .white
        case .error: return .white
        case .info: return .white
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
