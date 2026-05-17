//
//  CommentDetailView.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/6/8.
//

import SwiftUI
import AVKit

// Navigation wrapper to pass both comment and parent tweet
struct CommentNavigation: Hashable {
    let comment: Tweet
    let parentTweet: Tweet
    
    static func == (lhs: CommentNavigation, rhs: CommentNavigation) -> Bool {
        lhs.comment.mid == rhs.comment.mid && lhs.parentTweet.mid == rhs.parentTweet.mid
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(comment.mid)
        hasher.combine(parentTweet.mid)
    }
}

@MainActor
@available(iOS 16.0, *)
struct CommentDetailViewWithParent: View {
    @ObservedObject var comment: Tweet
    @State private var parentTweet: Tweet?
    @State private var isLoading = true
    @EnvironmentObject private var hproseInstance: HproseInstance
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Group {
            if let parentTweet = parentTweet {
                CommentDetailView(comment: comment, parentTweet: parentTweet)
            } else if isLoading {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("Could not load parent tweet")
                        .font(.headline)
                    Button("Go Back") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
            }
        }
        .task {
            await fetchParentTweet()
        }
    }
    
    private func fetchParentTweet() async {
        guard let originalTweetId = comment.originalTweetId,
              let originalAuthorId = comment.originalAuthorId else {
            isLoading = false
            return
        }
        
        do {
            let parent = try await hproseInstance.refreshTweet(tweetId: originalTweetId, authorId: originalAuthorId)
            await MainActor.run {
                self.parentTweet = parent
                self.isLoading = false
            }
        } catch {
            print("Failed to fetch parent tweet: \(error)")
            await MainActor.run {
                self.isLoading = false
            }
        }
    }
}

@MainActor
@available(iOS 16.0, *)
struct CommentDetailView: View {
    @ObservedObject var comment: Tweet
    @ObservedObject var parentTweet: Tweet
    @State private var showBrowser = false
    @State private var selectedMediaIndex = 0
    @State private var showLoginSheet = false
    @State private var replies: [Tweet] = []
    
    // Reply editor states
    @State private var showReplyEditor = true
    @State private var shouldShowExpandedReply = false
    
    // Toast states
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info
    
    @EnvironmentObject private var hproseInstance: HproseInstance
    @Environment(\.dismiss) private var dismiss
    
    init(comment: Tweet, parentTweet: Tweet) {
        self.comment = comment
        self.parentTweet = parentTweet
    }
    
    private func handleGuestAction() {
        if hproseInstance.appUser.isGuest {
            showLoginSheet = true
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Main comment section with deeper background
                    VStack(alignment: .leading, spacing: 0) {
                        mediaSection
                        commentHeader
                        commentContent
                        actionButtons
                    }
                    .padding(.bottom, 8)
                    .background(Color(UIColor.secondarySystemBackground))
                    
                    repliesListView
                }
            }
            .background(Color(.systemBackground))
            
