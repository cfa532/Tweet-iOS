import SwiftUI

@available(iOS 16.0, *)
struct ProfileStatsView: View {
    let user: User
    let onFollowersTap: () -> Void
    let onFollowingTap: () -> Void
    let onBookmarksTap: () -> Void
    let onFavoritesTap: () -> Void
    
    var body: some View {
        HStack {
            Button {
                onFollowersTap()
            } label: {
                VStack {
                    Text("Fans")
                        .font(.caption)
                    Text("\(user.followersCount ?? 0)")
                        .font(.headline)
                }
            }
            Spacer()
            Button {
                onFollowingTap()
            } label: {
                VStack {
                    Text("Followings")
                        .font(.caption)
                    Text("\(user.followingCount ?? 0)")
                        .font(.headline)
                }
            }
            Spacer()
            VStack {
                Text("Tweets")
                    .font(.caption)
                Text("\(user.tweetCount ?? 0)")
                    .font(.headline)
            }
            Spacer()
            Button {
                onBookmarksTap()
            } label: {
                VStack {
                    Image(systemName: "bookmark")
                    Text("\(user.bookmarksCount ?? 0)")
                        .font(.headline)
                }
            }
            Spacer()
            Button {
                onFavoritesTap()
            } label: {
                VStack {
                    Image(systemName: "heart")
                    Text("\(user.favoritesCount ?? 0)")
                        .font(.headline)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }
} 
