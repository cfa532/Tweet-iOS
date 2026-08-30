//
//  CommentDetailView.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/6/8.
//

import SwiftUI
import AVKit

// Navigation wrapper to pass both comment and parent tweet
struct CommentNavigation: @MainActor Hashable {
    let comment: Tweet
    let parentTweet: Tweet
    
    @MainActor
    static func == (lhs: CommentNavigation, rhs: CommentNavigation) -> Bool {
        lhs.comment.mid == rhs.comment.mid && lhs.parentTweet.mid == rhs.parentTweet.mid
    }
    
    @MainActor
    func hash(into hasher: inout Hasher) {
        hasher.combine(comment.mid)
        hasher.combine(parentTweet.mid)
    }
}

@MainActor
@available(iOS 16.0, *)
struct CommentDetailViewWithParent: View {
    @ObservedObject var comment: Tweet
    @State private var parentTweet: Tweet?
    @State private var isLoading = true
    @EnvironmentObject private var hproseInstance: HproseInstance
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Group {
            if let parentTweet = parentTweet {
                CommentDetailView(comment: comment, parentTweet: parentTweet)
            } else if isLoading {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("Could not load parent tweet")
                        .font(.headline)
                    Button("Go Back") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
            }
        }
        .task {
            await fetchParentTweet()
        }
    }
    
    private func fetchParentTweet() async {
        guard let originalTweetId = comment.originalTweetId,
              let originalAuthorId = comment.originalAuthorId else {
            isLoading = false
            return
        }
        
        do {
            // Any read that opens a detail view carries fromDetailView, so the node
            // syncs and provides the tweet if it isn't a provider yet.
            let parent = try await hproseInstance.getTweet(
                tweetId: originalTweetId,
                authorId: originalAuthorId,
                bypassCache: true,
                fromDetailView: true
            )
            await MainActor.run {
                self.parentTweet = parent
                self.isLoading = false
            }
        } catch {
            print("Failed to fetch parent tweet: \(error)")
            await MainActor.run {
                self.isLoading = false
            }
        }
    }
}

@MainActor
@available(iOS 16.0, *)
struct CommentDetailView: View {
    @ObservedObject var comment: Tweet
    @ObservedObject var parentTweet: Tweet
    @State private var showBrowser = false
    @State private var selectedMediaIndex = 0
    @State private var showLoginSheet = false
    @State private var replies: [Tweet] = []
    @State private var repliesRefreshToken = 0
    /// True while a pull-to-refresh fetch is in flight. Stays true until the fetch
    /// actually finishes — not until the refresh control comes down — because its job
    /// is to keep the replies list from paginating against a page cursor the refresh
    /// is in the middle of invalidating.
    @State private var isPullRefreshing = false
    // Replies cache context, mirroring TweetDetailView's comment cache context.
    @State private var hasServedCachedRepliesForCurrentComment = false
    @State private var currentRepliesCommentId = ""
    @State private var initialLoadCommentId = ""
    @State private var refreshTimer: Timer?
    
    // Reply editor states
    @State private var showReplyEditor = true
    @State private var shouldShowExpandedReply = false
    
    // Toast states
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info
    
    @EnvironmentObject private var hproseInstance: HproseInstance
    @Environment(\.dismiss) private var dismiss
    
    init(comment: Tweet, parentTweet: Tweet) {
        self.comment = comment
        self.parentTweet = parentTweet
    }
    
    private func handleGuestAction() {
        if hproseInstance.appUser.isGuest {
            showLoginSheet = true
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Main comment section with deeper background
                    VStack(alignment: .leading, spacing: 0) {
                        mediaSection
                        commentHeader
                        commentContent
                        actionButtons
                    }
                    .padding(.bottom, 8)
                    .background(Color(UIColor.secondarySystemBackground))
                    
                    repliesListView
                }
            }
            .refreshable {
                await runCappedPullRefresh()
            }
            .background(Color(.systemBackground))
            
