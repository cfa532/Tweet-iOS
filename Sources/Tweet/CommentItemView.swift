//
//  CommentItemView.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/5/30.
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
    @State private var isVisible = false

    var body: some View {
        Group {
            if linkToComment || onTap == nil {
                // Use NavigationLink when linkToComment is true or no onTap callback is provided
                NavigationLink(value: CommentNavigation(comment: comment, parentTweet: parentTweet)) {
                    commentContent
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                // Use tap gesture when onTap callback is provided
                commentContent
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onTap?(comment)
                    }
            }
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
                if isInProfile || linkToComment {
                    // Don't navigate if we're in the same profile or using NavigationLink for comment
                    Avatar(user: user)
                } else {
                    NavigationLink(value: user) {
                        Avatar(user: user)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    TweetItemHeaderView(tweet: comment)
                    Spacer(minLength: 0)
                    CommentMenu(comment: comment, parentTweet: parentTweet)
                        .padding(.trailing, -8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                TweetItemBodyView(
                    tweet: comment,
                    enableTap: true, // Always enable tap for proper gesture recognition
                    isVisible: isVisible,
                    onTweetBodyTap: {
                        // Handle tap via callback when using callback approach
                        if let callback = onTap {
                            callback(comment)
                        }
                        // When using NavigationLink, the tap is handled by the NavigationLink wrapper
                    }
                )
                
                TweetActionButtonsView(tweet: comment, commentsVM: commentsVM, parentTweet: parentTweet)
                    .padding(.top, 8)
            }
        }
        .padding(.vertical)
        .padding(.horizontal, 16)
        .background(backgroundColor)
        .if(backgroundColor != Color(.systemBackground)) { view in
            view.shadow(color: Color(.sRGB, white: 0, opacity: 0.18), radius: 8, x: 0, y: 2)
        }
    }
}
