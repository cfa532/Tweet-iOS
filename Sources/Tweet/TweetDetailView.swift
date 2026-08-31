import SwiftUI
import AVKit
import Combine
import UIKit

/// Comment list per detail-screen subject, keyed by that subject's mid.
///
/// Shared with `CommentDetailView`, whose subject is a comment and whose "comments" are
/// that comment's replies — the same relationship one level down.
///
/// Two tiers, mirroring Android: an in-process dictionary for same-session reopens, and
/// Core Data underneath so a cold start serves comments from disk instead of spinning on
/// the network. The durable rows are bucketed under the parent's mid, exactly as
/// Android's `TweetCacheManager.saveCommentsByParent` does, which also means they expire
/// with every other cached tweet in `deleteExpiredTweets()` rather than needing a purge
/// of their own.
@MainActor
final class TweetDetailCommentsCache {
    static let shared = TweetDetailCommentsCache()
    /// Matches Android's `getCachedCommentsByParent` limit.
    private static let persistedLimit: UInt = 200
    private var commentsByParentTweetId: [String: [Tweet]] = [:]

    private init() {}

    /// In-memory copy only. Callers that can await should prefer `persistedComments`.
    func comments(for parentTweetId: String) -> [Tweet]? {
        commentsByParentTweetId[parentTweetId]
    }

    /// Memory first, then the durable copy. Mirrors Android
    /// `TweetCacheManager.getCachedCommentsByParent`.
    func persistedComments(for parentTweetId: String) async -> [Tweet] {
        if let inMemory = commentsByParentTweetId[parentTweetId], !inMemory.isEmpty {
            return inMemory
        }
        let stored = await TweetCacheManager.shared.fetchCachedTweets(
            for: parentTweetId,
            page: 0,
            pageSize: Self.persistedLimit
        ).compactMap { $0 }
        let sorted = stored.sorted { $0.timestamp > $1.timestamp }
        if !sorted.isEmpty {
            commentsByParentTweetId[parentTweetId] = sorted
        }
        return sorted
    }

    func setComments(_ comments: [Tweet], for parentTweetId: String) {
        commentsByParentTweetId[parentTweetId] = comments
        for comment in comments {
            TweetCacheManager.shared.saveTweet(comment, userId: parentTweetId)
        }
    }
}

// MARK: - Bottom bar scroll tracker
// Observes scroll view and updates SwiftUI state for bottom bar visibility
@MainActor
private final class BottomBarScrollObserver: NSObject {
    private var observation: NSKeyValueObservation?
    private var idleWorkItem: DispatchWorkItem?
    private var previousOffset: CGFloat = 0
    weak var scrollView: UIScrollView?
    var onScrollChange: ((CGFloat, CGFloat, Bool, Bool) -> Void)?
    // (currentOffset, delta, isAtBottom, isInteracting)
    
    func attachToScrollView(_ scrollView: UIScrollView) {
        self.scrollView = scrollView
        previousOffset = scrollView.contentOffset.y
        observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, change in
            MainActor.assumeIsolated {
                guard let self = self, let y = change.newValue?.y else { return }
                let delta = y - self.previousOffset
                self.previousOffset = y

                // Check if we're at the bottom (within 50pt threshold)
                let contentHeight = scrollView.contentSize.height
                let scrollViewHeight = scrollView.bounds.height
                let contentOffsetY = y
                let isAtBottom = (contentHeight > 0 && scrollViewHeight > 0) &&
                                (contentOffsetY + scrollViewHeight >= contentHeight - 50)
                let isInteracting = scrollView.isTracking
                    || scrollView.isDragging
                    || scrollView.isDecelerating

                // Defer the SwiftUI state update off the current view-update cycle:
                // contentOffset KVO can fire synchronously during a SwiftUI layout pass,
                // and mutating @State in onScrollChange then triggers
                // "Modifying state during view update".
                DispatchQueue.main.async { [weak self] in
                    self?.onScrollChange?(y, delta, isAtBottom, isInteracting)
                }
                self.scheduleIdleReport(for: scrollView)
            }
        }
    }

    private func scheduleIdleReport(for scrollView: UIScrollView) {
        // One poll is enough while scrolling; recreating a DispatchWorkItem for every
        // contentOffset frame adds main-thread churn on the exact path we are protecting.
        guard idleWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self, weak scrollView] in
            guard let self else { return }
            self.idleWorkItem = nil
            guard let scrollView else { return }
            if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
                self.scheduleIdleReport(for: scrollView)
                return
            }

            let y = scrollView.contentOffset.y
            let isAtBottom = scrollView.contentSize.height > 0
                && scrollView.bounds.height > 0
                && y + scrollView.bounds.height >= scrollView.contentSize.height - 50
            self.onScrollChange?(y, 0, isAtBottom, false)
        }
        idleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }
    
    func reset() {
        previousOffset = 0
    }
    
    isolated deinit {
        idleWorkItem?.cancel()
        observation?.invalidate()
    }
}

// MARK: - Nav bar scroll tracker with UIKit overlay
// Uses a real UIView for the nav bar to bypass SwiftUI rendering pipeline entirely.
// KVO on UIScrollView.contentOffset drives the UIView transform directly.

@MainActor
private final class LargeHitButton: UIButton {
    var hitInset: UIEdgeInsets = UIEdgeInsets(top: -12, left: -16, bottom: -12, right: -24)
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.inset(by: hitInset).contains(point)
    }
}

@MainActor
private final class NavBarUIView: UIView {
    private let titleLabel = UILabel()
    private let backButton = LargeHitButton(type: .system)
    private var onBack: (() -> Void)?
    private var observation: NSKeyValueObservation?
    private var previousOffset: CGFloat = 0
    weak var scrollView: UIScrollView?

    init(onBack: @escaping () -> Void) {
        self.onBack = onBack
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        backgroundColor = XTheme.background

        // Back button
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        backButton.setImage(UIImage(systemName: "chevron.left", withConfiguration: config), for: .normal)
        backButton.tintColor = XTheme.text
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backButton)

        // Title
        titleLabel.text = NSLocalizedString("Tweet", comment: "Tweet detail screen title")
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = XTheme.text
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func backTapped() {
        onBack?()
    }

    func attachToScrollView(_ scrollView: UIScrollView) {
        self.scrollView = scrollView
        observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, change in
            MainActor.assumeIsolated {
                guard let self = self, let y = change.newValue?.y else { return }
                self.handleScroll(y, scrollView: scrollView)
            }
        }
    }

    private func handleScroll(_ y: CGFloat, scrollView: UIScrollView) {
        let delta = y - previousOffset
        previousOffset = y

        if y <= 0 {
            transform = .identity
            alpha = 1
            backButton.isEnabled = true
            return
        }

        // Check if we're at the bottom (within 50pt threshold)
        let contentHeight = scrollView.contentSize.height
        let scrollViewHeight = scrollView.bounds.height
        let contentOffsetY = y
        let isAtBottom = (contentHeight > 0 && scrollViewHeight > 0) && 
                        (contentOffsetY + scrollViewHeight >= contentHeight - 50)
        
        // If at bottom and scrolling up (delta negative), ignore to prevent bounce-induced nav bar reappearance
        if isAtBottom && delta < 0 {
            // Don't update nav bar position when bouncing at bottom
            return
        }

        // Proportional tracking: translate nav bar upward as user scrolls down
        let currentTY = transform.ty
        let newTY = max(-44.0, min(0.0, currentTY - delta))
        transform = CGAffineTransform(translationX: 0, y: newTY)
        alpha = CGFloat(max(0.0, 1.0 + newTY / 44.0))
        backButton.isEnabled = newTY > -22
    }

    func reset() {
        previousOffset = 0
        transform = .identity
        alpha = 1
        backButton.isEnabled = true
    }

    deinit {
        observation?.invalidate()
    }
}

// UIViewRepresentable wrapper that places NavBarUIView and attaches it to the parent UIScrollView
private struct NavBarOverlay: UIViewRepresentable {
    let onBack: () -> Void

    func makeUIView(context: Context) -> NavBarUIView {
        let navBar = NavBarUIView(onBack: onBack)
        // Find and attach to parent scroll view after hierarchy is built
        DispatchQueue.main.async {
            Self.findAndAttach(navBar: navBar)
        }
        return navBar
    }

    func updateUIView(_ uiView: NavBarUIView, context: Context) {}

    // Walk up to find common ancestor, then search downward for UIScrollView
    private static func findAndAttach(navBar: NavBarUIView) {
        var current: UIView? = navBar.superview
        while let ancestor = current {
            if let scrollView = findScrollView(in: ancestor) {
                navBar.attachToScrollView(scrollView)
                return
            }
            current = ancestor.superview
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            findAndAttach(navBar: navBar)
        }
    }

    private static func findScrollView(in view: UIView) -> UIScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? UIScrollView {
                return scrollView
            }
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }
}

// Coordinator to hold the observer
private class BottomBarScrollCoordinator: NSObject {
    var observer: BottomBarScrollObserver?
}

// UIViewRepresentable wrapper for bottom bar scroll tracking
private struct BottomBarScrollTracker: UIViewRepresentable {
    let onScrollChange: (CGFloat, CGFloat, Bool, Bool) -> Void
    
    func makeCoordinator() -> BottomBarScrollCoordinator {
        BottomBarScrollCoordinator()
    }
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        
        // Find and attach to parent scroll view after hierarchy is built
        DispatchQueue.main.async {
            Self.findAndAttach(view: view, coordinator: context.coordinator, onScrollChange: onScrollChange)
        }
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.observer?.onScrollChange = onScrollChange
    }
    
    private static func findAndAttach(view: UIView, coordinator: BottomBarScrollCoordinator, onScrollChange: @escaping (CGFloat, CGFloat, Bool, Bool) -> Void) {
        var current: UIView? = view.superview
        while let ancestor = current {
            if let scrollView = findScrollView(in: ancestor) {
                let observer = BottomBarScrollObserver()
                observer.onScrollChange = onScrollChange
                observer.attachToScrollView(scrollView)
                
                // Store observer in coordinator to keep it alive
                coordinator.observer = observer
                
                return
            }
            current = ancestor.superview
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            findAndAttach(view: view, coordinator: coordinator, onScrollChange: onScrollChange)
        }
    }
    
    private static func findScrollView(in view: UIView) -> UIScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? UIScrollView {
                return scrollView
            }
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }
}

// Custom text view that enables text selection without NavigationLink interference
@available(iOS 16.0, *)
struct SelectableTextView: UIViewRepresentable {
    let text: String
    
