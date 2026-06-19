//
//  EmbeddedTweetUIView.swift
//  Tweet
//
//  Pure UIKit embedded tweet view for retweets/quoted tweets.
//  Replaces SwiftUI EmbeddedTweetView within the feed cell.
//
import UIKit
import SwiftUI
import Combine

class EmbeddedTweetUIView: UIView {
    private let avatarView = AvatarUIView()
    private let headerView = TweetHeaderUIView()
    private let bodyView = TweetBodyUIView()

    // Placeholder shown while loading
    private let placeholderView: UIView = {
        let v = UIView()
        v.isHidden = true

        let circle = UIView()
        circle.backgroundColor = .systemGray5
        circle.layer.cornerRadius = 20
        circle.translatesAutoresizingMaskIntoConstraints = false

        let line1 = UIView()
        line1.backgroundColor = .systemGray6
        line1.layer.cornerRadius = 4
        line1.translatesAutoresizingMaskIntoConstraints = false

        let line2 = UIView()
        line2.backgroundColor = .systemGray6
        line2.layer.cornerRadius = 4
        line2.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(circle)
        v.addSubview(line1)
        v.addSubview(line2)

        NSLayoutConstraint.activate([
            circle.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            circle.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            circle.widthAnchor.constraint(equalToConstant: 40),
            circle.heightAnchor.constraint(equalToConstant: 40),

            line1.leadingAnchor.constraint(equalTo: circle.trailingAnchor, constant: 8),
            line1.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            line1.topAnchor.constraint(equalTo: v.topAnchor, constant: 12),
            line1.heightAnchor.constraint(equalToConstant: 20),

            line2.leadingAnchor.constraint(equalTo: circle.trailingAnchor, constant: 8),
            line2.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            line2.topAnchor.constraint(equalTo: line1.bottomAnchor, constant: 4),
            line2.heightAnchor.constraint(equalToConstant: 16),
        ])

        return v
    }()

