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
    private let loadMoreBatchSize: Int = 5
    @State private var errorMessage: String? = nil
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hproseInstance: HproseInstance

    // MARK: - Initialization
    init(
        title: String,
        userFetcher: @escaping @Sendable (Int, Int) async throws -> [String],
        onFollowToggle: ((User) async -> Void)? = nil,
        onUserTap: ((User) -> Void)? = nil
    ) {
        self.title = title
        self.userFetcher = userFetcher
        self.onFollowToggle = onFollowToggle
        self.onUserTap = onUserTap
    }

    // MARK: - Body
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("top")
                    ForEach(users) { user in
                        UserRowView(
                            user: user,
                            onFollowToggle: onFollowToggle,
                            onTap: onUserTap
                        )
                        .id(user.id)
                    }
                    if hasMoreUsers {
                        ProgressView()
                            .padding()
                            .onAppear {
                                if !isLoadingMore {
                                    loadMoreUsers()
                                }
                            }
                    } else if isLoading || isLoadingMore {
                        ProgressView()
                            .padding()
                    }
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
        
        for userId in userIds {
            // First check if user is in cache
            if let cachedUser = hproseInstance.exposedCachedUsers.first(where: { $0.mid == userId }) {
                fetchedUsers.append(cachedUser)
                continue
            }
            
            // If not in cache, fetch from server
            do {
                if let user = try await hproseInstance.getUser(userId) {
                    fetchedUsers.append(user)
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

// MARK: - UserRowView
@available(iOS 16.0, *)
struct UserRowView: View {
    let user: User
    let onFollowToggle: ((User) async -> Void)?
    let onTap: ((User) -> Void)?
    @State private var isFollowing: Bool = false
    @EnvironmentObject private var hproseInstance: HproseInstance

    var body: some View {
        Button {
            onTap?(user)
        } label: {
            HStack {
                NavigationLink(destination: ProfileView(user: user, onLogout: nil)) {
                    Avatar(user: user, size: 40)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.trailing, 8)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.name ?? "User Name")
                        .font(.headline)
                    Text("@\(user.username ?? "username")")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                if let onFollowToggle = onFollowToggle {
                    Button {
                        Task {
                            await onFollowToggle(user)
                            isFollowing.toggle()
                        }
                    } label: {
                        Text(isFollowing ? "Unfollow" : "Follow")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isFollowing ? Color.red : Color.blue, lineWidth: 1)
                            )
                            .foregroundColor(isFollowing ? .red : .blue)
                    }
                }
            }
            .padding()
            .background(Color(.systemBackground))
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            isFollowing = hproseInstance.appUser.followingList?.contains(user.mid) ?? false
        }
    }
} 