    private func makeAttributedString(_ text: String) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 3
        let attributedString = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: XTheme.text,
            .paragraphStyle: ps,
        ])
        applyDetectedLinks(to: attributedString)
        return attributedString
    }

    private func applyDetectedLinks(to attributedString: NSMutableAttributedString) {
        guard attributedString.length > 0,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return
        }

        let fullString = attributedString.string as NSString
        let fullRange = NSRange(location: 0, length: attributedString.length)
        detector.enumerateMatches(in: attributedString.string, options: [], range: fullRange) { match, _, _ in
            guard let match,
                  let url = match.url,
                  NSMaxRange(match.range) <= attributedString.length else { return }

            let matchedText = fullString.substring(with: match.range)
            let trimmedLength = matchedText.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:)］】》」'\"")).utf16.count
            let linkRange = NSRange(location: match.range.location, length: trimmedLength)
            guard linkRange.length > 0 else { return }

            attributedString.addAttributes([
                .link: url,
                .foregroundColor: XTheme.accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: linkRange)
        }
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        // isEditable must be cleared BEFORE any text is assigned. On a still-editable
        // text view, setAttributedText: runs the editable-input path, which reaches
        // +[UIDictationController sharedInstance] -> +[UIDictationConnection
        // isDictationAvailable] and dlopens AssistantServices on the main thread —
        // ~840ms on device, and it lands mid-scroll because SwiftUI builds this view
        // lazily during a layout pass.
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.linkTextAttributes = [
            .foregroundColor: XTheme.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.delegate = context.coordinator
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.attributedText = makeAttributedString(text)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.delegate = context.coordinator
        if uiView.text != text {
            uiView.attributedText = makeAttributedString(text)
        }
    }
    
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width - 32 // Account for padding
        uiView.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return size
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else {
                return defaultAction
            }
            return UIAction { _ in
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
    }
}

// Custom MediaCell for TweetDetailView that shows native video controls instead of going full-screen
@available(iOS 16.0, *)
@MainActor
private enum DetailImageLoadRegistry {
    static var activeCompressedLoads: Set<String> = []
}

@available(iOS 16.0, *)
struct DetailMediaCell: View {
    @ObservedObject var parentTweet: Tweet
    let attachmentIndex: Int
    let aspectRatio: Float
    let shouldLoadVideo: Bool
    @State private var image: UIImage?
    @State private var loading = false
    let showMuteButton: Bool
    @State private var hasRestoredPosition = false // Track if we've restored position
    @State private var foregroundObserver: NSObjectProtocol? = nil // Observer for app foreground events
    @State private var imageCacheObserver: NSObjectProtocol? = nil
    @State private var originalImageTask: Task<Void, Never>? = nil
    
    init(parentTweet: Tweet, attachmentIndex: Int, aspectRatio: Float = 1.0, shouldLoadVideo: Bool = false, showMuteButton: Bool = true) {
        self.parentTweet = parentTweet
        self.attachmentIndex = attachmentIndex
        self.aspectRatio = aspectRatio
        self.shouldLoadVideo = shouldLoadVideo
        self.showMuteButton = showMuteButton
    }
    
    private var attachment: MimeiFileType {
        guard let attachments = parentTweet.attachments,
              attachmentIndex >= 0 && attachmentIndex < attachments.count else {
            return MimeiFileType(mid: "", mediaType: .unknown)
        }
        return attachments[attachmentIndex]
    }
    
    private var baseUrl: URL? {
        return parentTweet.author?.baseUrl
    }

    static func imageLoadId(for attachment: MimeiFileType) -> String {
        "detail_\(attachment.mid)"
    }
    
    var body: some View {
        Group {
            if let baseUrl = baseUrl, let url = attachment.getUrl(baseUrl) {
                switch attachment.type {
                case .video, .hls_video:
                    // Singleton video player — only the selected page loads/plays.
                    // Non-selected pages show a thumbnail placeholder (no invisible playback).
                    DetailSingletonVideoPlayerView(
                        url: url,
                        mid: attachment.mid,
                        mediaType: attachment.type,
                        aspectRatio: attachment.aspectRatio,
                        shouldLoad: shouldLoadVideo,
                        shouldMountNativePlaybackSurface: true
                    )
                case .audio:
                    // Show audio player with SimpleAudioPlayer
                    SimpleAudioPlayer(url: url, autoPlay: false)
                        .environmentObject(MuteState.shared)
                case .image:
                    // Images: use .fit for landscape, .fill for portrait, with black background
                    let isLandscape = CGFloat(aspectRatio) > 1.0
                    ZStack {
                        Color.black
                        Group {
                            if let image = image {
                                Image(uiImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: isLandscape ? .fit : .fill)
                                    .if(!isLandscape) { $0.clipped() }
                            } else if loading {
                                // Show cached placeholder while loading original image
                                // CRITICAL: Use memory-only cache check to avoid blocking disk I/O in view body
                                if let cachedImage = ImageCacheManager.shared.getCompressedImageFromMemory(for: attachment) {
                                    Image(uiImage: cachedImage)
                                        .resizable()
                                        .aspectRatio(contentMode: isLandscape ? .fit : .fill)
                                        .if(!isLandscape) { $0.clipped() }
                                        .overlay(
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                                .scaleEffect(1.0)
                                                .background(Color.black.opacity(0.3))
                                                .clipShape(Circle())
                                                .padding(),
                                            alignment: .topTrailing
                                        )
                                } else {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(1.2)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            } else {
                                // Show cached placeholder if available, otherwise gray background
                                // CRITICAL: Use memory-only cache check to avoid blocking disk I/O in view body
                                if let cachedImage = ImageCacheManager.shared.getCompressedImageFromMemory(for: attachment) {
                                    Image(uiImage: cachedImage)
                                        .resizable()
                                        .aspectRatio(contentMode: isLandscape ? .fit : .fill)
                                        .if(!isLandscape) { $0.clipped() }
                                } else {
                                    Color.gray.opacity(0.2)
                                }
                            }
                        }
                    }
                default:
                    // Documents are shown in DocumentAttachmentsView, not in detail media viewer
                    Color.gray.opacity(0.2)
                }
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .onAppear {
            print("DEBUG: [DetailMediaCell] Cell appeared for attachment \(attachmentIndex): \(attachment.type), mid: \(attachment.mid), shouldLoadVideo: \(shouldLoadVideo)")
            
            // For videos in detail view, check if we need to restore position
            // This runs regardless of shouldLoadVideo since player is always created
            if attachment.type == .video || attachment.type == .hls_video {
                if !hasRestoredPosition {
                    if let savedState = PersistentVideoStateManager.shared.getState(videoMid: attachment.mid, context: .detailView),
                       PersistentVideoStateManager.shared.shouldRestorePlayback(videoMid: attachment.mid, context: .detailView) {
                        
                        print("🔄 [DetailMediaCell] Found saved state for \(attachment.mid): time=\(savedState.currentTime.seconds)s, wasPlaying=\(savedState.wasPlaying)")
                        hasRestoredPosition = true
                        // No notification needed: SimpleVideoPlayer now restores (seek) before starting playback,
                        // preventing the visible "start at 0 then jump back" in TweetDetailView.
                    }
                }
            }
            
            if attachment.type == .image && image == nil {
                print("DEBUG: [DetailMediaCell] Starting image load for attachment \(attachmentIndex)")
                loadImage()
            }
            
            // Setup foreground observer to reload resources if released during background
            setupForegroundObserver()
            setupImageCacheObserver()
        }
        .onDisappear {
            // For videos in detail view, post notification to save state
            // SimpleVideoPlayer will handle the actual state capture
            if attachment.type == .video || attachment.type == .hls_video {
                NotificationCenter.default.post(
                    name: NSNotification.Name("SaveVideoPosition"),
                    object: nil,
                    userInfo: [
                        "videoMid": attachment.mid,
                        "context": PersistentVideoStateManager.VideoPlaybackState.VideoContext.detailView.rawValue
                    ]
                )
            }
            
            // Clean up foreground observer
            if let observer = foregroundObserver {
                NotificationCenter.default.removeObserver(observer)
                foregroundObserver = nil
            }
            if let observer = imageCacheObserver {
                NotificationCenter.default.removeObserver(observer)
                imageCacheObserver = nil
            }
            if attachment.type == .image {
                DetailImageLoadRegistry.activeCompressedLoads.remove(Self.imageLoadId(for: attachment))
            }

            originalImageTask?.cancel()
            originalImageTask = nil
        }

    }
    
    /// Setup observer to detect foreground return and reload image if released
    private func setupForegroundObserver() {
        // Only setup for image attachments
        guard attachment.type == .image else { return }
        
        // Avoid duplicate observers
        guard foregroundObserver == nil else { return }
        
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                // Only reload if image was released
                guard self.image == nil, self.attachment.type == .image else { return }

                print("DEBUG: [DetailMediaCell] App returned to foreground, image released - reloading: \(self.attachment.mid)")
                self.loadImage()
            }
        }
    }

    private func setupImageCacheObserver() {
        guard attachment.type == .image else { return }
        guard imageCacheObserver == nil else { return }

        imageCacheObserver = NotificationCenter.default.addObserver(
            forName: .imageCached,
            object: nil,
            queue: .main
        ) { notification in
            let avatarId = notification.userInfo?["avatarId"] as? String
            MainActor.assumeIsolated {
                guard avatarId == self.attachment.mid else { return }
                if self.image == nil || self.loading {
                    self.updateImageFromMemoryCache()
                }
            }
        }
    }

    @discardableResult
    private func updateImageFromMemoryCache() -> Bool {
        guard let cachedImage = ImageCacheManager.shared.getCompressedImageFromMemory(for: attachment) else {
            return false
        }
        image = cachedImage
        loading = false
        return true
    }
    
    private func loadImage() {
        guard let baseUrl = baseUrl,
              let url = attachment.getUrl(baseUrl) else { return }
        
        // Use a detail-specific request ID so feed cells disappearing during navigation
        // cannot cancel the image load that is now visible in TweetDetailView.
        let loadId = Self.imageLoadId(for: attachment)
        print("DEBUG: [TweetDetailView] loadImage called for \(loadId)")

        if updateImageFromMemoryCache() {
            print("DEBUG: [TweetDetailView] Found memory cached image for \(loadId)")
            startOriginalImageLoad(url: url, baseUrl: baseUrl)
            return
        }
        
        // First, try to get cached image immediately (disk check is OK in async context)
        if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: attachment) {
            print("DEBUG: [TweetDetailView] Found cached image for \(loadId)")
            self.image = cachedImage
            
            // ✅ Load original image in background and replace compressed cache
            // This ensures detail view uses the highest quality image
            startOriginalImageLoad(url: url, baseUrl: baseUrl)
            return
        }

        if DetailImageLoadRegistry.activeCompressedLoads.contains(loadId) {
            print("♻️ [TweetDetailView] Waiting for shared detail image load \(loadId)")
            loading = true
            return
        }
        
        // If no cached image, start loading with global manager
        print("DEBUG: [TweetDetailView] Starting network load for \(loadId)")
        loading = true
        DetailImageLoadRegistry.activeCompressedLoads.insert(loadId)
        
        // Detail-visible images should outrank preload/background image work.
        GlobalImageLoadManager.shared.loadImageCriticalPriority(
            id: loadId,
            url: url,
            attachment: attachment,
            baseUrl: baseUrl
        ) { loadedImage in
            print("DEBUG: [TweetDetailView] Load completed for \(loadId), success: \(loadedImage != nil)")
            DetailImageLoadRegistry.activeCompressedLoads.remove(loadId)
            // Completion is already @MainActor, update state immediately without additional Task wrapper
            // The extra Task wrapper was causing a delay in UI updates, making spinners stick
            self.image = loadedImage
            self.loading = false

            if loadedImage != nil {
                NotificationCenter.default.post(
                    name: .imageCached,
                    object: nil,
                    userInfo: ["avatarId": attachment.mid]
                )
            }
            
            // ✅ Load original image in background and replace compressed cache
            // This ensures detail view uses the highest quality image
            if loadedImage != nil {
                startOriginalImageLoad(url: url, baseUrl: baseUrl)
            }
        }
    }

