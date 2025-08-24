import SwiftUI
import AVKit

// MARK: - Scroll Detection
private enum ScrollDirection {
    case up
    case down
}

// MARK: - Detail Video Player View
@available(iOS 16.0, *)
struct DetailVideoPlayerView: View {
    let url: URL
    let mid: String
    let isVisible: Bool
    let videoAspectRatio: CGFloat
    let showMuteButton: Bool
    
    @StateObject private var detailVideoManager = DetailVideoManager.shared
    @State private var isLoading = true
    @State private var isMuted: Bool = false
    
    var body: some View {
        Group {
            if let player = detailVideoManager.currentPlayer {
                VideoPlayer(player: player)
                    .aspectRatio(videoAspectRatio, contentMode: .fit)
                    .clipped()
                    .overlay(
                        // Video controls overlay
                        Group {
                            VStack {
                                Spacer()
                                HStack {

                                    
                                    Spacer()
                                    
                                    // Mute button in bottom right corner
                                    if showMuteButton {
                                        MuteButton()
                                            .padding(.trailing, 8)
                                            .padding(.bottom, 8)
                                    }
                                }
                            }
                        }
                    )
            } else if isLoading {
                ProgressView("Loading video...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.1))
            } else {
                Color.black
                    .overlay(
                        Image(systemName: "play.circle")
                            .font(.system(size: 40))
                            .foregroundColor(.white)
                    )
            }
        }
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            cleanupPlayer()
        }
        .onChange(of: isVisible) { _, visible in
            if visible {
                detailVideoManager.currentPlayer?.play()
            } else {
                detailVideoManager.currentPlayer?.pause()
            }
        }
        .onChange(of: isMuted) { _, newMuteState in
            detailVideoManager.currentPlayer?.isMuted = newMuteState
        }
        .onChange(of: detailVideoManager.currentPlayer) { _, player in
            if player != nil {
                isLoading = false
            }
        }
    }
    
    private func setupPlayer() {
        Task {
            await MainActor.run {
                isLoading = true
            }
            
            // Use DetailVideoManager to get or create player
            detailVideoManager.setCurrentVideo(url: url, mid: mid, autoPlay: isVisible)
        }
    }
    
    private func cleanupPlayer() {
        // Pause the video when detail view disappears
        detailVideoManager.currentPlayer?.pause()
    }
}

// Custom MediaCell for TweetDetailView that shows native video controls instead of going full-screen
@available(iOS 16.0, *)
struct DetailMediaCell: View {
    @ObservedObject var parentTweet: Tweet
    let attachmentIndex: Int
    let aspectRatio: Float
    @State private var play: Bool
    let shouldLoadVideo: Bool
    @State private var isVisible: Bool = false
    @State private var image: UIImage?
    @State private var loading = false
    let showMuteButton: Bool
    @ObservedObject var videoManager: DetailVideoManager
    
    // Local mute state management for detail view
    @State private var isMuted: Bool = false // Always unmuted in detail view
    @State private var hasSavedOriginalState: Bool = false
    
    init(parentTweet: Tweet, attachmentIndex: Int, aspectRatio: Float = 1.0, play: Bool = false, shouldLoadVideo: Bool = false, showMuteButton: Bool = true, videoManager: DetailVideoManager) {
        self.parentTweet = parentTweet
        self.attachmentIndex = attachmentIndex
        self.aspectRatio = aspectRatio
        self._play = State(initialValue: play)
        self.shouldLoadVideo = shouldLoadVideo
        self.showMuteButton = showMuteButton
        self.videoManager = videoManager
    }
    
    private var attachment: MimeiFileType {
        guard let attachments = parentTweet.attachments,
              attachmentIndex >= 0 && attachmentIndex < attachments.count else {
            return MimeiFileType(mid: "", type: "unknown")
        }
        return attachments[attachmentIndex]
    }
    
    private var baseUrl: URL {
        return parentTweet.author?.baseUrl ?? HproseInstance.baseUrl
    }
    
