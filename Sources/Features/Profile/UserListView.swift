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
            }
            
            // Then fetch initial batch of user objects
            let initialUserIds = Array(uniqueUserIds.prefix(initialBatchSize))
            let initialUsers = try await fetchUserObjects(for: initialUserIds)
            
            await MainActor.run {
                users = initialUsers
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
            
            do {
                let moreUsers = try await fetchUserObjects(for: nextBatchIds)
                await MainActor.run {
                    let existingIds = Set(users.map { $0.mid })
                    let uniqueNewUsers = moreUsers.filter { !existingIds.contains($0.mid) }
                    users.append(contentsOf: uniqueNewUsers)
                    // If we loaded fewer users than requested, or none, stop loading more
                    if uniqueNewUsers.isEmpty || moreUsers.count < nextBatchIds.count || endIndex >= userIds.count {
                        hasMoreUsers = false
                    } else {
                        hasMoreUsers = true
                    }
                    isLoadingMore = false
                }
            } catch {
                print("Error loading more users: \(error)")
                await MainActor.run {
                    isLoadingMore = false
                    errorMessage = error.localizedDescription
                    hasMoreUsers = false // Stop spinner on error
                }
            }
        }
    }
    
    private func fetchUserObjects(for userIds: [String]) async throws -> [User] {
        var fetchedUsers: [User] = []
        var processedIds = Set<String>()
        
        for userId in userIds {
            // Skip if we've already processed this ID
            guard !processedIds.contains(userId) else { continue }
            processedIds.insert(userId)
            
            do {
                // Fetch user using HproseInstance's improved fetchUser method
                if let user = try await hproseInstance.fetchUser(userId) {
                    // Only add if we haven't already added this user
                    if !fetchedUsers.contains(where: { $0.mid == userId }) {
                        fetchedUsers.append(user)
                    }
                }
            } catch {
                print("Error fetching user \(userId): \(error)")
                // Continue with next user ID
                continue
            }
        }
        
        return fetchedUsers
    }
}