            // ReplyEditor as a component at the bottom
            if showReplyEditor {
                ReplyEditorView(
                    parentTweet: comment,
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
        .navigationTitle(NSLocalizedString("Reply", comment: "Reply screen title"))
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showBrowser) {
            MediaBrowserView(tweet: comment, initialIndex: selectedMediaIndex)
        }
        .sheet(isPresented: $showLoginSheet) {
            LoginView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .commentDeleted)) { notification in
            if let deletedComment = notification.userInfo?["comment"] as? Tweet,
               deletedComment.mid == comment.mid {
                dismiss()
            }
        }
        .overlay(toastOverlay)
        .onAppear {
            // Mark detail view as active to prevent MediaCell autoplay
            NavigationStateManager.shared.setDetailViewActive(true)

            // Claim the manager's attachment registration from the screen we were pushed
            // from — it still holds that tweet's videos and route until the last detail
            // view goes away, and a coordinator notification arriving now must not be
            // resolved against them.
            registerCommentVideoAttachments()

            // Activate detail video manager
            DetailVideoManager.shared.activateForDetail()
            DetailVideoManager.shared.prepareStartupAudioFade(duration: 0.5)
            loadSelectedCommentVideoIfNeeded()
        }
        .onChange(of: commentVideoWiringKey) { _, _ in
            // The comment's author route or its selected page changed. Nothing else drives
            // playback on this screen — there is no visibility coordinator here — so the
            // load has to follow the selection and the route that resolves its URL.
            registerCommentVideoAttachments()
            loadSelectedCommentVideoIfNeeded()
        }
        .onChange(of: replies.count) { _, _ in
            TweetDetailCommentsCache.shared.setComments(replies, for: comment.mid)
        }
        .onChange(of: comment.mid) { _, _ in
            configureRepliesCacheContextIfNeeded()
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
            // Keep feed autoplay suppressed until the outgoing player's fade and
            // handoff are complete.
            DetailVideoManager.shared.deactivate(audioFadeDuration: 0.35) {
                NavigationStateManager.shared.setDetailViewActive(false)
            }
        }
        .task {
            setupInitialData()
        }
    }

    /// Mirrors TweetDetailView.setupInitialData.
    private func setupInitialData() {
        configureRepliesCacheContextIfNeeded()

        // The server syncs the comment and its replies when this detail-view read
        // completes. Keep one owner for the ordered read so replies are fetched
        // exactly once, after that sync opportunity.
        if initialLoadCommentId != comment.mid {
            initialLoadCommentId = comment.mid
            Task { await loadInitialServerData() }
        }

        // Periodically reload the current provider without triggering a cross-node sync.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                await syncComment(isInitialLoad: false)
            }
        }
    }

    private func loadInitialServerData() async {
        await syncComment(isInitialLoad: true)
        // A failed comment read must not prevent a best-effort replies refresh.
        await refreshReplies()
    }

    /// Mirrors TweetDetailView.configureCommentCacheContextIfNeeded.
    private func configureRepliesCacheContextIfNeeded() {
        let commentId = comment.mid
        if currentRepliesCommentId == commentId {
            return
        }

        currentRepliesCommentId = commentId
        hasServedCachedRepliesForCurrentComment = false
        initialLoadCommentId = ""
        if let cachedReplies = TweetDetailCommentsCache.shared.comments(for: commentId) {
            replies = cachedReplies
            hasServedCachedRepliesForCurrentComment = true
        } else {
            replies = []
        }
    }
    
    private var commentVideoMids: [String] {
        (comment.attachments ?? [])
            .filter { $0.type == .video || $0.type == .hls_video }
            .map { $0.mid }
    }

    /// The video the pager is currently showing, if that page holds one. `DetailMediaCell`
    /// gives exactly this page `shouldLoadVideo`, so this is the video whose player the
    /// singleton manager is expected to be holding.
    private var selectedCommentVideo: (url: URL, mid: String, mediaType: MediaType)? {
        guard let attachments = comment.attachments,
              attachments.indices.contains(selectedMediaIndex),
              let baseUrl = comment.author?.baseUrl else {
            return nil
        }

        let attachment = attachments[selectedMediaIndex]
        guard attachment.type == .video || attachment.type == .hls_video,
              let url = attachment.getUrl(baseUrl) else {
            return nil
        }
        return (url, attachment.mid, attachment.type)
    }

    /// What the video wiring below is derived from: the comment, the page in view, and the
    /// author route its URL is built from. The route can still be arriving when this view
    /// opens, and the media section only renders a player once it exists, so the wiring
    /// has to follow the key rather than snapshot it on appear.
    private var commentVideoWiringKey: String {
        let route = comment.author?.baseUrl?.absoluteString ?? ""
        return "\(comment.mid)|\(route)|\(selectedMediaIndex)|\(commentVideoMids.joined(separator: ","))"
    }

    /// Registers unconditionally, empty list included: the manager still holds the
    /// attachments of the screen this one was pushed from until the last detail view goes
    /// away, and a comment with no video of its own must not leave that registration
    /// standing for a stray play notification to resolve against.
    private func registerCommentVideoAttachments() {
        DetailVideoManager.shared.setMainTweetAttachments(
            comment.attachments ?? [],
            baseUrl: comment.author?.baseUrl
        )
    }

    /// Loads the video on the selected page. Nothing else on this screen asks the manager
    /// to load one — there is no visibility coordinator here — so without this a comment
    /// with a video shows its spinner forever.
    private func loadSelectedCommentVideoIfNeeded() {
        guard let video = selectedCommentVideo else {
            // Paged to an image: the singleton player keeps running until something stops
            // it, and this screen has no visibility tracking to do that.
            if let playingMid = DetailVideoManager.shared.currentVideoMid,
               commentVideoMids.contains(playingMid) {
                DetailVideoManager.shared.pause()
            }
            return
        }

        guard DetailVideoManager.shared.currentVideoMid != video.mid else { return }

        DetailVideoManager.shared.loadVideo(
            url: video.url,
            mid: video.mid,
            mediaType: video.mediaType
        )
    }

    private var mediaSection: some View {
        Group {
            if let attachments = comment.attachments, !attachments.isEmpty {
                let aspect = CGFloat(attachments.first?.aspectRatio ?? 4.0/3.0)
                let _ = print("DEBUG: [CommentDetailView] Showing \(attachments.count) attachments from comment \(comment.mid)")
                let _ = print("DEBUG: [CommentDetailView]   comment.author = \(comment.author?.username ?? "nil")")
                let _ = print("DEBUG: [CommentDetailView]   comment.author.baseUrl = \(comment.author?.baseUrl?.absoluteString ?? "nil")")
                let _ = attachments.enumerated().forEach { index, att in
                    print("DEBUG: [CommentDetailView]   [\(index)] type=\(att.type), mid=\(att.mid)")
                }
                TabView(selection: $selectedMediaIndex) {
                    ForEach(attachments.indices, id: \.self) { index in
                        DetailMediaCell(
                            parentTweet: comment,
                            attachmentIndex: index,
                            aspectRatio: attachments[index].aspectRatio ?? 16.0/9.0,
                            shouldLoadVideo: index == selectedMediaIndex, // Only load current video
                            showMuteButton: false
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
                .frame(maxWidth: .infinity)
                .frame(height: UIScreen.main.bounds.width / aspect)
                .background(Color.black)
            } else {
                let _ = print("DEBUG: [CommentDetailView] No attachments found for comment \(comment.mid)")
                let _ = print("DEBUG: [CommentDetailView]   comment.attachments = \(comment.attachments?.description ?? "nil")")
                let _ = print("DEBUG: [CommentDetailView]   comment.author = \(comment.author?.username ?? "nil")")
                let _ = print("DEBUG: [CommentDetailView]   parentTweet.mid = \(parentTweet.mid)")
                let _ = print("DEBUG: [CommentDetailView]   parentTweet.attachments = \(parentTweet.attachments?.count ?? 0) items")
                EmptyView()
            }
        }
    }
    
    private var commentHeader: some View {
        HStack(alignment: .top, spacing: 0) {
            if let user = comment.author {
                Avatar(user: user)
            }
            Spacer(minLength: 4)
            TweetItemHeaderView(tweet: comment)
            Spacer(minLength: 0)
            CommentMenu(comment: comment, parentTweet: parentTweet)
                .padding(.trailing, -16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top)
    }
    
    private var commentContent: some View {
        Group {
            if let content = comment.content, !content.isEmpty {
                SelectableTextView(text: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        }
    }
    
    private var actionButtons: some View {
        TweetActionBarRepresentable(
            tweet: comment,
            onCommentTap: {
                shouldShowExpandedReply = true
            },
            isInDetailView: true,
            parentTweet: parentTweet
        )
        .frame(height: 30)
        .padding(.horizontal)
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
    
    private var repliesListView: some View {
        CommentListView<CommentItemView>(
            comments: $replies,
            commentFetcher: { page, size in
                let subject = await MainActor.run { comment }

                if page == 0 {
                    let subjectMid = await MainActor.run { subject.mid }
                    let alreadyServed = await MainActor.run { hasServedCachedRepliesForCurrentComment }
                    if !alreadyServed {
                        let cached = await TweetDetailCommentsCache.shared.persistedComments(for: subjectMid)
                        if !cached.isEmpty {
                            await MainActor.run {
                                hasServedCachedRepliesForCurrentComment = true
                                replies = cached
                            }
                            return cached.map { Optional($0) }
                        }
                    }
                }

                let fetched = try await hproseInstance.fetchComments(
                    subject,
                    pageNumber: page,
                    pageSize: size
                )
                if page == 0 {
                    await MainActor.run {
                        hasServedCachedRepliesForCurrentComment = true
                        TweetDetailCommentsCache.shared.setComments(fetched.compactMap { $0 }, for: subject.mid)
                    }
                }
                return fetched
            },
            commentCount: comment.commentCount ?? 0,
            notifications: [
                CommentListNotification(
                    name: .newCommentAdded,
                    key: "comment",
                    shouldAccept: { reply in
                        // Accept replies that belong to this comment
                        return true // We'll filter in the action
                    },
                    action: { reply, parentTweetId in
                        // Only add reply if it belongs to this comment
                        if parentTweetId == comment.mid {
                            print("[CommentDetailView] Adding reply \(reply.mid) to replies list")
                            replies.insert(reply, at: 0)
                            print("[CommentDetailView] Replies count after insert: \(replies.count)")
                        } else {
                            print("[CommentDetailView] Reply \(reply.mid) belongs to different comment (\(parentTweetId ?? "nil")), not adding")
                        }
                    }
                ),
                CommentListNotification(
                    name: .commentDeleted,
                    key: "comment",
                    shouldAccept: { reply in
                        // Only accept reply deletions that belong to this comment
                        reply.originalTweetId == comment.mid
                    },
                    action: { reply, parentTweetId in
                        if parentTweetId == comment.mid {
                            replies.removeAll { $0.mid == reply.mid }
                        }
                    }
                )
            ],
            externalRefreshToken: repliesRefreshToken,
            isRefreshing: $isPullRefreshing,
            rowView: { reply in
                CommentItemView(
                    parentTweet: comment,
                    comment: reply,
                    isInProfile: false,
                    onAvatarTap: nil, // NavigationLink will be handled inside CommentItemView
                    linkToComment: true // Enable NavigationLink wrapping
                )
            }
        )
        .padding(.leading, -8)
        .padding(.trailing, 4)
    }

    // A comment is itself a tweet on the backend, so opening its detail view needs the
    // same fromDetailView DHT provider sync/registration that TweetDetailView triggers for
    // top-level tweets. bypassCache is required for fromDetailView to actually reach the
    // server — comment is already populated from the feed, so a cache hit would otherwise
    // short-circuit before the sync ever runs.
    // `fromDetailView` asks the server to sync/provide the comment on the DHT. That only
    // needs to happen once per detail-view open, not on every periodic re-read — same
    // split as TweetDetailView.doReadTweet(isInitialLoad:).
    private func syncComment(isInitialLoad: Bool) async {
        if let refreshed = try? await hproseInstance.getTweet(
            tweetId: comment.mid, authorId: comment.authorId, bypassCache: true,
            fromDetailView: isInitialLoad
        ) {
            try? comment.update(from: refreshed)
        }
    }

    /// Every RPC below has a 15s client timeout, so the control is capped rather than
    /// left to follow the fetch. `isPullRefreshing` clears when the fetch actually
    /// finishes, keeping the list from paginating underneath it past the cap.
    private func runCappedPullRefresh() async {
        await MainActor.run { isPullRefreshing = true }
        await runWithSpinnerCap {
            await refreshCommentAndReplies()
            isPullRefreshing = false
        }
    }

    // Pull-to-refresh: sync the latest comment state, then reload replies.
    private func refreshCommentAndReplies() async {
        if let refreshed = try? await hproseInstance.refreshTweet(
            tweetId: comment.mid,
            authorId: comment.authorId
        ) {
            try? comment.update(from: refreshed)
        }

        await refreshReplies()
    }

    /// READ replies page-by-page until overlap or end, mirroring
    /// TweetDetailView.refreshComments. Walking pages catches the case where more than
    /// one page of replies accrued since the last load, and prepending (rather than
    /// replacing page 0) keeps replies already in hand — including the cached ones.
    private func refreshReplies() async {
        do {
            var allNewReplies: [Tweet] = []
            var currentPage: UInt = 0
            let pageSize: UInt = 20
            var hasOverlap = false

            while !hasOverlap {
                let freshReplies = try await hproseInstance.fetchComments(
                    comment, pageNumber: currentPage, pageSize: pageSize
                )

                let validReplies = freshReplies.compactMap { $0 }
                if validReplies.isEmpty { break }

                let existingIds = Set(replies.map { $0.mid })
                let newOnThisPage = validReplies.filter { !existingIds.contains($0.mid) }
                if newOnThisPage.count < validReplies.count { hasOverlap = true }
                allNewReplies.append(contentsOf: newOnThisPage)
                if freshReplies.count < pageSize { break }
                currentPage += 1
            }

            await MainActor.run {
                if !allNewReplies.isEmpty {
                    replies.insert(contentsOf: allNewReplies, at: 0)
                    TweetDetailCommentsCache.shared.setComments(replies, for: comment.mid)
                    // The child's page cursor is now behind by `allNewReplies.count`;
                    // resetting it keeps load-more aligned with the server's paging.
                    repliesRefreshToken += 1
                }
            }
        } catch {}
    }
}