    var body: some View {
        Group {
            if let url = attachment.getUrl(baseUrl) {
                switch attachment.type.lowercased() {
                case "video", "hls_video":
                    // Show video with native controls using DetailVideoManager singleton
                    if shouldLoadVideo {
                        DetailVideoPlayerView(
                            url: url,
                            mid: attachment.mid,
                            isVisible: true, // Always visible in detail view
                            videoAspectRatio: CGFloat(attachment.aspectRatio ?? 1.0),
                            showMuteButton: showMuteButton
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
                case "image":
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
            isVisible = true
            if attachment.type.lowercased() == "image" && image == nil {
                loadImage()
            }
            
            // Handle mute state for videos in detail view - delay 1s before unmuting
            if (attachment.type.lowercased() == "video" || attachment.type.lowercased() == "hls_video") {
                setupDetailViewMuteState()
            }
        }

    }
    
    private func loadImage() {
        guard let url = attachment.getUrl(baseUrl) else { return }
        
        // First, try to get cached image immediately
        if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: attachment, baseUrl: baseUrl) {
            self.image = cachedImage
            return
        }
        
        // If no cached image, start loading
        loading = true
        
        Task {
            if let loadedImage = await ImageCacheManager.shared.loadAndCacheImage(from: url, for: attachment, baseUrl: baseUrl) {
                await MainActor.run {
                    self.image = loadedImage
                    self.loading = false
                }
            } else {
                await MainActor.run {
                    self.loading = false
                }
            }
        }
    }
    
    // MARK: - Mute State Management for Detail View
    
    private func setupDetailViewMuteState() {
        // Set local mute state to false (unmuted) immediately
        isMuted = false
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
    @State private var imageAspectRatios: [Int: CGFloat] = [:] // index: aspectRatio
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
                        print("[TweetDetailView] Drag gesture offset: \(offset)")
                        handleScroll(offset: offset)
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
        .onDisappear {
            // Reset top navigation visibility when view disappears
            withAnimation(.easeInOut(duration: 0.3)) {
                isTopNavigationVisible = true
            }
            print("DEBUG: [TweetDetailView] View disappeared, top navigation reset to visible")
        }
        .onChange(of: originalTweet) { _, _ in
            // Clear cache when originalTweet changes
            cachedDisplayTweet = nil
        }
        .overlay(toastOverlay)
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
            isVisible = false
            
            // Clear the DetailVideoManager to prevent cached player issues
            DetailVideoManager.shared.clearCurrentVideo()
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
                            showMuteButton: false,
                            videoManager: DetailVideoManager.shared,
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
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
            TweetMenu(tweet: displayTweet, isPinned: displayTweet.isPinned(in: pinnedTweets))
        }
        .padding(.horizontal, 8)
        .padding(.top)
    }
    
    private var tweetContent: some View {
        Group {
            if let content = displayTweet.content, !content.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text(content)
//                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    // If this is a retweet with content, show quoted tweet without actions
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
                        } else {
                            Text("Loading quoted tweet...")
                                .foregroundColor(.secondary)
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                        }
                    }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            refreshTweet()
        }
        
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
        let type = attachment.type.lowercased()
        if type == "video" || type == "hls_video" {
            return CGFloat(attachment.aspectRatio ?? (4.0/3.0))
        } else if type == "image" {
            if let ratio = imageAspectRatios[index] {
                return ratio
            } else {
                // Try to get cached image first
                let baseUrl = displayTweet.author?.baseUrl ?? HproseInstance.baseUrl
                if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: attachment, baseUrl: baseUrl) {
                    let ratio = cachedImage.size.width / cachedImage.size.height
                    DispatchQueue.main.async {
                        imageAspectRatios[index] = ratio
                    }
                    return ratio
                } else if let url = attachment.getUrl(baseUrl) {
                    // If not cached, load from network
                    loadImageAspectRatio(from: url, for: index)
                }
                return 4.0/3.0 // placeholder until loaded
            }
        } else {
            return 4.0/3.0
        }
    }
    
    private func loadImageAspectRatio(from url: URL, for index: Int) {
        // Only load if not already loaded
        guard imageAspectRatios[index] == nil else { return }
        DispatchQueue.global().async {
            if let data = try? Data(contentsOf: url),
               let image = UIImage(data: data) {
                let ratio = image.size.width / image.size.height
                DispatchQueue.main.async {
                    imageAspectRatios[index] = ratio
                }
            }
        }
    }
    
    private func handleScroll(offset: CGFloat) {
        print("[TweetDetailView] handleScroll called with offset: \(offset)")
        
        // Calculate scroll direction and threshold
        let scrollDelta = offset - previousScrollOffset
        let scrollThreshold: CGFloat = 30 // Single threshold for both scroll directions
        
        print("[TweetDetailView] Scroll delta: \(scrollDelta), previous offset: \(previousScrollOffset)")
        
        // Determine scroll direction with threshold
        let isScrollingDown = scrollDelta < -scrollThreshold
        let isScrollingUp = scrollDelta > scrollThreshold
        
        print("[TweetDetailView] isScrollingDown: \(isScrollingDown), isScrollingUp: \(isScrollingUp)")
        
        // Determine if we should show top navigation
        let shouldShowTopNavigation: Bool
        
        if offset >= 0 {
            // Always show when at the top (or initial state)
            shouldShowTopNavigation = true
        } else if isScrollingDown && isTopNavigationVisible {
            // Scrolling down and navigation is visible - hide it
            shouldShowTopNavigation = false
        } else if isScrollingUp && !isTopNavigationVisible {
            // Scrolling up and navigation is hidden - show it
            shouldShowTopNavigation = true
        } else {
            // Keep current state for small movements or when already in desired state
            shouldShowTopNavigation = isTopNavigationVisible
        }
        
        print("[TweetDetailView] Current isTopNavigationVisible: \(isTopNavigationVisible), shouldShowTopNavigation: \(shouldShowTopNavigation)")
        
        // Only update if the state actually changed
        if shouldShowTopNavigation != isTopNavigationVisible {
            withAnimation(.easeInOut(duration: 0.3)) {
                isTopNavigationVisible = shouldShowTopNavigation
            }
            
            print("[TweetDetailView] Top navigation visibility changed to: \(shouldShowTopNavigation) - Scroll delta: \(scrollDelta), offset: \(offset)")
        }
        
        previousScrollOffset = offset
    }
}
