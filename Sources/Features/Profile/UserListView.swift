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
    @State private var sequentialLoadingTask: Task<Void, Never>?
    @State private var currentLoadIndex: Int = 0 // Track which user we're currently trying to load
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
                            onFollowToggle: onFollowToggle,
                            onTap: { selectedUser in
                                navigationPath.append(selectedUser)
                            },
                            onLoadFailed: { failedUserId in
                                // Remove failed user from both lists
                                displayedUserIds.removeAll { $0 == failedUserId }
                                allUserIds.removeAll { $0 == failedUserId }
                                
                                // Try to load the next user
                                Task {
                                    await loadNextUser()
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
            sequentialLoadingTask?.cancel()
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
                
                // Start loading users one by one
                await loadNextUser()
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
            
            let startIndex = displayedUserIds.count
            let endIndex = min(startIndex + pageSize, allUserIds.count)
            
            // If we've reached the end of the list, update state and return
            if startIndex >= allUserIds.count {
                await MainActor.run {
                    // Check if task was cancelled before updating UI
                    guard !Task.isCancelled else { return }
                    hasMoreUsers = false
                    isLoadingMore = false
                }
                return
            }
            
            let nextBatchIds = Array(allUserIds[startIndex..<endIndex])
            // Defensive: If no more IDs to load, stop
            if nextBatchIds.isEmpty {
                await MainActor.run {
                    // Check if task was cancelled before updating UI
                    guard !Task.isCancelled else { return }
                    hasMoreUsers = false
                    isLoadingMore = false
                }
                return
            }
            
            // Load next batch sequentially
            await loadUsersSequentially(nextBatchIds)
            
            await MainActor.run {
                // Check if task was cancelled before updating UI
                guard !Task.isCancelled else { return }
                // If we loaded fewer users than requested, or none, stop loading more
                if endIndex >= allUserIds.count {
                    hasMoreUsers = false
                } else {
                    hasMoreUsers = true
                }
                isLoadingMore = false
            }
        }
    }
    
    // MARK: - Sequential Loading
    private func loadUsersSequentially(_ userIds: [String]) async {
        // Cancel any existing sequential loading task
        sequentialLoadingTask?.cancel()
        
        // Create a new sequential loading task
        sequentialLoadingTask = Task {
            for (index, userId) in userIds.enumerated() {
                // Check if task was cancelled
                guard !Task.isCancelled else { return }
                
                // Add user to displayed list
                await MainActor.run {
                    displayedUserIds.append(userId)
                }
                
                // Add delay between users (except for the last one)
                if index < userIds.count - 1 {
                    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms delay
                }
            }
        }
    }
    
    // MARK: - Single User Loading
    private func loadNextUser() async {
        // Check if we have more users to load
        guard currentLoadIndex < allUserIds.count else { return }
        
        let nextUserId = allUserIds[currentLoadIndex]
        currentLoadIndex += 1
        
        // Add user to displayed list
        await MainActor.run {
            displayedUserIds.append(nextUserId)
        }
        
        // Add a small delay before potentially loading the next user
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms delay
    }
}
