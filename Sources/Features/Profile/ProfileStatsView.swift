import SwiftUI

@available(iOS 16.0, *)
struct ProfileStatsView: View {
    @ObservedObject var user: User
    let onFollowersTap: () -> Void
    let onFollowingTap: () -> Void
    let onBookmarksTap: () -> Void
    let onFavoritesTap: () -> Void
    @EnvironmentObject private var hproseInstance: HproseInstance
    
    // Always use singleton instance to ensure stats update when data changes
    private var singleton: User {
        User.getInstance(mid: user.mid)
    }
    
    var body: some View {
        HStack {
            Button {
                onFollowersTap()
            } label: {
                VStack {
                    Text(LocalizedStringKey("Fans"))
                        .font(.caption)
                        .foregroundColor(.themeSecondaryText)
                    Text("\(singleton.followersCount ?? 0)")
                        .font(.headline)
                        .foregroundColor(.themeText)
                }
            }
            Spacer()
            Button {
                onFollowingTap()
            } label: {
                VStack {
                    Text(LocalizedStringKey("Followings"))
                        .font(.caption)
                        .foregroundColor(.themeSecondaryText)
                    Text("\(singleton.followingCount ?? 0)")
                        .font(.headline)
                        .foregroundColor(.themeText)
                }
            }
            Spacer()
            VStack {
                Text(LocalizedStringKey("Tweets"))
                    .font(.caption)
                    .foregroundColor(.themeSecondaryText)
                Text("\(singleton.tweetCount ?? 0)")
                    .font(.headline)
                    .foregroundColor(.themeText)
            }
            Spacer()
            if hproseInstance.appUser.mid == user.mid {
                Button {
                    onBookmarksTap()
                } label: {
                    VStack {
                        Image(systemName: "bookmark")
                            .foregroundColor(.themeSecondaryText)
                        Text("\(singleton.bookmarksCount ?? 0)")
                            .font(.headline)
                            .foregroundColor(.themeText)
                    }
                }
                Spacer()
                Button {
                    onFavoritesTap()
                } label: {
                    VStack {
                        Image(systemName: "heart")
                            .foregroundColor(.themeSecondaryText)
                        Text("\(singleton.favoritesCount ?? 0)")
                            .font(.headline)
                            .foregroundColor(.themeText)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(Color.cyan.opacity(0.3))
        .id(singleton.tweetCount) // Force re-render when tweetCount changes
    }
}
