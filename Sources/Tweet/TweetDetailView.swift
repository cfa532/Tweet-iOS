import SwiftUI
import AVKit
import UIKit

@MainActor
private final class TweetDetailCommentsCache {
    static let shared = TweetDetailCommentsCache()
    private var commentsByParentTweetId: [String: [Tweet]] = [:]

    private init() {}

    func comments(for parentTweetId: String) -> [Tweet]? {
        commentsByParentTweetId[parentTweetId]
    }

    func setComments(_ comments: [Tweet], for parentTweetId: String) {
        commentsByParentTweetId[parentTweetId] = comments
    }
}

// MARK: - Bottom bar scroll tracker
// Observes scroll view and updates SwiftUI state for bottom bar visibility
@MainActor
private final class BottomBarScrollObserver: NSObject {
    private var observation: NSKeyValueObservation?
    private var previousOffset: CGFloat = 0
    weak var scrollView: UIScrollView?
    var onScrollChange: ((CGFloat, CGFloat, Bool) -> Void)? // (currentOffset, delta, isAtBottom)
    
    func attachToScrollView(_ scrollView: UIScrollView) {
        self.scrollView = scrollView
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

                self.onScrollChange?(y, delta, isAtBottom)
            }
        }
    }
    
    func reset() {
        previousOffset = 0
    }
    
    deinit {
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
    let onScrollChange: (CGFloat, CGFloat, Bool) -> Void // (currentOffset, delta, isAtBottom)
    
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
    
    func updateUIView(_ uiView: UIView, context: Context) {}
    
    private static func findAndAttach(view: UIView, coordinator: BottomBarScrollCoordinator, onScrollChange: @escaping (CGFloat, CGFloat, Bool) -> Void) {
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
        textView.attributedText = makeAttributedString(text)
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
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
                        shouldLoad: shouldLoadVideo
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
            MainActor.assumeIsolated {
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

    @ObservedObject private var manager = DetailVideoManager.shared
    @State private var handoffThumbnail: UIImage?

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
        didThisVideoFailToLoad
            || !isThisVideoLoaded
            || isThisVideoPreparing
            || (manager.currentVideoMid == mid
                && !manager.isPlaybackRendering
                && !didThisVideoFinishPlayback
                && !didThisVideoFailToLoad)
    }

    var body: some View {
        ZStack {
            Color.black

            if isThisVideoLoaded, let player = manager.currentPlayer {
                DetailAVPlayerView(
                    player: player
                )
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

// MARK: - Detail AVPlayerViewController Wrapper

private struct DetailAVPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.videoGravity = .resizeAspect
        vc.view.backgroundColor = .black
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player {
            vc.player = player
        }
        if !vc.showsPlaybackControls {
            vc.showsPlaybackControls = true
        }
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: ()) {
        vc.player = nil
    }
}

@MainActor
@available(iOS 16.0, *)
struct TweetDetailView: View {
    @ObservedObject var tweet: Tweet
    @State private var showBrowser = false
    @State private var selectedMediaIndex = 0
    @State private var showLoginSheet = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastIsError = false
    @State private var pinnedTweets: [[String: Any]] = []
    @State private var originalTweet: Tweet?
    @State private var refreshTimer: Timer?
    @State private var comments: [Tweet] = []
    @State private var failedCommentIds: Set<String> = []
    // Flipped to true on the first real user pan, detected via the
    // BottomBarScrollTracker observing the parent UIScrollView. Used by
    // CommentListView to suppress the open-time auto-probe's flash.
    @State private var hasUserScrolledComments = false
    @State private var showReplyEditor = true
    @State private var shouldShowExpandedReply = false
    @State private var menuShareItems: ShareSheetData?
    @State private var cachedDisplayTweet: Tweet?
    @State private var hasLoadedOriginalTweet = false
    @State private var hasServedCachedCommentsForCurrentParentTweet = false
    @State private var currentCommentsParentTweetId = ""

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
                        await refreshTweetAndComments()
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
                        BottomBarScrollTracker { offset, delta, isAtBottom in
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
                .padding(.bottom, isNavigationBarVisible ? 48 : 8) // Move down when tab bar is hidden
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
        .sheet(item: $menuShareItems) { data in
            ShareSheetView(items: data.items)
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
        // Use .task(id:) instead of onAppear for stable async loading (like Android's LaunchedEffect)
        // This ensures the task only runs when originalTweetId changes, preventing duplicate loads
        .task(id: tweet.originalTweetId) {
            // Load original tweet if this is a retweet/quoted tweet
            guard let originalTweetId = tweet.originalTweetId,
                  let originalAuthorId = tweet.originalAuthorId else {
                return
            }
            
            // First, try to restore from cache immediately to prevent layout shifts
            if let cachedTweet = await TweetCacheManager.shared.fetchTweet(mid: originalTweetId) {
                await MainActor.run {
                    originalTweet = cachedTweet
                    hasLoadedOriginalTweet = true
                }
            }
            
            // Then fetch from server to get the latest version
            if let originalTweet = try? await hproseInstance.getTweet(
                tweetId: originalTweetId,
                authorId: originalAuthorId
            ) {
                await MainActor.run {
                    self.originalTweet = originalTweet
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
            if let attachments = displayTweet.attachments {
                DetailVideoManager.shared.setMainTweetAttachments(
                    attachments,
                    baseUrl: displayTweet.author?.baseUrl
                )
            }

            // Activate manager and coordinate singleton lifecycle across nested detail navigations (quoted -> original).
            DetailVideoManager.shared.activateForDetail()

            // Prevent audible playback during the push transition while still allowing
            // immediate player attachment (avoids black flicker on open).
            DetailVideoManager.shared.setStartupAudioMuteWindow(duration: 0.2)
            if let initialVideo = firstMainTweetVideoToAutoplay {
                DetailVideoManager.shared.loadVideo(
                    url: initialVideo.url,
                    mid: initialVideo.mid,
                    mediaType: initialVideo.mediaType
                )
            }

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
        .onChange(of: comments.count) { _, _ in
            // Rebuild video list for fullscreen navigation when comments change
            commentsVideoCoordinator.buildVideoList(from: comments, outerTweetId: displayTweet.mid)
            TweetDetailCommentsCache.shared.setComments(comments, for: displayTweet.mid)
        }
        .onChange(of: displayTweet.mid) { _, _ in
            configureCommentCacheContextIfNeeded()
        }
            .onDisappear {
            print("DEBUG: [TweetDetailView] ===== VIEW DISAPPEARED =====")
            print("DEBUG: [TweetDetailView] Cancelling image loads for tweet: \(displayTweet.mid)")

            // Deactivate manager first so feed resume cannot race detail's observer
            // teardown/state save while both surfaces point at the shared AVPlayer.
            DetailVideoManager.shared.deactivate()

            // Mark detail view as inactive only after handoff state is established.
            NavigationStateManager.shared.setDetailViewActive(false)

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
    
    private var mediaSection: some View {
        Group {
            if let attachments = displayTweet.attachments,
               !attachments.isEmpty {
                let audioAttachments = attachments.filter { $0.type == .audio }
                let mediaAttachments = attachments.filter { isMediaType($0.type) }

                if !audioAttachments.isEmpty || !mediaAttachments.isEmpty {
                    let cellWidth = UIScreen.main.bounds.width
                    LazyVStack(spacing: 1) {
                        if !audioAttachments.isEmpty {
                            CompactAudioPlaylistPlayer(
                                parentTweet: displayTweet,
                                attachments: audioAttachments
                            )
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                        }

                        ForEach(mediaAttachments.indices, id: \.self) { idx in
                            let attachment = mediaAttachments[idx]
                            let origIdx = attachments.firstIndex(where: { $0.mid == attachment.mid }) ?? idx
                            let ar = CGFloat(aspectRatio(for: attachment, at: idx))
                            let cellHeight = cellWidth / ar

                            Group {
                                if attachment.type == .video || attachment.type == .hls_video {
                                    if let baseUrl = displayTweet.author?.baseUrl,
                                       let url = attachment.getUrl(baseUrl) {
                                        DetailSingletonVideoPlayerView(
                                            url: url,
                                            mid: attachment.mid,
                                            mediaType: attachment.type,
                                            aspectRatio: attachment.aspectRatio,
                                            shouldLoad: attachment.mid == firstMainTweetVideoToAutoplay?.mid
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
                            .frame(width: cellWidth, height: cellHeight)
                            .background(Color.black)
                        }
                    }
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
                        let items = await TweetActionBarView.buildDetailShareItems(
                            tweet: displayTweet,
                            hproseInstance: hproseInstance
                        )
                        await MainActor.run {
                            menuShareItems = ShareSheetData(items: items)
                        }
                    }
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
                            onTap: nil, // NavigationLink to quoted tweet detail
                            isEmbedded: true
                        )
                    }
                    .padding(.horizontal)
                    .padding(.top, (displayTweet.content?.isEmpty ?? true) ? 8 : 0)
                } else {
                    Text("Loading quoted tweet...")
                        .foregroundColor(XTheme.secondaryTextColor)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }
            }
        }
    }
    
    private var actionButtons: some View {
        TweetActionButtonsView(
            tweet: displayTweet,
            onCommentTap: {
                shouldShowExpandedReply = true
            }
        )
        .frame(height: 30)
        .padding(.leading, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .padding(.trailing, 12)
    }
    
    private var commentsListView: some View {
        CommentListView(
            title: "Comments",
            comments: $comments,
            commentFetcher: { page, size in
                let parentTweet = await MainActor.run { displayTweet }

                if page == 0 {
                    let cachedComments: [Tweet]? = await MainActor.run {
                        guard !hasServedCachedCommentsForCurrentParentTweet else { return nil }
                        guard let cached = TweetDetailCommentsCache.shared.comments(for: parentTweet.mid),
                              !cached.isEmpty else { return nil }
                        hasServedCachedCommentsForCurrentParentTweet = true
                        comments = cached
                        return cached
                    }
                    if let cachedComments {
                        return cachedComments.map { Optional($0) }
                    }
                }

                let (fetched, failed) = try await hproseInstance.fetchComments(
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
                if !failed.isEmpty {
                    await MainActor.run { failedCommentIds.formUnion(failed) }
                }
                return fetched
            },
            showTitle: false,
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
            isEmbedded: true, // Embedded in TweetDetailView's ScrollView, avoid nested scrolling
            hasUserScrolled: $hasUserScrolledComments,
            rowView: { comment in
                CommentVideoTrackingWrapper(
                    parentTweet: displayTweet,
                    comment: comment,
                    coordinator: commentsVideoCoordinator,
                    scrollCoordinateSpace: "commentsScroll"
                )
                .environment(\.videoListProvider, { videoMid, outerTweetId, mediaTweetId, attachmentIndex in
                    let list = commentsVideoCoordinator.getVideoListForFullscreen()
                    guard !list.isEmpty else { return nil }
                    let startIndex = list.firstIndex(where: {
                        $0.videoMid == videoMid &&
                        $0.contextTweetId == outerTweetId &&
                        $0.mediaTweetId == mediaTweetId &&
                        $0.attachmentIndex == attachmentIndex
                    }) ?? list.firstIndex(where: {
                        $0.videoMid == videoMid &&
                        $0.contextTweetId == displayTweet.mid &&
                        $0.mediaTweetId == mediaTweetId &&
                        $0.attachmentIndex == attachmentIndex
                    }) ?? 0
                    return (list, startIndex)
                })
            }
        )
    }
    
    private func setupInitialData() {
        configureCommentCacheContextIfNeeded()

        // READ tweet on appear (comments handled by CommentListView.task)
        Task { await doReadTweet() }

        // SYNC: if nodes differ, resync tweet + any already-known failed comments
        let hostIds = displayTweet.author?.hostIds ?? []
        if hostIds.count >= 2 && hostIds[0] != hostIds[1] {
            Task { await doResyncTweet() }
            Task { await syncMissingComments() }
        }

        // 5-min tick: resync if nodes differ
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                let ids = displayTweet.author?.hostIds ?? []
                guard ids.count >= 2, ids[0] != ids[1] else { return }
                Task { await doResyncTweet() }
                await syncMissingComments()
            }
        }
    }

    // READ: get_tweet on hostIds[1] (author's read node), bypasses cache
    private func doReadTweet() async {
        if let originalTweetId = tweet.originalTweetId,
           let originalAuthorId = tweet.originalAuthorId {
            let isPureRetweet = (tweet.content?.isEmpty ?? true) && (tweet.attachments?.isEmpty ?? true)
            if isPureRetweet {
                if let refreshed = try? await hproseInstance.getTweet(
                    tweetId: originalTweetId, authorId: originalAuthorId, bypassCache: true
                ) {
                    await MainActor.run { originalTweet = refreshed }
                }
            } else {
                async let tweetResult = hproseInstance.getTweet(tweetId: tweet.mid, authorId: tweet.authorId, bypassCache: true)
                async let originalResult = hproseInstance.getTweet(tweetId: originalTweetId, authorId: originalAuthorId, bypassCache: true)
                if let refreshed = try? await tweetResult { await MainActor.run { try? tweet.update(from: refreshed) } }
                if let refreshedOriginal = try? await originalResult { await MainActor.run { originalTweet = refreshedOriginal } }
            }
        } else {
            if let refreshed = try? await hproseInstance.getTweet(
                tweetId: tweet.mid, authorId: tweet.authorId, bypassCache: true
            ) {
                await MainActor.run { try? tweet.update(from: refreshed) }
            }
        }
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
                    await MainActor.run { originalTweet = refreshed }
                }
            } else {
                async let tweetResult = hproseInstance.refreshTweet(tweetId: tweet.mid, authorId: tweet.authorId)
                async let originalResult = hproseInstance.refreshTweet(tweetId: originalTweetId, authorId: originalAuthorId)
                if let refreshed = try? await tweetResult { await MainActor.run { try? tweet.update(from: refreshed) } }
                if let refreshedOriginal = try? await originalResult { await MainActor.run { originalTweet = refreshedOriginal } }
            }
        } else {
            if let refreshed = try? await hproseInstance.refreshTweet(
                tweetId: tweet.mid, authorId: tweet.authorId
            ) {
                await MainActor.run { try? tweet.update(from: refreshed) }
            }
        }
    }

    // Pull-to-refresh: READ tweet + comments on hostIds[1], then fire background sync for failed comments
    private func refreshTweetAndComments() async {
        async let tweetRead: Void = doReadTweet()
        async let commentsRead: Void = refreshComments()
        await tweetRead
        await commentsRead

        let hostIds = displayTweet.author?.hostIds ?? []
        if hostIds.count >= 2 && hostIds[0] != hostIds[1] && !failedCommentIds.isEmpty {
            Task { await syncMissingComments() }
        }
    }

    // READ comments page-by-page on hostIds[1] until overlap or end; collects failedIds
    private func refreshComments() async {
        do {
            var allNewComments: [Tweet] = []
            var currentPage: UInt = 0
            let pageSize: UInt = 20
            var hasOverlap = false

            while !hasOverlap {
                let (freshComments, failed) = try await hproseInstance.fetchComments(
                    displayTweet, pageNumber: currentPage, pageSize: pageSize
                )
                await MainActor.run { failedCommentIds.formUnion(failed) }

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

    // SYNC: for each failed comment not blacklisted, call node_update_mid_by_score then retry
    private func syncMissingComments() async {
        let pending = Array(failedCommentIds).filter { !BlackList.shared.isBlacklisted($0) }
        for commentId in pending {
            if let comment = await hproseInstance.syncComment(commentId: commentId, parentTweet: displayTweet) {
                await MainActor.run {
                    failedCommentIds.remove(commentId)
                    guard !comments.contains(where: { $0.mid == comment.mid }) else { return }
                    NotificationCenter.default.post(
                        name: .commentSynced,
                        object: nil,
                        userInfo: ["comment": comment, "parentTweetId": displayTweet.mid]
                    )
                }
            }
        }
    }

    private func configureCommentCacheContextIfNeeded() {
        let parentTweetId = displayTweet.mid
        if currentCommentsParentTweetId == parentTweetId {
            return
        }

        currentCommentsParentTweetId = parentTweetId
        hasServedCachedCommentsForCurrentParentTweet = false

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
