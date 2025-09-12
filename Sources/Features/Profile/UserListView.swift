import SwiftUI

@available(iOS 16.0, *)
struct UserListView: View {
    // MARK: - Properties
    let title: String
    let userFetcher: @Sendable (Int, Int) async throws -> [String] // Returns user IDs
    let onFollowToggle: ((User) async -> Void)?
    let onUserTap: ((User) -> Void)?
    
    @State private var allUserIds: [String] = [] // Store all user IDs
    @State private var displayedUserIds: [String] = [] // Currently displayed user IDs
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var hasMoreUsers: Bool = true
    @State private var currentPage: Int = 0
    private let pageSize: Int = 4
    @State private var errorMessage: String? = nil
    @State private var refreshTask: Task<Void, Never>?
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var currentLoadIndex: Int = 0 // Track which user we're currently trying to load
    @State private var cancellationToken: UUID = UUID() // Token to cancel all UserRowView tasks
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hproseInstance: HproseInstance
    @Binding var navigationPath: NavigationPath
    
    // MARK: - Initialization
    init(
        title: String,
        userFetcher: @escaping @Sendable (Int, Int) async throws -> [String],
        navigationPath: Binding<NavigationPath>,
        onFollowToggle: ((User) async -> Void)? = nil,
        onUserTap: ((User) -> Void)? = nil
    ) {
        self.title = title
        self.userFetcher = userFetcher
        self._navigationPath = navigationPath
        self.onFollowToggle = onFollowToggle
        self.onUserTap = onUserTap
    }
    
    // MARK: - Body
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    Color.clear.frame(height: 0).id("top")
                    ForEach(displayedUserIds, id: \.self) { userId in
                        UserRowView(
                            userId: userId,
                            cancellationToken: cancellationToken,
                            onFollowToggle: onFollowToggle,
                            onTap: { selectedUser in
                                navigationPath.append(selectedUser)
                            },
                            onLoadFailed: { failedUserId in
                                // Remove failed user from both lists
                                displayedUserIds.removeAll { $0 == failedUserId }
                                allUserIds.removeAll { $0 == failedUserId }
                                
                                // Try to load the next user to fill the gap
                                Task {
                                    await loadNextUserToFillGap()
                                }
                            }
                        )
                        .id(userId)
                    }
                    if isLoading {
                        ProgressView()
                            .padding()
                    } else if hasMoreUsers && !isLoadingMore {
                        ProgressView()
                            .padding()
                            .onAppear {
                                loadMoreUsers()
                            }
                    } else if isLoadingMore {
                        ProgressView()
                            .padding()
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: 60)
                }
            }
            .refreshable {
                await refreshUsers()
            }
            .onAppear {
                if allUserIds.isEmpty {
                    Task {
                        await refreshUsers()
                    }
                }
            }
        }
        .navigationTitle(title)
        .onReceive(NotificationCenter.default.publisher(for: .popToRoot)) { _ in
            dismiss()
        }
        .onDisappear {
            // Cancel any ongoing tasks when view disappears
            refreshTask?.cancel()
            loadMoreTask?.cancel()
            // Generate new cancellation token to cancel all UserRowView tasks
            cancellationToken = UUID()
        }
    }
    
    // MARK: - Methods
    func refreshUsers() async {
        // Cancel any existing refresh task
        refreshTask?.cancel()
        
        // Create a new refresh task
        refreshTask = Task {
            isLoading = true
            currentPage = 0
            hasMoreUsers = true
            do {
                // Fetch all user IDs
                let allIds = try await userFetcher(0, Int.max)
                // Deduplicate user IDs
                let uniqueUserIds = Array(Set(allIds))
                
                await MainActor.run {
                    // Check if task was cancelled before updating UI
                    guard !Task.isCancelled else { return }
                    allUserIds = uniqueUserIds
                    // Start with empty displayed list for sequential loading
                    displayedUserIds = []
                    currentLoadIndex = 0
                    hasMoreUsers = uniqueUserIds.count > 0
                    isLoading = false
                }
                
                // Start loading first batch
                await loadBatch(Array(uniqueUserIds.prefix(pageSize)))
            } catch is CancellationError {
                print("DEBUG: [UserListView] Refresh cancelled")
            } catch {
                print("Error refreshing users: \(error)")
                await MainActor.run {
                    // Check if task was cancelled before updating UI
                    guard !Task.isCancelled else { return }
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    func loadMoreUsers() {
        guard hasMoreUsers, !isLoadingMore else { return }
        
        // Cancel any existing load more task
        loadMoreTask?.cancel()
        
        // Create a new load more task
        loadMoreTask = Task {
            isLoadingMore = true
            
            // Load next batch
            let startIndex = currentLoadIndex
            let endIndex = min(startIndex + pageSize, allUserIds.count)
            
            guard startIndex < allUserIds.count else {
                await MainActor.run {
                    hasMoreUsers = false
                    isLoadingMore = false
                }
                return
            }
            
            let nextBatchIds = Array(allUserIds[startIndex..<endIndex])
            await loadBatch(nextBatchIds)
            
            await MainActor.run {
                // Check if task was cancelled before updating UI
                guard !Task.isCancelled else { return }
                // Check if we have more users to load
                hasMoreUsers = currentLoadIndex < allUserIds.count
                isLoadingMore = false
            }
        }
    }
    
    // MARK: - Batch Loading
    private func loadBatch(_ userIds: [String]) async {
        // Add all users to displayed list at once for faster loading
        await MainActor.run {
            displayedUserIds.append(contentsOf: userIds)
            currentLoadIndex += userIds.count
        }
        
        // Add a small delay for smooth visual feedback
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
    }
    
    // MARK: - Gap Filling
    private func loadNextUserToFillGap() async {
        // Check if we have more users to load
        guard currentLoadIndex < allUserIds.count else { return }
        
        let nextUserId = allUserIds[currentLoadIndex]
        currentLoadIndex += 1
        
        // Add user to displayed list
        await MainActor.run {
            displayedUserIds.append(nextUserId)
        }
        
        // Add a small delay for smooth visual feedback
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
    }
}
