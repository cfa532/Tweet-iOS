import SwiftUI

struct TweetItemHeaderView: View {
    @ObservedObject var tweet: Tweet
    
    var body: some View {
        HStack {
            HStack(alignment: .top) {
                AuthorNameView(author: tweet.author)
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
    let onShareTap: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var appUser = HproseInstance.shared.appUser
    @EnvironmentObject private var hproseInstance: HproseInstance
    @State private var isCurrentlyPinned: Bool
    @State private var isPressed = false
    @State private var showReportSheet = false
    @State private var showFilterSheet = false
    
    init(tweet: Tweet, isPinned: Bool, showDeleteButton: Bool = false, onShareTap: (() -> Void)? = nil) {
        self.tweet = tweet
        self.isPinned = isPinned
        self.showDeleteButton = showDeleteButton
        self.onShareTap = onShareTap
        self._isCurrentlyPinned = State(initialValue: isPinned)
    }
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Menu {
                Button(action: {
                    UIPasteboard.general.string = tweet.mid
                }) {
                    Label(truncatedTweetId(tweet.mid), systemImage: "doc.on.clipboard")
                }

                Button(action: {
                    onShareTap?()
                }) {
                    Label(LocalizedStringKey("Share"), systemImage: "square.and.arrow.up")
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
                            do {
                                if let isPinned = try await hproseInstance.togglePinnedTweet(tweetId: tweet.mid) {
                                    print("DEBUG: [TweetMenu] Pin toggle successful - isPinned: \(isPinned), tweetId: \(tweet.mid)")
                                    isCurrentlyPinned = isPinned
                                    NotificationCenter.default.post(
                                        name: .tweetPinStatusChanged,
                                        object: nil,
                                        userInfo: [
                                            "tweetId": tweet.mid,
                                            "isPinned": isPinned
                                        ]
                                    )
                                } else {
                                    print("DEBUG: [TweetMenu] Pin toggle returned nil for tweet: \(tweet.mid)")
                                }
                            } catch {
                                print("DEBUG: [TweetMenu] Pin toggle failed: \(error)")
                                // Show error toast
                                await MainActor.run {
                                    NotificationCenter.default.post(
                                        name: .errorOccurred,
                                        object: NSError(domain: "PinToggle", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to update pin status: \(ErrorMessageHelper.userFriendlyMessage(from: error))"])
                                    )
                                }
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
                                let newPrivacyStatus = try await hproseInstance.toggleTweetPrivacy(tweetId: tweet.mid)
                                await MainActor.run {
                                    // Update the tweet's privacy status locally
                                    tweet.isPrivate = newPrivacyStatus
                                    
                                    // Update Core Data cache with the new privacy status
                                    // Cache under the tweet's authorId, not appUser.mid
                                    TweetCacheManager.shared.saveTweet(tweet, userId: tweet.authorId)
                                    
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
                    .frame(width: 44, height: 24, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isPressed ? Color.secondary.opacity(0.2) : Color.clear)
                    )
                    // IMPROVED: Expand touch area using background (doesn't affect layout)
                    .background(
                        Color.clear
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    )
                    .scaleEffect(isPressed ? 0.95 : 1.0)
                    .animation(.easeInOut(duration: 0.1), value: isPressed)
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
        print("DEBUG: [TweetItemHeaderView] Starting tweet deletion for: \(tweet.mid)")
        
        // Post notification for optimistic UI update
        NotificationCenter.default.post(
            name: .tweetDeleted,
            object: nil,
            userInfo: ["tweetId": tweet.mid]
        )
        print("DEBUG: [TweetItemHeaderView] Posted .tweetDeleted notification for: \(tweet.mid)")
        
        // Attempt actual deletion
        do {
            if let tweetId = try await hproseInstance.deleteTweet(tweet.mid) {
                print("DEBUG: [TweetItemHeaderView] Successfully deleted tweet: \(tweetId)")
                
                // Note: tweetCount is updated by refreshAppUserFromServer() inside deleteTweet()
                
                if let originalTweetId = tweet.originalTweetId,
                   let originalAuthorId = tweet.originalAuthorId,
                   let originalTweet = try? await hproseInstance.getTweet(
                    tweetId: originalTweetId,
                    authorId: originalAuthorId)
                {
                    // originalTweet is loaded in cache, which is visible to user.
                    let currentCount = originalTweet.retweetCount ?? 0
                    originalTweet.retweetCount = max(0, currentCount - 1)
                    if let updatedTweet = await hproseInstance.updateRetweetCount(tweet: originalTweet, retweetId: tweet.mid, direction: false) {
                        // Cache the updated original tweet with its authorId as the cache key
                        TweetCacheManager.shared.saveTweet(updatedTweet, userId: updatedTweet.authorId)
                        
                        // Refresh original tweet from server to ensure all views get the updated count
                        if let refreshedTweet = try? await hproseInstance.refreshTweet(tweetId: originalTweetId, authorId: originalAuthorId) {
                            await MainActor.run {
                                if let existingTweet = Tweet.getInstance(for: originalTweetId) {
                                    try? existingTweet.update(from: refreshedTweet)
                                }
                            }
                        }
                    }
                }
            } else {
                print("DEBUG: [TweetItemHeaderView] deleteTweet returned nil for: \(tweet.mid)")
                throw NSError(domain: "TweetDeletion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server returned nil"])
            }
        } catch {
            print("DEBUG: [TweetItemHeaderView] Tweet deletion failed for \(tweet.mid): \(error)")
            
            // If deletion fails and this was a retweet, refresh original tweet to restore correct retweetCount
            if let originalTweetId = tweet.originalTweetId,
               let originalAuthorId = tweet.originalAuthorId {
                if let refreshedTweet = try? await hproseInstance.refreshTweet(tweetId: originalTweetId, authorId: originalAuthorId) {
                    await MainActor.run {
                        if let existingTweet = Tweet.getInstance(for: originalTweetId) {
                            try? existingTweet.update(from: refreshedTweet)
                        }
                    }
                }
            }
            
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
                    object: NSError(domain: "TweetDeletion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to delete tweet: \(ErrorMessageHelper.userFriendlyMessage(from: error))"])
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

/// Separate view to observe User singleton changes
private struct AuthorNameView: View {
    let author: User?
    
    var body: some View {
        Group {
            if let user = author {
                ObservedAuthorNameView(user: user)
            } else {
                Text("No one")
                    .font(.headline)
                    .foregroundColor(.themeText)
                Text("@\(NSLocalizedString("username", comment: "Default username"))")
                    .font(.subheadline)
                    .foregroundColor(.themeSecondaryText)
                    .padding(.leading, -6)
            }
        }
    }
}

/// Observes the User singleton to refresh when username/name updates
private struct ObservedAuthorNameView: View {
    @ObservedObject var user: User
    
    var body: some View {
        Text(user.name ?? "No one")
            .font(.headline)
            .foregroundColor(.themeText)
        Text("@\(user.username ?? NSLocalizedString("username", comment: "Default username"))")
            .font(.subheadline)
            .foregroundColor(.themeSecondaryText)
            .padding(.leading, -6)
    }
}
