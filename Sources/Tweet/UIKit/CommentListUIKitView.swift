//
//  CommentListUIKitView.swift
//  Tweet
//
//  UIKit-backed comment list for TweetDetailView. Rows use the existing pure
//  UIKit TweetTableViewCell to avoid per-comment SwiftUI view graph churn.
//

import SwiftUI
import UIKit

@available(iOS 16.0, *)
struct CommentListUIKitView: View {
    @Binding var comments: [Tweet]
    let parentTweet: Tweet
    let commentFetcher: @Sendable (UInt, UInt) async throws -> [Tweet?]
    let notifications: [CommentListNotification]
    var hasUserScrolled: Binding<Bool> = .constant(true)
    /// Bound to the parent's pull-to-refresh flag. A refresh rewrites `comments`
    /// from the parent, which makes the table re-display its last row and fire
    /// `onReachBottom`; without this gate that starts a load-more against a page
    /// cursor the refresh has already invalidated.
    var isRefreshing: Binding<Bool> = .constant(false)
    let commentsVideoCoordinator: CommentsVideoPlaybackCoordinator
    let onAvatarTap: (User) -> Void
    let onShowLogin: () -> Void
    let onShowToast: (String, Bool) -> Void

    @EnvironmentObject private var hproseInstance: HproseInstance
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var hasMoreComments = true
    @State private var currentPage: UInt = 0
    @State private var initialLoadComplete = false
    @State private var showNoMoreComments = false
    @State private var loadedParentTweetId: String?
    @State private var tableHeight: CGFloat = 148

    private let pageSize: UInt = 10
    private let minimumLoadingDuration: TimeInterval = 0.5

    var body: some View {
        CommentListTableRepresentable(
            comments: comments,
            parentTweet: parentTweet,
            hproseInstance: hproseInstance,
            commentsVideoCoordinator: commentsVideoCoordinator,
            commentCount: parentTweet.commentCount ?? 0,
            isLoading: isLoading,
            isLoadingMore: isLoadingMore,
            initialLoadComplete: initialLoadComplete,
            showNoMoreComments: showNoMoreComments,
            tableHeight: $tableHeight,
            onReachBottom: { handleReachBottom() },
            onAvatarTap: onAvatarTap,
            onShowLogin: onShowLogin,
            onShowToast: onShowToast,
            onCommentTap: { comment in
                NotificationCenter.default.post(
                    name: NSNotification.Name("NavigateToCommentDetail"),
                    object: nil,
                    userInfo: ["comment": comment, "parentTweet": parentTweet]
                )
            }
        )
        .frame(height: max(1, tableHeight))
        .task(id: parentTweet.mid) {
            guard loadedParentTweetId != parentTweet.mid else { return }
            loadedParentTweetId = parentTweet.mid
            // TweetDetailView owns the ordered page-zero server refresh. This view
            // only reflects the bound cache/server results and handles pagination.
            initialLoadComplete = true
            if !comments.isEmpty {
                currentPage = UInt((comments.count - 1) / Int(pageSize))
                hasMoreComments = comments.count >= pageSize
            }
        }
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
        .onChange(of: hasUserScrolled.wrappedValue) { _, scrolled in
            if scrolled && !hasMoreComments && !comments.isEmpty {
                hasMoreComments = true
            }
        }
    }

    private func performInitialLoad() async {
        await MainActor.run {
            isLoading = true
            initialLoadComplete = false
            currentPage = 0
        }

        do {
            let newComments = try await commentFetcher(0, pageSize)
            let validComments = newComments.compactMap { $0 }

            await MainActor.run {
                if comments.isEmpty {
                    comments = validComments
                }
                hasMoreComments = newComments.count >= pageSize
                initialLoadComplete = true
            }
        } catch {
            await MainActor.run {
                initialLoadComplete = true
            }
        }
    }

    private func refreshComments() async {
        guard !isLoading else { return }
        // Capped: the fetch keeps running past the cap and fills the list when it
        // lands, but the spinner does not follow it.
        await runWithSpinnerCap { await performInitialLoad() }
        await MainActor.run {
            isLoading = false
        }
    }

    private func loadMoreComments(page: UInt? = nil) {
        guard hasMoreComments, !isLoadingMore, initialLoadComplete else { return }

        let nextPage = page ?? (currentPage + 1)
        let pageSize = self.pageSize

        Task {
            let startTime = Date()
            await MainActor.run {
                isLoadingMore = true
            }

            do {
                let newComments = try await commentFetcher(nextPage, pageSize)
                let validComments = newComments.compactMap { $0 }
                let remainingTime = max(0, minimumLoadingDuration - Date().timeIntervalSince(startTime))
                if remainingTime > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingTime * 1_000_000_000))
                }

