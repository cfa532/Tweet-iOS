import SwiftUI
import AVKit

// MARK: - Video Player Representable
struct VideoPlayerRepresentable: UIViewRepresentable {
    let player: AVPlayer
    
    func makeUIView(context: Context) -> UIView {
        let view = VideoPlayerView()
        view.backgroundColor = .black
        
        NSLog("DEBUG: [VideoPlayerRepresentable] makeUIView - creating NEW view and layer")
        
        // Create layer immediately
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.needsDisplayOnBoundsChange = true
        view.layer.addSublayer(playerLayer)
        view.playerLayer = playerLayer
        
        context.coordinator.playerLayer = playerLayer
        context.coordinator.view = view
        context.coordinator.currentPlayer = player
        
        NSLog("DEBUG: [VideoPlayerRepresentable] makeUIView - layer created and player assigned")
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        guard let videoView = uiView as? VideoPlayerView else { return }
        
        NSLog("DEBUG: [VideoPlayerRepresentable] updateUIView called")
        
        // Check if player instance changed
        let playerChanged = videoView.playerLayer?.player !== player
        
        // Always refresh player connection
        if let playerLayer = videoView.playerLayer {
            NSLog("DEBUG: [VideoPlayerRepresentable] updateUIView - updating player, changed: \(playerChanged)")
            playerLayer.player = player
            context.coordinator.currentPlayer = player
            
            // CRITICAL: Reset recreation flag when player changes
            // This ensures layer will be recreated for the new player
            if playerChanged {
                videoView.hasRecreatedLayer = false
                NSLog("DEBUG: [VideoPlayerRepresentable] Player changed - reset recreation flag")
            }
        } else {
            NSLog("DEBUG: [VideoPlayerRepresentable] updateUIView - NO LAYER EXISTS!")
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject {
        var playerLayer: AVPlayerLayer?
        var view: VideoPlayerView?
        var currentPlayer: AVPlayer?
    }
}

// Custom UIView that properly handles layout
class VideoPlayerView: UIView {
    var playerLayer: AVPlayerLayer?
    var hasRecreatedLayer = false  // Not private - needs to be reset by representable
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        guard let layer = playerLayer else { return }
        
        let hadZeroBounds = layer.frame.width == 0 || layer.frame.height == 0
        let hasValidBounds = bounds.width > 0 && bounds.height > 0
        
        // ALWAYS recreate layer if it has zero bounds - don't trust the flag
        // This handles view reuse cases where the flag might be stale
        if hadZeroBounds && hasValidBounds {
            NSLog("DEBUG: [VideoPlayerView] Recreating layer - old frame: \(layer.frame), new bounds: \(bounds), flag was: \(hasRecreatedLayer)")
            hasRecreatedLayer = true
            
            // Get player before removing layer
            let player = layer.player
            layer.removeFromSuperlayer()
            
            // CRITICAL: Create layer WITHOUT player, set frame FIRST, then assign player
            let newLayer = AVPlayerLayer()
            newLayer.videoGravity = .resizeAspect
            newLayer.frame = bounds  // Set frame BEFORE assigning player
            newLayer.needsDisplayOnBoundsChange = true
            self.layer.addSublayer(newLayer)
            
            // NOW assign player after frame is set
            newLayer.player = player
            
            playerLayer = newLayer
            
            NSLog("DEBUG: [VideoPlayerView] Layer recreated - frame set BEFORE player assigned")
        } else {
            // Just update frame
            layer.frame = bounds
        }
    }
}

// MARK: - Scroll Detection
private enum ScrollDirection {
    case up
    case down
}

// Custom MediaCell for TweetDetailView that shows native video controls instead of going full-screen
@available(iOS 16.0, *)
struct DetailMediaCell: View {
    @ObservedObject var parentTweet: Tweet
    let attachmentIndex: Int
    let aspectRatio: Float
    @State private var play: Bool
    let shouldLoadVideo: Bool
    @State private var isVisible: Bool = true
    @State private var image: UIImage?
    @State private var loading = false
    let showMuteButton: Bool
    
