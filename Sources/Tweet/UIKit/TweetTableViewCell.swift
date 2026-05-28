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
    /// Last desired height we asked the table to grow to. Prevents firing
    /// onHeightChanged repeatedly for the same overflow before the table reacts.
    private var lastReportedDesiredHeight: CGFloat = 0
    /// Throttle the expensive Auto Layout fitting pass. Video cells can relayout
    /// several times while attaching layers/spinners; fitting the whole tweet
    /// hierarchy on every pass causes scroll hitches.
    private var lastHeightOverflowCheckTime: CFTimeInterval = 0
    private var lastHeightOverflowCheckWidth: CGFloat = 0
    private var pendingHeightOverflowCheck: DispatchWorkItem?
    private let heightOverflowCheckInterval: CFTimeInterval = 0.25
    /// Fired when the cell's content needs more height than the table allotted.
    /// Parameter is the Auto Layout fitting height the cell wants — the controller
    /// should cache this and re-layout the table.
    var onHeightChanged: ((CGFloat) -> Void)?
    var onContentExpanded: (() -> Void)?

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

        // 1. Track table-driven height changes (cell got resized externally).
        if lastNotifiedHeight == 0 {
            // Initial layout after reuse — record height without firing callback
            // to avoid a spurious beginUpdates/endUpdates on every first display.
            lastNotifiedHeight = currentHeight
            lastReportedDesiredHeight = 0
        } else if abs(currentHeight - lastNotifiedHeight) > 1 {
            lastNotifiedHeight = currentHeight
            // Bounds caught up — clear the reported-desired guard so the next
            // legitimate overflow can fire again.
            lastReportedDesiredHeight = 0
        }

        guard shouldCheckForHeightOverflow else { return }

        let now = CACurrentMediaTime()
        let widthChanged = abs(bounds.width - lastHeightOverflowCheckWidth) > 1
        if widthChanged || now - lastHeightOverflowCheckTime >= heightOverflowCheckInterval {
            runHeightOverflowCheck(now: now)
        } else if pendingHeightOverflowCheck == nil {
            let delay = heightOverflowCheckInterval - (now - lastHeightOverflowCheckTime)
            let scheduledTweetId = currentTweetId
            let workItem = DispatchWorkItem { [weak self] in
                self?.pendingHeightOverflowCheck = nil
                guard self?.currentTweetId == scheduledTweetId else { return }
                self?.runHeightOverflowCheck(now: CACurrentMediaTime())
            }
            pendingHeightOverflowCheck = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private var shouldCheckForHeightOverflow: Bool {
        window != nil &&
        currentTweetId != nil &&
        onHeightChanged != nil &&
        bounds.width > 0 &&
        bounds.height > 0
    }

    private func runHeightOverflowCheck(now: CFTimeInterval) {
        guard shouldCheckForHeightOverflow else { return }

        lastHeightOverflowCheckTime = now
        lastHeightOverflowCheckWidth = bounds.width

        // Detect content overflow: the cell wants more height than the table
        // allotted. This can happen when async content finishes loading after
        // initial render, but it is too expensive to run on every video relayout.
        let desired = ceil(tweetContentView.systemLayoutSizeFitting(
            CGSize(width: bounds.width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height)

        if desired > bounds.height + 1 && abs(desired - lastReportedDesiredHeight) > 1 {
            lastReportedDesiredHeight = desired
            onHeightChanged?(desired)
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
        onShowToast: ((String, Bool) -> Void)?,
        allowDeleteAll: Bool = false
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
        tweetContentView.onContentExpanded = { [weak self] in self?.onContentExpanded?() }

        tweetContentView.configure(
            tweet: tweet,
            hproseInstance: hproseInstance,
            isPinned: isPinned,
            isLastItem: isLastItem,
            parentViewController: parentViewController,
            allowDeleteAll: allowDeleteAll
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        lastNotifiedHeight = 0
        lastReportedDesiredHeight = 0
        lastHeightOverflowCheckTime = 0
        lastHeightOverflowCheckWidth = 0
        pendingHeightOverflowCheck?.cancel()
        pendingHeightOverflowCheck = nil
        onHeightChanged = nil
        onContentExpanded = nil
        currentTweetId = nil
        tweetContentView.prepareForReuse()
    }
}