                await MainActor.run {
                    if !validComments.isEmpty {
                        // Merge by mid. Offset pagination over a list other users
                        // are still posting to can re-serve a comment that page N
                        // already returned, so an unfiltered append duplicates rows
                        // (and duplicate mids break `ForEach(id: \.element.mid)` in
                        // the SwiftUI sibling). Matches Android's `loadComments` and
                        // TweetDetailView's own `refreshComments`.
                        let existingIds = Set(comments.map { $0.mid })
                        comments.append(contentsOf: validComments.filter { !existingIds.contains($0.mid) })
                    }

                    if newComments.count < pageSize {
                        hasMoreComments = false
                        if !comments.isEmpty {
                            showNoMoreMessage()
                        }
                    } else if validComments.isEmpty {
                        isLoadingMore = false
                        loadMoreComments(page: nextPage + 1)
                        return
                    } else {
                        hasMoreComments = true
                    }

                    currentPage = nextPage
                    isLoadingMore = false
                }
            } catch {
                let remainingTime = max(0, minimumLoadingDuration - Date().timeIntervalSince(startTime))
                if remainingTime > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingTime * 1_000_000_000))
                }

                await MainActor.run {
                    hasMoreComments = false
                    isLoadingMore = false
                    if !comments.isEmpty {
                        showNoMoreMessage()
                    }
                }
            }
        }
    }

    private func handleReachBottom() {
        guard initialLoadComplete, !isLoading, !isLoadingMore, !isRefreshing.wrappedValue,
              hasMoreComments else { return }
        loadMoreComments()
    }

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
}

@available(iOS 16.0, *)
private struct CommentListTableRepresentable: UIViewControllerRepresentable {
    let comments: [Tweet]
    let parentTweet: Tweet
    let hproseInstance: HproseInstance
    let commentsVideoCoordinator: CommentsVideoPlaybackCoordinator
    let commentCount: Int
    let isLoading: Bool
    let isLoadingMore: Bool
    let initialLoadComplete: Bool
    let showNoMoreComments: Bool
    @Binding var tableHeight: CGFloat
    let onReachBottom: () -> Void
    let onAvatarTap: (User) -> Void
    let onShowLogin: () -> Void
    let onShowToast: (String, Bool) -> Void
    let onCommentTap: (Tweet) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(tableHeight: $tableHeight)
    }

    @MainActor
    final class Coordinator {
        var tableHeight: Binding<CGFloat>
        private var pendingHeight: CGFloat?
        private var isHeightUpdateScheduled = false

        init(tableHeight: Binding<CGFloat>) {
            self.tableHeight = tableHeight
        }

        func scheduleTableHeightUpdate(_ height: CGFloat) {
            pendingHeight = height
            guard !isHeightUpdateScheduled else { return }

            isHeightUpdateScheduled = true
            Task { @MainActor [weak self] in
                self?.applyPendingHeightUpdate()
            }
        }

        private func applyPendingHeightUpdate() {
            guard let height = pendingHeight else {
                isHeightUpdateScheduled = false
                return
            }

            pendingHeight = nil
            isHeightUpdateScheduled = false
            tableHeight.wrappedValue = height
        }
    }

    func makeUIViewController(context: Context) -> CommentListTableViewController {
        let controller = CommentListTableViewController()
        let coordinator = context.coordinator
        controller.onHeightChange = { height in
            coordinator.scheduleTableHeightUpdate(height)
        }
        return controller
    }

    func updateUIViewController(_ controller: CommentListTableViewController, context: Context) {
        controller.update(
            comments: comments,
            parentTweet: parentTweet,
            hproseInstance: hproseInstance,
            commentsVideoCoordinator: commentsVideoCoordinator,
            commentCount: commentCount,
            isLoading: isLoading,
            isLoadingMore: isLoadingMore,
            initialLoadComplete: initialLoadComplete,
            showNoMoreComments: showNoMoreComments,
            onReachBottom: onReachBottom,
            onAvatarTap: onAvatarTap,
            onShowLogin: onShowLogin,
            onShowToast: onShowToast,
            onCommentTap: onCommentTap
        )
    }
}

