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

@available(iOS 16.0, *)
@main
struct TweetApp: App {
    @StateObject private var appState = AppState()
    
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
