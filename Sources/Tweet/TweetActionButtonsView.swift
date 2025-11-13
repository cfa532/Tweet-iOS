import SwiftUI
import UIKit
import AVFoundation
import LinkPresentation

enum UserActions: Int {
    case FAVORITE = 0
    case BOOKMARK = 1
    case RETWEET = 2
}

// Wrapper to make share items identifiable for .sheet(item:)
struct ShareSheetData: Identifiable {
    let id = UUID()
    let items: [Any]
}

@available(iOS 16.0, *)
struct TweetActionButtonsView: View {
    @ObservedObject var tweet: Tweet
    var commentsVM: CommentsViewModel? = nil
    var onCommentTap: (() -> Void)? = nil
    @State private var showCommentCompose = false
    @State private var showLoginSheet = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .error
    @State private var attachmentPreviewImage: UIImage? = nil
    @State private var isPreparingShare = false
    @State private var shareSheetItems: ShareSheetData? = nil
    @EnvironmentObject private var hproseInstance: HproseInstance

    private func handleGuestAction() {
        if hproseInstance.appUser.isGuest {
            showLoginSheet = true
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
                                toastMessage = wasFavorite ? NSLocalizedString("Failed to remove favorite. Please try again.", comment: "Remove favorite error") : NSLocalizedString("Failed to add favorite. Please try again.", comment: "Add favorite error")
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
                                toastMessage = wasBookmarked ? NSLocalizedString("Failed to remove bookmark. Please try again.", comment: "Remove bookmark error") : NSLocalizedString("Failed to add bookmark. Please try again.", comment: "Add bookmark error")
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
                guard !isPreparingShare else { return }
                Task {
                    await MainActor.run {
                        isPreparingShare = true
                    }
                    
                    print("DEBUG: [SHARE] Share button tapped for tweet: \(tweet.mid)")
                    let preview = await loadAttachmentPreviewImage()
                    
                    await MainActor.run {
                        attachmentPreviewImage = preview
                        print("DEBUG: [SHARE] Preview image loaded: \(preview != nil ? "YES" : "NO")")
                        
                        // Create the activity items with the current preview image
                        let items = shareActivityItems()
                        print("DEBUG: [SHARE] Created activity items, count: \(items.count)")
                        
                        // Set the sheet data which will trigger the sheet
                        shareSheetItems = ShareSheetData(items: items)
                        isPreparingShare = false
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 20)
                    .frame(maxWidth: .infinity, alignment: .trailing)
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
        .sheet(item: $shareSheetItems, onDismiss: {
            // Reset state when sheet is dismissed
            attachmentPreviewImage = nil
            print("DEBUG: [SHARE] Sheet dismissed, state cleared")
        }) { sheetData in
            let _ = print("DEBUG: [SHARE] Sheet presenting with \(sheetData.items.count) items")
            return ShareSheet(activityItems: sheetData.items)
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
        return CustomShareItem(shareText: shareText, tweet: tweet, previewImage: attachmentPreviewImage)
    }
    
    private func shareActivityItems() -> [Any] {
        var items: [Any] = [createCustomShareItem()]
        print("DEBUG: [SHARE] Creating share items, preview image: \(attachmentPreviewImage != nil ? "YES" : "NO")")
        if let previewImage = attachmentPreviewImage {
            items.append(CustomShareImage(image: previewImage))
            print("DEBUG: [SHARE] Added CustomShareImage to share items")
        } else {
            print("DEBUG: [SHARE] No preview image to share")
        }
        return items
    }
    
    private func cachedAttachmentBaseURL(for sourceTweet: Tweet) -> URL? {
        if let base = sourceTweet.author?.baseUrl {
            return base
        }
        let author = User.getInstance(mid: sourceTweet.authorId)
        if let base = author.baseUrl {
            return base
        }
        if let appUserBase = hproseInstance.appUser.baseUrl {
            return appUserBase
        }
        return URL(string: AppConfig.baseUrl)
    }
    
    private func loadAttachmentPreviewImage() async -> UIImage? {
        print("DEBUG: [SHARE] loadAttachmentPreviewImage called for tweet: \(tweet.mid)")
        print("DEBUG: [SHARE] Tweet has attachments: \(tweet.attachments?.count ?? 0)")
        print("DEBUG: [SHARE] Tweet originalTweetId: \(tweet.originalTweetId ?? "nil")")
        
        guard let sourceTweet = await resolveSourceTweetWithAttachments() else {
            print("DEBUG: [SHARE] No source tweet with attachments found")
            return nil
        }
        
        print("DEBUG: [SHARE] Source tweet found: \(sourceTweet.mid), attachments: \(sourceTweet.attachments?.count ?? 0)")
        
        guard let attachment = sourceTweet.attachments?.first else {
            print("DEBUG: [SHARE] No first attachment found")
            return nil
        }
        
        print("DEBUG: [SHARE] First attachment type: \(attachment.type), mid: \(attachment.mid)")
        
        let baseURL = await resolveAttachmentBaseURL(for: sourceTweet)
        print("DEBUG: [SHARE] Resolved baseURL: \(baseURL?.absoluteString ?? "nil")")
        
        switch attachment.type {
        case .image:
            print("DEBUG: [SHARE] Processing image attachment")
            if let cached = ImageCacheManager.shared.getCachedCompressedImage(forMid: attachment.mid) {
                print("DEBUG: [SHARE] Found cached image")
                return cached
            }
            if let url = resolvedAttachmentURL(for: attachment, baseURL: baseURL) {
                print("DEBUG: [SHARE] Loading image from URL: \(url.absoluteString)")
                let cacheBase = baseURL ?? url.deletingLastPathComponent()
                let image = await ImageCacheManager.shared.loadAndCacheImage(from: url, for: attachment, baseUrl: cacheBase)
                print("DEBUG: [SHARE] Image loaded: \(image != nil ? "YES" : "NO")")
                return image
            }
        case .video, .hls_video:
            print("DEBUG: [SHARE] Processing video attachment")
            if let url = resolvedAttachmentURL(for: attachment, baseURL: baseURL) {
                print("DEBUG: [SHARE] Generating video preview from URL: \(url.absoluteString)")
                let preview = await generateVideoPreviewImage(for: url)
                print("DEBUG: [SHARE] Video preview generated: \(preview != nil ? "YES" : "NO")")
                return preview
            }
        default:
            print("DEBUG: [SHARE] Attachment type not supported: \(attachment.type)")
            break
        }
        
        print("DEBUG: [SHARE] No preview image could be generated")
        return nil
    }
    
    private func resolveSourceTweetWithAttachments() async -> Tweet? {
        if let attachments = tweet.attachments, !attachments.isEmpty {
            return tweet
        }
        if let originalTweetId = tweet.originalTweetId,
           let originalAuthorId = tweet.originalAuthorId {
            if let original = Tweet.getInstance(for: originalTweetId),
               let attachments = original.attachments,
               !attachments.isEmpty {
                return original
            }
            if let original = try? await hproseInstance.getTweet(
                tweetId: originalTweetId,
                authorId: originalAuthorId
            ),
               let attachments = original.attachments,
               !attachments.isEmpty {
                return original
            }
        }
        return nil
    }
    
    private func resolveAttachmentBaseURL(for sourceTweet: Tweet) async -> URL? {
        if let cached = cachedAttachmentBaseURL(for: sourceTweet) {
            return cached
        }
        if let user = try? await hproseInstance.fetchUser(sourceTweet.authorId),
           let base = user.baseUrl {
            return base
        }
        return await MainActor.run {
            hproseInstance.appUser.baseUrl
        } ?? URL(string: AppConfig.baseUrl)
    }
    
    private func resolvedAttachmentURL(for attachment: MimeiFileType, baseURL: URL?) -> URL? {
        if let urlString = attachment.url,
           let url = URL(string: urlString),
           url.scheme != nil {
            return url
        }
        if let urlString = attachment.url,
           let base = baseURL {
            return URL(string: urlString, relativeTo: base) ?? base.appendingPathComponent(urlString)
        }
        if let baseURL = baseURL {
            return attachment.getUrl(baseURL)
        }
        return nil
    }
    
    private func generateVideoPreviewImage(for url: URL) async -> UIImage? {
        do {
            let asset = try await SharedAssetCache.shared.getAsset(for: url, tweetId: tweet.mid)
            _ = try? await asset.load(.tracks)
            
            let capturePoints: [Double] = [1.0, 0.5, 0.1]
            for seconds in capturePoints {
                if let image = try? await captureFrame(from: asset, at: seconds) {
                    return image
                }
            }
        } catch {
            print("DEBUG: Failed to load asset for preview: \(error)")
        }
        return nil
    }
    
    private func captureFrame(from asset: AVAsset, at seconds: Double) async throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let cgImage = try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
                switch result {
                case .succeeded:
                    if let image = image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: NSError(domain: "AttachmentPreview", code: -2, userInfo: nil))
                    }
                case .failed:
                    continuation.resume(throwing: error ?? NSError(domain: "AttachmentPreview", code: -3, userInfo: nil))
                case .cancelled:
                    continuation.resume(throwing: NSError(domain: "AttachmentPreview", code: -4, userInfo: nil))
                @unknown default:
                    continuation.resume(throwing: NSError(domain: "AttachmentPreview", code: -5, userInfo: nil))
                }
            }
        }
        
        return UIImage(cgImage: cgImage)
    }
    
    private func tweetShareText(_ tweet: Tweet) -> String {
        // Create a share text that includes app branding
        var shareText = ""
        
        // Priority: title > content
        if let title = tweet.title, !title.isEmpty {
            // Use title if available
            let maxLength = 40
            let truncatedTitle = title.count > maxLength ? String(title.prefix(maxLength)) + "..." : title
            shareText += truncatedTitle
        } else if let content = tweet.content, !content.isEmpty {
            // Use content if title is not available
            let maxLength = 40
            // Replace newlines with spaces in the content
            let cleanedContent = content.replacingOccurrences(of: "\n", with: " ")
            let truncatedContent = cleanedContent.count > maxLength ? String(cleanedContent.prefix(maxLength)) + "..." : cleanedContent
            shareText += truncatedContent
        }
        
        // Add two newlines after text if there is text
        if !shareText.isEmpty {
            shareText += "\n\n"
        }
        
        // Add URL
        var text = hproseInstance.domainToShare
        text.append("/tweet/\(tweet.mid)/\(tweet.authorId)")
        
        // Only add space if there's content before the URL
        if !shareText.isEmpty {
            shareText += text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            shareText += text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
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
    let previewImage: UIImage?
    
    init(shareText: String, tweet: Tweet, previewImage: UIImage?) {
        self.shareText = shareText
        self.tweet = tweet
        self.previewImage = previewImage
        super.init()
    }
    
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return shareText
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        return shareText
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        // Custom app name with bird icon using the same algorithm as share text
        var previewText = ""
        
        // Priority: title > content
        if let title = tweet.title, !title.isEmpty {
            // Use title if available
            let maxLength = 40
            let truncatedTitle = title.count > maxLength ? String(title.prefix(maxLength)) + "..." : title
            previewText = truncatedTitle
        } else if let content = tweet.content, !content.isEmpty {
            // Use content if title is not available
            let maxLength = 40
            // Replace newlines with spaces in the content
            let cleanedContent = content.replacingOccurrences(of: "\n", with: " ")
            let truncatedContent = cleanedContent.count > maxLength ? String(cleanedContent.prefix(maxLength)) + "..." : cleanedContent
            previewText = truncatedContent
        }
        
        // Add smiling face emoji prefix
        if !previewText.isEmpty {
            return "😊 Tweet: \(previewText)"
        } else {
            return "😊 Tweet"
        }
    }
    
    @available(iOS 13.0, *)
    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        
        // Set the title
        if let title = tweet.title, !title.isEmpty {
            metadata.title = title
        } else if let content = tweet.content, !content.isEmpty {
            let maxLength = 80
            let cleanedContent = content.replacingOccurrences(of: "\n", with: " ")
            metadata.title = cleanedContent.count > maxLength ? String(cleanedContent.prefix(maxLength)) + "..." : cleanedContent
        } else {
            metadata.title = "Tweet"
        }
        
        // Set the icon/thumbnail image
        if let previewImage = previewImage {
            metadata.iconProvider = NSItemProvider(object: previewImage)
            metadata.imageProvider = NSItemProvider(object: previewImage)
            print("DEBUG: [SHARE] Link metadata created with preview image")
        } else if let appIcon = UIImage(named: "ic_splash") {
            metadata.iconProvider = NSItemProvider(object: appIcon)
            print("DEBUG: [SHARE] Link metadata created with app icon fallback")
        }
        
        return metadata
    }
}

class CustomShareImage: NSObject, UIActivityItemSource {
    let image: UIImage
    
    init(image: UIImage) {
        self.image = image
        super.init()
    }
    
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return image
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        return image
    }
}
