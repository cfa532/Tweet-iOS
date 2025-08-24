import SwiftUI

struct ProfileView: View {
    let user: User
    let onLogout: (() -> Void)?
    @Binding var navigationPath: NavigationPath
    
    @EnvironmentObject private var hproseInstance: HproseInstance
    @Environment(\.dismiss) private var dismiss
    
    /// Navigation state
    @State private var selectedUser: User? = nil
    @State private var showUserList = false
    @State private var showTweetList = false
    @State private var selectedTweetForNavigation: Tweet? = nil

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
                    onUserSelect: { user in selectedUser = user },
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
                    onScroll: { offset in
                        handleScroll(offset: offset)
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
            
            // Refresh user data from backend every time profile is opened
            Task {
                do {
                    _ = try await hproseInstance.fetchUser(user.mid, baseUrl: "")
                    print("DEBUG: [ProfileView] Refreshed user data from backend for user: \(user.mid)")
                } catch {
                    print("DEBUG: [ProfileView] Failed to refresh user data: \(error)")
                }
            }
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
            // Clean up timer
            scrollEndTimer?.invalidate()
            scrollEndTimer = nil
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
    @State private var scrollEndTimer: Timer?
    @State private var lastScrollTime: Date = Date()
    @State private var isActivelyScrolling: Bool = false
    @State private var consecutiveSmallMovements: Int = 0
    @State private var lastSignificantMovementTime: Date = Date()
    @State private var hasStartedInertiaScrolling: Bool = false
    
    private func handleScroll(offset: CGFloat) {
        print("[ProfileView] handleScroll called with offset: \(offset)")
        
        let currentTime = Date()
        let timeSinceLastScroll = currentTime.timeIntervalSince(lastScrollTime)
        let timeSinceLastSignificantMovement = currentTime.timeIntervalSince(lastSignificantMovementTime)
        lastScrollTime = currentTime
        
        // Cancel any existing timer
        scrollEndTimer?.invalidate()
        
        // Calculate scroll direction and threshold
        let scrollDelta = offset - previousScrollOffset
        let scrollThreshold: CGFloat = 30 // Single threshold for both scroll directions
        
        // Determine if we're actively scrolling (significant movement within short time)
        let isSignificantMovement = abs(scrollDelta) > scrollThreshold
        let isRecentMovement = timeSinceLastScroll < 0.1 // Within 100ms
        
        // Track consecutive small movements (potential inertia stop attempts)
        if isSignificantMovement {
            consecutiveSmallMovements = 0
            lastSignificantMovementTime = currentTime
            isActivelyScrolling = true
            hasStartedInertiaScrolling = false
        } else {
            consecutiveSmallMovements += 1
            // If we have significant movement followed by small movements, we might be in inertia scrolling
            if isActivelyScrolling && consecutiveSmallMovements > 2 {
                hasStartedInertiaScrolling = true
            }
        }
        
        // If we have many consecutive small movements or it's been a while since significant movement,
        // we might be in an inertia stop scenario - don't change navigation state
        let isInertiaStopScenario = consecutiveSmallMovements > 3 || timeSinceLastSignificantMovement > 0.5
        
        print("[ProfileView] Scroll delta: \(scrollDelta), previous offset: \(previousScrollOffset), timeSinceLastScroll: \(timeSinceLastScroll), consecutiveSmallMovements: \(consecutiveSmallMovements), isInertiaStopScenario: \(isInertiaStopScenario), hasStartedInertiaScrolling: \(hasStartedInertiaScrolling)")
        
        // Determine scroll direction with threshold
        let isScrollingDown = scrollDelta < -scrollThreshold
        let isScrollingUp = scrollDelta > scrollThreshold
        
        print("[ProfileView] isScrollingDown: \(isScrollingDown), isScrollingUp: \(isScrollingUp), isActivelyScrolling: \(isActivelyScrolling)")
        
        // Only change navigation state if we're actively scrolling AND not in an inertia stop scenario AND not in inertia scrolling
        if isActivelyScrolling && !isInertiaStopScenario && !hasStartedInertiaScrolling {
            // Determine if we should show navigation
            let shouldShowNavigation: Bool
            
            if offset >= 0 {
                // Always show when at the top (or initial state)
                shouldShowNavigation = true
            } else if isScrollingDown && isNavigationVisible {
                // Scrolling down and navigation is visible - hide it
                shouldShowNavigation = false
            } else if isScrollingUp && !isNavigationVisible {
                // Scrolling up and navigation is hidden - show it
                shouldShowNavigation = true
            } else {
                // Keep current state for small movements or when already in desired state
                shouldShowNavigation = isNavigationVisible
            }
            
            print("[ProfileView] Current isNavigationVisible: \(isNavigationVisible), shouldShowNavigation: \(shouldShowNavigation)")
            
            // Only update if the state actually changed
            if shouldShowNavigation != isNavigationVisible {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isNavigationVisible = shouldShowNavigation
                }
                // Notify parent about navigation visibility change
                NotificationCenter.default.post(
                    name: .navigationVisibilityChanged,
                    object: nil,
                    userInfo: ["isVisible": shouldShowNavigation]
                )
                
                print("[ProfileView] Navigation visibility changed to: \(shouldShowNavigation) - Scroll delta: \(scrollDelta), offset: \(offset)")
            }
        }
        
        previousScrollOffset = offset
        
        // Set a timer to handle scroll end - if no more scroll events come in for 0.3 seconds,
        // we can assume the scroll has ended and maintain the current state
        scrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            print("[ProfileView] Scroll end timer fired - maintaining current navigation state")
            isActivelyScrolling = false
            consecutiveSmallMovements = 0
            hasStartedInertiaScrolling = false
            // Don't change the navigation state when scroll ends
            // Let it remain in its current state
        }
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
                showToastMessage(String(format: NSLocalizedString("Failed to block user: %@", comment: "Block user error message"), error.localizedDescription), type: .error)
            }
        }
    }
    
    // MARK: - Logout Handling
    private func handleLogout() async {
        await MainActor.run {
            // Use the same logout logic as Settings
            hproseInstance.logout()
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
            
            await MainActor.run {
                if let success = result["success"] as? Bool, success {
                    // Show success message first
                    showToastMessage(NSLocalizedString("Account deleted successfully", comment: "Account deletion success message"), type: .success)
                    
                    // Clear all cached data
                    TweetCacheManager.shared.clearAllCache()
                    ImageCacheManager.shared.clearAllCache()
                    
                    // Use the same logout logic as Settings to reset the app state
                    hproseInstance.logout()
                    NotificationCenter.default.post(name: .userDidLogout, object: nil)
                    
                    // Call the onLogout callback if provided
                    if let onLogout = onLogout {
                        onLogout()
                    }
                } else {
                    // Handle failure case
                    let errorMessage = result["message"] as? String ?? "Unknown error occurred"
                    showToastMessage(String(format: NSLocalizedString("Failed to delete account: %@", comment: "Delete account error message"), errorMessage), type: .error)
                }
            }
            
        } catch {
            // Show error message
            await MainActor.run {
                showToastMessage(String(format: NSLocalizedString("Failed to delete account: %@", comment: "Delete account error message"), error.localizedDescription), type: .error)
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
                        onAvatarTap: { user in selectedUser = user },
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
                        onAvatarTap: { user in selectedUser = user },
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
