import SwiftUI
import OSLog

private let userListLogger = Logger(subsystem: "com.zz", category: "UserListView")

// Navigation destination identifier (like Android's NavTweet.Following/Following)
struct UserListDestination: Hashable {
    let userId: String
    let listType: UserListType
}

@available(iOS 16.0, *)
struct UserListView: View {
    // MARK: - Properties
    let title: String
    let userId: String // Profile owner whose baseUrl we watch for refresh
    let cachedUserFetcher: @MainActor @Sendable () async -> [String]
    let userPageFetcher: @MainActor @Sendable (Int) async throws -> RelationshipUserPage
    let onFollowToggle: ((User) async -> Void)?
    let onShowLogin: (() -> Void)?
    let onUserTap: ((User) -> Void)?

    @State private var allUserIds: [String] = []
    @State private var displayedUserIds: [String] = []
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    /// False until IDs are loaded — avoids a phantom bottom loader firing during push.
    @State private var hasMoreUsers: Bool = false
    @State private var hasMoreServerPages: Bool = false
    @State private var errorMessage: String? = nil
    @State private var refreshTask: Task<Void, Never>?
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var nextPageNumber: Int = 0
    @State private var cancellationToken: UUID = UUID()

    /// Enough rows to cover a full iPhone screen without geometry-driven auto-fill,
    /// which previously caused concurrent pagination races during navigation.
    private let minimumFillRowCount: Int = 12

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hproseInstance: HproseInstance
    @Binding var navigationPath: NavigationPath

    // MARK: - Initialization
    init(
        title: String,
        userId: String,
        cachedUserFetcher: @escaping @MainActor @Sendable () async -> [String],
        userPageFetcher: @escaping @MainActor @Sendable (Int) async throws -> RelationshipUserPage,
        navigationPath: Binding<NavigationPath>,
        onFollowToggle: ((User) async -> Void)? = nil,
        onShowLogin: (() -> Void)? = nil,
        onUserTap: ((User) -> Void)? = nil
    ) {
        self.title = title
        self.userId = userId
        self.cachedUserFetcher = cachedUserFetcher
        self.userPageFetcher = userPageFetcher
        self._navigationPath = navigationPath
        self.onFollowToggle = onFollowToggle
        self.onShowLogin = onShowLogin
        self.onUserTap = onUserTap
    }

    // MARK: - Body
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if let errorMessage = errorMessage, displayedUserIds.isEmpty, !isLoading {
                    VStack(spacing: 12) {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button(NSLocalizedString("Retry", comment: "Retry button")) {
                            Task { await refreshUsers() }
                        }
                        .font(.subheadline)
                    }
                    .padding()
                }

                ForEach(displayedUserIds, id: \.self) { rowUserId in
                    UserRowView(
                        userId: rowUserId,
                        cancellationToken: cancellationToken,
                        onFollowToggle: onFollowToggle,
                        onShowLogin: onShowLogin,
                        onTap: { selectedUser in
                            navigationPath.append(selectedUser)
                        },
                        onLoadFailed: { failedUserId in
                            displayedUserIds.removeAll { $0 == failedUserId }
                            allUserIds.removeAll { $0 == failedUserId }
                            Task { await loadNextUserToFillGap() }
                        }
                    )
                    .id(rowUserId)
                }

