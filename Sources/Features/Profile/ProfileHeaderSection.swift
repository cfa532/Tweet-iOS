import SwiftUI

@available(iOS 16.0, *)
struct ProfileHeaderSection: View {
    let user: User
    let isCurrentUser: Bool
    let isFollowing: Bool
    let onEditTap: () -> Void
    let onFollowToggle: () -> Void
    let onAvatarTap: () -> Void
    
    var body: some View {
        ProfileHeaderView(
            user: user,
            isCurrentUser: isCurrentUser,
            isFollowing: isFollowing,
            onEditTap: onEditTap,
            onFollowToggle: onFollowToggle,
            onAvatarTap: onAvatarTap
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }
} 