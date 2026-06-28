import SwiftUI

// Main ContentView
@available(iOS 17.0, *)
struct ContentView: View {
    @StateObject private var hproseInstance = HproseInstance.shared
    @StateObject private var chatSessionManager = ChatSessionManager.shared
    @StateObject private var uploadProgressManager = UploadProgressManager.shared
    @StateObject private var followingsTweetViewModel = FollowingsTweetViewModel.shared
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var selectedTab = 0
    @State private var showComposeSheet = false
    @State private var isNavigationVisible = true
    @State private var animateNavigationVisibility = true
    @State private var shouldHideHeight = false // Flag for TweetDetailView to hide height
    @State private var navigationPath = NavigationPath()
    @State private var chatNavigationPath = NavigationPath()
    @State private var isInChatScreen = false
    @State private var isInProfileFromChat = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .success
    @State private var pendingUpload: TweetUploadManager.PendingTweetUpload? = nil
    @State private var showPendingUploadDialog = false
    @State private var showCloudDriveLimitAlert = false
    @State private var showLoginSheet = false
    @State private var notificationObservers: [NSObjectProtocol] = []
    @State private var didClearStartupNewTweetsBanner = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Main content area
            VStack(spacing: 0) {
                if selectedTab == 0 {
                    NavigationStack(path: $navigationPath) {
                        HomeView(
                            navigationPath: $navigationPath,
                            onNavigationVisibilityChanged: { isVisible in
                                // Disabled to prevent dual updates (NotificationCenter handles this)
                            },
                            onReturnToHome: {
                                selectedTab = 0
                            },
                            onShowLogin: {
                                showLoginSheet = true
                            },
                            onShowToast: { message, isError in
                                toastMessage = message
                                toastType = isError ? .error : .success
                                showToast = true
                                let delay = isError ? 5.0 : 2.0
                                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                    withAnimation { showToast = false }
                                }
                            }
                        )
                    }
                } else if selectedTab == 1 {
                    NavigationStack(path: $chatNavigationPath) {
                        ChatListScreen(
                            navigationPath: $chatNavigationPath,
                            onProfileNavigate: {
                                isInProfileFromChat = true
                            },
                            onChatNavigate: {
                                isInProfileFromChat = false
                                isInChatScreen = true
                            },
                            onShowLogin: {
                                showLoginSheet = true
                            },
                            onShowToast: { message, isError in
                                toastMessage = message
                                toastType = isError ? .error : .success
                                showToast = true
                                let delay = isError ? 5.0 : 2.0
                                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                    withAnimation { showToast = false }
                                }
                            }
                        )
                    }
                    .onChange(of: chatNavigationPath.count) { _, count in
                        if count == 0 {
                            // Reset all flags when back at root
                            isInChatScreen = false
                            isInProfileFromChat = false
                        } else if !isInProfileFromChat {
                            // If count > 0 and we haven't explicitly set profile flag, assume it's ChatScreen
                            isInChatScreen = true
                        }
                        // If isInProfileFromChat is true, keep tab bar visible (isInChatScreen stays false)
                    }
                } else if selectedTab == 3 {
                    SearchScreen(
                        onShowLogin: {
                            showLoginSheet = true
                        },
                        onShowToast: { message, isError in
                            toastMessage = message
                            toastType = isError ? .error : .success
                            showToast = true
                            let delay = isError ? 5.0 : 2.0
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                withAnimation { showToast = false }
                            }
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(XTheme.backgroundColor)
            
            // Custom Tab Bar - Hide when in chat screen, but show when in profile from chat
            if !isInChatScreen || isInProfileFromChat {
                HStack(spacing: 0) {
                // Home Tab
                Button(action: {
                    if selectedTab != 0 {
                        selectedTab = 0
                    } else if !navigationPath.isEmpty {
                        navigationPath.removeLast(navigationPath.count)
                        selectedTab = 0
                    } else {
                        // Already on home tab at root - scroll to top
                        NotificationCenter.default.post(name: .scrollToTop, object: nil)
                    }
                }) {
                    let isHomeActive = navigationPath.isEmpty && selectedTab == 0
                    Image(systemName: isHomeActive ? "house.fill" : "house")
                        .font(.system(size: 24))
                        .foregroundColor(isHomeActive ? XTheme.accentColor : XTheme.secondaryTextColor)
                }
                .frame(maxWidth: .infinity)
                
                // Chat Tab
                Button(action: {
                    if hproseInstance.appUser.isGuest {
                        showLoginSheet = true
                    } else if selectedTab != 1 {
                        selectedTab = 1
                    } else {
                        // Already on chat tab - navigate back to chat list
                        chatNavigationPath.removeLast(chatNavigationPath.count)
                        isInChatScreen = false
                        isInProfileFromChat = false
                    }
                }) {
                    ZStack {
                        Image(systemName: "message")
                            .font(.system(size: 24))
                            .foregroundColor(selectedTab == 1 ? XTheme.accentColor : XTheme.secondaryTextColor)
                        
                        // Badge for unread messages
                        BadgeView(count: chatSessionManager.unreadMessageCount)
                            .offset(x: 12, y: -12)
                    }
                }
                .frame(maxWidth: .infinity)
                
                // Compose Tab
                Button(action: {
                    if hproseInstance.appUser.isGuest {
                        showLoginSheet = true
                        return
                    }
                    // Check if user has no valid cloudDrivePort and has reached tweet limit
                    let cloudDrivePort = hproseInstance.appUser.cloudDrivePort
                    let tweetCount = hproseInstance.appUser.tweetCount ?? 0
                    
                    print("DEBUG: [Tweet Limit Check] cloudDrivePort: \(cloudDrivePort), tweetCount: \(tweetCount)")
                    
                    if (cloudDrivePort <= 0) && (tweetCount >= 5) {
                        print("DEBUG: [Tweet Limit Check] ❌ LIMIT REACHED - Showing alert")
                        showCloudDriveLimitAlert = true
                    } else {
                        print("DEBUG: [Tweet Limit Check] ✅ ALLOWED - cloudDrivePort: \(cloudDrivePort > 0 ? "valid" : "invalid"), tweetCount: \(tweetCount)/5")
                        showComposeSheet = true
                    }
                }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 24))
                        .foregroundColor(XTheme.accentColor)
                }
                .frame(maxWidth: .infinity)
                
                // Search Tab
                Button(action: {
                    selectedTab = 3
                }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundColor(selectedTab == 3 ? XTheme.accentColor : XTheme.secondaryTextColor)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 16)
            .padding(.bottom, 2)
            .frame(height: (shouldHideHeight && !isNavigationVisible) ? 0 : nil)
            .clipped()
            .background(
                XTheme.backgroundColor
                    .opacity(isNavigationVisible ? 1.0 : 0.0)
            )
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(XTheme.borderColor.opacity(isNavigationVisible ? 1.0 : 0.0))
                    .frame(height: 0.5)
            }
            .opacity(isNavigationVisible ? 1.0 : 0.3)
            .allowsHitTesting(true)
            .animation(animateNavigationVisibility ? .easeInOut(duration: 0.25) : nil, value: isNavigationVisible)
            .animation(animateNavigationVisibility ? .easeInOut(duration: 0.25) : nil, value: shouldHideHeight)
        }
        }
        .overlay(alignment: .top) {
            if shouldShowMainFeedNewTweetsBanner {
                NewTweetsBannerOverlay(viewModel: followingsTweetViewModel) {
                    openMainFeedAndShowNewTweets()
                }
                .zIndex(1500)
            }
        }
        .background(XTheme.backgroundColor)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $showComposeSheet) {
            ComposeTweetView()
        }
        .sheet(isPresented: $showLoginSheet) {
            LoginView()
        }
        .onChange(of: showComposeSheet) { _, isPresented in
            if isPresented {
                OverlayVisibilityCoordinator.shared.beginOverlay(id: "composeSheet", source: "ContentView")
            } else {
                OverlayVisibilityCoordinator.shared.endOverlay(id: "composeSheet", source: "ContentView")
            }
        }
        .alert(NSLocalizedString("Tweet Limit Reached", comment: "Tweet limit alert title"), isPresented: $showCloudDriveLimitAlert) {
            Button(NSLocalizedString("Learn More", comment: "Learn more button")) {
                Task {
                    await fetchDeveloperUserAndNavigate()
                }
            }
            Button(NSLocalizedString("Cancel", comment: "Cancel button"), role: .cancel) {
                // Do nothing, just dismiss the alert
            }
        } message: {
            Text(NSLocalizedString("This is a Web3 tweet app. You have reached the maximum number of benevolently hosted tweets. Please set up your own node or ask a friend to host your future tweets.", comment: "Tweet limit message"))
        }
        .onChange(of: showCloudDriveLimitAlert) { _, isPresented in
            if isPresented {
                OverlayVisibilityCoordinator.shared.beginOverlay(id: "tweetLimitAlert", source: "ContentView")
            } else {
                OverlayVisibilityCoordinator.shared.endOverlay(id: "tweetLimitAlert", source: "ContentView")
            }
        }
        .overlay(
            // Toast message overlay
            VStack {
                Spacer()
                if showToast {
                    ToastView(message: toastMessage, type: toastType)
                        .padding(.bottom, 60) // Position to overlap tab bar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showToast)
        )
        .overlay(
            // Upload progress overlay
            UploadProgressOverlay(progressManager: uploadProgressManager)
        )
        .overlay(
            // Pending upload dialog
            Group {
                if showPendingUploadDialog, let upload = pendingUpload {
                    ZStack {
                        Color.black.opacity(0.4)
                            .edgesIgnoringSafeArea(.all)
                            .onTapGesture {
                                // Prevent dismissal by tapping background
                            }
                        
                        PendingUploadDialog(
                            pendingUpload: upload,
                            onRetry: {
                                showPendingUploadDialog = false
                                retryPendingUpload(upload)
                            },
                            onCancel: {
                                showPendingUploadDialog = false
                                cancelPendingUpload()
                            }
                        )
                    }
                    .transition(.opacity)
                    .zIndex(2000)
                }
            }
        )
        .onAppear {
            if !didClearStartupNewTweetsBanner {
                didClearStartupNewTweetsBanner = true
                Task { @MainActor in
                    followingsTweetViewModel.clearPendingNewTweetsBanner(reason: "app start")
                }
            }
            checkForPendingUpload()
            setupNotificationObservers()
        }
        .onDisappear {
            cleanupNotificationObservers()
        }
        .environmentObject(hproseInstance)
        .environmentObject(themeManager)
    }
    
    // MARK: - Notification Observer Management

    private var shouldShowMainFeedNewTweetsBanner: Bool {
        !hproseInstance.appUser.isGuest && (selectedTab == 0 || isInProfileFromChat)
    }

    private func openMainFeedAndShowNewTweets() {
        selectedTab = 0
        if !navigationPath.isEmpty {
            navigationPath.removeLast(navigationPath.count)
        }
        isInChatScreen = false
        isInProfileFromChat = false
        isNavigationVisible = true

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .scrollToTop,
                object: nil,
                userInfo: ["scrollTarget": "firstRegularTweet"]
            )
        }
    }
    
    private func setupNotificationObservers() {
        cleanupNotificationObservers()
        
        // 1. Tweet submitted
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .showMainFeedNewTweets,
                object: nil,
                queue: .main
            ) { _ in
                self.openMainFeedAndShowNewTweets()
            }
        )

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .tweetSubmitted,
                object: nil,
                queue: .main
            ) { notification in
                if let message = notification.userInfo?["message"] as? String {
                    self.toastMessage = message
                    self.toastType = .success
                    self.showToast = true
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation { self.showToast = false }
                    }
                }
            }
        )
        
        // 2. Tweet privacy updated
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .tweetPrivacyUpdated,
                object: nil,
                queue: .main
            ) { notification in
                if let message = notification.userInfo?["message"] as? String,
                   let typeString = notification.userInfo?["type"] as? String {
                    self.toastMessage = message
                    self.toastType = typeString == "error" ? .error : .success
                    self.showToast = true
                    
                    let delay = typeString == "error" ? 5.0 : 2.0
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        withAnimation { self.showToast = false }
                    }
                }
            }
        )
        
        // 3. Navigation visibility changed
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .navigationVisibilityChanged,
                object: nil,
                queue: .main
            ) { notification in
                if let isVisible = notification.userInfo?["isVisible"] as? Bool {
                    guard self.isNavigationVisible != isVisible else { return }
                    
                    // Check if TweetDetailView wants height hidden (only affects TweetDetailView)
                    let hideHeight = notification.userInfo?["hideHeight"] as? Bool ?? false
                    let animated = notification.userInfo?["animated"] as? Bool ?? true
                    
                    print("[ContentView] Navigation visibility changed to: \(isVisible), hideHeight: \(hideHeight)")
                    if animated {
                        self.animateNavigationVisibility = true
                        withAnimation(.easeInOut(duration: 0.25)) {
                            self.isNavigationVisible = isVisible
                            self.shouldHideHeight = hideHeight && !isVisible // Only hide height when hidden and flag is set
                        }
                    } else {
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            self.animateNavigationVisibility = false
                            self.isNavigationVisible = isVisible
                            self.shouldHideHeight = hideHeight && !isVisible // Only hide height when hidden and flag is set
                        }
                        DispatchQueue.main.async {
                            self.animateNavigationVisibility = true
                        }
                    }
                }
            }
        )
        
        // 4. New tweet created
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .newTweetCreated,
                object: nil,
                queue: .main
            ) { notification in
                if notification.userInfo?["tweet"] is Tweet {
                    self.toastMessage = NSLocalizedString("Tweet posted successfully", comment: "Tweet upload success")
                    self.toastType = .success
                    self.showToast = true
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation { self.showToast = false }
                    }
                }
            }
        )
        
        // 5. New comment added
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .newCommentAdded,
                object: nil,
                queue: .main
            ) { notification in
                if notification.userInfo?["comment"] is Tweet {
                    self.toastMessage = NSLocalizedString("Comment posted successfully", comment: "Comment upload success")
                    self.toastType = .success
                    self.showToast = true
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation { self.showToast = false }
                    }
                }
            }
        )
        
        // 6. Background upload failed
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .backgroundUploadFailed,
                object: nil,
                queue: .main
            ) { notification in
                if let error = notification.userInfo?["error"] as? Error {
                    self.toastMessage = ErrorMessageHelper.userFriendlyMessage(from: error)
                    self.toastType = .error
                    self.showToast = true
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        withAnimation { self.showToast = false }
                    }
                }
            }
        )

        // 6a. Tweet deletion failed
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .errorOccurred,
                object: nil,
                queue: .main
            ) { notification in
                guard let error = notification.object as? NSError,
                      error.domain == "TweetDeletion" else {
                    return
                }

                self.toastMessage = ErrorMessageHelper.userFriendlyMessage(from: error)
                self.toastType = .error
                self.showToast = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    withAnimation { self.showToast = false }
                }
            }
        )

        // 6b. Audio playback warning
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .audioPlaybackWarning,
                object: nil,
                queue: .main
            ) { notification in
                if let message = notification.userInfo?["message"] as? String {
                    self.toastMessage = message
                    self.toastType = .warning
                    self.showToast = true

                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        withAnimation { self.showToast = false }
                    }
                }
            }
        )

        // 6c. Video upload format warning
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .videoUploadFormatWarning,
                object: nil,
                queue: .main
            ) { notification in
                if let message = notification.userInfo?["message"] as? String {
                    self.toastMessage = message
                    self.toastType = .warning
                    self.showToast = true

                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        withAnimation { self.showToast = false }
                    }
                }
            }
        )
        
        // 7. Memory warning critical
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .memoryWarningCritical,
                object: nil,
                queue: .main
            ) { notification in
                if let memoryMB = notification.userInfo?["memoryMB"] as? UInt64,
                   let severity = notification.userInfo?["severity"] as? String {
                    
                    let memoryGB = String(format: "%.1f", Double(memoryMB) / 1024.0)
                    
                    if severity == "critical" {
                        self.toastMessage = NSLocalizedString("Memory critically low (\(memoryGB)GB). Please restart the app to free resources.", comment: "Critical memory warning")
                    } else {
                        self.toastMessage = NSLocalizedString("Memory is running low (\(memoryGB)GB). Consider restarting the app if issues persist.", comment: "High memory warning")
                    }
                    
                    self.toastType = .error
                    self.showToast = true
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                        withAnimation { self.showToast = false }
                    }
                }
            }
        )
        
        // 8. Will enter foreground
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                self.isNavigationVisible = true
                self.checkForPendingUpload()
            }
        )
        
        // 9. Navigate guest user to alphaId profile
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .appUserReady,
                object: nil,
                queue: .main
            ) { _ in
                guard self.hproseInstance.appUser.isGuest else { return }
                guard self.navigationPath.isEmpty else { return }
                guard let alphaId = Gadget.getAlphaIds().first else { return }
                let alphaUser = User.getInstance(mid: alphaId)
                guard alphaUser.username != nil else { return }
                self.selectedTab = 0
                self.navigationPath.append(alphaUser)
            }
        )

        // 10. Deeplink received
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .deeplinkReceived,
                object: nil,
                queue: .main
            ) { notification in
                print("[ContentView] ✅ Received deeplink notification")
                if let url = notification.userInfo?["url"] as? URL {
                    print("[ContentView] URL from notification: \(url.absoluteString)")
                    self.handleDeeplink(url)
                } else {
                    print("[ContentView] ⚠️ No URL found in notification userInfo")
                }
            }
        )
        
        // 11. Deeplink tweet not found
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .deeplinkTweetNotFound,
                object: nil,
                queue: .main
            ) { notification in
                if let message = notification.userInfo?["message"] as? String {
                    self.toastMessage = message
                    self.toastType = .error
                    self.showToast = true
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        withAnimation { self.showToast = false }
                    }
                }
            }
        )
        
        // 12. After successful login, return to the main (home) screen
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .userDidLogin,
                object: nil,
                queue: .main
            ) { _ in
                self.selectedTab = 0
                self.navigationPath = NavigationPath()
                self.chatNavigationPath = NavigationPath()
                self.isInChatScreen = false
                self.isInProfileFromChat = false
                NotificationCenter.default.post(name: .scrollToTop, object: nil)
            }
        )
    }
    
    private func cleanupNotificationObservers() {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }
    
    // MARK: - Developer Profile Navigation
    
    private func fetchDeveloperUserAndNavigate() async {
        do {
            // Fetch developer user by username
            if let userId = try await hproseInstance.getUserId("developer"),
               let user = try await hproseInstance.fetchUser(userId) {
                await MainActor.run {
                    // Switch to home tab and navigate to developer's profile
                    selectedTab = 0
                    // Clear any existing navigation and push developer user
                    navigationPath = NavigationPath()
                    navigationPath.append(user)
                }
            } else {
                print("DEBUG: Could not find @developer user")
            }
        } catch {
            print("DEBUG: Error fetching @developer user: \(error)")
        }
    }
    
    // MARK: - Pending Upload Handling
    
    private func checkForPendingUpload() {
        // Don't check if dialog is already showing or if actively uploading
        guard !showPendingUploadDialog && !uploadProgressManager.isUploading else {
            return
        }
        
        Task {
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("pendingTweetUpload.json")
            
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return
            }
            
            do {
                let data = try Data(contentsOf: fileURL)
                let upload = try JSONDecoder().decode(TweetUploadManager.PendingTweetUpload.self, from: data)
                
                // Check if the pending upload is not too old (e.g., within 24 hours)
                let maxAge: TimeInterval = 24 * 60 * 60 // 24 hours
                guard Date().timeIntervalSince(upload.timestamp) < maxAge else {
                    // Too old, remove it
                    try? FileManager.default.removeItem(at: fileURL)
                    return
                }
                
                // Auto-resume if there are still retries left (maxRetries = 2)
                let maxRetries = 2
                if upload.retryCount < maxRetries {
                    print("DEBUG: [Auto-resume] Pending upload found with retryCount=\(upload.retryCount), auto-resuming without user confirmation")
                    // Automatically retry without showing dialog
                    retryPendingUpload(upload)
                } else {
                    // Max retries reached, show dialog for user to decide
                    print("DEBUG: [Auto-resume] Pending upload found with retryCount=\(upload.retryCount) (max reached), showing dialog")
                    await MainActor.run {
                        self.pendingUpload = upload
                        self.showPendingUploadDialog = true
                    }
                }
            } catch {
                print("DEBUG: Failed to load pending upload: \(error)")
            }
        }
    }
    
    private func retryPendingUpload(_ upload: TweetUploadManager.PendingTweetUpload) {
        Task {
            // Determine upload type and check for videos
            let uploadType = upload.tweet.originalTweetId != nil ? "comment" : "tweet"
            let hasVideos = upload.itemData.contains { item in
                item.typeIdentifier.contains("video") || item.typeIdentifier.contains("movie")
            }
            
            // Use upload queue for retry (prevents conflicts with other uploads)
            await MainActor.run {
                UploadProgressManager.shared.enqueueUpload(type: uploadType, hasVideos: hasVideos) {
                    // Retry the upload using the upload manager
                    // If there's an existing video job ID, it will check status and poll
                    // If not, it will re-upload attachments in foreground (with dialog visible)
                    await self.hproseInstance.uploadManager.uploadTweetWithPersistenceAndRetry(
                        tweet: upload.tweet,
                        itemData: upload.itemData,
                        retryCount: upload.retryCount,
                        videoJobId: upload.videoJobId
                    )
                }
            }
        }
    }
    
    private func cancelPendingUpload() {
        Task {
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("pendingTweetUpload.json")
            try? FileManager.default.removeItem(at: fileURL)
            
            await MainActor.run {
                self.pendingUpload = nil
                self.showPendingUploadDialog = false
                
                self.toastMessage = NSLocalizedString("Upload discarded", comment: "Upload cancelled message")
                self.toastType = .error
                self.showToast = true
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation { self.showToast = false }
                }
            }
        }
    }
    
    // MARK: - Deeplink Handling
    
    private func handleDeeplink(_ url: URL) {
        print("[ContentView] Handling deeplink: \(url.absoluteString)")
        
        // Parse the URL
        let deeplinkType = DeeplinkManager.shared.parseURL(url)
        
        // Switch to home tab if needed (for navigation)
        // Use a small delay to ensure tab switch completes before navigation
        if selectedTab != 0 {
            selectedTab = 0
            // Wait a bit for tab switch animation
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
                await DeeplinkManager.shared.handleDeeplink(
                    deeplinkType,
                    navigationPath: $navigationPath,
                    hproseInstance: hproseInstance
                )
            }
        } else {
            // Already on home tab, navigate immediately
            Task {
                await DeeplinkManager.shared.handleDeeplink(
                    deeplinkType,
                    navigationPath: $navigationPath,
                    hproseInstance: hproseInstance
                )
            }
        }
    }
}

