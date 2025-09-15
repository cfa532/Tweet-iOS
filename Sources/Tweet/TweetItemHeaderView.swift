import SwiftUI





struct TweetItemHeaderView: View {
    @ObservedObject var tweet: Tweet
    
    var body: some View {
        HStack {
            HStack(alignment: .top) {
                Text(tweet.author?.name ?? "No one")
                    .font(.headline)
                    .foregroundColor(.themeText)
                Text("@\(tweet.author?.username ?? NSLocalizedString("username", comment: "Default username"))")
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
    let showDeleteButton: Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var appUser = HproseInstance.shared.appUser
    @EnvironmentObject private var hproseInstance: HproseInstance
    @State private var isCurrentlyPinned: Bool
    @State private var isPressed = false
    @State private var showReportSheet = false
    @State private var showFilterSheet = false
    
    init(tweet: Tweet, isPinned: Bool, showDeleteButton: Bool = false) {
        self.tweet = tweet
        self.isPinned = isPinned
        self.showDeleteButton = showDeleteButton
        self._isCurrentlyPinned = State(initialValue: isPinned)
    }
    
    var body: some View {
        ZStack {
            Menu {
                Button(action: {
                    UIPasteboard.general.string = tweet.mid
                }) {
                    Label(truncatedTweetId(tweet.mid), systemImage: "doc.on.clipboard")
                }
                
                // Content filtering option
                Button(action: {
                    showFilterSheet = true
                }) {
                    Label(LocalizedStringKey("Filter Content"), systemImage: "line.3.horizontal.decrease.circle")
                }
                
                // Report tweet option (only show for tweets not authored by current user)
                if tweet.authorId != appUser.mid {
                    Button(action: {
                        showReportSheet = true
                    }) {
                        Label(LocalizedStringKey("Report Tweet"), systemImage: "flag")
                    }
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
                            Label(LocalizedStringKey("Unpin"), systemImage: "pin.slash")
                        } else {
                            Label(LocalizedStringKey("Pin"), systemImage: "pin")
                        }
                    }
                    
                    // Privacy toggle button
                    Button(action: {
                        Task {
                            do {
                                let newPrivacyStatus = try await hproseInstance.updateTweetPrivacy(tweetId: tweet.mid)
                                await MainActor.run {
                                    // Update the tweet's privacy status locally
                                    tweet.isPrivate = newPrivacyStatus
                                    
                                    // Update Core Data cache with the new privacy status
                                    TweetCacheManager.shared.updateTweetInAppUserCaches(tweet, appUserId: hproseInstance.appUser.mid)
                                    
                                    // Send notification to update tweet list views
                                    // Send tweetId for removal (handles both private->public and public->private)
                                    NotificationCenter.default.post(
                                        name: .tweetPrivacyChanged,
                                        object: nil,
                                        userInfo: [
                                            "tweetId": tweet.mid
                                        ]
                                    )
                                    
                                    // If tweet became public, also send it as a new tweet to add it back
                                    if !newPrivacyStatus {
                                        NotificationCenter.default.post(
                                            name: .newTweetCreated,
                                            object: nil,
                                            userInfo: [
                                                "tweet": tweet
                                            ]
                                        )
                                    }
                                    
                                    // Send notification for global toast
                                    let message = newPrivacyStatus ? NSLocalizedString("Tweet set to private", comment: "Toast message when tweet is set to private") : NSLocalizedString("Tweet set to public", comment: "Toast message when tweet is set to public")
                                    NotificationCenter.default.post(
                                        name: .tweetPrivacyUpdated,
                                        object: nil,
                                        userInfo: [
                                            "message": message,
                                            "type": "success"
                                        ]
                                    )
                                }
                            } catch {
                                await MainActor.run {
                                    print("[TweetMenu] Privacy update failed: \(error.localizedDescription)")
                                    
                                    // Send notification for global toast
                                    let message = NSLocalizedString("Failed to update privacy setting", comment: "Error message when privacy toggle fails")
                                    NotificationCenter.default.post(
                                        name: .tweetPrivacyUpdated,
                                        object: nil,
                                        userInfo: [
                                            "message": message,
                                            "type": "error"
                                        ]
                                    )
                                }
                            }
                        }
                    }) {
                        if tweet.isPrivate == true {
                            Label(LocalizedStringKey("Make Public"), systemImage: "globe")
                        } else {
                            Label(LocalizedStringKey("Make Private"), systemImage: "lock")
                        }
                    }
                }
                if showDeleteButton {
                    Button(role: .destructive) {
                        // Start deletion in background
                        Task {
                            do {
                                try await deleteTweet(tweet)
                            } catch {
                                print("Tweet deletion failed. \(tweet)")
                                await MainActor.run {
                                    NotificationCenter.default.post(
                                        name: .errorOccurred,
                                        object: error
                                    )
                                }
                            }
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(isPressed ? .primary : .secondary)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44) // Minimum 44x44 tap target for accessibility
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isPressed ? Color.secondary.opacity(0.2) : Color.clear)
                    )
                    .scaleEffect(isPressed ? 0.95 : 1.0)
                    .animation(.easeInOut(duration: 0.1), value: isPressed)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.1)) {
                            isPressed = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isPressed = false
                        }
                    }
                    .accessibilityLabel("Tweet options")
                    .accessibilityHint("Double tap to open tweet menu")
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            ContentFilterView(tweet: tweet)
        }
        .sheet(isPresented: $showReportSheet) {
            ReportTweetView(tweet: tweet)
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
            
            // Update user's tweet count
            await MainActor.run {
                hproseInstance.appUser.tweetCount = max(0, (hproseInstance.appUser.tweetCount ?? 0) - 1)
            }
            
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
                // Send notification for global error toast
                NotificationCenter.default.post(
                    name: .errorOccurred,
                    object: NSError(domain: "TweetDeletion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to delete tweet."])
                )
            }
        }
    }
    
    /// Truncates a tweet ID to show first 8 and last 4 characters with ellipsis in the middle
    private func truncatedTweetId(_ id: String) -> String {
        guard id.count > 12 else { return id }
        
        let prefix = String(id.prefix(8))
        let suffix = String(id.suffix(4))
        return "\(prefix)...\(suffix)"
    }
}
