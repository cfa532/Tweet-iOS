//
//  EmbeddedTweetUIView.swift
//  Tweet
//
//  Compact original-tweet preview in a feed quote.
//
import UIKit
import Combine

class EmbeddedTweetUIView: UIView {
    static let aspectRatio: CGFloat = 2
    static let placeholderHeight: CGFloat = 36
    // The card's left edge extends past the feed's content column by this inset.
    static let leadingExtension: CGFloat = 4

    private let avatarView = AvatarUIView()
    private let headerView = TweetHeaderUIView()
    private let previewRow = UIView()
    private let attachmentView = UIView()
    private let thumbnailView = UIImageView()
    private let attachmentIcon = UIImageView()
    private let playBadge = UIImageView()
    private let textLabel = UILabel()
    private let contentStack = UIStackView()
    private let placeholderLabel = UILabel()

    private var cardHeight: NSLayoutConstraint!
    private var placeholderHeight: NSLayoutConstraint!
    private var contentBottom: NSLayoutConstraint!
    private var attachmentAspect: NSLayoutConstraint!
    private var emptyAttachmentWidth: NSLayoutConstraint!
    private var textLeading: NSLayoutConstraint!
    private var avatarSubscription: AnyCancellable?
    private var posterSubscription: AnyCancellable?
    private var imageRequestID: String?
    private var loadTask: Task<Void, Never>?
    private weak var loadedTweet: Tweet?

