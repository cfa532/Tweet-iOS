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

    private let tweetContentView = TweetCellContentView()
    private var currentTweetId: String?

    // Height change tracking
    private var lastNotifiedHeight: CGFloat = 0
    var onHeightChanged: (() -> Void)?

    /// Publicly accessible tweet ID for video orchestration
    var tweetId: String? {
        return currentTweetId
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let currentHeight = bounds.height
        if currentHeight > 0 && abs(currentHeight - lastNotifiedHeight) > 1 {
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

        NSLayoutConstraint.activate([
            tweetContentView.topAnchor.constraint(equalTo: contentView.topAnchor),
            tweetContentView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tweetContentView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tweetContentView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    func configure(
        with tweet: Tweet,
        hproseInstance: HproseInstance,
        isPinned: Bool,
        isLastItem: Bool,
        parentViewController: UIViewController,
        onAvatarTap: ((User) -> Void)?,
        onTweetTap: ((Tweet) -> Void)?,
        onShowLogin: (() -> Void)?,
        onShowToast: ((String, Bool) -> Void)?
    ) {
        currentTweetId = tweet.mid

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
