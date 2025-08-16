import SwiftUI
import BackgroundTasks
import MetricKit

@MainActor
class AppState: ObservableObject {
    @Published var isInitialized = false
    @Published var error: Error?
    @Published var isLoading = true  // Add loading state
    
    func initialize() async {
        isLoading = true  // Set loading state at start
        do {
            try await HproseInstance.shared.initialize()
            isInitialized = true
            
            // Load chat sessions after user is properly initialized
            ChatSessionManager.shared.loadSessionsWhenUserAvailable()
            
            // Refresh mute state from preferences after HproseInstance is ready
            MuteState.shared.refreshFromPreferences()
            
            // Refresh theme state from preferences after HproseInstance is ready
            ThemeManager.shared.refreshFromPreferences()
            
            // Cleanup caches after a delay
            Task.detached(priority: .background) {
                // Wait 30 seconds after app initialization
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                // Clean up image cache
                ImageCacheManager.shared.cleanupOldCache()
            }
        } catch {
            self.error = error
        }
        isLoading = false  // Clear loading state when done
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
                    // Show loading view during initialization
                    ProgressView(NSLocalizedString("Initializing...", comment: "App initialization progress"))
                        .task {
                            await appState.initialize()
                        }
                } else if appState.isInitialized {
                    // Only show content view after initialization is complete
                    ContentView()
                        .environmentObject(themeManager)
                        .environmentObject(orientationManager)
                } else {
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
            .alert(NSLocalizedString("Error", comment: "Error alert title"), isPresented: .constant(appState.error != nil)) {
                Button(NSLocalizedString("OK", comment: "OK button")) {
                    appState.error = nil
                }
            } message: {
                if let error = appState.error {
                    Text(error.localizedDescription)
                }
            }
        }
    }
} 

