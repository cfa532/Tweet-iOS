//
//  TweetTableViewCell.swift
//  Tweet
//
//  Pure UIKit tweet cell — no UIHostingController.
//  Uses TweetCellContentView for layout and data binding.
//
import UIKit

// TEMPORARY (Jul 2026 fling-scroll stall investigation) — logs when a call on this
// instrumented path takes long enough to plausibly cause a dropped-frame/catch-up-jump
// scroll stall. Remove once the stall is root-caused.
enum StallLog {
    static let thresholdMs: Double = 4
    @inline(__always)
    static func measure<T>(_ label: String, _ extra: @autoclosure () -> String = "", _ block: () -> T) -> T {
        let start = CACurrentMediaTime()
        let result = block()
        let elapsedMs = (CACurrentMediaTime() - start) * 1000
        if elapsedMs >= thresholdMs {
            print("⏱️ [STALL] \(label) took \(String(format: "%.1f", elapsedMs))ms \(extra())")
        }
        return result
    }
}

class TweetTableViewCell: UITableViewCell {
    static let reuseIdentifier = "TweetTableViewCell"
    static let pinnedTweetsDividerHeight: CGFloat = 25

    let tweetContentView = TweetCellContentView()
    private let pinnedTweetsDivider = PinnedTweetsDividerView()
    private var currentTweetId: String?

    var onContentExpanded: (() -> Void)?
    var onContentDidChangeHeightAsync: (() -> Void)?
    var onRetweetUnavailable: ((String) -> Void)?

    // Padding constraints (updated per-configure to match list-level padding)
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!
    private var pinnedTweetsDividerHeightConstraint: NSLayoutConstraint!
    private var interfaceStyleTraitRegistration: UITraitChangeRegistration?

    /// Publicly accessible tweet ID for video orchestration
    var tweetId: String? {
        return currentTweetId
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
        applyTheme()
        interfaceStyleTraitRegistration = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: TweetTableViewCell, _) in
            cell.applyTheme()
        }

        tweetContentView.translatesAutoresizingMaskIntoConstraints = false
        pinnedTweetsDivider.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tweetContentView)
        contentView.addSubview(pinnedTweetsDivider)

        leadingConstraint = tweetContentView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        trailingConstraint = tweetContentView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)

        let bottomConstraint = pinnedTweetsDivider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        // Use high priority (not required) so the estimated row height
        // (UIView-Encapsulated-Layout-Height) doesn't conflict during initial layout.
        // The cell will still self-size correctly.
        bottomConstraint.priority = .defaultHigh

        pinnedTweetsDividerHeightConstraint = pinnedTweetsDivider.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tweetContentView.topAnchor.constraint(equalTo: contentView.topAnchor),
            leadingConstraint,
            trailingConstraint,
            tweetContentView.bottomAnchor.constraint(equalTo: pinnedTweetsDivider.topAnchor),
            pinnedTweetsDivider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pinnedTweetsDivider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            pinnedTweetsDividerHeightConstraint,
            bottomConstraint
        ])
    }

    func applyTheme() {
        backgroundColor = XTheme.background
        contentView.backgroundColor = XTheme.background
        selectedBackgroundView?.backgroundColor = XTheme.background
        tweetContentView.applyTheme()
        pinnedTweetsDivider.applyTheme()
    }

    func configure(
        with tweet: Tweet,
        hproseInstance: HproseInstance,
        isPinned: Bool,
        isLastPinnedTweet: Bool = false,
        isLastItem: Bool,
        parentViewController: UIViewController,
        leadingPadding: CGFloat,
        trailingPadding: CGFloat,
        rowWidth: CGFloat,
        videoCoordinator: VideoPlaybackCoordinator?,
        onAvatarTap: ((User) -> Void)?,
        onTweetTap: ((Tweet) -> Void)?,
        onShowLogin: (() -> Void)?,
        onShowToast: ((String, Bool) -> Void)?,
        allowDeleteAll: Bool = false,
        commentParentTweet: Tweet? = nil,
        savedParentTweetId: String? = nil
    ) {
        isHidden = false
        currentTweetId = tweet.mid
        applyTheme()
        pinnedTweetsDivider.isHidden = !isLastPinnedTweet
        pinnedTweetsDividerHeightConstraint.constant = isLastPinnedTweet ? Self.pinnedTweetsDividerHeight : 0

        // Apply list-level padding to the cell content
        leadingConstraint.constant = leadingPadding
        trailingConstraint.constant = -trailingPadding
        tweetContentView.cellHorizontalPadding = leadingPadding + trailingPadding
        tweetContentView.rowWidth = rowWidth

        tweetContentView.videoCoordinator = videoCoordinator
        tweetContentView.onAvatarTap = onAvatarTap
        tweetContentView.onTweetTap = onTweetTap
        tweetContentView.onShowLogin = onShowLogin
        tweetContentView.onShowToast = onShowToast
        tweetContentView.onContentExpanded = { [weak self] in self?.onContentExpanded?() }
        tweetContentView.onRetweetUnavailable = { [weak self] tweetId in
            self?.onRetweetUnavailable?(tweetId)
        }
        tweetContentView.onContentDidChangeHeightAsync = { [weak self] in
            guard let self else { return }
            self.onContentDidChangeHeightAsync?()
        }

        StallLog.measure("TweetTableViewCell.configure", "tweetId=\(tweet.mid)") {
            tweetContentView.configure(
                tweet: tweet,
                hproseInstance: hproseInstance,
                isPinned: isPinned,
                isLastItem: isLastItem,
                parentViewController: parentViewController,
                allowDeleteAll: allowDeleteAll,
                commentParentTweet: commentParentTweet,
                savedParentTweetId: savedParentTweetId
            )
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onContentExpanded = nil
        onContentDidChangeHeightAsync = nil
        onRetweetUnavailable = nil
        tweetContentView.onContentDidChangeHeightAsync = nil
        tweetContentView.onRetweetUnavailable = nil
        currentTweetId = nil
        tweetContentView.prepareForReuse()
        pinnedTweetsDivider.isHidden = true
        pinnedTweetsDividerHeightConstraint.constant = 0
    }
}

private final class PinnedTweetsDividerView: UIView {
    private let leftLine = UIView()
    private let dot = UIView()
    private let rightLine = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        isUserInteractionEnabled = false

        [leftLine, dot, rightLine].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        dot.layer.cornerRadius = 3
        NSLayoutConstraint.activate([
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalTo: dot.widthAnchor),

            leftLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leftLine.trailingAnchor.constraint(equalTo: dot.leadingAnchor, constant: -8),
            leftLine.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftLine.heightAnchor.constraint(equalToConstant: 1),

            rightLine.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            rightLine.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rightLine.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightLine.heightAnchor.constraint(equalToConstant: 1)
        ])

        applyTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme() {
        backgroundColor = XTheme.background
        let color = XTheme.secondaryText.withAlphaComponent(0.65)
        leftLine.backgroundColor = color
        dot.backgroundColor = color
        rightLine.backgroundColor = color
    }
}