    private func startOriginalImageLoad(url: URL, baseUrl: URL) {
        let expectedMid = attachment.mid
        originalImageTask?.cancel()
        originalImageTask = Task {
            if let originalImage = await ImageCacheManager.shared.loadOriginalImage(
                from: url,
                for: attachment,
                baseUrl: baseUrl,
                replaceCompressedCache: true,
                priority: .critical
            ) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.attachment.mid == expectedMid,
                          self.originalImageTask != nil else { return }
                    self.image = originalImage
                }
            }

            await MainActor.run {
                self.originalImageTask = nil
            }
        }
    }
}

// MARK: - Detail Singleton Video Player View
// Mirrors MediaBrowserView's SingletonVideoPlayerView pattern:
// Only the selected page loads video via DetailVideoManager.loadVideo().
// Non-selected pages show a cached thumbnail (no invisible playback).

private struct DetailSingletonVideoPlayerView: View {
    let url: URL
    let mid: String
    let mediaType: MediaType
    let aspectRatio: Float?
    /// Retained for call-site compatibility but no longer used for autoplay.
    /// Playback is driven by CommentsVideoPlaybackCoordinator notifications via DetailVideoManager.
    let shouldLoad: Bool
    /// Defers only the heavyweight native controller while a detail push is animating.
    /// Player loading and handoff continue immediately behind the cached thumbnail.
    let shouldMountNativePlaybackSurface: Bool

    @ObservedObject private var manager = DetailVideoManager.shared
    @State private var handoffThumbnail: UIImage?
    /// True once AVPlayerViewController has its first frame of the current item on screen.
    /// The manager's isPlaybackRendering only means the item is decoding — a freshly built
    /// AVPlayerViewController is still a black surface for several frames after that.
    @State private var isNativeSurfaceReadyForDisplay = false

    private var isThisVideoLoaded: Bool {
        manager.currentVideoMid == mid && manager.currentPlayer?.currentItem != nil
    }

    private var isThisVideoReady: Bool {
        manager.currentVideoMid == mid
            && manager.currentPlayer?.currentItem?.status == .readyToPlay
    }

    private var didThisVideoFailToLoad: Bool {
        manager.loadFailedVideoMid == mid
    }

    private var didThisVideoFinishPlayback: Bool {
        manager.currentVideoMid == mid && manager.didFinishPlayback
    }

    /// True after loadVideo has been called for this mid and before readyToPlay/failure.
    /// AVPlayer can already have a currentItem while that item is still .unknown; that
    /// state still needs visible loading feedback instead of a blank black frame.
    private var isThisVideoPreparing: Bool {
        manager.currentVideoMid == mid
            && !manager.isItemReady
            && !isThisVideoReady
            && !manager.isPlaybackRendering
            && !didThisVideoFailToLoad
    }

    private var shouldShowLoadingSpinner: Bool {
        guard !didThisVideoFailToLoad,
              !didThisVideoFinishPlayback else { return false }

        if shouldLoad && !isThisVideoLoaded {
            return true
        }

        guard manager.currentVideoMid == mid else { return false }

        return isThisVideoPreparing
            || manager.isBuffering
            || !manager.isPlaybackRendering
    }

    private var shouldShowPlaceholder: Bool {
        isNativePlaybackSurfaceDeferred
            || isNativePlaybackSurfaceBlank
            || didThisVideoFailToLoad
            || !isThisVideoLoaded
            || isThisVideoPreparing
            || (manager.currentVideoMid == mid
                && !manager.isPlaybackRendering
                && !didThisVideoFinishPlayback
                && !didThisVideoFailToLoad)
    }

    private var requiresLayerBackedPlaybackSurface: Bool {
#if targetEnvironment(macCatalyst)
        true
#else
        ProcessInfo.processInfo.isiOSAppOnMac
#endif
    }

    private var isNativePlaybackSurfaceDeferred: Bool {
        !requiresLayerBackedPlaybackSurface && !shouldMountNativePlaybackSurface
    }

    /// The native controller is mounted but has not put a frame up yet. Dropping the
    /// placeholder in the same transaction that builds AVPlayerViewController exposes
    /// its black backing view until the first frame lands.
    private var isNativePlaybackSurfaceBlank: Bool {
        !requiresLayerBackedPlaybackSurface
            && shouldMountNativePlaybackSurface
            && !isNativeSurfaceReadyForDisplay
    }

    var body: some View {
        ZStack {
            Color.black

            if isThisVideoLoaded, let player = manager.currentPlayer {
                Group {
                    if requiresLayerBackedPlaybackSurface {
                        DetailLayerVideoPlayerView(player: player)
                    } else if shouldMountNativePlaybackSurface {
                        DetailAVPlayerView(player: player) { isReady in
                            isNativeSurfaceReadyForDisplay = isReady
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if shouldShowPlaceholder {
                thumbnailOrBlack
                    .allowsHitTesting(false)
            }

            if shouldShowLoadingSpinner {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.5)
                    .allowsHitTesting(false)
            }

            if didThisVideoFailToLoad {
                retryButton
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .videoThumbnailCached)) { notification in
            guard notification.userInfo?["mediaID"] as? String == mid else { return }
            if handoffThumbnail == nil {
                handoffThumbnail = SharedAssetCache.shared.cachedThumbnail(for: mid)
            }
        }
        .onAppear {
            if handoffThumbnail == nil {
                handoffThumbnail = SharedAssetCache.shared.cachedThumbnail(for: mid)
            }
        }
        .onChange(of: shouldMountNativePlaybackSurface) { _, isMounted in
            if !isMounted {
                isNativeSurfaceReadyForDisplay = false
            }
        }
        .onChange(of: manager.currentPlayer) { _, _ in
            isNativeSurfaceReadyForDisplay = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .videoPlayerItemReplaced)) { notification in
            guard notification.userInfo?["mediaID"] as? String == mid else { return }
            isNativeSurfaceReadyForDisplay = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .videoInfrastructureRestarted)) { _ in
            recoverVisibleVideoAfterForeground(reason: "videoInfrastructureRestarted")
        }
        .onReceive(NotificationCenter.default.publisher(for: .reloadVisibleVideosOnly)) { _ in
            recoverVisibleVideoAfterForeground(reason: "reloadVisibleVideosOnly")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            recoverVisibleVideoAfterForeground(reason: "didBecomeActive")
        }
    }

    private func recoverVisibleVideoAfterForeground(reason: String) {
        guard shouldLoad || manager.currentVideoMid == mid else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard shouldLoad || manager.currentVideoMid == mid else { return }
            print("📱 [DetailSingletonVideoPlayerView] Foreground recovery reload \(mid) reason=\(reason)")
            manager.loadVideo(url: url, mid: mid, mediaType: mediaType)
        }
    }

    @ViewBuilder
    private var thumbnailOrBlack: some View {
        Group {
            if let thumbnail = handoffThumbnail ?? SharedAssetCache.shared.cachedThumbnail(for: mid) {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.black
            }
        }
    }

    private var retryButton: some View {
        Button {
            manager.loadVideo(url: url, mid: mid, mediaType: mediaType)
        } label: {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 32, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Retry video"))
        .help("Retry video")
    }

}

// MARK: - Layer-backed detail player for iPad apps running on Mac

/// AVPlayerViewController installs a UITransitionView for its native controls. The
/// iPad-on-Mac runtime can recursively invalidate that view's dynamic corner layout
/// guides when a LazyVStack hands the singleton player between cells. A plain
/// AVPlayerLayer has no transition controller or dynamic layout guides.
@MainActor
private struct DetailLayerVideoPlayerView: View {
    let player: AVPlayer

    @ObservedObject private var manager = DetailVideoManager.shared
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var isSeeking = false
    @State private var shouldResumeAfterSeek = false

