import SwiftUI

@available(iOS 16.0, *)
struct StartChatView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hproseInstance: HproseInstance
    @State private var users: [User] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var selectedUser: User? = nil
    @State private var showChatScreen = false
    
    var body: some View {
        NavigationStack {
            VStack {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if users.isEmpty {
                    VStack {
                        Image(systemName: "person.2")
                            .font(.system(size: 48))
                            .foregroundColor(.gray)
                        Text(LocalizedStringKey("No followings found"))
                            .font(.headline)
                            .foregroundColor(.gray)
                        Text(LocalizedStringKey("Follow some users to start chatting"))
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(users) { user in
                        Button(action: {
                            // Navigate to chat screen with this user
                            print("[StartChatView] Button tapped for user: \(user.username ?? "unknown")")
                            selectedUser = user
                            showChatScreen = true
                            print("[StartChatView] showChatScreen set to: \(showChatScreen)")
                        }) {
                            HStack {
                                Avatar(user: user, size: 40)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("\(user.name ?? "")@\(user.username ?? "")")
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        Spacer()
                                    }
                                    
                                    if let profile = user.profile, !profile.isEmpty {
                                        Text(profile)
                                            .font(.body)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                
                                Image(systemName: "message")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 16, weight: .medium))
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            .navigationTitle(NSLocalizedString("Start Chat", comment: "Start chat screen title"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showChatScreen) {
                if let selectedUser = selectedUser {
                    ChatScreen(receiptId: selectedUser.mid)
                } else {
                    EmptyView()
                }
            }
        }
        .task {
            await loadFollowings()
        }
    }
    
    private func loadFollowings() async {
        isLoading = true
        do {
            // Get current user's followings
            let followingIds = try await hproseInstance.getListByType(
                user: hproseInstance.appUser,
                entry: .FOLLOWING
            )
            
            // Fetch user objects for each following ID
            var fetchedUsers: [User] = []
            for userId in followingIds {
                if let user = try await hproseInstance.fetchUser(userId) {
                    fetchedUsers.append(user)
                }
            }
            
            await MainActor.run {
                users = fetchedUsers
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
    

}

 
