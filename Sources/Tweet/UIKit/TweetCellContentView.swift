//
//  TweetCellContentView.swift
//  Tweet
//
//  Main UIKit cell content view replacing the SwiftUI TweetItemView in the feed.
//  Contains avatar, header, body, action bar, embedded tweet, and retweet banner.
//
import UIKit
import SwiftUI
import Combine

class TweetCellContentView: UIView {

    // MARK: - Subviews

    private let avatarView = AvatarUIView()
    private let headerView = TweetHeaderUIView()
    private let bodyView = TweetBodyUIView()
    private let actionBar = TweetActionBarView()
    private let embeddedTweetView = EmbeddedTweetUIView()
    private let separatorView: UIView = {
        let v = UIView()
        v.backgroundColor = .systemGray.withAlphaComponent(0.2)
        return v
    }()

    // Retweet banner ("Forwarded by...") — sits ABOVE the mainStack
    private let retweetBanner: UIView = {
        let v = UIView()
        v.isHidden = true
        return v
    }()
    private let retweetIcon: UIImageView = {
        let iv = UIImageView()
        let config = UIImage.SymbolConfiguration(textStyle: .caption1)
        iv.image = UIImage(systemName: "arrow.2.squarepath", withConfiguration: config)
        iv.tintColor = .secondaryLabel
        return iv
    }()
    private let retweetLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        return label
    }()

    // Main horizontal layout: [Avatar | ContentColumn]
    private let mainStack: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.alignment = .top
        sv.spacing = 4
        return sv
    }()

    private let contentColumn: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.spacing = 0
        return sv
    }()

    // Wrapper for embedded tweet: provides -4pt leading offset to match old SwiftUI .padding(.leading, -4)
    private let embeddedTweetWrapper: UIView = {
        let v = UIView()
        v.clipsToBounds = false
        return v
    }()

    // MARK: - Constraints managed dynamically
    private var embeddedWrapperHeightConstraint: NSLayoutConstraint?
    private var retweetBannerHeightConstraint: NSLayoutConstraint?
    // Mutually exclusive: mainStack top when banner is hidden vs visible
    private var mainStackTopDefault: NSLayoutConstraint!
    private var mainStackTopAfterBanner: NSLayoutConstraint!

    // MARK: - State
    private var cancellables = Set<AnyCancellable>()
    private var currentTweetId: String?
    private weak var currentTweet: Tweet?
    private weak var parentViewController: UIViewController?

    // Callbacks (set by cell / controller)
    var onAvatarTap: ((User) -> Void)?
    var onTweetTap: ((Tweet) -> Void)?
    var onShowLogin: (() -> Void)?
    var onShowToast: ((String, Bool) -> Void)?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .systemBackground

        // Retweet banner setup — positioned above mainStack, not inside contentColumn
        retweetBanner.addSubview(retweetIcon)
        retweetBanner.addSubview(retweetLabel)
        retweetIcon.translatesAutoresizingMaskIntoConstraints = false
        retweetLabel.translatesAutoresizingMaskIntoConstraints = false
        // Label text aligns with content column leading; icon extends left into avatar area
        NSLayoutConstraint.activate([
            retweetLabel.leadingAnchor.constraint(equalTo: retweetBanner.leadingAnchor),
            retweetLabel.centerYAnchor.constraint(equalTo: retweetBanner.centerYAnchor),
            retweetLabel.trailingAnchor.constraint(lessThanOrEqualTo: retweetBanner.trailingAnchor),
            retweetIcon.trailingAnchor.constraint(equalTo: retweetLabel.leadingAnchor, constant: -4),
            retweetIcon.centerYAnchor.constraint(equalTo: retweetBanner.centerYAnchor),
            retweetIcon.widthAnchor.constraint(equalToConstant: 14),
        ])
        retweetBannerHeightConstraint = retweetBanner.heightAnchor.constraint(equalToConstant: 0)
        retweetBannerHeightConstraint?.isActive = true

        // Embedded tweet wrapper: offsets embedded tweet -4pt leading to match old SwiftUI .padding(.leading, -4)
        embeddedTweetWrapper.addSubview(embeddedTweetView)
        embeddedTweetView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            embeddedTweetView.topAnchor.constraint(equalTo: embeddedTweetWrapper.topAnchor),
            embeddedTweetView.bottomAnchor.constraint(equalTo: embeddedTweetWrapper.bottomAnchor),
            embeddedTweetView.leadingAnchor.constraint(equalTo: embeddedTweetWrapper.leadingAnchor, constant: -4),
            embeddedTweetView.trailingAnchor.constraint(equalTo: embeddedTweetWrapper.trailingAnchor),
        ])

        // Build content column: [header, body, embeddedWrapper, actionBar]
        // Note: retweetBanner is NOT in contentColumn — it's above mainStack
        contentColumn.addArrangedSubview(headerView)
        contentColumn.addArrangedSubview(bodyView)
        contentColumn.addArrangedSubview(embeddedTweetWrapper)
        contentColumn.addArrangedSubview(actionBar)

        contentColumn.setCustomSpacing(0, after: headerView)
        contentColumn.setCustomSpacing(12, after: bodyView)
        contentColumn.setCustomSpacing(20, after: embeddedTweetWrapper)

        // Main stack: [avatar | contentColumn]
        mainStack.addArrangedSubview(avatarView)
        mainStack.addArrangedSubview(contentColumn)

        addSubview(retweetBanner)
        addSubview(mainStack)
        addSubview(separatorView)

        retweetBanner.translatesAutoresizingMaskIntoConstraints = false
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.translatesAutoresizingMaskIntoConstraints = false

        // Retweet banner: aligned with content column (avatar 42 + spacing 4 from mainStack leading)
        NSLayoutConstraint.activate([
            retweetBanner.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            retweetBanner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 49), // 3 + 42 + 4
            retweetBanner.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])

        // MainStack top: two mutually exclusive constraints
        mainStackTopDefault = mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 16)
        mainStackTopAfterBanner = mainStack.topAnchor.constraint(equalTo: retweetBanner.bottomAnchor, constant: 2)
        mainStackTopDefault.isActive = true

        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: separatorView.topAnchor, constant: -16),

            avatarView.widthAnchor.constraint(equalToConstant: 42),
            avatarView.heightAnchor.constraint(equalToConstant: 42),

            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            separatorView.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 1),
        ])

        // Embedded tweet wrapper starts hidden
        embeddedTweetWrapper.isHidden = true
        embeddedWrapperHeightConstraint = embeddedTweetWrapper.heightAnchor.constraint(equalToConstant: 0)
        // Don't activate - only activate when hidden
    }

    /// Show or hide retweet banner and switch mainStack top constraint accordingly
    private func showRetweetBanner(_ show: Bool) {
        retweetBanner.isHidden = !show
        if show {
            retweetBannerHeightConstraint?.constant = 18
            retweetBannerHeightConstraint?.isActive = true
            mainStackTopDefault.isActive = false
            mainStackTopAfterBanner.isActive = true
        } else {
            retweetBannerHeightConstraint?.constant = 0
            retweetBannerHeightConstraint?.isActive = true
            mainStackTopAfterBanner.isActive = false
            mainStackTopDefault.isActive = true
        }
    }

    // MARK: - Configure

    func configure(tweet: Tweet, hproseInstance: HproseInstance,
                   isPinned: Bool, isLastItem: Bool,
                   parentViewController: UIViewController) {
        self.parentViewController = parentViewController
        self.currentTweet = tweet

        // Skip if same tweet
        if currentTweetId == tweet.mid { return }
        currentTweetId = tweet.mid
        cancellables.removeAll()

        let isRetweet = tweet.originalTweetId != nil && tweet.originalAuthorId != nil

        // Determine which tweet's content to show
        if isRetweet {
            configureAsRetweet(tweet: tweet, hproseInstance: hproseInstance,
                               isPinned: isPinned, parentViewController: parentViewController)
        } else {
            configureAsRegularTweet(tweet: tweet, hproseInstance: hproseInstance,
                                    isPinned: isPinned, parentViewController: parentViewController)
        }

        // Separator
        separatorView.isHidden = isLastItem

        // Load author if needed (background task)
        loadAuthorIfNeeded(tweet: tweet, hproseInstance: hproseInstance)

        // Force layout on next RunLoop after SwiftUI hosting controllers have rendered.
        // UIHostingController renders SwiftUI content asynchronously (needs one RunLoop pass),
        // but UITableView measures cells synchronously during cellForRowAt.
        // This deferred layout ensures the cell settles to its correct size.
        DispatchQueue.main.async { [weak self] in
            self?.setNeedsLayout()
            self?.layoutIfNeeded()
        }
    }

    private func configureAsRegularTweet(tweet: Tweet, hproseInstance: HproseInstance,
                                          isPinned: Bool, parentViewController: UIViewController) {
        // Hide retweet banner
        showRetweetBanner(false)

        // Hide embedded tweet wrapper
        embeddedTweetWrapper.isHidden = true
        embeddedWrapperHeightConstraint?.isActive = true

        // Avatar
        if let author = tweet.author {
            avatarView.configure(user: author, size: 42)
            avatarView.onTap = { [weak self] in self?.onAvatarTap?(author) }
        } else {
            avatarView.onTap = nil
        }

        // Subscribe to author appearing
        tweet.$author
            .compactMap { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] author in
                self?.avatarView.configure(user: author, size: 42)
                self?.avatarView.onTap = { [weak self] in self?.onAvatarTap?(author) }
            }
            .store(in: &cancellables)

        // Header
        headerView.configure(tweet: tweet)
        headerView.onMenuTap = { [weak self] tweet, sourceView in
            self?.presentTweetMenu(tweet: tweet, isPinned: isPinned,
                                    showDelete: tweet.authorId == hproseInstance.appUser.mid,
                                    sourceView: sourceView, hproseInstance: hproseInstance)
        }

        // Body
        bodyView.configure(tweet: tweet, isEmbedded: false, cellTweetId: nil,
                           parentViewController: parentViewController)
        bodyView.onTweetBodyTap = { [weak self] in self?.onTweetTap?(tweet) }
        updateBodyToActionSpacing()

        // Action bar
        actionBar.configure(tweet: tweet, hproseInstance: hproseInstance)
        actionBar.parentViewController = parentViewController
        actionBar.onCommentTap = { [weak self] in self?.onTweetTap?(tweet) }
        actionBar.onShowLogin = { [weak self] in self?.onShowLogin?() }
        actionBar.onShowToast = { [weak self] msg, isError in self?.onShowToast?(msg, isError) }
    }

    private func configureAsRetweet(tweet: Tweet, hproseInstance: HproseInstance,
                                     isPinned: Bool, parentViewController: UIViewController) {
        guard let originalTweetId = tweet.originalTweetId,
              let originalAuthorId = tweet.originalAuthorId else { return }

        // Check if this is a pure retweet (no own content) or quoted tweet (has own content)
        let hasOwnContent = (tweet.content != nil && !(tweet.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
            || (tweet.attachments != nil && !(tweet.attachments?.isEmpty ?? true))

        // Try to get embedded tweet from cache
        let embeddedTweet = Tweet.getInstance(for: originalTweetId)
            ?? TweetCacheManager.shared.fetchTweetSync(mid: originalTweetId)

        if !hasOwnContent, let embeddedTweet {
            // Pure retweet: show original tweet's content directly, with retweet banner
            configurePureRetweet(tweet: tweet, originalTweet: embeddedTweet,
                                  hproseInstance: hproseInstance, isPinned: isPinned,
                                  parentViewController: parentViewController)
        } else {
            // Quoted tweet: show own content + embedded original tweet below
            configureQuotedTweet(tweet: tweet, embeddedTweet: embeddedTweet,
                                  originalTweetId: originalTweetId,
                                  originalAuthorId: originalAuthorId,
                                  hproseInstance: hproseInstance, isPinned: isPinned,
                                  parentViewController: parentViewController)
        }
    }

    private func configurePureRetweet(tweet: Tweet, originalTweet: Tweet,
                                       hproseInstance: HproseInstance, isPinned: Bool,
                                       parentViewController: UIViewController) {
        // Show retweet banner above the tweet
        showRetweetBanner(true)

        if tweet.author?.mid == hproseInstance.appUser.mid {
            retweetLabel.text = NSLocalizedString("Forwarded by you", comment: "")
        } else {
            let name = tweet.author?.name ?? tweet.author?.username ?? ""
            retweetLabel.text = String(format: NSLocalizedString("Forwarded by %@", comment: ""), name)
        }

        // Hide embedded tweet wrapper (content shown directly)
        embeddedTweetWrapper.isHidden = true
        embeddedWrapperHeightConstraint?.isActive = true

        // Avatar from original tweet's author
        if let author = originalTweet.author {
            avatarView.configure(user: author, size: 42)
            avatarView.onTap = { [weak self] in self?.onAvatarTap?(author) }
        }

        // Header from original tweet
        headerView.configure(tweet: originalTweet)
        headerView.onMenuTap = { [weak self] _, sourceView in
            self?.presentTweetMenu(tweet: tweet, isPinned: isPinned,
                                    showDelete: tweet.authorId == hproseInstance.appUser.mid,
                                    sourceView: sourceView, hproseInstance: hproseInstance)
        }

        // Body from original tweet
        bodyView.configure(tweet: originalTweet, isEmbedded: false, cellTweetId: tweet.mid,
                           parentViewController: parentViewController)
        bodyView.onTweetBodyTap = { [weak self] in self?.onTweetTap?(originalTweet) }
        updateBodyToActionSpacing()

        // Action bar on original tweet
        actionBar.configure(tweet: originalTweet, hproseInstance: hproseInstance)
        actionBar.parentViewController = parentViewController
        actionBar.onCommentTap = { [weak self] in self?.onTweetTap?(originalTweet) }
        actionBar.onShowLogin = { [weak self] in self?.onShowLogin?() }
        actionBar.onShowToast = { [weak self] msg, isError in self?.onShowToast?(msg, isError) }
    }

    private func configureQuotedTweet(tweet: Tweet, embeddedTweet: Tweet?,
                                       originalTweetId: String, originalAuthorId: String,
                                       hproseInstance: HproseInstance, isPinned: Bool,
                                       parentViewController: UIViewController) {
        // Hide retweet banner
        showRetweetBanner(false)

        // Show embedded tweet wrapper
        embeddedTweetWrapper.isHidden = false
        embeddedWrapperHeightConstraint?.isActive = false

        // Avatar from quoting tweet's author
        if let author = tweet.author {
            avatarView.configure(user: author, size: 42)
            avatarView.onTap = { [weak self] in self?.onAvatarTap?(author) }
        }

        // Subscribe to author appearing
        tweet.$author
            .compactMap { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] author in
                self?.avatarView.configure(user: author, size: 42)
                self?.avatarView.onTap = { [weak self] in self?.onAvatarTap?(author) }
            }
            .store(in: &cancellables)

        // Header from quoting tweet
        headerView.configure(tweet: tweet)
        headerView.onMenuTap = { [weak self] _, sourceView in
            self?.presentTweetMenu(tweet: tweet, isPinned: isPinned,
                                    showDelete: tweet.authorId == hproseInstance.appUser.mid,
                                    sourceView: sourceView, hproseInstance: hproseInstance)
        }

        // Body from quoting tweet
        bodyView.configure(tweet: tweet, isEmbedded: false, cellTweetId: nil,
                           parentViewController: parentViewController)
        bodyView.onTweetBodyTap = { [weak self] in self?.onTweetTap?(tweet) }
        updateBodyToActionSpacing()

        // Embedded tweet
        if let embeddedTweet {
            embeddedTweetView.configure(tweet: embeddedTweet, quotingTweetId: tweet.mid,
                                         parentViewController: parentViewController)
        } else {
            embeddedTweetView.loadEmbeddedTweet(
                originalTweetId: originalTweetId,
                originalAuthorId: originalAuthorId,
                quotingTweet: tweet,
                hproseInstance: hproseInstance,
                parentViewController: parentViewController
            )
        }
        embeddedTweetView.onTap = { [weak self] t in self?.onTweetTap?(t) }

        // Action bar on quoting tweet
        actionBar.configure(tweet: tweet, hproseInstance: hproseInstance)
        actionBar.parentViewController = parentViewController
        actionBar.onCommentTap = { [weak self] in self?.onTweetTap?(tweet) }
        actionBar.onShowLogin = { [weak self] in self?.onShowLogin?() }
        actionBar.onShowToast = { [weak self] msg, isError in self?.onShowToast?(msg, isError) }
    }

    /// Adjust body→action spacing: more room when video caption is shown, tighter otherwise
    private func updateBodyToActionSpacing() {
        let spacing: CGFloat = bodyView.isCaptionVisible ? 20 : 10
        contentColumn.setCustomSpacing(spacing, after: bodyView)
    }

    // MARK: - Author Loading

    private func loadAuthorIfNeeded(tweet: Tweet, hproseInstance: HproseInstance) {
        if tweet.author == nil {
            // Try cache first
            Task {
                let cachedAuthor = await TweetCacheManager.shared.fetchUser(mid: tweet.authorId)
                await MainActor.run {
                    if cachedAuthor.username != nil {
                        tweet.author = cachedAuthor
                    } else {
                        tweet.author = User.getInstance(mid: tweet.authorId)
                    }
                }
                Task.detached(priority: .background) {
                    _ = try? await hproseInstance.fetchUser(tweet.authorId)
                }
            }
        } else if tweet.author?.username == nil || tweet.author?.baseUrl == nil {
            Task.detached(priority: .background) {
                _ = try? await hproseInstance.fetchUser(tweet.authorId)
            }
        }
    }

    // MARK: - Menu Presentation

    private func presentTweetMenu(tweet: Tweet, isPinned: Bool, showDelete: Bool,
                                   sourceView: UIView, hproseInstance: HproseInstance) {
        guard let parentVC = parentViewController else { return }

        // Use SwiftUI TweetMenu hosted in a popover for Phase 1
        let menuView = TweetMenu(tweet: tweet, isPinned: isPinned, showDeleteButton: showDelete)
            .environmentObject(hproseInstance)

        let hostingController = UIHostingController(rootView: menuView)
        hostingController.modalPresentationStyle = .popover
        hostingController.preferredContentSize = CGSize(width: 250, height: 200)

        if let popover = hostingController.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
            popover.permittedArrowDirections = .up
        }

        parentVC.present(hostingController, animated: true)
    }

    // MARK: - Reuse

    func prepareForReuse() {
        cancellables.removeAll()
        currentTweetId = nil
        currentTweet = nil

        avatarView.prepareForReuse()
        headerView.prepareForReuse()
        bodyView.prepareForReuse()
        actionBar.prepareForReuse()
        embeddedTweetView.prepareForReuse()

        showRetweetBanner(false)

        embeddedTweetWrapper.isHidden = true
        embeddedWrapperHeightConstraint?.isActive = true

        separatorView.isHidden = false
        onAvatarTap = nil
        onTweetTap = nil
        onShowLogin = nil
        onShowToast = nil
    }
}
