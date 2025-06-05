import SwiftUI

// Main ContentView
@available(iOS 17.0, *)
struct ContentView: View {
    @StateObject private var hproseInstance = HproseInstance.shared
    @State private var selectedTab = 0
    @State private var showComposeSheet = false
    
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }
            .tag(0)

            // Dummy view for Compose tab
            Color.clear
                .tabItem {
                    Label("Compose", systemImage: "square.and.pencil")
                }
                .tag(1)
        }
        .onChange(of: selectedTab) { newValue in
            if newValue == 1 {
                showComposeSheet = true
                selectedTab = 0 // Switch back to Home tab
            }
        }
        .sheet(isPresented: $showComposeSheet) {
            ComposeTweetView()
        }
        .environmentObject(hproseInstance)
    }
}

@available(iOS 17.0, *)
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
} 