@available(iOS 17.0, *)
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(ThemeManager.shared)
    }
}

@available(iOS 16.0, *)
private struct NewTweetsBannerOverlay: View {
    @ObservedObject var viewModel: FollowingsTweetViewModel
    let onTap: () -> Void

    private struct AvatarClusterItem: Identifiable {
        let id: String
        let user: User?
        let opacity: Double
    }

    private var pendingTweets: [Tweet] {
        viewModel.visiblePendingNewTweets
    }

    var body: some View {
        VStack {
            if viewModel.showNewTweetsBanner && !pendingTweets.isEmpty {
                Button(action: {
                    viewModel.applyPendingNewTweets()
                    onTap()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .semibold))

                        avatarCluster
                            .padding(.leading, -2)
                            .padding(.trailing, 5)

                        if shouldShowTitle {
                            Text(title)
                                .font(.system(size: 15, weight: .regular))
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.leading, 12)
                    .padding(.trailing, 14)
                    .frame(height: 44)
                    .background(
                        Capsule()
                            .fill(bannerBackgroundColor)
                    )
                    .clipShape(Capsule())
                    .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 3)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    scheduleAutoHide()
                }
                .onChange(of: pendingTweets.map(\.mid)) { _, _ in
                    scheduleAutoHide()
                }
            }