                if isLoading {
                    ProgressView()
                        .padding()
                } else if hasMoreUsers {
                    ProgressView()
                        .padding()
                        .id(nextPageNumber)
                        .onAppear {
                            loadMoreUsers()
                        }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 60)
            }
        }
        .refreshable {
            await refreshUsers()
        }
        /// Run initial fetch after the navigation transition so the push animation stays fluid.
        /// `id: title` distinguishes follower vs following for the same `userId`.
        .task(id: title) {
            guard allUserIds.isEmpty, displayedUserIds.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            await refreshUsers()
        }
        .navigationTitle(title)
        .onReceive(NotificationCenter.default.publisher(for: .popToRoot)) { _ in
            dismiss()
        }
        .onReceive(NotificationCenter.default.publisher(for: .userDidUpdate)) { notification in
            guard let updatedUserId = notification.userInfo?["userId"] as? String,
                  updatedUserId == userId,
                  !isLoading,
                  !isLoadingMore,
                  errorMessage != nil || displayedUserIds.isEmpty else { return }
            errorMessage = nil
            Task { await refreshUsers() }
        }
        .onDisappear {
            refreshTask?.cancel()
            loadMoreTask?.cancel()
            cancellationToken = UUID()
        }
    }

    // MARK: - Methods

    func refreshUsers() async {
        refreshTask?.cancel()
        loadMoreTask?.cancel()
        loadMoreTask = nil
        refreshTask = Task {
            await MainActor.run {
                isLoading = displayedUserIds.isEmpty
                isLoadingMore = false
                errorMessage = nil
            }

            // Keep already-renderable cached users as a fast/offline fallback. A
            // relationship ID without cached identity data must not create a row:
            // the backend page will supply the complete User object shortly.
            let cachedUserIds = await cachedUserFetcher()
            let renderableCachedIds = await renderableCachedUserIds(from: cachedUserIds)
            let filteredCachedIds = await filteredUniqueUserIds(from: renderableCachedIds)
            guard !Task.isCancelled else { return }

            if !filteredCachedIds.isEmpty {
                await MainActor.run {
                    publishUserIds(
                        filteredCachedIds,
                        nextPageNumber: 0,
                        hasMoreServerPages: false
                    )
                    isLoading = false
                }
            }

            do {
                var pageNumber = 0
                var fetchedUserIds: [String] = []
                var hasMorePages = true

                while fetchedUserIds.count < minimumFillRowCount && hasMorePages {
                    let page = try await userPageFetcher(pageNumber)
                    let filteredPageIds = await filteredUniqueUserIds(
                        from: page.userIds,
                        excluding: Set(fetchedUserIds)
                    )
                    fetchedUserIds.append(contentsOf: filteredPageIds)
                    pageNumber += 1
                    hasMorePages = page.hasMore
                }
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    publishUserIds(
                        fetchedUserIds,
                        nextPageNumber: pageNumber,
                        hasMoreServerPages: hasMorePages
                    )
                    isLoading = false
                    errorMessage = nil
                }
            } catch is CancellationError {
                return
            } catch {
                userListLogger.error("Failed to refresh user list: \(error.localizedDescription, privacy: .public)")
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isLoading = false
                    if displayedUserIds.isEmpty {
                        errorMessage = ErrorMessageHelper.userFriendlyMessage(from: error)
                    }
                }
            }
        }
        await refreshTask?.value
    }

    @MainActor
    private func publishUserIds(
        _ userIds: [String],
        nextPageNumber: Int,
        hasMoreServerPages: Bool
    ) {
        allUserIds = userIds
        displayedUserIds = userIds
        self.nextPageNumber = nextPageNumber
        self.hasMoreServerPages = hasMoreServerPages
        hasMoreUsers = hasMoreServerPages
    }

    func loadMoreUsers() {
        guard hasMoreUsers, !isLoadingMore, !isLoading else { return }

        loadMoreTask?.cancel()
        loadMoreTask = Task {
            await MainActor.run { isLoadingMore = true }

            do {
                var pageNumber = nextPageNumber
                var fetchedUserIds: [String] = []
                var hasMorePages = hasMoreServerPages

                // A backend page can contain only blocked/invalid users. Continue
                // until at least one visible row is found or the server is exhausted.
                repeat {
                    let page = try await userPageFetcher(pageNumber)
                    let filteredPageIds = await filteredUniqueUserIds(
                        from: page.userIds,
                        excluding: Set(allUserIds + fetchedUserIds)
                    )
                    fetchedUserIds.append(contentsOf: filteredPageIds)
                    pageNumber += 1
                    hasMorePages = page.hasMore
                } while fetchedUserIds.isEmpty && hasMorePages
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    allUserIds.append(contentsOf: fetchedUserIds)
                    displayedUserIds.append(contentsOf: fetchedUserIds)
                    nextPageNumber = pageNumber
                    hasMoreServerPages = hasMorePages
                    hasMoreUsers = hasMorePages
                    isLoadingMore = false
                }
            } catch is CancellationError {
                await MainActor.run { isLoadingMore = false }
            } catch {
                userListLogger.error("Failed to load more users: \(error.localizedDescription, privacy: .public)")
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    hasMoreUsers = false
                    isLoadingMore = false
                }
            }
        }
    }

    private func filteredUniqueUserIds(from userIds: [String], excluding existingUserIds: Set<String> = []) async -> [String] {
        let sociallyBlockedUserIds = await MainActor.run {
            Set(hproseInstance.appUser.userBlackList ?? [])
        }
        var seenUserIds = existingUserIds

        return userIds.compactMap { userId in
            guard !userId.isEmpty,
                  userId != Constants.GUEST_ID,
                  !sociallyBlockedUserIds.contains(userId),
                  !BlackList.shared.isBlacklisted(userId),
                  !seenUserIds.contains(userId) else { return nil }
            seenUserIds.insert(userId)
            return userId
        }
    }

    private func renderableCachedUserIds(from userIds: [String]) async -> [String] {
        var renderableUserIds: [String] = []
        renderableUserIds.reserveCapacity(min(userIds.count, minimumFillRowCount))

        // Only the initially visible batch can render before page zero arrives.
        // Limiting cache reads also prevents a large relationship list from delaying
        // the authoritative backend request.
        for userId in userIds.prefix(minimumFillRowCount) {
            guard !Task.isCancelled else { break }
            let cachedUser = await TweetCacheManager.shared.fetchUser(mid: userId)
            let hasRenderableIdentity = await MainActor.run { cachedUser.hasValidUsername }
            if hasRenderableIdentity {
                renderableUserIds.append(userId)
            }
        }

        return renderableUserIds
    }

    private func loadNextUserToFillGap() async {
        guard hasMoreUsers, !isLoadingMore, !isLoading else { return }
        loadMoreUsers()
    }
}
