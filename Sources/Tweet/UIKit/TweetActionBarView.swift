//
//  TweetActionBarView.swift
//  Tweet
//
//  Pure UIKit action bar replacing SwiftUI TweetActionButtonsView.
//  5 buttons: comment, retweet, like, bookmark, share.
//  Business logic (optimistic updates, server sync) ported from TweetActionButtonsView.swift.
//
import UIKit
import SwiftUI
import Combine
import AVFoundation

class TweetActionBarView: UIView {

    // MARK: - Action Buttons

    private let commentButton = ActionButtonView(icon: "bubble.left", pointSize: 16)
    private let retweetButton = ActionButtonView(icon: "arrow.2.squarepath", pointSize: 18)
    private let likeButton = ActionButtonView(icon: "heart", pointSize: 18)
    private let bookmarkButton = ActionButtonView(icon: "bookmark", pointSize: 18)
    private let shareButton: UIButton = {
        let btn = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 14)
        btn.setImage(UIImage(systemName: "square.and.arrow.up", withConfiguration: config), for: .normal)
        btn.tintColor = UIColor(named: "ThemeSecondaryText") ?? .secondaryLabel
        btn.contentHorizontalAlignment = .trailing
        return btn
    }()
    private let shareSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        return spinner
    }()

    // MARK: - State

    private var cancellables = Set<AnyCancellable>()
    private weak var currentTweet: Tweet?
    private var currentTweetId: String?
    private var hproseInstance: HproseInstance?

    // Debounce tracking
    private var lastCommentTime: Date = .distantPast
    private var lastRetweetTime: Date = .distantPast
    private var lastLikeTime: Date = .distantPast
    private var lastBookmarkTime: Date = .distantPast
    private var lastShareTime: Date = .distantPast
    private let cooldown: TimeInterval = 0.5

    // Callbacks
    var onCommentTap: (() -> Void)?
    var onShowLogin: (() -> Void)?
    var onShowToast: ((String, Bool) -> Void)? // (message, isError)
    var onShareVisibilityChange: ((Bool) -> Void)?
    weak var parentViewController: UIViewController?

    // Context
    var isInDetailView = false
    weak var parentTweet: Tweet?       // For comments: the parent tweet this is a comment on
    weak var commentsVMParentTweet: Tweet?  // Fallback: commentsVM?.parentTweet

    // Share state
    private var attachmentPreviewImage: UIImage?
    private var isPreparingShare = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Consume all taps within the action bar so they never fall through to the cell.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        if let hit = super.hitTest(point, with: event) { return hit }
        return self
    }

    private func setupViews() {
        let tintColor = UIColor(named: "ThemeSecondaryText") ?? .secondaryLabel
        commentButton.tintColor = tintColor
        retweetButton.tintColor = tintColor
        likeButton.tintColor = tintColor
        bookmarkButton.tintColor = tintColor

        // Left group: first 4 buttons equally distributed
        let leftStack = UIStackView(arrangedSubviews: [commentButton, retweetButton, likeButton, bookmarkButton])
        leftStack.axis = .horizontal
        leftStack.distribution = .fillEqually
        leftStack.alignment = .center

        // Share button container (alone at right) — button fills container for large tap area
        let shareContainer = UIView()
        shareContainer.addSubview(shareButton)
        shareContainer.addSubview(shareSpinner)
        shareButton.translatesAutoresizingMaskIntoConstraints = false
        shareSpinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            shareButton.topAnchor.constraint(equalTo: shareContainer.topAnchor),
            shareButton.leadingAnchor.constraint(equalTo: shareContainer.leadingAnchor),
            shareButton.trailingAnchor.constraint(equalTo: shareContainer.trailingAnchor, constant: -4),
            shareButton.bottomAnchor.constraint(equalTo: shareContainer.bottomAnchor),
            shareSpinner.centerYAnchor.constraint(equalTo: shareContainer.centerYAnchor),
            shareSpinner.trailingAnchor.constraint(equalTo: shareContainer.trailingAnchor, constant: -4),
        ])

        addSubview(leftStack)
        addSubview(shareContainer)

        leftStack.translatesAutoresizingMaskIntoConstraints = false
        shareContainer.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            leftStack.topAnchor.constraint(equalTo: topAnchor),
            leftStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            shareContainer.topAnchor.constraint(equalTo: topAnchor),
            shareContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            shareContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Left 80%, share 20% with padding gap between them
            leftStack.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.80),
            shareContainer.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.20),

            heightAnchor.constraint(equalToConstant: 30),
        ])

        // Button actions
        commentButton.onTap = { [weak self] in self?.handleComment() }
        retweetButton.onTap = { [weak self] in self?.handleRetweet() }
        likeButton.onTap = { [weak self] in self?.handleLike() }
        bookmarkButton.onTap = { [weak self] in self?.handleBookmark() }
        shareButton.addTarget(self, action: #selector(handleShare), for: .touchUpInside)
    }

    // MARK: - Configure

    func configure(tweet: Tweet, hproseInstance: HproseInstance) {
        self.hproseInstance = hproseInstance
        self.currentTweet = tweet

        if currentTweetId == tweet.mid {
            // Same tweet - just update counts (Combine handles it)
            return
        }
        currentTweetId = tweet.mid
        cancellables.removeAll()

        // Set initial values
        updateCounts(tweet: tweet)
        updateIcons(tweet: tweet)

        // Subscribe to count changes
        tweet.$commentCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.commentButton.setCount(count ?? 0)
            }
            .store(in: &cancellables)

        tweet.$retweetCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.retweetButton.setCount(count ?? 0)
            }
            .store(in: &cancellables)

        tweet.$favoriteCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.likeButton.setCount(count ?? 0)
            }
            .store(in: &cancellables)

        tweet.$bookmarkCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.bookmarkButton.setCount(count ?? 0)
            }
            .store(in: &cancellables)

        tweet.$favorites
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let tweet = self?.currentTweet else { return }
                self?.updateIcons(tweet: tweet)
            }
            .store(in: &cancellables)
    }

    private func updateCounts(tweet: Tweet) {
        commentButton.setCount(tweet.commentCount ?? 0)
        retweetButton.setCount(tweet.retweetCount ?? 0)
        likeButton.setCount(tweet.favoriteCount ?? 0)
        bookmarkButton.setCount(tweet.bookmarkCount ?? 0)
    }

    private func updateIcons(tweet: Tweet) {
        let isFavorite = tweet.favorites?[UserActions.FAVORITE.rawValue] ?? false
        likeButton.setIcon(isFavorite ? "heart.fill" : "heart")
        if isFavorite {
            likeButton.tintColor = .systemRed
        } else {
            likeButton.tintColor = UIColor(named: "ThemeSecondaryText") ?? .secondaryLabel
        }

        let isBookmarked = tweet.favorites?[UserActions.BOOKMARK.rawValue] ?? false
        bookmarkButton.setIcon(isBookmarked ? "bookmark.fill" : "bookmark")
        if isBookmarked {
            bookmarkButton.tintColor = .systemBlue
        } else {
            bookmarkButton.tintColor = UIColor(named: "ThemeSecondaryText") ?? .secondaryLabel
        }
    }

    // MARK: - Action Handlers

    private func debounce(_ lastTime: inout Date) -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastTime) > cooldown else { return false }
        lastTime = now
        return true
    }

    private func handleComment() {
        guard debounce(&lastCommentTime) else { return }
        guard let hproseInstance, !hproseInstance.appUser.isGuest else {
            onShowLogin?()
            return
        }

        // If callback is set, use it; otherwise present comment composer
        if let onCommentTap = onCommentTap {
            onCommentTap()
        } else if let tweet = currentTweet, let parentVC = parentViewController {
            // Present comment composer
            let commentsVM = CommentsViewModel(hproseInstance: hproseInstance, parentTweet: tweet)
            let commentCompose = CommentComposeView(tweet: tweet, commentsVM: commentsVM)
                .environmentObject(hproseInstance)
            let hostingController = UIHostingController(rootView: commentCompose)

            // Register overlay
            OverlayVisibilityCoordinator.shared.beginOverlay(id: "commentCompose_\(tweet.mid)", source: "TweetActionBarView")

            // Present modally
            parentVC.present(hostingController, animated: true)

            // Observe dismissal to clean up overlay
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self = self, let tweet = self.currentTweet else { return }
                if parentVC.presentedViewController == nil {
                    Task { @MainActor in
                        OverlayVisibilityCoordinator.shared.endOverlay(id: "commentCompose_\(tweet.mid)", source: "TweetActionBarView")
                    }
                }
            }
        }
    }

    private func handleRetweet() {
        guard debounce(&lastRetweetTime) else { return }
        guard let hproseInstance, !hproseInstance.appUser.isGuest else {
            onShowLogin?()
            return
        }
        guard let tweet = currentTweet else { return }

        let originalCount = tweet.retweetCount ?? 0

        // Optimistic update
        tweet.retweetCount = originalCount + 1

        Task {
            do {
                guard let retweet = try await hproseInstance.retweet(tweet) else {
                    if let refreshed = try? await hproseInstance.refreshTweet(tweetId: tweet.mid, authorId: tweet.authorId) {
                        await MainActor.run { try? tweet.update(from: refreshed) }
                    }
                    throw NSError(domain: "RetweetError", code: -1)
                }

                guard !retweet.mid.isEmpty && !retweet.mid.hasPrefix("TEMP_") else {
                    if let refreshed = try? await hproseInstance.refreshTweet(tweetId: tweet.mid, authorId: tweet.authorId) {
                        await MainActor.run { try? tweet.update(from: refreshed) }
                    }
                    throw NSError(domain: "RetweetError", code: -1)
                }

                // Refresh original tweet counts
                if let refreshed = try? await hproseInstance.refreshTweet(tweetId: tweet.mid, authorId: tweet.authorId) {
                    await MainActor.run {
                        if let existing = Tweet.getInstance(for: tweet.mid) {
                            try? existing.update(from: refreshed)
                        }
                    }
                }

                NotificationCenter.default.post(name: .newTweetCreated, object: nil,
                                                 userInfo: ["tweet": retweet])
            } catch {
                if let refreshed = try? await hproseInstance.refreshTweet(tweetId: tweet.mid, authorId: tweet.authorId) {
                    await MainActor.run { try? tweet.update(from: refreshed) }
                }
                await MainActor.run {
                    self.onShowToast?(ErrorMessageHelper.userFriendlyMessage(from: error), true)
                }
            }
        }
    }

    private func handleLike() {
        guard debounce(&lastLikeTime) else { return }
        guard let hproseInstance, !hproseInstance.appUser.isGuest else {
            onShowLogin?()
            return
        }
        guard let tweet = currentTweet else { return }

        let wasFavorite = tweet.favorites?[UserActions.FAVORITE.rawValue] ?? false
        let originalFavoriteCount = tweet.favoriteCount ?? 0
        let originalAppUserFavoriteCount = hproseInstance.appUser.favoritesCount ?? 0
        let originalFavorites = tweet.favorites

        // Optimistic update
        var newFavorites = tweet.favorites ?? [false, false, false]
        newFavorites[UserActions.FAVORITE.rawValue] = !wasFavorite
        tweet.favorites = newFavorites
        tweet.favoriteCount = originalFavoriteCount + (wasFavorite ? -1 : 1)
        hproseInstance.appUser.favoritesCount = originalAppUserFavoriteCount + (wasFavorite ? -1 : 1)

        Task {
            do {
                let (updatedTweet, updatedUser) = try await hproseInstance.toggleFavorite(tweet)

                if let updatedUser {
                    await MainActor.run {
                        hproseInstance.appUser.favoritesCount = updatedUser.favoritesCount
                        hproseInstance.appUser.favoriteTweets = updatedUser.favoriteTweets
                    }
                }
                if let updatedTweet {
                    await MainActor.run {
                        tweet.favorites = updatedTweet.favorites
                        tweet.favoriteCount = updatedTweet.favoriteCount
                    }
                    let notificationName: Notification.Name = wasFavorite ? .favoriteRemoved : .favoriteAdded
                    NotificationCenter.default.post(name: notificationName, object: nil,
                                                     userInfo: ["tweet": updatedTweet])
                }
            } catch {
                print("DEBUG: [handleLike] toggleFavorite failed: \(error)")
                await MainActor.run {
                    tweet.favorites = originalFavorites
                    tweet.favoriteCount = originalFavoriteCount
                    hproseInstance.appUser.favoritesCount = originalAppUserFavoriteCount
                    let msg = wasFavorite
                        ? NSLocalizedString("Failed to remove favorite. Please try again.", comment: "")
                        : NSLocalizedString("Failed to add favorite. Please try again.", comment: "")
                    print("DEBUG: [handleLike] Showing toast: \(msg)")
                    self.onShowToast?(msg, true)
                }
            }
        }
    }

    private func handleBookmark() {
        guard debounce(&lastBookmarkTime) else { return }
        guard let hproseInstance, !hproseInstance.appUser.isGuest else {
            onShowLogin?()
            return
        }
        guard let tweet = currentTweet else { return }

        let wasBookmarked = tweet.favorites?[UserActions.BOOKMARK.rawValue] ?? false
        let originalBookmarkCount = tweet.bookmarkCount ?? 0
        let originalAppUserBookmarkCount = hproseInstance.appUser.bookmarksCount ?? 0
        let originalFavorites = tweet.favorites

        // Optimistic update
        var newFavorites = tweet.favorites ?? [false, false, false]
        newFavorites[UserActions.BOOKMARK.rawValue] = !wasBookmarked
        tweet.favorites = newFavorites
        tweet.bookmarkCount = originalBookmarkCount + (wasBookmarked ? -1 : 1)
        hproseInstance.appUser.bookmarksCount = originalAppUserBookmarkCount + (wasBookmarked ? -1 : 1)

        Task {
            do {
                let (updatedTweet, updatedUser) = try await hproseInstance.toggleBookmark(tweet)

                if let updatedUser {
                    await MainActor.run {
                        hproseInstance.appUser.bookmarksCount = updatedUser.bookmarksCount
                        hproseInstance.appUser.bookmarkedTweets = updatedUser.bookmarkedTweets
                    }
                }
                if let updatedTweet {
                    await MainActor.run {
                        tweet.favorites = updatedTweet.favorites
                        tweet.bookmarkCount = updatedTweet.bookmarkCount
                    }
                    let notificationName: Notification.Name = wasBookmarked ? .bookmarkRemoved : .bookmarkAdded
                    NotificationCenter.default.post(name: notificationName, object: nil,
                                                     userInfo: ["tweet": updatedTweet])
                }
            } catch {
                print("DEBUG: [handleBookmark] toggleBookmark failed: \(error)")
                await MainActor.run {
                    tweet.favorites = originalFavorites
                    tweet.bookmarkCount = originalBookmarkCount
                    hproseInstance.appUser.bookmarksCount = originalAppUserBookmarkCount
                    let msg = wasBookmarked
                        ? NSLocalizedString("Failed to remove bookmark. Please try again.", comment: "")
                        : NSLocalizedString("Failed to add bookmark. Please try again.", comment: "")
                    print("DEBUG: [handleBookmark] Showing toast: \(msg)")
                    self.onShowToast?(msg, true)
                }
            }
        }
    }

    @objc private func handleShare() {
        guard debounce(&lastShareTime) else { return }
        guard let tweet = currentTweet, let hprose = hproseInstance else { return }

        isPreparingShare = true
        shareSpinner.startAnimating()
        shareButton.alpha = 0.3

        // Capture the current video frame BEFORE overlay pauses the video.
        // The MediaCellUIView already has an AVPlayerItemVideoOutput attached to the player,
        // so we can grab the pixel buffer synchronously via playerItem.outputs.
        captureVideoFrameBeforePause(for: tweet)

        // Register overlay for video coordination
        OverlayVisibilityCoordinator.shared.beginOverlay(id: "shareSheet_\(tweet.mid)", source: "TweetActionBarView")

        // If in detail view, pause the video explicitly
        if isInDetailView {
            DetailVideoManager.shared.pausePlayer()
        }

        Task {
            print("DEBUG: [SHARE] Share button tapped for tweet: \(tweet.mid)")

            // If sharing from detail view, resolve IPv4 for better compatibility
            if isInDetailView {
                _ = await Self.getIPv4PreferredBaseUrl(for: tweet, hproseInstance: hprose)
            }

            // Load attachment preview if available
            if attachmentPreviewImage == nil {
                print("DEBUG: [SHARE] Loading attachment preview...")
                let preview = await loadAttachmentPreviewImage(for: tweet, hproseInstance: hprose)
                await MainActor.run {
                    self.attachmentPreviewImage = preview
                    print("DEBUG: [SHARE] Preview image loaded: \(preview != nil ? "YES" : "NO")")
                }
            }

            // Create share items with preview
            let shareItems = await buildShareItems(for: tweet, hproseInstance: hprose)

            await MainActor.run {
                self.isPreparingShare = false
                self.shareSpinner.stopAnimating()
                self.shareButton.alpha = 1.0

                let activityVC = UIActivityViewController(activityItems: shareItems, applicationActivities: nil)

                activityVC.completionWithItemsHandler = { [weak self] _, _, _, _ in
                    guard let self = self else { return }
                    // Clean up
                    self.attachmentPreviewImage = nil
                    self.onShareVisibilityChange?(false)
                    OverlayVisibilityCoordinator.shared.endOverlay(id: "shareSheet_\(tweet.mid)", source: "TweetActionBarView")

                    // Reload visible videos after share sheet dismisses (with delay for overlay state to propagate)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        OverlayVisibilityCoordinator.shared.verifyConsistency(source: "TweetActionBarView share dismiss")
                        NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)
                        print("DEBUG: [SHARE] Posted reloadVisibleVideosOnly after share sheet dismissed")
                    }
                }

                // Re-resolve parentViewController if it became nil (weak reference)
                let vc = self.parentViewController ?? self.findViewController()
                if let vc = vc {
                    self.parentViewController = vc
                    if let popover = activityVC.popoverPresentationController {
                        popover.sourceView = self.shareButton
                        popover.sourceRect = self.shareButton.bounds
                    }
                    vc.present(activityVC, animated: true)
                    self.onShareVisibilityChange?(true)
                } else {
                    // Presentation failed - clean up overlay
                    print("DEBUG: [SHARE] No parentViewController found, cannot present share sheet")
                    OverlayVisibilityCoordinator.shared.endOverlay(id: "shareSheet_\(tweet.mid)", source: "TweetActionBarView (no VC)")
                }
            }
        }
    }

    /// Build share items with rich preview
    private func buildShareItems(for tweet: Tweet, hproseInstance: HproseInstance) async -> [Any] {
        let effectiveParentTweet = parentTweet ?? commentsVMParentTweet
        let shareText = Self.buildShareText(tweet: tweet, hproseInstance: hproseInstance, isInDetailView: isInDetailView, parentTweet: effectiveParentTweet)
        let customItem = CustomShareItem(shareText: shareText, tweet: tweet, previewImage: attachmentPreviewImage)

        var items: [Any] = [customItem]

        // Add image as separate item — WeChat ignores LPLinkMetadata and needs
        // a standalone image to show the correct preview in its share sheet.
        if let previewImage = attachmentPreviewImage {
            items.append(CustomShareImage(image: previewImage))
        }

        return items
    }

    /// Build share text for a tweet
    private static func buildShareText(tweet: Tweet, hproseInstance: HproseInstance, isInDetailView: Bool = false, parentTweet: Tweet? = nil) -> String {
        var shareText = ""

        // Priority: title > content > attachment types
        if let title = tweet.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let maxLength = 40
            shareText += title.count > maxLength ? String(title.prefix(maxLength)) + "..." : title
        } else if let content = tweet.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let maxLength = 40
            let cleaned = content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            shareText += cleaned.count > maxLength ? String(cleaned.prefix(maxLength)) + "..." : cleaned
        } else {
            shareText += composeAttachmentTypeText(for: tweet)
        }

        // Add two newlines after text if there is text
        if !shareText.isEmpty {
            shareText += "\n\n"
        }

        // Add URL - compose based on context (comment vs regular tweet, detail view vs feed)
        let urlText: String

        if let parent = parentTweet, isInDetailView {
            // Comment in detail view: use entry format with query params in hash fragment
            let baseUrlString = tweet.author?.baseUrl?.absoluteString ?? AppConfig.baseUrl
            urlText = "\(baseUrlString)/entry?aid=\(AppConfig.appIdHash)&ver=last#/tweet/\(tweet.mid)/\(tweet.authorId)?fromComment=true&parentTweetId=\(parent.mid)&parentAuthorId=\(parent.authorId)"
        } else if let parent = parentTweet {
            // Comment in feed/list: use traditional format with query parameters
            var domain = hproseInstance.domainToShare
            if !domain.hasPrefix("http://") && !domain.hasPrefix("https://") {
                domain = "http://" + domain
            }
            urlText = "\(domain)/tweet/\(tweet.mid)/\(tweet.authorId)?fromComment=true&parentTweetId=\(parent.mid)&parentAuthorId=\(parent.authorId)"
        } else if isInDetailView {
            // Regular tweet in detail view: use author's baseUrl with entry format
            let baseUrlString = tweet.author?.baseUrl?.absoluteString ?? AppConfig.baseUrl
            urlText = "\(baseUrlString)/entry?aid=\(AppConfig.appIdHash)&ver=last#/tweet/\(tweet.mid)/\(tweet.authorId)"
        } else {
            // Regular tweet in feed/grid: use traditional format
            var domain = hproseInstance.domainToShare
            if !domain.hasPrefix("http://") && !domain.hasPrefix("https://") {
                domain = "http://" + domain
            }
            urlText = "\(domain)/tweet/\(tweet.mid)/\(tweet.authorId)"
        }

        if !shareText.isEmpty {
            shareText += urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            shareText += urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return shareText
    }

    /// Get an IPv4-preferred baseUrl for sharing from detail view
    private static func getIPv4PreferredBaseUrl(for tweet: Tweet, hproseInstance: HproseInstance) async -> String {
        guard let author = tweet.author else {
            return AppConfig.baseUrl
        }

        let currentBaseUrl = author.baseUrl?.absoluteString ?? AppConfig.baseUrl

        // Quick check: if already IPv4, use it
        if !currentBaseUrl.contains("[") && currentBaseUrl.filter({ $0 == ":" }).count <= 1 {
            return currentBaseUrl
        }

        // IPv6 detected - resolve IPv4 via getProviderIP
        do {
            if let ipv4 = try await hproseInstance.getProviderIP(author.mid, v4Only: true) {
                let ipv4BaseUrl = "http://\(ipv4)"
                if let ipv4URL = URL(string: ipv4BaseUrl) {
                    await MainActor.run {
                        author.baseUrl = ipv4URL
                    }
                }
                return ipv4BaseUrl
            }
        } catch {}

        return currentBaseUrl
    }

    /// Load attachment preview image (first image or video thumbnail)
    private func loadAttachmentPreviewImage(for tweet: Tweet, hproseInstance: HproseInstance) async -> UIImage? {
        guard let sourceTweet = await resolveSourceTweetWithAttachments(tweet: tweet, hproseInstance: hproseInstance) else {
            return nil
        }

        guard let firstAttachment = sourceTweet.attachments?.first else {
            return nil
        }

        let baseURL = await resolveAttachmentBaseURL(for: sourceTweet, hproseInstance: hproseInstance)

        switch firstAttachment.type {
        case .image:
            // Try to get cached image first
            if let cached = ImageCacheManager.shared.getCachedCompressedImage(forMid: firstAttachment.mid) {
                return cropToCenter(image: cached)
            }

            // Load image from URL
            if let url = resolvedAttachmentURL(for: firstAttachment, baseURL: baseURL) {
                if let image = await ImageCacheManager.shared.loadAndCacheImage(from: url, for: firstAttachment) {
                    return cropToCenter(image: image)
                }
            }

        case .video, .hls_video:
            if let url = resolvedAttachmentURL(for: firstAttachment, baseURL: baseURL) {
                let isHLS = firstAttachment.type == .hls_video
                return await generateVideoPreviewImage(for: url, mediaID: firstAttachment.mid, isHLS: isHLS, tweet: tweet)
            }

        default:
            break
        }

        return nil
    }

    private func resolveSourceTweetWithAttachments(tweet: Tweet, hproseInstance: HproseInstance) async -> Tweet? {
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
            if let original = try? await hproseInstance.getTweet(tweetId: originalTweetId, authorId: originalAuthorId),
               let attachments = original.attachments,
               !attachments.isEmpty {
                return original
            }
        }
        return nil
    }

    private func resolveAttachmentBaseURL(for sourceTweet: Tweet, hproseInstance: HproseInstance) async -> URL? {
        if let base = sourceTweet.author?.baseUrl {
            return base
        }
        let author = User.getInstance(mid: sourceTweet.authorId)
        if let base = author.baseUrl {
            return base
        }
        if let user = try? await hproseInstance.fetchUser(sourceTweet.authorId),
           let base = user.baseUrl {
            return base
        }
        return await MainActor.run {
            hproseInstance.appUser.baseUrl
        } ?? URL(string: AppConfig.baseUrl)
    }

    /// Resolve attachment URL with baseURL
    private func resolvedAttachmentURL(for attachment: MimeiFileType, baseURL: URL?) -> URL? {
        if let urlString = attachment.url, let url = URL(string: urlString), url.scheme != nil {
            return url
        }
        if let urlString = attachment.url, let base = baseURL {
            return URL(string: urlString, relativeTo: base) ?? base.appendingPathComponent(urlString)
        }
        if let baseURL = baseURL {
            return attachment.getUrl(baseURL)
        }
        return nil
    }

    // MARK: - Video Preview Generation

    /// Synchronously capture the current video frame before overlay pauses playback.
    /// Uses the AVPlayerItemVideoOutput already attached by MediaCellUIView.
    /// Sets attachmentPreviewImage directly so the async load is skipped.
    private func captureVideoFrameBeforePause(for tweet: Tweet) {
        // Resolve the source tweet (retweet → original)
        let sourceTweet: Tweet
        if let attachments = tweet.attachments, !attachments.isEmpty {
            sourceTweet = tweet
        } else if let originalTweetId = tweet.originalTweetId,
                  let original = Tweet.getInstance(for: originalTweetId),
                  let attachments = original.attachments, !attachments.isEmpty {
            sourceTweet = original
        } else {
            return
        }

        guard let firstAttachment = sourceTweet.attachments?.first,
              (firstAttachment.type == .video || firstAttachment.type == .hls_video) else { return }

        let mediaID = firstAttachment.mid

        // For detail view, capture from DetailVideoManager
        if isInDetailView,
           let player = DetailVideoManager.shared.currentPlayer,
           DetailVideoManager.shared.currentVideoMid == mediaID {
            if let frame = Self.syncCaptureFrame(from: player, mediaID: mediaID) {
                VideoLastFrameCache.shared.set(frame, for: mediaID)
                attachmentPreviewImage = cropToCenter(image: frame)
            }
            return
        }

        // For feed, get player from SharedAssetCache
        guard let player = SharedAssetCache.shared.getCachedPlayer(for: mediaID) else { return }
        if let frame = Self.syncCaptureFrame(from: player, mediaID: mediaID) {
            VideoLastFrameCache.shared.set(frame, for: mediaID)
            attachmentPreviewImage = cropToCenter(image: frame)
        }
    }

    /// Synchronously grab the current frame from a player's existing video output.
    private static func syncCaptureFrame(from player: AVPlayer, mediaID: String) -> UIImage? {
        guard let playerItem = player.currentItem,
              playerItem.status == .readyToPlay,
              !playerItem.loadedTimeRanges.isEmpty else { return nil }

        // Find the AVPlayerItemVideoOutput already attached by MediaCellUIView
        guard let videoOutput = playerItem.outputs.compactMap({ $0 as? AVPlayerItemVideoOutput }).first else { return nil }

        let currentTime = playerItem.currentTime()
        guard let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0, width < 10000, height < 10000 else { return nil }

        return VideoFrameExtractor.makeDownscaledUIImage(from: pixelBuffer, maxDimension: 720)
    }

    private func generateVideoPreviewImage(for url: URL, mediaID: String, isHLS: Bool = false, tweet: Tweet) async -> UIImage? {

        // Check VideoLastFrameCache — populated by captureVideoFrameBeforePause()
        // at the moment the share button was tapped, before the overlay paused videos.
        if let cachedFrame = VideoLastFrameCache.shared.image(for: mediaID) {
            return cropToCenter(image: cachedFrame)
        }

        // Check DetailVideoManager when in detail view
        if isInDetailView,
           let detailPlayer = DetailVideoManager.shared.currentPlayer,
           DetailVideoManager.shared.currentVideoMid == mediaID,
           let playerItem = detailPlayer.currentItem {
            let duration = try? await playerItem.asset.load(.duration)
            if let duration = duration {
                let durationSeconds = CMTimeGetSeconds(duration)
                let currentTime = CMTimeGetSeconds(playerItem.currentTime())
                if durationSeconds > 0 && !durationSeconds.isNaN && !durationSeconds.isInfinite {
                    let captureTime = currentTime > 0.1 ? currentTime : min(1.0, durationSeconds * 0.1)
                    if let image = await captureFrameFromPlayer(detailPlayer, at: captureTime) {
                        return image
                    }
                }
            }
        }

        // For HLS videos, try cached player
        if isHLS {
            if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: mediaID),
               let playerItem = cachedPlayer.currentItem {
                let hasBufferedData = !playerItem.loadedTimeRanges.isEmpty
                if hasBufferedData && playerItem.status == .readyToPlay {
                    let duration = try? await playerItem.asset.load(.duration)
                    if let duration = duration {
                        let durationSeconds = CMTimeGetSeconds(duration)
                        if durationSeconds > 0 && !durationSeconds.isNaN && !durationSeconds.isInfinite {
                            let currentTime = CMTimeGetSeconds(playerItem.currentTime())
                            let captureTime = currentTime > 0.1 ? currentTime : min(1.0, durationSeconds * 0.1)
                            if let image = await captureFrameFromPlayer(cachedPlayer, at: captureTime) {
                                return image
                            }
                        }
                    }
                }
            }
            return nil
        }

        // For regular videos, try cached player
        if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: mediaID),
           let playerItem = cachedPlayer.currentItem {
            let currentTime = CMTimeGetSeconds(playerItem.currentTime())
            let duration = try? await playerItem.asset.load(.duration)
            if let duration = duration {
                let durationSeconds = CMTimeGetSeconds(duration)
                if durationSeconds > 0 && !durationSeconds.isNaN && !durationSeconds.isInfinite {
                    let captureTime = currentTime > 0.1 ? currentTime : min(1.0, durationSeconds * 0.1)
                    if let image = await captureFrameFromPlayer(cachedPlayer, at: captureTime) {
                        return image
                    }
                }
            }
        }

        // Fallback: use asset loading
        do {
            let mediaType: MediaType = isHLS ? .hls_video : .video
            let asset = try await SharedAssetCache.shared.getAsset(for: url, tweetId: tweet.mid, mediaType: mediaType)

            async let durationLoad = asset.load(.duration)
            async let tracksLoad = asset.load(.tracks)
            let (duration, tracks) = try await (durationLoad, tracksLoad)
            let durationSeconds = CMTimeGetSeconds(duration)

            guard durationSeconds > 0 && !durationSeconds.isNaN && !durationSeconds.isInfinite else { return nil }
            guard !tracks.isEmpty else { return nil }

            let captureTime = min(1.0, durationSeconds * 0.1)
            if let image = try? await captureFrame(from: asset, at: captureTime) {
                return image
            }
        } catch {}

        return nil
    }

    // MARK: - Frame Capture

    // Track active captures per player to prevent concurrent captures
    private static var activeCaptures: [ObjectIdentifier: Task<Void, Never>] = [:]
    private static let captureLock = NSLock()

    private func captureFrameFromPlayer(_ player: AVPlayer, at seconds: Double) async -> UIImage? {
        guard let playerItem = player.currentItem else { return nil }

        // Serialize captures per player to prevent concurrent interference
        let playerId = ObjectIdentifier(player)

        let existingTask = Self.captureLock.withLock { () -> Task<Void, Never>? in
            return Self.activeCaptures[playerId]
        }
        if let existingTask = existingTask {
            _ = await existingTask.value
        }

        let captureTask = Task<Void, Never> {}
        Self.captureLock.withLock {
            Self.activeCaptures[playerId] = captureTask
        }
        defer {
            Self.captureLock.withLock {
                _ = Self.activeCaptures.removeValue(forKey: playerId)
            }
        }

        // Save playback state before modifying player
        let savedState = await MainActor.run { () -> (wasPlaying: Bool, originalTime: CMTime, originalRate: Float) in
            let wasPlaying = player.rate > 0
            let originalTime = player.currentTime()
            let originalRate = player.rate
            if wasPlaying { player.pause() }
            return (wasPlaying: wasPlaying, originalTime: originalTime, originalRate: originalRate)
        }

        let videoOutput = await MainActor.run { () -> AVPlayerItemVideoOutput in
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            playerItem.add(output)
            return output
        }

        defer {
            Task { @MainActor in
                guard player.currentItem === playerItem else {
                    playerItem.remove(videoOutput)
                    return
                }
                let restoreTime = savedState.originalTime
                player.seek(to: restoreTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    if finished && savedState.wasPlaying {
                        Task { @MainActor in
                            if player.currentItem === playerItem {
                                player.rate = savedState.originalRate
                            }
                        }
                    }
                }
                playerItem.remove(videoOutput)
            }
        }

        // Try capturing at current position first, then with small offsets
        let retryOffsets = [0.0, 0.1, 0.3, 0.5]

        for retryOffset in retryOffsets {
            let currentItem = await MainActor.run { player.currentItem }
            guard currentItem === playerItem else { return nil }

            let targetTime = seconds + retryOffset
            let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
            let targetCMTime = CMTime(seconds: targetTime, preferredTimescale: 600)

            let seekCompleted = await MainActor.run { () -> Task<Bool, Never> in
                guard player.currentItem === playerItem else { return Task { false } }
                return Task {
                    await withCheckedContinuation { continuation in
                        player.seek(to: targetCMTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
                            continuation.resume(returning: finished)
                        }
                    }
                }
            }

            let didSeek = await seekCompleted.value
            guard didSeek else { continue }

            // Wait for segment to load
            var attempts = 0
            let maxAttempts = 50
            var hasDataAtTime = false

            while attempts < maxAttempts {
                hasDataAtTime = await MainActor.run { () -> Bool in
                    guard player.currentItem === playerItem else { return false }
                    let currentTime = playerItem.currentTime()
                    for timeRangeValue in playerItem.loadedTimeRanges {
                        let range = timeRangeValue.timeRangeValue
                        let start = range.start
                        let end = CMTimeAdd(start, range.duration)
                        if CMTimeCompare(currentTime, start) >= 0 && CMTimeCompare(currentTime, end) < 0 {
                            return true
                        }
                    }
                    return false
                }
                if hasDataAtTime { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
                attempts += 1
            }

            if !hasDataAtTime { continue }

            try? await Task.sleep(nanoseconds: 200_000_000)

            let initialImage = await MainActor.run { () -> UIImage? in
                guard player.currentItem === playerItem else { return nil }
                let currentTime = playerItem.currentTime()
                guard videoOutput.hasNewPixelBuffer(forItemTime: currentTime) else { return nil }
                guard let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) else { return nil }
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                let context = CIContext(options: [.useSoftwareRenderer: false])
                guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
                return UIImage(cgImage: cgImage)
            }

            if let initialImage = initialImage {
                return await Task.detached(priority: .userInitiated) { [initialImage] in
                    let renderer = UIGraphicsImageRenderer(size: initialImage.size)
                    let cleanImage = renderer.image { _ in
                        initialImage.draw(in: CGRect(origin: .zero, size: initialImage.size))
                    }
                    return self.cropToCenter(image: cleanImage, targetSize: 270)
                }.value
            }
        }

        return nil
    }

    private func captureFrame(from asset: AVAsset, at seconds: Double) async throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let time = CMTime(seconds: seconds, preferredTimescale: 600)

        let cgImage = try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
                switch result {
                case .succeeded:
                    if let image = image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: NSError(domain: "AttachmentPreview", code: -2))
                    }
                case .failed:
                    continuation.resume(throwing: error ?? NSError(domain: "AttachmentPreview", code: -3))
                case .cancelled:
                    continuation.resume(throwing: NSError(domain: "AttachmentPreview", code: -4))
                @unknown default:
                    continuation.resume(throwing: NSError(domain: "AttachmentPreview", code: -5))
                }
            }
        }

        let image = UIImage(cgImage: cgImage)

        // Re-render without alpha channel, then crop
        UIGraphicsBeginImageContextWithOptions(image.size, true, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let cleanImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return cropToCenter(image: cleanImage ?? image, targetSize: 270)
    }

    /// Crop image to center square and resize to 270x270
    private nonisolated func cropToCenter(image: UIImage, targetSize: CGFloat = 270) -> UIImage {
        let size = image.size
        let scale = image.scale
        let cropSize = min(size.width, size.height)

        let cropRect = CGRect(
            x: (size.width - cropSize) / 2,
            y: (size.height - cropSize) / 2,
            width: cropSize,
            height: cropSize
        )

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

        // Resize to target size
        UIGraphicsBeginImageContextWithOptions(CGSize(width: targetSize, height: targetSize), true, 1.0)
        defer { UIGraphicsEndImageContext() }

        croppedImage.draw(in: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
        guard let resized = UIGraphicsGetImageFromCurrentImageContext() else {
            return croppedImage
        }

        return resized
    }

    func prepareForReuse() {
        cancellables.removeAll()
        currentTweetId = nil
        currentTweet = nil
        hproseInstance = nil
        onCommentTap = nil
        onShowLogin = nil
        onShowToast = nil
        onShareVisibilityChange = nil
        parentViewController = nil
        parentTweet = nil
        commentsVMParentTweet = nil
        shareSpinner.stopAnimating()
        shareButton.alpha = 1.0
        attachmentPreviewImage = nil
        isPreparingShare = false
    }
}

