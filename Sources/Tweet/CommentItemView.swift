//
//  CommentItemView.swift
//  Tweet
//
//  Created by 超方 on 2025/5/30.
//

import SwiftUI

@available(iOS 16.0, *)
struct CommentItemView: View {
    @ObservedObject var comment: Tweet
    var isInProfile: Bool = false
    var onAvatarTap: ((User) -> Void)? = nil
    var commentsVM: CommentsViewModel? = nil
    @State private var showDetail = false
    @State private var detailTweet: Tweet = Tweet(mid: Constants.GUEST_ID, authorId: Constants.GUEST_ID)
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
                    CommentMenu(comment: comment, parentTweet: detailTweet)
                }
                .contentShape(Rectangle())
                .onTapGesture { showDetail = true }
                TweetItemBodyView(tweet: comment, enableTap: false)
                    .contentShape(Rectangle())
                    .onTapGesture { showDetail = true }
                    .padding(.top, -12)
                TweetActionButtonsView(tweet: comment, commentsVM: commentsVM)
                    .padding(.top, 8)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .background(
            NavigationLink(destination: TweetDetailView(tweet: detailTweet),
                           isActive: $showDetail) {
                EmptyView()
            }
                .hidden()
        )
        .task {
            detailTweet = comment
        }
    }
}

