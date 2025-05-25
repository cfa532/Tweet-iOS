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
                    Text("@\(user.username ?? "username")")
                        .foregroundColor(.gray)
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
                            .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                    )
                } else {
                    Button(isFollowing ? "Unfollow" : "Follow") {
                        onFollowToggle()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isFollowing ? Color.red : Color.blue, lineWidth: 1)
                    )
                    .foregroundColor(isFollowing ? .red : .blue)
                }
            }
            if let profile = user.profile {
                Text(profile)
                    .font(.body)
                    .foregroundColor(.primary)
            }
        }
        .padding(.horizontal)
        .padding(.top)
        .padding(.bottom, 4)
    }
} 