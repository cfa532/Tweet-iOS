//
//  CommentListView.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/6/6.
//

import SwiftUI

struct CommentListNotification {
    let name: Notification.Name
    let key: String
    let shouldAccept: (Tweet) -> Bool
    let action: (Tweet, String?) -> Void // Added parentTweetId parameter
}

@available(iOS 16.0, *)
struct CommentListView<RowView: View>: View {
    // MARK: - Properties
    let commentFetcher: @Sendable (UInt, UInt) async throws -> [Tweet?]
    /// The parent's own comment counter. A convenience value that can disagree with
    /// reality, so it only governs whether an empty list is worth waiting for — the
    /// page-0 fetch runs regardless and fills the list if the count was wrong.
    let commentCount: Int
    let rowView: (Tweet) -> RowView
    let notifications: [CommentListNotification]
    let externalRefreshToken: Int
    // Bound to a parent-owned flag (driven by the parent's UIScrollView
    // observer) that flips to true on the first real user pan. Used to
    // suppress the open-time auto-probe's "No more comments" flash. The
    // default is a non-functional constant binding for non-embedded usage.
    var hasUserScrolled: Binding<Bool> = .constant(true)
    /// Bound to the parent's pull-to-refresh flag when embedded. A refresh rewrites
    /// `comments` from the parent, which re-displays the last row and fires
    /// `onReachBottom`; without this gate that starts a load-more against a page
    /// cursor the refresh has already invalidated.
    var isRefreshing: Binding<Bool> = .constant(false)
    private let pageSize: UInt = 10

    @EnvironmentObject private var hproseInstance: HproseInstance
    @Binding var comments: [Tweet]
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var hasMoreComments: Bool = true
    @State private var currentPage: UInt = 0
    @State private var errorMessage: String? = nil
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info
    @State private var initialLoadComplete = false
    @State private var loadingStartTime: Date? = nil
    @State private var showNoMoreComments = false
    @State private var hasTriggeredInitialTaskLoad = false
    
    // Minimum duration to show the loading spinner (in seconds)
    private let minimumLoadingDuration: TimeInterval = 0.5

    // MARK: - Initialization
    init(
        comments: Binding<[Tweet]>,
        commentFetcher: @escaping @Sendable (UInt, UInt) async throws -> [Tweet?],
        commentCount: Int,
        notifications: [CommentListNotification]? = nil,
        externalRefreshToken: Int = 0,
        hasUserScrolled: Binding<Bool> = .constant(true),
        isRefreshing: Binding<Bool> = .constant(false),
        rowView: @escaping (Tweet) -> RowView
    ) {
        self._comments = comments
        self.commentFetcher = commentFetcher
        self.commentCount = commentCount
        self.notifications = notifications ?? []
        self.externalRefreshToken = externalRefreshToken
        self.hasUserScrolled = hasUserScrolled
        self.isRefreshing = isRefreshing
        self.rowView = rowView
    }

