import SwiftUI

// MARK: - ProfileView
/// A view that displays a user's profile, including their tweets, pinned tweets, and user information.
/// This view handles both the current user's profile and other users' profiles.
@available(iOS 16.0, *)
struct ProfileView: View {
    // MARK: - Environment
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hproseInstance: HproseInstance

    // MARK: - Properties
    /// The user whose profile is being displayed
    let user: User
    /// Optional callback for handling logout
    let onLogout: (() -> Void)?

    // MARK: - State
    /// List of tweets that are pinned to the top of the profile
    @State private var pinnedTweets: [Tweet] = []
    /// Set of tweet IDs that are pinned, used for quick lookup
    @State private var pinnedTweetIds: Set<String> = []
    /// Controls the visibility of the edit profile sheet
    @State private var showEditSheet = false
    /// Controls the visibility of the full-screen avatar view
    @State private var showAvatarFullScreen = false
    /// Tracks whether the current user is following the profile user
    @State private var isFollowing = false
    /// Indicates if tweets are currently being loaded
    @State private var isLoading = false
    /// Tracks if the initial data load has been completed
    @State private var didLoad = false
    /// The user selected when tapping on an avatar
    @State private var selectedUser: User? = nil
    /// Controls the visibility of the user list (followers/following)
    @State private var showUserList = false
    /// Determines which type of user list to show (followers or following)
    @State private var userListType: UserContentType = .FOLLOWING
    /// Controls the visibility of the tweet list (bookmarks/favorites)
    @State private var showTweetList = false
    /// Determines which type of tweet list to show (bookmarks or favorites)
    @State private var tweetListType: UserContentType = .BOOKMARKS

    // MARK: - Computed Properties
    /// Returns true if the displayed profile belongs to the current user
    var isCurrentUser: Bool {
        user.mid == hproseInstance.appUser.mid
    }

    // MARK: - Methods
    /// Refreshes the list of pinned tweets for the profile
    private func refreshPinnedTweets() async {
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
            await MainActor.run {
                pinnedTweets = sortedPinned.map { $0.0 }
                pinnedTweetIds = Set(pinnedTweets.map { $0.mid })
            }
        } catch {
            print("Error refreshing pinned tweets: \(error)")
        }
    }

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            // Profile header with user info and avatar
            ProfileHeaderView(
                user: user,
                isCurrentUser: isCurrentUser,
                isFollowing: isFollowing,
                onEditTap: { showEditSheet = true },
                onFollowToggle: { isFollowing.toggle() },
                onAvatarTap: { showAvatarFullScreen = true }
            )
            
            // Stats section showing followers, following, bookmarks, and favorites
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
            } else if pinnedTweets.isEmpty {
                RegularTweetsView(
                    user: user,
                    pinnedTweetIds: pinnedTweetIds,
                    hproseInstance: hproseInstance,
                    onUserSelect: { user in selectedUser = user }
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Pinned tweets section
                        VStack(spacing: 0) {
                            Text("Pinned")
                                .font(.subheadline)
                                .bold()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color(UIColor.systemBackground))
                            
                            ForEach(pinnedTweets) { tweet in
                                TweetItemView(tweet: tweet,
                                              retweet: { _ in },
                                              deleteTweet: { tweet in
                                                  Task {
                                                      if let tweetId = try? await hproseInstance.deleteTweet(tweet.mid) {
                                                          print("Successfully deleted pinned tweet: \(tweetId)")
                                                          await refreshPinnedTweets()
                                                      }
                                                  }
                                              },
                                              isPinned: true,
                                              isInProfile: true,
                                              onAvatarTap: { _ in })
                            }
                            
                            TweetsSectionHeader()
                        }
                        
                        // Regular tweets section
                        RegularTweetsView(
                            user: user,
                            pinnedTweetIds: pinnedTweetIds,
                            hproseInstance: hproseInstance,
                            onUserSelect: { user in selectedUser = user }
                        )
                    }
                }
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
        // Edit profile sheet
        .sheet(isPresented: $showEditSheet) {
            RegistrationView(mode: .edit, user: user, onSubmit: { username, password, alias, profile, hostId in
                // TODO: Implement user update logic here
            })
        }
        // Full-screen avatar view
        .fullScreenCover(isPresented: $showAvatarFullScreen) {
            AvatarFullScreenView(user: user, isPresented: $showAvatarFullScreen)
        }
        // Profile menu with logout option
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
        // Initial data loading
        .task {
            if !didLoad {
                isLoading = true
                await refreshPinnedTweets()
                isLoading = false
                didLoad = true
            }
        }
        // Listen for tweet pin status changes
        .onReceive(NotificationCenter.default.publisher(for: .tweetPinStatusChanged)) { notification in
            if let _ = notification.userInfo?["tweetId"] as? String,
               let _ = notification.userInfo?["isPinned"] as? Bool {
                Task {
                    await refreshPinnedTweets()
                }
            }
        }
        // User list navigation (followers/following)
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
        // Tweet list navigation (bookmarks/favorites)
        .navigationDestination(isPresented: $showTweetList) {
            TweetListView<TweetItemView>(
                title: tweetListType == .BOOKMARKS ? "Bookmarks" : "Favorites",
                tweetFetcher: { page, size in
                    print("[ProfileView] Fetching tweets for type: \(tweetListType)")
                    return try await hproseInstance.fetchUserTweet(
                        user: user,
                        startRank: UInt(page * size),
                        endRank: UInt((page + 1) * size - 1)
                    )
                },
//                onAvatarTap: { user in
//                    selectedUser = user
//                },
                showTitle: true,
                rowView: { tweet in
                    TweetItemView(
                        tweet: tweet,
                        retweet: { tweet in
                            if let retweet = try? await hproseInstance.retweet(tweet) {
                                if let updatedOriginalTweet = try? await hproseInstance.updateRetweetCount(
                                    tweet: tweet,
                                    retweetId: retweet.mid
                                ) {
                                    // The TweetListView will handle updating its own state
                                }
                            }
                        },
                        deleteTweet: { tweet in
                            if let tweetId = try? await hproseInstance.deleteTweet(tweet.mid) {
                                print("Successfully deleted tweet: \(tweetId)")
                                // The TweetListView will handle refreshing its content
                            }
                        },
                        isPinned: pinnedTweetIds.contains(tweet.mid),
                        isInProfile: true,
                        onAvatarTap: { user in selectedUser = user }
                    )
                }
            )
        }
    }
}

