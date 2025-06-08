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
    let action: (Tweet) -> Void
}

@available(iOS 16.0, *)
struct CommentListView<RowView: View>: View {
    // MARK: - Properties
    let title: String
    let commentFetcher: @Sendable (UInt, UInt) async throws -> [Tweet?]
    let showTitle: Bool
    let rowView: (Tweet) -> RowView
    let notifications: [CommentListNotification]
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
                    .animation(.easeInOut, value: showToast)
                }
            }
            .refreshable {
                await refreshComments()
            }
            .task {
                if comments.isEmpty {
                    await refreshComments()
                }
            }
            // Listen to all notifications
            .onReceive(NotificationCenter.default.publisher(for: .newCommentAdded)) { notif in
                if let comment = notif.userInfo?["comment"] as? Tweet,
                   let notification = notifications.first(where: { $0.name == .newCommentAdded }),
                   notification.shouldAccept(comment) {
                    notification.action(comment)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .commentDeleted)) { notif in
                if let comment = notif.userInfo?["comment"] as? Tweet,
                   let notification = notifications.first(where: { $0.name == .commentDeleted }),
                   notification.shouldAccept(comment) {
                    notification.action(comment)
                }
            }
        }
    }

    // MARK: - Methods
    func performInitialLoad() async {
        print("[CommentListView] Starting initial load")
        initialLoadComplete = false
        currentPage = 0
        comments = []
        
        do {
            print("[CommentListView] Loading page 0")
            let newComments = try await commentFetcher(0, pageSize)
            await MainActor.run {
                // Filter out nil comments and add valid ones
                comments = newComments.compactMap { $0 }
                // Set hasMoreComments based on whether we got a full page (including nils)
                hasMoreComments = newComments.count >= pageSize
                print("[CommentListView] Loaded \(comments.count) valid comments out of \(newComments.count) total, hasMoreComments: \(hasMoreComments)")
            }
        } catch {
            print("[CommentListView] Error during initial load: \(error)")
            errorMessage = error.localizedDescription
        }
        
        initialLoadComplete = true
        print("[CommentListView] Initial load complete - total valid comments: \(comments.count), hasMoreComments: \(hasMoreComments)")
    }

    func refreshComments() async {
        guard !isLoading else { return }
        isLoading = true
        initialLoadComplete = false
        await performInitialLoad()
        isLoading = false
    }

    func loadMoreComments(page: UInt? = nil) {
        print("[CommentListView] loadMoreComments called - hasMoreComments: \(hasMoreComments), isLoadingMore: \(isLoadingMore), initialLoadComplete: \(initialLoadComplete), currentPage: \(currentPage)")
        guard hasMoreComments, !isLoadingMore, initialLoadComplete else { 
            print("[CommentListView] loadMoreComments guard failed - hasMoreComments: \(hasMoreComments), isLoadingMore: \(isLoadingMore), initialLoadComplete: \(initialLoadComplete)")
            return 
        }
        
        let nextPage = page ?? (currentPage + 1)
        let pageSize = self.pageSize
        
        Task {
            if initialLoadComplete { isLoadingMore = true }
            
            do {
                print("[CommentListView] Starting to load more comments - page: \(nextPage)")
                let newComments = try await commentFetcher(nextPage, pageSize)
                await MainActor.run {
                    print("[CommentListView] Got \(newComments.count) total comments")
                    // Filter out nil comments and add valid ones
                    let validComments = newComments.compactMap { $0 }
                    if !validComments.isEmpty {
                        comments.append(contentsOf: validComments)
                    }
                    // Set hasMoreComments based on whether we got a full page (including nils)
                    hasMoreComments = newComments.count >= pageSize
                    currentPage = nextPage
                    print("[CommentListView] Added \(validComments.count) valid comments, updated currentPage to \(currentPage), hasMoreComments: \(hasMoreComments)")
                }
            } catch {
                print("[CommentListView] Error loading more comments: \(error)")
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
            ForEach(comments, id: \.mid) { comment in
                rowView(comment)
            }
            // Sentinel view for infinite scroll
            if hasMoreComments {
                ProgressView()
                    .frame(height: 40)
                    .onAppear {
                        print("[CommentListContentView] ProgressView appeared - initialLoadComplete: \(initialLoadComplete), isLoadingMore: \(isLoadingMore)")
                        if initialLoadComplete && !isLoadingMore {
                            print("[CommentListContentView] Scheduling loadMoreComments")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                if initialLoadComplete && !isLoadingMore {
                                    print("[CommentListContentView] Calling loadMoreComments")
                                    loadMoreComments()
                                }
                            }
                        }
                    }
            }
        }
    }
}

