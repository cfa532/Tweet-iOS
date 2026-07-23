import SwiftUI

struct ProfileView: View {
    let user: User
    let onLogout: (() -> Void)?
    @Binding var navigationPath: NavigationPath
    let onShowLogin: (() -> Void)?
    let onShowToast: ((String, Bool) -> Void)?

    /// Use singleton so ProfileView works when presented from detached view controllers (e.g. after MediaBrowserView).
    @ObservedObject private var hproseInstance = HproseInstance.shared
    @Environment(\.dismiss) private var dismiss
    
    /// Navigation state
    @State private var selectedUserForNavigation: User? = nil
    @State private var userListDestination: UserListDestination? = nil
    
    @State private var userListType: UserListType = .FOLLOWER
    
    /// UI state
    @State private var showEditSheet = false
    @State private var showAvatarFullScreen = false
    @State private var showChatScreen = false
    @State private var chatNavigationPath = NavigationPath()
    @State private var showBlockUserMenu = false
    @State private var previousScrollOffset: CGFloat = 0
    @State private var didLoad = false
    /// Bumped when stale-IP recovery changes this profile's read route so tweets reload without clearing cached content.
    @State private var profileTweetsRefreshToken = 0
    @State private var resyncedTweets: [Tweet] = []
    @State private var resyncedTweetsToken = 0
    @StateObject private var profileHeaderState = ProfileHeaderState()
    
    /// Pinned tweets state
    @State private var pinnedTweets: [Tweet] = []
    @State private var pinnedTweetIds: Set<String> = []
    
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

    private var blockUserDisplayName: String {
        if let username = user.username?.trimmingCharacters(in: .whitespacesAndNewlines),
           !username.isEmpty {
            return "@\(username)"
        }
        if let name = user.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return NSLocalizedString("this user", comment: "Fallback name in block confirmation")
    }
    
    // Scroll detection state
    @State private var isNavigationVisible = true
    
    var body: some View {
        contentWithNavigation
            .sheet(isPresented: $showEditSheet, onDismiss: handleSheetDismiss) {
                profileEditSheet
            }
            .fullScreenCover(isPresented: $showAvatarFullScreen) {
                AvatarFullScreenView(user: user, isPresented: $showAvatarFullScreen)
            }
            .fullScreenCover(isPresented: $showChatScreen) {
                NavigationStack(path: $chatNavigationPath) {
                    ChatScreen(
                        receiptId: user.mid,
                        navigationPath: $chatNavigationPath,
                        onProfileNavigate: nil,
                        onShowLogin: onShowLogin,
                        onShowToast: onShowToast
                    )
                    .appNavigationDestinations(
                        path: $chatNavigationPath,
                        onShowLogin: onShowLogin,
                        onShowToast: onShowToast
                    )
                }
            }
            .onChange(of: showChatScreen) { _, isShowing in
                if !isShowing {
                    chatNavigationPath.removeLast(chatNavigationPath.count)
                }
            }
            .alert(
                String(
                    format: NSLocalizedString("Block %@?", comment: "Block user confirmation title"),
                    blockUserDisplayName
                ),
                isPresented: $showBlockUserMenu
            ) {
                Button(NSLocalizedString("Block User", comment: "Block user confirmation action"), role: .destructive) {
                    Task {
                        await handleBlockUser()
                    }
                }
                Button(NSLocalizedString("Cancel", comment: "Cancel block user confirmation"), role: .cancel) { }
            } message: {
                Text(
                    String(
                        format: NSLocalizedString(
                            "This will remove %@ from your following list and hide their content.",
                            comment: "Block user confirmation message"
                        ),
                        blockUserDisplayName
                    )
                )
            }
    }
    
