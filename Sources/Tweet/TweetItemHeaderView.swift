import SwiftUI

struct TweetItemHeaderView: View {
    @ObservedObject var tweet: Tweet
    
    var body: some View {
        HStack {
            HStack(alignment: .top) {
                Text(tweet.author?.name ?? "No one")
                    .font(.headline)
                    .foregroundColor(.themeText)
                Text("@\(tweet.author?.username ?? "")")
                    .font(.subheadline)
                    .foregroundColor(.themeSecondaryText)
                    .padding(.leading, -6)
                Text("•")
                    .font(.subheadline)
                    .foregroundColor(.themeSecondaryText)
                    .padding(.leading, -6)
                Text(timeDifference)
                    .font(.subheadline)
                    .foregroundColor(.themeSecondaryText)
                    .padding(.leading, -6)
            }
            Spacer()
        }
    }
    
    private var timeDifference: String {
        let now = Date()
        let timeInterval = now.timeIntervalSince(tweet.timestamp)
        
        if timeInterval < 60 {
            return "now"
        } else if timeInterval < 3600 {
            let minutes = Int(timeInterval / 60)
            return "\(minutes)m"
        } else if timeInterval < 86400 {
            let hours = Int(timeInterval / 3600)
            return "\(hours)h"
        } else if timeInterval < 2592000 {
            let days = Int(timeInterval / 86400)
            return "\(days)d"
        } else if timeInterval < 31536000 {
            let months = Int(timeInterval / 2592000)
            return "\(months)mo"
        } else {
            let years = Int(timeInterval / 31536000)
            return "\(years)y"
        }
    }
}

@available(iOS 16.0, *)
struct TweetMenu: View {
    @ObservedObject var tweet: Tweet
    let isPinned: Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var appUser = HproseInstance.shared.appUser
    @EnvironmentObject private var hproseInstance: HproseInstance
    @State private var isCurrentlyPinned: Bool
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info

    init(tweet: Tweet, isPinned: Bool) {
        self.tweet = tweet
        self.isPinned = isPinned
        self._isCurrentlyPinned = State(initialValue: isPinned)
    }

    var body: some View {
        ZStack {
            Menu {
                Button(action: {
                    UIPasteboard.general.string = tweet.mid
                }) {
                    Label("\(tweet.mid)", systemImage: "doc.on.clipboard")
                }
                
                if tweet.authorId == appUser.mid {
                    Button(action: {
                        Task {
                            if let isPinned = try? await hproseInstance.togglePinnedTweet(tweetId: tweet.mid) {
                                isCurrentlyPinned = isPinned
                                NotificationCenter.default.post(
                                    name: .tweetPinStatusChanged,
                                    object: nil,
                                    userInfo: [
                                        "tweetId": tweet.mid,
                                        "isPinned": isPinned
                                    ]
                                )
                            }
                        }
                    }) {
                        if isCurrentlyPinned {
                            Label("Unpin", systemImage: "pin.slash")
                        } else {
                            Label("Pin", systemImage: "pin")
                        }
                    }
                    Button(role: .destructive) {
                        // Start deletion in background
                        Task {
                            do {
                                try await deleteTweet(tweet)
                            } catch {
                                print("Tweet deletion failed. \(tweet)")
                                await MainActor.run {
                                    toastMessage = "Failed to delete tweet."
                                    toastType = .error
                                    showToast = true
                                }
                            }
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(.secondary)
                    .padding(12)
                    .contentShape(Rectangle())
            }
            if showToast {
                VStack {
                    Spacer()
                    ToastView(message: toastMessage, type: toastType)
                        .padding(.bottom, 40)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut, value: showToast)
            }
        }
    }
    
    private func deleteTweet(_ tweet: Tweet) async throws {
        // Post notification for optimistic UI update
        NotificationCenter.default.post(
            name: .tweetDeleted,
            object: nil,
            userInfo: ["tweetId": tweet.mid]
        )
        
        // Attempt actual deletion
        if let tweetId = try? await hproseInstance.deleteTweet(tweet.mid) {
            print("Successfully deleted tweet: \(tweetId)")
            if let originalTweetId = tweet.originalTweetId,
               let originalAuthorId = tweet.originalAuthorId,
               let originalTweet = try? await hproseInstance.getTweet(
                tweetId: originalTweetId,
                authorId: originalAuthorId)
            {
                // originalTweet is loaded in cache, which is visible to user.
                let currentCount = originalTweet.retweetCount ?? 0
                originalTweet.retweetCount = max(0, currentCount - 1)
                try? await hproseInstance.updateRetweetCount(tweet: originalTweet, retweetId: tweet.mid, direction: false)
            }
        } else {
            // If deletion fails, post restoration notification
            NotificationCenter.default.post(
                name: .tweetRestored,
                object: nil,
                userInfo: ["tweetId": tweet.mid]
            )
            await MainActor.run {
                toastMessage = "Failed to delete tweet."
                toastType = .error
                showToast = true
            }
        }
    }
}
