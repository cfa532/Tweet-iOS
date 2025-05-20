import SwiftUI

struct TweetHeaderView: View {
    let tweet: Tweet
    private let hproseInstance = HproseInstance.shared
    
    var body: some View {
        HStack {

            HStack(alignment: .top) {
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
