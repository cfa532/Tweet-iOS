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
            
            // Cleanup caches after a delay
            Task.detached(priority: .background) {
                // Wait 3 seconds after app initialization
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
    @State private var showGlobalAlert = false
    @State private var globalAlertMessage = ""
    
    init() {
        // Configure background task scheduler
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.tweet.upload",
            using: nil
        ) { task in
            HproseInstance.handleBackgroundTask(task: task as! BGProcessingTask)
        }
        
        // Initialize MetricKit
        _ = MetricKitManager.shared
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if appState.isLoading {
                    // Show loading view during initialization
                    ProgressView("Initializing...")
                        .task {
                            await appState.initialize()
                        }
                } else if appState.isInitialized {
                    // Only show content view after initialization is complete
                    ContentView()
                } else {
                    // Show error state if initialization failed
                    VStack {
                        Text("Failed to initialize app")
                        if let error = appState.error {
                            Text(error.localizedDescription)
                                .foregroundColor(.red)
                        }
                        Button("Retry") {
                            Task {
                                await appState.initialize()
                            }
                        }
                    }
                }
            }
            .alert(isPresented: $showGlobalAlert) {
                Alert(title: Text("Error"), message: Text(globalAlertMessage), dismissButton: .default(Text("OK")))
            }
            .onReceive(NotificationCenter.default.publisher(for: .backgroundUploadFailed)) { notification in
                if let msg = notification.userInfo?["error"] as? String {
                    globalAlertMessage = msg
                } else {
                    globalAlertMessage = "Background upload failed."
                }
                showGlobalAlert = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .tweetPublishFailed)) { notification in
                if let msg = notification.userInfo?["error"] as? String {
                    globalAlertMessage = msg
                } else {
                    globalAlertMessage = "Failed to publish tweet."
                }
                showGlobalAlert = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .tweetDeletdFailed)) { notification in
                if let msg = notification.userInfo?["error"] as? String {
                    globalAlertMessage = msg
                } else {
                    globalAlertMessage = "Failed to delete tweet."
                }
                showGlobalAlert = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .commentPublishFailed)) { notification in
                if let msg = notification.userInfo?["error"] as? String {
                    globalAlertMessage = msg
                } else {
                    globalAlertMessage = "Failed to publish comment."
                }
                showGlobalAlert = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .commentDeleteFailed)) { notification in
                if let msg = notification.userInfo?["error"] as? String {
                    globalAlertMessage = msg
                } else {
                    globalAlertMessage = "Failed to delete comment."
                }
                showGlobalAlert = true
            }
            .alert("Error", isPresented: .constant(appState.error != nil)) {
                Button("OK") {
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

