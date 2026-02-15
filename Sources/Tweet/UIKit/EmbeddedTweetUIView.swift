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

    // Content wrapper (avatar + header + body)
    private let contentStack: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.alignment = .top
        sv.spacing = 8
        return sv
    }()

    private let textStack: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.spacing = 0
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
        backgroundColor = .systemGray4.withAlphaComponent(0.6)
        layer.cornerRadius = 8
        clipsToBounds = true

        // Prevent parent stack from stretching this view
        setContentHuggingPriority(.required, for: .vertical)

        // Content layout: [Avatar | [Header, Body]]
        textStack.addArrangedSubview(headerView)
        textStack.addArrangedSubview(bodyView)

        contentStack.addArrangedSubview(avatarView)
        contentStack.addArrangedSubview(textStack)

        addSubview(contentStack)
        addSubview(placeholderView)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.translatesAutoresizingMaskIntoConstraints = false

        // Content stack constraints (always active except bottom)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),

            avatarView.widthAnchor.constraint(equalToConstant: 40),
            avatarView.heightAnchor.constraint(equalToConstant: 40),

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
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
    }

    @objc private func handleTap() {
        guard let tweet = loadedTweet else { return }
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
            avatarView.configure(user: author, size: 40)
        }
        headerView.configure(tweet: tweet)
        bodyView.videoCoordinator = videoCoordinator
        bodyView.configure(tweet: tweet, isEmbedded: true,
                           cellTweetId: quotingTweetId,
                           parentViewController: parentViewController)

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

        // 2. Check disk cache synchronously
        if let cached = TweetCacheManager.shared.fetchTweetSync(mid: originalTweetId) {
            configure(tweet: cached, quotingTweetId: quotingTweet.mid,
                      parentViewController: parentViewController)
            registerVideoRelationship(quotingTweet: quotingTweet, originalTweet: cached)
        } else {
            showPlaceholder()
        }

        // 3. Fetch from server asynchronously
        loadTask = Task { [weak self] in
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

        VideoLoadingManager.shared.registerRetweetRelationship(
            retweetId: quotingTweet.mid,
            originalTweetId: originalTweet.mid
        )
    }

    // MARK: - Visibility

    /// Forward media visibility to the embedded tweet's body media grid
    func setMediaVisible(_ visible: Bool) {
        bodyView.mediaGridView.isGridVisible = visible
    }

    func refreshVideoLayersAfterForeground() {
        bodyView.mediaGridView.refreshVideoLayersAfterForeground()
    }

    func showVideoThumbnailsForBackground() {
        bodyView.mediaGridView.showVideoThumbnailsForBackground()
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
