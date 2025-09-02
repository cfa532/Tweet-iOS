//
//  CommentItemView.swift
//  Tweet
//
//  Created by 超方 on 2025/5/30.
//

import SwiftUI

@available(iOS 16.0, *)
struct CommentItemView: View {
    @ObservedObject var parentTweet: Tweet
    @ObservedObject var comment: Tweet
    var isInProfile: Bool = false
    var onAvatarTap: ((User) -> Void)? = nil
    var onTap: ((Tweet) -> Void)? = nil
    var linkToComment: Bool = false // Enable NavigationLink for the comment
    var commentsVM: CommentsViewModel? = nil
    var backgroundColor: Color = Color(.systemBackground)
    @State private var showDetail = false
    @State private var isVisible = false
    @State private var showBrowser = false
    @State private var selectedMediaIndex = 0
    @State private var hproseInstance = HproseInstanceState.shared

    var body: some View {
        Group {
            if linkToComment {
                NavigationLink(value: comment) {
                    commentContent
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                commentContent
            }
        }
        .fullScreenCover(isPresented: $showBrowser) {
            MediaBrowserView(
                tweet: comment,
                initialIndex: selectedMediaIndex
            )
        }
        .task {
            isVisible = true
            comment.isVisible = true
        }
        .onDisappear {
            isVisible = false
            comment.isVisible = false
        }
    }
    
    private var commentContent: some View {
        HStack(alignment: .top, spacing: 8) {
            if let user = comment.author {
                if isInProfile {
                    Avatar(user: user) // Don't navigate if we're in the same profile
                } else {
                    NavigationLink(value: user) {
                        Avatar(user: user)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            VStack(alignment: .leading) {
                HStack {
                    TweetItemHeaderView(tweet: comment)
                    CommentMenu(comment: comment, parentTweet: parentTweet)
                }
                .padding(.top, -8)
                
                TweetItemBodyView(tweet: comment, enableTap: false, isVisible: isVisible)
                .padding(.top, -12)
                
                TweetActionButtonsView(tweet: comment, commentsVM: commentsVM)
                    .padding(.top, 8)
            }
        }
        .padding()
        .padding(.horizontal, -4)
        .background(backgroundColor)
        .if(backgroundColor != Color(.systemBackground)) { view in
            view.shadow(color: Color(.sRGB, white: 0, opacity: 0.18), radius: 8, x: 0, y: 2)
        }
    }
}

