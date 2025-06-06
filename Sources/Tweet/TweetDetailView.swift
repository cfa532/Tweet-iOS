import SwiftUI
import AVKit

@MainActor
@available(iOS 16.0, *)
struct TweetDetailView: View {
    @ObservedObject var tweet: Tweet
    @State private var showBrowser = false
    @State private var selectedMediaIndex = 0
    @State private var showLoginSheet = false
    @State private var pinnedTweets: [[String: Any]] = []
    @State private var originalTweet: Tweet?
    @State private var selectedUser: User? = nil
    @EnvironmentObject private var hproseInstance: HproseInstance
    @Environment(\.dismiss) private var dismiss
    @State private var comments: [Tweet] = []
    
    // Toast states
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info
    
    init(tweet: Tweet) {
        self.tweet = tweet
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
                    TweetMenu(tweet: displayTweet, isPinned: displayTweet.isPinned(in: pinnedTweets))
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
                TweetActionButtonsView(tweet: displayTweet)
                    .padding(.leading, 48)
                    .padding(.trailing, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                Divider()
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                
                // Comments section using CommentListView
                commentsListView
            }
            .task {
                if let originalTweetId = tweet.originalTweetId, let originalAuthorId = tweet.originalAuthorId {
                    if let originalTweet = try? await hproseInstance.getTweet(tweetId: originalTweetId, authorId: originalAuthorId) {
                        self.originalTweet = originalTweet
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
        .onReceive(NotificationCenter.default.publisher(for: .tweetDeleted)) { notification in
            if let deletedTweetId = notification.userInfo?["tweetId"] as? String ?? notification.object as? String {
                if deletedTweetId == displayTweet.mid {
                    dismiss()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newCommentAdded)) { notification in
            if let comment = notification.userInfo?["comment"] as? Tweet,
               comment.originalTweetId == displayTweet.mid {
                showToast(message: "Comment posted successfully", type: .success)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .commentDeleted)) { notification in
            if let commentId = notification.userInfo?["commentId"] as? String {
                showToast(message: "Comment deleted successfully. \(commentId)", type: .success)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .backgroundUploadFailed)) { notification in
            if let error = notification.userInfo?["error"] as? Error {
                showToast(message: "Failed to post comment: \(error.localizedDescription)", type: .error)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .commentUploadStarted)) { notification in
            if let message = notification.userInfo?["message"] as? String {
                showToast(message: message, type: .info)
            }
        }
        .overlay(
            Group {
                if showToast {
                    VStack {
                        Spacer()
                        ToastView(message: toastMessage, type: toastType)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .padding(.bottom, 32)
                }
            }
        )
        // Navigation to another user's profile when an avatar is tapped
        profileNavigationLink
    }

    private var commentsListView: some View {
        CommentListView<CommentItemView>(
            title: "Comments",
            comments: $comments,
            commentFetcher: { page, size in
                try await hproseInstance.fetchComments(
                    tweet: displayTweet,
                    pageNumber: page,
                    pageSize: size
                )
            },
            showTitle: false,
            notifications: [
                CommentListNotification(
                    name: .newCommentAdded,
                    key: "comment",
                    shouldAccept: { comment in comment.originalTweetId == displayTweet.mid },
                    action: { comment in comments.insert(comment, at: 0) }
                ),
                CommentListNotification(
                    name: .commentDeleted,
                    key: "commentId",
                    shouldAccept: { _ in true },
                    action: { comment in comments.removeAll { $0.mid == comment.mid } }
                )
            ],
            rowView: { comment in
                CommentItemView(comment: comment, onAvatarTap: { user in selectedUser = user })
            }
        )
    }

    @ViewBuilder
    private var profileNavigationLink: some View {
        let profileDestination = selectedUser.map { ProfileView(user: $0, onLogout: nil) }
        let isActiveBinding = Binding(
            get: { selectedUser != nil },
            set: { isActive in if !isActive { selectedUser = nil } }
        )
        NavigationLink(
            destination: profileDestination,
            isActive: isActiveBinding
        ) {
            EmptyView()
        }
        .hidden()
    }

    private func showToast(message: String, type: ToastView.ToastType) {
        toastMessage = message
        toastType = type
        withAnimation {
            showToast = true
        }
        // Hide toast after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showToast = false
            }
        }
    }
}