    // MARK: - Body
    // Always nested inside the host screen's own ScrollView (CommentDetailView), so this
    // never scrolls itself and never owns a refresh control — the host does both.
    var body: some View {
            ZStack {
                    CommentListContentView(
                        comments: $comments,
                        rowView: { comment in
                            rowView(comment)
                        },
                        isLoadingMore: isLoadingMore,
                        isLoading: isLoading,
                        commentCount: commentCount,
                        showNoMoreComments: showNoMoreComments,
                        onReachBottom: { handleReachBottom() }
                    )
                if showToast {
                    VStack {
                        Spacer()
                        ToastView(message: toastMessage, type: toastType)
                            .padding(.bottom, 40)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: showToast)
                }
            }
            .task {
                guard !hasTriggeredInitialTaskLoad else { return }
                hasTriggeredInitialTaskLoad = true
                await refreshComments()
            }
            .onChange(of: externalRefreshToken) { _, _ in
                currentPage = 0
                hasMoreComments = comments.count >= Int(pageSize)
                initialLoadComplete = true
            }
            // Listen to all notifications
            .onReceive(NotificationCenter.default.publisher(for: .newCommentAdded)) { notif in
                if let comment = notif.userInfo?["comment"] as? Tweet,
                   let parentTweetId = notif.userInfo?["parentTweetId"] as? String,
                   let notification = notifications.first(where: { $0.name == .newCommentAdded }),
                   notification.shouldAccept(comment) {
                    notification.action(comment, parentTweetId)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .commentDeleted)) { notif in
                if let comment = notif.userInfo?["comment"] as? Tweet,
                   let parentTweetId = notif.userInfo?["parentTweetId"] as? String,
                   let notification = notifications.first(where: { $0.name == .commentDeleted }),
                   notification.shouldAccept(comment) {
                    notification.action(comment, parentTweetId)
                }
            }
            // The silent open-time auto-probe may have set `hasMoreComments`
            // to false without flashing the label. Re-arm on first user
            // scroll so a subsequent bottom-reach can retry.
            .onChange(of: hasUserScrolled.wrappedValue) { _, scrolled in
                if scrolled && !hasMoreComments && !comments.isEmpty {
                    hasMoreComments = true
                }
            }
    }

    // MARK: - Methods
    func performInitialLoad() async {
        isLoading = true
        initialLoadComplete = false
        currentPage = 0
        
        do {
            let newComments = try await commentFetcher(0, pageSize)
            let validComments = newComments.compactMap { $0 }
            
            await MainActor.run {
                comments = validComments
                hasMoreComments = newComments.count >= pageSize
                initialLoadComplete = true
            }
        } catch {
            errorMessage = ErrorMessageHelper.userFriendlyMessage(from: error)
            await MainActor.run {
                initialLoadComplete = true
            }
        }
    }

    func refreshComments() async {
        guard !isLoading else { return }

        // Capped: the fetch keeps running past the cap and fills the list when it
        // lands, but the spinner does not follow it.
        await runWithSpinnerCap { await performInitialLoad() }

        // Set loading to false after refresh completes
        await MainActor.run {
            isLoading = false
        }
    }

    func loadMoreComments(page: UInt? = nil) {
        guard hasMoreComments, !isLoadingMore, initialLoadComplete else { 
            return 
        }
        
        let nextPage = page ?? (currentPage + 1)
        let pageSize = self.pageSize
        
        Task {
            // Record loading start time
            let startTime = Date()
            
            await MainActor.run {
                isLoadingMore = true
                loadingStartTime = startTime
            }
            
            do {
                let newComments = try await commentFetcher(nextPage, pageSize)
                let validComments = newComments.compactMap { $0 }
                
                // Calculate elapsed time
                let elapsedTime = Date().timeIntervalSince(startTime)
                let remainingTime = max(0, minimumLoadingDuration - elapsedTime)
                
                // Wait for minimum duration if needed
                if remainingTime > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingTime * 1_000_000_000))
                }
                