            Spacer()
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(viewModel.showNewTweetsBanner && !pendingTweets.isEmpty)
        .animation(.easeOut(duration: 0.22), value: viewModel.showNewTweetsBanner)
    }

    private var title: String {
        let count = pendingTweets.count
        let format = count == 1
            ? NSLocalizedString("new_tweets_banner_one", comment: "New tweet floating pill title")
            : NSLocalizedString("new_tweets_banner_many", comment: "New tweets floating pill title")
        return String(format: format, count > 9 ? "9+" : "\(count)")
    }

    private var shouldShowTitle: Bool {
        avatarClusterItems(from: distinctAuthors).count <= 3
    }

    private var bannerBackgroundColor: Color {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        guard XTheme.accent.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return XTheme.accentColor
        }

        return Color(uiColor: UIColor(
            hue: hue,
            saturation: saturation * 0.86,
            brightness: brightness,
            alpha: 1.0
        ))
    }

    private var distinctAuthors: [User] {
        pendingTweets.reduce(into: [User]()) { result, tweet in
            let author = tweet.author ?? User.getInstance(mid: tweet.authorId)
            guard !result.contains(where: { $0.mid == author.mid }) else { return }
            result.append(author)
        }
    }

    private var avatarCluster: some View {
        let items = avatarClusterItems(from: distinctAuthors)
        let avatarCount = max(1, items.count)
        let avatarSize: CGFloat = 32
        let trailingReveal: CGFloat = 7
        let width = avatarSize + CGFloat(avatarCount - 1) * trailingReveal

        return ZStack(alignment: .leading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                avatarView(for: item, size: avatarSize)
                    .offset(x: CGFloat(index) * trailingReveal)
                    .zIndex(Double(avatarCount - index))
            }
        }
        .frame(width: width, height: avatarSize)
    }

    private func avatarClusterItems(from authors: [User]) -> [AvatarClusterItem] {
        if authors.isEmpty {
            return [AvatarClusterItem(id: "default-0", user: nil, opacity: 1.0)]
        }

        if authors.count <= 5 {
            return authors.map { author in
                AvatarClusterItem(id: author.mid, user: author, opacity: 1.0)
            }
        }

        let firstAuthors = authors.prefix(2).map { author in
            AvatarClusterItem(id: author.mid, user: author, opacity: 1.0)
        }
        let placeholders = [
            AvatarClusterItem(id: "default-more-0", user: nil, opacity: 0.42),
            AvatarClusterItem(id: "default-more-1", user: nil, opacity: 0.42)
        ]
        let lastAuthor = authors[authors.count - 1]
        return firstAuthors + placeholders + [
            AvatarClusterItem(id: lastAuthor.mid, user: lastAuthor, opacity: 1.0)
        ]
    }

    @ViewBuilder
    private func avatarView(for item: AvatarClusterItem, size: CGFloat) -> some View {
        if let user = item.user {
            Avatar(user: user, size: size)
                .frame(width: size, height: size)
        } else {
            Circle()
                .fill(XTheme.secondaryBackgroundColor)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(XTheme.secondaryTextColor)
                )
                .frame(width: size, height: size)
                .opacity(item.opacity)
        }
    }

    private func scheduleAutoHide() {
        let ids = pendingTweets.map(\.mid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            guard viewModel.visiblePendingNewTweets.map(\.mid) == ids else { return }
            Task { @MainActor in
                viewModel.dismissNewTweetsBanner()
            }
        }
    }
}
