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

// Global function to compose attachment type text
func composeAttachmentTypeText(for tweet: Tweet) -> String {
    // Get attachments from the tweet or its original tweet
    var attachments: [MimeiFileType]?
    
    if let tweetAttachments = tweet.attachments, !tweetAttachments.isEmpty {
        attachments = tweetAttachments
    } else if let originalTweetId = tweet.originalTweetId,
              let original = Tweet.getInstance(for: originalTweetId),
              let originalAttachments = original.attachments,
              !originalAttachments.isEmpty {
        attachments = originalAttachments
    }
    
    guard let attachments = attachments, !attachments.isEmpty else {
        return ""
    }
    
    // Get first 3 attachment types
    let firstThree = Array(attachments.prefix(3))
    var typeTexts: [String] = []
    
    for attachment in firstThree {
        switch attachment.type {
        case .image:
            typeTexts.append("📷 Image")
        case .video, .hls_video:
            typeTexts.append("🎬 Video")
        case .audio:
            typeTexts.append("🎵 Audio")
        case .pdf:
            typeTexts.append("📄 PDF")
        case .word:
            typeTexts.append("📝 Word")
        case .excel:
            typeTexts.append("📊 Excel")
        case .ppt:
            typeTexts.append("📊 PPT")
        case .zip:
            typeTexts.append("🗜️ Zip")
        case .txt:
            typeTexts.append("📄 Text")
        case .html:
            typeTexts.append("🌐 HTML")
        case .unknown:
            typeTexts.append("📎 File")
        }
    }
    
    // Add count if there are more attachments
    if attachments.count > 3 {
        let remaining = attachments.count - 3
        return typeTexts.joined(separator: ", ") + " +\(remaining) more"
    } else {
        return typeTexts.joined(separator: ", ")
    }
}

@available(iOS 16.0, *)
struct TweetActionButtonsView: View {
    @ObservedObject var tweet: Tweet
    var commentsVM: CommentsViewModel? = nil
    var onCommentTap: (() -> Void)? = nil
    var isInDetailView: Bool = false  // NEW: Track if we're in TweetDetailView
    var isFullScreen: Bool = false    // NEW: Track if we're in fullscreen player
    var onShareVisibilityChange: ((Bool) -> Void)? = nil
    @State private var showCommentCompose = false
    @State private var showLoginSheet = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .error
    @State private var attachmentPreviewImage: UIImage? = nil
    @State private var isPreparingShare = false
    @State private var shareSheetItems: ShareSheetData? = nil
    @State private var hasPreloadedPreview = false
    @EnvironmentObject private var hproseInstance: HproseInstance

    private func handleGuestAction() {
        if hproseInstance.appUser.isGuest {
            showLoginSheet = true
        }
    }
    
    private func preloadAttachmentPreview() {
        guard !hasPreloadedPreview else { return }
        hasPreloadedPreview = true
        
        Task {
            print("DEBUG: [SHARE] Preloading attachment preview in background")
            let preview = await loadAttachmentPreviewImage()
            await MainActor.run {
                attachmentPreviewImage = preview
                print("DEBUG: [SHARE] Background preview preloaded: \(preview != nil ? "YES" : "NO")")
            }
        }
    }
    
    private func retweet(tweetId: String, authorId: String) async throws {
        // Get the tweet instance at execution time to ensure we have the correct one
        guard let tweet = Tweet.getInstance(for: tweetId) else {
            print("❌ [Retweet] Tweet instance not found for ID: \(tweetId)")
            throw NSError(domain: "RetweetError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Tweet not found"])
        }
        