    // Content wrapper (two rows: header row + body row)
    private let contentStack: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.alignment = .fill
        sv.spacing = 4
        return sv
    }()

    // Row 1: avatar + header side by side
    private let headerRow: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.alignment = .center
        sv.spacing = 6
        return sv
    }()

    // Mutually exclusive constraint groups — only one set active at a time
    private var contentStackBottomConstraint: NSLayoutConstraint!
    private var placeholderBottomConstraint: NSLayoutConstraint!
    private var placeholderHeightConstraint: NSLayoutConstraint!

    private var cancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var currentTweetId: String?
    private weak var parentViewController: UIViewController?

    /// Per-feed video coordinator (set by TweetCellContentView)
    weak var videoCoordinator: VideoPlaybackCoordinator?

    var onTap: ((Tweet) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundColor = XTheme.quotedTweetSurface
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        clipsToBounds = true

        // Prevent parent stack from stretching this view
        setContentHuggingPriority(.required, for: .vertical)

        // Row 1: [avatar | header]
        // Row 2: body (full width)
        headerRow.addArrangedSubview(avatarView)
        headerRow.addArrangedSubview(headerView)

        contentStack.addArrangedSubview(headerRow)
        contentStack.addArrangedSubview(bodyView)

        addSubview(contentStack)
        addSubview(placeholderView)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.translatesAutoresizingMaskIntoConstraints = false

        // Content stack constraints (always active except bottom)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            avatarView.widthAnchor.constraint(equalToConstant: 32),
            avatarView.heightAnchor.constraint(equalToConstant: 32),

            placeholderView.topAnchor.constraint(equalTo: topAnchor),
            placeholderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Mutually exclusive constraints — only one group active at a time
        contentStackBottomConstraint = contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        placeholderBottomConstraint = placeholderView.bottomAnchor.constraint(equalTo: bottomAnchor)
        placeholderHeightConstraint = placeholderView.heightAnchor.constraint(equalToConstant: 60)
        // Lower priority so parent's height=0 constraint wins when hidden in stack view
        placeholderHeightConstraint.priority = .defaultHigh
        placeholderBottomConstraint.priority = .defaultHigh

        // Start with placeholder active (content hidden)
        contentStack.isHidden = true
        placeholderView.isHidden = false
        contentStackBottomConstraint.isActive = false
        placeholderBottomConstraint.isActive = true
        placeholderHeightConstraint.isActive = true

        headerView.menuButton(visible: false)

        // Tap gesture for navigation
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let tweet = loadedTweet else { return }
        let bodyLocation = gesture.location(in: bodyView)
        if bodyView.bounds.contains(bodyLocation),
           bodyView.isURLLinkPoint(bodyLocation) || bodyView.isMoreLinkPoint(bodyLocation) {
            return
        }
        onTap?(tweet)
    }

    private weak var loadedTweet: Tweet?

    /// Configure with an already-loaded embedded tweet
    func configure(tweet: Tweet, quotingTweetId: String?,
                   parentViewController: UIViewController) {
        self.parentViewController = parentViewController
        self.loadedTweet = tweet

        if currentTweetId == tweet.mid { return }
        currentTweetId = tweet.mid

        // Show content, hide placeholder — swap constraint groups
        contentStack.isHidden = false
        placeholderView.isHidden = true
        placeholderBottomConstraint.isActive = false
        placeholderHeightConstraint.isActive = false
        contentStackBottomConstraint.isActive = true

        // Configure subviews
        if let author = tweet.author {
            avatarView.configure(user: author, size: 32)
        } else {
            // Author not yet loaded — subscribe to update avatar when it arrives
            tweet.$author
                .compactMap { $0 }
                .first()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] author in
                    self?.avatarView.configure(user: author, size: 32)
                }
                .store(in: &cancellables)
        }
        headerView.configure(tweet: tweet)
        bodyView.videoCoordinator = videoCoordinator
        bodyView.configure(tweet: tweet, isEmbedded: true,
                           cellTweetId: quotingTweetId,
                           parentViewController: parentViewController)
        bodyView.onTweetBodyTap = { [weak self] in
            guard let self, let tweet = self.loadedTweet else { return }
            self.onTap?(tweet)
        }

        // Reduce bottom padding when media is present but no caption
        // (image attachments have no caption, so the gap looks excessive)
        let hasMedia = tweet.attachments?.contains(where: { TweetBodyUIView.isMediaType($0.type) }) ?? false
        let reduceBottom = hasMedia && !bodyView.isCaptionVisible
        contentStackBottomConstraint.constant = reduceBottom ? 0 : -8

        // Mark as accessed for cache management
        TweetCacheManager.shared.markTweetAccessed(tweet.mid)

        // Invalidate layout so parent stack view and table view recalculate height
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// Show loading placeholder while embedded tweet is being fetched
    func showPlaceholder() {
        contentStack.isHidden = true
        placeholderView.isHidden = false
        contentStackBottomConstraint.isActive = false
        placeholderBottomConstraint.isActive = true
        placeholderHeightConstraint.isActive = true
        loadedTweet = nil
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// Load embedded tweet asynchronously (cache -> server)
    func loadEmbeddedTweet(originalTweetId: String, originalAuthorId: String,
                           quotingTweet: Tweet, hproseInstance: HproseInstance,
                           parentViewController: UIViewController) {
        self.parentViewController = parentViewController
        loadTask?.cancel()

        // 1. Check singleton cache synchronously
        if let cached = Tweet.getInstance(for: originalTweetId), cached.author != nil {
            configure(tweet: cached, quotingTweetId: quotingTweet.mid,
                      parentViewController: parentViewController)
            registerVideoRelationship(quotingTweet: quotingTweet, originalTweet: cached)
            return
        }

        showPlaceholder()

        // 2. Fetch from cache/server asynchronously so row configuration stays off the hot path.
        loadTask = Task { [weak self] in
            if let cached = await TweetCacheManager.shared.fetchTweet(mid: originalTweetId) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.configure(tweet: cached, quotingTweetId: quotingTweet.mid,
                                    parentViewController: parentViewController)
                    self?.registerVideoRelationship(quotingTweet: quotingTweet, originalTweet: cached)
                }
                return
            }

            if let serverTweet = try? await hproseInstance.getTweet(
                tweetId: originalTweetId, authorId: originalAuthorId
            ) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.configure(tweet: serverTweet, quotingTweetId: quotingTweet.mid,
                                    parentViewController: parentViewController)
                    self?.registerVideoRelationship(quotingTweet: quotingTweet, originalTweet: serverTweet)
                }
            }
        }
    }

    private func registerVideoRelationship(quotingTweet: Tweet, originalTweet: Tweet) {
        let coordinator = videoCoordinator ?? .shared
        let hasContentText = quotingTweet.content != nil &&
            !(quotingTweet.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasAttachments = quotingTweet.attachments != nil &&
            !(quotingTweet.attachments?.isEmpty ?? true)
        let hasOwnContent = hasContentText || hasAttachments

        if hasOwnContent {
            coordinator.addEmbeddedTweetVideos(
                quotingTweetId: quotingTweet.mid,
                embeddedTweet: originalTweet
            )
        } else {
            coordinator.addRetweetVideos(
                retweetId: quotingTweet.mid,
                originalTweet: originalTweet
            )
        }

    }

    // MARK: - Visibility

    /// Forward media visibility to the embedded tweet's body media grid
    func setMediaVisible(_ visible: Bool) {
        bodyView.mediaGridView.isGridVisible = visible
    }

    func onScreenVideoIdentifiers(visibleRect: CGRect, coordinateSpace: UIView) -> [String] {
        bodyView.mediaGridView.onScreenVideoIdentifiers(
            visibleRect: visibleRect, coordinateSpace: coordinateSpace
        )
    }

    func mediaVisibilityIdentifiers(visibleRect: CGRect, coordinateSpace: UIView) -> (loadVisible: [String], continuePlayback: [String], playable: [String]) {
        bodyView.mediaGridView.mediaVisibilityIdentifiers(
            visibleRect: visibleRect,
            coordinateSpace: coordinateSpace
        )
    }

    func refreshVideoLayersAfterForeground() {
        bodyView.mediaGridView.refreshVideoLayersAfterForeground()
    }

    func prepareVideosForBackground() {
        bodyView.mediaGridView.prepareVideosForBackground()
    }

    // MARK: - Intrinsic Size

    override var intrinsicContentSize: CGSize {
        // Placeholder needs an explicit height; content relies on constraints
        if contentStack.isHidden {
            return CGSize(width: UIView.noIntrinsicMetric, height: 60)
        }
        // Let auto-layout constraints determine the height (top/bottom pinned to contentStack)
        return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    // MARK: - Reuse

    func prepareForReuse() {
        loadTask?.cancel()
        loadTask = nil
        cancellables.removeAll()
        currentTweetId = nil
        loadedTweet = nil
        onTap = nil
        avatarView.prepareForReuse()
        headerView.prepareForReuse()
        bodyView.prepareForReuse()
        // Reset to placeholder state — swap constraint groups
        contentStack.isHidden = true
        placeholderView.isHidden = false
        contentStackBottomConstraint.constant = -8  // Reset to default
        contentStackBottomConstraint.isActive = false
        placeholderBottomConstraint.isActive = true
        placeholderHeightConstraint.isActive = true
        invalidateIntrinsicContentSize()
    }

    deinit {
        loadTask?.cancel()
    }
}

// MARK: - TweetHeaderUIView Extension (hide menu for embedded tweets)
extension TweetHeaderUIView {
    func menuButton(visible: Bool) {
        // Access the menu button to hide it in embedded tweets
        subviews.compactMap { $0 as? UIButton }.forEach { $0.isHidden = !visible }
    }
}
