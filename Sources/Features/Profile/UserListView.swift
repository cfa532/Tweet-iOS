import SwiftUI

// Navigation destination identifier (like Android's NavTweet.Following/Following)
struct UserListDestination: Hashable {
    let userId: String
    let listType: UserListType
}

// Preference key to track content height
private struct ContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

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
    private let pageSize: Int = 5  // Reduced for better server load distribution
    @State private var errorMessage: String? = nil
    @State private var contentHeight: CGFloat = 0
    @State private var screenHeight: CGFloat = 0
    @State private var needsMoreContent: Bool = true
    @State private var refreshTask: Task<Void, Never>?
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var currentLoadIndex: Int = 0 // Track which user we're currently trying to load
    @State private var cancellationToken: UUID = UUID() // Token to cancel all UserRowView tasks
    @State private var isAutoFilling: Bool = false // Prevent multiple auto-fill operations
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
        GeometryReader { geometry in
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
                        
                        // Hidden view to measure content height
                        Color.clear
                            .frame(height: 1)
                            .background(
                                GeometryReader { contentGeometry in
                                    Color.clear.preference(
                                        key: ContentHeightPreferenceKey.self,
                                        value: contentGeometry.frame(in: .named("scroll")).maxY
                                    )
                                }
                            )
                    }
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: 60)
                    }
                }
                .coordinateSpace(name: "scroll")
                .refreshable {
                    await refreshUsers()
                }
                .onAppear {
                    screenHeight = geometry.size.height
                    if allUserIds.isEmpty {
                        Task {
                            await refreshUsers()
                        }
                    }
                }
                .onPreferenceChange(ContentHeightPreferenceKey.self) { newHeight in
                    contentHeight = newHeight
                    // Auto-load more if screen isn't filled and we have more users
                    if !isLoading && !isLoadingMore && !isAutoFilling && hasMoreUsers {
                        let needsFilling = contentHeight < screenHeight * 1.2 // 20% buffer
                        if needsFilling && needsMoreContent {
                            Task {
                                await loadMoreToFillScreen()
                            }
                        }
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
                
                // Filter out blacklisted user IDs
                let filteredUserIds = uniqueUserIds.filter { userId in
                    !BlackList.shared.isBlacklisted(userId)
                }
                
                await MainActor.run {
                    // Check if task was cancelled before updating UI
                    guard !Task.isCancelled else { return }
                    allUserIds = filteredUserIds
                    // Start with empty displayed list for sequential loading
                    displayedUserIds = []
                    currentLoadIndex = 0
                    hasMoreUsers = filteredUserIds.count > 0
                    isLoading = false
                }
                
                // Start loading first batch
                await loadBatch(Array(filteredUserIds.prefix(pageSize)))
            } catch is CancellationError {
                print("DEBUG: [UserListView] Refresh cancelled")
            } catch {
                print("Error refreshing users: \(error)")
                await MainActor.run {
                    // Check if task was cancelled before updating UI
                    guard !Task.isCancelled else { return }
                    isLoading = false
                    errorMessage = ErrorMessageHelper.userFriendlyMessage(from: error)
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
        // Add all users to displayed list at once
        await MainActor.run {
            displayedUserIds.append(contentsOf: userIds)
            currentLoadIndex += userIds.count
        }
        
        // Wait for batch to render and start loading before continuing
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms delay
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
    
    // MARK: - Screen Filling
    /// Automatically loads more users until the screen is filled
    private func loadMoreToFillScreen() async {
        guard hasMoreUsers, !isLoadingMore, !isLoading, !isAutoFilling else { return }
        
        print("DEBUG: [UserListView] Auto-loading more to fill screen (content: \(contentHeight), screen: \(screenHeight))")
        
        // Set auto-filling flag to prevent concurrent operations
        await MainActor.run {
            isAutoFilling = true
            needsMoreContent = false
        }
        
        // Load next batch
        await loadMoreUsers()
        
        // Re-enable after a delay to allow UI to update and measure new content height
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay to allow UI to settle
        await MainActor.run {
            needsMoreContent = true
            isAutoFilling = false
        }
    }
}
