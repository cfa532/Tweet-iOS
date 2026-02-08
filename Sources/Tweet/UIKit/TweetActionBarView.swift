//
//  TweetActionBarView.swift
//  Tweet
//
//  Pure UIKit action bar replacing SwiftUI TweetActionButtonsView.
//  5 buttons: comment, retweet, like, bookmark, share.
//  Business logic (optimistic updates, server sync) ported from TweetActionButtonsView.swift.
//
import UIKit
import Combine

class TweetActionBarView: UIView {

    // MARK: - Action Buttons

    private let commentButton = ActionButtonView(icon: "bubble.left")
    private let retweetButton = ActionButtonView(icon: "arrow.2.squarepath")
    private let likeButton = ActionButtonView(icon: "heart")
    private let bookmarkButton = ActionButtonView(icon: "bookmark")
    private let shareButton: UIButton = {
        let btn = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 14)
        btn.setImage(UIImage(systemName: "square.and.arrow.up", withConfiguration: config), for: .normal)
        btn.tintColor = UIColor(named: "ThemeSecondaryText") ?? .secondaryLabel
        return btn
    }()
    private let shareSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        return spinner
    }()

    private let stackView: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.distribution = .fill
        sv.alignment = .center
        sv.spacing = 0
        return sv
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
    weak var parentViewController: UIViewController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        let tintColor = UIColor(named: "ThemeSecondaryText") ?? .secondaryLabel
        commentButton.tintColor = tintColor
        retweetButton.tintColor = tintColor
        likeButton.tintColor = tintColor
        bookmarkButton.tintColor = tintColor

        let spacer1 = UIView()
        let spacer2 = UIView()
        let spacer3 = UIView()
        let spacer4 = UIView()

        stackView.addArrangedSubview(commentButton)
        stackView.addArrangedSubview(spacer1)
        stackView.addArrangedSubview(retweetButton)
        stackView.addArrangedSubview(spacer2)
        stackView.addArrangedSubview(likeButton)
        stackView.addArrangedSubview(spacer3)
        stackView.addArrangedSubview(bookmarkButton)
        stackView.addArrangedSubview(spacer4)

        let shareContainer = UIView()
        shareContainer.addSubview(shareButton)
        shareContainer.addSubview(shareSpinner)
        shareButton.translatesAutoresizingMaskIntoConstraints = false
        shareSpinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            shareButton.centerYAnchor.constraint(equalTo: shareContainer.centerYAnchor),
            shareButton.trailingAnchor.constraint(equalTo: shareContainer.trailingAnchor),
            shareSpinner.centerYAnchor.constraint(equalTo: shareContainer.centerYAnchor),
            shareSpinner.trailingAnchor.constraint(equalTo: shareContainer.trailingAnchor),
            shareContainer.widthAnchor.constraint(equalToConstant: 30),
        ])
        stackView.addArrangedSubview(shareContainer)

        // Equal spacers
        for spacer in [spacer1, spacer2, spacer3, spacer4] {
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        spacer1.widthAnchor.constraint(equalTo: spacer2.widthAnchor).isActive = true
        spacer2.widthAnchor.constraint(equalTo: spacer3.widthAnchor).isActive = true
        spacer3.widthAnchor.constraint(equalTo: spacer4.widthAnchor).isActive = true

        addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.heightAnchor.constraint(equalToConstant: 30),
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
        onCommentTap?()
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
                await MainActor.run {
                    tweet.favorites = originalFavorites
                    tweet.favoriteCount = originalFavoriteCount
                    hproseInstance.appUser.favoritesCount = originalAppUserFavoriteCount
                    let msg = wasFavorite
                        ? NSLocalizedString("Failed to remove favorite. Please try again.", comment: "")
                        : NSLocalizedString("Failed to add favorite. Please try again.", comment: "")
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
                await MainActor.run {
                    tweet.favorites = originalFavorites
                    tweet.bookmarkCount = originalBookmarkCount
                    hproseInstance.appUser.bookmarksCount = originalAppUserBookmarkCount
                    let msg = wasBookmarked
                        ? NSLocalizedString("Failed to remove bookmark. Please try again.", comment: "")
                        : NSLocalizedString("Failed to add bookmark. Please try again.", comment: "")
                    self.onShowToast?(msg, true)
                }
            }
        }
    }

    @objc private func handleShare() {
        guard debounce(&lastShareTime) else { return }
        guard let tweet = currentTweet, let hprose = hproseInstance else { return }

        shareSpinner.startAnimating()
        shareButton.alpha = 0.3

        Task {
            let shareText = Self.buildShareText(tweet: tweet, hproseInstance: hprose)

            await MainActor.run {
                self.shareSpinner.stopAnimating()
                self.shareButton.alpha = 1.0

                let activityVC = UIActivityViewController(activityItems: [shareText], applicationActivities: nil)

                if let vc = self.parentViewController {
                    if let popover = activityVC.popoverPresentationController {
                        popover.sourceView = self.shareButton
                        popover.sourceRect = self.shareButton.bounds
                    }
                    vc.present(activityVC, animated: true)
                }
            }
        }
    }

    /// Build share text for a tweet (feed context — not detail or comment view)
    private static func buildShareText(tweet: Tweet, hproseInstance: HproseInstance) -> String {
        var shareText = ""

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

        if !shareText.isEmpty {
            shareText += "\n\n"
        }

        var domain = hproseInstance.domainToShare
        if !domain.hasPrefix("http://") && !domain.hasPrefix("https://") {
            domain = "http://" + domain
        }
        shareText += "\(domain)/tweet/\(tweet.mid)/\(tweet.authorId)"

        return shareText
    }

    func prepareForReuse() {
        cancellables.removeAll()
        currentTweetId = nil
        currentTweet = nil
        hproseInstance = nil
        onCommentTap = nil
        onShowLogin = nil
        onShowToast = nil
        parentViewController = nil
        shareSpinner.stopAnimating()
        shareButton.alpha = 1.0
    }
}

// MARK: - ActionButtonView (reusable icon + count button)

private class ActionButtonView: UIView {

    private let iconView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14)
        return iv
    }()

    private let countLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.textColor = UIColor(named: "ThemeSecondaryText") ?? .secondaryLabel
        return label
    }()

    var onTap: (() -> Void)?

    override var tintColor: UIColor! {
        didSet {
            iconView.tintColor = tintColor
        }
    }

    init(icon: String) {
        super.init(frame: .zero)
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

            iconView.widthAnchor.constraint(equalToConstant: 20),
            countLabel.widthAnchor.constraint(equalToConstant: 28),
        ])

        // Ensure minimum width
        widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true

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
        iconView.image = UIImage(systemName: systemName)
    }
}
