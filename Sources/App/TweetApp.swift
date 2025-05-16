import SwiftUI

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

@main
struct TweetApp: App {
    @StateObject private var appState = AppState()
    
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