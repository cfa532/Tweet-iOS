import SwiftUI

@available(iOS 16.0, *)
struct ProfileStatsView: View {
    @ObservedObject var user: User
    let onFollowersTap: () -> Void
    let onFollowingTap: () -> Void
    let onBookmarksTap: () -> Void
    let onFavoritesTap: () -> Void
    @EnvironmentObject private var hproseInstance: HproseInstance
    
    var body: some View {
        HStack {
            Button {
                onFollowersTap()
            } label: {
                VStack {
                    Text(LocalizedStringKey("Fans"))
                        .font(.caption)
                        .foregroundColor(.themeSecondaryText)
                    Text("\(user.followersCount ?? 0)")
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
                    Text("\(user.followingCount ?? 0)")
                        .font(.headline)
                        .foregroundColor(.themeText)
                }
            }
            Spacer()
            VStack {
                Text(LocalizedStringKey("Tweets"))
                    .font(.caption)
                    .foregroundColor(.themeSecondaryText)
                Text("\(user.tweetCount ?? 0)")
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
                        Text("\(user.bookmarksCount ?? 0)")
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
                        Text("\(user.favoritesCount ?? 0)")
                            .font(.headline)
                            .foregroundColor(.themeText)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.cyan.opacity(0.3))
    }
}