                await MainActor.run {
                    if !validComments.isEmpty {
                        // Merge by mid. Offset pagination over a list other users are
                        // still posting to can re-serve a comment that page N already
                        // returned, and a duplicate mid breaks the `ForEach(id:
                        // \.element.mid)` below. Matches CommentListUIKitView.
                        let existingIds = Set(comments.map { $0.mid })
                        comments.append(contentsOf: validComments.filter { !existingIds.contains($0.mid) })
                    }
                    
                    // Use the same logic as TweetListView
                    if newComments.count < pageSize {
                        hasMoreComments = false
                        if comments.count > 0 {
                            showNoMoreMessage()
                        }
                    } else if validComments.isEmpty {
                        // All comments are nil, auto-increment and try again
                        isLoadingMore = false
                        loadingStartTime = nil
                        loadMoreComments(page: nextPage + 1)
                        return
                    } else {
                        // We got some valid comments, continue normally
                        hasMoreComments = true
                    }
                    
                    currentPage = nextPage
                    isLoadingMore = false
                    loadingStartTime = nil
                }
            } catch {
                // Calculate elapsed time for error case
                let elapsedTime = Date().timeIntervalSince(startTime)
                let remainingTime = max(0, minimumLoadingDuration - elapsedTime)
                
                // Wait for minimum duration even on error
                if remainingTime > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingTime * 1_000_000_000))
                }
                
                await MainActor.run {
                    hasMoreComments = false
                    isLoadingMore = false
                    loadingStartTime = nil
                    if comments.count > 0 {
                        showNoMoreMessage()
                    }
                }
            }
        }
    }

    // Called whenever the last comment row appears on screen. Triggers a
    // load-more fetch when something is fetchable. The "No more comments"
    // flash and the open-time suppression live in `showNoMoreMessage`.
    private func handleReachBottom() {
        guard initialLoadComplete, !isLoading, !isLoadingMore, !isRefreshing.wrappedValue,
              hasMoreComments else { return }
        loadMoreComments()
    }

    // Flash "No more comments" for 2s, then re-arm `hasMoreComments` so the
    // user can scroll up and back down to retry — other users may post new
    // comments at any time, so "no more" is not a permanent state.
    //
    // Suppress the flash entirely while the user hasn't scrolled yet. The
    // initial auto-probe (fired by the last row's onAppear at open when all
    // comments already fit on screen) shouldn't surface UI noise.
    private func showNoMoreMessage() {
        guard hasUserScrolled.wrappedValue else { return }
        withAnimation(.easeOut(duration: 0.4)) {
            showNoMoreComments = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeIn(duration: 0.3)) {
                showNoMoreComments = false
            }
            hasMoreComments = true
        }
    }

    private func showToastWith(message: String, type: ToastView.ToastType) {
        toastMessage = message
        toastType = type
        showToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { showToast = false }
        }
    }
}

@available(iOS 16.0, *)
struct CommentListContentView<RowView: View>: View {
    @Binding var comments: [Tweet]
    let rowView: (Tweet) -> RowView
    let isLoadingMore: Bool
    let isLoading: Bool
    let commentCount: Int
    let showNoMoreComments: Bool
    let onReachBottom: () -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            Color.clear.frame(height: 0)

            // Display order, shared with Android `TweetDetailScreen` and Web
            // `TweetDetail.vue`: comments in hand win, then `commentCount` decides
            // whether an empty list is worth waiting on a spinner for.
            if comments.isEmpty && isLoading && commentCount > 0 {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text(NSLocalizedString("Loading comments...", comment: "Loading comments message"))
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else if comments.isEmpty {
                // Nothing to show and nothing worth waiting for
                VStack(spacing: 16) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(NSLocalizedString("No comment yet", comment: "No comment available message"))
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                // Show comments
                commentDivider

                ForEach(Array(comments.enumerated()), id: \.element.mid) { index, comment in
                    VStack(spacing: 0) {
                        rowView(comment)

                        // Add divider under each comment except the last one
                        if index < comments.count - 1 {
                            commentDivider
                        }
                    }
                    // Trigger from the last row directly — more reliable than a sentinel
                    // when the surrounding LazyVStack is itself nested inside another
                    // LazyVStack (as in TweetDetailView). Fires for both "load more" and
                    // "no more" feedback.
                    .onAppear {
                        if index == comments.count - 1 {
                            onReachBottom()
                        }
                    }
                }

                // Spinner — shown while loading more
                if isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }

                // "No more comments" label — shown briefly after a user-driven
                // load-more returned no new data.
                if showNoMoreComments && !isLoadingMore {
                    Text(NSLocalizedString("No more comments", comment: "Message shown when there are no more comments to load"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
    }

    private var commentDivider: some View {
        Rectangle()
            .padding(.horizontal, 4)
            .frame(height: 0.5)
            .foregroundColor(Color(.systemGray).opacity(0.4))
    }
}
