import SwiftUI
import AVKit

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
                                    // Video time remaining label in bottom left corner
                                    if showMuteButton {
                                        VideoTimeRemainingLabel(mid: mid)
                                            .padding(.leading, 8)
                                            .padding(.bottom, 8)
                                    }
                                    
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
        .onChange(of: isVisible) { visible in
            if visible {
                detailVideoManager.currentPlayer?.play()
            } else {
                detailVideoManager.currentPlayer?.pause()
            }
        }
        .onChange(of: isMuted) { newMuteState in
            detailVideoManager.currentPlayer?.isMuted = newMuteState
        }
        .onChange(of: detailVideoManager.currentPlayer) { player in
            print("DEBUG: [DETAIL VIDEO PLAYER] Player changed: \(player != nil ? "available" : "nil")")
            if player != nil {
                isLoading = false
            }
        }
    }
    
    private func setupPlayer() {
        print("DEBUG: [DETAIL VIDEO PLAYER] Setting up player for: \(mid)")
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
        print("DEBUG: [DETAIL VIDEO PLAYER] Cleanup - paused video for: \(mid)")
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
    @State private var selectedUser: User? = nil
    @State private var selectedComment: Tweet? = nil
    @State private var refreshTimer: Timer?
    @State private var comments: [Tweet] = []
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info
    @State private var isVisible = true
    @State private var imageAspectRatios: [Int: CGFloat] = [:] // index: aspectRatio
    @State private var showReplyEditor = false
    @State private var cachedDisplayTweet: Tweet?
    
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
            print("[TweetDetailView] Returning originalTweet: \(result.mid)")
        } else {
            result = tweet
            print("[TweetDetailView] Returning tweet: \(result.mid)")
        }
        
        cachedDisplayTweet = result
        return result
    }

    var body: some View {
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
            .padding(.top, 2)
            .task {
                setupInitialData()
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Tweet")
        .navigationBarTitleDisplayMode(.inline)
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
        .onChange(of: originalTweet) { _ in
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
            print("DEBUG: [TweetDetailView] Cleared DetailVideoManager on disappear")
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedUser != nil },
            set: { if !$0 { selectedUser = nil } }
        )) {
            if let selectedUser = selectedUser {
                ProfileView(user: selectedUser, onLogout: nil)
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedComment != nil },
            set: { if !$0 { selectedComment = nil } }
        )) {
            if let selectedComment = selectedComment {
                TweetDetailView(tweet: selectedComment)
            }
        }
        .overlay(
            VStack {
                Spacer()
                if showReplyEditor {
                    ReplyEditorView(
                        parentTweet: displayTweet,
                        onClose: {
                            showReplyEditor = false
                        },
                        initialExpanded: true
                    )
                }
            }
            .padding(.bottom, 48) // Move it down further, closer to navigation bar
        )

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
        HStack(alignment: .top, spacing: 12) {
            if let user = displayTweet.author {
                Avatar(user: user)
                    .onTapGesture { selectedUser = user }
            }
            TweetItemHeaderView(tweet: displayTweet)
            TweetMenu(tweet: displayTweet, isPinned: displayTweet.isPinned(in: pinnedTweets))
        }
        .padding(.horizontal)
        .padding(.top)
    }
    
    private var tweetContent: some View {
        Group {
            if let content = displayTweet.content, !content.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text(content)
                        .font(.title3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    // If this is a retweet with content, show quoted tweet without actions
                    if let _ = displayTweet.originalTweetId, let _ = displayTweet.originalAuthorId {
                        if let orig = originalTweet {
                            TweetItemView(
                                tweet: orig,
                                hideActions: true,
                                backgroundColor: Color(.systemGray4).opacity(0.7)
                            )
                            .background(Color(.systemGray4))
                            .cornerRadius(6)
                            .padding(.horizontal)
                            .padding(.vertical, 2)
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
                print("[TweetDetailView] Comment button tapped, setting showReplyEditor to true")
                showReplyEditor = true
            }
        )
        .padding(.leading, 48)
        .padding(.trailing, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
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
                print("[TweetDetailView] Fetching comments for displayTweet: \(await displayTweet.mid)")
                print("[TweetDetailView] displayTweet content: \(await displayTweet.content ?? "nil")")
                print("[TweetDetailView] displayTweet originalTweetId: \(await displayTweet.originalTweetId ?? "nil")")
                let fetchedComments = try await hproseInstance.fetchComments(
                    displayTweet,
                    pageNumber: page,
                    pageSize: size
                )
                print("[TweetDetailView] Fetched \(fetchedComments.compactMap { $0 }.count) comments")
                return fetchedComments
            },
            showTitle: false,
            notifications: [
                CommentListNotification(
                    name: .newCommentAdded,
                    key: "comment",
                    shouldAccept: { comment in
                        // Only accept comments that belong to this tweet
                        let shouldAccept = comment.originalTweetId == displayTweet.mid
                        print("[TweetDetailView] Comment \(comment.mid) shouldAccept check: \(shouldAccept)")
                        print("[TweetDetailView] Comment originalTweetId: \(comment.originalTweetId ?? "nil")")
                        print("[TweetDetailView] Display tweet mid: \(displayTweet.mid)")
                        return shouldAccept
                    },
                    action: { comment in 
                        print("[TweetDetailView] Adding comment \(comment.mid) to comments list")
                        comments.insert(comment, at: 0)
                        print("[TweetDetailView] Comments count after insert: \(comments.count)")
                    }
                ),
                CommentListNotification(
                    name: .commentDeleted,
                    key: "comment",
                    shouldAccept: { comment in
                        // Only accept comment deletions that belong to this tweet
                        comment.originalTweetId == displayTweet.mid
                    },
                    action: { comment in comments.removeAll { $0.mid == comment.mid } }
                )
            ],
            rowView: { comment in
                CommentItemView(
                    parentTweet: displayTweet,
                    comment: comment,
                    onAvatarTap: { user in selectedUser = user },
                    onTap: { comment in
                        selectedComment = comment
                    }
                )
            }
        )
    }

    private func setupInitialData() {
        print("[TweetDetailView] setupInitialData called")
        print("[TweetDetailView] tweet.originalTweetId: \(tweet.originalTweetId ?? "nil")")
        print("[TweetDetailView] tweet.originalAuthorId: \(tweet.originalAuthorId ?? "nil")")
        
        if let originalTweetId = tweet.originalTweetId,
           let originalAuthorId = tweet.originalAuthorId {
            print("[TweetDetailView] Fetching original tweet: \(originalTweetId)")
            Task {
                if let originalTweet = try? await hproseInstance.getTweet(
                    tweetId: originalTweetId,
                    authorId: originalAuthorId
                ) {
                    print("[TweetDetailView] Successfully fetched original tweet: \(originalTweet.mid)")
                    self.originalTweet = originalTweet
                } else {
                    print("[TweetDetailView] Failed to fetch original tweet")
                }
            }
        } else {
            print("[TweetDetailView] No originalTweetId/originalAuthorId, skipping original tweet fetch")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            refreshTweet()
        }
        
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                refreshTweet()
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
                print("Error refreshing tweet: \(error)")
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
}
