import SwiftUI

struct TweetItemView: View {
    @Binding var tweet: Tweet
    let retweet: (Tweet) async -> Void
    let deleteTweet: (Tweet) async -> Void
    var isInProfile: Bool = false
    var onAvatarTap: ((User) -> Void)? = nil
    @State private var showDetail = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Author info
            if let user = tweet.author {
                Button(action: {
                    if !isInProfile {
                        onAvatarTap?(user)
                    }
                }) {
                    Avatar(user: user)
                }
                .buttonStyle(PlainButtonStyle())
            }
            VStack(alignment: .leading, content: {
                TweetHeaderView(tweet: tweet)
                    .contentShape(Rectangle())
                    .onTapGesture { showDetail = true }
                TweetBodyView(tweet: $tweet, enableTap: false, retweet: retweet, deleteTweet: deleteTweet)
                    .contentShape(Rectangle())
                    .onTapGesture { showDetail = true }
            })
        }
        .padding()
        .background(Color(.systemBackground))
        .background(
            NavigationLink(destination: TweetDetailView(
                tweet: $tweet,
                retweet: retweet,
                deleteTweet: deleteTweet
            ), isActive: $showDetail) {
                EmptyView()
            }
            .hidden()
        )
    }
}
