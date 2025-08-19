//
//  CommentListView.swift
//  Tweet
//
//  Created by 超方 on 2025/6/6.
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
    private let pageSize: UInt = 20

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

    // MARK: - Initialization
    init(
        title: String,
        comments: Binding<[Tweet]>,
        commentFetcher: @escaping @Sendable (UInt, UInt) async throws -> [Tweet?],
        showTitle: Bool = true,
        notifications: [CommentListNotification]? = nil,
        rowView: @escaping (Tweet) -> RowView
    ) {
        self.title = title
        self._comments = comments
        self.commentFetcher = commentFetcher
        self.showTitle = showTitle
        self.notifications = notifications ?? []
        self.rowView = rowView
    }

    // MARK: - Body
    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
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
                        loadMoreComments: { loadMoreComments() }
                    )
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
            .task {
                if comments.isEmpty {
                    await refreshComments()
                }
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
        }
    }

    // MARK: - Methods
    func performInitialLoad() async {
        isLoading = true
        initialLoadComplete = false
        currentPage = 0
        comments = []
        
        do {
            let newComments = try await commentFetcher(0, pageSize)
            let validComments = newComments.compactMap { $0 }
            
            await MainActor.run {
                comments = validComments
                hasMoreComments = newComments.count >= pageSize
                initialLoadComplete = true
            }
        } catch {
            errorMessage = error.localizedDescription
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
            isLoadingMore = true
            
            do {
                let newComments = try await commentFetcher(nextPage, pageSize)
                let validComments = newComments.compactMap { $0 }
                
                await MainActor.run {
                    if !validComments.isEmpty {
                        comments.append(contentsOf: validComments)
                    }
                    
                    // Use the same logic as TweetListView
                    if newComments.count < pageSize {
                        hasMoreComments = false
                    } else if validComments.isEmpty {
                        // All comments are nil, auto-increment and try again
                        isLoadingMore = false
                        loadMoreComments(page: nextPage + 1)
                        return
                    } else {
                        // We got some valid comments, continue normally
                        hasMoreComments = true
                    }
                    
                    currentPage = nextPage
                }
            } catch {
                await MainActor.run {
                    hasMoreComments = false
                }
            }
            
            await MainActor.run { isLoadingMore = false }
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
    let loadMoreComments: () -> Void
    
    var body: some View {
        LazyVStack(spacing: 0) {
            Color.clear.frame(height: 0)
            
            // Show loading state
            if isLoading {
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
                    Text(NSLocalizedString("No comments yet", comment: "No comments available message"))
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
                }
                
                // Sentinel view for infinite scroll
                if hasMoreComments {
                    ProgressView()
                        .frame(height: 40)
                        .onAppear {
                            if initialLoadComplete && !isLoadingMore {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    if initialLoadComplete && !isLoadingMore {
                                        loadMoreComments()
                                    }
                                }
                            }
                        }
                }
            }
        }
    }
}