@available(iOS 16.0, *)
@MainActor
private final class CommentListTableViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private enum FooterMode: Equatable {
        case none
        case loading
        case noMore
    }

    private enum Row {
        case status(CommentStatusCell.State)
        case comment(Tweet)
    }

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var comments: [Tweet] = []
    private weak var parentTweet: Tweet?
    private weak var hproseInstance: HproseInstance?
    private weak var commentsVideoCoordinator: CommentsVideoPlaybackCoordinator?
    private var commentCount = 0
    private var isLoading = false
    private var isLoadingMore = false
    private var initialLoadComplete = false
    private var showNoMoreComments = false
    private var hasSentReachBottomForCommentIds = Set<String>()
    private var lastReportedVideoCommentIds = Set<String>()
    private var contentSizeObservation: NSKeyValueObservation?
    private var visibilityDisplayLink: CADisplayLink?
    private var lastVisibilitySampleTime: CFTimeInterval = 0
    private var isVisibilityUpdateScheduled = false
    private var currentFooterMode: FooterMode = .none
    private var currentFooterWidth: CGFloat = 0

    var onHeightChange: ((CGFloat) -> Void)?
    private var onReachBottom: (() -> Void)?
    private var onAvatarTap: ((User) -> Void)?
    private var onShowLogin: (() -> Void)?
    private var onShowToast: ((String, Bool) -> Void)?
    private var onCommentTap: ((Tweet) -> Void)?

    private let leadingPadding: CGFloat = 12
    private let trailingPadding: CGFloat = 8

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = XTheme.background

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(TweetTableViewCell.self, forCellReuseIdentifier: TweetTableViewCell.reuseIdentifier)
        tableView.register(CommentStatusCell.self, forCellReuseIdentifier: CommentStatusCell.reuseIdentifier)
        tableView.separatorStyle = .none
        tableView.backgroundColor = XTheme.background
        tableView.isScrollEnabled = false
        tableView.showsVerticalScrollIndicator = false
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 220
        tableView.contentInsetAdjustmentBehavior = .never

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        contentSizeObservation = tableView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.reportContentHeight()
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startVisibilityDisplayLink()
        updateCommentVideoVisibility()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopVisibilityDisplayLink()
        clearReportedCommentVideos()
    }

    isolated deinit {
        contentSizeObservation?.invalidate()
        visibilityDisplayLink?.invalidate()
    }

    func update(
        comments: [Tweet],
        parentTweet: Tweet,
        hproseInstance: HproseInstance,
        commentsVideoCoordinator: CommentsVideoPlaybackCoordinator,
        commentCount: Int,
        isLoading: Bool,
        isLoadingMore: Bool,
        initialLoadComplete: Bool,
        showNoMoreComments: Bool,
        onReachBottom: @escaping () -> Void,
        onAvatarTap: @escaping (User) -> Void,
        onShowLogin: @escaping () -> Void,
        onShowToast: @escaping (String, Bool) -> Void,
        onCommentTap: @escaping (Tweet) -> Void
    ) {
        let oldIds = self.comments.map(\.mid)
        let newIds = comments.map(\.mid)

        self.comments = comments
        self.parentTweet = parentTweet
        self.hproseInstance = hproseInstance
        self.commentsVideoCoordinator = commentsVideoCoordinator
        self.commentCount = commentCount
        self.isLoading = isLoading
        self.isLoadingMore = isLoadingMore
        self.initialLoadComplete = initialLoadComplete
        self.showNoMoreComments = showNoMoreComments
        self.onReachBottom = onReachBottom
        self.onAvatarTap = onAvatarTap
        self.onShowLogin = onShowLogin
        self.onShowToast = onShowToast
        self.onCommentTap = onCommentTap

        tableView.backgroundColor = XTheme.background
        view.backgroundColor = XTheme.background
        updateFooter()

        let reloadedRows = oldIds != newIds || rowsNeedStatusReload
        if reloadedRows {
            tableView.reloadData()
        } else {
            for cell in tableView.visibleCells {
                if let tweetCell = cell as? TweetTableViewCell {
                    tweetCell.applyTheme()
                }
            }
        }

        reportContentHeight()
        if reloadedRows {
            scheduleCommentVideoVisibilityUpdate()
        } else {
            updateCommentVideoVisibility()
        }
    }

    private var rowsNeedStatusReload: Bool {
        comments.isEmpty
    }

    /// Display order, shared with Android `TweetDetailScreen` and Web `TweetDetail.vue`:
    /// comments in hand win; otherwise the parent's `commentCount` decides whether an
    /// empty list is worth waiting for. That counter is a convenience value and can
    /// disagree with reality, so it only governs whether to *wait* — the page-0 fetch
    /// runs regardless and fills the list if the count was wrong.
    private var rows: [Row] {
        if comments.isEmpty {
            if isLoading && commentCount > 0 {
                return [.status(.loading)]
            }
            return [.status(.empty)]
        }
        return comments.map { .comment($0) }
    }

    private func reportContentHeight() {
        tableView.layoutIfNeeded()
        let minimumHeight: CGFloat = comments.isEmpty && !initialLoadComplete ? 148 : 1
        let height = max(minimumHeight, tableView.contentSize.height)
        onHeightChange?(height)
    }

    private func updateFooter() {
        let mode: FooterMode
        if comments.isEmpty {
            mode = .none
        } else if isLoadingMore {
            mode = .loading
        } else if showNoMoreComments {
            mode = .noMore
        } else {
            mode = .none
        }

        let width = tableView.bounds.width
        guard mode != currentFooterMode || abs(width - currentFooterWidth) > 1 else { return }
        currentFooterMode = mode
        currentFooterWidth = width

        switch mode {
        case .none:
            tableView.tableFooterView = nil

        case .loading:
            let footer = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 64))
            footer.backgroundColor = .clear
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimating()
            footer.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            ])
            tableView.tableFooterView = footer

        case .noMore:
            let footer = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 72))
            footer.backgroundColor = .clear
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.text = NSLocalizedString("No more comments", comment: "Message shown when there are no more comments to load")
            label.textColor = XTheme.secondaryText
            label.font = .systemFont(ofSize: 15, weight: .medium)
            footer.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            ])
            tableView.tableFooterView = footer
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch rows[indexPath.row] {
        case .status(let state):
            let cell = tableView.dequeueReusableCell(withIdentifier: CommentStatusCell.reuseIdentifier, for: indexPath) as? CommentStatusCell
            cell?.configure(state: state)
            return cell ?? UITableViewCell()

        case .comment(let comment):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: TweetTableViewCell.reuseIdentifier,
                for: indexPath
            ) as? TweetTableViewCell else {
                return UITableViewCell()
            }

            if let hproseInstance, let parentTweet {
                cell.configure(
                    with: comment,
                    hproseInstance: hproseInstance,
                    isPinned: false,
                    isLastItem: indexPath.row == comments.count - 1,
                    parentViewController: self,
                    leadingPadding: leadingPadding,
                    trailingPadding: trailingPadding,
                    rowWidth: tableView.bounds.width,
                    videoCoordinator: nil,
                    onAvatarTap: onAvatarTap,
                    onTweetTap: onCommentTap,
                    onShowLogin: onShowLogin,
                    onShowToast: onShowToast,
                    allowDeleteAll: false,
                    commentParentTweet: parentTweet
                )
            }
            return cell
        }
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        heightForRow(at: indexPath) ?? 220
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        heightForRow(at: indexPath) ?? UITableView.automaticDimension
    }

    private func heightForRow(at indexPath: IndexPath) -> CGFloat? {
        guard indexPath.row < rows.count else { return nil }
        switch rows[indexPath.row] {
        case .status:
            return 148
        case .comment(let comment):
            return TweetTableViewController.calculateTweetHeight(
                for: comment,
                rowWidth: tableView.bounds.width > 0 ? tableView.bounds.width : UIScreen.main.bounds.width,
                cellHorizontalPadding: leadingPadding + trailingPadding
            )
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard case .comment(let comment) = rows[indexPath.row] else { return }
        if indexPath.row == comments.count - 1, hasSentReachBottomForCommentIds.insert(comment.mid).inserted {
            onReachBottom?()
        }
        // UIKit is still installing this row here; querying visibleCells from this
        // callback triggers UITableViewAlertForVisibleCellsAccessDuringUpdate.
        scheduleCommentVideoVisibilityUpdate()
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let tweetCell = cell as? TweetTableViewCell {
            tweetCell.tweetContentView.setMediaVisible(false)
        }
        guard indexPath.row < comments.count else { return }
        commentsVideoCoordinator?.reportVideoNotVisible(commentId: comments[indexPath.row].mid)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateFooter()
        reportContentHeight()
        scheduleCommentVideoVisibilityUpdate()
    }

    private func startVisibilityDisplayLink() {
        guard visibilityDisplayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleVisibilityDisplayLink))
        link.add(to: .main, forMode: .common)
        visibilityDisplayLink = link
    }

    private func stopVisibilityDisplayLink() {
        visibilityDisplayLink?.invalidate()
        visibilityDisplayLink = nil
    }

    @objc private func handleVisibilityDisplayLink(_ link: CADisplayLink) {
        guard link.timestamp - lastVisibilitySampleTime >= FeedPlaybackTuning.videoVisibilityThrottleInterval else { return }
        lastVisibilitySampleTime = link.timestamp
        updateCommentVideoVisibility()
    }

    private func scheduleCommentVideoVisibilityUpdate() {
        guard !isVisibilityUpdateScheduled else { return }
        isVisibilityUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isVisibilityUpdateScheduled = false
            self.updateCommentVideoVisibility()
        }
    }

    private func updateCommentVideoVisibility() {
        // A queued scan means UIKit is still completing a reload/layout callback.
        // Let the scheduled next-run-loop scan observe the stable visible-cell set.
        guard !isVisibilityUpdateScheduled else { return }
        guard view.window != nil, let parentTweet else { return }
        guard let window = view.window else { return }
        let visibleRect = window.bounds
        var reportedNow = Set<String>()

        for cell in tableView.visibleCells {
            guard let tweetCell = cell as? TweetTableViewCell,
                  let indexPath = tableView.indexPath(for: tweetCell),
                  indexPath.row < comments.count else { continue }

            let comment = comments[indexPath.row]
            let cellFrame = tweetCell.convert(tweetCell.bounds, to: nil)
            let visibleHeight = max(0, cellFrame.intersection(visibleRect).height)
            let ratio = cellFrame.height > 0 ? visibleHeight / cellFrame.height : 0
            let isVisible = ratio > 0

            tweetCell.tweetContentView.setMediaVisible(isVisible)
            _ = tweetCell.tweetContentView.mediaVisibilityIdentifiers(
                visibleRect: visibleRect,
                coordinateSpace: window
            )

            guard let video = firstVideoAttachment(in: comment) else { continue }
            if isVisible {
                reportedNow.insert(comment.mid)
                commentsVideoCoordinator?.reportVideoVisible(
                    commentId: comment.mid,
                    outerTweetId: parentTweet.mid,
                    videoMid: video.attachment.mid,
                    attachmentIndex: video.index,
                    visibilityRatio: ratio,
                    yPosition: cellFrame.minY
                )
            }
        }

        for staleId in lastReportedVideoCommentIds.subtracting(reportedNow) {
            commentsVideoCoordinator?.reportVideoNotVisible(commentId: staleId)
        }
        lastReportedVideoCommentIds = reportedNow
    }

    private func clearReportedCommentVideos() {
        for commentId in lastReportedVideoCommentIds {
            commentsVideoCoordinator?.reportVideoNotVisible(commentId: commentId)
        }
        lastReportedVideoCommentIds.removeAll()
    }

    private func firstVideoAttachment(in comment: Tweet) -> (index: Int, attachment: MimeiFileType)? {
        guard let attachments = comment.attachments else { return nil }
        for (index, attachment) in attachments.enumerated() where attachment.type == .video || attachment.type == .hls_video {
            return (index, attachment)
        }
        return nil
    }
}

