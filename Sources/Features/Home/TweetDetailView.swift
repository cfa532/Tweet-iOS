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
struct TweetDetailView: View {
    @ObservedObject var tweet: Tweet
    @State private var showBrowser = false
    @State private var selectedMediaIndex = 0
    @State private var showLoginSheet = false
    @State private var pinnedTweets: [[String: Any]] = []
    @EnvironmentObject private var hproseInstance: HproseInstance
    @StateObject private var commentsVM: CommentsViewModel
    @State private var originalTweet: Tweet?

    let retweet: (Tweet) async -> Void
    let deleteTweet: (Tweet) async -> Void

    init(tweet: Tweet, retweet: @escaping (Tweet) async -> Void, deleteTweet: @escaping (Tweet) async -> Void) {
        self._commentsVM = StateObject(wrappedValue: CommentsViewModel(hproseInstance: HproseInstance.shared, parentTweet: tweet))
        self.tweet = tweet
        self.retweet = retweet
        self.deleteTweet = deleteTweet
    }

    // Computed property to determine which tweet to display
    private var displayTweet: Tweet {
        let currentTweet = tweet
        if (currentTweet.content == nil || currentTweet.content?.isEmpty == true) && (currentTweet.attachments == nil || currentTweet.attachments?.isEmpty == true) {
            return originalTweet ?? currentTweet
        }
        return currentTweet
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
                if let attachments = displayTweet.attachments, let baseUrl = displayTweet.author?.baseUrl, !attachments.isEmpty {
                    let aspect = CGFloat(attachments.first?.aspectRatio ?? 4.0/3.0)
                    TabView(selection: $selectedMediaIndex) {
                        ForEach(attachments.indices, id: \.self) { index in
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
                    if let user = displayTweet.author {
                        Avatar(user: user)
                    }
                    TweetItemHeaderView(tweet: displayTweet)
                    TweetMenu(tweet: displayTweet, deleteTweet: deleteTweet, isPinned: displayTweet.isPinned(in: pinnedTweets))
                }
                .padding(.horizontal)
                .padding(.top)
                // Tweet content
                if let content = displayTweet.content, !content.isEmpty {
                    Text(content)
                        .font(.title3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }
                TweetActionButtonsView(tweet: displayTweet, retweet: retweet, commentsVM: commentsVM)
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
            .task {
                if let originalTweetId = tweet.originalTweetId, let originalAuthorId = tweet.originalAuthorId {
                    if let originalTweet = try? await hproseInstance.getTweet(tweetId: originalTweetId, authorId: originalAuthorId) {
                        self.originalTweet = originalTweet
                        commentsVM.parentTweet = originalTweet
                        await commentsVM.loadInitial()
                    }
                }
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Tweet")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showBrowser) {
            MediaBrowserView(attachments: displayTweet.attachments ?? [], baseUrl: displayTweet.author?.baseUrl ?? "", initialIndex: selectedMediaIndex)
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
            if let author = displayTweet.author {
                pinnedTweets = (try? await hproseInstance.getPinnedTweets(user: author)) ?? []
            }
        }
    }
}

