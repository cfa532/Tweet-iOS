//
//  TweetHeaderUIView.swift
//  Tweet
//
//  Pure UIKit tweet header replacing SwiftUI TweetItemHeaderView.
//  Shows author name, @username, timestamp, and ellipsis menu button.
//
import UIKit
import Combine
import SwiftUI

class ImmediateMenuButton: UIButton, UIPopoverPresentationControllerDelegate {
    var menuActions: [UIAction] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(showImmediateMenu), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addTarget(self, action: #selector(showImmediateMenu), for: .touchUpInside)
    }

    @objc private func showImmediateMenu() {
        guard !menuActions.isEmpty, let presenter = nearestViewController else { return }
        let controller = ImmediateMenuViewController(actions: menuActions)
        controller.modalPresentationStyle = .popover
        controller.preferredContentSize = CGSize(width: 210, height: CGFloat(menuActions.count) * 48)
        guard let popover = controller.popoverPresentationController else { return }
        popover.sourceView = self
        popover.sourceRect = CGRect(x: bounds.maxX, y: bounds.maxY, width: 1, height: 1)
        popover.permittedArrowDirections = []
        popover.backgroundColor = XTheme.secondaryBackground
        popover.delegate = self
        presenter.present(controller, animated: true)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        .none
    }

    private var nearestViewController: UIViewController? {
        sequence(first: next, next: { $0?.next })
            .first { $0 is UIViewController } as? UIViewController
    }
}

private final class ImmediateMenuViewController: UITableViewController {
    private let actions: [UIAction]

    init(actions: [UIAction]) {
        self.actions = actions
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.isScrollEnabled = false
        tableView.rowHeight = 48
        tableView.separatorInset = .zero
        tableView.separatorColor = XTheme.border
        tableView.backgroundColor = XTheme.secondaryBackground
        view.backgroundColor = XTheme.secondaryBackground
        view.layer.cornerRadius = 4
        view.layer.borderWidth = 1 / UIScreen.main.scale
        view.layer.borderColor = XTheme.border.cgColor
        view.clipsToBounds = true
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        actions.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let action = actions[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = XTheme.secondaryBackground
        cell.textLabel?.text = action.title
        cell.imageView?.image = action.image
        cell.tintColor = action.attributes.contains(.destructive) ? .systemRed : .label
        cell.textLabel?.textColor = cell.tintColor
        cell.selectionStyle = .default
        let selectedBackground = UIView()
        selectedBackground.backgroundColor = XTheme.border.withAlphaComponent(0.35)
        cell.selectedBackgroundView = selectedBackground
        cell.isUserInteractionEnabled = !action.attributes.contains(.disabled)
        cell.accessibilityTraits = action.attributes.contains(.destructive) ? [.button] : [.button]
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let action = actions[indexPath.row]
        dismiss(animated: true) {
            UIButton(primaryAction: action).sendActions(for: .primaryActionTriggered)
        }
    }
}

struct ImmediateMenuButtonView: UIViewRepresentable {
    let actions: [UIAction]

    func makeUIView(context: Context) -> ImmediateMenuButton {
        let button = ImmediateMenuButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        button.setImage(UIImage(systemName: "ellipsis", withConfiguration: config), for: .normal)
        button.tintColor = XTheme.secondaryText
        button.contentHorizontalAlignment = .left
        return button
    }

    func updateUIView(_ button: ImmediateMenuButton, context: Context) {
        button.menuActions = actions
    }
}

class TweetHeaderUIView: UIView {

    private final class MenuButton: ImmediateMenuButton {
        override var isHighlighted: Bool {
            get { false }
            set { super.isHighlighted = false }
        }

        override var isSelected: Bool {
            get { false }
            set { super.isSelected = false }
        }
    }

    private let headerLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let menuButton: MenuButton = {
        let button = MenuButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        button.setImage(UIImage(systemName: "ellipsis", withConfiguration: config), for: .normal)
        button.tintColor = XTheme.secondaryText
        return button
    }()

    private var tweetCancellables = Set<AnyCancellable>()
    private var userCancellables = Set<AnyCancellable>()
    private var currentTweetId: String?
    private var currentAuthorId: String?
    private var currentTimestampText = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        addSubview(headerLabel)
        addSubview(menuButton)

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        menuButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -4),

