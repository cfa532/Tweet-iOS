import SwiftUI

// Main ContentView
@available(iOS 17.0, *)
struct ContentView: View {
    @StateObject private var hproseInstance = HproseInstance.shared
    @StateObject private var chatSessionManager = ChatSessionManager.shared
    @StateObject private var uploadProgressManager = UploadProgressManager.shared
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var selectedTab = 0
    @State private var showComposeSheet = false
    @State private var isNavigationVisible = true
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
    
    var body: some View {
        let _ = NSLog("DEBUG: [ContentView] ContentView body is being rendered")
        ZStack(alignment: .bottom) {
            // Main content area
            VStack(spacing: 0) {
                if selectedTab == 0 {
                    NavigationStack(path: $navigationPath) {
                        HomeView(
                            navigationPath: $navigationPath,
                            onNavigationVisibilityChanged: { isVisible in
                                print("[ContentView] Navigation visibility changed to: \(isVisible)")
                                isNavigationVisible = isVisible
                            },
                            onReturnToHome: {
                                selectedTab = 0
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
                    SearchScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) {
                Color.clear
                    .frame(height: 40)
            }
            
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
                    }
                }) {
                    Image(systemName: "house")
                        .font(.system(size: 24))
                        .foregroundColor(navigationPath.isEmpty && selectedTab == 0 ? .blue : .gray)
                }
                .frame(maxWidth: .infinity)
                
                // Chat Tab
                Button(action: {
                    if selectedTab != 1 {
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
                            .foregroundColor(selectedTab == 1 ? .blue : .gray)
                        
                        // Badge for unread messages
                        BadgeView(count: chatSessionManager.unreadMessageCount)
                            .offset(x: 12, y: -12)
                    }
                }
                .frame(maxWidth: .infinity)
                
                // Compose Tab
                Button(action: {
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
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
                
                // Search Tab
                Button(action: {
                    selectedTab = 3
                }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundColor(selectedTab == 3 ? .blue : .gray)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 16)
            .padding(.bottom, 2)
            .background(
                Color(.systemBackground)
                    .opacity(isNavigationVisible ? 1.0 : 0.0)
            )
            .shadow(color: Color(.systemBlue).opacity(isNavigationVisible ? 0.3 : 0.0), radius: 1, x: 0, y: -1)
            .opacity(isNavigationVisible ? 1.0 : 0.3)
            .allowsHitTesting(true)
            .animation(.easeInOut(duration: 0.25), value: isNavigationVisible)
        }
        }
        .sheet(isPresented: $showComposeSheet) {
            ComposeTweetView()
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
        .onReceive(NotificationCenter.default.publisher(for: .tweetSubmitted)) { notification in
            if let message = notification.userInfo?["message"] as? String {
                toastMessage = message
                toastType = .success
                showToast = true
                
                // Auto-hide toast after 2 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation { showToast = false }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tweetPrivacyUpdated)) { notification in
            if let message = notification.userInfo?["message"] as? String,
               let typeString = notification.userInfo?["type"] as? String {
                toastMessage = message
                toastType = typeString == "error" ? .error : .success
                showToast = true
                
                // Auto-hide toast after 2 seconds for success, 5 seconds for error
                let delay = typeString == "error" ? 5.0 : 2.0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation { showToast = false }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigationVisibilityChanged)) { notification in
            if let isVisible = notification.userInfo?["isVisible"] as? Bool {
                print("[ContentView] Navigation visibility changed to: \(isVisible)")
                withAnimation(.easeInOut(duration: 0.25)) {
                    isNavigationVisible = isVisible
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTweetCreated)) { notification in
            if notification.userInfo?["tweet"] is Tweet {
                toastMessage = NSLocalizedString("Tweet posted successfully", comment: "Tweet upload success")
                toastType = .success
                showToast = true
                
                // Auto-hide toast after 2 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation { showToast = false }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newCommentAdded)) { notification in
            if notification.userInfo?["comment"] is Tweet {
                toastMessage = NSLocalizedString("Comment posted successfully", comment: "Comment upload success")
                toastType = .success
                showToast = true
                
                // Auto-hide toast after 2 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation { showToast = false }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .backgroundUploadFailed)) { notification in
            if let error = notification.userInfo?["error"] as? Error {
                toastMessage = ErrorMessageHelper.userFriendlyMessage(from: error)
                toastType = .error
                showToast = true
                
                // Auto-hide toast after 5 seconds for errors
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    withAnimation { showToast = false }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryWarningCritical)) { notification in
            if let memoryMB = notification.userInfo?["memoryMB"] as? UInt64,
               let severity = notification.userInfo?["severity"] as? String {
                
                let memoryGB = String(format: "%.1f", Double(memoryMB) / 1024.0)
                
                if severity == "critical" {
                    toastMessage = NSLocalizedString("Memory critically low (\(memoryGB)GB). Please restart the app to free resources.", comment: "Critical memory warning")
                } else {
                    toastMessage = NSLocalizedString("Memory is running low (\(memoryGB)GB). Consider restarting the app if issues persist.", comment: "High memory warning")
                }
                
                toastType = .error
                showToast = true
                
                // Keep toast visible longer for memory warnings (10 seconds)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    withAnimation { showToast = false }
                }
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
            checkForPendingUpload()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Check for pending uploads when app returns to foreground
            checkForPendingUpload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .deeplinkReceived)) { notification in
            // Handle deeplink navigation
            print("[ContentView] ✅ Received deeplink notification")
            if let url = notification.userInfo?["url"] as? URL {
                print("[ContentView] URL from notification: \(url.absoluteString)")
                handleDeeplink(url)
            } else {
                print("[ContentView] ⚠️ No URL found in notification userInfo")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deeplinkTweetNotFound)) { notification in
            // Show error toast when deeplink tweet is not found
            if let message = notification.userInfo?["message"] as? String {
                toastMessage = message
                toastType = .error
                showToast = true
                
                // Auto-hide toast after 5 seconds for errors
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    withAnimation { showToast = false }
                }
            }
        }
        .environmentObject(hproseInstance)
        .environmentObject(themeManager)
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
            // Determine upload type
            let uploadType = upload.tweet.originalTweetId != nil ? "comment" : "tweet"
            
            // Start progress tracking (shows dialog in foreground)
            await MainActor.run {
                UploadProgressManager.shared.startUpload(type: uploadType)
            }
            
            // Retry the upload using the upload manager
            // If there's an existing video job ID, it will check status and poll
            // If not, it will re-upload attachments in foreground (with dialog visible)
            await hproseInstance.uploadManager.uploadTweetWithPersistenceAndRetry(
                tweet: upload.tweet,
                itemData: upload.itemData,
                retryCount: upload.retryCount,
                videoJobId: upload.videoJobId
            )
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
