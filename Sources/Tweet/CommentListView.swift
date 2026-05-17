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
    let title: String
    let commentFetcher: @Sendable (UInt, UInt) async throws -> [Tweet?]
    let showTitle: Bool
    let rowView: (Tweet) -> RowView
    let notifications: [CommentListNotification]
    let isEmbedded: Bool // When true, don't use ScrollView (for nested scroll situations)
    // Bound to a parent-owned flag (driven by the parent's UIScrollView
    // observer) that flips to true on the first real user pan. Used to
    // suppress the open-time auto-probe's "No more comments" flash. The
    // default is a non-functional constant binding for non-embedded usage.
    var hasUserScrolled: Binding<Bool> = .constant(true)
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
        title: String,
        comments: Binding<[Tweet]>,
        commentFetcher: @escaping @Sendable (UInt, UInt) async throws -> [Tweet?],
        showTitle: Bool = true,
        notifications: [CommentListNotification]? = nil,
        isEmbedded: Bool = false,
        hasUserScrolled: Binding<Bool> = .constant(true),
        rowView: @escaping (Tweet) -> RowView
    ) {
        self.title = title
        self._comments = comments
        self.commentFetcher = commentFetcher
        self.showTitle = showTitle
        self.notifications = notifications ?? []
        self.isEmbedded = isEmbedded
        self.hasUserScrolled = hasUserScrolled
        self.rowView = rowView
    }

    // MARK: - Body
    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                if isEmbedded {
                    // When embedded, don't use ScrollView to avoid nested scroll issues
                    CommentListContentView(
                        comments: $comments,
                        rowView: { comment in
                            rowView(comment)
                        },
                        hasMoreComments: hasMoreComments,
                        isLoadingMore: isLoadingMore,
                        isLoading: isLoading,
                        initialLoadComplete: initialLoadComplete,
                        showNoMoreComments: showNoMoreComments,
                        onReachBottom: { handleReachBottom() }
                    )
                } else {
                    // Standalone mode: use ScrollView
                    ScrollView {
                        CommentListContentView(
                            comments: $comments,
                            rowView: { comment in
                                rowView(comment)
                            },
                            hasMoreComments: hasMoreComments,
                            isLoadingMore: isLoadingMore,
                            isLoading: isLoading,
                            initialLoadComplete: initialLoadComplete,
                            showNoMoreComments: showNoMoreComments,
                            onReachBottom: { handleReachBottom() }
                        )
                    }
                    .refreshable {
                        let startTime = Date()
                        await refreshComments()
                        
                        // Ensure pull-to-refresh spinner shows for at least 0.5 seconds
                        let elapsedTime = Date().timeIntervalSince(startTime)
                        let minimumDuration: TimeInterval = 0.5
                        if elapsedTime < minimumDuration {
                            let remainingTime = minimumDuration - elapsedTime
                            try? await Task.sleep(nanoseconds: UInt64(remainingTime * 1_000_000_000))
                        }
                    }
                }
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
        
        await performInitialLoad()
        
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
                        comments.append(contentsOf: validComments)
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
        guard initialLoadComplete, !isLoading, !isLoadingMore, hasMoreComments else { return }
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
    let hasMoreComments: Bool
    let isLoadingMore: Bool
    let isLoading: Bool
    let initialLoadComplete: Bool
    let showNoMoreComments: Bool
    let onReachBottom: () -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            Color.clear.frame(height: 0)

            // Show loading state
            if isLoading && comments.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text(NSLocalizedString("Loading comments...", comment: "Loading comments message"))
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else if initialLoadComplete && comments.isEmpty {
                // Show empty state when loading is complete but no comments
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
                ForEach(Array(comments.enumerated()), id: \.element.mid) { index, comment in
                    VStack(spacing: 0) {
                        rowView(comment)

                        // Add divider under each comment except the last one
                        if index < comments.count - 1 {
                            Rectangle()
                                .padding(.horizontal, 4)
                                .frame(height: 0.5)
                                .foregroundColor(Color(.systemGray).opacity(0.4))
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
}