// MARK: - ActionButtonView (reusable icon + count button)

private class ActionButtonView: UIView {

    private let iconView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        return iv
    }()

    private let countLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        label.textColor = UIColor(named: "ThemeSecondaryText") ?? .secondaryLabel
        return label
    }()

    var onTap: (() -> Void)?

    override var tintColor: UIColor! {
        didSet {
            iconView.tintColor = tintColor
        }
    }

    init(icon: String, pointSize: CGFloat = 16) {
        super.init(frame: .zero)
        let config = UIImage.SymbolConfiguration(pointSize: pointSize)
        iconView.preferredSymbolConfiguration = config
        iconView.image = UIImage(systemName: icon)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        let stack = UIStackView(arrangedSubviews: [iconView, countLabel])
        stack.axis = .horizontal
        stack.spacing = 2
        stack.alignment = .center

        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.widthAnchor.constraint(equalToConstant: 22),
            countLabel.widthAnchor.constraint(equalToConstant: 32),
        ])

        // Ensure minimum width
        widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
    }

    @objc private func tapped() {
        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        // Scale animation
        UIView.animate(withDuration: 0.1, animations: {
            self.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }) { _ in
            UIView.animate(withDuration: 0.1) {
                self.transform = .identity
            }
        }

        onTap?()
    }

    func setCount(_ count: Int) {
        countLabel.text = count > 0 ? formatCount(count) : ""
    }

    func setIcon(_ systemName: String) {
        iconView.image = UIImage(systemName: systemName, withConfiguration: iconView.preferredSymbolConfiguration)
    }
}

