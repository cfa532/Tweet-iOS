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
    @State private var refreshTimer: Timer?
    @State private var comments: [Tweet] = []
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info
    @State private var isVisible = true
    
    @EnvironmentObject private var hproseInstance: HproseInstance
    @Environment(\.dismiss) private var dismiss

    init(tweet: Tweet) {
        self.tweet = tweet
    }

    private var displayTweet: Tweet {
        if (tweet.content == nil || tweet.content?.isEmpty == true) && 
           (tweet.attachments == nil || tweet.attachments?.isEmpty == true) {
            return originalTweet ?? tweet
        }
        return tweet
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                mediaSection
                tweetHeader
                tweetContent
                actionButtons
                Divider()
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                commentsListView
            }
            .task {
                setupInitialData()
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Tweet")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showBrowser) {
            MediaBrowserView(
                attachments: displayTweet.attachments ?? [],
                initialIndex: selectedMediaIndex
            )
        }
        .sheet(isPresented: $showLoginSheet) {
            LoginView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tweetDeleted)) { notification in
            if let deletedTweetId = notification.userInfo?["tweetId"] as? String ?? notification.object as? String,
               deletedTweetId == displayTweet.mid {
                dismiss()
            }
        }
        .overlay(toastOverlay)
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
            isVisible = false
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedUser != nil },
            set: { if !$0 { selectedUser = nil } }
        )) {
            if let selectedUser = selectedUser {
                ProfileView(user: selectedUser, onLogout: nil)
            }
        }
    }
    
    private var mediaSection: some View {
        Group {
            if let attachments = displayTweet.attachments,
               !attachments.isEmpty {
                let aspect = CGFloat(attachments.first?.aspectRatio ?? 4.0/3.0)
                TabView(selection: $selectedMediaIndex) {
                    ForEach(attachments.indices, id: \.self) { index in
                        MediaCell(
                            parentTweet: displayTweet,
                            attachmentIndex: index
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
        }
    }
    
    private var tweetHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            if let user = displayTweet.author {
                Avatar(user: user)
                    .onTapGesture { selectedUser = user }
            }
            TweetItemHeaderView(tweet: displayTweet)
            TweetMenu(tweet: displayTweet, isPinned: displayTweet.isPinned(in: pinnedTweets))
        }
        .padding(.horizontal)
        .padding(.top)
    }
    
    private var tweetContent: some View {
        Group {
            if let content = displayTweet.content, !content.isEmpty {
                Text(content)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        }
    }
    
    private var actionButtons: some View {
        TweetActionButtonsView(tweet: displayTweet)
            .padding(.leading, 48)
            .padding(.trailing, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
    
    private var toastOverlay: some View {
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
    }
    
    private var commentsListView: some View {
        CommentListView<CommentItemView>(
            title: "Comments",
            comments: $comments,
            commentFetcher: { page, size in
                try await hproseInstance.fetchComments(
                    displayTweet,
                    pageNumber: page,
                    pageSize: size
                )
            },
            showTitle: false,
            notifications: [
                CommentListNotification(
                    name: .newCommentAdded,
                    key: "comment",
                    shouldAccept: { _ in true },
                    action: { comment in comments.insert(comment, at: 0) }
                ),
                CommentListNotification(
                    name: .commentDeleted,
                    key: "comment",
                    shouldAccept: { _ in true },
                    action: { comment in comments.removeAll { $0.mid == comment.mid } }
                )
            ],
            rowView: { comment in
                CommentItemView(
                    parentTweet: tweet,
                    comment: comment,
                    onAvatarTap: { user in selectedUser = user }
                )
            }
        )
    }

    private func setupInitialData() {
        if let originalTweetId = tweet.originalTweetId,
           let originalAuthorId = tweet.originalAuthorId {
            Task {
                if let originalTweet = try? await hproseInstance.getTweet(
                    tweetId: originalTweetId,
                    authorId: originalAuthorId
                ) {
                    self.originalTweet = originalTweet
                }
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            refreshTweet()
        }
        
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                refreshTweet()
            }
        }
    }

    private func refreshTweet() {
        Task {
            do {
                if let refreshedTweet = try await hproseInstance.refreshTweet(
                    tweetId: tweet.mid,
                    authorId: tweet.authorId
                ) {
                    try await MainActor.run {
                        try tweet.update(from: refreshedTweet)
                    }
                }
            } catch {
                print("Error refreshing tweet: \(error)")
            }
        }
    }

    private func showToast(message: String, type: ToastView.ToastType) {
        toastMessage = message
        toastType = type
        withAnimation {
            showToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showToast = false
            }
        }
    }
}

