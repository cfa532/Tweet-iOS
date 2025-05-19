import SwiftUI

struct TweetItemView: View {
    let tweet: Tweet
    let likeTweet: (Tweet) async -> Void
    let retweet: (Tweet) async -> Void
    let bookmarkTweet: (Tweet) async -> Void
    let deleteTweet: (Tweet) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Author info
            TweetHeaderView(tweet: tweet)
            TweetBodyView(tweet: tweet)
        }
        .padding()
        .background(Color(.systemBackground))
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
            deleteTweet: { _ in }
        )
    }
} 