@available(iOS 16.0, *)
private final class CommentStatusCell: UITableViewCell {
    enum State {
        case loading
        case empty
    }

    static let reuseIdentifier = "CommentStatusCell"

    private let stack = UIStackView()
    private let imageViewIcon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = XTheme.background
        contentView.backgroundColor = XTheme.background

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        contentView.addSubview(stack)

        imageViewIcon.tintColor = XTheme.secondaryText
        imageViewIcon.contentMode = .scaleAspectFit
        spinner.hidesWhenStopped = true
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = XTheme.secondaryText

        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(imageViewIcon)
        stack.addArrangedSubview(label)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 148),
            imageViewIcon.widthAnchor.constraint(equalToConstant: 44),
            imageViewIcon.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(state: State) {
        backgroundColor = XTheme.background
        contentView.backgroundColor = XTheme.background

        switch state {
        case .loading:
            spinner.startAnimating()
            imageViewIcon.isHidden = true
            label.text = NSLocalizedString("Loading comments...", comment: "Loading comments message")
        case .empty:
            spinner.stopAnimating()
            imageViewIcon.isHidden = false
            imageViewIcon.image = UIImage(systemName: "bubble.left")
            label.text = NSLocalizedString("No comment yet", comment: "No comment available message")
        }
    }
}
