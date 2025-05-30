import SwiftUI

@available(iOS 16.0, *)
struct TweetListView: View {
    // MARK: - Properties
    @EnvironmentObject private var hproseInstance: HproseInstance
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
    @State private var showDeleteResult = false
    @State private var deleteResultMessage = ""
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastType = .info
    enum ToastType { case success, error, info }

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
            ZStack {
                ScrollView {
                    TweetListContentView(
                        tweets: $tweets,
                        onRetweet: { tweet in
                            let placeholderId = String(repeating: "0", count: 17)
                            let placeholder = Tweet(
                                mid: placeholderId,
                                authorId: hproseInstance.appUser.mid,
                                content: nil,
                                originalTweetId: tweet.mid,
                                originalAuthorId: tweet.authorId,
                                author: hproseInstance.appUser,
                                favorites: [false, false, true],
                                favoriteCount: tweet.favoriteCount ?? 0,
                                bookmarkCount: tweet.bookmarkCount ?? 0,
                                retweetCount: tweet.retweetCount ?? 0,
                                commentCount: tweet.commentCount ?? 0,
                                attachments: nil
                            )
                            tweets.insert(placeholder, at: 0)
                            showToastWith(message: "Retweeting...", type: .info)
                            let originalIndex = tweets.firstIndex(where: { $0.mid == tweet.mid })
                            let originalRetweetCount = tweet.retweetCount
                            if let idx = originalIndex {
                                tweets[idx].retweetCount = (tweets[idx].retweetCount ?? 0) + 1
                            }
                            Task {
                                var success = false
                                var newRetweet: Tweet? = nil
                                if let onRetweet = onRetweet {
                                    await onRetweet(tweet)
                                    if let retweet = try? await hproseInstance.retweet(tweet) {
                                        newRetweet = retweet
                                        success = true
                                    }
                                }
                                if success, let actualRetweet = newRetweet {
                                    if let idx = tweets.firstIndex(where: { $0.mid == placeholderId }) {
                                        await MainActor.run {
                                            tweets[idx] = actualRetweet
                                        }
                                    }
                                    if let idx = originalIndex {
                                        if let updated = try? await hproseInstance.updateRetweetCount(tweet: tweets[idx], retweetId: actualRetweet.mid, direction: true) {
                                            await MainActor.run {
                                                tweets[idx].retweetCount = updated.retweetCount
                                                tweets[idx].favoriteCount = updated.favoriteCount
                                                tweets[idx].bookmarkCount = updated.bookmarkCount
                                                tweets[idx].commentCount = updated.commentCount
                                            }
                                        }
                                    }
                                    await MainActor.run {
                                        showToastWith(message: "Retweet successful!", type: .success)
                                    }
                                } else {
                                    if let idx = tweets.firstIndex(where: { $0.mid == placeholderId }) {
                                        await MainActor.run {
                                            let _ = tweets.remove(at: idx)
                                        }
                                    }
                                    if let idx = originalIndex {
                                        await MainActor.run {
                                            tweets[idx].retweetCount = originalRetweetCount
                                        }
                                    }
                                    await MainActor.run {
                                        showToastWith(message: "Retweet failed.", type: .error)
                                    }
                                }
                            }
                        },
                        onDeleteTweet: { tweet in
                            let index = tweets.firstIndex(where: { $0.id == tweet.id })
                            var removedTweet: Tweet? = nil
                            var origIdx: Int? = nil
                            var oldRetweetCount: Int? = nil
                            if let index = index {
                                removedTweet = tweets.remove(at: index)
                            }
                            // If this was a retweet, optimistically decrement retweetCount and remember old value
                            if let originalId = tweet.originalTweetId, let idx = tweets.firstIndex(where: { $0.mid == originalId }) {
                                origIdx = idx
                                oldRetweetCount = tweets[idx].retweetCount
                                let current = tweets[idx].retweetCount ?? 1
                                tweets[idx].retweetCount = max(0, current - 1)
                            }
                            Task {
                                var success = false
                                if let onDeleteTweet = onDeleteTweet {
                                    await onDeleteTweet(tweet)
                                    success = !tweets.contains(where: { $0.id == tweet.id })
                                }
                                if success {
                                    // Persist the change if this was a retweet
                                    if let originalId = tweet.originalTweetId, let idx = tweets.firstIndex(where: { $0.mid == originalId }) {
                                        if let updated = try? await hproseInstance.updateRetweetCount(tweet: tweets[idx], retweetId: tweet.mid, direction: false) {
                                            await MainActor.run {
                                                tweets[idx].retweetCount = updated.retweetCount
                                                tweets[idx].favoriteCount = updated.favoriteCount
                                                tweets[idx].bookmarkCount = updated.bookmarkCount
                                                tweets[idx].commentCount = updated.commentCount
                                            }
                                        }
                                    }
                                    await MainActor.run {
                                        showToastWith(message: "Tweet deleted.", type: .success)
                                    }
                                } else {
                                    // Restore tweet and retweetCount if needed
                                    if let removed = removedTweet, let idx = index {
                                        await MainActor.run {
                                            tweets.insert(removed, at: idx)
                                        }
                                    }
                                    if let idx = origIdx, let oldCount = oldRetweetCount {
                                        await MainActor.run {
                                            tweets[idx].retweetCount = oldCount
                                        }
                                    }
                                    await MainActor.run {
                                        showToastWith(message: "Failed to delete tweet.", type: .error)
                                    }
                                }
                            }
                        },
                        onAvatarTap: onAvatarTap
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

    private func showToastWith(message: String, type: ToastType) {
        toastMessage = message
        toastType = type
        showToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { showToast = false }
        }
    }
}

@available(iOS 16.0, *)
struct TweetListContentView: View {
    @Binding var tweets: [Tweet]
    let onRetweet: (Tweet) -> Void
    let onDeleteTweet: (Tweet) -> Void
    let onAvatarTap: ((User) -> Void)?
    var body: some View {
        LazyVStack(spacing: 0) {
            Color.clear.frame(height: 0).id("top")
            ForEach(tweets) { tweet in
                TweetItemView(
                    tweet: tweet,
                    retweet: onRetweet,
                    deleteTweet: onDeleteTweet,
                    isInProfile: false,
                    onAvatarTap: onAvatarTap
                )
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
    let toastType: TweetListView.ToastType
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
    let type: TweetListView.ToastType
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
