import SwiftUI

@available(iOS 16.0, *)
struct ProfileStatsSection: View {
    let user: User
    let onFollowersTap: () -> Void
    let onFollowingTap: () -> Void
    let onBookmarksTap: () -> Void
    let onFavoritesTap: () -> Void
    
    var body: some View {
        ProfileStatsView(
            user: user,
            onFollowersTap: onFollowersTap,
            onFollowingTap: onFollowingTap,
            onBookmarksTap: onBookmarksTap,
            onFavoritesTap: onFavoritesTap
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }
} 