    var onTap: ((Tweet) -> Void)?
    var onAvatarTap: ((User) -> Void)?
    var onAsyncConfigured: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundColor = XTheme.cardBackground
        layer.borderWidth = 0.5
        layer.borderColor = XTheme.border.resolvedColor(with: traitCollection).cgColor
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: EmbeddedTweetUIView, _) in
            view.layer.borderColor = XTheme.border.resolvedColor(with: view.traitCollection).cgColor
        }

        let headerRow = UIStackView(arrangedSubviews: [avatarView, headerView])
        headerRow.alignment = .center
        headerRow.spacing = 6
        headerView.useCompactLayout()

        contentStack.axis = .vertical
        contentStack.spacing = 4
        contentStack.addArrangedSubview(headerRow)
        contentStack.addArrangedSubview(previewRow)
        textLabel.font = .preferredFont(forTextStyle: .subheadline)
        textLabel.textColor = XTheme.text
        textLabel.adjustsFontForContentSizeCategory = true
        // This fixed-size card is a feed preview. An unlimited label typesets the
        // entire quoted document during setText and intrinsic-size calculation,
        // even though the card clips it. Use the feed's existing preview line cap.
        textLabel.numberOfLines = TweetBodyUIView.maxContentLines
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        attachmentView.backgroundColor = .tertiarySystemFill
        attachmentView.layer.cornerRadius = 8
        attachmentView.clipsToBounds = true
        thumbnailView.contentMode = .scaleAspectFill
        attachmentIcon.contentMode = .scaleAspectFit
        attachmentIcon.tintColor = .secondaryLabel
        attachmentIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20)
        // High-contrast play badge for embedded videos; the small secondaryLabel
        // attachmentIcon is hard to read over an arbitrary poster frame.
        playBadge.image = UIImage(systemName: "play.fill")
        playBadge.tintColor = .white
        playBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 16)
        playBadge.contentMode = .center
        playBadge.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        playBadge.layer.cornerRadius = 16
        playBadge.layer.cornerCurve = .continuous
        playBadge.isHidden = true

        placeholderLabel.textColor = XTheme.secondaryText
        placeholderLabel.font = .preferredFont(forTextStyle: .subheadline)
        addSubview(placeholderLabel)
        addSubview(contentStack)
        previewRow.addSubview(attachmentView)
        previewRow.addSubview(textLabel)
        attachmentView.addSubview(thumbnailView)
        attachmentView.addSubview(attachmentIcon)
        attachmentView.addSubview(playBadge)
        for view in [placeholderLabel, contentStack, attachmentView, textLabel, thumbnailView, attachmentIcon, playBadge] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        cardHeight = heightAnchor.constraint(equalTo: widthAnchor, multiplier: 1 / Self.aspectRatio)
        placeholderHeight = heightAnchor.constraint(equalToConstant: Self.placeholderHeight)
        cardHeight.priority = UILayoutPriority(999)
        placeholderHeight.priority = .defaultHigh
        contentBottom = contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        attachmentAspect = attachmentView.widthAnchor.constraint(equalTo: attachmentView.heightAnchor)
        emptyAttachmentWidth = attachmentView.widthAnchor.constraint(equalToConstant: 0)
        textLeading = textLabel.leadingAnchor.constraint(equalTo: attachmentView.trailingAnchor)
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 20),
            avatarView.heightAnchor.constraint(equalToConstant: 20),
            headerRow.heightAnchor.constraint(equalToConstant: 22),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            placeholderLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            attachmentView.leadingAnchor.constraint(equalTo: previewRow.leadingAnchor),
            attachmentView.topAnchor.constraint(equalTo: previewRow.topAnchor),
            attachmentView.bottomAnchor.constraint(equalTo: previewRow.bottomAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: attachmentView.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: attachmentView.trailingAnchor),
            thumbnailView.topAnchor.constraint(equalTo: attachmentView.topAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: attachmentView.bottomAnchor),
            attachmentIcon.centerXAnchor.constraint(equalTo: attachmentView.centerXAnchor),
            attachmentIcon.centerYAnchor.constraint(equalTo: attachmentView.centerYAnchor),
            attachmentIcon.widthAnchor.constraint(equalToConstant: 24),
            attachmentIcon.heightAnchor.constraint(equalToConstant: 24),
            playBadge.centerXAnchor.constraint(equalTo: attachmentView.centerXAnchor),
            playBadge.centerYAnchor.constraint(equalTo: attachmentView.centerYAnchor),
            playBadge.widthAnchor.constraint(equalToConstant: 32),
            playBadge.heightAnchor.constraint(equalToConstant: 32),
            textLeading,
            textLabel.trailingAnchor.constraint(equalTo: previewRow.trailingAnchor),
            textLabel.topAnchor.constraint(equalTo: previewRow.topAnchor),
            textLabel.bottomAnchor.constraint(lessThanOrEqualTo: previewRow.bottomAnchor),
            emptyAttachmentWidth
        ])
        showPlaceholder()

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    @objc private func handleTap() {
        if let loadedTweet { onTap?(loadedTweet) }
    }

    func configure(tweet: Tweet) {
        if loadedTweet === tweet { return }
        loadTask?.cancel()
        loadTask = nil
        clearPreview()
        loadedTweet = tweet

        placeholderLabel.isHidden = true
        placeholderHeight.isActive = false
        contentStack.isHidden = false
        cardHeight.isActive = true
        contentBottom.isActive = true
        headerView.configure(tweet: tweet)
        let previewText = [tweet.title, tweet.content]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        // A line cap does not stop CoreText from shaping the whole string it is given,
        // so a long quoted document still stalled the cell. Hand the label only a
        // bounded prefix — the same bound the feed body uses — which is far more than
        // this clipped card can show.
        textLabel.text = TweetBodyUIView.contentForTruncationLayout(previewText).text

        avatarSubscription = tweet.$author
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] author in
                guard let self else { return }
                self.avatarView.configure(user: author, size: 20)
                self.avatarView.onTap = { [weak self] in self?.onAvatarTap?(author) }
            }

        if let attachment = tweet.attachments?.first {
            emptyAttachmentWidth.isActive = false
            attachmentAspect.isActive = true
            attachmentView.isHidden = false
            textLeading.constant = 8
            loadPreview(attachment, from: tweet)
        }
        TweetCacheManager.shared.markTweetAccessed(tweet.mid)
    }

    private func loadPreview(_ attachment: MimeiFileType, from tweet: Tweet) {
        let mediaId = attachment.mid
        let baseURL = tweet.mediaBaseURL ?? HproseInstance.shared.appUser.baseUrl ?? HproseInstance.baseUrl
        guard let url = attachment.getUrl(baseURL) else { return }

        switch attachment.type {
        case .image:
            attachmentIcon.image = UIImage(systemName: "photo")
            let requestId = UUID().uuidString
            imageRequestID = requestId
            GlobalImageLoadManager.shared.loadImageNormalPriority(
                id: requestId, url: url, attachment: attachment, baseUrl: baseURL
            ) { [weak self] image in
                guard let self, self.imageRequestID == requestId, let image else { return }
                self.thumbnailView.image = image
                self.attachmentIcon.isHidden = true
            }
        case .video, .hls_video:
            // Replace the low-contrast icon glyph with the play badge; the badge
            // stays visible over the poster frame once it loads.
            attachmentIcon.isHidden = true
            playBadge.isHidden = false
            if let poster = SharedAssetCache.shared.cachedThumbnail(for: mediaId) {
                thumbnailView.image = poster
            } else {
                posterSubscription = NotificationCenter.default.publisher(for: .videoThumbnailCached)
                    .compactMap { $0.userInfo?["mediaID"] as? String }
                    .filter { $0 == mediaId }
                    .receive(on: DispatchQueue.main)
                    .first()
                    .sink { [weak self] _ in
                        self?.thumbnailView.image = SharedAssetCache.shared.cachedThumbnail(for: mediaId)
                    }
                SharedAssetCache.shared.preloadPoster(for: url, mediaID: mediaId, tweetId: tweet.mid, mediaType: attachment.type)
            }
        case .audio:
            attachmentIcon.image = UIImage(systemName: "waveform")
        default:
            attachmentIcon.image = UIImage(systemName: "doc")
        }
    }

    func showPlaceholder(message: String = NSLocalizedString("Loading quoted tweet...", comment: "")) {
        loadTask?.cancel()
        loadTask = nil
        clearPreview()
        loadedTweet = nil
        placeholderLabel.text = message
        placeholderLabel.isHidden = false
        contentStack.isHidden = true
        contentBottom.isActive = false
        cardHeight.isActive = false
        placeholderHeight.isActive = true
    }

    func loadEmbeddedTweet(originalTweetId: String, originalAuthorId: String, hproseInstance: HproseInstance) {
        showPlaceholder()
        loadTask = Task { [weak self] in
            let cached = await TweetCacheManager.shared.fetchTweet(mid: originalTweetId)
            guard !Task.isCancelled else { return }
            let original: Tweet?
            if let cached {
                original = cached
            } else {
                original = try? await hproseInstance.getTweet(tweetId: originalTweetId, authorId: originalAuthorId)
            }
            guard let self, !Task.isCancelled else { return }
            self.loadTask = nil
            if let original {
                self.configure(tweet: original)
                self.onAsyncConfigured?()
            } else {
                self.showPlaceholder(message: NSLocalizedString("Original tweet not found", comment: ""))
            }
        }
    }

    private func clearPreview() {
        if let imageRequestID { GlobalImageLoadManager.shared.cancelLoad(id: imageRequestID) }
        imageRequestID = nil
        posterSubscription = nil
        avatarSubscription = nil
        avatarView.prepareForReuse()
        headerView.prepareForReuse()
        attachmentView.isHidden = true
        attachmentAspect.isActive = false
        emptyAttachmentWidth.isActive = true
        textLeading.constant = 0
        thumbnailView.image = nil
        attachmentIcon.image = nil
        attachmentIcon.isHidden = false
        playBadge.isHidden = true
        textLabel.text = nil
    }

    func prepareForReuse() {
        showPlaceholder()
        onTap = nil
        onAvatarTap = nil
        onAsyncConfigured = nil
    }

    deinit {
        loadTask?.cancel()
    }
}
