import SwiftUI

/// TweetWeb-style admin edit (username `admin`); same API as web `updateTweet(..., authorId)`.
struct AdminTweetContentEditSheet: View {
    @ObservedObject var tweet: Tweet
    @EnvironmentObject private var hproseInstance: HproseInstance
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    init(tweet: Tweet) {
        self.tweet = tweet
        _text = State(initialValue: tweet.content ?? "")
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(8)
                .navigationTitle("Edit (admin)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task {
                                await MainActor.run { saving = true }
                                defer { Task { @MainActor in saving = false } }
                                do {
                                    try await hproseInstance.updateTweetContent(
                                        tweetId: tweet.mid,
                                        content: text,
                                        tweetAuthorId: tweet.authorId
                                    )
                                    await MainActor.run {
                                        tweet.performBatchUpdate {
                                            tweet.content = text
                                            // Invalidate rendered text cache so feed/detail re-render
                                            // uses the new content immediately.
                                            tweet.cachedContentAttributedString = nil
                                            tweet.cachedContentWidth = 0
                                            tweet.cachedMeasuredTextHeight = -1
                                            tweet.cachedMeasuredTextWidth = 0
                                            tweet.cachedHeight = nil
                                        }
                                        if let singleton = Tweet.getInstance(for: tweet.mid), singleton !== tweet {
                                            singleton.performBatchUpdate {
                                                singleton.content = text
                                                singleton.cachedContentAttributedString = nil
                                                singleton.cachedContentWidth = 0
                                                singleton.cachedMeasuredTextHeight = -1
                                                singleton.cachedMeasuredTextWidth = 0
                                                singleton.cachedHeight = nil
                                            }
                                        }
                                        TweetCacheManager.shared.saveTweet(tweet, userId: tweet.authorId)
                                        dismiss()
                                    }
                                } catch {
                                    await MainActor.run {
                                        errorMessage = ErrorMessageHelper.userFriendlyMessage(from: error)
                                        showErrorAlert = true
                                        NotificationCenter.default.post(name: .errorOccurred, object: error)
                                    }
                                }
                            }
                        }
                        .disabled(saving)
                    }
                }
        }
        .overlay {
            if saving {
                ZStack {
                    Color.black.opacity(0.08).ignoresSafeArea()
                    ProgressView("Saving...")
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .alert("Update Failed", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }
}

struct TweetItemHeaderView: View {
    @ObservedObject var tweet: Tweet
    
    var body: some View {
        AuthorNameView(author: tweet.author, timeDifference: timeDifference)
            .lineLimit(2)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
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
    typealias DeleteConfirmationPresenter = (@escaping () -> Void) -> Void

    @ObservedObject var tweet: Tweet
    let editTweet: Tweet?
    let isPinned: Bool
    let showDeleteButton: Bool
    let onShareTap: (() -> Void)?
    let onShowLogin: (() -> Void)?
    let onFilterTap: (() -> Void)?
    let onReportTap: (() -> Void)?
    let onDeleteTap: DeleteConfirmationPresenter?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var appUser = HproseInstance.shared.appUser
    @EnvironmentObject private var hproseInstance: HproseInstance
    @State private var isCurrentlyPinned: Bool
    @State private var isPressed = false
    @State private var showReportSheet = false
    @State private var showFilterSheet = false
    @State private var showAdminEditSheet = false
    @State private var showDeleteConfirmation = false
    
    init(
        tweet: Tweet,
        editTweet: Tweet? = nil,
        isPinned: Bool,
        showDeleteButton: Bool = false,
        onShareTap: (() -> Void)? = nil,
        onShowLogin: (() -> Void)? = nil,
        onFilterTap: (() -> Void)? = nil,
        onReportTap: (() -> Void)? = nil,
        onDeleteTap: DeleteConfirmationPresenter? = nil
    ) {
        self.tweet = tweet
        self.editTweet = editTweet
        self.isPinned = isPinned
        self.showDeleteButton = showDeleteButton
        self.onShareTap = onShareTap
        self.onShowLogin = onShowLogin
        self.onFilterTap = onFilterTap
        self.onReportTap = onReportTap
        self.onDeleteTap = onDeleteTap
        self._isCurrentlyPinned = State(initialValue: isPinned)
    }

    private var immediateActions: [UIAction] {
        var actions = [UIAction(title: truncatedTweetId(tweet.mid), image: UIImage(systemName: "doc.on.clipboard")) { _ in
            UIPasteboard.general.string = tweet.mid
        }]
        actions.append(UIAction(title: NSLocalizedString("Share", comment: "Menu item"), image: UIImage(systemName: "square.and.arrow.up")) { _ in
            onShareTap?()
        })
        actions.append(UIAction(title: NSLocalizedString("Filter Content", comment: "Menu item"), image: UIImage(systemName: "line.3.horizontal.decrease.circle")) { _ in
            guard requireAuthenticatedForWrite() else { return }
            if let onFilterTap {
                onFilterTap()
            } else {
                showFilterSheet = true
            }
        })
        if tweet.authorId != appUser.mid {
            actions.append(UIAction(title: NSLocalizedString("Report Tweet", comment: "Menu item"), image: UIImage(systemName: "flag")) { _ in
                guard requireAuthenticatedForWrite() else { return }
                if let onReportTap {
                    onReportTap()
                } else {
                    showReportSheet = true
                }
            })
        }
        if Gadget.isResearchAdminUser(appUser) {
            actions.append(UIAction(title: NSLocalizedString("Edit content (admin)", comment: "Admin research menu"), image: UIImage(systemName: "pencil.line")) { _ in
                showAdminEditSheet = true
            })
        }
        if tweet.authorId == appUser.mid {
            let pinTitle = isCurrentlyPinned ? NSLocalizedString("Unpin", comment: "Menu item") : NSLocalizedString("Pin", comment: "Menu item")
            actions.append(UIAction(title: pinTitle, image: UIImage(systemName: isCurrentlyPinned ? "pin.slash" : "pin")) { _ in
                togglePin()
            })
            let privacyTitle = tweet.isPrivate == true ? NSLocalizedString("Make Public", comment: "Menu item") : NSLocalizedString("Make Private", comment: "Menu item")
            actions.append(UIAction(title: privacyTitle, image: UIImage(systemName: tweet.isPrivate == true ? "globe" : "lock")) { _ in
                togglePrivacy()
            })
        }
        if showDeleteButton {
            actions.append(UIAction(title: NSLocalizedString("Delete", comment: "Menu item"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                guard requireAuthenticatedForWrite() else { return }
                if let onDeleteTap {
                    onDeleteTap {
                        Task { try? await deleteTweet(tweet) }
                    }
                } else {
                    showDeleteConfirmation = true
                }
            })
        }
        return actions
    }

    private func togglePin() {
        guard requireAuthenticatedForWrite() else { return }
        let previousPinStatus = isCurrentlyPinned
        let intendedPinStatus = !previousPinStatus
        isCurrentlyPinned = intendedPinStatus
        NotificationCenter.default.post(
            name: .tweetPinStatusChanged,
            object: nil,
            userInfo: ["tweetId": tweet.mid, "isPinned": intendedPinStatus]
        )

        Task {
            do {
                guard let pinned = try await hproseInstance.togglePinnedTweet(tweetId: tweet.mid) else {
                    throw NSError(
                        domain: "PinToggle",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to update pinned tweet", comment: "Pin tweet error")]
                    )
                }
                if pinned != intendedPinStatus {
                    await MainActor.run {
                        isCurrentlyPinned = pinned
                        NotificationCenter.default.post(
                            name: .tweetPinStatusChanged,
                            object: nil,
                            userInfo: ["tweetId": tweet.mid, "isPinned": pinned]
                        )
                    }
                }
            } catch {
                let message = ErrorMessageHelper.userFriendlyMessage(from: error)
                await MainActor.run {
                    isCurrentlyPinned = previousPinStatus
                    NotificationCenter.default.post(
                        name: .tweetPinStatusChanged,
                        object: nil,
                        userInfo: ["tweetId": tweet.mid, "isPinned": previousPinStatus]
                    )
                    NotificationCenter.default.post(
                        name: .errorOccurred,
                        object: NSError(domain: "PinToggle", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
                    )
                }
            }
        }
    }

    private func togglePrivacy() {
        guard requireAuthenticatedForWrite() else { return }
        Task {
            guard let isPrivate = try? await hproseInstance.toggleTweetPrivacy(tweetId: tweet.mid) else { return }
            await MainActor.run {
                tweet.isPrivate = isPrivate
                TweetCacheManager.shared.saveTweet(tweet, userId: tweet.authorId)
                NotificationCenter.default.post(name: .tweetPrivacyChanged, object: nil, userInfo: ["tweetId": tweet.mid])
            }
        }
    }
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if false {
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
                    guard requireAuthenticatedForWrite() else { return }
                    showFilterSheet = true
                }) {
                    Label(LocalizedStringKey("Filter Content"), systemImage: "line.3.horizontal.decrease.circle")
                }
                
                // Report tweet option (only show for tweets not authored by current user)
                if tweet.authorId != appUser.mid {
                    Button(action: {
                        guard requireAuthenticatedForWrite() else { return }
                        showReportSheet = true
                    }) {
                        Label(LocalizedStringKey("Report Tweet"), systemImage: "flag")
                    }
                }

                if Gadget.isResearchAdminUser(appUser) {
                    Button(action: { showAdminEditSheet = true }) {
                        Label("Edit content (admin)", systemImage: "pencil.line")
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
                        if let onDeleteTap {
                            onDeleteTap {
                                Task { try? await deleteTweet(tweet) }
                            }
                        } else {
                            showDeleteConfirmation = true
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
                .buttonStyle(.plain)
            } else {
                ImmediateMenuButtonView(actions: immediateActions)
                    .frame(width: 44, height: 44)
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
        .sheet(isPresented: $showAdminEditSheet) {
            AdminTweetContentEditSheet(tweet: editTweet ?? tweet)
                .environmentObject(hproseInstance)
        }
        .alert(
            NSLocalizedString("Delete Tweet?", comment: "Delete tweet confirmation title"),
            isPresented: $showDeleteConfirmation
        ) {
            Button(NSLocalizedString("Delete Tweet", comment: "Confirm tweet deletion"), role: .destructive) {
                Task { try? await deleteTweet(tweet) }
            }
            Button(NSLocalizedString("Cancel", comment: "Cancel tweet deletion"), role: .cancel) { }
        } message: {
            Text(
                NSLocalizedString(
                    "This tweet will be permanently deleted. This action cannot be undone.",
                    comment: "Delete tweet confirmation message"
                )
            )
        }
    }
    
    private func deleteTweet(_ tweet: Tweet) async throws {
        guard requireAuthenticatedForWrite() else { return }
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
            let tweetId = try await hproseInstance.deleteTweet(tweet.mid, tweetAuthorId: tweet.authorId)
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
            TweetDeletionRegistry.shared.unmarkDeleted(tweet.mid)
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

    private func requireAuthenticatedForWrite() -> Bool {
        guard appUser.isGuest else { return true }
        onShowLogin?()
        return false
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
    let timeDifference: String
    
    var body: some View {
        Group {
            if let user = author {
                ObservedAuthorNameView(user: user, timeDifference: timeDifference)
            } else {
                headerText(
                    name: "No one",
                    username: NSLocalizedString("username", comment: "Default username"),
                    timeDifference: timeDifference
                )
            }
        }
    }

    private func headerText(name: String, username: String, timeDifference: String) -> Text {
        Text(name)
            .font(.headline)
            .foregroundColor(.themeText)
        + Text(" @\(username) • \(timeDifference)")
            .font(.subheadline)
            .foregroundColor(.themeSecondaryText)
    }
}

/// Observes the User singleton to refresh when username/name updates
private struct ObservedAuthorNameView: View {
    @ObservedObject var user: User
    let timeDifference: String
    
    var body: some View {
        Text(user.name ?? "No one")
            .font(.headline)
            .foregroundColor(.themeText)
        + Text(" @\(user.username ?? NSLocalizedString("username", comment: "Default username")) • \(timeDifference)")
            .font(.subheadline)
            .foregroundColor(.themeSecondaryText)
    }
}
