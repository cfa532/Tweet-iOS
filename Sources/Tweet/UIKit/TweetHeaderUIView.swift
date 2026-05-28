//
//  TweetHeaderUIView.swift
//  Tweet
//
//  Pure UIKit tweet header replacing SwiftUI TweetItemHeaderView.
//  Shows author name, @username, timestamp, and ellipsis menu button.
//
import UIKit
import Combine

class TweetHeaderUIView: UIView {

    private let headerLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let menuButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        button.setImage(UIImage(systemName: "ellipsis", withConfiguration: config), for: .normal)
        button.tintColor = .secondaryLabel
        button.showsMenuAsPrimaryAction = true
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
        menuButton.menu = menu
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
                .foregroundColor: UIColor(named: "ThemeText") ?? UIColor.label
            ]
        )

        text.append(
            NSAttributedString(
                string: " @\(username) · \(timestamp)",
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .subheadline),
                    .foregroundColor: UIColor(named: "ThemeSecondaryText") ?? UIColor.secondaryLabel
                ]
            )
        )

        return text
    }

    func prepareForReuse() {
        tweetCancellables.removeAll()
        userCancellables.removeAll()
        currentTweetId = nil
        currentAuthorId = nil
        currentTweet = nil
        currentTimestampText = ""
        headerLabel.attributedText = nil
        menuButton.menu = nil
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
