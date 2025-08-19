import SwiftUI

struct ProfileView: View {
    let user: User
    let onLogout: (() -> Void)?
    
    @EnvironmentObject private var hproseInstance: HproseInstance
    @Environment(\.dismiss) private var dismiss
    
    /// Navigation state
    @State private var selectedUser: User? = nil
    @State private var showUserList = false
    @State private var showTweetList = false

    @State private var userListType: UserListType = .FOLLOWER
    @State private var tweetListType: TweetListType = .BOOKMARKS
    
    /// UI state
    @State private var showEditSheet = false
    @State private var showAvatarFullScreen = false
    @State private var showChatScreen = false
    @State private var previousScrollOffset: CGFloat = 0
    @State private var isLoading = false
    @State private var didLoad = false
    
    /// Pinned tweets state
    @State private var pinnedTweets: [Tweet] = []
    @State private var pinnedTweetIds: Set<String> = []
    
    /// Bookmarks and favorites tweets state
    @State private var bookmarksTweets: [Tweet] = []
    @State private var favoritesTweets: [Tweet] = []
    
    /// Indicates if avatar is currently being uploaded
    @State private var isUploadingAvatar = false
    /// Indicates if profile data is currently being submitted
    @State private var isSubmittingProfile = false
    /// Toast message states
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .success
    
    /// Computed properties
    private var isAppUser: Bool {
        user.mid == hproseInstance.appUser.mid
    }
    