    private let playbackClock = Timer.publish(
        every: 0.25,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        ZStack {
            LightweightVideoPlayer(player: player)

            VStack {
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        manager.togglePlayback()
                    } label: {
                        Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    .accessibilityLabel(manager.isPlaying ? "Pause video" : "Play video")

                    Slider(
                        value: Binding(
                            get: { currentTime },
                            set: { currentTime = $0 }
                        ),
                        in: 0...max(duration, 1),
                        onEditingChanged: handleSeeking
                    )
                    .tint(.white)

                    Text("\(formattedTime(currentTime)) / \(formattedTime(duration))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 92, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.65))
            }
        }
        .onAppear {
            refreshPlaybackTime()
        }
        .onReceive(playbackClock) { _ in
            refreshPlaybackTime()
        }
    }

    private func refreshPlaybackTime() {
        guard !isSeeking else { return }

        let playerTime = player.currentTime().seconds
        if playerTime.isFinite {
            currentTime = max(0, playerTime)
        }

        if let itemDuration = player.currentItem?.duration.seconds,
           itemDuration.isFinite,
           itemDuration > 0 {
            duration = itemDuration
        }
    }

    private func handleSeeking(_ editing: Bool) {
        if editing {
            isSeeking = true
            shouldResumeAfterSeek = manager.isPlaying
            player.pause()
            return
        }

        let target = CMTime(seconds: currentTime, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        isSeeking = false

        if shouldResumeAfterSeek {
            player.play()
        }
        shouldResumeAfterSeek = false
    }

    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

// MARK: - Detail AVPlayerViewController Wrapper

private struct DetailAVPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    /// Reports whether the controller currently has a video frame on screen, so the
    /// caller can keep its placeholder up instead of exposing the black backing view.
    let onReadyForDisplayChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate, @preconcurrency AVPlayerViewControllerDelegate {
        var player: AVPlayer?
        var onReadyForDisplayChange: ((Bool) -> Void)?
        private var wasPlayingBeforeSurfaceTap = false
        private var fullscreenMuteObserver: NSKeyValueObservation?
        private var fullscreenVolumeObserver: NSKeyValueObservation?
        private var readyForDisplayObserver: NSKeyValueObservation?

        func attach(player: AVPlayer) {
            self.player = player
        }

        func observeReadyForDisplay(on playerViewController: AVPlayerViewController) {
            readyForDisplayObserver?.invalidate()
            readyForDisplayObserver = playerViewController.observe(
                \.isReadyForDisplay,
                options: [.new]
            ) { [weak self] _, change in
                guard let isReady = change.newValue else { return }
                Task { @MainActor in
                    self?.onReadyForDisplayChange?(isReady)
                }
            }

            // Seed the current value out of band: makeUIViewController runs inside a
            // SwiftUI update, so the callback cannot mutate state synchronously here.
            let isReadyNow = playerViewController.isReadyForDisplay
            Task { @MainActor [weak self] in
                self?.onReadyForDisplayChange?(isReadyNow)
            }
        }

        @objc func handleSurfaceTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            let shouldPreservePlayback = wasPlayingBeforeSurfaceTap
            wasPlayingBeforeSurfaceTap = false

            // AVPlayerViewController handles the same tap first to reveal its controls.
            // Restore only an already-playing video; a paused video stays paused.
            guard shouldPreservePlayback else { return }
            DispatchQueue.main.async { [weak player] in
                guard let player,
                      player.timeControlStatus == .paused,
                      player.rate == 0 else { return }
                player.play()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            guard !touchTargetsControl(touch.view, within: gestureRecognizer.view) else {
                wasPlayingBeforeSurfaceTap = false
                return false
            }

            if let player {
                wasPlayingBeforeSurfaceTap = player.rate > 0
                    || player.timeControlStatus == .playing
                    || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            } else {
                wasPlayingBeforeSurfaceTap = false
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator transitionCoordinator: UIViewControllerTransitionCoordinator
        ) {
            beginEnforcingAudibleFullscreenPlayback()
            restoreAudiblePlayback(on: playerViewController)
            transitionCoordinator.animate(alongsideTransition: nil) { [weak self, weak playerViewController] context in
                guard let self, let playerViewController else { return }
                self.restoreAudiblePlayback(on: playerViewController)
                if context.isCancelled {
                    self.stopEnforcingAudibleFullscreenPlayback()
                }
            }
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator transitionCoordinator: UIViewControllerTransitionCoordinator
        ) {
            transitionCoordinator.animate(alongsideTransition: nil) { [weak self, weak playerViewController] context in
                guard let self, let playerViewController else { return }
                self.restoreAudiblePlayback(on: playerViewController)
                if !context.isCancelled {
                    self.stopEnforcingAudibleFullscreenPlayback()
                }
            }
        }

        private func beginEnforcingAudibleFullscreenPlayback() {
            fullscreenMuteObserver?.invalidate()
            fullscreenVolumeObserver?.invalidate()

            guard let player else { return }
            fullscreenMuteObserver = player.observe(\.isMuted, options: [.new]) { player, change in
                guard change.newValue == true else { return }
                DispatchQueue.main.async {
                    AudioSessionManager.shared.activateForVideoPlayback()
                    player.isMuted = false
                }
            }
            fullscreenVolumeObserver = player.observe(\.volume, options: [.new]) { player, change in
                guard let volume = change.newValue, volume < 1 else { return }
                DispatchQueue.main.async {
                    AudioSessionManager.shared.activateForVideoPlayback()
                    player.volume = 1
                }
            }
        }

        private func stopEnforcingAudibleFullscreenPlayback() {
            fullscreenMuteObserver?.invalidate()
            fullscreenMuteObserver = nil
            fullscreenVolumeObserver?.invalidate()
            fullscreenVolumeObserver = nil
        }

        private func restoreAudiblePlayback(on playerViewController: AVPlayerViewController) {
            guard let player else { return }
            AudioSessionManager.shared.activateForVideoPlayback()
            player.isMuted = false
            player.volume = 1
            if playerViewController.player !== player {
                playerViewController.player = player
            }
            playerViewController.view.setNeedsLayout()
        }

        private func touchTargetsControl(_ touchedView: UIView?, within rootView: UIView?) -> Bool {
            var candidate = touchedView
            while let view = candidate {
                if view is UIControl {
                    return true
                }
                if view === rootView {
                    break
                }
                candidate = view.superview
            }
            return false
        }
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        // Inline autoplay pauses frequently and does not expose frame-analysis actions.
        // Avoid starting Visual Look Up work that would immediately be cancelled by the
        // next cell handoff on platforms where the native controller remains in use.
        vc.allowsVideoFrameAnalysis = false
        configureAudiblePlayback(for: player)
        vc.player = player
        vc.showsPlaybackControls = true
        vc.videoGravity = .resizeAspect
        vc.view.backgroundColor = .black

        let coordinator = context.coordinator
        vc.delegate = coordinator
        coordinator.attach(player: player)
        coordinator.onReadyForDisplayChange = onReadyForDisplayChange
        coordinator.observeReadyForDisplay(on: vc)
        let surfaceTap = UITapGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleSurfaceTap(_:))
        )
        surfaceTap.cancelsTouchesInView = false
        surfaceTap.delaysTouchesBegan = false
        surfaceTap.delaysTouchesEnded = false
        surfaceTap.delegate = coordinator
        vc.view.addGestureRecognizer(surfaceTap)

        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        context.coordinator.attach(player: player)
        context.coordinator.onReadyForDisplayChange = onReadyForDisplayChange
        configureAudiblePlayback(for: player)
        if vc.player !== player {
            vc.player = player
        }
        if !vc.showsPlaybackControls {
            vc.showsPlaybackControls = true
        }
    }

    private func configureAudiblePlayback(for player: AVPlayer) {
        AudioSessionManager.shared.activateForVideoPlayback()
        player.isMuted = false
        player.volume = 1
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        // AVPlayerViewController can still own a system fullscreen transition when
        // SwiftUI dismantles the inline representable. Keep the player attached until
        // that controller is released so fullscreen does not become a black surface.
    }
}

/// Gives every detail attachment a concrete width and height in the same pass that
/// sizes the media column. This avoids both AVPlayerViewController's responsive-layout
/// invalidation loop and a second SwiftUI transaction that inserts media after scrolling
/// has already been positioned.
@available(iOS 16.0, *)
private struct DetailMediaColumnLayout: Layout {
    let aspectRatios: [CGFloat]
    var spacing: CGFloat = 1

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = max(0, proposal.width ?? 0)
        let itemCount = min(subviews.count, aspectRatios.count)
        let contentHeight = (0..<itemCount).reduce(CGFloat.zero) { result, index in
            result + width / max(0.01, aspectRatios[index])
        }
        let spacingHeight = CGFloat(max(0, itemCount - 1)) * spacing
        return CGSize(width: width, height: contentHeight + spacingHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let itemCount = min(subviews.count, aspectRatios.count)
        var y = bounds.minY
        for index in 0..<itemCount {
            let height = bounds.width / max(0.01, aspectRatios[index])
            subviews[index].place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: height)
            )
            y += height + spacing
        }
    }
}

@MainActor
@available(iOS 16.0, *)
struct TweetDetailView: View {
    @ObservedObject var tweet: Tweet
    @State private var showBrowser = false
    @State private var selectedMediaIndex = 0
    @State private var shouldMountNativePlaybackSurface = false
    @State private var nativePlaybackMountDelayElapsed = false
    @State private var isDetailScrollInteractionActive = false
    @State private var showLoginSheet = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastIsError = false
    @State private var pinnedTweets: [[String: Any]] = []
    @State private var originalTweet: Tweet?
    @State private var refreshTimer: Timer?
    @State private var comments: [Tweet] = []
    // Flipped to true on the first real user pan, detected via the
    // BottomBarScrollTracker observing the parent UIScrollView. Used by
    // CommentListView to suppress the open-time auto-probe's flash.
    @State private var hasUserScrolledComments = false
    /// True while a pull-to-refresh fetch is in flight. Stays true until the fetch
    /// actually finishes — not until the refresh control comes down — because its
    /// job is to keep the comment list from paginating against a page cursor the
    /// refresh is in the middle of invalidating.
    @State private var isPullRefreshing = false
    @State private var showReplyEditor = true
    @State private var shouldShowExpandedReply = false
    @State private var menuShareItems: ShareSheetData?
    @State private var showMenuFilterSheet = false
    @State private var showMenuReportSheet = false
    @State private var showMenuDeleteConfirmation = false
    @State private var pendingMenuDeleteAction: (() -> Void)?
    @State private var cachedDisplayTweet: Tweet?
    @State private var hasLoadedOriginalTweet = false
    @State private var hasServedCachedCommentsForCurrentParentTweet = false
    @State private var currentCommentsParentTweetId = ""
    @State private var initialLoadParentTweetId = ""
    @State private var selectedEmbeddedTweetForNavigation: Tweet?
    @State private var selectedCommentUserForNavigation: User?
    @State private var commentProfileNavigationPath = NavigationPath()

    // Bottom navigation bar scroll tracking
    @State private var isNavigationBarVisible = true
    @State private var lastNotificationTime: Date?
    private let notificationThrottleInterval: TimeInterval = 0.1 // 100ms throttle
    @State private var bottomBounceDebouncer: Timer?
    private let bottomBounceDebounceInterval: TimeInterval = 0.3 // 300ms debounce for bottom bounce
    @State private var lastStateChangeTime: Date?
    private let stateChangeCooldown: TimeInterval = 0.2 // 200ms cooldown after state changes
    private let maxDeltaThreshold: CGFloat = 200.0 // Ignore deltas larger than this (programmatic scrolls)

    // Comments video playback coordinator
    @StateObject private var commentsVideoCoordinator = CommentsVideoPlaybackCoordinator()

