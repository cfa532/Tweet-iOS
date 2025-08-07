import SwiftUI

struct ProfileView: View {
    let user: User
    let onLogout: (() -> Void)?
    
    @EnvironmentObject private var hproseInstance: HproseInstance
    @Environment(\.dismiss) private var dismiss
    
    /// Navigation state
    @State private var selectedUser: User? = nil
    @State private var selectedTweet: Tweet? = nil
    @State private var showUserList = false
    @State private var showTweetList = false
    @State private var showChat = false
    @State private var userListType: UserListType = .FOLLOWER
    @State private var tweetListType: TweetListType = .BOOKMARKS
    
    /// UI state
    @State private var showEditSheet = false
    @State private var showAvatarFullScreen = false
    @State private var previousScrollOffset: CGFloat = 0
    @State private var isLoading = false
    @State private var didLoad = false
    
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
                    onTweetTap: { tweet in selectedTweet = tweet },
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
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isAppUser {
                    Button("Logout") {
                        onLogout?()
                    }
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            RegistrationView(
                onSubmit: { username, password, alias, profile, hostId, cloudDrivePort in
                    // Set submission state
                    isSubmittingProfile = true
                    print("DEBUG: Profile update - username: \(username), alias: \(alias ?? "nil"), profile: \(profile ?? "nil"), hostId: \(hostId ?? "nil"), cloudDrivePort: \(cloudDrivePort?.description ?? "nil")")
                    do {
                        let success = try await hproseInstance.updateUserCore(
                            password: password, alias: alias, profile: profile, hostId: hostId, cloudDrivePort: cloudDrivePort
                        )
                        print("DEBUG: Profile update result: \(success)")
                        await MainActor.run {
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
                                
                                showToastMessage("Profile updated successfully!", type: .success)
                                // Keep the sheet open after successful update
                            } else {
                                showToastMessage("Profile update failed", type: .error)
                            }
                            // Reset submission state
                            isSubmittingProfile = false
                        }
                    } catch {
                        print("DEBUG: Profile update error: \(error)")
                        await MainActor.run {
                            showToastMessage("Failed to update profile: \(error.localizedDescription)", type: .error)
                            // Reset submission state
                            isSubmittingProfile = false
                        }
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
                }
            )
        }
        .fullScreenCover(isPresented: $showAvatarFullScreen) {
            AvatarFullScreenView(user: user, isPresented: $showAvatarFullScreen)
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
                    if let _ = try? await hproseInstance.toggleFollowing(
                        followingId: user.mid
                    ) {
                        // Handle follow toggle success
                    }
                }
            )
        }
        .navigationDestination(isPresented: $showTweetList) {
            bookmarksOrFavoritesListView()
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedUser != nil },
            set: { if !$0 { selectedUser = nil } }
        )) {
            if let selectedUser = selectedUser {
                ProfileView(user: selectedUser, onLogout: nil)
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedTweet != nil },
            set: { if !$0 { selectedTweet = nil } }
        )) {
            if let selectedTweet = selectedTweet {
                TweetDetailView(tweet: selectedTweet)
            }
        }
        .navigationDestination(isPresented: $showChat) {
            ChatScreen(receiptId: user.mid)
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
    
    private func refreshPinnedTweets() async {
        do {
            let pinnedTweetData = try await hproseInstance.getPinnedTweets(user: user)
            var pinnedTweets: [Tweet] = []
            var pinnedTweetIds: [String] = []
            
            // Extract tweets and IDs from the response
            for tweetData in pinnedTweetData {
                if let tweet = tweetData["tweet"] as? Tweet {
                    pinnedTweets.append(tweet)
                    pinnedTweetIds.append(tweet.mid)
                }
            }
            
            await MainActor.run {
                self.pinnedTweetIds = Set(pinnedTweetIds)
                self.pinnedTweets = pinnedTweets
            }
        } catch {
            print("Failed to refresh pinned tweets: \(error)")
        }
    }
    
    @ViewBuilder
    private func bookmarksOrFavoritesListView() -> some View {
        if tweetListType == .BOOKMARKS {
            TweetListView(
                title: "Bookmarks",
                tweets: .constant([]),
                tweetFetcher: { page, size, _ in
                    try await hproseInstance.getUserTweetsByType(user: user, type: .BOOKMARKS, pageNumber: page, pageSize: size)
                },
                rowView: { tweet in
                    TweetItemView(
                        tweet: tweet,
                        onAvatarTap: { user in selectedUser = user },
                        onTap: { tweet in selectedTweet = tweet }
                    )
                }
            )
        } else {
            TweetListView(
                title: "Favorites",
                tweets: .constant([]),
                tweetFetcher: { page, size, _ in
                    try await hproseInstance.getUserTweetsByType(user: user, type: .FAVORITES, pageNumber: page, pageSize: size)
                },
                rowView: { tweet in
                    TweetItemView(
                        tweet: tweet,
                        onAvatarTap: { user in selectedUser = user },
                        onTap: { tweet in selectedTweet = tweet }
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