            // ReplyEditor as a component at the bottom
            if showReplyEditor {
                ReplyEditorView(
                    parentTweet: comment,
                    isQuoting: false,
                    onClose: {
                        showReplyEditor = false
                    },
                    onExpandedClose: {
                        shouldShowExpandedReply = false
                    },
                    initialExpanded: shouldShowExpandedReply
                )
                .padding(.bottom, 48) // Add padding to avoid navigation bar
            }
        }
        .navigationTitle(NSLocalizedString("Reply", comment: "Reply screen title"))
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showBrowser) {
            MediaBrowserView(tweet: comment, initialIndex: selectedMediaIndex)
        }
        .sheet(isPresented: $showLoginSheet) {
            LoginView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .commentDeleted)) { notification in
            if let deletedComment = notification.userInfo?["comment"] as? Tweet,
               deletedComment.mid == comment.mid {
                dismiss()
            }
        }
        .overlay(toastOverlay)
        .onAppear {
            // Mark detail view as active to prevent MediaCell autoplay
            NavigationStateManager.shared.setDetailViewActive(true)
            
            // Activate detail video manager
            DetailVideoManager.shared.activateForDetail()
        }
        .onDisappear {
            // Mark detail view as inactive
            NavigationStateManager.shared.setDetailViewActive(false)
            
            // Deactivate detail video manager
            DetailVideoManager.shared.deactivate()
        }
        .task {
            // Refresh comment after a short delay
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            await refreshComment()
        }

    }
    
    private var mediaSection: some View {
        Group {
            if let attachments = comment.attachments, !attachments.isEmpty {
                let aspect = CGFloat(attachments.first?.aspectRatio ?? 4.0/3.0)
                let _ = print("DEBUG: [CommentDetailView] Showing \(attachments.count) attachments from comment \(comment.mid)")
                let _ = print("DEBUG: [CommentDetailView]   comment.author = \(comment.author?.username ?? "nil")")
                let _ = print("DEBUG: [CommentDetailView]   comment.author.baseUrl = \(comment.author?.baseUrl?.absoluteString ?? "nil")")
                let _ = attachments.enumerated().forEach { index, att in
                    print("DEBUG: [CommentDetailView]   [\(index)] type=\(att.type), mid=\(att.mid)")
                }
                TabView(selection: $selectedMediaIndex) {
                    ForEach(attachments.indices, id: \.self) { index in
                        DetailMediaCell(
                            parentTweet: comment,
                            attachmentIndex: index,
                            aspectRatio: attachments[index].aspectRatio ?? 16.0/9.0,
                            shouldLoadVideo: index == selectedMediaIndex, // Only load current video
                            showMuteButton: false
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
                .frame(maxWidth: .infinity)
                .frame(height: UIScreen.main.bounds.width / aspect)
                .background(Color.black)
            } else {
                let _ = print("DEBUG: [CommentDetailView] No attachments found for comment \(comment.mid)")
                let _ = print("DEBUG: [CommentDetailView]   comment.attachments = \(comment.attachments?.description ?? "nil")")
                let _ = print("DEBUG: [CommentDetailView]   comment.author = \(comment.author?.username ?? "nil")")
                let _ = print("DEBUG: [CommentDetailView]   parentTweet.mid = \(parentTweet.mid)")
                let _ = print("DEBUG: [CommentDetailView]   parentTweet.attachments = \(parentTweet.attachments?.count ?? 0) items")
                EmptyView()
            }
        }
    }
    
    private var commentHeader: some View {
        HStack(alignment: .top, spacing: 0) {
            if let user = comment.author {
                Avatar(user: user)
            }
            Spacer(minLength: 4)
            TweetItemHeaderView(tweet: comment)
            Spacer(minLength: 0)
            CommentMenu(comment: comment, parentTweet: parentTweet)
                .padding(.trailing, -16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top)
    }
    
    private var commentContent: some View {
        Group {
            if let content = comment.content, !content.isEmpty {
                SelectableTextView(text: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        }
    }
    
    private var actionButtons: some View {
        TweetActionBarRepresentable(
            tweet: comment,
            onCommentTap: {
                shouldShowExpandedReply = true
            },
            isInDetailView: true,
            parentTweet: parentTweet
        )
        .frame(height: 30)
        .padding(.horizontal)
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
    
    private var repliesListView: some View {
        CommentListView<CommentItemView>(
            title: "Replies",
            comments: $replies,
            commentFetcher: { page, size in
                let (fetched, _) = try await hproseInstance.fetchComments(
                    comment,
                    pageNumber: page,
                    pageSize: size
                )
                return fetched
            },
            showTitle: false,
            notifications: [
                CommentListNotification(
                    name: .newCommentAdded,
                    key: "comment",
                    shouldAccept: { reply in
                        // Accept replies that belong to this comment
                        return true // We'll filter in the action
                    },
                    action: { reply, parentTweetId in
                        // Only add reply if it belongs to this comment
                        if parentTweetId == comment.mid {
                            print("[CommentDetailView] Adding reply \(reply.mid) to replies list")
                            replies.insert(reply, at: 0)
                            print("[CommentDetailView] Replies count after insert: \(replies.count)")
                        } else {
                            print("[CommentDetailView] Reply \(reply.mid) belongs to different comment (\(parentTweetId ?? "nil")), not adding")
                        }
                    }
                ),
                CommentListNotification(
                    name: .commentDeleted,
                    key: "comment",
                    shouldAccept: { reply in
                        // Only accept reply deletions that belong to this comment
                        reply.originalTweetId == comment.mid
                    },
                    action: { reply, parentTweetId in
                        if parentTweetId == comment.mid {
                            replies.removeAll { $0.mid == reply.mid }
                        }
                    }
                )
            ],
            isEmbedded: true, // Embedded in CommentDetailView's ScrollView, avoid nested scrolling
            rowView: { reply in
                CommentItemView(
                    parentTweet: comment,
                    comment: reply,
                    isInProfile: false,
                    onAvatarTap: nil, // NavigationLink will be handled inside CommentItemView
                    linkToComment: true // Enable NavigationLink wrapping
                )
            }
        )
        .padding(.leading, -8)
        .padding(.trailing, 4)
    }
    
    private func refreshComment() async {
        do {
            if let refreshedComment = try await hproseInstance.getTweet(tweetId: comment.mid, authorId: comment.authorId) {
                try comment.update(from: refreshedComment)
            }
        } catch {
            print("Failed to refresh comment: \(error)")
        }
    }
}
