import SwiftUI

struct UserListView: View {
    let user: User
    let type: UserContentType
    @State private var users: [User] = []
    @State private var isLoading = true
    @State private var error: String? = nil
    @State private var followingStatus: [String: Bool] = [:]
    @EnvironmentObject private var hproseInstance: HproseInstance

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
                        Button(action: {
                            Task {
                                let isNowFollowing = followingStatus[user.mid] ?? false
                                // Toggle following for appUser
                                _ = try? await hproseInstance.toggleFollowing(
                                    followedId: user.mid,
                                    followingId: hproseInstance.appUser.mid
                                )
                                // Toggle follower for the other user
                                _ = try? await hproseInstance.toggleFollower(
                                    userId: user.mid,
                                    isFollowing: !isNowFollowing,
                                    followerId: hproseInstance.appUser.mid
                                )
                                await MainActor.run {
                                    followingStatus[user.mid] = !isNowFollowing
                                }
                            }
                        }) {
                            Text((followingStatus[user.mid] ?? false) ? "Unfollow" : "Follow")
                                .foregroundColor((followingStatus[user.mid] ?? false) ? .red : .blue)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                        }
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
            var followingMap: [String: Bool] = [:]
            for id in ids {
                if let u = try? await hprose.getUser(id) {
                    loadedUsers.append(u)
                    // Determine if appUser is following this user
                    let isFollowing = hproseInstance.appUser.followingList?.contains(u.mid) ?? false
                    followingMap[u.mid] = isFollowing
                }
            }
            await MainActor.run {
                self.users = loadedUsers
                self.followingStatus = followingMap
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
