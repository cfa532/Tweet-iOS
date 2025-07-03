import SwiftUI

@available(iOS 16.0, *)
struct ProfileHeaderView: View {
    let user: User
    let isCurrentUser: Bool
    let isFollowing: Bool
    let onEditTap: () -> Void
    let onFollowToggle: () -> Void
    let onAvatarTap: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                // Avatar
                Button {
                    onAvatarTap()
                } label: {
                    Avatar(user: user, size: 72)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.trailing, 12)

                VStack(alignment: .leading, spacing: 4) {
                    Text(user.name ?? "User Name")
                        .font(.title2)
                        .bold()
                        .foregroundColor(.themeText)
                    Text("@\(user.username ?? NSLocalizedString("username", comment: "Default username"))")
                        .foregroundColor(.themeSecondaryText)
                        .font(.subheadline)
                }
                Spacer()
                // Edit/Follow/Unfollow button
                if isCurrentUser {
                    Button("Edit") {
                        onEditTap()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.themeBorder, lineWidth: 1)
                    )
                    .foregroundColor(.themeText)
                } else {
                    Button(isFollowing ? "Unfollow" : "Follow") {
                        onFollowToggle()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isFollowing ? Color.red : Color.themeAccent, lineWidth: 1)
                    )
                    .foregroundColor(isFollowing ? .red : .themeAccent)
                }
            }
            if let profile = user.profile {
                Text(profile)
                    .font(.body)
                    .foregroundColor(.themeText)
            }
        }
        .padding(.horizontal)
        .padding(.top)
        .padding(.bottom, 4)
    }
} 