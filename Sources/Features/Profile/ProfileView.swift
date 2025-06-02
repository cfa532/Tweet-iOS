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
    /// Tracks the scroll position for header collapse
    @State private var scrollOffset: CGFloat = 0
    /// Previous scroll offset for determining scroll direction
    @State private var previousScrollOffset: CGFloat = 0
    /// Controls header visibility
    @State private var isHeaderVisible = true

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
            // Collapsible header and stats
            VStack(spacing: 0) {
                ProfileHeaderSection(
                    user: user,
                    isCurrentUser: isCurrentUser,
                    isFollowing: isFollowing,
                    onEditTap: { showEditSheet = true },
                    onFollowToggle: { isFollowing.toggle() },
                    onAvatarTap: { showAvatarFullScreen = true }
                )
                ProfileStatsSection(
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
            }
            .opacity(isHeaderVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: isHeaderVisible)

            // Only the tweet list is scrollable and refreshable
            ProfileTweetsSection(
                isLoading: isLoading,
                pinnedTweets: pinnedTweets,
                pinnedTweetIds: pinnedTweetIds,
                user: user,
                hproseInstance: hproseInstance,
                onUserSelect: { user in selectedUser = user },
                onPinnedTweetsRefresh: refreshPinnedTweets,
                onScroll: { offset in
                    // Show header if at the top or scrolling up
                    let shouldShowHeader = offset >= 0 || offset > previousScrollOffset
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isHeaderVisible = shouldShowHeader
                    }
                    previousScrollOffset = offset
                }
            )
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
                await refreshPinnedTweets()
                isLoading = false
                didLoad = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tweetPinStatusChanged)) { notification in
            if let _ = notification.userInfo?["tweetId"] as? String,
               let _ = notification.userInfo?["isPinned"] as? Bool {
                Task {
                    await refreshPinnedTweets()
                }
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
            TweetListView<TweetItemView>(
                title: tweetListType == .BOOKMARKS ? "Bookmarks" : "Favorites",
                tweetFetcher: { page, size in
                    try await hproseInstance.fetchUserTweet(
                        user: user,
                        startRank: UInt(page * size),
                        endRank: UInt((page + 1) * size - 1)
                    )
                },
                showTitle: true,
                rowView: { tweet in
                    TweetItemView(
                        tweet: tweet,
                        isPinned: pinnedTweetIds.contains(tweet.mid),
                        isInProfile: true,
                        onAvatarTap: { user in selectedUser = user }
                    )
                }
            )
        }
    }
}

// MARK: - Scroll Offset Preference Key
private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
