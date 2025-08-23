import SwiftUI

@available(iOS 16.0, *)
struct UserListView: View {
    // MARK: - Properties
    let title: String
    let userFetcher: @Sendable (Int, Int) async throws -> [String] // Now returns user IDs
    let onFollowToggle: ((User) async -> Void)?
    let onUserTap: ((User) -> Void)?
    
    @State private var userIds: [String] = [] // Store all user IDs
    @State private var users: [User] = [] // Store fetched user objects
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var hasMoreUsers: Bool = true
    @State private var currentPage: Int = 0
    private let initialBatchSize: Int = 10
    private let loadMoreBatchSize: Int = 10
    @State private var errorMessage: String? = nil
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
                    ForEach(users) { user in
                        UserRowView(
                            user: user,
                            onFollowToggle: onFollowToggle,
                            onTap: { selectedUser in
                                navigationPath.append(selectedUser)
                            }
                        )
                        .id(user.mid)
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
                if users.isEmpty {
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
    }
    
    // MARK: - Methods
    func refreshUsers() async {
        isLoading = true
        currentPage = 0
        hasMoreUsers = true
        do {
            // First fetch all user IDs
            let allUserIds = try await userFetcher(0, Int.max)
            // Deduplicate user IDs
            let uniqueUserIds = Array(Set(allUserIds))
            await MainActor.run {
                userIds = uniqueUserIds
                users = []
                print("DEBUG: [UserListView] Loaded \(uniqueUserIds.count) user IDs: \(uniqueUserIds)")
            }
            
            // Start fetching initial batch of user objects in parallel
            let initialUserIds = Array(uniqueUserIds.prefix(initialBatchSize))
            await fetchUsersInParallel(for: initialUserIds)
            
            await MainActor.run {
                hasMoreUsers = uniqueUserIds.count > initialBatchSize
                isLoading = false
            }
        } catch {
            print("Error refreshing users: \(error)")
            await MainActor.run {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }
    
    func loadMoreUsers() {
        guard hasMoreUsers, !isLoadingMore else { return }
        isLoadingMore = true
        
        let startIndex = users.count
        let endIndex = min(startIndex + loadMoreBatchSize, userIds.count)
        
        Task {
            // If we've reached the end of the list, update state and return
            if startIndex >= userIds.count {
                await MainActor.run {
                    hasMoreUsers = false
                    isLoadingMore = false
                }
                return
            }
            
            let nextBatchIds = Array(userIds[startIndex..<endIndex])
            // Defensive: If no more IDs to load, stop
            if nextBatchIds.isEmpty {
                await MainActor.run {
                    hasMoreUsers = false
                    isLoadingMore = false
                }
                return
            }
            
            await fetchUsersInParallel(for: nextBatchIds)
            
            await MainActor.run {
                hasMoreUsers = endIndex < userIds.count
                isLoadingMore = false
            }
        }
    }
    
    // New method: Fetch users in parallel and add them individually as they complete
    private func fetchUsersInParallel(for userIds: [String]) async {
        await withTaskGroup(of: (String, User?).self) { group in
            for userId in userIds {
                group.addTask {
                    do {
                        if let user = try await hproseInstance.fetchUser(userId) {
                            print("DEBUG: [UserListView] Successfully fetched user: \(userId)")
                            return (userId, user)
                        } else {
                            print("DEBUG: [UserListView] Failed to fetch user: \(userId)")
                            return (userId, nil)
                        }
                    } catch {
                        print("DEBUG: [UserListView] Error fetching user \(userId): \(error)")
                        return (userId, nil)
                    }
                }
            }
            
            // Process results as they complete
            for await (userId, user) in group {
                if let user = user {
                    await MainActor.run {
                        // Only add if not already present
                        if !users.contains(where: { $0.mid == userId }) {
                            users.append(user)
                            print("DEBUG: [UserListView] Added user to display: \(userId)")
                        }
                    }
                }
            }
        }
    }
}
