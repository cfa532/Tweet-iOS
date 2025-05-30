import SwiftUI
import AVKit

@available(iOS 16.0, *)
struct CommentsSection: View {
    let isLoading: Bool
    let hasMoreComments: Bool
    let onLoadMore: () -> Void
    let onRefresh: () async -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
    }
}

@MainActor
@available(iOS 16.0, *)
class CommentsViewModel: ObservableObject {
    @Published var comments: [Tweet] = []
    @Published var isLoading: Bool = false
    @Published var hasMore: Bool = true
    @Published var showToast: Bool = false
    @Published var toastMessage: String = ""
    private var currentPage: Int = 0
    private let pageSize: Int = 20
    private let hproseInstance: HproseInstance
    private let parentTweet: Tweet

    init(hproseInstance: HproseInstance, parentTweet: Tweet) {
        self.hproseInstance = hproseInstance
        self.parentTweet = parentTweet
    }

    func loadInitial() async {
        await MainActor.run { isLoading = true; currentPage = 0 }
        do {
            let newComments = try await hproseInstance.fetchComments(
                tweet: parentTweet,
                pageNumber: 0,
                pageSize: pageSize
            )
            await MainActor.run {
                comments = newComments
                hasMore = newComments.count == pageSize
                isLoading = false
            }
        } catch {
            await MainActor.run {
                isLoading = false
                showToast = true
                toastMessage = "Failed to load comments."
            }
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        await MainActor.run { isLoading = true }
        let nextPage = currentPage + 1
        do {
            let moreComments = try await hproseInstance.fetchComments(
                tweet: parentTweet,
                pageNumber: nextPage,
                pageSize: pageSize
            )
            await MainActor.run {
                let existingIds = Set(comments.map { $0.mid })
                let uniqueNew = moreComments.filter { !existingIds.contains($0.mid) }
                comments.append(contentsOf: uniqueNew)
                hasMore = moreComments.count == pageSize
                currentPage = nextPage
                isLoading = false
            }
        } catch {
            await MainActor.run {
                isLoading = false
                showToast = true
                toastMessage = "Failed to load more comments."
            }
        }
    }

    func addComment(_ comment: Tweet) {
        comments.insert(comment, at: 0)
    }

    func removeComment(_ comment: Tweet) {
        comments.removeAll { $0.mid == comment.mid }
    }

    func postComment(_ comment: Tweet, tweet: Tweet) async {
        addComment(comment)
        do {
            try await hproseInstance.addComment(comment, to: tweet)
        } catch {
            removeComment(comment)
            await MainActor.run {
                showToast = true
                toastMessage = "Failed to post comment."
            }
        }
    }

    func deleteComment(_ comment: Tweet) async {
        let idx = comments.firstIndex(where: { $0.mid == comment.mid })
        removeComment(comment)
        do {
            let result = try await hproseInstance.deleteComment(parentTweet: parentTweet, commentId: comment.mid)
            if let dict = result, let deletedId = dict["commentId"] as? String, let count = dict["count"] as? Int, deletedId == comment.mid {
                parentTweet.commentCount = count
            }
        } catch {
            if let idx = idx {
                comments.insert(comment, at: idx)
            }
            await MainActor.run {
                showToast = true
                toastMessage = "Failed to delete comment."
            }
        }
    }
}

@MainActor
@available(iOS 16.0, *)
struct TweetDetailView: View {
    @ObservedObject var tweet: Tweet
    @State private var showBrowser = false
    @State private var selectedMediaIndex = 0
    @State private var showLoginSheet = false
    @State private var pinnedTweets: [[String: Any]] = []
    @EnvironmentObject private var hproseInstance: HproseInstance
    @StateObject private var commentsVM: CommentsViewModel

    let retweet: (Tweet) async -> Void
    let deleteTweet: (Tweet) async -> Void

    init(tweet: Tweet, retweet: @escaping (Tweet) async -> Void, deleteTweet: @escaping (Tweet) async -> Void) {
        self._commentsVM = StateObject(wrappedValue: CommentsViewModel(hproseInstance: HproseInstance.shared, parentTweet: tweet))
        self.tweet = tweet
        self.retweet = retweet
        self.deleteTweet = deleteTweet
    }

    private func handleGuestAction() {
        if hproseInstance.appUser.isGuest {
            showLoginSheet = true
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Attachments (edge-to-edge, no margin)
                if let attachments = tweet.attachments, let baseUrl = tweet.author?.baseUrl, !attachments.isEmpty {
                    let aspect = CGFloat(attachments.first?.aspectRatio ?? 4.0/3.0)
                    TabView(selection: $selectedMediaIndex) {
                        ForEach(attachments.indices, id: \ .self) { index in
                            MediaCell(
                                attachment: attachments[index],
                                baseUrl: baseUrl,
                                play: index == selectedMediaIndex
                            )
                            .tag(index)
                            .onTapGesture { showBrowser = true }
                        }
                    }
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScreen.main.bounds.width / aspect)
                    .background(Color.black)
                }
                // Tweet header (with avatar and menu)
                HStack(alignment: .top, spacing: 12) {
                    if let user = tweet.author {
                        Avatar(user: user)
                    }
                    TweetItemHeaderView(tweet: tweet)
                    TweetMenu(tweet: tweet, deleteTweet: deleteTweet, isPinned: tweet.isPinned(in: pinnedTweets))
                }
                .padding(.horizontal)
                .padding(.top)
                // Tweet content
                if let content = tweet.content, !content.isEmpty {
                    Text(content)
                        .font(.title3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }
                TweetActionButtonsView(tweet: tweet, retweet: retweet, commentsVM: commentsVM)
                    .padding(.leading, 48)
                    .padding(.trailing, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                Divider()
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                // Comments
                ForEach(commentsVM.comments) { comment in
                    CommentItemView(
                        comment: comment,
                        deleteComment: { c in await commentsVM.deleteComment(c) },
                        retweet: retweet,
                        commentsVM: commentsVM
                    )
                }
                if commentsVM.isLoading {
                    ProgressView().padding()
                } else if commentsVM.hasMore {
                    Button("Load More") {
                        Task { await commentsVM.loadMore() }
                    }
                    .padding()
                }
                if commentsVM.showToast {
                    VStack {
                        Spacer()
                        Text(commentsVM.toastMessage)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                            .background(Color(red: 0.22, green: 0.32, blue: 0.48, opacity: 0.95))
                            .foregroundColor(.white)
                            .cornerRadius(22)
                            .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
                            .padding(.bottom, 40)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .animation(.easeInOut, value: commentsVM.showToast)
                }
            }
            .task { await commentsVM.loadInitial() }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Tweet")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showBrowser) {
            MediaBrowserView(attachments: tweet.attachments ?? [], baseUrl: tweet.author?.baseUrl ?? "", initialIndex: selectedMediaIndex)
        }
        .sheet(isPresented: $showLoginSheet) {
            LoginView()
        }
        .onAppear {
            loadPinnedTweets()
        }
    }

    private func loadPinnedTweets() {
        Task {
            if let author = tweet.author {
                pinnedTweets = (try? await hproseInstance.getPinnedTweets(user: author)) ?? []
            }
        }
    }
}