    init(parentTweet: Tweet, attachmentIndex: Int, aspectRatio: Float = 1.0, play: Bool = false, shouldLoadVideo: Bool = false, showMuteButton: Bool = true) {
        self.parentTweet = parentTweet
        self.attachmentIndex = attachmentIndex
        self.aspectRatio = aspectRatio
        self._play = State(initialValue: play)
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
    
    private var baseUrl: URL {
        // Use author's baseUrl if available, otherwise use appUser's baseUrl
        // If both are nil, use real IP from HproseInstance (resolved at app start)
        return parentTweet.author?.baseUrl 
            ?? HproseInstance.shared.appUser.baseUrl 
            ?? HproseInstance.baseUrl
    }
    
    var body: some View {
        Group {
            if let url = attachment.getUrl(baseUrl) {
                switch attachment.type {
                case .video, .hls_video:
                    // Show video with SimpleVideoPlayer in tweetDetail mode (shares player with grid, bypasses VideoManager)
                    if shouldLoadVideo {
                        SimpleVideoPlayer(
                            url: url,
                            mid: attachment.mid,
                            parentTweetId: parentTweet.mid,
                            isVisible: true,
                            mediaType: attachment.type,
                            autoPlay: true,
                            videoAspectRatio: CGFloat(attachment.aspectRatio ?? 1.0),
                            showNativeControls: true,
                            isMuted: false,
                            mode: .tweetDetail
                        )
                    } else {
                        // Show placeholder for videos that haven't been loaded yet
                        Color.black
                            .overlay(
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(1.5)
                            )
                    }
                case .audio:
                    // Show audio player with SimpleAudioPlayer
                    SimpleAudioPlayer(url: url, autoPlay: false)
                        .environmentObject(MuteState.shared)
                case .image:
                    // Images still go to full-screen when tapped
                    Group {
                        if let image = image {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                        } else if loading {
                            // Show cached placeholder while loading original image
                            if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: attachment, baseUrl: baseUrl) {
                                Image(uiImage: cachedImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .clipped()
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
                                    .background(Color.gray.opacity(0.2))
                            }
                        } else {
                            // Show cached placeholder if available, otherwise gray background
                            if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: attachment, baseUrl: baseUrl) {
                                Image(uiImage: cachedImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .clipped()
                            } else {
                                Color.gray.opacity(0.2)
                            }
                        }
                    }
                default:
                    Color.gray.opacity(0.2)
                }
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .onAppear {
            print("DEBUG: [DetailMediaCell] Cell appeared for attachment \(attachmentIndex): \(attachment.type), mid: \(attachment.mid)")
            isVisible = true
            if attachment.type == .image && image == nil {
                print("DEBUG: [DetailMediaCell] Starting image load for attachment \(attachmentIndex)")
                loadImage()
            }
        }

    }
    
    private func loadImage() {
        guard let url = attachment.getUrl(baseUrl) else { return }
        
        let loadId = "\(attachment.mid)_\(baseUrl.absoluteString)"
        print("DEBUG: [TweetDetailView] loadImage called for \(loadId)")
        
        // First, try to get cached image immediately
        if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: attachment, baseUrl: baseUrl) {
            print("DEBUG: [TweetDetailView] Found cached image for \(loadId)")
            self.image = cachedImage
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
            self.image = loadedImage
            self.loading = false
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
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info
    @State private var isVisible = true
    @State private var showReplyEditor = true
    @State private var shouldShowExpandedReply = false
    @State private var cachedDisplayTweet: Tweet?
    @State private var hasLoadedOriginalTweet = false
    
    // Scroll detection state for top navigation bar
    @State private var isTopNavigationVisible = true
    @State private var previousScrollOffset: CGFloat = 0
    @State private var cleanupTask: Task<Void, Never>? // Delayed cleanup task
    
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
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            mediaSection
                            tweetHeader
                            tweetContent
                            actionButtons
                            Divider()
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                            commentsListView
                                .padding(.leading, -4)
                        }
                        .task {
                            setupInitialData()
                        }
                    }
                    .coordinateSpace(name: "scroll")
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        let offset = value.translation.height
                        handleScroll(offset: offset)
                    }
                    .onEnded { _ in
                        // When gesture ends, maintain current state for a brief period
                        // to allow scroll inertia to settle naturally
                        // Don't immediately change navigation state
                        // Let the scroll view settle naturally
                    }
            )
            .onAppear {
                handleScroll(offset: 0)
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
                .padding(.bottom, 48) // Add padding to avoid navigation bar
            }
                }
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(NSLocalizedString("Tweet", comment: "Tweet detail screen title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(!isTopNavigationVisible)
        .animation(.easeInOut(duration: 0.3), value: isTopNavigationVisible)
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
        .onAppear {
            print("DEBUG: [TweetDetailView] ===== VIEW APPEARED =====")
            print("DEBUG: [TweetDetailView] Tweet ID: \(tweet.mid)")
            print("DEBUG: [TweetDetailView] Attachments count: \(tweet.attachments?.count ?? 0)")
            
            // Don't stop videos - let them naturally pause when scrolled off screen
            // Posting stopAllVideos causes player conflicts when MediaCell and TweetDetailView share the same player
            print("DEBUG: [TweetDetailView] View appeared - not posting stopAllVideos to avoid player conflicts")
            
            // Log all attachments
            if let attachments = tweet.attachments {
                for (index, attachment) in attachments.enumerated() {
                    print("DEBUG: [TweetDetailView] Attachment \(index): \(attachment.type), mid: \(attachment.mid)")
                }
            }
            
            // Load original tweet immediately when view appears (like TweetItemView)
            if !hasLoadedOriginalTweet,
               let originalTweetId = tweet.originalTweetId,
               let originalAuthorId = tweet.originalAuthorId {
                hasLoadedOriginalTweet = true
                Task {
                    if let originalTweet = try? await hproseInstance.getTweet(
                        tweetId: originalTweetId,
                        authorId: originalAuthorId
                    ) {
                        await MainActor.run {
                            self.originalTweet = originalTweet
                        }
                    }
                }
            }
            
            
            // Ensure top navigation is visible when view appears
            isTopNavigationVisible = true
            print("DEBUG: [TweetDetailView] View appeared, top navigation set to visible")
        }
        .onChange(of: originalTweet) { _, _ in
            // Clear cache when originalTweet changes
            cachedDisplayTweet = nil
        }
        .overlay(toastOverlay)
        .onDisappear {
            print("DEBUG: [TweetDetailView] ===== VIEW DISAPPEARED =====")
            print("DEBUG: [TweetDetailView] Cancelling image loads for tweet: \(displayTweet.mid)")
            
            // Stop video player immediately
            // The .task defer block will also clean up when the view is permanently dismissed
            DetailVideoManager.shared.clearCurrentVideo()
            print("DEBUG: [TweetDetailView] Stopped video player immediately in onDisappear")
            
            // Cancel any pending cleanup task
            cleanupTask?.cancel()
            cleanupTask = nil
            
            // Reset top navigation visibility when view disappears
            withAnimation(.easeInOut(duration: 0.3)) {
                isTopNavigationVisible = true
            }
            
            // Clean up timer
            scrollEndTimer?.invalidate()
            scrollEndTimer = nil
            
            refreshTimer?.invalidate()
            refreshTimer = nil
            isVisible = false
            
            // Cancel any pending image loads to prevent memory leaks
            if let attachments = displayTweet.attachments {
                for attachment in attachments {
                    let baseUrl = displayTweet.author?.baseUrl ?? HproseInstance.baseUrl
                    let mainLoadId = "\(attachment.mid)_\(baseUrl.absoluteString)"
                    
                    print("DEBUG: [TweetDetailView] Cancelling load: \(mainLoadId)")
                    
                    GlobalImageLoadManager.shared.cancelLoad(id: mainLoadId)
                }
            }
            
            print("DEBUG: [TweetDetailView] onDisappear called")
        }
        .task {
            // This task is cancelled when the view is permanently dismissed
            // Keep singleton alive while view exists
            defer {
                // This runs when task is cancelled (view dismissed)
                // Use clearCurrentVideo() for proper cleanup (removes observers, deactivates audio session)
                DetailVideoManager.shared.clearCurrentVideo()
                print("DEBUG: [TweetDetailView] Task cancelled - cleaned up singleton")
            }
            
            // Just wait forever - cleanup happens in defer when cancelled
            try? await Task.sleep(for: .seconds(3600))
        }
    }
    
    private var mediaSection: some View {
        Group {
            if let attachments = displayTweet.attachments,
               !attachments.isEmpty {
                let aspect = aspectRatio(for: attachments[selectedMediaIndex], at: selectedMediaIndex)
                TabView(selection: $selectedMediaIndex) {
                    ForEach(attachments.indices, id: \.self) { index in
                        DetailMediaCell(
                            parentTweet: displayTweet,
                            attachmentIndex: index,
                            aspectRatio: Float(aspectRatio(for: attachments[index], at: index)),
                            play: index == selectedMediaIndex,
                            shouldLoadVideo:  index == selectedMediaIndex,
                            showMuteButton: false
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
                .onChange(of: selectedMediaIndex) { _, newIndex in
                    // User swiped to new image - no aspect ratio loading needed
                }
                .frame(maxWidth: .infinity)
                .frame(height: UIScreen.main.bounds.width / aspect)
                .background(Color.black)
            }
        }
    }
    
    private var tweetHeader: some View {
        HStack(alignment: .top, spacing: 4) {
            if let user = displayTweet.author {
                NavigationLink(value: user) {
                    Avatar(user: user)
                }
                .buttonStyle(PlainButtonStyle())
            }
            TweetItemHeaderView(tweet: displayTweet)
            TweetMenu(
                tweet: displayTweet, 
                isPinned: displayTweet.isPinned(in: pinnedTweets),
                showDeleteButton: displayTweet.authorId == hproseInstance.appUser.mid
            )
        }
        .padding(.horizontal, 8)
        .padding(.top)
    }
    
    private var tweetContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Show text content if available
            if let content = displayTweet.content, !content.isEmpty {
                Text(content)
//                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
            
            // Show quoted tweet if this is a quote tweet (regardless of content)
            if let _ = tweet.originalTweetId, let _ = tweet.originalAuthorId {
                if let orig = originalTweet {
                    VStack {
                        TweetItemView(
                            tweet: orig,
                            onTap: nil, // Enable NavigationLink for quoted tweet
                            hideActions: true,
                            backgroundColor: Color(.systemGray6).opacity(0.5)
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
        TweetActionButtonsView(
            tweet: displayTweet,
            onCommentTap: {
                shouldShowExpandedReply = true
            },
            isInDetailView: true  // Tell TweetActionButtonsView we're in detail view context
        )
        .padding(.leading, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .padding(.trailing, 12)
    }
    
    private var toastOverlay: some View {
        Group {
            if showToast {
                VStack {
                    Spacer()
                    ToastView(message: toastMessage, type: toastType)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .padding(.bottom, 32)
            }
        }
    }
    
    private var commentsListView: some View {
        CommentListView<CommentItemView>(
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
                    shouldAccept: { comment in
                        // Accept comments that belong to this tweet based on parentTweetId in notification
                        // This will be handled by the notification system using the parentTweetId
                        return true // We'll filter in the action
                    },
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
                    shouldAccept: { comment in
                        // Accept all comment deletions - let the action function filter
                        return true
                    },
                    action: { comment, parentTweetId in
                        if parentTweetId == displayTweet.mid {
                            comments.removeAll { $0.mid == comment.mid }
                        }
                    }
                )
            ],
            rowView: { comment in
                CommentItemView(
                    parentTweet: displayTweet,
                    comment: comment,
                    isInProfile: false,
                    onAvatarTap: nil, // NavigationLink will be handled inside CommentItemView
                    linkToComment: true // Enable NavigationLink wrapping
                )
            }
        )
    }
    
    private func setupInitialData() {
        // Refresh immediately in background - the Task inside refreshTweet() makes it non-blocking
        // View will display with current data, then update when refresh completes
        refreshTweet()
        
        // Set up periodic refresh timer (every 5 minutes)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                refreshTweet()
                refreshComments()
            }
        }
    }
    
    private func refreshTweet() {
        Task {
            do {
                if let refreshedTweet = try await hproseInstance.refreshTweet(
                    tweetId: tweet.mid,
                    authorId: tweet.authorId
                ) {
                    try await MainActor.run {
                        try tweet.update(from: refreshedTweet)
                    }
                }
            } catch {
                // Error refreshing tweet
            }
        }
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
    
    private func showToast(message: String, type: ToastView.ToastType) {
        toastMessage = message
        toastType = type
        withAnimation {
            showToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showToast = false
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
    
    
    @State private var scrollEndTimer: Timer?
    @State private var consecutiveSmallMovements: Int = 0
    @State private var isInertiaScrolling: Bool = false
    
    private func handleScroll(offset: CGFloat) {
        // Cancel any existing timer
        scrollEndTimer?.invalidate()
        
        // Calculate scroll direction and threshold
        let scrollDelta = offset - previousScrollOffset
        let scrollThreshold: CGFloat = 30
        
        // Track consecutive small movements to detect inertia scrolling
        if abs(scrollDelta) > scrollThreshold {
            consecutiveSmallMovements = 0
            isInertiaScrolling = false
        } else {
            consecutiveSmallMovements += 1
            // If we have many consecutive small movements, we're likely in inertia scrolling
            if consecutiveSmallMovements > 3 {
                isInertiaScrolling = true
            }
        }
        
        // Only change navigation state if we're not in inertia scrolling
        if !isInertiaScrolling {
            // Determine scroll direction
            let isScrollingDown = scrollDelta < -scrollThreshold
            let isScrollingUp = scrollDelta > scrollThreshold
            
            // Determine if we should show top navigation
            let shouldShowTopNavigation: Bool
            
            if offset >= 0 {
                // Always show when at the top
                shouldShowTopNavigation = true
            } else if isScrollingDown && isTopNavigationVisible {
                // Scrolling down and navigation is visible - hide it
                shouldShowTopNavigation = false
            } else if isScrollingUp && !isTopNavigationVisible {
                // Scrolling up and navigation is hidden - show it
                shouldShowTopNavigation = true
            } else {
                // Keep current state
                shouldShowTopNavigation = isTopNavigationVisible
            }
            
            // Only update if the state actually changed
            if shouldShowTopNavigation != isTopNavigationVisible {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isTopNavigationVisible = shouldShowTopNavigation
                }
                print("[TweetDetailView] Top navigation visibility changed to: \(shouldShowTopNavigation)")
            }
        }
        
        previousScrollOffset = offset
        
        // Reset inertia scrolling state after 0.3 seconds of no scroll activity
        scrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            Task { @MainActor in
                consecutiveSmallMovements = 0
                isInertiaScrolling = false
            }
        }
    }
}
