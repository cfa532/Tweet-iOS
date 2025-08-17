import SwiftUI

@available(iOS 16.0, *)
struct ProfileHeaderView: View {
    let user: User
    let isCurrentUser: Bool
    let isFollowing: Bool
    let onEditTap: () -> Void
    let onFollowToggle: () -> Void
    let onAvatarTap: () -> Void
    
    private func formatRegistrationDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return "Since \(formatter.string(from: date))"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                // Avatar
                Button {
                    onAvatarTap()
                } label: {
                    Avatar(user: user, size: 80)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.trailing, 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text(user.name ?? "User Name")
                        .font(.title2)
                        .bold()
                        .foregroundColor(.themeText)
                    Text("@\(user.username ?? NSLocalizedString("username", comment: "Default username"))")
                        .foregroundColor(.themeSecondaryText)
                        .font(.subheadline)
                    Text(formatRegistrationDate(user.timestamp))
                        .foregroundColor(.themeSecondaryText)
                        .font(.caption)
                }
                Spacer()
                // Edit/Follow/Unfollow button
                if isCurrentUser {
                    Button(NSLocalizedString("Edit", comment: "Edit button")) {
                        onEditTap()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(.systemGray6))
                    )
                    .foregroundColor(.primary)
                } else {
                    DebounceButton(
                        isFollowing ? NSLocalizedString("Unfollow", comment: "Unfollow button") : NSLocalizedString("Follow", comment: "Follow button"),
                        cooldownDuration: 0.5,
                        enableVibration: false
                    ) {
                        onFollowToggle()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(isFollowing ? Color(.systemRed) : Color(.systemBlue))
                    )
                    .foregroundColor(.white)
                }
            }
            if let profile = user.profile {
                Text(profile)
                    .font(.body)
                    .foregroundColor(.themeText)
                    .lineLimit(3)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal)
        .padding(.top)
        .padding(.bottom, 4)
    }
} 
