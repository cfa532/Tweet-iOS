import SwiftUI

enum UserActions: Int {
    case FAVORITE = 0
    case BOOKMARK = 1
    case RETWEET = 2
}

@available(iOS 16.0, *)
struct TweetActionButtonsView: View {
    @ObservedObject var tweet: Tweet
    var commentsVM: CommentsViewModel? = nil
    var onCommentTap: (() -> Void)? = nil
    @State private var showCommentCompose = false
    @State private var showShareSheet = false
    @State private var showLoginSheet = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .error
    @State private var shareDomain: String? = nil
    @State private var isFetchingShareDomain = false
    @EnvironmentObject private var hproseInstance: HproseInstance

    private func handleGuestAction() {
        if hproseInstance.appUser.isGuest {
            showLoginSheet = true
        }
    }
    
    private func fetchSharingDomain() async {
        await MainActor.run {
            isFetchingShareDomain = true
        }
        
        guard let client = hproseInstance.appUser.hproseClient else {
            print("[TweetActionButtonsView] Client not initialized for sharing domain fetch")
            await MainActor.run {
                isFetchingShareDomain = false
            }
            return
        }
        
        let entry = "check_upgrade"
        let params: [String: Any] = [
            "aid": AppConfig.appId,
            "ver": "last",
            "entry": entry
        ]
        
        // Make the network call on a background queue to prevent UI freezing
        let response = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = client.invoke("runMApp", withArgs: [entry, params])
                continuation.resume(returning: result)
            }
        }
        
        guard let responseDict = response as? [String: Any] else {
            print("[TweetActionButtonsView] Invalid response format for sharing domain")
            await MainActor.run {
                isFetchingShareDomain = false
            }
            return
        }
        
        guard let domain = responseDict["domain"] as? String else {
            print("[TweetActionButtonsView] No domain received for sharing")
            await MainActor.run {
                isFetchingShareDomain = false
            }
            return
        }
        
        await MainActor.run {
            shareDomain = "http://" + domain
            isFetchingShareDomain = false
            print("[TweetActionButtonsView] Updated shareDomain to: \(shareDomain ?? "nil")")
        }
    }
    
    private func retweet(_ tweet: Tweet) async throws {
        do {
            let currentCount = tweet.retweetCount ?? 0
            tweet.retweetCount = currentCount + 1

            if let retweet = try await hproseInstance.retweet(tweet) {
                NotificationCenter.default.post(name: .newTweetCreated,
                                                object: nil,
                                                userInfo: ["tweet": retweet])
                // Update retweet count of the original tweet in backend.
                // tweet, the original tweet now, is updated in the following function.
                try? await hproseInstance.updateRetweetCount(tweet: tweet, retweetId: retweet.mid)
            }
        } catch {
            print("Retweet failed in FollowingsTweetView")
        }
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Comment button
            DebounceButton(
                cooldownDuration: 0.3,
                enableAnimation: true,
                enableVibration: false
            ) {
                if hproseInstance.appUser.isGuest {
                    handleGuestAction()
                } else {
                    onCommentTap?() ?? { showCommentCompose = true }()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left")
                        .frame(width: 20)
                    if let count = tweet.commentCount, count > 0 {
                        Text("\(count)")
                            .frame(minWidth: 20, alignment: .leading)
                    }
                }
                .frame(width: 48, alignment: .leading)
            }
            Spacer(minLength: 12)
            // Retweet button
            DebounceButton(
                cooldownDuration: 0.5,
                enableAnimation: true,
                enableVibration: false
            ) {
                if hproseInstance.appUser.isGuest {
                    handleGuestAction()
                } else {
                    Task {
                        do {
                            try await retweet(tweet)
                        } catch {
                            print("reTweet failed. \(tweet)")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.2.squarepath")
                        .frame(width: 20)
                    if let count = tweet.retweetCount, count > 0 {
                        Text("\(count)")
                            .frame(minWidth: 20, alignment: .leading)
                    }
                }
                .frame(width: 48, alignment: .leading)
            }
            Spacer(minLength: 12)
            // Like button
            DebounceButton(
                cooldownDuration: 0.3,
                enableAnimation: true,
                enableVibration: false
            ) {
                if hproseInstance.appUser.isGuest {
                    handleGuestAction()
                } else {
                    Task {
                        // Store current state before any changes
                        let wasFavorite = tweet.favorites?[UserActions.FAVORITE.rawValue] ?? false
                        let originalFavoriteCount = tweet.favoriteCount ?? 0
                        let originalAppUserFavoriteCount = hproseInstance.appUser.favoritesCount ?? 0
                        
                        // Optimistic UI update - only after debounce check passes
                        var newFavorites = tweet.favorites ?? [false, false, false]
                        newFavorites[UserActions.FAVORITE.rawValue] = !wasFavorite
                        
                        await MainActor.run {
                            tweet.favorites = newFavorites
                            tweet.favoriteCount = (tweet.favoriteCount ?? 0) + (wasFavorite ? -1 : 1)
                            // Update appUser favorite count immediately
                            hproseInstance.appUser.favoritesCount = originalAppUserFavoriteCount + (wasFavorite ? -1 : 1)
                        }
                        
                        do {
                            let (updatedTweet, updatedUser) = try await hproseInstance.toggleFavorite(tweet)
                            
                            // Update appUser with server response if available
                            if let updatedUser = updatedUser {
                                await MainActor.run {
                                    hproseInstance.appUser.favoritesCount = updatedUser.favoritesCount
                                    hproseInstance.appUser.favoriteTweets = updatedUser.favoriteTweets
                                }
                            }
                            
                            // Update tweet with server response if available
                            if let updatedTweet = updatedTweet {
                                await MainActor.run {
                                    self.tweet.favorites = updatedTweet.favorites
                                    self.tweet.favoriteCount = updatedTweet.favoriteCount
                                }
                            }
                            
                            // Post notification for favorite list updates
                            if let updatedTweet = updatedTweet {
                                let notificationName: Notification.Name = wasFavorite ? .favoriteRemoved : .favoriteAdded
                                NotificationCenter.default.post(
                                    name: notificationName,
                                    object: nil,
                                    userInfo: ["tweet": updatedTweet]
                                )
                            }
                        } catch {
                            // Rollback optimistic updates on failure
                            await MainActor.run {
                                self.tweet.favorites = tweet.favorites
                                self.tweet.favoriteCount = originalFavoriteCount
                                hproseInstance.appUser.favoritesCount = originalAppUserFavoriteCount
                            }
                            
                            // Show error toast
                            await MainActor.run {
                                showToast = true
                                toastMessage = "Failed to \(wasFavorite ? "remove favorite" : "add favorite"). Please try again."
                                toastType = .error
                                
                                // Auto-hide toast after 3 seconds
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                    showToast = false
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: tweet.favorites?[UserActions.FAVORITE.rawValue] == true ? "heart.fill" : "heart")
                        .frame(width: 20)
                    if let count = tweet.favoriteCount, count > 0 {
                        Text("\(count)")
                            .frame(minWidth: 20, alignment: .leading)
                    }
                }
                .frame(width: 48, alignment: .leading)
            }
            Spacer(minLength: 12)
            // Bookmark button
            DebounceButton(
                cooldownDuration: 0.3,
                enableAnimation: true,
                enableVibration: false
            ) {
                if hproseInstance.appUser.isGuest {
                    handleGuestAction()
                } else {
                    Task {
                        // Store current state before any changes
                        let wasBookmarked = tweet.favorites?[UserActions.BOOKMARK.rawValue] ?? false
                        let originalBookmarkCount = tweet.bookmarkCount ?? 0
                        let originalAppUserBookmarkCount = hproseInstance.appUser.bookmarksCount ?? 0
                        
                        // Optimistic UI update - only after debounce check passes
                        var newFavorites = tweet.favorites ?? [false, false, false]
                        newFavorites[UserActions.BOOKMARK.rawValue] = !wasBookmarked
                        
                        await MainActor.run {
                            self.tweet.favorites = newFavorites
                            self.tweet.bookmarkCount = (self.tweet.bookmarkCount ?? 0) + (wasBookmarked ? -1 : 1)
                            // Update appUser bookmark count immediately
                            hproseInstance.appUser.bookmarksCount = originalAppUserBookmarkCount + (wasBookmarked ? -1 : 1)
                        }
                        
                        do {
                            let (updatedTweet, updatedUser) = try await hproseInstance.toggleBookmark(tweet)
                            
                            // Update appUser with server response if available
                            if let updatedUser = updatedUser {
                                await MainActor.run {
                                    hproseInstance.appUser.bookmarksCount = updatedUser.bookmarksCount
                                    hproseInstance.appUser.bookmarkedTweets = updatedUser.bookmarkedTweets
                                }
                            }
                            
                            // Update tweet with server response if available
                            if let updatedTweet = updatedTweet {
                                await MainActor.run {
                                    self.tweet.favorites = updatedTweet.favorites
                                    self.tweet.bookmarkCount = updatedTweet.bookmarkCount
                                }
                            }
                            
                            // Post notification for bookmark list updates
                            if let updatedTweet = updatedTweet {
                                let notificationName: Notification.Name = wasBookmarked ? .bookmarkRemoved : .bookmarkAdded
                                NotificationCenter.default.post(
                                    name: notificationName,
                                    object: nil,
                                    userInfo: ["tweet": updatedTweet]
                                )
                            }
                        } catch {
                            // Rollback optimistic updates on failure
                            await MainActor.run {
                                self.tweet.favorites = tweet.favorites
                                self.tweet.bookmarkCount = originalBookmarkCount
                                hproseInstance.appUser.bookmarksCount = originalAppUserBookmarkCount
                            }
                            
                            // Show error toast
                            await MainActor.run {
                                showToast = true
                                toastMessage = "Failed to \(wasBookmarked ? "remove bookmark" : "add bookmark"). Please try again."
                                toastType = .error
                                
                                // Auto-hide toast after 3 seconds
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                    showToast = false
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: tweet.favorites?[UserActions.BOOKMARK.rawValue] == true ? "bookmark.fill" : "bookmark")
                        .frame(width: 20)
                    if let count = tweet.bookmarkCount, count > 0 {
                        Text("\(count)")
                            .frame(minWidth: 20, alignment: .leading)
                    }
                }
                .frame(width: 48, alignment: .leading)
            }
            // Share button
            Spacer(minLength: 16)
            DebounceButton(
                cooldownDuration: 0.3,
                enableAnimation: true,
                enableVibration: false
            ) {
                if !isFetchingShareDomain {
                    Task {
                        // Only fetch domain if we don't have it yet
                        if shareDomain == nil {
                            await fetchSharingDomain()
                        }
                        showShareSheet = true
                    }
                }
            } label: {
                if isFetchingShareDomain {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 20)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 20)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .foregroundColor(.themeSecondaryText)
        .padding(.trailing, 8)
        .padding(.leading, 0)
        .sheet(isPresented: $showCommentCompose) {
            if let commentsVM = commentsVM {
                CommentComposeView(tweet: tweet, commentsVM: commentsVM)
            } else {
                CommentComposeView(tweet: tweet, commentsVM: CommentsViewModel(hproseInstance: hproseInstance, parentTweet: tweet))
            }
        }
        .onChange(of: showCommentCompose) { _, isPresented in
            // Video management is now handled locally per grid
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: [createCustomShareItem(), createCustomShareImage()])
        }
        .sheet(isPresented: $showLoginSheet) {
            LoginView()
        }
        .overlay(
            // Toast message overlay
            VStack {
                Spacer()
                if showToast {
                    ToastView(message: toastMessage, type: toastType)
                        .padding(.bottom, 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showToast)
        )
    }

    private func createCustomShareItem() -> CustomShareItem {
        let shareText = tweetShareText(tweet)
        return CustomShareItem(shareText: shareText, tweet: tweet)
    }
    
    private func createCustomShareImage() -> UIImage {
        // Create a simple app icon image
        let size = CGSize(width: 120, height: 120) // Square app icon size
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            
            // Draw the actual app icon
            if let appIcon = UIImage(named: "AppIcon") {
                let iconSize = CGSize(width: 80, height: 80)
                let iconRect = CGRect(
                    x: rect.midX - iconSize.width / 2,
                    y: rect.midY - iconSize.height / 2,
                    width: iconSize.width,
                    height: iconSize.height
                )
                appIcon.draw(in: iconRect)
            } else {
                // Fallback to bird emoji if app icon not found
                let iconAttributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 40),
                    .foregroundColor: UIColor.black
                ]
                let iconString = NSAttributedString(string: "🐦", attributes: iconAttributes)
                let iconStringSize = iconString.size()
                let iconStringRect = CGRect(
                    x: rect.midX - iconStringSize.width / 2,
                    y: rect.midY - iconStringSize.height / 2,
                    width: iconStringSize.width,
                    height: iconStringSize.height
                )
                iconString.draw(in: iconStringRect)
            }
        }
    }
    
    private func tweetShareText(_ tweet: Tweet) -> String {
        // Create a share text that includes app branding
        var shareText = ""
        
        // Priority: title > content > attachment types
        if let title = tweet.title, !title.isEmpty {
            // Use title if available
            let maxLength = 40
            let truncatedTitle = title.count > maxLength ? String(title.prefix(maxLength)) + "..." : title
            shareText += truncatedTitle
        } else if let content = tweet.content, !content.isEmpty {
            // Use content if title is not available
            let maxLength = 40
            let truncatedContent = content.count > maxLength ? String(content.prefix(maxLength)) + "..." : content
            shareText += truncatedContent
        }
        // Add URL
        let domainToUse = shareDomain ?? AppConfig.baseUrl
        var text = domainToUse
        text.append("/tweet/\(tweet.mid)/\(tweet.authorId)")
        shareText += (shareText.isEmpty ? "" : "\n\n") + text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return shareText
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

class CustomShareItem: NSObject, UIActivityItemSource {
    let shareText: String
    let tweet: Tweet
    
    init(shareText: String, tweet: Tweet) {
        self.shareText = shareText
        self.tweet = tweet
        super.init()
    }
    
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return shareText
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        return shareText
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        // Custom app name with bird icon
        if let content = tweet.content, !content.isEmpty {
            let maxLength = 40
            let truncatedContent = content.count > maxLength ? String(content.prefix(maxLength)) + "..." : content
            return "🐦 Tweet: \(truncatedContent)"
        } else {
            return "🐦 Tweet"
        }
    }
}
