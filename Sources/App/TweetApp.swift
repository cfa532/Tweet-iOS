import SwiftUI
import BackgroundTasks
import MetricKit

@MainActor
class AppState: ObservableObject {
    @Published var isInitialized = false
    @Published var error: Error?
    @Published var isLoading = true  // Add loading state
    @Published var canShowCachedContent = false  // Allow showing cached content immediately
    
    func initialize() async {
        // Initialize basic components first (no network calls)
        HproseInstance.shared.preferenceHelper = PreferenceHelper()
        
        // Cache screen width for background tweet height pre-warming.
        // Formula: screenWidth - 8(leading) - 8(trailing) - 3 - 42(avatar) - 4 = screenWidth - 65.
        TweetHeightPrewarmer.shared.standardContentWidth = UIScreen.main.bounds.width - 65

        // Let SwiftUI paint cached content immediately. User/cache/network
        // initialization continues below without holding the launch screen.
        canShowCachedContent = true
        isLoading = false
        
        // Continue with full network initialization off the first paint path.
        Task.detached(priority: .userInitiated) {
            do {
                await HproseInstance.shared.initializeAppUser()
                try await HproseInstance.shared.initAppEntry()
                await MainActor.run {
                    self.isInitialized = true
                }
                
                // Chat sessions will be loaded lazily when chat screens are accessed
                // Check for new messages (only updates badge, no notifications)
                await ChatSessionManager.shared.checkBackendForNewMessages(suppressNotifications: true)
                print("[TweetApp] ✅ Initial message check completed after app initialization")
                
                // Refresh mute state from preferences after HproseInstance is ready
                MuteState.shared.refreshFromPreferences()
                
                // Refresh theme state from preferences after HproseInstance is ready
                await ThemeManager.shared.refreshFromPreferences()
                
                // Audio session and video players will be initialized lazily when first needed
                // to avoid blocking app startup
                
                // Cleanup caches after a delay
                Task.detached(priority: .background) {
                    // Wait 30 seconds after app initialization
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    // Clean up image cache
                    ImageCacheManager.shared.cleanupOldCache()
                }
            } catch {
                // Even if initAppEntry fails, mark initialization as complete
                // so the app can still function and fetch users from server
                await MainActor.run {
                    self.error = error
                    // Mark HproseInstance initialization as complete even on failure
                    // This allows user fetches to proceed with resolved IPs
                    HproseInstance.shared.markInitializationComplete()
                }
                print("DEBUG: [AppState] initAppEntry failed but marking initialization complete: \(error)")
            }
            
            // Always start periodic tasks (idempotent inside HproseInstance)
            HproseInstance.shared.startPeriodicBlackListProcessing()
        }
    }
}

@available(iOS 17.0, *)
@main
struct TweetApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var orientationManager = OrientationManager.shared
    @State private var showGlobalAlert = false
    @State private var globalAlertMessage = ""
    
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        // Initialize MetricKit
        _ = MetricKitManager.shared
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if appState.isLoading {
                    // Show loading view during basic initialization
                    ProgressView(NSLocalizedString("Initializing...", comment: "App initialization progress"))
                        .task {
                            await appState.initialize()
                        }
                } else if appState.canShowCachedContent {
                    // Show content view immediately with cached data
                    ContentView()
                        .environmentObject(themeManager)
                        .environmentObject(orientationManager)
                } else if appState.error != nil {
                    // Show error state if initialization failed
                    VStack {
                        Text(NSLocalizedString("Failed to initialize app", comment: "App initialization error"))
                        if let error = appState.error {
                            Text(error.localizedDescription)
                                .foregroundColor(.red)
                        }
                        Button(NSLocalizedString("Retry", comment: "Retry button")) {
                            Task {
                                await appState.initialize()
                            }
                        }
                    }
                } else {
                    // Fallback loading state
                    ProgressView(NSLocalizedString("Loading...", comment: "App loading progress"))
                }
            }
            .alert(isPresented: $showGlobalAlert) {
                Alert(title: Text(LocalizedStringKey("Error")), message: Text(globalAlertMessage), dismissButton: .default(Text(LocalizedStringKey("OK"))))
            }
            .onReceive(NotificationCenter.default.publisher(for: .backgroundUploadFailed)) { notification in
                if let msg = notification.userInfo?["error"] as? String {
                    globalAlertMessage = msg
                } else {
                    globalAlertMessage = NSLocalizedString("Background upload failed.", comment: "Background upload error")
                }
                showGlobalAlert = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .tweetPublishFailed)) { notification in
                if let msg = notification.userInfo?["error"] as? String {
                    globalAlertMessage = msg
                } else {
                    globalAlertMessage = NSLocalizedString("Failed to publish tweet.", comment: "Tweet publish error")
                }
                showGlobalAlert = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .tweetDeletdFailed)) { notification in
                if let msg = notification.userInfo?["error"] as? String {
                    globalAlertMessage = msg
                } else {
                    globalAlertMessage = NSLocalizedString("Failed to delete tweet.", comment: "Tweet delete error")
                }
                showGlobalAlert = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .commentPublishFailed)) { notification in
                if let msg = notification.userInfo?["error"] as? String {
                    globalAlertMessage = msg
                } else {
                    globalAlertMessage = NSLocalizedString("Failed to publish comment.", comment: "Comment publish error")
                }
                showGlobalAlert = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .commentDeleteFailed)) { notification in
                if let msg = notification.userInfo?["error"] as? String {
                    globalAlertMessage = msg
                } else {
                    globalAlertMessage = NSLocalizedString("Failed to delete comment.", comment: "Comment delete error")
                }
                showGlobalAlert = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openChatFromNotification)) { notification in
                // Handle chat notification tap
                if let senderId = notification.userInfo?["senderId"] as? String {
                    // Navigate to chat screen with the sender
                    // This will be handled by the navigation system
                    print("[TweetApp] Received notification to open chat with: \(senderId)")
                }
            }
            .onOpenURL { url in
                // SwiftUI's onOpenURL handler - works for both custom schemes and Universal Links
                print("[TweetApp] ✅ SwiftUI onOpenURL received: \(url.absoluteString)")
                print("[TweetApp] URL scheme: \(url.scheme ?? "nil"), host: \(url.host ?? "nil"), path: \(url.path)")
                
                // Post notification for ContentView to handle
                NotificationCenter.default.post(
                    name: .deeplinkReceived,
                    object: nil,
                    userInfo: ["url": url]
                )
            }
        }
    }
} 