// MARK: - SwiftUI wrapper for using TweetActionBarView in SwiftUI views

@available(iOS 16.0, *)
struct TweetActionBarRepresentable: UIViewRepresentable {
    @ObservedObject var tweet: Tweet
    @EnvironmentObject private var hproseInstance: HproseInstance
    var onCommentTap: (() -> Void)? = nil
    var onShowLogin: (() -> Void)? = nil
    var isInDetailView: Bool = false
    var parentTweet: Tweet? = nil
    var commentsVMParentTweet: Tweet? = nil
    var onShareVisibilityChange: ((Bool) -> Void)? = nil
    var onShowToast: ((String, Bool) -> Void)? = nil

    func makeUIView(context: Context) -> TweetActionBarView {
        let bar = TweetActionBarView()
        bar.isInDetailView = isInDetailView
        return bar
    }

    func updateUIView(_ bar: TweetActionBarView, context: Context) {
        bar.configure(tweet: tweet, hproseInstance: hproseInstance)
        bar.onCommentTap = onCommentTap
        bar.onShowLogin = onShowLogin
        bar.onShareVisibilityChange = onShareVisibilityChange
        bar.onShowToast = onShowToast
        bar.isInDetailView = isInDetailView
        bar.parentTweet = parentTweet
        bar.commentsVMParentTweet = commentsVMParentTweet

        // Find the hosting controller's parent to use as parentViewController
        if bar.parentViewController == nil, let vc = bar.findViewController() {
            bar.parentViewController = vc
        }
    }
}

// Helper to find the UIViewController from a UIView
private extension UIView {
    func findViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let vc = next as? UIViewController {
                return vc
            }
            responder = next
        }
        return nil
    }
}
