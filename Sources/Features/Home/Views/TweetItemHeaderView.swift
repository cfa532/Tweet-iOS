import SwiftUI

struct TweetItemHeaderView: View {
    @Binding var tweet: Tweet
    let deleteTweet: (String) async -> Void
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
//                        try await hproseInstance.deleteTweet(tweet.mid)
                        await deleteTweet(tweet.mid)
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
