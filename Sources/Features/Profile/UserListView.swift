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
    private let pageSize: Int = 10
    @State private var errorMessage: String? = nil
    @State private var refreshTask: Task<Void, Never>?
    @State private var loadMoreTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @State private var hproseInstance = HproseInstanceState.shared
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
                    // Load initial page
                    let initialUserIds = Array(uniqueUserIds.prefix(pageSize))
                    displayedUserIds = initialUserIds
                    hasMoreUsers = uniqueUserIds.count > pageSize
                    isLoading = false
                }
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
            
            await MainActor.run {
                // Check if task was cancelled before updating UI
                guard !Task.isCancelled else { return }
                displayedUserIds.append(contentsOf: nextBatchIds)
                // If we loaded fewer users than requested, or none, stop loading more
                if nextBatchIds.isEmpty || endIndex >= allUserIds.count {
                    hasMoreUsers = false
                } else {
                    hasMoreUsers = true
                }
                isLoadingMore = false
            }
        }
    }
}
