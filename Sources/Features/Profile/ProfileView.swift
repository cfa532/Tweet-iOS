import SwiftUI

struct ProfileView: View {
    let user: User
    let onLogout: (() -> Void)?
    @Binding var navigationPath: NavigationPath
    
    @EnvironmentObject private var hproseInstance: HproseInstance
    @Environment(\.dismiss) private var dismiss
    
    /// Navigation state
    @State private var showUserList = false
    @State private var showTweetList = false
    @State private var selectedTweetForNavigation: Tweet? = nil
    @State private var selectedUserForNavigation: User? = nil
    
    @State private var userListType: UserListType = .FOLLOWER
    @State private var tweetListType: TweetListType = .BOOKMARKS
    
    /// UI state
    @State private var showEditSheet = false
    @State private var showAvatarFullScreen = false
    @State private var showChatScreen = false
    @State private var showBlockUserMenu = false
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
    @State private var showLogoutConfirmation = false
    @State private var showDeleteAccountConfirmation = false
    
    // Scroll detection state
    @State private var isNavigationVisible = true
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ProfileTweetsSection(
                    pinnedTweets: pinnedTweets,
                    pinnedTweetIds: pinnedTweetIds,
                    user: user,
                    hproseInstance: hproseInstance,
                    onUserSelect: { _ in }, // Not used - NavigationLink handles user navigation
                    onTweetTap: { tweet in
                        // This should never be called since we'll use NavigationLink directly
                        print("DEBUG: [ProfileView] onTweetTap called - this should not happen")
                    },
                    onAvatarTapInProfile: { tappedUser in
                        // Check if the tapped avatar is the same as the profile user
                        if tappedUser.mid == user.mid {
                            // Same user - scroll to top
                            scrollToTop()
                        }
                        // Different user navigation is handled by NavigationLink in TweetItemView
                    },
                    onPinnedTweetsRefresh: refreshPinnedTweets,
                    onScroll: { offset, delta in
                        handleScroll(offset: offset, delta: delta)
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
                    ToastView(message: toastMessage, type: toastType)
                        .padding(.bottom, 48)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showToast)
        }
        .onAppear {
            // Calculate isFollowing by checking if the user's mid is in the app user's followingList
            isFollowing = (hproseInstance.appUser.followingList)?.contains(user.mid) ?? false
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
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
                    
                    Menu {
                        if !isAppUser {
                            Button(role: .destructive) {
                                Task {
                                    await handleBlockUser()
                                }
                            } label: {
                                Label(NSLocalizedString("Block User", comment: "Block user menu item"), systemImage: "slash.circle")
                            }
                        }
                        
                        if isAppUser {
                            Button(role: .destructive) {
                                showLogoutConfirmation = true
                            } label: {
                                Label(NSLocalizedString("Logout", comment: "Logout menu item"), systemImage: "rectangle.portrait.and.arrow.right")
                            }
                            
                            Button(role: .destructive) {
                                showDeleteAccountConfirmation = true
                            } label: {
                                Label(NSLocalizedString("Delete Account", comment: "Delete account menu item"), systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .rotationEffect(.degrees(90))
                            .foregroundColor(.primary)
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        .toolbar(isNavigationVisible ? .visible : .hidden, for: .navigationBar)
        .sheet(isPresented: $showEditSheet) {
            ProfileEditView(
                onSubmit: { username, password, alias, profile, hostId, cloudDrivePort in
                    // Set submission state
                    isSubmittingProfile = true
                    print("DEBUG: Profile update - username: \(username), alias: \(alias ?? "nil"), profile: \(profile ?? "nil"), hostId: \(hostId ?? "nil"), cloudDrivePort: \(cloudDrivePort)")
                    
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
                        hproseInstance.appUser.cloudDrivePort = cloudDrivePort
                        print("DEBUG: Updated cloudDrivePort to: \(cloudDrivePort)")
                        
                        // Clear user cache to ensure fresh data is loaded on next app launch
                        TweetCacheManager.shared.deleteUser(mid: hproseInstance.appUser.mid)
                        print("DEBUG: Cleared user cache for: \(hproseInstance.appUser.mid)")
                        
                        // Save updated user to cache with fresh data
                        TweetCacheManager.shared.saveUser(hproseInstance.appUser)
                        print("DEBUG: Saved updated user to cache")
                        
                        // Reset submission state
                        isSubmittingProfile = false
                    } else {
                        // Reset submission state
                        isSubmittingProfile = false
                        throw NSError(domain: "ProfileUpdate", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Profile update failed", comment: "Profile update error")])
                    }
                },
                onAvatarUploadStateChange: { isUploading in
                    isUploadingAvatar = isUploading
                },
                onAvatarUploadSuccess: {
                    showToastMessage(NSLocalizedString("Avatar updated successfully!", comment: "Avatar update success"), type: .success)
                    // Clear all avatar cache to ensure fresh images are loaded everywhere
                    ImageCacheManager.shared.clearAllAvatarCache()
                    // Force refresh all avatar images immediately by triggering a UI update
                    // Cache clear is synchronous, so we can notify immediately
                    hproseInstance.objectWillChange.send()
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
                
                // Fetch fresh user data from server
                do {
                    let refreshedUser = try await hproseInstance.fetchUser(user.mid, baseUrl: "")
                    print("DEBUG: [ProfileView] Successfully fetched user \(user.mid) from server")
                    
                    // Save updated user to cache if fetch was successful
                    if let refreshedUser = refreshedUser {
                        TweetCacheManager.shared.saveUser(refreshedUser)
                        print("DEBUG: [ProfileView] Saved fetched user to cache")
                    }
                } catch {
                    print("DEBUG: [ProfileView] Failed to fetch user \(user.mid): \(error)")
                }
                
                // Refresh pinned tweets
                await refreshPinnedTweets()
                
                isLoading = false
                didLoad = true
                
                // Resync user data on server in background (long-running operation)
                let userId = user.mid
                Task.detached {
                    do {
                        let resyncedUser = try await hproseInstance.resyncUser(userId: userId)
                        print("DEBUG: [ProfileView] Successfully resynced user \(userId) on server")
                        
                        // Save resynced user to cache
                        TweetCacheManager.shared.saveUser(resyncedUser)
                        print("DEBUG: [ProfileView] Saved resynced user to cache")
                    } catch {
                        print("DEBUG: [ProfileView] Failed to resync user \(userId): \(error)")
                    }
                }
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
                    // Only fetch all IDs once when page is 0
                    if page == 0 {
                        let entry: UserContentType = userListType == .FOLLOWER ? .FOLLOWER : .FOLLOWING
                        let ids = try await hproseInstance.getListByType(user: user, entry: entry)
                        // Update user properties on main thread to avoid publishing changes from background thread
                        await MainActor.run {
                            if userListType == .FOLLOWER {
                                user.fansList = ids
                            } else {
                                user.followingList = ids
                            }
                        }
                        return ids
                    } else {
                        return if userListType == .FOLLOWER {
                            user.fansList ?? []
                        } else {
                            user.followingList ?? []
                        }
                    }
                },
                navigationPath: $navigationPath,
                onFollowToggle: { user in
                    Task {
                        await handleToggleFollowing(for: user)
                    }
                }
            )
        }
        .navigationDestination(isPresented: $showTweetList) {
            print("🔵 [ProfileView] navigationDestination(showTweetList) TRIGGERED - type: \(tweetListType), user: \(user.username ?? "nil")")
            return bookmarksOrFavoritesListView()
                .onAppear {
                    print("🔵 [ProfileView] Bookmarks/Favorites list appeared - type: \(tweetListType), user: \(user.username ?? "nil")")
                    // Clear tweets when view appears to ensure fresh data
                    if tweetListType == .BOOKMARKS {
                        bookmarksTweets.removeAll()
                    } else {
                        favoritesTweets.removeAll()
                    }
                }
                .onDisappear {
                    print("🔵 [ProfileView] Bookmarks/Favorites list disappeared - type: \(tweetListType)")
                }
        }
        .navigationDestination(item: $selectedTweetForNavigation) { tweet in
            // Check if this is a comment (has originalTweetId but no content) vs quote tweet (has originalTweetId AND content)
            if tweet.originalTweetId != nil && (tweet.content?.isEmpty ?? true) && (tweet.attachments?.isEmpty ?? true) {
                // This is a comment (retweet with no content), show CommentDetailView with a parent fetcher
                CommentDetailViewWithParent(comment: tweet)
            } else {
                // This is a regular tweet or quote tweet, show TweetDetailView
                TweetDetailView(tweet: tweet)
            }
        }
        .navigationDestination(item: $selectedUserForNavigation) { user in
            print("🟢 [ProfileView] navigationDestination(selectedUser) TRIGGERED - navigating to user: \(user.username ?? "nil"), mid: \(user.mid)")
            print("🟢 [ProfileView] Current showTweetList value: \(showTweetList)")
            // Navigate to user's profile when avatar is tapped from favorites/bookmarks
            return ProfileView(user: user, onLogout: onLogout, navigationPath: $navigationPath)
                .onAppear {
                    print("🟢 [ProfileView] NEW user profile appeared: \(user.username ?? "nil")")
                }
        }
        .onChange(of: selectedUserForNavigation) { oldValue, newValue in
            print("🟡 [ProfileView] selectedUserForNavigation changed from \(oldValue?.username ?? "nil") to \(newValue?.username ?? "nil")")
            print("🟡 [ProfileView] Current showTweetList: \(showTweetList), will set to false")
            // When navigating to a user profile, dismiss the favorites/bookmarks list
            if newValue != nil {
                showTweetList = false
                print("🟡 [ProfileView] Set showTweetList = false")
            }
        }
        .onChange(of: showTweetList) { oldValue, newValue in
            print("🟠 [ProfileView] showTweetList changed from \(oldValue) to \(newValue) - user: \(user.username ?? "nil")")
        }
        .onChange(of: navigationPath.count) { oldCount, newCount in
            print("🟣 [ProfileView] navigationPath.count changed from \(oldCount) to \(newCount) - user: \(user.username ?? "nil")")
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
        .onAppear {
            // Ensure navigation is visible when view appears
            isNavigationVisible = true
            NotificationCenter.default.post(
                name: .navigationVisibilityChanged,
                object: nil,
                userInfo: ["isVisible": true]
            )
            print("DEBUG: [ProfileView] View appeared, navigation set to visible")
        }
        .onDisappear {
            // Reset navigation visibility when view disappears
            withAnimation(.easeInOut(duration: 0.3)) {
                isNavigationVisible = true
            }
            NotificationCenter.default.post(
                name: .navigationVisibilityChanged,
                object: nil,
                userInfo: ["isVisible": true]
            )
            print("DEBUG: [ProfileView] View disappeared, navigation reset to visible")
        }
        .alert(NSLocalizedString("Are you sure you want to logout?", comment: "Logout confirmation alert title"), isPresented: $showLogoutConfirmation) {
            Button(NSLocalizedString("Cancel", comment: "Cancel button"), role: .cancel) { }
            Button(NSLocalizedString("Logout", comment: "Logout button"), role: .destructive) {
                Task {
                    await handleLogout()
                }
            }
        } message: {
            Text(NSLocalizedString("This action cannot be undone.", comment: "Logout confirmation message"))
        }
        .alert(NSLocalizedString("Are you sure you want to delete your account?", comment: "Delete account confirmation alert title"), isPresented: $showDeleteAccountConfirmation) {
            Button(NSLocalizedString("Cancel", comment: "Cancel button"), role: .cancel) { }
            Button(NSLocalizedString("Delete Account", comment: "Delete account button"), role: .destructive) {
                Task {
                    await handleDeleteAccount()
                }
            }
        } message: {
            Text(NSLocalizedString("This action cannot be undone.", comment: "Delete account confirmation message"))
        }
        
    }
    
    // MARK: - Scroll Handling
    @State private var lastSignificantDelta: CGFloat = 0
    
    private func handleScroll(offset: CGFloat, delta: CGFloat) {
        // Threshold for detecting intentional scroll
        let scrollThreshold: CGFloat = 15
        
        // DON'T force show based on offset - ProfileView offset is often negative
        // Just rely on scroll direction (delta)
        
        // Ignore very small deltas (noise from rendering/layout)
        guard abs(delta) > 2 else { return }
        
        // Detect significant scroll direction changes
        // Positive delta = scrolling down (content moves up)
        // Negative delta = scrolling up (content moves down)
        let isScrollingDown = delta > scrollThreshold
        let isScrollingUp = delta < -scrollThreshold
        
        // Update navigation visibility based on scroll direction
        if isScrollingDown && isNavigationVisible {
            // Scrolling down significantly - hide bottom bar
            withAnimation(.easeInOut(duration: 0.25)) {
                isNavigationVisible = false
            }
            NotificationCenter.default.post(
                name: .navigationVisibilityChanged,
                object: nil,
                userInfo: ["isVisible": false]
            )
            lastSignificantDelta = delta
        } else if isScrollingUp && !isNavigationVisible {
            // Scrolling up significantly - show bottom bar
            withAnimation(.easeInOut(duration: 0.4)) {
                isNavigationVisible = true
            }
            NotificationCenter.default.post(
                name: .navigationVisibilityChanged,
                object: nil,
                userInfo: ["isVisible": true]
            )
            lastSignificantDelta = delta
        }
        
        previousScrollOffset = offset
    }
    
    // MARK: - Helper Methods
    
    private func scrollToTop() {
        // Scroll to top of the profile view
        // This will be handled by the ScrollViewReader in ProfileTweetsSection
        print("DEBUG: [ProfileView] Scroll to top requested")
        NotificationCenter.default.post(name: .scrollToTop, object: nil)
    }
    
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
                    
                    // Fetch and add recent tweets from newly followed user to main feed
                    Task {
                        await FollowingsTweetViewModel.shared.addTweetsFromNewlyFollowedUser(user)
                    }
                } else {
                    // User is no longer following - remove app user from followed user's fansList
                    user.fansList?.removeAll { $0 == hproseInstance.appUser.mid }
                    // Decrement the followed user's followers count
                    user.followersCount = max(0, (user.followersCount ?? 0) - 1)
                    print("DEBUG: [ProfileView] Decremented followers count for user \(user.mid): \(oldFollowersCount ?? 0) -> \(user.followersCount ?? 0)")
                    
                    // Remove unfollowed user's tweets from main feed
                    FollowingsTweetViewModel.shared.removeTweetsFromUser(user.mid)
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
    
    // MARK: - Block User Handling
    private func handleBlockUser() async {
        do {
            // Call the backend to block the user
            try await hproseInstance.blockUser(userId: user.mid)
            
            await MainActor.run {
                // Remove the user from following list if they are being followed
                if let followingList = hproseInstance.appUser.followingList,
                   followingList.contains(user.mid) {
                    hproseInstance.appUser.followingList = followingList.filter { $0 != user.mid }
                    // Update the following count
                    hproseInstance.appUser.followingCount = (hproseInstance.appUser.followingCount ?? 0) - 1
                }
                
                // Add the user to the blacklist
                var currentBlackList = hproseInstance.appUser.userBlackList ?? []
                if !currentBlackList.contains(user.mid) {
                    currentBlackList.append(user.mid)
                    hproseInstance.appUser.userBlackList = currentBlackList
                }
            }
            
            // Show success message
            await MainActor.run {
                showToastMessage(NSLocalizedString("User blocked successfully", comment: "User blocked success message"), type: .success)
            }
            
            // Navigate back to previous screen
            await MainActor.run {
                dismiss()
            }
            
        } catch {
            // Show error message
            await MainActor.run {
                showToastMessage(String(format: NSLocalizedString("Failed to block user: %@", comment: "Block user error message"), ErrorMessageHelper.userFriendlyMessage(from: error)), type: .error)
            }
        }
    }
    
    // MARK: - Logout Handling
    private func handleLogout() async {
        // Use the same logout logic as Settings
        await hproseInstance.logout()
        await MainActor.run {
            NotificationCenter.default.post(name: .userDidLogout, object: nil)
            
            // Show success message
            showToastMessage(NSLocalizedString("Logged out successfully", comment: "Logout success message"), type: .success)
            
            // Call the onLogout callback if provided
            if let onLogout = onLogout {
                onLogout()
            }
        }
    }
    
    // MARK: - Delete Account Handling
    private func handleDeleteAccount() async {
        do {
            // Call the backend to delete the account
            let result = try await hproseInstance.deleteAccount()
            
            if let success = result["success"] as? Bool, success {
                // Clear all cached data
                TweetCacheManager.shared.clearAllCache()
                ImageCacheManager.shared.clearAllCache()
                
                // Use the same logout logic as Settings to reset the app state
                await hproseInstance.logout()
                
                await MainActor.run {
                    // Show success message first
                    showToastMessage(NSLocalizedString("Account deleted successfully", comment: "Account deletion success message"), type: .success)
                    
                    NotificationCenter.default.post(name: .userDidLogout, object: nil)
                    
                    // Call the onLogout callback if provided
                    if let onLogout = onLogout {
                        onLogout()
                    }
                }
            } else {
                await MainActor.run {
                    // Handle failure case
                    let errorMessage = result["message"] as? String ?? "Unknown error occurred"
                    showToastMessage(String(format: NSLocalizedString("Failed to delete account: %@", comment: "Delete account error message"), errorMessage), type: .error)
                }
            }
            
        } catch {
            // Show error message
            await MainActor.run {
                showToastMessage(String(format: NSLocalizedString("Failed to delete account: %@", comment: "Delete account error message"), ErrorMessageHelper.userFriendlyMessage(from: error)), type: .error)
            }
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
                    TweetItemView(
                        tweet: tweet,
                        showDeleteButton: isAppUser,
                        onAvatarTap: { tappedUser in
                            print("🔴 [ProfileView-Bookmarks] Avatar tapped - user: \(tappedUser.username ?? "nil"), mid: \(tappedUser.mid)")
                            print("🔴 [ProfileView-Bookmarks] Current showTweetList: \(showTweetList), current user: \(user.username ?? "nil")")
                            selectedUserForNavigation = tappedUser
                        },
                        onTap: { selectedTweet in
                            selectedTweetForNavigation = selectedTweet
                        }
                    )
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
                    TweetItemView(
                        tweet: tweet,
                        showDeleteButton: isAppUser,
                        onAvatarTap: { tappedUser in
                            print("🔴 [ProfileView-Favorites] Avatar tapped - user: \(tappedUser.username ?? "nil"), mid: \(tappedUser.mid)")
                            print("🔴 [ProfileView-Favorites] Current showTweetList: \(showTweetList), current user: \(user.username ?? "nil")")
                            selectedUserForNavigation = tappedUser
                        },
                        onTap: { selectedTweet in
                            selectedTweetForNavigation = selectedTweet
                        }
                    )
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
