//
//  AvatarUIView.swift
//  Tweet
//
//  Pure UIKit avatar view replacing SwiftUI Avatar.
//  Uses ImageCacheManager directly for memory-efficient image loading.
//
import UIKit
import Combine

class AvatarUIView: UIView {

    private let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = .systemGray5
        return iv
    }()

    private let placeholderImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.image = UIImage(named: "manyone")
        iv.alpha = 0.3
        return iv
    }()

    private var loadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var notificationObservers: [NSObjectProtocol] = []
    private var currentUserId: String?
    private var currentAvatarId: String?
    private var avatarSize: CGFloat = 40
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        addSubview(placeholderImageView)
        addSubview(imageView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
    }

    @objc private func handleTap() {
        onTap?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        placeholderImageView.frame = bounds
        let cornerRadius = bounds.width / 2
        imageView.layer.cornerRadius = cornerRadius
        placeholderImageView.layer.cornerRadius = cornerRadius
    }

    func configure(user: User, size: CGFloat) {
        avatarSize = size
        updateSizeIfNeeded(size)

        // Skip if same user and avatar hasn't changed
        if currentUserId == user.mid && currentAvatarId == user.avatar {
            return
        }

        currentUserId = user.mid
        currentAvatarId = user.avatar

        // Clear previous subscriptions
        cancellables.removeAll()
        removeNotificationObservers()
        loadTask?.cancel()

        // Try loading avatar
        loadAvatarImage(user: user)

        // Subscribe to avatar changes
        user.$avatar
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak user] _ in
                guard let self, let user else { return }
                self.currentAvatarId = user.avatar
                self.loadAvatarImage(user: user)
            }
            .store(in: &cancellables)

        // Listen for user update notifications (baseUrl resolved)
        let userUpdateObserver = NotificationCenter.default.addObserver(
            forName: .userDidUpdate, object: nil, queue: .main
        ) { [weak self, weak user] notification in
            guard let self, let user,
                  let userId = notification.userInfo?["userId"] as? String,
                  userId == user.mid,
                  user.avatarUrl != nil else { return }
            // Cancel in-flight request (may be stuck on stale IP timeout)
            self.loadTask?.cancel()
            self.loadTask = nil
            // Only reload if avatar hasn't been displayed yet
            guard self.imageView.image == nil else { return }
            self.loadAvatarImage(user: user)
        }
        notificationObservers.append(userUpdateObserver)
    }

    private func updateSizeIfNeeded(_ size: CGFloat) {
        if widthConstraint == nil || heightConstraint == nil {
            let width = widthAnchor.constraint(equalToConstant: size)
            let height = heightAnchor.constraint(equalToConstant: size)
            NSLayoutConstraint.activate([width, height])
            widthConstraint = width
            heightConstraint = height
        } else {
            widthConstraint?.constant = size
            heightConstraint?.constant = size
        }
    }

    private func loadAvatarImage(user: User) {
        guard let avatarUrl = user.avatarUrl else {
            // No avatar URL - show placeholder
            imageView.image = nil
            placeholderImageView.isHidden = false
            return
        }

        let rawKey = user.avatar ?? (URL(string: avatarUrl)?.lastPathComponent ?? avatarUrl)
        let cacheKey = "avatar_\(rawKey)"
        let avatarAttachment = MimeiFileType(mid: cacheKey, mediaType: .image)

        // Check memory cache first (synchronous, fast)
        if let cached = ImageCacheManager.shared.getCompressedImageFromMemory(for: avatarAttachment) {
            imageView.image = cached
            placeholderImageView.isHidden = true
            return
        }

        // Show placeholder while loading
        placeholderImageView.isHidden = false

        // Load asynchronously
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            // Check disk cache
            if let cached = ImageCacheManager.shared.getCompressedImage(for: avatarAttachment) {
                await MainActor.run {
                    self?.imageView.image = cached
                    self?.placeholderImageView.isHidden = true
                }
                return
            }

            // Fetch from network
            guard let url = URL(string: avatarUrl) else {
                await MainActor.run { self?.placeholderImageView.isHidden = false }
                return
            }

            let result = await ImageCacheManager.shared.loadAndCacheImage(from: url, for: avatarAttachment)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                if let image = result {
                    self?.imageView.image = image
                    self?.placeholderImageView.isHidden = true
                } else {
                    self?.placeholderImageView.isHidden = false
                }
            }
        }
    }

    func prepareForReuse() {
        loadTask?.cancel()
        loadTask = nil
        cancellables.removeAll()
        removeNotificationObservers()
        imageView.image = nil
        placeholderImageView.isHidden = false
        currentUserId = nil
        currentAvatarId = nil
        onTap = nil
    }

    private func removeNotificationObservers() {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    deinit {
        loadTask?.cancel()
        removeNotificationObservers()
    }
}
