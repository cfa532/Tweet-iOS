import SwiftUI

struct TweetItemHeaderView: View {
    @Binding var tweet: Tweet
    
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
        }
    }
}

struct TweetMenu: View {
    @Binding var tweet: Tweet
    let deleteTweet: (Tweet) async -> Void
    let isPinned: Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var appUser = HproseInstance.shared.appUser
    @State private var isTogglingPin = false
    private let hproseInstance = HproseInstance.shared

    var body: some View {
        Menu {
            if tweet.authorId == appUser.mid {
                Button(action: {
                    Task {
                        isTogglingPin = true
                        _ = try? await hproseInstance.togglePinnedTweet(tweetId: tweet.mid)
                        isTogglingPin = false
                    }
                }) {
                    if isTogglingPin {
                        Label("Toggling...", systemImage: "pin")
                    } else if isPinned {
                        Label("Unpin", systemImage: "pin.slash")
                    } else {
                        Label("Pin", systemImage: "pin")
                    }
                }
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
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundColor(.secondary)
        }
    }
}
