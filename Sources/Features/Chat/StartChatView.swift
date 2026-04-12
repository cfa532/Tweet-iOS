import SwiftUI

@available(iOS 16.0, *)
struct StartChatView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hproseInstance: HproseInstance
    @State private var users: [User] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var navigationPath = NavigationPath()

    private let onShowLogin: (() -> Void)?
    private let onShowToast: ((String, Bool) -> Void)?

    init(
        onShowLogin: (() -> Void)? = nil,
        onShowToast: ((String, Bool) -> Void)? = nil
    ) {
        self.onShowLogin = onShowLogin
        self.onShowToast = onShowToast
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
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
                            navigationPath.append(user.mid)
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
            .navigationDestination(for: String.self) { receiptId in
                ChatScreen(
                    receiptId: receiptId,
                    navigationPath: $navigationPath,
                    onProfileNavigate: nil,
                    onShowLogin: onShowLogin,
                    onShowToast: onShowToast
                )
            }
            .appNavigationDestinations(
                path: $navigationPath,
                onShowLogin: onShowLogin,
                onShowToast: onShowToast
            )
        }
        .task {
            await loadFollowings()
        }
    }

    private func loadFollowings() async {
        isLoading = true
        do {
            let followingIds = try await hproseInstance.getListByType(
                user: hproseInstance.appUser,
                entry: .FOLLOWING
            )

            var fetchedUsers: [User] = []
            for userId in followingIds {
                if let user = try await hproseInstance.fetchUser(userId) {
                    if user.username != nil {
                        fetchedUsers.append(user)
                    }
                }
            }

            await MainActor.run {
                users = fetchedUsers
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = ErrorMessageHelper.userFriendlyMessage(from: error)
                isLoading = false
            }
        }
    }
}
