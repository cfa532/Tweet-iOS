//
//  CommentDetailView.swift
//  Tweet
//
//  Created by 超方 on 2025/6/8.
//

import SwiftUI
import AVKit

@MainActor
@available(iOS 16.0, *)
struct CommentDetailView: View {
    @ObservedObject var comment: Tweet
    @ObservedObject var parentTweet: Tweet
    @State private var showBrowser = false
    @State private var selectedMediaIndex = 0
    @State private var showLoginSheet = false
    @State private var selectedUser: User? = nil
    @State private var replies: [Tweet] = []
    
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                mediaSection
                commentHeader
                commentContent
                actionButtons
                Divider()
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                repliesListView
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Reply")
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
        .task {
            // Refresh comment after a short delay
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            await refreshComment()
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
            if let attachments = comment.attachments, !attachments.isEmpty {
                let aspect = CGFloat(attachments.first?.aspectRatio ?? 4.0/3.0)
                TabView(selection: $selectedMediaIndex) {
                    ForEach(attachments.indices, id: \.self) { index in
                        DetailMediaCell(
                            parentTweet: comment,
                            attachmentIndex: index,
                            showMuteButton: false,
                            videoManager: DetailVideoManager.shared,
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
                .frame(maxWidth: .infinity)
                .frame(height: UIScreen.main.bounds.width / aspect)
                .background(Color.black)
            }
        }
    }
    
    private var commentHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            if let user = comment.author {
                Avatar(user: user)
            }
            TweetItemHeaderView(tweet: comment)
            CommentMenu(comment: comment, parentTweet: parentTweet)
        }
        .padding(.horizontal)
        .padding(.top)
    }
    
    private var commentContent: some View {
        Group {
            if let content = comment.content, !content.isEmpty {
                Text(content)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        }
    }
    
    private var actionButtons: some View {
        TweetActionButtonsView(tweet: comment)
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
    
    private var repliesListView: some View {
        CommentListView<CommentItemView>(
            title: "Replies",
            comments: $replies,
            commentFetcher: { page, size in
                try await hproseInstance.fetchComments(
                    comment,
                    pageNumber: page,
                    pageSize: size
                )
            },
            showTitle: false,
            notifications: [
                CommentListNotification(
                    name: .newCommentAdded,
                    key: "comment",
                    shouldAccept: { reply in
                        // Only accept replies that belong to this comment
                        let shouldAccept = reply.originalTweetId == comment.mid
                        print("[CommentDetailView] Reply \(reply.mid) shouldAccept check: \(shouldAccept)")
                        print("[CommentDetailView] Reply originalTweetId: \(reply.originalTweetId ?? "nil")")
                        print("[CommentDetailView] Comment mid: \(comment.mid)")
                        return shouldAccept
                    },
                    action: { reply in
                        print("[CommentDetailView] Adding reply \(reply.mid) to replies list")
                        replies.insert(reply, at: 0)
                        print("[CommentDetailView] Replies count after insert: \(replies.count)")
                    }
                ),
                CommentListNotification(
                    name: .commentDeleted,
                    key: "comment",
                    shouldAccept: { reply in
                        // Only accept reply deletions that belong to this comment
                        reply.originalTweetId == comment.mid
                    },
                    action: { reply in replies.removeAll { $0.mid == reply.mid } }
                )
            ],
            rowView: { reply in
                CommentItemView(
                    parentTweet: comment,
                    comment: reply,
                    onAvatarTap: { user in selectedUser = user },
                    onTap: { reply in
                        // Handle reply tap - navigate to reply detail
                        // For now, we'll just print since this view doesn't have navigation state
                        print("Reply tapped: \(reply.mid)")
                    }
                )
            }
        )
        .padding(.leading, -4)
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
