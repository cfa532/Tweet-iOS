import SwiftUI

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var hproseInstance = HproseInstance.shared

    let user: User
    @State private var tweets: [Tweet] = []
    @State private var showEditSheet = false
    @State private var showAvatarFullScreen = false
    @State private var isFollowing = false // Set this based on your logic
    @State private var isLoading = false
    @State private var didLoad = false

    var isCurrentUser: Bool {
        user.mid == hproseInstance.appUser.mid
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header (now VStack, not ZStack)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    // Avatar
                    Button {
                        showAvatarFullScreen = true
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
                            showEditSheet = true
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                        )
                    } else {
                        Button(isFollowing ? "Unfollow" : "Follow") {
                            // Follow/unfollow logic here
                            isFollowing.toggle()
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
            .padding(.bottom, 4) // Reduce bottom padding for tighter layout

            // Stats Row (always visible)
            HStack {
                VStack {
                    Text("Fans")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text("\(user.followersCount ?? 0)")
                        .font(.headline)
                }
                Spacer()
                VStack {
                    Text("Following")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text("\(user.followingCount ?? 0)")
                        .font(.headline)
                }
                Spacer()
                VStack {
                    Text("Tweet")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text("\(user.tweetCount ?? 0)")
                        .font(.headline)
                }
                Spacer()
                VStack {
                    Image(systemName: "bookmark")
                    Text("\(user.bookmarksCount ?? 0)")
                        .font(.headline)
                }
                Spacer()
                VStack {
                    Image(systemName: "heart")
                    Text("\(user.favoritesCount ?? 0)")
                        .font(.headline)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))

            // Tabs (optional, for now just a sticky bar)
            HStack {
                Text("Pinned")
                    .font(.subheadline)
                    .bold()
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color(.systemGray6))

            // Posts List
            if isLoading {
                ProgressView("Loading tweets...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tweets.isEmpty {
                Text("No tweets yet.")
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(tweets) { tweet in
                    TweetItemView(tweet: tweet,
                                  likeTweet: { _ in },
                                  retweet: { _ in },
                                  bookmarkTweet: { _ in },
                                  deleteTweet: { _ in })
                }
                .listStyle(PlainListStyle())
            }
        }
        .sheet(isPresented: $showEditSheet) {
            Text("Edit User Info Sheet")
        }
        .fullScreenCover(isPresented: $showAvatarFullScreen) {
            AvatarFullScreenView(user: user, isPresented: $showAvatarFullScreen)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isCurrentUser {
                    Menu {
                        Button("Logout", role: .destructive) {
                            UserViewModel.logout()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .rotationEffect(.degrees(90))
                    }
                }
            }
        }
        .task {
            // Only load once
            if !didLoad {
                isLoading = true
                do {
                    let loadedTweets = try await hproseInstance.fetchUserTweet(user: user, startRank: 0, endRank: 19)
                    tweets = loadedTweets
                } catch {
                    // Optionally handle error
                }
                isLoading = false
                didLoad = true
            }
        }
    }
}

// Full screen avatar view
struct AvatarFullScreenView: View {
    let user: User
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            VStack {
                Spacer()
                if let avatarUrl = user.avatarUrl, let url = URL(string: avatarUrl) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Color.gray
                    }
                } else {
                    Image("ic_splash")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Text("mid: \(user.mid)")
                    if let baseUrl = user.baseUrl {
                        Text("baseUrl: \(baseUrl)")
                    }
                    if let hostId = user.hostIds?.first {
                        Text("hostId: \(hostId)")
                    }
                }
                .foregroundColor(.white)
                .padding()
                .background(Color.black.opacity(0.7))
                .cornerRadius(12)
                .padding(.bottom, 32)
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.white)
                            .padding()
                    }
                }
                Spacer()
            }
        }
    }
} 
