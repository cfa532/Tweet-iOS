import SwiftUI

@available(iOS 16.0, *)
struct UserListView: View {
    // MARK: - Properties
    let title: String
    let userFetcher: @Sendable (Int, Int) async throws -> [User]
    let onFollowToggle: ((User) async -> Void)?
    let onUserTap: ((User) -> Void)?
    
    @State private var users: [User] = []
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var hasMoreUsers: Bool = true
    @State private var currentPage: Int = 0
    private let pageSize: Int = 20
    @State private var errorMessage: String? = nil

    // MARK: - Initialization
    init(
        title: String,
        userFetcher: @escaping @Sendable (Int, Int) async throws -> [User],
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
    }

    // MARK: - Methods
    func refreshUsers() async {
        isLoading = true
        currentPage = 0
        hasMoreUsers = true
        do {
            let newUsers = try await userFetcher(0, pageSize)
            await MainActor.run {
                users = newUsers
                hasMoreUsers = newUsers.count == pageSize
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
        let nextPage = currentPage + 1
        Task {
            do {
                let moreUsers = try await userFetcher(nextPage, pageSize)
                await MainActor.run {
                    // Prevent duplicates
                    let existingIds = Set(users.map { $0.id })
                    let uniqueNew = moreUsers.filter { !existingIds.contains($0.id) }
                    users.append(contentsOf: uniqueNew)
                    hasMoreUsers = moreUsers.count == pageSize
                    currentPage = nextPage
                    isLoadingMore = false
                }
            } catch {
                print("Error loading more users: \(error)")
                await MainActor.run {
                    isLoadingMore = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - UserRowView
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
                Avatar(user: user, size: 40)
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
