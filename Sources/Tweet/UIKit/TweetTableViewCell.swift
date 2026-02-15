//
//  TweetTableViewCell.swift
//  Tweet
//
//  Pure UIKit tweet cell — no UIHostingController.
//  Uses TweetCellContentView for layout and data binding.
//
import UIKit

class TweetTableViewCell: UITableViewCell {
    static let reuseIdentifier = "TweetTableViewCell"

    let tweetContentView = TweetCellContentView()
    private var currentTweetId: String?

    // Height change tracking
    private var lastNotifiedHeight: CGFloat = 0
    var onHeightChanged: (() -> Void)?

    // Padding constraints (updated per-configure to match list-level padding)
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    /// Publicly accessible tweet ID for video orchestration
    var tweetId: String? {
        return currentTweetId
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let currentHeight = bounds.height
        guard currentHeight > 0 else { return }

        if lastNotifiedHeight == 0 {
            // Initial layout after reuse — record height without firing callback.
            // This prevents a spurious beginUpdates/endUpdates on every first display.
            lastNotifiedHeight = currentHeight
            return
        }

        if abs(currentHeight - lastNotifiedHeight) > 1 {
            lastNotifiedHeight = currentHeight
            onHeightChanged?()
        }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupCell()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupCell() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        tweetContentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tweetContentView)

        leadingConstraint = tweetContentView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        trailingConstraint = tweetContentView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)

        let bottomConstraint = tweetContentView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        // Use high priority (not required) so the estimated row height
        // (UIView-Encapsulated-Layout-Height) doesn't conflict during initial layout.
        // The cell will still self-size correctly.
        bottomConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            tweetContentView.topAnchor.constraint(equalTo: contentView.topAnchor),
            leadingConstraint,
            trailingConstraint,
            bottomConstraint,
        ])
    }

    func configure(
        with tweet: Tweet,
        hproseInstance: HproseInstance,
        isPinned: Bool,
        isLastItem: Bool,
        parentViewController: UIViewController,
        leadingPadding: CGFloat,
        trailingPadding: CGFloat,
        videoCoordinator: VideoPlaybackCoordinator?,
        onAvatarTap: ((User) -> Void)?,
        onTweetTap: ((Tweet) -> Void)?,
        onShowLogin: (() -> Void)?,
        onShowToast: ((String, Bool) -> Void)?
    ) {
        currentTweetId = tweet.mid

        // Apply list-level padding to the cell content
        leadingConstraint.constant = leadingPadding
        trailingConstraint.constant = -trailingPadding

        tweetContentView.videoCoordinator = videoCoordinator
        tweetContentView.onAvatarTap = onAvatarTap
        tweetContentView.onTweetTap = onTweetTap
        tweetContentView.onShowLogin = onShowLogin
        tweetContentView.onShowToast = onShowToast

        tweetContentView.configure(
            tweet: tweet,
            hproseInstance: hproseInstance,
            isPinned: isPinned,
            isLastItem: isLastItem,
            parentViewController: parentViewController
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        lastNotifiedHeight = 0
        onHeightChanged = nil
        currentTweetId = nil
        tweetContentView.prepareForReuse()
    }
}
