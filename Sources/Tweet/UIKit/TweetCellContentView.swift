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
    private static let authorLoadQueue = DispatchQueue(label: "TweetCellContentView.authorLoad")
    private static var authorCacheLoadsInFlight = Set<String>()
    private static var authorRefreshesInFlight = Set<String>()

    private struct MenuCacheKey: Equatable {
        let tweetId: String
        let isPinned: Bool
        let showDelete: Bool
        let isPrivate: Bool
        let isOwnTweet: Bool
        let showsAdminEdit: Bool
    }

    // MARK: - Subviews

    private let avatarView = AvatarUIView()
    private let headerView = TweetHeaderUIView()
    private let bodyView = TweetBodyUIView()
    private let actionBar = TweetActionBarView()
    private let embeddedTweetView = EmbeddedTweetUIView()
    private let separatorView: UIView = {
        let v = UIView()
        v.backgroundColor = XTheme.border.withAlphaComponent(0.7)
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
        iv.tintColor = XTheme.secondaryText
        return iv
    }()
    private let retweetLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = XTheme.secondaryText
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
        v.backgroundColor = .clear
        v.clipsToBounds = false
        // Prevent contentColumn (.fill distribution) from stretching the wrapper
        v.setContentHuggingPriority(.required, for: .vertical)
        return v
    }()

    // MARK: - Constraints managed dynamically
    private var embeddedWrapperHeightConstraint: NSLayoutConstraint?
    private var retweetBannerHeightConstraint: NSLayoutConstraint?
    // Mutually exclusive: mainStack top when banner is hidden vs visible
    private var mainStackTopDefault: NSLayoutConstraint!
    private var mainStackTopAfterBanner: NSLayoutConstraint!
    private var interfaceStyleTraitRegistration: UITraitChangeRegistration?

    // MARK: - State
    private var cancellables = Set<AnyCancellable>()
    private var retweetLoadTask: Task<Void, Never>?
    private var currentMenuKey: MenuCacheKey?
    private var cachedMenu: UIMenu?
    private var currentTweetId: String?
    private weak var currentTweet: Tweet?
    private weak var parentViewController: UIViewController?

    /// Per-feed video coordinator (set by TweetTableViewCell)
    weak var videoCoordinator: VideoPlaybackCoordinator?
    var cellHorizontalPadding: CGFloat = 16 {
        didSet {
            bodyView.cellHorizontalPadding = cellHorizontalPadding
            embeddedTweetView.cellHorizontalPadding = cellHorizontalPadding
        }
    }

    // Callbacks (set by cell / controller)
    var onAvatarTap: ((User) -> Void)?
    var onTweetTap: ((Tweet) -> Void)?
    var onShowLogin: (() -> Void)?
    var onShowToast: ((String, Bool) -> Void)?
    var onContentExpanded: (() -> Void)?
    /// Called when async content loads and may have changed cell height (retweet/embedded tweet).
    var onContentDidChangeHeightAsync: (() -> Void)?

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
        applyTheme()
        interfaceStyleTraitRegistration = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TweetCellContentView, _) in
            view.applyTheme()
        }

        // Add tap gesture to entire view for tweet detail navigation
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapGesture.cancelsTouchesInView = false
        addGestureRecognizer(tapGesture)

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

        contentColumn.setCustomSpacing(0, after: headerView)  // Space between header and body content
        contentColumn.setCustomSpacing(12, after: bodyView)
        contentColumn.setCustomSpacing(10, after: embeddedTweetWrapper)

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
            mainStack.bottomAnchor.constraint(equalTo: separatorView.topAnchor, constant: -8),

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

    func applyTheme() {
        backgroundColor = XTheme.background
        separatorView.backgroundColor = XTheme.border.withAlphaComponent(0.7)
        retweetIcon.tintColor = XTheme.secondaryText
        retweetLabel.textColor = XTheme.secondaryText
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

    // MARK: - Tap Handling

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // Handle taps on the entire tweet content area (like SwiftUI version)
        // Filter out only specific interactive elements: action buttons, avatar, menu, media
        guard let tweet = currentTweet else { return }

        // Get tap location
        let location = gesture.location(in: self)

        // Check if tap is anywhere on the action bar — never open detail view from it
        let actionBarLocation = gesture.location(in: actionBar)
        if actionBar.hitTest(actionBarLocation, with: nil) != nil {
            return
        }

        // Check if tap is on avatar (has its own tap handler)
        if avatarView.frame.contains(location) {
            return
        }

        // Check if tap is on menu button in header
        let headerLocation = gesture.location(in: headerView)
        if headerView.containsMenuButton(at: headerLocation) {
            return
        }

        // Check if tap is on embedded tweet view (quoted tweet)
        // Note: For pure retweets, embeddedTweetWrapper is hidden; for quoted tweets it's visible
        if !embeddedTweetWrapper.isHidden {
            let wrapperLocation = gesture.location(in: embeddedTweetWrapper)
            if embeddedTweetView.frame.contains(wrapperLocation) {
                // Embedded tweet handles its own tap
                return
            }
        }

        // Check if tap is on body view - need to verify it's not on media
        // Use bodyView's own coordinate system (bounds) — bodyView.frame is in contentColumn's
        // coordinate system, not self's, so frame.contains(location) gives wrong results for
        // taps on the right side of the media (e.g. the mute button).
        let bodyLocation = gesture.location(in: bodyView)
        if bodyView.bounds.contains(bodyLocation) {
            if bodyView.isAudioPlayerPoint(bodyLocation) {
                return
            }

            if bodyView.isURLLinkPoint(bodyLocation) {
                return
            }

            // Use hitTest to check if tap is on an interactive element in body (media grid)
            if let hitView = bodyView.hitTest(bodyLocation, with: nil),
               hitView !== bodyView {
                // Tap is on a subview of body (likely media or document)
                // Check if it's the media grid or a media cell
                var currentView: UIView? = hitView
                while currentView != nil && currentView !== bodyView {
                    if String(describing: type(of: currentView!)).contains("MediaGrid") ||
                       String(describing: type(of: currentView!)).contains("MediaCell") ||
                       String(describing: type(of: currentView!)).contains("Document") {
                        // Tap is on media or document - let it handle itself
                        return
                    }
                    currentView = currentView?.superview
                }
                // Tap is on the content label — let bodyView handle "More..." expansion
                if bodyView.isMoreLinkPoint(bodyLocation) {
                    return
                }
            }
        }

        // For all other taps (header text, body content text, padding, blank areas), navigate to detail
        // For PURE retweets (no own content), navigate to the original tweet's detail view
        // For quoted tweets (has own content), navigate to the quoting tweet's detail view

        // Check if this is a pure retweet (no own content) or quoted tweet (has own content)
        let hasOwnContent = (tweet.content != nil && !(tweet.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
            || (tweet.attachments != nil && !(tweet.attachments?.isEmpty ?? true))

        if !hasOwnContent,
           let originalTweetId = tweet.originalTweetId,
           let originalTweet = Tweet.getInstance(for: originalTweetId) {
            // Pure retweet: navigate to original tweet
            navigateToTweetDetail(originalTweet, source: "retweetBodyTap")
        } else {
            // Regular tweet or quoted tweet: navigate to current tweet
            navigateToTweetDetail(tweet, source: "tweetBodyTap")
        }
    }

    private func navigateToTweetDetail(_ tweet: Tweet, source: String) {
        NavigationStateManager.shared.markDetailNavigationPending(
            source: source,
            preserveFeedPlayback: Self.hasVideoAttachment(tweet)
        )
        onTweetTap?(tweet)
    }

    private static func hasVideoAttachment(_ tweet: Tweet) -> Bool {
        tweet.attachments?.contains { $0.type == .video || $0.type == .hls_video } == true
    }

    // MARK: - Configure

    func configure(tweet: Tweet, hproseInstance: HproseInstance,
                   isPinned: Bool, isLastItem: Bool,
                   parentViewController: UIViewController,
                   allowDeleteAll: Bool = false) {
        self.parentViewController = parentViewController
        self.currentTweet = tweet

        // Propagate per-feed coordinator to subviews
        bodyView.videoCoordinator = videoCoordinator
        embeddedTweetView.videoCoordinator = videoCoordinator

        // Forward content expansion callback (set before early return so it's always current)
        bodyView.onContentExpanded = { [weak self] in self?.onContentExpanded?() }
        embeddedTweetView.onContentExpanded = { [weak self] in self?.onContentExpanded?() }

        let showDelete = Gadget.canShowTweetDeleteMenu(
            appUser: hproseInstance.appUser,
            tweetAuthorId: tweet.authorId,
            allowDeleteAll: allowDeleteAll
        )
        separatorView.isHidden = isLastItem
        applyTweetMenuIfNeeded(
            tweet: tweet,
            isPinned: isPinned,
            showDelete: showDelete,
            hproseInstance: hproseInstance
        )

        // Skip if same tweet
        if currentTweetId == tweet.mid { return }
        retweetLoadTask?.cancel()
        retweetLoadTask = nil
        currentTweetId = tweet.mid
        cancellables.removeAll()

        let isRetweet = tweet.originalTweetId != nil && tweet.originalAuthorId != nil

        // Determine which tweet's content to show
        if isRetweet {
            configureAsRetweet(tweet: tweet, hproseInstance: hproseInstance,
                               isPinned: isPinned, parentViewController: parentViewController,
                               allowDeleteAll: allowDeleteAll)
        } else {
            configureAsRegularTweet(tweet: tweet, hproseInstance: hproseInstance,
                                    isPinned: isPinned, parentViewController: parentViewController,
                                    allowDeleteAll: allowDeleteAll)
        }

        // Load author if needed (background task)
        loadAuthorIfNeeded(tweet: tweet, hproseInstance: hproseInstance)

        // Also load original tweet's author for retweets/quoted tweets
        if isRetweet, let originalId = tweet.originalTweetId,
           let originalTweet = Tweet.getInstance(for: originalId),
           originalTweet.author == nil || originalTweet.author?.username == nil {
            loadAuthorIfNeeded(tweet: originalTweet, hproseInstance: hproseInstance)
        }

        // No deferred layout needed — Phase 3 media grid is pure UIKit with synchronous sizing
    }

    private func configureAsRegularTweet(tweet: Tweet, hproseInstance: HproseInstance,
                                          isPinned: Bool, parentViewController: UIViewController,
                                          allowDeleteAll: Bool = false) {
        // Hide retweet banner
        showRetweetBanner(false)

        // Hide embedded tweet wrapper and suppress its spacing
        embeddedTweetWrapper.isHidden = true
        embeddedWrapperHeightConstraint?.isActive = true
        contentColumn.setCustomSpacing(0, after: embeddedTweetWrapper)

        // Avatar
        if let author = tweet.author {
            avatarView.configure(user: author, size: 42)
            avatarView.onTap = { [weak self] in self?.onAvatarTap?(author) }
        } else {
            avatarView.onTap = nil
        }

        // Only observe author attachment when it is still missing.
        if tweet.author == nil {
            tweet.$author
                .compactMap { $0 }
                .first()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] author in
                    self?.avatarView.configure(user: author, size: 42)
                    self?.avatarView.onTap = { [weak self] in self?.onAvatarTap?(author) }
                }
                .store(in: &cancellables)
        }

        // Header
        headerView.configure(tweet: tweet)

        // Body
        bodyView.configure(tweet: tweet, isEmbedded: false, cellTweetId: nil,
                           parentViewController: parentViewController)
        bodyView.onTweetBodyTap = { [weak self] in self?.navigateToTweetDetail(tweet, source: "bodyMoreTap") }
        updateBodyToActionSpacing()

        // Action bar
        actionBar.configure(tweet: tweet, hproseInstance: hproseInstance)
        actionBar.parentViewController = parentViewController
        // Don't set onCommentTap - let action bar present comment composer directly
        actionBar.onShowLogin = { [weak self] in self?.onShowLogin?() }
        actionBar.onShowToast = { [weak self] msg, isError in self?.onShowToast?(msg, isError) }
    }

    private func configureAsRetweet(tweet: Tweet, hproseInstance: HproseInstance,
                                     isPinned: Bool, parentViewController: UIViewController,
                                     allowDeleteAll: Bool = false) {
        guard let originalTweetId = tweet.originalTweetId,
              let originalAuthorId = tweet.originalAuthorId else { return }

        // Check if this is a pure retweet (no own content) or quoted tweet (has own content)
        let hasOwnContent = (tweet.content != nil && !(tweet.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
            || (tweet.attachments != nil && !(tweet.attachments?.isEmpty ?? true))

        // Keep quoted-tweet configuration on the fast path by using only the in-memory singleton.
        let embeddedTweet = Tweet.getInstance(for: originalTweetId)

        if !hasOwnContent, let embeddedTweet {
            // Pure retweet: show original tweet's content directly, with retweet banner
            configurePureRetweet(tweet: tweet, originalTweet: embeddedTweet,
                                  hproseInstance: hproseInstance, isPinned: isPinned,
                                  parentViewController: parentViewController,
                                  allowDeleteAll: allowDeleteAll)
        } else if !hasOwnContent {
            configureQuotedTweet(tweet: tweet, embeddedTweet: nil,
                                  originalTweetId: originalTweetId,
                                  originalAuthorId: originalAuthorId,
                                  hproseInstance: hproseInstance, isPinned: isPinned,
                                  parentViewController: parentViewController,
                                  allowDeleteAll: allowDeleteAll)

            retweetLoadTask = Task { [weak self] in
                guard let loadedTweet = await TweetCacheManager.shared.fetchTweet(mid: originalTweetId),
                      !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.currentTweetId == tweet.mid else { return }
                    self.configurePureRetweet(
                        tweet: tweet,
                        originalTweet: loadedTweet,
                        hproseInstance: hproseInstance,
                        isPinned: isPinned,
                        parentViewController: parentViewController,
                        allowDeleteAll: allowDeleteAll
                    )
                    self.onContentDidChangeHeightAsync?()
                }
            }
        } else {
            // Quoted tweet: show own content + embedded original tweet below
            configureQuotedTweet(tweet: tweet, embeddedTweet: embeddedTweet,
                                  originalTweetId: originalTweetId,
                                  originalAuthorId: originalAuthorId,
                                  hproseInstance: hproseInstance, isPinned: isPinned,
                                  parentViewController: parentViewController,
                                  allowDeleteAll: allowDeleteAll)
        }
    }

    private func configurePureRetweet(tweet: Tweet, originalTweet: Tweet,
                                       hproseInstance: HproseInstance, isPinned: Bool,
                                       parentViewController: UIViewController,
                                       allowDeleteAll: Bool = false) {
        // Show retweet banner above the tweet
        showRetweetBanner(true)

        if tweet.author?.mid == hproseInstance.appUser.mid {
            retweetLabel.text = NSLocalizedString("Forwarded by you", comment: "")
        } else {
            let name = tweet.author?.name ?? tweet.author?.username ?? ""
            retweetLabel.text = String(format: NSLocalizedString("Forwarded by %@", comment: ""), name)
        }

        // Hide embedded tweet wrapper (content shown directly) and suppress its spacing
        embeddedTweetWrapper.isHidden = true
        embeddedWrapperHeightConstraint?.isActive = true
        contentColumn.setCustomSpacing(0, after: embeddedTweetWrapper)

        // Avatar from original tweet's author
        if let author = originalTweet.author {
            avatarView.configure(user: author, size: 42)
            avatarView.onTap = { [weak self] in self?.onAvatarTap?(author) }
        }

        // Subscribe to original tweet's author appearing (may load async)
        originalTweet.$author
            .compactMap { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] author in
                self?.avatarView.configure(user: author, size: 42)
                self?.avatarView.onTap = { [weak self] in self?.onAvatarTap?(author) }
            }
            .store(in: &cancellables)

        // Header from original tweet
        headerView.configure(tweet: originalTweet)

        // Body from original tweet
        bodyView.configure(tweet: originalTweet, isEmbedded: false, cellTweetId: tweet.mid,
                           parentViewController: parentViewController)
        bodyView.onTweetBodyTap = { [weak self] in self?.navigateToTweetDetail(originalTweet, source: "retweetBodyMoreTap") }
        updateBodyToActionSpacing()

        // Action bar on original tweet
        actionBar.configure(tweet: originalTweet, hproseInstance: hproseInstance)
        actionBar.parentViewController = parentViewController
        // Don't set onCommentTap - let action bar present comment composer directly
        actionBar.onShowLogin = { [weak self] in self?.onShowLogin?() }
        actionBar.onShowToast = { [weak self] msg, isError in self?.onShowToast?(msg, isError) }
    }

    private func configureQuotedTweet(tweet: Tweet, embeddedTweet: Tweet?,
                                       originalTweetId: String, originalAuthorId: String,
                                       hproseInstance: HproseInstance, isPinned: Bool,
                                       parentViewController: UIViewController,
                                       allowDeleteAll: Bool = false) {
        // Hide retweet banner
        showRetweetBanner(false)

        // Show embedded tweet wrapper and restore its spacing
        embeddedTweetWrapper.isHidden = false
        embeddedWrapperHeightConstraint?.isActive = false
        contentColumn.setCustomSpacing(10, after: embeddedTweetWrapper)

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

        // Body from quoting tweet
        bodyView.configure(tweet: tweet, isEmbedded: false, cellTweetId: nil,
                           parentViewController: parentViewController)
        bodyView.onTweetBodyTap = { [weak self] in self?.navigateToTweetDetail(tweet, source: "quotedBodyMoreTap") }
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
        embeddedTweetView.onTap = { [weak self] t in self?.navigateToTweetDetail(t, source: "embeddedTweetTap") }
        embeddedTweetView.onAsyncConfigured = { [weak self] in self?.onContentDidChangeHeightAsync?() }

        // Action bar on quoting tweet
        actionBar.configure(tweet: tweet, hproseInstance: hproseInstance)
        actionBar.parentViewController = parentViewController
        // Don't set onCommentTap - let action bar present comment composer directly
        actionBar.onShowLogin = { [weak self] in self?.onShowLogin?() }
        actionBar.onShowToast = { [weak self] msg, isError in self?.onShowToast?(msg, isError) }
    }

    /// Adjust body→action spacing (or body→embedded spacing for quoted tweets)
    private func updateBodyToActionSpacing() {
        let spacing: CGFloat
        if !embeddedTweetWrapper.isHidden {
            // Quoted tweet: body → embedded tweet needs consistent spacing
            spacing = 12
        } else {
            // Regular/retweet: body → action bar spacing depends on caption
            spacing = bodyView.isCaptionVisible ? 4 : 10
        }
        contentColumn.setCustomSpacing(spacing, after: bodyView)
    }

    // MARK: - Author Loading

    private static func beginAuthorCacheLoad(_ authorId: String) -> Bool {
        authorLoadQueue.sync {
            authorCacheLoadsInFlight.insert(authorId).inserted
        }
    }

    private static func endAuthorCacheLoad(_ authorId: String) {
        _ = authorLoadQueue.sync {
            authorCacheLoadsInFlight.remove(authorId)
        }
    }

    private static func beginAuthorRefresh(_ authorId: String) -> Bool {
        authorLoadQueue.sync {
            authorRefreshesInFlight.insert(authorId).inserted
        }
    }

    private static func endAuthorRefresh(_ authorId: String) {
        _ = authorLoadQueue.sync {
            authorRefreshesInFlight.remove(authorId)
        }
    }

    private func requestAuthorRefreshIfNeeded(authorId: String, hproseInstance: HproseInstance) {
        guard Self.beginAuthorRefresh(authorId) else { return }
        Task(priority: .background) {
            // Yield before the first @MainActor hop so the initial render frame
            // and UIKit event processing can complete before background refreshes pile on.
            await Task.yield()
            _ = try? await hproseInstance.fetchUser(authorId)
            Self.endAuthorRefresh(authorId)
        }
    }

    private func loadAuthorIfNeeded(tweet: Tweet, hproseInstance: HproseInstance) {
        let authorId = tweet.authorId

        if tweet.author == nil {
            // Reuse any already-populated singleton immediately on the main path.
            let singletonAuthor = User.getInstance(mid: authorId)
            if singletonAuthor.username != nil {
                tweet.author = singletonAuthor
                if singletonAuthor.baseUrl == nil {
                    requestAuthorRefreshIfNeeded(authorId: authorId, hproseInstance: hproseInstance)
                }
                return
            }

            guard Self.beginAuthorCacheLoad(authorId) else {
                tweet.author = singletonAuthor
                return
            }

            Task {
                defer { Self.endAuthorCacheLoad(authorId) }
                let cachedAuthor = await TweetCacheManager.shared.fetchUser(mid: authorId)
                await MainActor.run {
                    guard tweet.author == nil || tweet.author?.username == nil else { return }
                    if cachedAuthor.username != nil {
                        tweet.author = cachedAuthor
                    } else {
                        tweet.author = User.getInstance(mid: authorId)
                    }
                }
                requestAuthorRefreshIfNeeded(authorId: authorId, hproseInstance: hproseInstance)
            }
        } else if tweet.author?.username == nil || tweet.author?.baseUrl == nil {
            requestAuthorRefreshIfNeeded(authorId: authorId, hproseInstance: hproseInstance)
        }
    }

    // MARK: - Menu Creation

    private func applyTweetMenuIfNeeded(tweet: Tweet, isPinned: Bool, showDelete: Bool,
                                        hproseInstance: HproseInstance) {
        let showsAdminEdit = Gadget.isResearchAdminUser(hproseInstance.appUser)
        let key = MenuCacheKey(
            tweetId: tweet.mid,
            isPinned: isPinned,
            showDelete: showDelete,
            isPrivate: tweet.isPrivate == true,
            isOwnTweet: tweet.authorId == hproseInstance.appUser.mid,
            showsAdminEdit: showsAdminEdit
        )

        if currentMenuKey != key {
            cachedMenu = createTweetMenu(
                tweet: tweet,
                isPinned: isPinned,
                showDelete: showDelete,
                showsAdminEdit: showsAdminEdit,
                hproseInstance: hproseInstance
            )
            currentMenuKey = key
        }

        if let cachedMenu {
            headerView.setMenu(cachedMenu)
        }
    }

    private func createTweetMenu(tweet: Tweet, isPinned: Bool, showDelete: Bool, showsAdminEdit: Bool,
                                  hproseInstance: HproseInstance) -> UIMenu {
        var actions: [UIAction] = []

        // Copy Tweet ID
        let truncatedId = String(tweet.mid.prefix(8)) + "..."
        let copyAction = UIAction(title: truncatedId, image: UIImage(systemName: "doc.on.clipboard")) { _ in
            UIPasteboard.general.string = tweet.mid
        }
        actions.append(copyAction)

        // Filter Content
        let filterAction = UIAction(title: NSLocalizedString("Filter Content", comment: "Menu item"),
                                     image: UIImage(systemName: "line.3.horizontal.decrease.circle")) { _ in
            // TODO: Show filter sheet
            print("Filter content tapped")
        }
        actions.append(filterAction)

        if showsAdminEdit {
            let editAction = UIAction(
                title: NSLocalizedString("Edit content (admin)", comment: "Admin research menu"),
                image: UIImage(systemName: "pencil.line")
            ) { [weak self] _ in
                guard let self, let pvc = self.parentViewController else { return }
                let sheet = UIHostingController(
                    rootView: AdminTweetContentEditSheet(tweet: tweet).environmentObject(hproseInstance)
                )
                sheet.modalPresentationStyle = .pageSheet
                pvc.present(sheet, animated: true)
            }
            actions.append(editAction)
        }

        // Report (only for others' tweets)
        if tweet.authorId != hproseInstance.appUser.mid {
            let reportAction = UIAction(title: NSLocalizedString("Report Tweet", comment: "Menu item"),
                                        image: UIImage(systemName: "flag"),
                                        attributes: .destructive) { _ in
                // TODO: Show report sheet
                print("Report tapped")
            }
            actions.append(reportAction)
        }

        // Pin/Unpin (only for own tweets)
        if tweet.authorId == hproseInstance.appUser.mid {
            let pinTitle = isPinned ? NSLocalizedString("Unpin", comment: "Menu item") : NSLocalizedString("Pin", comment: "Menu item")
            let pinIcon = isPinned ? "pin.slash" : "pin"
            let pinAction = UIAction(title: pinTitle, image: UIImage(systemName: pinIcon)) { _ in
                Task {
                    do {
                        if let newPinStatus = try await hproseInstance.togglePinnedTweet(tweetId: tweet.mid) {
                            NotificationCenter.default.post(
                                name: .tweetPinStatusChanged,
                                object: nil,
                                userInfo: ["tweetId": tweet.mid, "isPinned": newPinStatus]
                            )
                        }
                    } catch {
                        print("Pin toggle failed: \(error)")
                    }
                }
            }
            actions.append(pinAction)

            // Privacy Toggle
            let privacyTitle = tweet.isPrivate == true ?
                NSLocalizedString("Make Public", comment: "Menu item") :
                NSLocalizedString("Make Private", comment: "Menu item")
            let privacyIcon = tweet.isPrivate == true ? "globe" : "lock"
            let privacyAction = UIAction(title: privacyTitle, image: UIImage(systemName: privacyIcon)) { _ in
                Task {
                    do {
                        let newPrivacy = try await hproseInstance.toggleTweetPrivacy(tweetId: tweet.mid)
                        await MainActor.run {
                            tweet.isPrivate = newPrivacy
                            TweetCacheManager.shared.saveTweet(tweet, userId: tweet.authorId)
                            NotificationCenter.default.post(
                                name: .tweetPrivacyChanged,
                                object: nil,
                                userInfo: ["tweetId": tweet.mid]
                            )
                        }
                    } catch {
                        print("Privacy toggle failed: \(error)")
                    }
                }
            }
            actions.append(privacyAction)

        }

        // Delete — shown for own tweets, or for any tweet when allowDeleteAll is true (main feed)
        if showDelete {
            let deleteAction = UIAction(title: NSLocalizedString("Delete", comment: "Menu item"),
                                        image: UIImage(systemName: "trash"),
                                        attributes: .destructive) { _ in
                // Optimistic UI update — remove immediately
                NotificationCenter.default.post(
                    name: .tweetDeleted,
                    object: nil,
                    userInfo: ["tweetId": tweet.mid]
                )
                Task {
                    do {
                        _ = try await hproseInstance.deleteTweet(tweet.mid, tweetAuthorId: tweet.authorId)
                    } catch {
                        print("DEBUG: [TweetCellContentView] deleteTweet FAILED — raw error: \(error) | localizedDescription: \(error.localizedDescription)")
                        // Restore tweet on failure
                        TweetDeletionRegistry.shared.unmarkDeleted(tweet.mid)
                        NotificationCenter.default.post(
                            name: .tweetRestored,
                            object: nil,
                            userInfo: ["tweetId": tweet.mid]
                        )
                        NotificationCenter.default.post(
                            name: .errorOccurred,
                            object: NSError(domain: "TweetDeletion", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to delete tweet: \(ErrorMessageHelper.userFriendlyMessage(from: error))"])
                        )
                    }
                }
            }
            actions.append(deleteAction)
        }

        return UIMenu(title: "", children: actions)
    }

    // MARK: - Visibility

    /// Forward media visibility to the body's media grid and embedded tweet's media grid
    func setMediaVisible(_ visible: Bool) {
        bodyView.mediaGridView.isGridVisible = visible

        // Also forward to embedded tweet's media grid if it's visible
        if !embeddedTweetWrapper.isHidden {
            embeddedTweetView.setMediaVisible(visible)
        }
    }

    /// Returns video identifiers for on-screen media cells in both the main body and embedded tweet.
    func onScreenVideoIdentifiers(visibleRect: CGRect, coordinateSpace: UIView) -> [String] {
        var result = bodyView.mediaGridView.onScreenVideoIdentifiers(
            visibleRect: visibleRect, coordinateSpace: coordinateSpace
        )
        if !embeddedTweetWrapper.isHidden {
            result += embeddedTweetView.onScreenVideoIdentifiers(
                visibleRect: visibleRect, coordinateSpace: coordinateSpace
            )
        }
        return result
    }

    func mediaVisibilityIdentifiers(visibleRect: CGRect, coordinateSpace: UIView) -> (loadVisible: [String], continuePlayback: [String], playable: [String]) {
        let bodyResult = bodyView.mediaGridView.mediaVisibilityIdentifiers(
            visibleRect: visibleRect,
            coordinateSpace: coordinateSpace
        )
        var loadVisible = bodyResult.loadVisible
        var continuePlayback = bodyResult.continuePlayback
        var playable = bodyResult.playable

        if !embeddedTweetWrapper.isHidden {
            let embeddedResult = embeddedTweetView.mediaVisibilityIdentifiers(
                visibleRect: visibleRect,
                coordinateSpace: coordinateSpace
            )
            loadVisible += embeddedResult.loadVisible
            continuePlayback += embeddedResult.continuePlayback
            playable += embeddedResult.playable
        }

        return (loadVisible, continuePlayback, playable)
    }

    func refreshVideoLayersAfterForeground() {
        bodyView.mediaGridView.refreshVideoLayersAfterForeground()
        if !embeddedTweetWrapper.isHidden {
            embeddedTweetView.refreshVideoLayersAfterForeground()
        }
    }

    func prepareMediaForBackground(aggressive: Bool = false) {
        bodyView.mediaGridView.prepareMediaForBackground(aggressive: aggressive)
        if !embeddedTweetWrapper.isHidden {
            embeddedTweetView.prepareMediaForBackground(aggressive: aggressive)
        }
    }

    // MARK: - Reuse

    func prepareForReuse() {
        retweetLoadTask?.cancel()
        retweetLoadTask = nil
        cancellables.removeAll()
        currentMenuKey = nil
        cachedMenu = nil
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
        onContentExpanded = nil
    }
}
