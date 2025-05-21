import SwiftUI

struct TweetItemHeaderView: View {
    @Binding var tweet: Tweet
    let deleteTweet: (Tweet) async -> Void
    @Environment(\.dismiss) private var dismiss
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
                    // Start deletion in background
                    Task {
                        await deleteTweet(tweet)
                    }
                    // Dismiss immediately
                    dismiss()
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