    @State private var isFollowing: Bool = false
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ProfileTweetsSection(
                    pinnedTweets: pinnedTweets,
                    pinnedTweetIds: pinnedTweetIds,
                    user: user,
                    hproseInstance: hproseInstance,
                    onUserSelect: { user in selectedUser = user },
                    onTweetTap: { tweet in
                        // This should never be called since we'll use NavigationLink directly
                        print("DEBUG: [ProfileView] onTweetTap called - this should not happen")
                    },
                    onPinnedTweetsRefresh: refreshPinnedTweets,
                    onScroll: { offset in
                        previousScrollOffset = offset
                    },
                    header: {
                        VStack(spacing: 0) {
                            ProfileHeaderSection(
                                user: user,
                                isCurrentUser: isAppUser,
                                isFollowing: isFollowing,
                                onEditTap: { showEditSheet = true },
                                onFollowToggle: {
                                    isFollowing.toggle()
                                    Task {
                                        await handleToggleFollowing(for: user, isFollowing: $isFollowing)
                                    }
                                },
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
                                    bookmarksTweets.removeAll() // Clear previous data
                                    showTweetList = true
                                },
                                onFavoritesTap: {
                                    tweetListType = .FAVORITES
                                    favoritesTweets.removeAll() // Clear previous data
                                    showTweetList = true
                                }
                            )
                        }
                        .padding(.top, 2)
                    }
                )
                .id(user.mid)
                .padding(.leading, -4)
            }
            .allowsHitTesting(!isUploadingAvatar && !isSubmittingProfile)
            
            // Loading overlay for avatar upload and profile submission
            if isUploadingAvatar || isSubmittingProfile {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            
                            Text(isUploadingAvatar ? "Updating avatar..." : "Updating profile...")
                                .foregroundColor(.white)
                                .font(.headline)
                                .fontWeight(.medium)
                                .multilineTextAlignment(.center)
                        }
                        .padding(24)
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(12)
                        Spacer()
                    }
                    Spacer()
                }
                .allowsHitTesting(true)
            }
            
            // Toast overlay
            VStack {
                Spacer()
                if showToast {
                    Text(toastMessage)
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(8)
                        .padding(.bottom, 20)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showToast)
        }
        .onAppear {
            // Calculate isFollowing by checking if the user's mid is in the app user's followingList
            isFollowing = hproseInstance.appUser.followingList?.contains(user.mid) ?? false
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    if !isAppUser {
                        Button {
                            showChatScreen = true
                        } label: {
                            Image(systemName: "message")
                                .foregroundColor(.blue)
                        }
                    }
                    
                    if isAppUser {
                        // show nothing for now.
                    }
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            ProfileEditView(
                onSubmit: { username, password, alias, profile, hostId, cloudDrivePort in
                    // Set submission state
                    isSubmittingProfile = true
                    print("DEBUG: Profile update - username: \(username), alias: \(alias ?? "nil"), profile: \(profile ?? "nil"), hostId: \(hostId ?? "nil"), cloudDrivePort: \(cloudDrivePort?.description ?? "nil")")
                    
                    let success = try await hproseInstance.updateUserCore(
                        password: password, alias: alias, profile: profile, hostId: hostId, cloudDrivePort: cloudDrivePort
                    )
                    print("DEBUG: Profile update result: \(success)")
                    
                    if success {
                        // Update local user data
                        if let alias = alias, !alias.isEmpty {
                            hproseInstance.appUser.name = alias
                            print("DEBUG: Updated name to: \(alias)")
                        }
                        if let profile = profile, !profile.isEmpty {
                            hproseInstance.appUser.profile = profile
                            print("DEBUG: Updated profile to: \(profile)")
                        }
                        if let hostId = hostId, !hostId.isEmpty {
                            hproseInstance.appUser.hostIds = [hostId]
                            print("DEBUG: Updated hostIds to: [\(hostId)]")
                        }
                        if let cloudDrivePort = cloudDrivePort {
                            hproseInstance.appUser.cloudDrivePort = cloudDrivePort
                            print("DEBUG: Updated cloudDrivePort to: \(cloudDrivePort)")
                        }
                        
                        // Clear user cache to ensure fresh data is loaded on next app launch
                        TweetCacheManager.shared.deleteUser(mid: hproseInstance.appUser.mid)
                        print("DEBUG: Cleared user cache for: \(hproseInstance.appUser.mid)")
                        
                        // Save updated user to cache with fresh data
                        TweetCacheManager.shared.saveUser(hproseInstance.appUser)
                        print("DEBUG: Saved updated user to cache")
                        
                        // Force refresh user data from server to ensure consistency
                        Task {
                            do {
                                _ = try await hproseInstance.fetchUser(hproseInstance.appUser.mid, baseUrl: "")
                                print("DEBUG: Forced refresh of user data from server")
                            } catch {
                                print("DEBUG: Failed to refresh user data: \(error)")
                            }
                        }
                        
                        // Reset submission state
                        isSubmittingProfile = false
                    } else {
                        // Reset submission state
                        isSubmittingProfile = false
                        throw NSError(domain: "ProfileUpdate", code: -1, userInfo: [NSLocalizedDescriptionKey: "Profile update failed"])
                    }
                },
                onAvatarUploadStateChange: { isUploading in
                    isUploadingAvatar = isUploading
                },
                onAvatarUploadSuccess: {
                    showToastMessage("Avatar updated successfully!", type: .success)
                    // Clear all avatar cache to ensure fresh images are loaded everywhere
                    ImageCacheManager.shared.clearAllAvatarCache()
                    // Force refresh all avatar images by triggering a UI update
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        // This will trigger the Avatar view to reload due to the .id(user.mid) modifier
                        hproseInstance.objectWillChange.send()
                    }
                },
                onAvatarUploadFailure: { errorMessage in
                    showToastMessage(errorMessage, type: .error)
                },
                onProfileUpdateFailure: { errorMessage in
                    showToastMessage(errorMessage, type: .error)
                }
            )
        }
        .fullScreenCover(isPresented: $showAvatarFullScreen) {
            AvatarFullScreenView(user: user, isPresented: $showAvatarFullScreen)
        }
        .fullScreenCover(isPresented: $showChatScreen) {
            ChatScreen(receiptId: user.mid)
        }
        .task {
            if !didLoad {
                isLoading = true
                _ = try? await hproseInstance.fetchUser(user.mid, baseUrl: "") // force user to reload from server
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
            let displayName = if let name = user.name, !name.isEmpty {
                name
            } else {
                user.username ?? "No One"
            }
            UserListView(
                title: userListType == .FOLLOWER ? "Fans@\(displayName)" : "Followings@\(displayName)",
                userFetcher: { page, size in
                    let entry: UserContentType = userListType == .FOLLOWER ? .FOLLOWER : .FOLLOWING
                    let ids = try await hproseInstance.getFollows(user: user, entry: entry)
                    let startIndex = page * size
                    let endIndex = min(startIndex + size, ids.count)
                    guard startIndex < endIndex else { return [] }
                    return Array(ids[startIndex..<endIndex])
                },
                onFollowToggle: { user in
                    Task {
                        await handleToggleFollowing(for: user)
                    }
                }
            )
        }
        .navigationDestination(isPresented: $showTweetList) {
            bookmarksOrFavoritesListView()
                .onAppear {
                    // Clear tweets when view appears to ensure fresh data
                    if tweetListType == .BOOKMARKS {
                        bookmarksTweets.removeAll()
                    } else {
                        favoritesTweets.removeAll()
                    }
                }
        }

        .onReceive(NotificationCenter.default.publisher(for: .bookmarkAdded)) { notification in
            if let tweet = notification.userInfo?["tweet"] as? Tweet,
               isAppUser {
                // Add tweet to bookmarks list if it's not already there
                if !bookmarksTweets.contains(where: { $0.mid == tweet.mid }) {
                    bookmarksTweets.insert(tweet, at: 0)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookmarkRemoved)) { notification in
            if let tweet = notification.userInfo?["tweet"] as? Tweet,
               isAppUser {
                // Remove tweet from bookmarks list
                bookmarksTweets.removeAll { $0.mid == tweet.mid }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .favoriteAdded)) { notification in
            if let tweet = notification.userInfo?["tweet"] as? Tweet,
               isAppUser {
                // Add tweet to favorites list if it's not already there
                if !favoritesTweets.contains(where: { $0.mid == tweet.mid }) {
                    favoritesTweets.insert(tweet, at: 0)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .favoriteRemoved)) { notification in
            if let tweet = notification.userInfo?["tweet"] as? Tweet,
               isAppUser {
                // Remove tweet from favorites list
                favoritesTweets.removeAll { $0.mid == tweet.mid }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tweetDeleted)) { notification in
            if let deletedTweetId = notification.userInfo?["tweetId"] as? String {
                // Check if the deleted tweet was in the pinned list
                if pinnedTweetIds.contains(deletedTweetId) {
                    // Remove from pinned tweets
                    pinnedTweets.removeAll { $0.mid == deletedTweetId }
                    pinnedTweetIds.remove(deletedTweetId)
                    print("DEBUG: [ProfileView] Removed deleted tweet \(deletedTweetId) from pinned tweets")
                } else {
                    // Tweet was in regular list, will be handled by ProfileTweetsViewModel
                    print("DEBUG: [ProfileView] Deleted tweet \(deletedTweetId) was in regular tweets list")
                }
            }
        }

    }
    
    // MARK: - Helper Methods
    
    private func showToastMessage(_ message: String, type: ToastView.ToastType) {
        toastMessage = message
        toastType = type
        showToast = true
        
        // Auto-hide toast after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            showToast = false
        }
    }
    
    private func handleToggleFollowing(for user: User, isFollowing: Binding<Bool>? = nil) async {
        if let ret = try? await hproseInstance.toggleFollowing(followingId: user.mid) {
            // Update the isFollowing binding if provided
            if let isFollowing = isFollowing {
                isFollowing.wrappedValue = ret
            }
            
            // Update app user's followingList based on the result
            if ret {
                // User is now following - add to followingList
                if hproseInstance.appUser.followingList == nil {
                    hproseInstance.appUser.followingList = []
                }
                if !hproseInstance.appUser.followingList!.contains(user.mid) {
                    hproseInstance.appUser.followingList!.append(user.mid)
                }
            } else {
                // User is no longer following - remove from followingList
                hproseInstance.appUser.followingList?.removeAll { $0 == user.mid }
            }
            
            // Update the followed user's fansList and counts on main thread
            await MainActor.run {
                let oldFollowersCount = user.followersCount
                let oldFollowingCount = hproseInstance.appUser.followingCount
                
                print("DEBUG: [ProfileView] Before update - user \(user.mid) followers count: \(oldFollowersCount ?? 0)")
                
                if ret {
                    // User is now following - add app user to followed user's fansList
                    if user.fansList == nil {
                        user.fansList = []
                    }
                    if !user.fansList!.contains(hproseInstance.appUser.mid) {
                        user.fansList!.append(hproseInstance.appUser.mid)
                    }
                    // Increment the followed user's followers count
                    user.followersCount = (user.followersCount ?? 0) + 1
                    print("DEBUG: [ProfileView] Incremented followers count for user \(user.mid): \(oldFollowersCount ?? 0) -> \(user.followersCount ?? 0)")
                } else {
                    // User is no longer following - remove app user from followed user's fansList
                    user.fansList?.removeAll { $0 == hproseInstance.appUser.mid }
                    // Decrement the followed user's followers count
                    user.followersCount = max(0, (user.followersCount ?? 0) - 1)
                    print("DEBUG: [ProfileView] Decremented followers count for user \(user.mid): \(oldFollowersCount ?? 0) -> \(user.followersCount ?? 0)")
                }
                
                // Update app user's following count
                if ret {
                    // User is now following - increment app user's following count
                    hproseInstance.appUser.followingCount = (hproseInstance.appUser.followingCount ?? 0) + 1
                    print("DEBUG: [ProfileView] Incremented app user following count: \(oldFollowingCount ?? 0) -> \(hproseInstance.appUser.followingCount ?? 0)")
                } else {
                    // User is no longer following - decrement app user's following count
                    hproseInstance.appUser.followingCount = max(0, (hproseInstance.appUser.followingCount ?? 0) - 1)
                    print("DEBUG: [ProfileView] Decremented app user following count: \(oldFollowingCount ?? 0) -> \(hproseInstance.appUser.followingCount ?? 0)")
                }
                
                print("DEBUG: [ProfileView] After update - user \(user.mid) followers count: \(user.followersCount ?? 0)")
            }
        } else {
            // Revert the isFollowing binding if provided
            if let isFollowing = isFollowing {
                isFollowing.wrappedValue.toggle()
            }
            showToastMessage(NSLocalizedString("Failed to toggle following status", comment: "Profile action error"), type: .error)
        }
    }
    
    private func refreshPinnedTweets() async {
        print("DEBUG: [ProfileView] Starting to refresh pinned tweets for user: \(user.mid)")
        do {
            let pinnedTweetData = try await hproseInstance.getPinnedTweets(user: user)
            print("DEBUG: [ProfileView] Got \(pinnedTweetData.count) pinned tweet data items from server")
            
            var pinnedTweets: [Tweet] = []
            var pinnedTweetIds: [String] = []
            
            // Extract tweets and IDs from the response
            for (index, tweetData) in pinnedTweetData.enumerated() {
                print("DEBUG: [ProfileView] Processing pinned tweet data item \(index): \(tweetData)")
                if let tweet = tweetData["tweet"] as? Tweet {
                    print("DEBUG: [ProfileView] Successfully extracted tweet: \(tweet.mid)")
                    pinnedTweets.append(tweet)
                    pinnedTweetIds.append(tweet.mid)
                } else {
                    print("DEBUG: [ProfileView] Failed to extract tweet from data item \(index)")
                }
            }
            
            print("DEBUG: [ProfileView] Final pinned tweets count: \(pinnedTweets.count), IDs: \(pinnedTweetIds)")
            
            await MainActor.run {
                self.pinnedTweetIds = Set(pinnedTweetIds)
                self.pinnedTweets = pinnedTweets
                print("DEBUG: [ProfileView] Updated pinned tweets state - count: \(self.pinnedTweets.count), IDs: \(self.pinnedTweetIds)")
            }
        } catch {
            print("DEBUG: [ProfileView] Failed to refresh pinned tweets: \(error)")
        }
    }
    
    @ViewBuilder
    private func bookmarksOrFavoritesListView() -> some View {
        if tweetListType == .BOOKMARKS {
            TweetListView(
                title: "Bookmarks",
                tweets: $bookmarksTweets,
                tweetFetcher: { page, size, isFromCache, shouldCache in
                    print("DEBUG: [ProfileView] Fetching bookmarks - page: \(page), size: \(size), isFromCache: \(isFromCache), shouldCache: \(shouldCache)")
                    if isFromCache {
                        // For bookmarks/favorites, we don't cache, so return empty array
                        print("DEBUG: [ProfileView] Cache requested for bookmarks, returning empty array")
                        return []
                    } else {
                        let tweets = try await hproseInstance.getUserTweetsByType(user: user, type: .BOOKMARKS, pageNumber: page, pageSize: size)
                        print("DEBUG: [ProfileView] Got \(tweets.count) bookmarks tweets, valid: \(tweets.compactMap { $0 }.count)")
                        return tweets
                    }
                },
                shouldCacheServerTweets: false,
                rowView: { tweet in
                    NavigationLink(value: tweet) {
                        TweetItemView(
                            tweet: tweet,
                            showDeleteButton: isAppUser,
                            onAvatarTap: { user in selectedUser = user },
                            onTap: nil // NavigationLink will handle the tap
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            )
        } else {
            TweetListView(
                title: "Favorites",
                tweets: $favoritesTweets,
                tweetFetcher: { page, size, isFromCache, shouldCache in
                    print("DEBUG: [ProfileView] Fetching favorites - page: \(page), size: \(size), isFromCache: \(isFromCache), shouldCache: \(shouldCache)")
                    if isFromCache {
                        // For favorites, we don't cache, so return empty array
                        print("DEBUG: [ProfileView] Cache requested for favorites, returning empty array")
                        return []
                    } else {
                        let tweets = try await hproseInstance.getUserTweetsByType(user: user, type: .FAVORITES, pageNumber: page, pageSize: size)
                        print("DEBUG: [ProfileView] Got \(tweets.count) favorites tweets, valid: \(tweets.compactMap { $0 }.count)")
                        return tweets
                    }
                },
                shouldCacheServerTweets: false,
                rowView: { tweet in
                    NavigationLink(value: tweet) {
                        TweetItemView(
                            tweet: tweet,
                            showDeleteButton: isAppUser,
                            onAvatarTap: { user in selectedUser = user },
                            onTap: nil // NavigationLink will handle the tap
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            )
        }
    }
}

enum UserListType {
    case FOLLOWER
    case FOLLOWING
}

enum TweetListType {
    case BOOKMARKS
    case FAVORITES
} 
