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

    private let nameLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = UIColor(named: "ThemeText") ?? .label
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let usernameLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = UIColor(named: "ThemeSecondaryText") ?? .secondaryLabel
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let dotLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = UIColor(named: "ThemeSecondaryText") ?? .secondaryLabel
        label.text = "·"
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }()

    private let timestampLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = UIColor(named: "ThemeSecondaryText") ?? .secondaryLabel
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
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

    private let stackView: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.alignment = .top
        sv.spacing = 2
        return sv
    }()

    private var tweetCancellables = Set<AnyCancellable>()
    private var userCancellables = Set<AnyCancellable>()
    private var currentTweetId: String?
    private var currentAuthorId: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        addSubview(stackView)
        addSubview(menuButton)

        stackView.addArrangedSubview(nameLabel)
        stackView.addArrangedSubview(usernameLabel)
        stackView.addArrangedSubview(dotLabel)
        stackView.addArrangedSubview(timestampLabel)

        // Default stackView.spacing = 2 matches old SwiftUI HStack(spacing:8) with .padding(.leading, -6)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        menuButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -4),

            menuButton.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
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
        timestampLabel.text = Self.timeDifference(from: tweet.timestamp)

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

        user.$name
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name in
                self?.nameLabel.text = name ?? "No one"
            }
            .store(in: &userCancellables)

        user.$username
            .receive(on: DispatchQueue.main)
            .sink { [weak self] username in
                self?.usernameLabel.text = "@\(username ?? NSLocalizedString("username", comment: "Default username"))"
            }
            .store(in: &userCancellables)
    }

    private func updateAuthorLabels(user: User?) {
        if let user = user {
            nameLabel.text = user.name ?? "No one"
            usernameLabel.text = "@\(user.username ?? NSLocalizedString("username", comment: "Default username"))"
            if currentAuthorId != user.mid {
                subscribeToUserChanges(user)
            }
        } else {
            userCancellables.removeAll()
            currentAuthorId = nil
            nameLabel.text = "No one"
            usernameLabel.text = "@\(NSLocalizedString("username", comment: "Default username"))"
        }
    }

    func prepareForReuse() {
        tweetCancellables.removeAll()
        userCancellables.removeAll()
        currentTweetId = nil
        currentAuthorId = nil
        currentTweet = nil
        nameLabel.text = nil
        usernameLabel.text = nil
        timestampLabel.text = nil
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