        // Verify tweet identity matches
        guard tweet.mid == tweetId && tweet.authorId == authorId else {
            print("❌ [Retweet] Tweet identity mismatch! Expected: \(tweetId)/\(authorId), Got: \(tweet.mid)/\(tweet.authorId)")
            throw NSError(domain: "RetweetError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Tweet identity mismatch"])
        }
        
        // Save original count for rollback
        let originalCount = tweet.retweetCount ?? 0
        
        print("🔄 [Retweet] Starting retweet for tweet: \(tweet.mid), current count: \(originalCount)")
        
        do {
            // Optimistic UI update - increment retweet count immediately on MainActor
            await MainActor.run {
                tweet.retweetCount = originalCount + 1
                print("🔄 [Retweet] Optimistically incremented count to: \(tweet.retweetCount ?? 0) for tweet: \(tweet.mid)")
            }
            
            // Upload the retweet and update count (matches Android flow)
            // HproseInstance.retweet() now handles:
            // 1. Upload retweet
            // 2. Update retweet count of original tweet
            // 3. Cache the updated original tweet
            print("🔄 [Retweet] Calling hproseInstance.retweet for tweet: \(tweet.mid)")
            guard let retweet = try await hproseInstance.retweet(tweet) else {
                // Retweet upload failed - rollback on MainActor
                print("❌ [Retweet] Upload failed for tweet: \(tweet.mid), rolling back")
                await MainActor.run {
                    tweet.retweetCount = originalCount
                }
                throw NSError(domain: "RetweetError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to upload retweet"])
            }
            
            print("✅ [Retweet] Retweet created with ID: \(retweet.mid) for original tweet: \(tweet.mid)")
            
            // Verify we got a valid retweet ID from server (not a temporary ID)
            // Only post notification if server actually created a retweet with valid ID
            guard !retweet.mid.isEmpty && !retweet.mid.hasPrefix("TEMP_") else {
                print("❌ [Retweet] Invalid retweet ID from server for tweet: \(tweet.mid)")
                await MainActor.run {
                    tweet.retweetCount = originalCount
                }
                throw NSError(domain: "RetweetError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid retweet ID from server"])
            }
            
            // Post notification only after confirmed successful retweet creation with valid ID
            // The original tweet's retweet count has already been updated and cached by HproseInstance.retweet()
            print("✅ [Retweet] Posting notification for new tweet created: \(retweet.mid)")
            NotificationCenter.default.post(name: .newTweetCreated,
                                            object: nil,
                                            userInfo: ["tweet": retweet])
        } catch {
            // Rollback on retweet creation failure on MainActor
            print("❌ [Retweet] Retweet failed for tweet: \(tweet.mid), error: \(error), rolling back count from \(tweet.retweetCount ?? 0) to \(originalCount)")
            await MainActor.run {
                tweet.retweetCount = originalCount
            }
            throw error
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
            Spacer(minLength: 12)
            // Retweet / forward button
            DebounceButton(
                cooldownDuration: 0.5,
                enableAnimation: true,
                enableVibration: false
            ) {
                if hproseInstance.appUser.isGuest {
                    handleGuestAction()
                } else {
                    // Capture immutable values (not object references) at button press time
                    // This prevents any issues with singleton pattern or view reuse
                    let tweetId = tweet.mid
                    let authorId = tweet.authorId
                    
                    print("🔵 [Retweet Button] Button pressed for tweet: \(tweetId), author: \(authorId)")
                    
                    Task {
                        print("🔄 [Retweet Task] Starting async task for tweet: \(tweetId), author: \(authorId)")
                        
                        do {
                            // Pass immutable values, not the tweet object
                            try await retweet(tweetId: tweetId, authorId: authorId)
                        } catch {
                            print("❌ [Retweet] Retweet failed for tweet: \(tweetId)")
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
            // Share button
            Spacer(minLength: 16)
            DebounceButton(
                cooldownDuration: 0.3,
                enableAnimation: true,
                enableVibration: false
            ) {
                Task {
                    print("DEBUG: [SHARE] Share button tapped for tweet: \(tweet.mid)")
                    
                    // If we don't have a preloaded preview, generate it now
                    if attachmentPreviewImage == nil {
                        print("DEBUG: [SHARE] No preloaded preview, generating now...")
                        
                        await MainActor.run {
                            isPreparingShare = true
                        }
                        
                        // Generate preview (will return quickly if it fails or succeeds)
                        let preview = await loadAttachmentPreviewImage()
                        
                        await MainActor.run {
                            attachmentPreviewImage = preview
                            print("DEBUG: [SHARE] Preview image generated: \(preview != nil ? "YES" : "NO")")
                        }
                    } else {
                        print("DEBUG: [SHARE] Using preloaded preview")
                    }
                    
                    // Open sheet with preview (if available)
                    await MainActor.run {
                        let items = shareActivityItems()
                        print("DEBUG: [SHARE] Opening sheet with items, count: \(items.count)")
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
            isPreparingShare = false
            print("DEBUG: [SHARE] Sheet dismissed, state cleared")
            onShareVisibilityChange?(false)
        }) { sheetData in
            let _ = print("DEBUG: [SHARE] Sheet presenting with \(sheetData.items.count) items")
            onShareVisibilityChange?(true)
            return ZStack {
                ShareSheet(activityItems: sheetData.items)
                
                // Show loading overlay if still generating preview
                if isPreparingShare {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        
                        Text("Generating preview...")
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                    .padding(32)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(16)
                }
            }
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
        .onAppear {
            // Preload attachment preview in background when view appears
            preloadAttachmentPreview()
        }
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
            // No attachment preview - use app icon as default
            if let appIcon = UIImage(named: "ic_splash") {
                items.append(CustomShareImage(image: appIcon))
                print("DEBUG: [SHARE] Added app icon as default image (no attachments)")
            } else {
                print("DEBUG: [SHARE] No preview image to share and app icon not found")
            }
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
            var fullImage: UIImage?
            
            if let cached = ImageCacheManager.shared.getCachedCompressedImage(forMid: attachment.mid) {
                print("DEBUG: [SHARE] Found cached image")
                fullImage = cached
            } else if let url = resolvedAttachmentURL(for: attachment, baseURL: baseURL) {
                print("DEBUG: [SHARE] Loading image from URL: \(url.absoluteString)")
                let cacheBase = baseURL ?? url.deletingLastPathComponent()
                fullImage = await ImageCacheManager.shared.loadAndCacheImage(from: url, for: attachment, baseUrl: cacheBase)
                print("DEBUG: [SHARE] Image loaded: \(fullImage != nil ? "YES" : "NO")")
            }
            
            // Crop to center square for preview
            if let image = fullImage {
                let croppedImage = cropToCenter(image: image)
                print("DEBUG: [SHARE] Image cropped to center")
                return croppedImage
            }
            return nil
        case .video, .hls_video:
            print("DEBUG: [SHARE] Processing video attachment, type: \(attachment.type)")
            if let url = resolvedAttachmentURL(for: attachment, baseURL: baseURL) {
                print("DEBUG: [SHARE] Generating video preview from URL: \(url.absoluteString)")
                let isHLS = attachment.type == .hls_video
                let preview = await generateVideoPreviewImage(for: url, isHLS: isHLS)
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
    
    private func generateVideoPreviewImage(for url: URL, isHLS: Bool = false) async -> UIImage? {
        print("DEBUG: [SHARE] Starting video preview generation for: \(url.absoluteString), isHLS: \(isHLS)")
        let startTime = Date()
        
        // Extract mediaID from URL
        let mediaID = extractMediaID(from: url)
        print("DEBUG: [SHARE] Extracted mediaID: \(mediaID)")
        
        // If we're in fullscreen, try to use the fullscreen singleton player first
        if isFullScreen,
           let fullPlayer = FullScreenVideoManager.shared.singletonPlayer,
           let fullItem = fullPlayer.currentItem {
            print("DEBUG: [SHARE] Fullscreen context detected, trying singleton player for preview")
            let duration = try? await fullItem.asset.load(.duration)
            if let duration = duration {
                let durationSeconds = CMTimeGetSeconds(duration)
                let currentTime = CMTimeGetSeconds(fullItem.currentTime())
                print("DEBUG: [SHARE] Fullscreen player duration: \(durationSeconds)s, currentTime: \(currentTime)s")
                
                if durationSeconds > 0 && !durationSeconds.isNaN && !durationSeconds.isInfinite {
                    let captureTime = currentTime > 0.1 ? currentTime : min(1.0, durationSeconds * 0.1)
                    print("DEBUG: [SHARE] Capturing fullscreen frame at \(captureTime)s")
                    if let image = await captureFrameFromPlayer(fullPlayer, at: captureTime) {
                        let elapsed = Date().timeIntervalSince(startTime)
                        print("DEBUG: [SHARE] Fullscreen preview generated from singleton player in \(elapsed)s")
                        return image
                    }
                }
            }
        }
        
        // Determine the cache key to use based on context
        // When in TweetDetailView, the player is cached with "tweetDetail_\(mid)" key
        let cacheKey: String
        if isInDetailView {
            cacheKey = "tweetDetail_\(mediaID)"
            print("DEBUG: [SHARE] In TweetDetailView context, using cache key: \(cacheKey)")
        } else {
            cacheKey = mediaID
            print("DEBUG: [SHARE] In feed/grid context, using cache key: \(cacheKey)")
        }
        
        // For HLS videos, try to use cached player first
        if isHLS {
            print("DEBUG: [SHARE] HLS video detected, checking for cached player with key: \(cacheKey)...")
            if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: cacheKey),
               let playerItem = cachedPlayer.currentItem {
                print("DEBUG: [SHARE] Found cached player for HLS video")
                
                // Check if player has buffered data
                let hasBufferedData = !playerItem.loadedTimeRanges.isEmpty
                print("DEBUG: [SHARE] Cached player has buffered data: \(hasBufferedData)")
                
                if hasBufferedData && playerItem.status == .readyToPlay {
                    let duration = try? await playerItem.asset.load(.duration)
                    if let duration = duration {
                        let durationSeconds = CMTimeGetSeconds(duration)
                        print("DEBUG: [SHARE] Using cached HLS player, duration: \(durationSeconds)s")
                        
                        if durationSeconds > 0 && !durationSeconds.isNaN && !durationSeconds.isInfinite {
                            // Get current playback position
                            let currentTime = CMTimeGetSeconds(playerItem.currentTime())
                            print("DEBUG: [SHARE] Current playback position: \(String(format: "%.2f", currentTime))s")
                            
                            // Use current position, or fallback to 1s if at beginning
                            let captureTime = currentTime > 0.1 ? currentTime : min(1.0, durationSeconds * 0.1)
                            print("DEBUG: [SHARE] Capturing frame at \(String(format: "%.2f", captureTime))s")
                            
                            // Capture the frame at current position
                            if let image = await captureFrameFromPlayer(cachedPlayer, at: captureTime) {
                                let elapsed = Date().timeIntervalSince(startTime)
                                print("DEBUG: [SHARE] HLS preview generated from player in \(String(format: "%.2f", elapsed))s")
                                return image
                            }
                        }
                    }
                }
            }
            print("DEBUG: [SHARE] No usable cached player for HLS video, skipping preview")
            return nil
        }
        
        // For regular videos, try to use cached player first to get current position
        if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: cacheKey),
           let playerItem = cachedPlayer.currentItem {
            print("DEBUG: [SHARE] Found cached player for regular video with key: \(cacheKey)")
            
            let currentTime = CMTimeGetSeconds(playerItem.currentTime())
            print("DEBUG: [SHARE] Current playback position: \(String(format: "%.2f", currentTime))s")
            
            let duration = try? await playerItem.asset.load(.duration)
            if let duration = duration {
                let durationSeconds = CMTimeGetSeconds(duration)
                
                if durationSeconds > 0 && !durationSeconds.isNaN && !durationSeconds.isInfinite {
                    // Use current position, or fallback to 1s if at beginning
                    let captureTime = currentTime > 0.1 ? currentTime : min(1.0, durationSeconds * 0.1)
                    print("DEBUG: [SHARE] Capturing frame at \(String(format: "%.2f", captureTime))s")
                    
                    if let image = await captureFrameFromPlayer(cachedPlayer, at: captureTime) {
                        let elapsed = Date().timeIntervalSince(startTime)
                        print("DEBUG: [SHARE] Regular video preview generated from player in \(String(format: "%.2f", elapsed))s")
                        return image
                    }
                }
            }
        }
        
        // Fallback: use asset loading if no cached player
        do {
            let asset = try await SharedAssetCache.shared.getAsset(for: url, tweetId: tweet.mid)
            
            // Load duration and tracks to ensure video is ready
            async let durationLoad = asset.load(.duration)
            async let tracksLoad = asset.load(.tracks)
            
            let (duration, tracks) = try await (durationLoad, tracksLoad)
            let durationSeconds = CMTimeGetSeconds(duration)
            
            print("DEBUG: [SHARE] Video duration: \(durationSeconds)s, tracks: \(tracks.count)")
            
            // Check if video has valid duration
            guard durationSeconds > 0 && !durationSeconds.isNaN && !durationSeconds.isInfinite else {
                print("DEBUG: [SHARE] Invalid video duration: \(durationSeconds)")
                return nil
            }
            
            // Check if video has tracks
            guard !tracks.isEmpty else {
                print("DEBUG: [SHARE] Video has no tracks, cannot generate preview")
                return nil
            }
            
            // Fallback: Capture at 1 second, or at 10% of duration if video is shorter than 10 seconds
            let captureTime = min(1.0, durationSeconds * 0.1)
            print("DEBUG: [SHARE] Attempting fallback capture at \(String(format: "%.2f", captureTime))s")
            
            if let image = try? await captureFrame(from: asset, at: captureTime) {
                let elapsed = Date().timeIntervalSince(startTime)
                print("DEBUG: [SHARE] Video preview generated successfully at \(String(format: "%.2f", captureTime))s in \(String(format: "%.2f", elapsed))s")
                return image
            }
            
            print("DEBUG: [SHARE] Failed to capture frame at \(String(format: "%.2f", captureTime))s")
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            print("DEBUG: [SHARE] Failed to load asset for preview after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription)")
        }
        return nil
    }
    
    private func extractMediaID(from url: URL) -> String {
        // Extract mediaID from URL path
        // Format: http://baseurl/ipfs/MEDIAID or http://baseurl/ipfs/MEDIAID/master.m3u8
        let pathComponents = url.pathComponents
        if let ipfsIndex = pathComponents.firstIndex(of: "ipfs"),
           ipfsIndex + 1 < pathComponents.count {
            return pathComponents[ipfsIndex + 1]
        }
        // Fallback: use last path component
        return url.lastPathComponent
    }
    
    private func captureFrameFromPlayer(_ player: AVPlayer, at seconds: Double) async -> UIImage? {
        print("DEBUG: [SHARE] Attempting to capture frame from player at \(seconds)s")
        
        guard let playerItem = player.currentItem else {
            print("DEBUG: [SHARE] Player has no current item")
            return nil
        }
        
        // Create video output to extract frames
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        
        // Add output to player item
        playerItem.add(videoOutput)
        defer {
            playerItem.remove(videoOutput)
        }
        
        // Seek to the desired time
        let targetTime = CMTime(seconds: seconds, preferredTimescale: 600)
        await player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        
        // Wait a bit for the seek to complete and frame to be ready
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Get the current time after seek
        let currentTime = playerItem.currentTime()
        print("DEBUG: [SHARE] Player seeked to: \(CMTimeGetSeconds(currentTime))s")
        
        // Check if we have a pixel buffer at this time
        guard videoOutput.hasNewPixelBuffer(forItemTime: currentTime) else {
            print("DEBUG: [SHARE] No pixel buffer available at current time")
            return nil
        }
        
        // Copy the pixel buffer
        guard let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) else {
            print("DEBUG: [SHARE] Failed to copy pixel buffer")
            return nil
        }
        
        // Convert pixel buffer to UIImage without alpha channel
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            print("DEBUG: [SHARE] Failed to create CGImage from pixel buffer")
            return nil
        }
        
        // Convert to UIImage and remove alpha channel to avoid iOS warning
        let image = UIImage(cgImage: cgImage)
        
        // Re-render without alpha channel
        UIGraphicsBeginImageContextWithOptions(image.size, true, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let imageWithoutAlpha = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        guard let cleanImage = imageWithoutAlpha else {
            print("DEBUG: [SHARE] Failed to remove alpha channel, using original")
            return cropToCenter(image: image, targetSize: 270)
        }
        
        // Crop to center and resize to 270x270
        let croppedImage = cropToCenter(image: cleanImage, targetSize: 270)
        
        print("DEBUG: [SHARE] Successfully captured and cropped frame from player to 270x270")
        return croppedImage
    }
    
    private func captureFrame(from asset: AVAsset, at seconds: Double) async throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        
        print("DEBUG: [SHARE] Generating CGImage at time: \(seconds)s")
        
        let cgImage = try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { requestedTime, image, actualTime, result, error in
                print("DEBUG: [SHARE] Frame generation result: \(result.rawValue), requested: \(CMTimeGetSeconds(requestedTime)), actual: \(CMTimeGetSeconds(actualTime))")
                
                switch result {
                case .succeeded:
                    if let image = image {
                        print("DEBUG: [SHARE] CGImage generated successfully")
                        continuation.resume(returning: image)
                    } else {
                        print("DEBUG: [SHARE] CGImage generation succeeded but image is nil")
                        continuation.resume(throwing: NSError(domain: "AttachmentPreview", code: -2, userInfo: [NSLocalizedDescriptionKey: "Image is nil"]))
                    }
                case .failed:
                    let errorDesc = error?.localizedDescription ?? "Unknown error"
                    print("DEBUG: [SHARE] CGImage generation failed: \(errorDesc)")
                    continuation.resume(throwing: error ?? NSError(domain: "AttachmentPreview", code: -3, userInfo: [NSLocalizedDescriptionKey: "Generation failed"]))
                case .cancelled:
                    print("DEBUG: [SHARE] CGImage generation cancelled")
                    continuation.resume(throwing: NSError(domain: "AttachmentPreview", code: -4, userInfo: [NSLocalizedDescriptionKey: "Cancelled"]))
                @unknown default:
                    print("DEBUG: [SHARE] CGImage generation unknown result")
                    continuation.resume(throwing: NSError(domain: "AttachmentPreview", code: -5, userInfo: [NSLocalizedDescriptionKey: "Unknown result"]))
                }
            }
        }
        
        print("DEBUG: [SHARE] Creating UIImage from CGImage")
        let image = UIImage(cgImage: cgImage)
        
        // Re-render without alpha channel to avoid iOS warning, then crop
        UIGraphicsBeginImageContextWithOptions(image.size, true, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let imageWithoutAlpha = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        guard let cleanImage = imageWithoutAlpha else {
            print("DEBUG: [SHARE] Failed to remove alpha, using original")
            return cropToCenter(image: image, targetSize: 270)
        }
        
        // Crop to center and resize to 270x270
        let croppedImage = cropToCenter(image: cleanImage, targetSize: 270)
        
        print("DEBUG: [SHARE] Video frame cropped and resized to 270x270")
        return croppedImage
    }
    
    private func cropToCenter(image: UIImage, targetSize: CGFloat = 270) -> UIImage {
        let size = image.size
        let scale = image.scale
        
        // Determine the crop size (square based on the shorter dimension)
        let cropSize = min(size.width, size.height)
        
        // Calculate the crop rect (centered)
        let cropRect = CGRect(
            x: (size.width - cropSize) / 2,
            y: (size.height - cropSize) / 2,
            width: cropSize,
            height: cropSize
        )
        
        // Create a scaled crop rect for the CGImage
        let scaledCropRect = CGRect(
            x: cropRect.origin.x * scale,
            y: cropRect.origin.y * scale,
            width: cropRect.size.width * scale,
            height: cropRect.size.height * scale
        )
        
        guard let cgImage = image.cgImage?.cropping(to: scaledCropRect) else {
            return image
        }
        
        let croppedImage = UIImage(cgImage: cgImage, scale: scale, orientation: image.imageOrientation)
        
        // Resize to target size (270x270)
        let targetRect = CGRect(x: 0, y: 0, width: targetSize, height: targetSize)
        UIGraphicsBeginImageContextWithOptions(CGSize(width: targetSize, height: targetSize), true, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        croppedImage.draw(in: targetRect)
        guard let resizedImage = UIGraphicsGetImageFromCurrentImageContext() else {
            return croppedImage
        }
        
        return resizedImage
    }
    
    private func composeAttachmentTypeText(for tweet: Tweet) -> String {
        // Get attachments from the tweet or its original tweet
        var attachments: [MimeiFileType]?
        
        if let tweetAttachments = tweet.attachments, !tweetAttachments.isEmpty {
            attachments = tweetAttachments
        } else if let originalTweetId = tweet.originalTweetId,
                  let original = Tweet.getInstance(for: originalTweetId),
                  let originalAttachments = original.attachments,
                  !originalAttachments.isEmpty {
            attachments = originalAttachments
        }
        
        guard let attachments = attachments, !attachments.isEmpty else {
            return ""
        }
        
        // Get first 3 attachment types
        let firstThree = Array(attachments.prefix(3))
        var typeTexts: [String] = []
        
        for attachment in firstThree {
            switch attachment.type {
            case .image:
                typeTexts.append("📷 Image")
            case .video, .hls_video:
                typeTexts.append("🎬 Video")
            case .audio:
                typeTexts.append("🎵 Audio")
            case .pdf:
                typeTexts.append("📄 PDF")
            case .word:
                typeTexts.append("📝 Word")
            case .excel:
                typeTexts.append("📊 Excel")
            case .ppt:
                typeTexts.append("📊 PPT")
            case .zip:
                typeTexts.append("🗜️ Zip")
            case .txt:
                typeTexts.append("📄 Text")
            case .html:
                typeTexts.append("🌐 HTML")
            case .unknown:
                typeTexts.append("📎 File")
            }
        }
        
        // Add count if there are more attachments
        if attachments.count > 3 {
            let remaining = attachments.count - 3
            return typeTexts.joined(separator: ", ") + " +\(remaining) more"
        } else {
            return typeTexts.joined(separator: ", ")
        }
    }
    
    private func tweetShareText(_ tweet: Tweet) -> String {
        // Create a share text that includes app branding
        var shareText = ""
        
        // Priority: title > content > attachment types
        if let title = tweet.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Use title if available
            let maxLength = 40
            let truncatedTitle = title.count > maxLength ? String(title.prefix(maxLength)) + "..." : title
            shareText += truncatedTitle
        } else if let content = tweet.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Use content if title is not available
            let maxLength = 40
            // Replace newlines with spaces in the content
            let cleanedContent = content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let truncatedContent = cleanedContent.count > maxLength ? String(cleanedContent.prefix(maxLength)) + "..." : cleanedContent
            shareText += truncatedContent
        } else {
            // No title or content, use attachment types
            shareText += composeAttachmentTypeText(for: tweet)
        }
        
        // Add two newlines after text if there is text
        if !shareText.isEmpty {
            shareText += "\n\n"
        }
        
        // Add URL - use different format based on context
        let urlText: String
        if isInDetailView {
            // In detail view: use author's baseUrl with entry format
            let baseUrlString = tweet.author?.baseUrl?.absoluteString ?? AppConfig.baseUrl
            urlText = "\(baseUrlString)/entry?aid=\(AppConfig.appIdHash)&ver=last#/tweet/\(tweet.mid)/\(tweet.authorId)"
        } else {
            // In feed/grid: use traditional format
            var text = hproseInstance.domainToShare
            text.append("/tweet/\(tweet.mid)/\(tweet.authorId)")
            urlText = text
        }
        
        // Only add space if there's content before the URL
        if !shareText.isEmpty {
            shareText += urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            shareText += urlText.trimmingCharacters(in: .whitespacesAndNewlines)
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
        
        // Priority: title > content > attachment types
        if let title = tweet.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Use title if available
            let maxLength = 40
            let truncatedTitle = title.count > maxLength ? String(title.prefix(maxLength)) + "..." : title
            previewText = truncatedTitle
            print("DEBUG: [SHARE] Subject from title: \(truncatedTitle)")
        } else if let content = tweet.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Use content if title is not available
            let maxLength = 40
            // Replace newlines with spaces in the content
            let cleanedContent = content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let truncatedContent = cleanedContent.count > maxLength ? String(cleanedContent.prefix(maxLength)) + "..." : cleanedContent
            previewText = truncatedContent
            print("DEBUG: [SHARE] Subject from content: \(truncatedContent)")
        } else {
            // No title or content, use attachment types
            previewText = composeAttachmentTypeText(for: tweet)
            print("DEBUG: [SHARE] Subject from attachments: '\(previewText)'")
        }
        
        // Add smiling face emoji prefix
        if !previewText.isEmpty {
            let result = "😊 Tweet: \(previewText)"
            print("DEBUG: [SHARE] Final subject: \(result)")
            return result
        } else {
            print("DEBUG: [SHARE] Final subject: 😊 Tweet (fallback)")
            return "😊 Tweet"
        }
    }
    
    @available(iOS 13.0, *)
    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        
        print("DEBUG: [SHARE] Creating link metadata for tweet: \(tweet.mid)")
        print("DEBUG: [SHARE] Tweet title: '\(tweet.title ?? "nil")'")
        print("DEBUG: [SHARE] Tweet content: '\(tweet.content ?? "nil")'")
        print("DEBUG: [SHARE] Tweet attachments count: \(tweet.attachments?.count ?? 0)")
        
        // Set the title
        if let title = tweet.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata.title = title
            print("DEBUG: [SHARE] Link metadata title from tweet title: \(title)")
        } else if let content = tweet.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let maxLength = 80
            let cleanedContent = content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let truncated = cleanedContent.count > maxLength ? String(cleanedContent.prefix(maxLength)) + "..." : cleanedContent
            metadata.title = truncated
            print("DEBUG: [SHARE] Link metadata title from tweet content: \(truncated)")
        } else {
            // No title or content, compose from first 3 attachment types
            let attachmentText = composeAttachmentTypeText(for: tweet)
            metadata.title = attachmentText.isEmpty ? nil : attachmentText
            print("DEBUG: [SHARE] Link metadata title from attachments: '\(attachmentText)'")
            print("DEBUG: [SHARE] Final metadata.title value: '\(metadata.title ?? "nil")'")
        }
        
        // Set the icon/thumbnail image
        if let previewImage = previewImage {
            metadata.iconProvider = NSItemProvider(object: previewImage)
            metadata.imageProvider = NSItemProvider(object: previewImage)
            print("DEBUG: [SHARE] Link metadata created with preview image")
        } else if let appIcon = UIImage(named: "ic_splash") {
            // No attachments - use app icon as default
            metadata.iconProvider = NSItemProvider(object: appIcon)
            metadata.imageProvider = NSItemProvider(object: appIcon)
            print("DEBUG: [SHARE] Link metadata created with app icon fallback (no attachments)")
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
