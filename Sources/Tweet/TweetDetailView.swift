import SwiftUI
import AVKit
import UIKit

// MARK: - Bottom bar scroll tracker
// Observes scroll view and updates SwiftUI state for bottom bar visibility
private class BottomBarScrollObserver: NSObject {
    private var observation: NSKeyValueObservation?
    private var previousOffset: CGFloat = 0
    weak var scrollView: UIScrollView?
    var onScrollChange: ((CGFloat, CGFloat, Bool) -> Void)? // (currentOffset, delta, isAtBottom)
    
    func attachToScrollView(_ scrollView: UIScrollView) {
        self.scrollView = scrollView
        observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, change in
            guard let self = self, let y = change.newValue?.y else { return }
            let delta = y - self.previousOffset
            self.previousOffset = y
            
            // Check if we're at the bottom (within 50pt threshold)
            let contentHeight = scrollView.contentSize.height
            let scrollViewHeight = scrollView.bounds.height
            let contentOffsetY = y
            let isAtBottom = (contentHeight > 0 && scrollViewHeight > 0) && 
                            (contentOffsetY + scrollViewHeight >= contentHeight - 50)
            
            // Ensure callback runs on main thread for SwiftUI updates
            DispatchQueue.main.async {
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
private class NavBarUIView: UIView {
    private let titleLabel = UILabel()
    private let backButton = UIButton(type: .system)
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
        backgroundColor = .systemBackground

        // Back button
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        backButton.setImage(UIImage(systemName: "chevron.left", withConfiguration: config), for: .normal)
        backButton.tintColor = UIColor(named: "ThemeText") ?? .label
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backButton)

        // Title
        titleLabel.text = NSLocalizedString("Tweet", comment: "Tweet detail screen title")
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = UIColor(named: "ThemeText") ?? .label
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
            guard let self = self, let y = change.newValue?.y else { return }
            self.handleScroll(y, scrollView: scrollView)
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
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.text = text
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textColor = UIColor.label
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.linkTextAttributes = [:] // Prevent links from being tappable
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }
    
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width - 32 // Account for padding
        uiView.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return size
    }
}

// Custom MediaCell for TweetDetailView that shows native video controls instead of going full-screen
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
    
    var body: some View {
        Group {
            if let baseUrl = baseUrl, let url = attachment.getUrl(baseUrl) {
                switch attachment.type {
                case .video, .hls_video:
                    // Show video with SimpleVideoPlayer in tweetDetail mode (shares player with grid, bypasses VideoManager)
                    // Videos already use .fit in tweetDetail mode, wrap in black background
                    ZStack {
                        Color.black
                        SimpleVideoPlayer(
                            url: url,
                            mid: attachment.mid,
                            parentTweetId: parentTweet.mid,
                            isVisible: shouldLoadVideo, // Control visibility instead of conditionally creating
                            mediaType: attachment.type,
                            authorId: parentTweet.authorId, // Pass authorId for health check
                            autoPlay: shouldLoadVideo, // Only autoplay when selected
                            videoAspectRatio: CGFloat(attachment.aspectRatio ?? 1.0),
                            showNativeControls: true,
                            isMuted: false,
                            mode: .tweetDetail
                        )
                        .opacity(shouldLoadVideo ? 1.0 : 0.0) // Hide when not selected
                    }
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
                                        .progressViewStyle(CircularProgressViewStyle())
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
            // Only reload if image was released
            guard self.image == nil, self.attachment.type == .image else { return }
            
            print("DEBUG: [DetailMediaCell] App returned to foreground, image released - reloading: \(self.attachment.mid)")
            self.loadImage()
        }
    }
    
    private func loadImage() {
        guard let baseUrl = baseUrl,
              let url = attachment.getUrl(baseUrl) else { return }
        
        // ✅ FIX: Use only mid as request ID - cache key is based on mid, so request ID should match
        // This ensures cached images are reused even when baseUrl changes
        let loadId = attachment.mid
        print("DEBUG: [TweetDetailView] loadImage called for \(loadId)")
        
        // First, try to get cached image immediately (disk check is OK in async context)
        if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: attachment) {
            print("DEBUG: [TweetDetailView] Found cached image for \(loadId)")
            self.image = cachedImage
            
            // ✅ Load original image in background and replace compressed cache
            // This ensures detail view uses the highest quality image
            Task {
                if let originalImage = await ImageCacheManager.shared.loadOriginalImage(
                    from: url,
                    for: attachment,
                    baseUrl: baseUrl,
                    replaceCompressedCache: true
                ) {
                    // Update image with original
                    await MainActor.run {
                        self.image = originalImage
                    }
                }
            }
            return
        }
        
        // If no cached image, start loading with global manager
        print("DEBUG: [TweetDetailView] Starting network load for \(loadId)")
        loading = true
        
        // Use high priority for visible images in detail view
        GlobalImageLoadManager.shared.loadImageHighPriority(
            id: loadId,
            url: url,
            attachment: attachment,
            baseUrl: baseUrl
        ) { loadedImage in
            print("DEBUG: [TweetDetailView] Load completed for \(loadId), success: \(loadedImage != nil)")
            // Completion is already @MainActor, update state immediately without additional Task wrapper
            // The extra Task wrapper was causing a delay in UI updates, making spinners stick
            self.image = loadedImage
            self.loading = false
            
            // ✅ Load original image in background and replace compressed cache
            // This ensures detail view uses the highest quality image
            if loadedImage != nil {
                Task {
                    if let originalImage = await ImageCacheManager.shared.loadOriginalImage(
                        from: url,
                        for: attachment,
                        baseUrl: baseUrl,
                        replaceCompressedCache: true
                    ) {
                        // Update image with original
                        await MainActor.run {
                            self.image = originalImage
                        }
                    }
                }
            }
        }
    }
}

