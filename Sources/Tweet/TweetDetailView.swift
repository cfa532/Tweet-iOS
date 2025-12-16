import SwiftUI
import AVKit
import UIKit

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
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.5)
                        }
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
                                if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: attachment) {
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
                                if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: attachment) {
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
                    Color.gray.opacity(0.2)
                }
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .onAppear {
            print("DEBUG: [DetailMediaCell] Cell appeared for attachment \(attachmentIndex): \(attachment.type), mid: \(attachment.mid)")
            
            // For videos in detail view, check if we need to restore position
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
        }

    }
    
    private func loadImage() {
        guard let baseUrl = baseUrl,
              let url = attachment.getUrl(baseUrl) else { return }
        
        let loadId = "\(attachment.mid)_\(baseUrl.absoluteString)"
        print("DEBUG: [TweetDetailView] loadImage called for \(loadId)")
        
        // First, try to get cached image immediately
        if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: attachment) {
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
            // Completion is already @MainActor, but use Task to ensure SwiftUI view updates properly
            Task { @MainActor in
                self.image = loadedImage
                self.loading = false
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
    
    // Scroll detection state for top navigation bar
    @State private var isTopNavigationVisible = true
    @State private var previousScrollOffset: CGFloat = 0
    
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
            
            // Ensure top navigation is visible when view appears
            isTopNavigationVisible = true
            print("DEBUG: [TweetDetailView] View appeared, top navigation set to visible")

            // Mark detail view as active to prevent MediaCell autoplay
            NavigationStateManager.shared.setDetailViewActive(true)

            // Coordinate singleton lifecycle across nested detail navigations (quoted -> original).
            DetailVideoManager.shared.beginDetailViewSession()
            
            // Detail view playback position is persisted independently (not seeded from feed positions).
        }
        .onChange(of: originalTweet) { _, _ in
            // Clear cache when originalTweet changes
            cachedDisplayTweet = nil
        }
        .onDisappear {
            print("DEBUG: [TweetDetailView] ===== VIEW DISAPPEARED =====")
            print("DEBUG: [TweetDetailView] Cancelling image loads for tweet: \(displayTweet.mid)")

            // Mark detail view as inactive
            NavigationStateManager.shared.setDetailViewActive(false)

            // End session: we pause immediately, and clear only if no other detail view appears shortly.
            // This avoids black flashes when pushing from one detail view to another.
            DetailVideoManager.shared.endDetailViewSession()
            
            // Reset top navigation visibility when view disappears
            withAnimation(.easeInOut(duration: 0.3)) {
                isTopNavigationVisible = true
            }
            
            // Clean up timers and tasks
            scrollUpdateTask?.cancel()
            scrollUpdateTask = nil
            
            refreshTimer?.invalidate()
            refreshTimer = nil
            
            // Cancel any pending image loads to prevent memory leaks
            if let attachments = displayTweet.attachments,
               let baseUrl = displayTweet.author?.baseUrl {
                for attachment in attachments {
                    let mainLoadId = "\(attachment.mid)_\(baseUrl.absoluteString)"
                    
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
                // Use a fixed height based on all attachments to prevent jumping
                let fixedAspect = calculateFixedAspectRatio(for: attachments)
                TabView(selection: $selectedMediaIndex) {
                    ForEach(attachments.indices, id: \.self) { index in
                        DetailMediaCell(
                            parentTweet: displayTweet,
                            attachmentIndex: index,
                            aspectRatio: Float(aspectRatio(for: attachments[index], at: index)),
                            shouldLoadVideo: index == selectedMediaIndex,
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
    
    @State private var scrollUpdateTask: Task<Void, Never>?
    @State private var lastStateChangeTime: Date = Date()
    
    private func handleScroll(offset: CGFloat) {
        // Cancel any existing update task
        scrollUpdateTask?.cancel()
        
        // Debounce scroll updates - only process after a short delay
        let capturedOffset = offset
        scrollUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000) // 0.15 seconds
            if !Task.isCancelled {
                processScrollUpdate(offset: capturedOffset)
            }
        }
    }
    
    private func processScrollUpdate(offset: CGFloat) {
        // Prevent rapid state changes - enforce minimum time between changes
        let timeSinceLastChange = Date().timeIntervalSince(lastStateChangeTime)
        let minTimeBetweenChanges: TimeInterval = 0.6 // Minimum 0.6 seconds between state changes
        
        // Calculate scroll direction and threshold
        let scrollDelta = offset - previousScrollOffset
        let scrollThreshold: CGFloat = 60 // Increased threshold for more stability
        
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
        
        // Only update if the state actually changed AND enough time has passed
        if shouldShowTopNavigation != isTopNavigationVisible && timeSinceLastChange >= minTimeBetweenChanges {
            lastStateChangeTime = Date()
            withAnimation(.easeInOut(duration: 0.3)) {
                isTopNavigationVisible = shouldShowTopNavigation
            }
            print("[TweetDetailView] Top navigation visibility changed to: \(shouldShowTopNavigation)")
        }
        
        previousScrollOffset = offset
    }
}