    // Track if the main tweet has video attachments
    private var hasVideoAttachment: Bool {
        guard let attachments = displayTweet.attachments else { return false }
        return attachments.contains { $0.type == .video || $0.type == .hls_video }
    }

    private var firstMainTweetVideoToAutoplay: (url: URL, mid: String, mediaType: MediaType)? {
        guard let baseUrl = displayTweet.author?.baseUrl,
              let attachment = displayTweet.attachments?.first(where: { $0.type == .video || $0.type == .hls_video }),
              let url = attachment.getUrl(baseUrl) else {
            return nil
        }
        return (url, attachment.mid, attachment.type)
    }

    private var mainTweetVideoMids: [String] {
        (displayTweet.attachments ?? [])
            .filter { $0.type == .video || $0.type == .hls_video }
            .map { $0.mid }
    }

    /// Everything the main tweet's video wiring is built from: which tweet is on screen,
    /// which videos it carries, and the author route their URLs are resolved against.
    ///
    /// Registering that wiring once, on appear, assumes all three are already settled.
    /// They are when the view is pushed from a feed cell that just rendered the tweet,
    /// but not when a deeplink opens it. A deeplink whose tweet is already cached
    /// navigates on the cached copy alone — no author fetch, no route repair — so the
    /// author can still be arriving, and with it the only base URL an attachment URL can
    /// be built from. The media section renders the player the moment that route exists,
    /// so a snapshot taken before it leaves the player spinning on a video nobody ever
    /// asked the manager to load; the visibility coordinator cannot rescue it either,
    /// because it resolves playback through the same snapshot.
    private var mainTweetVideoWiringKey: String {
        let route = displayTweet.author?.baseUrl?.absoluteString ?? ""
        return "\(displayTweet.mid)|\(route)|\(mainTweetVideoMids.joined(separator: ","))"
    }

    /// Tells the manager which videos belong to the main tweet, and where to read them
    /// from, so coordinator play/pause notifications can be filtered and resolved.
    private func registerMainTweetVideoAttachments() {
        guard let attachments = displayTweet.attachments else { return }
        DetailVideoManager.shared.setMainTweetAttachments(
            attachments,
            baseUrl: displayTweet.author?.baseUrl
        )
    }

    /// Starts the main tweet's first video. Safe to re-run: it stands down as soon as the
    /// manager is on any of this tweet's videos.
    ///
    /// That covers both an attachment the coordinator promoted and the video this would
    /// load anyway. The media is content-addressed and served by any reachable node, so a
    /// route that moves under a working player changes nothing about what it is playing —
    /// re-loading it would only resume a video the reader had paused.
    private func loadInitialMainTweetVideoIfNeeded() {
        guard let initialVideo = firstMainTweetVideoToAutoplay else { return }

        if let currentMid = DetailVideoManager.shared.currentVideoMid,
           mainTweetVideoMids.contains(currentMid) {
            return
        }

        DetailVideoManager.shared.loadVideo(
            url: initialVideo.url,
            mid: initialVideo.mid,
            mediaType: initialVideo.mediaType
        )
    }

    @EnvironmentObject private var hproseInstance: HproseInstance
    @Environment(\.dismiss) private var dismiss
    
    init(tweet: Tweet) {
        self.tweet = tweet
    }
    
    // Check if this is a retweet or quoted tweet
    private var isRetweetOrQuotedTweet: Bool {
        return tweet.originalTweetId != nil && tweet.originalAuthorId != nil
    }
    
    private var displayTweet: Tweet {
        // Check if we need to update the cached value
        let isRetweet = (tweet.content == nil || tweet.content?.isEmpty == true) &&
        (tweet.attachments == nil || tweet.attachments?.isEmpty == true)
        let shouldUseOriginal = isRetweet && originalTweet != nil
        
        // If we have a cached value and the conditions haven't changed, return it
        if let cached = cachedDisplayTweet {
            let cachedIsRetweet = (cached.content == nil || cached.content?.isEmpty == true) &&
            (cached.attachments == nil || cached.attachments?.isEmpty == true)
            let cachedShouldUseOriginal = cachedIsRetweet && originalTweet != nil
            
            if shouldUseOriginal == cachedShouldUseOriginal {
                return cached
            }
        }
        
        // Calculate new value and cache it
        let result: Tweet
        if shouldUseOriginal {
            result = originalTweet ?? tweet
        } else {
            result = tweet
        }
        
        // Update cache on next run loop to avoid modifying state during view update
        DispatchQueue.main.async {
            self.cachedDisplayTweet = result
        }
        
        return result
    }
    