// MARK: - Supporting Views
@available(iOS 16.0, *)
private struct TweetsSectionHeader: View {
    var body: some View {
        VStack(spacing: 8) {
            Divider()
                .background(Color.gray.opacity(0.3))
                .padding(.vertical, 8)
            Text("Tweets")
                .font(.subheadline)
                .bold()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
        }
    }
}

@available(iOS 16.0, *)
private struct RegularTweetsView: View {
    let user: User
    let pinnedTweetIds: Set<String>
    let hproseInstance: HproseInstance
    let onUserSelect: (User) -> Void
    
    var body: some View {
        ScrollView {
            TweetListView<TweetItemView>(
                title: "",
                tweetFetcher: { page, size in
                    print("[RegularTweetsView] Fetching tweets page: \(page), size: \(size)")
                    // Match server's pagination strategy: increment by 11
                    let startRank = page * 11
                    let endRank = startRank + 10  // end is inclusive, so we add 10 to get 11 items
                    print("[RegularTweetsView] Fetching tweets with ranks: start=\(startRank), end=\(endRank)")
                    
                    let tweets = try await hproseInstance.fetchUserTweet(
                        user: user,
                        startRank: UInt(startRank),
                        endRank: UInt(endRank)
                    )
                    print("[RegularTweetsView] Received \(tweets.count) tweets")
                    // Convert [Tweet] to [Tweet?] as expected by TweetListView
                    return tweets.map { Optional($0) }
                },
                onRetweet: { tweet in
                    if let retweet = try? await hproseInstance.retweet(tweet) {
                        if let updatedOriginalTweet = try? await hproseInstance.updateRetweetCount(
                            tweet: tweet,
                            retweetId: retweet.mid
                        ) {
                            // Note: This update might need to be handled differently now
                            // since we're using TweetListView
                        }
                    }
                },
                onAvatarTap: { user in
                    onUserSelect(user)
                },
                showTitle: false,
                rowView: { tweet in
                    TweetItemView(
                        tweet: tweet,
                        retweet: { _ in },
                        deleteTweet: { tweet in
                            if let tweetId = try? await hproseInstance.deleteTweet(tweet.mid) {
                                print("Successfully deleted tweet: \(tweetId)")
                                // The TweetListView will handle refreshing its content
                            }
                        },
                        isPinned: pinnedTweetIds.contains(tweet.mid),
                        isInProfile: true,
                        onAvatarTap: { user in onUserSelect(user) }
                    )
                }
            )
        }
    }
}