@MainActor
@available(iOS 16.0, *)
struct TweetDetailView: View {
    @ObservedObject var tweet: Tweet
    @State private var showBrowser = false
    @State private var selectedMediaIndex = 0
    @State private var showLoginSheet = false
    @State private var pinnedTweets: [[String: Any]] = []
    @State private var originalTweet: Tweet?
    @State private var refreshTimer: Timer?
    @State private var comments: [Tweet] = []
    @State private var showReplyEditor = true
    @State private var shouldShowExpandedReply = false
    @State private var cachedDisplayTweet: Tweet?
    @State private var hasLoadedOriginalTweet = false

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

    // Track if the main tweet's media section is visible (for video pause/resume)
    @State private var isMainMediaVisible = true

    // Track if the main tweet has video attachments
    private var hasVideoAttachment: Bool {
        guard let attachments = displayTweet.attachments else { return false }
        return attachments.contains { $0.type == .video || $0.type == .hls_video }
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
                        .foregroundColor(.secondary)
                    Text("The original tweet may have been deleted or is no longer accessible.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    ZStack(alignment: .top) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            // Fixed spacer for floating nav bar
                            Color.clear.frame(height: 44)
                            
                            // Main tweet section with deeper background
                            VStack(spacing: 0) {
                                mediaSection
                                    .background(
                                        // Track main tweet video visibility for comment autoplay coordination
                                        Group {
                                            if hasVideoAttachment {
                                                GeometryReader { geometry in
                                                    Color.clear
                                                        .onAppear {
                                                            updateMainVideoVisibility(geometry: geometry)
                                                        }
                                                        .onChange(of: geometry.frame(in: .named("commentsScroll"))) { _, _ in
                                                            updateMainVideoVisibility(geometry: geometry)
                                                        }
                                                }
                                            }
                                        }
                                    )
                                tweetHeader
                                documentsSection
                                tweetContent
                                actionButtons
                            }
                            .padding(.bottom, 8)
                            .background(Color(UIColor.secondarySystemBackground))

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

                    // Floating navigation bar — pure UIKit, driven directly by KVO
                    NavBarOverlay(onBack: { dismiss() })
                        .frame(height: 44)
                    
                    // Bottom bar scroll tracker — placed outside ScrollView to properly find it
                    BottomBarScrollTracker { offset, delta, isAtBottom in
                        handleScrollOffsetChange(offset, delta: delta, isAtBottom: isAtBottom)
                    }
                    .frame(width: 0, height: 0)
                    } // ZStack

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
        .background(Color(.systemBackground))
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
        .onReceive(NotificationCenter.default.publisher(for: .tweetDeleted)) { notification in
            if let deletedTweetId = notification.userInfo?["tweetId"] as? String ?? notification.object as? String,
               deletedTweetId == displayTweet.mid {
                dismiss()
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

            // Activate manager and coordinate singleton lifecycle across nested detail navigations (quoted -> original).
            DetailVideoManager.shared.activateForDetail()

            // Activate comments video playback coordinator
            // Pass hasVideoAttachment so coordinator knows to suppress comment videos initially
            commentsVideoCoordinator.activate(hasMainVideo: hasVideoAttachment)

            // Rebuild video list on re-enter (deactivate clears it, onChange won't fire if count unchanged)
            commentsVideoCoordinator.buildVideoList(from: comments)

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
            commentsVideoCoordinator.buildVideoList(from: comments)
        }
            .onDisappear {
            print("DEBUG: [TweetDetailView] ===== VIEW DISAPPEARED =====")
            print("DEBUG: [TweetDetailView] Cancelling image loads for tweet: \(displayTweet.mid)")

            // Mark detail view as inactive
            NavigationStateManager.shared.setDetailViewActive(false)

            // Deactivate manager - this handles session end and lifecycle teardown
            DetailVideoManager.shared.deactivate()

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
            
            // Cancel any pending image loads to prevent memory leaks
            if let attachments = displayTweet.attachments {
                for attachment in attachments {
                    // ✅ FIX: Use only mid as request ID (matching loadImageHighPriority above)
                    let mainLoadId = attachment.mid

                    print("DEBUG: [TweetDetailView] Cancelling load: \(mainLoadId)")

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
                // Filter to only show media types (images, videos, audio)
                let mediaAttachments = attachments.filter { isMediaType($0.type) }
                
                if !mediaAttachments.isEmpty {
                    // Use a fixed height based on media attachments only
                    let fixedAspect = calculateFixedAspectRatio(for: mediaAttachments)
                    TabView(selection: $selectedMediaIndex) {
                        ForEach(mediaAttachments.indices, id: \.self) { index in
                            let attachment = mediaAttachments[index]
                            DetailMediaCell(
                                parentTweet: displayTweet,
                                attachmentIndex: attachments.firstIndex(where: { $0.mid == attachment.mid }) ?? index,
                                aspectRatio: Float(aspectRatio(for: attachment, at: index)),
                                shouldLoadVideo: index == selectedMediaIndex && isMainMediaVisible, // Only play when selected AND visible
                                showMuteButton: false
                            )
                            .tag(index)
                        }
                    }
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScreen.main.bounds.width / fixedAspect)
                    .background(Color.black)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showBrowser = true
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
                showDeleteButton: displayTweet.authorId == hproseInstance.appUser.mid
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
                            backgroundColor: Color(.systemGray6).opacity(0.5),
                            isEmbedded: true
                        )
                        
                    }
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .padding(.top, (displayTweet.content?.isEmpty ?? true) ? 8 : 0)
                } else {
                    Text("Loading quoted tweet...")
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }
            }
        }
    }
    
    private var actionButtons: some View {
        TweetActionBarRepresentable(
            tweet: displayTweet,
            onCommentTap: {
                shouldShowExpandedReply = true
            },
            onShowLogin: {
                showLoginSheet = true
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
        CommentListView(
            title: "Comments",
            comments: $comments,
            commentFetcher: { page, size in
                let fetchedComments = try await hproseInstance.fetchComments(
                    displayTweet,
                    pageNumber: page,
                    pageSize: size
                )
                return fetchedComments
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
            rowView: { comment in
                CommentVideoTrackingWrapper(
                    parentTweet: displayTweet,
                    comment: comment,
                    coordinator: commentsVideoCoordinator,
                    scrollCoordinateSpace: "commentsScroll"
                )
                .environment(\.videoListProvider, { videoMid, cellTweetId, attachmentIndex in
                    let list = commentsVideoCoordinator.getVideoListForFullscreen()
                    guard !list.isEmpty else { return nil }
                    let startIndex = list.firstIndex(where: {
                        $0.videoMid == videoMid && $0.cellTweetId == cellTweetId
                    }) ?? list.firstIndex(where: {
                        $0.videoMid == videoMid
                    }) ?? 0
                    return (list, startIndex)
                })
            }
        )
    }
    
    private func setupInitialData() {
        // Refresh immediately in background - the Task inside refreshTweet() makes it non-blocking
        // View will display with current data, then update when refresh completes
        refreshTweet()
        
        // Set up periodic refresh timer (every 5 minutes)
        // NOTE: Can't use [weak self] for structs (SwiftUI Views), but timer is invalidated in onDisappear
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                refreshTweet()
                refreshComments()
            }
        }
    }
    
    private func refreshTweet() {
        Task {
            if let refreshedTweet = try await hproseInstance.refreshTweet(
                tweetId: tweet.mid,
                authorId: tweet.authorId
            ) {
                try await MainActor.run {
                    try tweet.update(from: refreshedTweet)
                }
            }
        }
    }
    
    private func refreshTweetAndComments() async {
        // Refresh both tweet and comments when pull-to-refresh is triggered
        async let tweetRefresh: Void = {
            if let refreshedTweet = try? await hproseInstance.refreshTweet(
                tweetId: tweet.mid,
                authorId: tweet.authorId
            ) {
                await MainActor.run {
                    try? tweet.update(from: refreshedTweet)
                }
            }
        }()
        
        async let commentsRefresh: Void = {
            await refreshComments()
        }()
        
        // Wait for both to complete
        await tweetRefresh
        await commentsRefresh
    }
    
    private func refreshComments() {
        Task {
            do {
                var allNewComments: [Tweet] = []
                var currentPage: UInt = 0
                let pageSize: UInt = 20
                var hasOverlap = false
                
                // Load pages until we find overlap with existing comments
                while !hasOverlap {
                    let freshComments = try await hproseInstance.fetchComments(
                        displayTweet,
                        pageNumber: currentPage,
                        pageSize: pageSize
                    )
                    let validComments = freshComments.compactMap { $0 }
                    
                    if validComments.isEmpty {
                        break
                    }
                    
                    // Check for overlap with existing comments
                    let existingIds = Set(comments.map { $0.mid })
                    let newCommentsOnThisPage = validComments.filter { !existingIds.contains($0.mid) }
                    
                    if newCommentsOnThisPage.count < validComments.count {
                        // Found overlap - some comments on this page already exist
                        hasOverlap = true
                    } else {
                        // No overlap - all comments on this page are new
                    }
                    
                    // Add new comments from this page
                    allNewComments.append(contentsOf: newCommentsOnThisPage)
                    
                    // If we got fewer comments than pageSize, we've reached the end
                    if freshComments.count < pageSize {
                        break
                    }
                    
                    currentPage += 1
                }
                
                await MainActor.run {
                    if !allNewComments.isEmpty {
                        // Insert all new comments at the beginning (most recent first)
                        comments.insert(contentsOf: allNewComments, at: 0)
                    }
                }
            } catch {
                // Error refreshing comments
            }
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
    
    // Helper to check if attachment is media type (image, video, audio)
    private func isMediaType(_ type: MediaType) -> Bool {
        switch type {
        case .image, .video, .hls_video, .audio:
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
    
    /// Update main tweet video visibility for comment autoplay coordination
    private func updateMainVideoVisibility(geometry: GeometryProxy) {
        let frame = geometry.frame(in: .named("commentsScroll"))
        let screenBounds = UIScreen.main.bounds

        // Calculate how much of the video section is visible
        let visibleTop = max(frame.minY, 0)
        let visibleBottom = min(frame.maxY, screenBounds.height)
        let visibleHeight = max(0, visibleBottom - visibleTop)
        let totalHeight = frame.height

        // Consider video visible if at least 30% is on screen
        let visibilityRatio = totalHeight > 0 ? visibleHeight / totalHeight : 0
        let isVisible = visibilityRatio >= 0.30

        // Update state to control main video playback
        if isMainMediaVisible != isVisible {
            isMainMediaVisible = isVisible
        }

        commentsVideoCoordinator.reportMainTweetVideoVisibility(isVisible: isVisible)
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

