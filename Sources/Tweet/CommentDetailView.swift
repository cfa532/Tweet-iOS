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
    @State private var refreshTimer: Timer?
    @EnvironmentObject private var hproseInstance: HproseInstance
    @Environment(\.dismiss) private var dismiss
    @State private var replies: [Tweet] = []
    
    // Toast states
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info
    
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
                // Attachments (edge-to-edge, no margin)
                if let attachments = comment.attachments, let baseUrl = comment.author?.baseUrl, !attachments.isEmpty {
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
                
                // Comment header (with avatar and menu)
                HStack(alignment: .top, spacing: 12) {
                    if let user = comment.author {
                        Avatar(user: user)
                    }
                    TweetItemHeaderView(tweet: comment)
                    CommentMenu(comment: comment, parentTweet: parentTweet)
                }
                .padding(.horizontal)
                .padding(.top)
                
                // Comment content
                if let content = comment.content, !content.isEmpty {
                    Text(content)
                        .font(.title3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }
                
                TweetActionButtonsView(tweet: comment)
                    .padding(.leading, 48)
                    .padding(.trailing, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                
                Divider()
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                
                // Replies section
                repliesListView
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Reply")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showBrowser) {
            MediaBrowserView(attachments: comment.attachments ?? [], baseUrl: comment.author?.baseUrl ?? "", initialIndex: selectedMediaIndex)
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
        .onDisappear {
            // Clean up timer when view disappears
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .task {
            // Initial refresh after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                refreshComment()
            }
            
            // Set up periodic refresh every 5 minutes
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
                Task { @MainActor in
                    refreshComment()
                }
            }
        }
        .background(profileNavigationLink)
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
                    shouldAccept: { _ in true },
                    action: { reply in
                        replies.insert(reply, at: 0)
                    }
                ),
                CommentListNotification(
                    name: .commentDeleted,
                    key: "comment",
                    shouldAccept: { _ in true },
                    action: { reply in replies.removeAll { $0.mid == reply.mid } }
                )
            ],
            rowView: { reply in
                CommentItemView(
                    parentTweet: comment,
                    comment: reply,
                    onAvatarTap: { user in selectedUser = user }
                )
            }
        )
    }
    
    private func refreshComment() {
        Task {
            do {
                if let refreshedComment = try await hproseInstance.getTweet(tweetId: comment.mid, authorId: comment.authorId) {
                    await MainActor.run {
                        try? comment.update(from: refreshedComment)
                    }
                }
            } catch {
                print("Failed to refresh comment: \(error)")
            }
        }
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
}