            menuButton.topAnchor.constraint(equalTo: topAnchor, constant: -10),
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 44),
            menuButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    /// Set the UIMenu for the menu button
    func setMenu(_ menu: UIMenu) {
        menuButton.menuActions = menu.children.compactMap { $0 as? UIAction }
    }

    /// Check if a tap location (in header view's coordinate space) is within the menu button
    func containsMenuButton(at point: CGPoint) -> Bool {
        return menuButton.frame.contains(point)
    }

    private weak var currentTweet: Tweet?

    func configure(tweet: Tweet) {
        currentTweet = tweet

        // Skip full reconfigure if same tweet
        if currentTweetId == tweet.mid {
            return
        }
        currentTweetId = tweet.mid
        tweetCancellables.removeAll()
        userCancellables.removeAll()
        currentAuthorId = nil

        // Set timestamp (static - doesn't change)
        currentTimestampText = Self.timeDifference(from: tweet.timestamp)

        // Set author info
        updateAuthorLabels(user: tweet.author)

        // Track author attachment/replacement without duplicating per-user subscriptions.
        tweet.$author
            .dropFirst()
            .removeDuplicates(by: { $0?.mid == $1?.mid })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] user in
                self?.updateAuthorLabels(user: user)
            }
            .store(in: &tweetCancellables)
    }

    private func subscribeToUserChanges(_ user: User) {
        userCancellables.removeAll()
        currentAuthorId = user.mid

        Publishers.CombineLatest(user.$name, user.$username)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name, username in
                self?.setHeaderText(name: name, username: username)
            }
            .store(in: &userCancellables)
    }

    private func updateAuthorLabels(user: User?) {
        if let user = user {
            setHeaderText(name: user.name, username: user.username)
            if currentAuthorId != user.mid {
                subscribeToUserChanges(user)
            }
        } else {
            userCancellables.removeAll()
            currentAuthorId = nil
            setHeaderText(name: nil, username: nil)
        }
    }

    private func setHeaderText(name: String?, username: String?) {
        let displayName = name?.isEmpty == false ? name! : "No one"
        let usernameText = username?.isEmpty == false
            ? username!
            : NSLocalizedString("username", comment: "Default username")

        headerLabel.attributedText = Self.makeHeaderText(
            name: displayName,
            username: usernameText,
            timestamp: currentTimestampText
        )
    }

    private static func makeHeaderText(name: String, username: String, timestamp: String) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: name,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .headline),
                .foregroundColor: XTheme.text
            ]
        )

        text.append(
            NSAttributedString(
                string: " @\(username) · \(timestamp)",
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .subheadline),
                    .foregroundColor: XTheme.secondaryText
                ]
            )
        )

        return text
    }

    /// Shared measurement label. Configured exactly like `headerLabel` so the number it
    /// returns is the height Auto Layout will give the real one — a fresh UILabel per call
    /// was also an allocation on the scroll critical path.
    private static let measurementLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    /// Height of the header label for `tweet` at `availableWidth`.
    ///
    /// NOT rounded up: the header view's height is the label's fitting height.
    ///
    /// ⚠️ This runs a UILabel/CoreText layout pass. It is used only for the EMBEDDED
    /// (quote) header, which exists on a small minority of rows. Do NOT call it from the
    /// top-level row height path: `estimatedHeightForRowAt` is invoked for every row when
    /// a paginated page is inserted, and typesetting 10-20 cold headers there measured as
    /// an 837ms main-thread stall on device. The cache below does not save you — the rows
    /// being inserted are exactly the cold ones. Measure headers off the main thread
    /// (TweetHeightPrewarmer) if the top-level path ever needs a real number.
    static func measuredHeaderHeight(for tweet: Tweet, availableWidth: CGFloat) -> CGFloat {
        if tweet.cachedHeaderHeight >= 0, tweet.cachedHeaderWidth == availableWidth {
            return tweet.cachedHeaderHeight
        }

        let displayName = tweet.author?.name?.isEmpty == false ? tweet.author!.name! : "No one"
        let usernameText = tweet.author?.username?.isEmpty == false
            ? tweet.author!.username!
            : NSLocalizedString("username", comment: "Default username")
        let attrText = makeHeaderText(
            name: displayName,
            username: usernameText,
            timestamp: timeDifference(from: tweet.timestamp)
        )
        let label = measurementLabel
        label.attributedText = attrText
        // TweetHeaderUIView always reserves the hidden menu button's 44pt width
        // plus the 4pt label-to-menu gap because hiding the button does not remove
        // its Auto Layout constraints.
        let labelWidth = max(10, availableWidth - 48)
        let height = label.sizeThatFits(CGSize(width: labelWidth, height: .greatestFiniteMagnitude)).height
        tweet.cachedHeaderHeight = height
        tweet.cachedHeaderWidth = availableWidth
        return height
    }

    func prepareForReuse() {
        tweetCancellables.removeAll()
        userCancellables.removeAll()
        currentTweetId = nil
        currentAuthorId = nil
        currentTweet = nil
        currentTimestampText = ""
        headerLabel.attributedText = nil
        menuButton.menuActions = []
    }

    // MARK: - Time Difference (ported from TweetItemHeaderView)

    static func timeDifference(from timestamp: Date) -> String {
        let timeInterval = Date().timeIntervalSince(timestamp)

        if timeInterval < 60 {
            return "now"
        } else if timeInterval < 3600 {
            return "\(Int(timeInterval / 60))m"
        } else if timeInterval < 86400 {
            return "\(Int(timeInterval / 3600))h"
        } else if timeInterval < 2592000 {
            return "\(Int(timeInterval / 86400))d"
        } else if timeInterval < 31536000 {
            return "\(Int(timeInterval / 2592000))mo"
        } else {
            return "\(Int(timeInterval / 31536000))y"
        }
    }
}
