import SwiftUI

struct UserListView: View {
    let user: User
    let type: UserContentType
    @State private var users: [User] = []
    @State private var isLoading = true
    @State private var error: String? = nil

    var body: some View {
        VStack {
            if isLoading {
                ProgressView()
            } else if let error = error {
                Text(error).foregroundColor(.red)
            } else if users.isEmpty {
                Text("No users found.").foregroundColor(.secondary)
            } else {
                List(users) { user in
                    HStack(spacing: 12) {
                        Avatar(user: user, size: 40)
                        VStack(alignment: .leading) {
                            Text(user.name ?? "No Name").font(.headline)
                            Text("@\(user.username ?? "")").font(.subheadline).foregroundColor(.secondary)
                            if let profile = user.profile, !profile.isEmpty {
                                Text(profile).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(type == .FOLLOWER ? "Fans" : "Followings")
        .onAppear {
            Task {
                await loadUsers()
            }
        }
    }

    private func loadUsers() async {
        isLoading = true
        error = nil
        do {
            let hprose = HproseInstance.shared
            let ids = try await hprose.getFollows(user: user, entry: type)
            var loadedUsers: [User] = []
            for id in ids {
                if let u = try? await hprose.getUser(id) {
                    loadedUsers.append(u)
                }
            }
            await MainActor.run {
                self.users = loadedUsers
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }
} 
