import SwiftUI

struct TweetHeaderView: View {
    let tweet: Tweet
    private let hproseInstance = HproseInstance.shared
    
    var body: some View {
        HStack {
            if let avatarUrl = tweet.author?.avatarUrl {
                AsyncImage(url: URL(string: avatarUrl)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.gray
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            } else {
                Image("ic_splash")
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
            }
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
                        try await hproseInstance.deleteTweet(tweet.mid)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Preview
struct TweetHeaderView_Previews: PreviewProvider {
    static var previews: some View {
        TweetHeaderView(
            tweet: Tweet(
                mid: "1",
                authorId: "1"
            ),
        )
        .padding()
    }
}
