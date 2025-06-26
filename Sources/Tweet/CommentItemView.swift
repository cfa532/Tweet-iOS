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
    var commentsVM: CommentsViewModel? = nil
    @State private var showDetail = false
    @EnvironmentObject private var hproseInstance: HproseInstance

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let user = comment.author {
                Button(action: {
                    if !isInProfile {
                        onAvatarTap?(user)
                    }
                }) {
                    Avatar(user: user)
                }
                .buttonStyle(PlainButtonStyle())
            }
            VStack(alignment: .leading) {
                HStack {
                    TweetItemHeaderView(tweet: comment)
                    CommentMenu(comment: comment, parentTweet: parentTweet)
                }
                .contentShape(Rectangle())
                .onTapGesture { showDetail = true }
                .padding(.top, -8)
                
                TweetItemBodyView(tweet: comment, enableTap: false)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap?(comment) }
                    .padding(.top, -12)
                TweetActionButtonsView(tweet: comment, commentsVM: commentsVM)
                    .padding(.top, 8)
            }
        }
        .padding()
        .background(Color(.systemBackground))
    }
}

