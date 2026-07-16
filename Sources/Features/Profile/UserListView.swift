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
    let userFetcher: @MainActor @Sendable (Int, Int) async throws -> [String]
    let authoritativeUserFetcher: @MainActor @Sendable () async throws -> [String]
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
    @State private var nextDisplayIndex: Int = 0
    @State private var cancellationToken: UUID = UUID()

    /// Match Android's ID page size, but reveal only the visible row count.
    private let pageSize: Int = Constants.USER_BATCH_SIZE
    private let visibleBatchSize: Int = Constants.USER_VISIBLE_BATCH_SIZE

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hproseInstance: HproseInstance
    @Binding var navigationPath: NavigationPath

    // MARK: - Initialization
    init(
        title: String,
        userId: String,
        userFetcher: @escaping @MainActor @Sendable (Int, Int) async throws -> [String],
        authoritativeUserFetcher: @escaping @MainActor @Sendable () async throws -> [String],
        navigationPath: Binding<NavigationPath>,
        onFollowToggle: ((User) async -> Void)? = nil,
        onShowLogin: (() -> Void)? = nil,
        onUserTap: ((User) -> Void)? = nil
    ) {
        self.title = title
        self.userId = userId
        self.userFetcher = userFetcher
        self.authoritativeUserFetcher = authoritativeUserFetcher
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
                            nextDisplayIndex = min(nextDisplayIndex, displayedUserIds.count)
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
        refreshTask = Task {
            await MainActor.run {
                isLoading = displayedUserIds.isEmpty
                errorMessage = nil
            }

            // Publish cached relationship IDs immediately. Each row independently
            // renders its cached user, or a placeholder while that user loads.
            do {
                let cachedPageIds = try await userFetcher(0, pageSize)
                let filteredCachedIds = await filteredUniqueUserIds(from: cachedPageIds)
                guard !Task.isCancelled else { return }

                if !filteredCachedIds.isEmpty {
                    await MainActor.run {
                        publishUserIds(
                            filteredCachedIds,
                            minimumVisibleCount: displayedUserIds.count,
                            hasMoreServerPages: cachedPageIds.count >= pageSize
                        )
                        isLoading = false
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                userListLogger.error("Failed to read cached user list: \(error.localizedDescription, privacy: .public)")
            }

            do {
                let authoritativeIds = try await authoritativeUserFetcher()
                let filteredAuthoritativeIds = await filteredUniqueUserIds(from: authoritativeIds)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    publishUserIds(
                        filteredAuthoritativeIds,
                        minimumVisibleCount: displayedUserIds.count,
                        hasMoreServerPages: false
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
        minimumVisibleCount: Int,
        hasMoreServerPages: Bool
    ) {
        allUserIds = userIds
        let visibleCount = min(max(minimumVisibleCount, visibleBatchSize), userIds.count)
        displayedUserIds = Array(userIds.prefix(visibleCount))
        nextDisplayIndex = displayedUserIds.count
        nextPageNumber = 1
        self.hasMoreServerPages = hasMoreServerPages
        hasMoreUsers = nextDisplayIndex < allUserIds.count || hasMoreServerPages
    }

    func loadMoreUsers() {
        guard hasMoreUsers, !isLoadingMore, !isLoading else { return }

        loadMoreTask?.cancel()
        loadMoreTask = Task {
            await MainActor.run { isLoadingMore = true }

            let didRevealCachedUsers = revealNextVisibleBatch()
            if didRevealCachedUsers {
                await MainActor.run { isLoadingMore = false }
                return
            }

            let pageToLoad = nextPageNumber
            let existingUserIds = Set(allUserIds)

            do {
                let pageIds = try await userFetcher(pageToLoad, pageSize)
                let filteredUserIds = await filteredUniqueUserIds(from: pageIds, excluding: existingUserIds)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    allUserIds.append(contentsOf: filteredUserIds)
                    nextPageNumber = pageToLoad + 1
                    let revealEndIndex = min(nextDisplayIndex + visibleBatchSize, allUserIds.count)
                    if nextDisplayIndex < revealEndIndex {
                        displayedUserIds.append(contentsOf: allUserIds[nextDisplayIndex..<revealEndIndex])
                        nextDisplayIndex = revealEndIndex
                    }
                    hasMoreServerPages = pageIds.count >= pageSize
                    hasMoreUsers = nextDisplayIndex < allUserIds.count || hasMoreServerPages
                    isLoadingMore = false
                }
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

    @MainActor
    private func revealNextVisibleBatch() -> Bool {
        guard nextDisplayIndex < allUserIds.count else { return false }
        let endIndex = min(nextDisplayIndex + visibleBatchSize, allUserIds.count)
        displayedUserIds.append(contentsOf: allUserIds[nextDisplayIndex..<endIndex])
        nextDisplayIndex = endIndex
        hasMoreUsers = nextDisplayIndex < allUserIds.count || hasMoreServerPages
        return true
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

    private func loadNextUserToFillGap() async {
        guard hasMoreUsers, !isLoadingMore, !isLoading else { return }
        loadMoreUsers()
    }
}
