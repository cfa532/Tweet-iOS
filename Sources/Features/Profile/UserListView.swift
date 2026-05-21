import SwiftUI

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
    let userFetcher: @Sendable (Int, Int) async throws -> [String]
    let onFollowToggle: ((User) async -> Void)?
    let onUserTap: ((User) -> Void)?

    @State private var allUserIds: [String] = []
    @State private var displayedUserIds: [String] = []
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    /// False until IDs are loaded — avoids a phantom bottom loader firing during push.
    @State private var hasMoreUsers: Bool = false
    @State private var errorMessage: String? = nil
    @State private var refreshTask: Task<Void, Never>?
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var currentLoadIndex: Int = 0
    @State private var cancellationToken: UUID = UUID()

    /// Enough rows to cover an iPhone screen (~12 rows).
    private let initialBatchSize: Int = 12
    /// Smaller batches after the first screen for pagination.
    private let pageSize: Int = 10

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hproseInstance: HproseInstance
    @Binding var navigationPath: NavigationPath

    // MARK: - Initialization
    init(
        title: String,
        userId: String,
        userFetcher: @escaping @Sendable (Int, Int) async throws -> [String],
        navigationPath: Binding<NavigationPath>,
        onFollowToggle: ((User) async -> Void)? = nil,
        onUserTap: ((User) -> Void)? = nil
    ) {
        self.title = title
        self.userId = userId
        self.userFetcher = userFetcher
        self._navigationPath = navigationPath
        self.onFollowToggle = onFollowToggle
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
                } else if hasMoreUsers, !allUserIds.isEmpty {
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
                isLoading = true
                errorMessage = nil
                hasMoreUsers = false
            }
            do {
                let allIds = try await userFetcher(0, Int.max)
                let uniqueUserIds = Array(Set(allIds))
                let sociallyBlockedUserIds = await MainActor.run {
                    Set(hproseInstance.appUser.userBlackList ?? [])
                }
                let filteredUserIds = uniqueUserIds.filter { userId in
                    !sociallyBlockedUserIds.contains(userId)
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    allUserIds = filteredUserIds
                    displayedUserIds = []
                    currentLoadIndex = 0
                }
                await loadBatch(count: initialBatchSize)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    hasMoreUsers = currentLoadIndex < allUserIds.count
                    isLoading = false
                }
            } catch is CancellationError {
                print("DEBUG: [UserListView] Refresh cancelled")
            } catch {
                print("Error refreshing users: \(error)")
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isLoading = false
                    errorMessage = ErrorMessageHelper.userFriendlyMessage(from: error)
                }
            }
        }
        await refreshTask?.value
    }

    func loadMoreUsers() {
        guard hasMoreUsers, !isLoadingMore, !isLoading else { return }

        loadMoreTask?.cancel()
        loadMoreTask = Task {
            await MainActor.run { isLoadingMore = true }

            let startIndex = currentLoadIndex
            guard startIndex < allUserIds.count else {
                await MainActor.run {
                    hasMoreUsers = false
                    isLoadingMore = false
                }
                return
            }

            let endIndex = min(startIndex + pageSize, allUserIds.count)
            let nextBatchIds = Array(allUserIds[startIndex..<endIndex])
            await loadBatch(ids: nextBatchIds)

            guard !Task.isCancelled else { return }
            await MainActor.run {
                hasMoreUsers = currentLoadIndex < allUserIds.count
                isLoadingMore = false
            }
        }
    }

    /// Append `count` IDs from `allUserIds` starting at `currentLoadIndex`.
    private func loadBatch(count: Int) async {
        let start = currentLoadIndex
        let end = min(start + count, allUserIds.count)
        guard start < end else { return }
        let batch = Array(allUserIds[start..<end])
        await loadBatch(ids: batch)
    }

    private func loadBatch(ids: [String]) async {
        guard !ids.isEmpty else { return }
        await MainActor.run {
            displayedUserIds.append(contentsOf: ids)
            currentLoadIndex += ids.count
        }
    }

    private func loadNextUserToFillGap() async {
        guard currentLoadIndex < allUserIds.count else { return }
        let nextUserId = allUserIds[currentLoadIndex]
        await MainActor.run {
            displayedUserIds.append(nextUserId)
            currentLoadIndex += 1
        }
    }
}