    private var contentWithNavigation: some View {
        mainContentView
            .onAppear {
                // Keep the hosted SwiftUI profile header in sync with the app user's follow list.
                setFollowingState((hproseInstance.appUser.followingList)?.contains(user.mid) ?? false)
            }
            .onReceive(hproseInstance.appUser.$followingList) { newList in
                // followingList may load asynchronously after onAppear; keep button state in sync
                setFollowingState(newList?.contains(user.mid) ?? false)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                toolbarContent
            }
            .toolbar(isNavigationVisible ? .visible : .hidden, for: .navigationBar)
            .task(id: user.mid) {
                guard !didLoad else { return }
                didLoad = true
                await Task.yield()
                guard !Task.isCancelled else { return }
                await validateProfileRouteOnOpen()
            }
            .onChange(of: user.mid) { _, _ in
                // Reset didLoad when user changes so the new user's data is fetched
                didLoad = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .tweetPinStatusChanged)) { notification in
                handlePinStatusChanged(notification: notification)
            }
            .navigationDestination(item: $selectedUserForNavigation) { user in
                userDestinationView(for: user)
            }
            .onChange(of: navigationPath.count) { oldCount, newCount in
                print("🟣 [ProfileView] navigationPath.count changed from \(oldCount) to \(newCount) - user: \(user.username ?? "nil")")
            }
            .onReceive(NotificationCenter.default.publisher(for: .tweetDeleted)) { notification in
                handleTweetDeleted(notification: notification)
            }
            .onAppear {
                handleViewAppear()
            }
            .onDisappear {
                handleViewDisappear()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                isNavigationVisible = true
                NotificationCenter.default.post(
                    name: .navigationVisibilityChanged,
                    object: nil,
                    userInfo: ["isVisible": true]
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .showBarsAfterScrollEnd)) { notification in
                guard !isNavigationVisible else { return }
                isNavigationVisible = true
                let animated = notification.userInfo?["animated"] as? Bool ?? false
                postNavigationVisibilityNotification(isVisible: true, animated: animated)
            }
    }
    
    @ViewBuilder
    private func userDestinationView(for user: User) -> some View {
        // Navigate to user's profile when avatar is tapped from favorites/bookmarks
        let _ = print("🟢 [ProfileView] navigationDestination(selectedUser) TRIGGERED - navigating to user: \(user.username ?? "nil"), mid: \(user.mid)")
        ProfileView(
            user: user,
            onLogout: onLogout,
            navigationPath: $navigationPath,
            onShowLogin: onShowLogin,
            onShowToast: onShowToast
        )
        .onAppear {
            print("🟢 [ProfileView] NEW user profile appeared: \(user.username ?? "nil")")
        }
    }
    
    private func handleSheetDismiss() {
        // CRITICAL: Reset submission state when sheet is dismissed
        // This handles cases where user dismisses sheet during submission or clicks "Discard Changes"
        isSubmittingProfile = false
        print("DEBUG: [ProfileView] ProfileEditView dismissed, reset isSubmittingProfile")
    }
    
    private func handleTweetDeleted(notification: Notification) {
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
    
    private func handleViewAppear() {
        // Ensure navigation is visible when view appears
        isNavigationVisible = true
        NotificationCenter.default.post(
            name: .navigationVisibilityChanged,
            object: nil,
            userInfo: ["isVisible": true]
        )
        print("DEBUG: [ProfileView] View appeared, navigation set to visible")
    }
    
    private func handleViewDisappear() {
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
    
    // MARK: - View Components
    
    private var mainContentView: some View {
        ZStack {
            VStack(spacing: 0) {
                ProfileTweetsSection(
                    pinnedTweets: pinnedTweets,
                    pinnedTweetIds: pinnedTweetIds,
                    user: user,
                    hproseInstance: hproseInstance,
                    onUserSelect: { _ in }, // Not used - onAvatarTapInProfile handles all avatar navigation
                    onTweetTap: { tweet in
                        // Append tweet to navigationPath to navigate to detail view
                        // This matches the pattern used in HomeViewModel
                        navigationPath.append(tweet)
                    },
                    onAvatarTapInProfile: { tappedUser in
                        if tappedUser.mid == user.mid {
                            scrollToTop()
                        } else {
                            selectedUserForNavigation = tappedUser
                        }
                    },
                    onProfileRefresh: {
                        await resyncProfileDataForPull()
                    },
                    onScroll: { offset, delta in
                        handleScroll(offset: offset, delta: delta)
                    },
                    onShowLogin: onShowLogin,
                    onShowToast: onShowToast,
                    routeRefreshToken: profileTweetsRefreshToken,
                    resyncedTweets: resyncedTweets,
                    resyncedTweetsToken: resyncedTweetsToken,
                    header: {
                        VStack(spacing: 0) {
                            ProfileHeaderSection(
                                user: user,
                                headerState: profileHeaderState,
                                isCurrentUser: isAppUser,
                                onEditTap: {
                                    if hproseInstance.appUser.isGuest {
                                        onShowLogin?()
                                    } else {
                                        showEditSheet = true
                                    }
                                },
                                onFollowToggle: {
                                    guard !hproseInstance.appUser.isGuest else {
                                        onShowLogin?()
                                        return
                                    }
                                    let optimisticFollowing = !profileHeaderState.isFollowing
                                    setFollowingState(optimisticFollowing)
                                    Task {
                                        await handleToggleFollowing(for: user, optimisticFollowing: optimisticFollowing)
                                    }
                                },
                                onAvatarTap: { showAvatarFullScreen = true }
                            )

                            ProfileStatsView(
                                user: user,
                                onFollowersTap: {
                                    userListType = .FOLLOWER
                                    userListDestination = UserListDestination(userId: user.mid, listType: .FOLLOWER)
                                    navigationPath.append(userListDestination!)
                                },
                                onFollowingTap: {
                                    userListType = .FOLLOWING
                                    userListDestination = UserListDestination(userId: user.mid, listType: .FOLLOWING)
                                    navigationPath.append(userListDestination!)
                                },
                                onBookmarksTap: {
                                    let destination = TweetListDestination(userId: user.mid, listType: .BOOKMARKS)
                                    navigationPath.append(destination)
                                },
                                onFavoritesTap: {
                                    let destination = TweetListDestination(userId: user.mid, listType: .FAVORITES)
                                    navigationPath.append(destination)
                                }
                            )
                            .padding(.horizontal, -16)
                        }
                    }
                )
                .id(user.mid)
            }
            .allowsHitTesting(!isUploadingAvatar && !isSubmittingProfile)
            
            loadingOverlay
            toastOverlay
        }
    }
    
    private var loadingOverlay: some View {
        Group {
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
        }
    }
    
    private var toastOverlay: some View {
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
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !isAppUser {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        if hproseInstance.appUser.isGuest {
                            onShowLogin?()
                        } else {
                            showChatScreen = true
                        }
                    } label: {
                        Image(systemName: "message")
                            .foregroundColor(XTheme.accentColor)
                    }

                    Menu {
                        Button(role: .destructive) {
                            guard !hproseInstance.appUser.isGuest else {
                                onShowLogin?()
                                return
                            }
                            showBlockUserMenu = true
                        } label: {
                            Label(NSLocalizedString("Block User", comment: "Block user menu item"), systemImage: "slash.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .rotationEffect(.degrees(90))
                            .foregroundColor(XTheme.textColor)
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
    }
    
    private var profileEditSheet: some View {
        ProfileEditView(
            onSubmit: handleProfileSubmit,
            onAvatarUploadStateChange: { isUploading in
                isUploadingAvatar = isUploading
            },
            onAvatarUploadSuccess: {
                showToastMessage(NSLocalizedString("Avatar updated successfully!", comment: "Avatar update success"), type: .success)
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
    
    private func handleProfileSubmit(username: String, password: String?, alias: String?, profile: String?, hostId: String?, cloudDrivePort: Int, domainToShare: String?) async throws {
        // Set submission state
        isSubmittingProfile = true
        print("DEBUG: Profile update - username: \(username), alias: \(alias ?? "nil"), profile: \(profile ?? "nil"), hostId: \(hostId ?? "nil"), cloudDrivePort: \(cloudDrivePort), domainToShare: \(domainToShare ?? "nil")")

        let originalHostId = hproseInstance.appUser.hostIds?.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let submittedHostId = hostId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hostIdChanged = submittedHostId.count == Constants.MIMEI_ID_LENGTH && submittedHostId != originalHostId

        let success: Bool
        do {
            success = try await hproseInstance.updateUserCore(
                password: password,
                alias: alias,
                profile: profile,
                hostId: hostId,
                cloudDrivePort: cloudDrivePort,
                domainToShare: domainToShare
            )
        } catch {
            if hostIdChanged && isTimeoutLikeError(error) {
                print("DEBUG: Profile hostId update timed out after migration; logging out so user can verify result")
                await completeHostIdMigration(
                    message: NSLocalizedString("Host ID update timed out. Log in again to verify the result.", comment: "Host ID migration timeout message"),
                    isError: true
                )
                throw NSError(
                    domain: "ProfileHostIdMigration",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Host ID update timed out. Log in again to verify the result.", comment: "Host ID migration timeout message")]
                )
            }
            isSubmittingProfile = false
            throw error
        }
        print("DEBUG: Profile update result: \(success)")
        
        if success {
            if hostIdChanged {
                await completeHostIdMigration(
                    message: NSLocalizedString("Host ID updated. Please log in on the new host.", comment: "Host ID migration success message"),
                    isError: false
                )
                return
            }

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
            
            let sanitizedDomain = domainToShare?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let domain = sanitizedDomain, !domain.isEmpty {
                hproseInstance.appUser.domainToShare = domain
                print("DEBUG: Updated domainToShare to: \(domain)")
            } else {
                hproseInstance.appUser.domainToShare = nil
                print("DEBUG: Cleared domainToShare")
            }
            
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
    }

    private func completeHostIdMigration(message: String, isError: Bool) async {
        await hproseInstance.logout()
        await MainActor.run {
            isSubmittingProfile = false
            showEditSheet = false
            if let onShowToast {
                onShowToast(message, isError)
            } else {
                showToastMessage(message, type: isError ? .warning : .success)
            }
            NotificationCenter.default.post(name: .userDidLogout, object: nil)
            dismiss()
        }
    }

    private func isTimeoutLikeError(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0

        while let nsError = current, depth < 8 {
            if nsError.code == NSURLErrorTimedOut {
                return true
            }

            let description = nsError.localizedDescription.lowercased()
            if description.contains("timed out") || description.contains("timeout") {
                return true
            }

            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }

        return false
    }
    
    // MARK: - Scroll Handling
    @State private var lastSignificantDelta: CGFloat = 0
    @State private var lastNotificationTime: Date?
    private let notificationThrottleInterval: TimeInterval = 0.1 // 100ms - prevent rapid-fire notifications
    
    private func handleScroll(offset: CGFloat, delta: CGFloat) {
        // Threshold for detecting intentional scroll
        let scrollThreshold: CGFloat = 15
        
        // CRITICAL: Always show toolbar when near the top
        // Profile view has a header, so we need to account for negative offsets
        // When scrolled to the very top, offset will be around -100 to 0 depending on header height
        // We want to show toolbar when user is in the header area or just below it
        if offset < 100 {
            // Near the top - always show toolbar
            if !isNavigationVisible {
                // Use DispatchQueue to defer state update to next run loop to avoid modifying state during view update
                DispatchQueue.main.async { [self] in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isNavigationVisible = true
                    }
                    postNavigationVisibilityNotification(isVisible: true)
                }
            }
            // Defer state update to avoid modifying during view update
            DispatchQueue.main.async { [self] in
                previousScrollOffset = offset
            }
            return
        }
        
        // Only process scroll direction changes when scrolled down into content
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
            // Use DispatchQueue to defer state update to next run loop to avoid modifying state during view update
            DispatchQueue.main.async { [self] in
                withAnimation(.easeInOut(duration: 0.25)) {
                    isNavigationVisible = false
                }
                postNavigationVisibilityNotification(isVisible: false)
                lastSignificantDelta = delta
            }
        } else if isScrollingUp && !isNavigationVisible {
            // Scrolling up significantly - show bottom bar
            // Use DispatchQueue to defer state update to next run loop to avoid modifying state during view update
            DispatchQueue.main.async { [self] in
                withAnimation(.easeInOut(duration: 0.25)) {
                    isNavigationVisible = true
                }
                postNavigationVisibilityNotification(isVisible: true)
                lastSignificantDelta = delta
            }
        }

        // Defer state update to avoid modifying during view update
        DispatchQueue.main.async { [self] in
            previousScrollOffset = offset
        }
    }
    
    // Helper to post navigation visibility notification with throttling
    private func postNavigationVisibilityNotification(isVisible: Bool, animated: Bool = true) {
        // Throttle notifications to prevent excessive posting during rapid scroll
        let now = Date()
        if animated, let lastTime = lastNotificationTime, now.timeIntervalSince(lastTime) < notificationThrottleInterval {
            return
        }
        
        lastNotificationTime = now
        NotificationCenter.default.post(
            name: .navigationVisibilityChanged,
            object: nil,
            userInfo: ["isVisible": isVisible, "animated": animated]
        )
    }
    
    // MARK: - Helper Methods
    
    private func scrollToTop() {
        // Scroll to top of this specific profile's feed
        // Pass the feed identifier to target only this profile's tweet list
        let feedIdentifier = "profile_\(user.mid)"
        NotificationCenter.default.post(
            name: .scrollToTop,
            object: nil,
            userInfo: ["feedIdentifier": feedIdentifier]
        )
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

    private func setFollowingState(_ newValue: Bool) {
        guard profileHeaderState.isFollowing != newValue else { return }
        profileHeaderState.isFollowing = newValue
    }
    
    private func handleToggleFollowing(for user: User, optimisticFollowing: Bool) async {
        if let ret = try? await hproseInstance.toggleFollowing(followingId: user.mid) {
            await MainActor.run {
                setFollowingState(ret)
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
            await MainActor.run {
                setFollowingState(!optimisticFollowing)
                showToastMessage(NSLocalizedString("Failed to toggle following status", comment: "Profile action error"), type: .error)
            }
        }
    }
    
    private func validateProfileRouteOnOpen() async {
        let routeBeforeValidation = user.baseUrl?.absoluteString
        let routeIsReady = await hproseInstance.validateAndRepairProfileRoute(for: user)
        guard routeIsReady, !Task.isCancelled else { return }

        if user.baseUrl?.absoluteString != routeBeforeValidation {
            await MainActor.run {
                profileTweetsRefreshToken += 1
            }
        }
        await refreshProfileData()
    }

    private func refreshProfileData() async {
        var refreshedProfileUser: User?
        let profileUserId = user.mid
        let cachedRoute = user.baseUrl?.absoluteString ?? ""
        let hproseInstance = hproseInstance

        // Fetch fresh user data from server
        do {
            let refreshedUser = try await Task.detached(priority: .utility) {
                try await hproseInstance.fetchUser(
                    profileUserId,
                    baseUrl: "",
                    forceRefresh: true,
                    refreshExpiredCacheInBackground: false
                )
            }.value
            if let userData = refreshedUser {
                refreshedProfileUser = userData
                let refreshedRoute = userData.baseUrl?.absoluteString ?? ""
                if refreshedRoute != cachedRoute {
                    await MainActor.run {
                        profileTweetsRefreshToken += 1
                    }
                    print("DEBUG: [ProfileView] User route changed from \(cachedRoute.isEmpty ? "nil" : cachedRoute) to \(refreshedRoute.isEmpty ? "nil" : refreshedRoute); reloading profile tweets")
                }
                print("DEBUG: [ProfileView] Successfully fetched user \(profileUserId) from server - username: \(userData.username ?? "nil"), baseUrl: \(userData.baseUrl?.absoluteString ?? "nil"), tweetCount: \(userData.tweetCount ?? 0), followersCount: \(userData.followersCount ?? 0), followingCount: \(userData.followingCount ?? 0)")
                TweetCacheManager.shared.saveUser(userData)
                print("DEBUG: [ProfileView] Saved fetched user to cache")
            } else {
                print("DEBUG: [ProfileView] Failed to fetch user \(profileUserId): server returned nil")
            }
        } catch {
            print("DEBUG: [ProfileView] Failed to fetch user \(profileUserId): \(error)")
        }

        guard refreshedProfileUser != nil else {
            print("DEBUG: [ProfileView] Skipping pinned tweet refresh because user fetch failed for \(profileUserId)")
            return
        }
        
        await refreshPinnedTweets()
    }

    /// Explicit recovery for profile pull-to-refresh. The backend executes this
    /// on the current access node and synchronizes the User plus its direct Tweet
    /// references from the home host before returning fresh data.
    private func resyncProfileDataForPull() async {
        let profileUserId = user.mid
        let hproseInstance = hproseInstance

        let routeIsReady = await hproseInstance.validateAndRepairProfileRoute(for: user)
        guard routeIsReady, !Task.isCancelled else {
            print("DEBUG: [ProfileView] Skipping profile resync because no healthy route is available for \(profileUserId)")
            return
        }

        do {
            let resyncResult = try await Task.detached(priority: .utility) {
                try await hproseInstance.resyncUser(userId: profileUserId)
            }.value
            print("DEBUG: [ProfileView] Successfully resynced user \(profileUserId) on server with \(resyncResult.tweets.count) tweets")

            await MainActor.run {
                resyncedTweets = resyncResult.tweets
                resyncedTweetsToken += 1
            }

            // Pinned tweets are a separate list read; run it only after the
            // access node has received the user's current data.
            await refreshPinnedTweets()
        } catch is CancellationError {
            print("DEBUG: [ProfileView] Profile resync cancelled for \(profileUserId)")
        } catch {
            print("DEBUG: [ProfileView] Failed to resync user \(profileUserId): \(error)")
            // Keep pull-to-refresh useful if synchronization is temporarily
            // unavailable. This fallback performs the previous ordinary read.
            await refreshProfileData()
        }
    }
    
    private func refreshPinnedTweets() async {
        let profileUser = user
        let hproseInstance = hproseInstance

        print("DEBUG: [ProfileView] Starting to refresh pinned tweets for user: \(profileUser.mid)")
        do {
            let pinnedTweets = try await hproseInstance.getPinnedTweets(user: profileUser)
            print("DEBUG: [ProfileView] Got \(pinnedTweets.count) pinned tweets from server")
            
            let pinnedTweetIds = pinnedTweets.map(\.mid)
            
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

    private func handlePinStatusChanged(notification: Notification) {
        guard let tweetId = notification.userInfo?["tweetId"] as? String,
              let isPinned = notification.userInfo?["isPinned"] as? Bool else {
            return
        }

        if isPinned {
            guard let tweet = Tweet.getInstance(for: tweetId),
                  tweet.authorId == user.mid else {
                return
            }
            pinnedTweetIds.insert(tweetId)
            if !pinnedTweets.contains(where: { $0.mid == tweetId }) {
                pinnedTweets.insert(tweet, at: 0)
            }
        } else {
            guard pinnedTweetIds.contains(tweetId)
                    || Tweet.getInstance(for: tweetId)?.authorId == user.mid else {
                return
            }
            pinnedTweetIds.remove(tweetId)
            pinnedTweets.removeAll { $0.mid == tweetId }
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
    

}

enum UserListType {
    case FOLLOWER
    case FOLLOWING
}

enum TweetListType: Hashable {
    case BOOKMARKS
    case FAVORITES
}

// Navigation destination for tweet lists (bookmarks/favorites)
struct TweetListDestination: Hashable {
    let userId: String
    let listType: TweetListType
} 
