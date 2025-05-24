import SwiftUI

@available(iOS 16.0, *)
struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var hproseInstance = HproseInstance.shared

    let user: User
    let onLogout: (() -> Void)?
    @State private var tweets: [Tweet] = []
    @State private var pinnedTweets: [Tweet] = []
    @State private var pinnedTweetIds: Set<String> = []
    @State private var pinnedTweetTimes: [String: Any] = [:]
    @State private var showEditSheet = false
    @State private var showAvatarFullScreen = false
    @State private var isFollowing = false // Set this based on your logic
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var selectedUser: User? = nil

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

            // Posts List
            if isLoading {
                ProgressView("Loading tweets...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tweets.isEmpty && pinnedTweets.isEmpty {
                Text("No tweets yet.")
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !pinnedTweets.isEmpty {
                        Section(header: Text("Pinned").font(.subheadline).bold()) {
                            ForEach($pinnedTweets) { $tweet in
                                TweetItemView(tweet: $tweet,
                                              retweet: { _ in },
                                              deleteTweet: { _ in },
                                              isInProfile: true,
                                              onAvatarTap: { _ in })
                                    .listRowInsets(EdgeInsets())
                                    .listRowSeparator(.hidden)
                            }
                        }
                    }
                    ForEach($tweets) { $tweet in
                        TweetItemView(tweet: $tweet,
                                      retweet: { _ in },
                                      deleteTweet: { _ in },
                                      isInProfile: true,
                                      onAvatarTap: { _ in /* do nothing in profile */ })
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(PlainListStyle())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.zero)
            }

            // Hidden NavigationLink for avatar navigation (not used in profile, but for completeness)
            NavigationLink(
                destination: selectedUser.map { ProfileView(user: $0, onLogout: onLogout) },
                isActive: Binding(
                    get: { selectedUser != nil },
                    set: { if !$0 { selectedUser = nil } }
                )
            ) {
                EmptyView()
            }
            .hidden()
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
                            hproseInstance.logout()
                            onLogout?()
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
            if !didLoad {
                isLoading = true
                let start = Date()
                do {
                    let pinnedList = try await hproseInstance.getPinnedTweets(user: user)
                    // Extract tweets and their pin times, sort by timePinned descending
                    let sortedPinned = pinnedList.compactMap { dict -> (Tweet, Any)? in
                        guard let tweet = dict["tweet"] as? Tweet, let timePinned = dict["timePinned"] else { return nil }
                        return (tweet, timePinned)
                    }.sorted { lhs, rhs in
                        // Sort by timePinned descending (most recent first)
                        guard let l = lhs.1 as? TimeInterval, let r = rhs.1 as? TimeInterval else { return false }
                        return l > r
                    }
                    pinnedTweets = sortedPinned.map { $0.0 }
                    pinnedTweetIds = Set(pinnedTweets.map { $0.mid })
                    pinnedTweetTimes = Dictionary(uniqueKeysWithValues: sortedPinned.map { ($0.0.mid, $0.1) })
                } catch {
                    print("Error loading pinned tweets: \(error)")
                }
                do {
                    let loadedTweets = try await hproseInstance.fetchUserTweet(user: user, startRank: 0, endRank: 19)
                    tweets = loadedTweets.map { tweet in
                        var t = tweet
                        t.isPinned = pinnedTweetIds.contains(tweet.mid)
                        return t
                    }
                } catch {
                    // handle error
                }
                let end = Date()
                print("Time to load tweets: \(end.timeIntervalSince(start)) seconds")
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
