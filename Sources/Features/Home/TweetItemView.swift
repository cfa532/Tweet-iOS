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
            HStack {
                AsyncImage(url: URL(string: tweet.author?.avatar ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.gray
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                VStack(alignment: .leading) {
                    Text(tweet.author?.name ?? "No one")
                        .font(.headline)
                    Text("@\(tweet.author?.username ?? "")")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Menu {
                    Button(role: .destructive) {
                        Task {
                            await deleteTweet(tweet)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.secondary)
                }
            }
            // Tweet content
            Text(tweet.content ?? "")
                .font(.body)
            // Media attachments
            if let attachments = tweet.attachments {
                let mimeiAttachments = attachments.map { media in
                    MimeiFileType(
                        mid: media.mid,
                        type: media.type,
                        size: media.size,
                        fileName: media.fileName,
                        timestamp: media.timestamp,
                        aspectRatio: media.aspectRatio,
                        url: media.url
                    )
                }
                MediaGridView(attachments: mimeiAttachments)
            }
            // Tweet actions
            HStack(spacing: 16) {
                TweetActionButton(
                    icon: "message",
                    count: tweet.retweetCount,
                    isSelected: false
                ) {
                    // Handle reply
                }
                TweetActionButton(
                    icon: "arrow.2.squarepath",
                    count: tweet.retweetCount,
                    isSelected: tweet.isRetweeted
                ) {
                    Task {
                        await retweet(tweet)
                    }
                }
                TweetActionButton(
                    icon: "heart",
                    count: tweet.favoriteCount,
                    isSelected: tweet.isLiked
                ) {
                    Task {
                        await likeTweet(tweet)
                    }
                }
                TweetActionButton(
                    icon: "bookmark",
                    count: 0,
                    isSelected: tweet.isBookmarked
                ) {
                    Task {
                        await bookmarkTweet(tweet)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
    }
}

struct TweetActionButton: View {
    let icon: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundColor(isSelected ? .blue : .secondary)
                if count > 0 {
                    Text("\(count)")
                        .font(.subheadline)
                        .foregroundColor(isSelected ? .blue : .secondary)
                }
            }
        }
    }
}

struct MediaGridView: View {
    let attachments: [MimeiFileType]
    private let appUser = HproseInstance.shared.appUser

    var body: some View {
        let columns = [
            GridItem(.flexible()),
            GridItem(.flexible())
        ]
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(attachments) { attachment in
                AsyncImage(url: attachment.getUrl(appUser.baseUrl ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.gray
                }
                .frame(height: 200)
                .clipped()
            }
        }
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
