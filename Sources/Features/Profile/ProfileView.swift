import SwiftUI

// MARK: - ProfileView
@available(iOS 16.0, *)
struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hproseInstance: HproseInstance

    let user: User
    let onLogout: (() -> Void)?
    @State private var tweets: [Tweet] = []
    @State private var pinnedTweets: [Tweet] = []
    @State private var pinnedTweetIds: Set<String> = []
    @State private var pinnedTweetTimes: [String: Any] = [:]
    @State private var showEditSheet = false
    @State private var showAvatarFullScreen = false
    @State private var isFollowing = false
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var selectedUser: User? = nil
    @State private var showUserList = false
    @State private var userListType: UserContentType = .FOLLOWING
    @State private var showTweetList = false
    @State private var tweetListType: UserContentType = .BOOKMARKS

    var isCurrentUser: Bool {
        user.mid == hproseInstance.appUser.mid
    }

    var body: some View {
        VStack(spacing: 0) {
            ProfileHeaderView(
                user: user,
                isCurrentUser: isCurrentUser,
                isFollowing: isFollowing,
                onEditTap: { showEditSheet = true },
                onFollowToggle: { isFollowing.toggle() },
                onAvatarTap: { showAvatarFullScreen = true }
            )
            
            ProfileStatsView(
                user: user,
                onFollowersTap: {
                    userListType = .FOLLOWER
                    showUserList = true
                },
                onFollowingTap: {
                    userListType = .FOLLOWING
                    showUserList = true
                },
                onBookmarksTap: {
                    tweetListType = .BOOKMARKS
                    showTweetList = true
                },
                onFavoritesTap: {
                    tweetListType = .FAVORITES
                    showTweetList = true
                }
            )

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
                                      onAvatarTap: { _ in })
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(PlainListStyle())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.zero)
            }

            // Hidden NavigationLink for avatar navigation
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
            RegistrationView(mode: .edit, user: user, onSubmit: { username, password, alias, profile, hostId in
                // TODO: Implement user update logic here
            })
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
        .navigationDestination(isPresented: $showUserList) {
            UserListView(
                title: userListType == .FOLLOWER ? "Fans" : "Following",
                userFetcher: { page, size in
                    let ids = try await hproseInstance.getFollows(user: user, entry: userListType)
                    let startIndex = page * size
                    let endIndex = min(startIndex + size, ids.count)
                    guard startIndex < endIndex else { return [] }
                    let pageIds = Array(ids[startIndex..<endIndex])
                    
                    var users: [User] = []
                    for id in pageIds {
                        if let user = try? await hproseInstance.getUser(id) {
                            users.append(user)
                        }
                    }
                    return users
                },
                onFollowToggle: { user in
                    if let isFollowing = try? await hproseInstance.toggleFollowing(
                        followedId: user.mid,
                        followingId: hproseInstance.appUser.mid
                    ) {
                        // Toggle follower for the other user
                        try? await hproseInstance.toggleFollower(
                            userId: user.mid,
                            isFollowing: isFollowing,
                            followerId: hproseInstance.appUser.mid
                        )
                    }
                },
                onUserTap: { user in
                    selectedUser = user
                }
            )
        }
        .navigationDestination(isPresented: $showTweetList) {
            TweetListView(
                title: tweetListType == .BOOKMARKS ? "Bookmarks" : "Favorites",
                tweetFetcher: { page, size in
                    try await hproseInstance.getUserTweetsByType(
                        user: user,
                        type: tweetListType
                    )
                },
                onRetweet: { tweet in
                    if let retweet = try? await hproseInstance.retweet(tweet) {
                        // Update retweet count of the original tweet
                        if let updatedOriginalTweet = try? await hproseInstance.updateRetweetCount(
                            tweet: tweet,
                            retweetId: retweet.mid
                        ) {
                            // Update the tweet in the list if it exists
                            if let index = tweets.firstIndex(where: { $0.id == updatedOriginalTweet.mid }) {
                                tweets[index] = updatedOriginalTweet
                            }
                        }
                    }
                },
                onDeleteTweet: { tweet in
                    if let tweetId = try? await hproseInstance.deleteTweet(tweet.mid) {
                        print("Successfully deleted tweet: \(tweetId)")
                    }
                },
                onAvatarTap: { user in
                    selectedUser = user
                }
            )
        }
    }
}
