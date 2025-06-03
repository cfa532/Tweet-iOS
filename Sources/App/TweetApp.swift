import SwiftUI
import BackgroundTasks

@MainActor
class AppState: ObservableObject {
    @Published var isInitialized = false
    @Published var error: Error?
    
    func initialize() async {
        do {
            try await HproseInstance.shared.initialize()
            isInitialized = true
        } catch {
            self.error = error
        }
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
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if appState.isInitialized {
                    ContentView()
                } else {
                    ProgressView("Initializing...")
                        .task {
                            await appState.initialize()
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
