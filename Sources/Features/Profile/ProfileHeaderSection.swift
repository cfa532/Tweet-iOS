import SwiftUI

@available(iOS 16.0, *)
struct ProfileHeaderSection: View {
    @ObservedObject var user: User
    @ObservedObject var headerState: ProfileHeaderState
    let isCurrentUser: Bool
    let onEditTap: () -> Void
    let onFollowToggle: () -> Void
    let onAvatarTap: () -> Void
    
    var body: some View {
        ProfileHeaderView(
            user: user,
            headerState: headerState,
            isCurrentUser: isCurrentUser,
            onEditTap: onEditTap,
            onFollowToggle: onFollowToggle,
            onAvatarTap: onAvatarTap
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
