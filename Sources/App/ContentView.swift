import SwiftUI

// Main ContentView
@available(iOS 17.0, *)
struct ContentView: View {
    @StateObject private var hproseInstance = HproseInstance.shared
    @StateObject private var chatSessionManager = ChatSessionManager.shared
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var selectedTab = 0
    @State private var showComposeSheet = false
    @State private var isNavigationVisible = true
    @State private var navigationPath = NavigationPath()
    @State private var chatNavigationPath = NavigationPath()
    @State private var isInChatScreen = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .success
    
    var body: some View {
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
                        ChatListScreen()
                    }
                    .onChange(of: chatNavigationPath.count) { _, count in
                        isInChatScreen = count > 0
                    }
                } else if selectedTab == 3 {
                    SearchScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: isNavigationVisible ? 40 : 0)
            }
            
            // Custom Tab Bar - Hide when in chat screen
            if !isInChatScreen {
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
                    selectedTab = 1
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
                    showComposeSheet = true
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
            .shadow(color: Color(.systemBlue).opacity(0.3), radius: 1, x: 0, y: -1)
            .opacity(isNavigationVisible ? 1.0 : 0.3)
            .allowsHitTesting(true)
            .animation(.easeInOut(duration: 0.3), value: isNavigationVisible)
        }
        }
        .sheet(isPresented: $showComposeSheet) {
            ComposeTweetView()
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
                isNavigationVisible = isVisible
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
                toastMessage = error.localizedDescription
                toastType = .error
                showToast = true
                
                // Auto-hide toast after 5 seconds for errors
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
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
        .environmentObject(hproseInstance)
        .environmentObject(themeManager)
    }
}

@available(iOS 17.0, *)
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(ThemeManager.shared)
    }
} 