    var body: some View {
        Group {
            // Hide retweets/quoted tweets if their original tweets failed to load
            if isRetweetOrQuotedTweet && originalTweet == nil && hasLoadedOriginalTweet {
                // This is a retweet/quoted tweet but original tweet failed to load - show error message
                VStack {
                    Spacer()
                    Text("Original tweet not found")
                        .font(.headline)
                        .foregroundColor(XTheme.secondaryTextColor)
                    Text("The original tweet may have been deleted or is no longer accessible.")
                        .font(.caption)
                        .foregroundColor(XTheme.secondaryTextColor)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            VStack(spacing: 0) {
                                mediaSection
                                tweetHeader
                                documentsSection
                                tweetContent
                                actionButtons
                            }
                            .padding(.bottom, 8)
                            .background(XTheme.backgroundColor)

                            commentsListView
                                .padding(.leading, -4)
                        }
                        .task {
                            setupInitialData()
                        }
                    }
                    .coordinateSpace(name: "commentsScroll")
                    .refreshable {
                        await runCappedPullRefresh()
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        // Floating navigation bar — pure UIKit, driven directly by KVO.
                        // Using safeAreaInset (instead of a ZStack overlay) so the
                        // ScrollView's pull-to-refresh spinner appears below the nav bar
                        // rather than being hidden behind it.
                        NavBarOverlay(onBack: { dismiss() })
                            .frame(height: 44)
                    }
                    .overlay(alignment: .top) {
                        // Bottom bar scroll tracker — placed outside ScrollView to properly find it
                        BottomBarScrollTracker { offset, delta, isAtBottom, isInteracting in
                            if isDetailScrollInteractionActive != isInteracting {
                                isDetailScrollInteractionActive = isInteracting
                                if !isInteracting {
                                    mountNativePlaybackSurfaceIfReady()
                                }
                            }
                            handleScrollOffsetChange(offset, delta: delta, isAtBottom: isAtBottom)
                        }
                        .frame(width: 0, height: 0)
                    }

            // ReplyEditor as a component at the bottom
            if showReplyEditor {
                ReplyEditorView(
                    parentTweet: displayTweet,
                    isQuoting: false,
                    onClose: {
                        showReplyEditor = false
                    },
                    onExpandedClose: {
                        shouldShowExpandedReply = false
                    },
                    initialExpanded: shouldShowExpandedReply
                )
                // Reserve a constant footprint so showing/hiding the bottom bar cannot resize
                // the ScrollView during an active gesture. Offset preserves the previous visual
                // position without changing layout or the visible tweet's content offset.
                .padding(.bottom, 48)
                .offset(y: isNavigationBarVisible ? 0 : 40)
                .animation(.easeInOut(duration: 0.25), value: isNavigationBarVisible)
            }
                }
            }
        }
        .background(XTheme.backgroundColor)
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $showBrowser) {
            MediaBrowserView(
                tweet: displayTweet,
                initialIndex: selectedMediaIndex
            )
        }
        .sheet(isPresented: $showLoginSheet) {
            LoginView()
        }
        .sheet(isPresented: $showMenuFilterSheet) {
            ContentFilterView(tweet: displayTweet)
        }
        .sheet(isPresented: $showMenuReportSheet) {
            ReportTweetView(tweet: displayTweet)
        }
        .alert(
            NSLocalizedString("Delete Tweet?", comment: "Delete tweet confirmation title"),
            isPresented: $showMenuDeleteConfirmation
        ) {
            Button(NSLocalizedString("Delete Tweet", comment: "Confirm tweet deletion"), role: .destructive) {
                let deleteAction = pendingMenuDeleteAction
                pendingMenuDeleteAction = nil
                deleteAction?()
            }
            Button(NSLocalizedString("Cancel", comment: "Cancel tweet deletion"), role: .cancel) {
                pendingMenuDeleteAction = nil
            }
        } message: {
            Text(
                NSLocalizedString(
                    "This tweet will be permanently deleted. This action cannot be undone.",
                    comment: "Delete tweet confirmation message"
                )
            )
        }
        .sheet(item: $menuShareItems) { data in
            ShareSheetView(items: data.items)
        }
        .navigationDestination(item: $selectedEmbeddedTweetForNavigation) { embeddedTweet in
            if embeddedTweet.originalTweetId != nil,
               (embeddedTweet.content?.isEmpty ?? true),
               (embeddedTweet.attachments?.isEmpty ?? true) {
                CommentDetailViewWithParent(comment: embeddedTweet)
            } else {
                TweetDetailView(tweet: embeddedTweet)
            }
        }
        .navigationDestination(item: $selectedCommentUserForNavigation) { user in
            ProfileView(
                user: user,
                onLogout: nil,
                navigationPath: $commentProfileNavigationPath,
                onShowLogin: { showLoginSheet = true },
                onShowToast: { message, isError in
                    toastMessage = message
                    toastIsError = isError
                    showToast = true
                }
            )
        }
        .overlay(alignment: .top) {
            if showToast {
                ToastView(
                    message: toastMessage,
                    type: toastIsError ? .error : .success
                )
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: showToast)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .commentSynced)) { notification in
            if let comment = notification.userInfo?["comment"] as? Tweet,
               let parentTweetId = notification.userInfo?["parentTweetId"] as? String,
               parentTweetId == displayTweet.mid,
               !comments.contains(where: { $0.mid == comment.mid }) {
                comments.append(comment)
                comments.sort { $0.timestamp > $1.timestamp }
                TweetDetailCommentsCache.shared.setComments(comments, for: displayTweet.mid)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tweetDeleted)) { notification in
            if let deletedTweetId = notification.userInfo?["tweetId"] as? String ?? notification.object as? String,
               deletedTweetId == displayTweet.mid {
                dismiss()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .videoInfrastructureRestarted)) { _ in
            commentsVideoCoordinator.refreshVisiblePlaybackAfterForeground(reason: "videoInfrastructureRestarted")
        }
        .onReceive(NotificationCenter.default.publisher(for: .reloadVisibleVideosOnly)) { _ in
            commentsVideoCoordinator.refreshVisiblePlaybackAfterForeground(reason: "reloadVisibleVideosOnly")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                commentsVideoCoordinator.refreshVisiblePlaybackAfterForeground(reason: "didBecomeActive")
            }
        }
        // AVPlayerViewController creates its complete controls/KVO/PiP hierarchy synchronously.
        // Keep that work out of the navigation transaction while player borrowing and loading
        // continue immediately behind the cached handoff thumbnail.
        .task(id: tweet.mid) {
            shouldMountNativePlaybackSurface = false
            nativePlaybackMountDelayElapsed = false
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            nativePlaybackMountDelayElapsed = true
            mountNativePlaybackSurfaceIfReady()
        }
        // Use .task(id:) instead of onAppear for stable async loading (like Android's LaunchedEffect)
        // Cache restore only. The server read of the original belongs to
        // doReadTweet(isInitialLoad:), which sends fromDetailView so the node syncs and
        // provides it; fetching it here as well was a second round trip without the flag.
        .task(id: tweet.originalTweetId) {
            // Load original tweet if this is a retweet/quoted tweet
            guard let originalTweetId = tweet.originalTweetId,
                  tweet.originalAuthorId != nil else {
                return
            }
            
            // Restore from cache immediately to prevent layout shifts while the
            // detail-view read is still in flight.
            if let cachedTweet = await TweetCacheManager.shared.fetchTweet(mid: originalTweetId) {
                await MainActor.run {
                    originalTweet = cachedTweet
                    hasLoadedOriginalTweet = true
                }
            }
        }
        .onAppear {

            print("DEBUG: [TweetDetailView] View appeared")

            // Mark detail view as active to prevent MediaCell autoplay
            NavigationStateManager.shared.setDetailViewActive(true)

            // Register main tweet video attachments before activating so the coordinator
            // notification observers can filter incoming play/pause commands correctly.
            registerMainTweetVideoAttachments()

            // Activate manager and coordinate singleton lifecycle across nested detail navigations (quoted -> original).
            DetailVideoManager.shared.activateForDetail()

            DetailVideoManager.shared.prepareStartupAudioFade(duration: 0.5)
            loadInitialMainTweetVideoIfNeeded()

            // Activate comments video playback coordinator
            commentsVideoCoordinator.activate(hasMainVideo: hasVideoAttachment)

            // Rebuild video list on re-enter (deactivate clears it, onChange won't fire if count unchanged)
            commentsVideoCoordinator.buildVideoList(from: comments, outerTweetId: displayTweet.mid)

            // Ensure bottom navigation bar is visible when detail view appears
            // Always post notification to ensure ContentView state is synced
            isNavigationBarVisible = true
            postNavigationVisibilityNotification(isVisible: true)
            print("DEBUG: [TweetDetailView] onAppear - Set navigation bar to visible")

            // Detail view playback position is persisted independently (not seeded from feed positions).
        }
        .onChange(of: originalTweet) { _, _ in
            // Clear cache when originalTweet changes
            cachedDisplayTweet = nil
        }
        .onChange(of: mainTweetVideoWiringKey) { _, _ in
            // The tweet, its videos or the author's route settled after onAppear. This
            // runs in the same body evaluation that decides whether the player view can
            // be rendered at all, so the manager is always wired for the URL on screen.
            print("DEBUG: [TweetDetailView] Main tweet video wiring changed - re-registering")
            registerMainTweetVideoAttachments()
            loadInitialMainTweetVideoIfNeeded()
        }
        .onChange(of: comments.count) { _, _ in
            // Rebuild video list for fullscreen navigation when comments change
            commentsVideoCoordinator.buildVideoList(from: comments, outerTweetId: displayTweet.mid)
            TweetDetailCommentsCache.shared.setComments(comments, for: displayTweet.mid)
        }
        .onChange(of: displayTweet.mid) { _, _ in
            configureCommentCacheContextIfNeeded()
        }
        .onDisappear {
            // Ensure a retained detail view cannot remount the native controller synchronously
            // when it reappears after a nested push. Its task will enable the surface again.
            shouldMountNativePlaybackSurface = false
            nativePlaybackMountDelayElapsed = false
            print("DEBUG: [TweetDetailView] ===== VIEW DISAPPEARED =====")
            print("DEBUG: [TweetDetailView] Cancelling image loads for tweet: \(displayTweet.mid)")

            // Keep feed autoplay suppressed until the outgoing player's fade and
            // handoff are complete.
            DetailVideoManager.shared.deactivate(audioFadeDuration: 0.35) {
                NavigationStateManager.shared.setDetailViewActive(false)
            }

            // Deactivate comments video playback coordinator
            commentsVideoCoordinator.deactivate()
            
            // Cancel bottom bounce debouncer
            bottomBounceDebouncer?.invalidate()
            bottomBounceDebouncer = nil

            // Restore bottom navigation bar visibility when leaving detail view
            if !isNavigationBarVisible {
                isNavigationBarVisible = true
                postNavigationVisibilityNotification(isVisible: true)
            }
            
            // Clean up timers
            refreshTimer?.invalidate()
            refreshTimer = nil
            
            // Cancel any pending IMAGE loads to prevent memory leaks.
            // Only cancel image-type attachments — video/audio mids belong to
            // SharedAssetCache/VideoStateCache, not GlobalImageLoadManager.
            if let attachments = displayTweet.attachments {
                for attachment in attachments where attachment.type == .image {
                    let mainLoadId = DetailMediaCell.imageLoadId(for: attachment)
                    print("DEBUG: [TweetDetailView] Cancelling image load: \(mainLoadId)")
                    GlobalImageLoadManager.shared.cancelLoad(id: mainLoadId)
                }
            }
            
            print("DEBUG: [TweetDetailView] onDisappear called")
        }
    }
    
    /// Gray rules between the stacked media attachments and below the last one. The
    /// column layout leaves exactly this much space between items and the same amount
    /// of padding sits under the column, so the color behind shows through as both the
    /// bottom rule and the dividers. The media stays full-bleed horizontally.
    private static let mediaBorderThickness: CGFloat = 1.5
    private static let mediaBorderColor = Color(uiColor: .systemGray)

    private var mediaSection: some View {
        Group {
            if let attachments = displayTweet.attachments,
               !attachments.isEmpty {
                let audioAttachments = attachments.filter { $0.type == .audio }
                let mediaAttachments = attachments.filter { isMediaType($0.type) }
                let mediaAspectRatios = mediaAttachments.indices.map { index in
                    CGFloat(aspectRatio(for: mediaAttachments[index], at: index))
                }

                if !audioAttachments.isEmpty || !mediaAttachments.isEmpty {
                    // Deliberately NOT a LazyVStack. It holds at most two children — the
                    // audio player and the media column — so laziness saves nothing, and
                    // being lazy inside the detail ScrollView costs correctness: once the
                    // comments are scrolled to the bottom this column sits far outside the
                    // realized window and gets discarded. Dragging back re-realizes it, and
                    // SwiftUI re-resolves the scroll geometry in that same CA commit
                    // (HostingScrollView.updateContext) and re-applies a contentOffset
                    // anchored to the content it just rebuilt — a ~1765pt jump back up to
                    // the media grid, mid-drag, on a tweet with a tall media column.
                    // DetailMediaColumnLayout needs every subview to compute the layout
                    // anyway, so nothing here was ever actually deferred.
                    VStack(spacing: 1) {
                        if !audioAttachments.isEmpty {
                            CompactAudioPlaylistPlayer(
                                parentTweet: displayTweet,
                                attachments: audioAttachments
                            )
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                        }

                        if !mediaAttachments.isEmpty {
                            DetailMediaColumnLayout(
                                aspectRatios: mediaAspectRatios,
                                spacing: Self.mediaBorderThickness
                            ) {
                                ForEach(mediaAttachments.indices, id: \.self) { idx in
                                    let attachment = mediaAttachments[idx]
                                    let origIdx = attachments.firstIndex(where: { $0.mid == attachment.mid }) ?? idx
                                    let ar = mediaAspectRatios[idx]

                                    Group {
                                        if attachment.type == .video || attachment.type == .hls_video {
                                            if let baseUrl = displayTweet.author?.baseUrl,
                                               let url = attachment.getUrl(baseUrl) {
                                                DetailSingletonVideoPlayerView(
                                                    url: url,
                                                    mid: attachment.mid,
                                                    mediaType: attachment.type,
                                                    aspectRatio: attachment.aspectRatio,
                                                    shouldLoad: attachment.mid == firstMainTweetVideoToAutoplay?.mid,
                                                    shouldMountNativePlaybackSurface: shouldMountNativePlaybackSurface
                                                )
                                                .trackAttachmentVideoVisibility(
                                                    attachmentIndex: origIdx,
                                                    videoMid: attachment.mid,
                                                    coordinator: commentsVideoCoordinator,
                                                    scrollCoordinateSpace: "commentsScroll"
                                                )
                                            }
                                        } else {
                                            DetailMediaCell(
                                                parentTweet: displayTweet,
                                                attachmentIndex: origIdx,
                                                aspectRatio: Float(ar),
                                                shouldLoadVideo: false,
                                                showMuteButton: false
                                            )
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                selectedMediaIndex = origIdx
                                                showBrowser = true
                                            }
                                        }
                                    }
                                    // The custom layout gives the player a stable concrete proposal.
                                    // AVPlayerViewController's dynamic layout guides can otherwise form
                                    // an invalidation loop on the iPad-on-Mac runtime.
                                    .background(Color.black)
                                }
                            }
                            // Each item paints an opaque background over its own rect, so the
                            // color behind shows only in the gaps the layout leaves between
                            // items and in the padding under the column: dividers plus a
                            // bottom rule closing off the media.
                            .padding(.bottom, Self.mediaBorderThickness)
                            .background(Self.mediaBorderColor)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
    
    private var documentsSection: some View {
        Group {
            if let attachments = displayTweet.attachments,
               !attachments.isEmpty {
                // Filter to only show documents
                let documentAttachments = attachments.filter { isDocumentType($0.type) }
                
                if !documentAttachments.isEmpty {
                    DocumentAttachmentsView(
                        parentTweet: displayTweet,
                        documents: documentAttachments,
                        maxDocuments: nil // Show all documents in detail view
                    )
                    .padding(.leading, 48) // Left alignment with 48pt padding
                    .padding(.trailing, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear {
                        print("DEBUG: [TweetDetailView] Total attachments: \(attachments.count), Documents: \(documentAttachments.count)")
                        for (index, attachment) in attachments.enumerated() {
                            print("DEBUG: [TweetDetailView] Attachment \(index): type=\(attachment.type), fileName=\(attachment.fileName ?? "nil")")
                        }
                    }
                }
            }
        }
    }
    
    private var tweetHeader: some View {
        HStack(alignment: .top, spacing: 0) {
            if let user = displayTweet.author {
                NavigationLink(value: user) {
                    Avatar(user: user)
                }
                .buttonStyle(PlainButtonStyle())
            }
            Spacer(minLength: 4)
            TweetItemHeaderView(tweet: displayTweet)
            Spacer(minLength: 0)
            TweetMenu(
                tweet: displayTweet, 
                isPinned: displayTweet.isPinned(in: pinnedTweets),
                showDeleteButton: Gadget.canShowTweetDeleteMenu(
                    appUser: hproseInstance.appUser,
                    tweetAuthorId: displayTweet.authorId,
                    allowDeleteAll: false
                ),
                onShareTap: {
                    Task {
                        // Same link as the feed tweet's dropdown menu: the
                        // check_upgrade domain (see DEEPLINKING.md).
                        let items = await TweetActionBarView.buildFeedMenuShareItems(
                            tweet: displayTweet,
                            hproseInstance: hproseInstance,
                            isInDetailView: true
                        )
                        await MainActor.run {
                            menuShareItems = ShareSheetData(items: items)
                        }
                    }
                },
                onShowLogin: { showLoginSheet = true },
                onFilterTap: { showMenuFilterSheet = true },
                onReportTap: { showMenuReportSheet = true },
                onDeleteTap: { deleteAction in
                    pendingMenuDeleteAction = deleteAction
                    showMenuDeleteConfirmation = true
                }
            )
            .padding(.trailing, -20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.top)
    }
    
    private var tweetContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Show text content if available
            if let content = displayTweet.content, !content.isEmpty {
                SelectableTextView(text: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
            
            // Show quoted tweet if this is a quote tweet (regardless of content)
            if let _ = tweet.originalTweetId, let _ = tweet.originalAuthorId {
                if let orig = originalTweet {
                    VStack {
                        // Use embedded rendering: prevents quoted tweet videos from loading/autoplaying
                        // (avoids conflicts with feed/shared MediaCell players).
                        EmbeddedTweetView(
                            tweet: orig,
                            isPinned: false,
                            onTap: { selectedEmbeddedTweetForNavigation = $0 },
                            isEmbedded: true
                        )
                    }
                    .padding(.horizontal)
                    .padding(.top, (displayTweet.content?.isEmpty ?? true) ? 8 : 0)
                } else {
                    Text(NSLocalizedString("Loading quoted tweet...", comment: ""))
                        .foregroundColor(XTheme.secondaryTextColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: XTheme.quotedTweetSurface))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.horizontal)
                        .padding(.top, (displayTweet.content?.isEmpty ?? true) ? 8 : 0)
                }
            }
        }
    }
    
    private var actionButtons: some View {
        TweetActionButtonsView(
            tweet: displayTweet,
            onCommentTap: {
                shouldShowExpandedReply = true
            },
            isInDetailView: true
        )
        .frame(height: 30)
        .padding(.leading, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .padding(.trailing, 12)
    }
    
    private var commentsListView: some View {
        CommentListUIKitView(
            comments: $comments,
            parentTweet: displayTweet,
            commentFetcher: { page, size in
                let parentTweet = await MainActor.run { displayTweet }

                if page == 0 {
                    let parentMid = await MainActor.run { parentTweet.mid }
                    let alreadyServed = await MainActor.run { hasServedCachedCommentsForCurrentParentTweet }
                    if !alreadyServed {
                        let cached = await TweetDetailCommentsCache.shared.persistedComments(for: parentMid)
                        if !cached.isEmpty {
                            await MainActor.run {
                                hasServedCachedCommentsForCurrentParentTweet = true
                                comments = cached
                            }
                            return cached.map { Optional($0) }
                        }
                    }
                }

                let fetched = try await hproseInstance.fetchComments(
                    parentTweet,
                    pageNumber: page,
                    pageSize: size
                )
                if page == 0 {
                    await MainActor.run {
                        hasServedCachedCommentsForCurrentParentTweet = true
                        TweetDetailCommentsCache.shared.setComments(fetched.compactMap { $0 }, for: parentTweet.mid)
                    }
                }
                return fetched
            },
            notifications: [
                CommentListNotification(
                    name: .newCommentAdded,
                    key: "comment",
                    shouldAccept: { _ in true },
                    action: { comment, parentTweetId in
                        // Only add comment if it belongs to this tweet
                        if parentTweetId == displayTweet.mid {
                            comments.insert(comment, at: 0)
                        }
                    }
                ),
                CommentListNotification(
                    name: .commentDeleted,
                    key: "comment",
                    shouldAccept: { _ in true },
                    action: { comment, parentTweetId in
                        if parentTweetId == displayTweet.mid {
                            comments.removeAll { $0.mid == comment.mid }
                        }
                    }
                )
            ],
            hasUserScrolled: $hasUserScrolledComments,
            isRefreshing: $isPullRefreshing,
            commentsVideoCoordinator: commentsVideoCoordinator,
            onAvatarTap: { user in
                selectedCommentUserForNavigation = user
            },
            onShowLogin: {
                showLoginSheet = true
            },
            onShowToast: { message, isError in
                toastMessage = message
                toastIsError = isError
                showToast = true
            }
        )
    }
    
    private func setupInitialData() {
        configureCommentCacheContextIfNeeded()

        // The server syncs the tweet and its comments when this detail-view read
        // completes. Keep one owner for the ordered read so comments are fetched
        // exactly once, after that sync opportunity.
        if initialLoadParentTweetId != displayTweet.mid {
            initialLoadParentTweetId = displayTweet.mid
            Task { await loadInitialServerData() }
        }

        // Periodically reload the current provider without triggering a cross-node sync.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                await doReadTweet(isInitialLoad: false)
            }
        }
    }

    private func loadInitialServerData() async {
        await doReadTweet(isInitialLoad: true)
        // A failed tweet read must not prevent a best-effort comments refresh.
        await refreshComments()
    }

    // READ: get_tweet on hostIds[1] (author's read node), bypasses cache.
    // fromDetailView (server-side DHT provider sync) only needs to fire once per
    // detail-view open (isInitialLoad), not on every pull-to-refresh — except for
    // the embedded/quoted original tweet, which always gets it since it isn't
    // covered by any other "opened from feed" sync.
    private func doReadTweet(isInitialLoad: Bool) async {
        if let originalTweetId = tweet.originalTweetId,
           let originalAuthorId = tweet.originalAuthorId {
            let isPureRetweet = (tweet.content?.isEmpty ?? true) && (tweet.attachments?.isEmpty ?? true)
            if isPureRetweet {
                // The original tweet is the only thing displayed (as the embedded card).
                if let refreshed = try? await hproseInstance.getTweet(
                    tweetId: originalTweetId, authorId: originalAuthorId, bypassCache: true, fromDetailView: true
                ) {
                    await MainActor.run { adoptRefreshedOriginal(refreshed) }
                }
            } else {
                async let tweetResult = hproseInstance.getTweet(tweetId: tweet.mid, authorId: tweet.authorId, bypassCache: true, fromDetailView: isInitialLoad)
                async let originalResult = hproseInstance.getTweet(tweetId: originalTweetId, authorId: originalAuthorId, bypassCache: true, fromDetailView: true)
                if let refreshed = try? await tweetResult { await MainActor.run { try? tweet.update(from: refreshed) } }
                if let refreshedOriginal = try? await originalResult { await MainActor.run { adoptRefreshedOriginal(refreshedOriginal) } }
            }
        } else {
            if let refreshed = try? await hproseInstance.getTweet(
                tweetId: tweet.mid, authorId: tweet.authorId, bypassCache: true, fromDetailView: isInitialLoad
            ) {
                await MainActor.run { try? tweet.update(from: refreshed) }
            }
        }
    }

    /// Adopts a freshly fetched original tweet.
    ///
    /// `Tweet.getInstance` is a singleton registry, but instances get evicted
    /// (`clearInstance` on a feed trim, `cleanupOldInstances` over the cap), so a refresh
    /// can hand back a *different* object than the one a feed cell is already bound to.
    /// Copying onto the incumbent first keeps that cell live; the detail view then points
    /// at the registered instance so both sides converge.
    private func adoptRefreshedOriginal(_ refreshed: Tweet) {
        if let incumbent = originalTweet, incumbent !== refreshed {
            try? incumbent.update(from: refreshed)
        }
        originalTweet = refreshed
        // The detail-view read is now the only server load of the original, so it is
        // what marks the load attempt complete for the "Original tweet not found" gate.
        hasLoadedOriginalTweet = true
    }

    // SYNC: refresh_tweet on hostIds[1], which pulls from hostIds[0] if they differ
    private func doResyncTweet() async {
        if let originalTweetId = tweet.originalTweetId,
           let originalAuthorId = tweet.originalAuthorId {
            let isPureRetweet = (tweet.content?.isEmpty ?? true) && (tweet.attachments?.isEmpty ?? true)
            if isPureRetweet {
                if let refreshed = try? await hproseInstance.refreshTweet(
                    tweetId: originalTweetId, authorId: originalAuthorId
                ) {
                    await MainActor.run { adoptRefreshedOriginal(refreshed) }
                }
            } else {
                async let tweetResult = hproseInstance.refreshTweet(tweetId: tweet.mid, authorId: tweet.authorId)
                async let originalResult = hproseInstance.refreshTweet(tweetId: originalTweetId, authorId: originalAuthorId)
                if let refreshed = try? await tweetResult { await MainActor.run { try? tweet.update(from: refreshed) } }
                if let refreshedOriginal = try? await originalResult { await MainActor.run { adoptRefreshedOriginal(refreshedOriginal) } }
            }
        } else {
            if let refreshed = try? await hproseInstance.refreshTweet(
                tweetId: tweet.mid, authorId: tweet.authorId
            ) {
                await MainActor.run { try? tweet.update(from: refreshed) }
            }
        }
    }

    /// `refreshComments` walks comment pages until it overlaps what we already have and
    /// every RPC on the way has a 15s client timeout, so the control is capped rather
    /// than left to follow the fetch. `isPullRefreshing` clears when the fetch actually
    /// finishes, keeping the list from paginating underneath it past the cap.
    private func runCappedPullRefresh() async {
        await MainActor.run { isPullRefreshing = true }
        await runWithSpinnerCap {
            await refreshTweetAndComments()
            isPullRefreshing = false
        }
    }

    // Pull-to-refresh: sync the latest tweet state, then reload comments.
    private func refreshTweetAndComments() async {
        await doResyncTweet()
        await refreshComments()
    }

    // READ comments page-by-page on hostIds[1] until overlap or end.
    private func refreshComments() async {
        do {
            var allNewComments: [Tweet] = []
            var currentPage: UInt = 0
            let pageSize: UInt = 20
            var hasOverlap = false

            while !hasOverlap {
                let freshComments = try await hproseInstance.fetchComments(
                    displayTweet, pageNumber: currentPage, pageSize: pageSize
                )

                let validComments = freshComments.compactMap { $0 }
                if validComments.isEmpty { break }

                let existingIds = Set(comments.map { $0.mid })
                let newOnThisPage = validComments.filter { !existingIds.contains($0.mid) }
                if newOnThisPage.count < validComments.count { hasOverlap = true }
                allNewComments.append(contentsOf: newOnThisPage)
                if freshComments.count < pageSize { break }
                currentPage += 1
            }

            await MainActor.run {
                if !allNewComments.isEmpty {
                    comments.insert(contentsOf: allNewComments, at: 0)
                    TweetDetailCommentsCache.shared.setComments(comments, for: displayTweet.mid)
                }
            }
        } catch {}
    }

    private func configureCommentCacheContextIfNeeded() {
        let parentTweetId = displayTweet.mid
        if currentCommentsParentTweetId == parentTweetId {
            return
        }

        currentCommentsParentTweetId = parentTweetId
        hasServedCachedCommentsForCurrentParentTweet = false
        initialLoadParentTweetId = ""
        if let cachedComments = TweetDetailCommentsCache.shared.comments(for: parentTweetId) {
            comments = cachedComments
            hasServedCachedCommentsForCurrentParentTweet = true
        } else {
            comments = []
        }
    }
    
    private func aspectRatio(for attachment: MimeiFileType, at index: Int) -> CGFloat {
        if attachment.type == .video || attachment.type == .hls_video {
            return CGFloat(attachment.aspectRatio ?? (4.0/3.0))
        } else if attachment.type == .image {
            return CGFloat(attachment.aspectRatio ?? 1.0)
        }
        return 1.0 // Default aspect ratio
    }
    
    /// Calculate a fixed aspect ratio for all attachments to prevent height jumping
    /// Uses a smart approach: if all same orientation, use average; if mixed, use minimum aspect ratio
    private func calculateFixedAspectRatio(for attachments: [MimeiFileType]) -> CGFloat {
        guard !attachments.isEmpty else { return 1.0 }
        
        // Collect all aspect ratios
        let aspectRatios = attachments.map { attachment -> CGFloat in
            if attachment.type == .video || attachment.type == .hls_video {
                return CGFloat(attachment.aspectRatio ?? (4.0/3.0))
            } else if attachment.type == .image {
                return CGFloat(attachment.aspectRatio ?? 1.0)
            }
            return 1.0
        }
        
        // Separate portrait and landscape
        let portraits = aspectRatios.filter { $0 < 1.0 }
        let landscapes = aspectRatios.filter { $0 >= 1.0 }
        
        // If all are same orientation, use average
        if portraits.isEmpty || landscapes.isEmpty {
            let average = aspectRatios.reduce(0, +) / CGFloat(aspectRatios.count)
            // Clamp to reasonable bounds (0.5 to 2.0)
            return max(0.5, min(2.0, average))
        }
        
        // Mixed orientations: use the minimum aspect ratio
        // This ensures the container is tall enough for all content
        // (minimum aspect ratio = tallest content = maximum height needed)
        let minAspectRatio = aspectRatios.min() ?? 1.0
        
        // Clamp to reasonable bounds
        return max(0.5, min(2.0, minAspectRatio))
    }
    
    // Helper to check if attachment is visual media type
    private func isMediaType(_ type: MediaType) -> Bool {
        switch type {
        case .image, .video, .hls_video:
            return true
        default:
            return false
        }
    }
    
    // Helper to check if attachment is document type (pdf, word, excel, etc)
    private func isDocumentType(_ type: MediaType) -> Bool {
        switch type {
        case .pdf, .word, .excel, .ppt, .zip, .txt, .html, .unknown:
            return true
        default:
            return false
        }
    }
    
    /// Handle scroll offset changes to show/hide bottom navigation bar
    private func mountNativePlaybackSurfaceIfReady() {
        guard nativePlaybackMountDelayElapsed,
              !isDetailScrollInteractionActive,
              !shouldMountNativePlaybackSurface else { return }
        shouldMountNativePlaybackSurface = true
    }

    @MainActor
    private func handleScrollOffsetChange(_ offset: CGFloat, delta: CGFloat, isAtBottom: Bool) {
        // Threshold for scroll detection (prevents jittery behavior)
        let scrollThreshold: CGFloat = 5.0

        // Ignore very large deltas - these are likely programmatic scrolls from layout changes
        if abs(delta) > maxDeltaThreshold {
            return
        }

        // Mark the comment list as user-scrolled on the first real pan.
        // The auto-probe at open completes silently before this flips.
        if !hasUserScrolledComments && abs(delta) > scrollThreshold {
            hasUserScrolledComments = true
        }
        
        // Cooldown period after state changes to prevent feedback loops
        if let lastChangeTime = lastStateChangeTime {
            let timeSinceChange = Date().timeIntervalSince(lastChangeTime)
            if timeSinceChange < stateChangeCooldown {
                return
            }
        }
        
        // Detect scroll direction
        // When scrolling down: contentOffset.y increases (delta is positive)
        // When scrolling up: contentOffset.y decreases (delta is negative)
        let isScrollingDown = delta > scrollThreshold
        let isScrollingUp = delta < -scrollThreshold
        
        // Cancel any pending bottom bounce debouncer if we're not at bottom or scrolling away
        if !isAtBottom || isScrollingDown {
            bottomBounceDebouncer?.invalidate()
            bottomBounceDebouncer = nil
        }
        
        // Update bottom navigation bar visibility based on scroll direction
        if isScrollingDown && isNavigationBarVisible && offset > 0 {
            // Scrolling down - hide bottom navigation bar (only if we've scrolled past the top)
            bottomBounceDebouncer?.invalidate()
            bottomBounceDebouncer = nil
            isNavigationBarVisible = false
            lastStateChangeTime = Date()
            postNavigationVisibilityNotification(isVisible: false)
        } else if isScrollingUp && !isNavigationBarVisible {
            // Scrolling up - show bottom navigation bar
            // If at bottom, use debouncer to prevent showing due to bounce effect
            if isAtBottom {
                // Cancel any existing debouncer
                bottomBounceDebouncer?.invalidate()
                // Set debouncer - only show nav bar if still scrolling up after delay
                bottomBounceDebouncer = Timer.scheduledTimer(withTimeInterval: bottomBounceDebounceInterval, repeats: false) { timer in
                    DispatchQueue.main.async {
                        // Check if we're still at bottom - if so, don't show (it was just bounce)
                        // The scroll observer will call this again if user continues scrolling up
                    }
                }
                // Don't show nav bar when at bottom - prevents overlap with ReplyEditor
                return
            } else {
                // Not at bottom, show immediately
                bottomBounceDebouncer?.invalidate()
                bottomBounceDebouncer = nil
                isNavigationBarVisible = true
                lastStateChangeTime = Date()
                postNavigationVisibilityNotification(isVisible: true)
            }
        }
        
        // Reset to visible if at top of scroll view
        if offset <= 0 && !isNavigationBarVisible {
            bottomBounceDebouncer?.invalidate()
            bottomBounceDebouncer = nil
            isNavigationBarVisible = true
            lastStateChangeTime = Date()
            postNavigationVisibilityNotification(isVisible: true)
        }
    }
    
    /// Post navigation visibility notification with throttling
    private func postNavigationVisibilityNotification(isVisible: Bool) {
        // Throttle notifications to prevent excessive posting during rapid scroll
        let now = Date()
        if let lastTime = lastNotificationTime, now.timeIntervalSince(lastTime) < notificationThrottleInterval {
            return
        }
        
        lastNotificationTime = now
        NotificationCenter.default.post(
            name: .navigationVisibilityChanged,
            object: nil,
            userInfo: [
                "isVisible": isVisible,
                "hideHeight": true // TweetDetailView wants height 0 when hidden
            ]
        )
    }

}

// MARK: - Comment Video Tracking Wrapper

/// Wrapper view that tracks video visibility for comments and coordinates autoplay
@available(iOS 16.0, *)
struct CommentVideoTrackingWrapper: View {
    let parentTweet: Tweet
    @ObservedObject var comment: Tweet
    let coordinator: CommentsVideoPlaybackCoordinator
    let scrollCoordinateSpace: String

    /// Returns the first video attachment in the comment, if any
    private var videoAttachment: (index: Int, attachment: MimeiFileType)? {
        guard let attachments = comment.attachments else { return nil }
        for (index, attachment) in attachments.enumerated() {
            if attachment.type == .video || attachment.type == .hls_video {
                return (index, attachment)
            }
        }
        return nil
    }

    var body: some View {
        CommentItemView(
            parentTweet: parentTweet,
            comment: comment,
            isInProfile: false,
            onAvatarTap: nil,
            linkToComment: true
        )
        .background(
            // Only track visibility if the comment has video attachments
            Group {
                if let video = videoAttachment {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear {
                                updateVisibility(geometry: geometry, videoInfo: video)
                            }
                            .onChange(of: geometry.frame(in: .named(scrollCoordinateSpace))) { _, _ in
                                updateVisibility(geometry: geometry, videoInfo: video)
                            }
                    }
                }
            }
        )
        .onDisappear {
            if videoAttachment != nil {
                coordinator.reportVideoNotVisible(commentId: comment.mid)
            }
        }
    }

    private func updateVisibility(geometry: GeometryProxy, videoInfo: (index: Int, attachment: MimeiFileType)) {
        let frame = geometry.frame(in: .named(scrollCoordinateSpace))
        let screenBounds = UIScreen.main.bounds

        // Calculate how much of the comment is visible
        let visibleTop = max(frame.minY, 0)
        let visibleBottom = min(frame.maxY, screenBounds.height)
        let visibleHeight = max(0, visibleBottom - visibleTop)
        let totalHeight = frame.height

        let visibilityRatio = totalHeight > 0 ? visibleHeight / totalHeight : 0

        if visibilityRatio > 0 {
            coordinator.reportVideoVisible(
                commentId: comment.mid,
                outerTweetId: parentTweet.mid,
                videoMid: videoInfo.attachment.mid,
                attachmentIndex: videoInfo.index,
                visibilityRatio: visibilityRatio,
                yPosition: frame.minY
            )
        } else {
            coordinator.reportVideoNotVisible(commentId: comment.mid)
        }
    }
}
