import SwiftUI

struct TweetItemView: View {
    let tweet: Tweet
    let likeTweet: (Tweet) async -> Void
    let retweet: (Tweet) async -> Void
    let bookmarkTweet: (Tweet) async -> Void
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
                TweetBodyView(tweet: tweet, enableTap: false)
                    .contentShape(Rectangle())
                    .onTapGesture { showDetail = true }
            })
        }
        .padding()
        .background(Color(.systemBackground))
        .background(
            NavigationLink(destination: TweetDetailView(tweet: tweet), isActive: $showDetail) {
                EmptyView()
            }
            .hidden()
        )
    }
}

// MARK: - Preview
struct TweetItemView_Previews: PreviewProvider {
    static var previews: some View {
        TweetItemView(
            tweet: Tweet(
                mid: "1",
                authorId: "1"
            ),
            likeTweet: { _ in },
            retweet: { _ in },
            bookmarkTweet: { _ in },
            deleteTweet: { _ in },
            isInProfile: false,
            onAvatarTap: { _ in }
        )
    }
} 
