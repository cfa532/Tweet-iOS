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

@available(iOS 16.0, *)
struct TweetDetailView: View {
    @Binding var tweet: Tweet
    @State private var showBrowser = false
    @State private var selectedMediaIndex = 0
    @State private var comments: [Tweet] = []
    @State private var isLoadingComments = false
    @State private var currentPage = 0
    @State private var hasMoreComments = true
    @State private var showLoginSheet = false
    @ObservedObject private var hproseInstance = HproseInstance.shared
    
    let retweet: (Tweet) async -> Void
    let deleteTweet: (Tweet) async -> Void
    
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
                    if let user = tweet.author {
                        Avatar(user: user)
                    }
                    TweetItemHeaderView(tweet: $tweet)
                    TweetMenu(tweet: $tweet, deleteTweet: deleteTweet, isPinned: tweet.isPinned ?? false)
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
                // Tweet actions
                TweetActionButtonsView(tweet: $tweet, retweet: retweet, onGuestAction: handleGuestAction)
                    .padding(.leading, 48)
                    .padding(.trailing, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                // Divider between tweet and comments
                Divider()
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                // Comments
                if comments.isEmpty && !isLoadingComments {
                    Text("No comments yet")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else {
                    ForEach($comments, id: \.id) { $comment in
                        TweetItemView(tweet: $comment, retweet: retweet, deleteTweet: deleteTweet)
                    }
                    if hasMoreComments && isLoadingComments {
                        ProgressView()
                            .padding()
                            .onAppear {
                                loadMoreComments()
                            }
                    }
                }
                CommentsSection(
                    isLoading: isLoadingComments,
                    hasMoreComments: hasMoreComments,
                    onLoadMore: loadMoreComments,
                    onRefresh: refreshComments
                )
            }
            .refreshable {
                await refreshComments()
            }
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
            loadComments()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NewCommentAdded"))) { notification in
            if let tweetId = notification.userInfo?["tweetId"] as? String,
               let updatedTweet = notification.userInfo?["updatedTweet"] as? Tweet,
               let comment = notification.userInfo? ["comment"] as? Tweet,
               tweetId == tweet.mid {
                tweet.commentCount = updatedTweet.commentCount
                if !comments.contains(where: { $0.mid == comment.mid }) {
                    comments.insert(comment, at: 0)
                }
            }
        }
    }
    
    private func loadComments() {
        guard !isLoadingComments else { return }
        isLoadingComments = true
        
        Task {
            do {
                let newComments = try await hproseInstance.fetchComments(
                    tweet: tweet,
                    pageNumber: currentPage,
                    pageSize: 20
                )
                await MainActor.run {
                    if currentPage == 0 {
                        comments = newComments
                    } else {
                        // Only append comments that are not already in the list
                        let existingIds = Set(comments.map { $0.mid })
                        let uniqueNew = newComments.filter { !existingIds.contains($0.mid) }
                        comments.append(contentsOf: uniqueNew)
                    }
                    hasMoreComments = !newComments.isEmpty
                    isLoadingComments = false
                }
            } catch {
                print("Error loading comments: \(error)")
                await MainActor.run {
                    isLoadingComments = false
                }
            }
        }
    }
    
    private func loadMoreComments() {
        guard hasMoreComments, !isLoadingComments else { return }
        currentPage += 1
        loadComments()
    }

    private func refreshComments() async {
        await MainActor.run {
            isLoadingComments = true
            currentPage = 0
        }
        do {
            let newComments = try await hproseInstance.fetchComments(
                tweet: tweet,
                pageNumber: 0,
                pageSize: 20
            )
            await MainActor.run {
                comments = newComments
                hasMoreComments = !newComments.isEmpty
                isLoadingComments = false
            }
        } catch {
            print("Error refreshing comments: \(error)")
            await MainActor.run {
                isLoadingComments = false
            }
        }
    }
}
