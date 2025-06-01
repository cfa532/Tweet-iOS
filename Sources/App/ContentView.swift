import SwiftUI

// Main ContentView
@available(iOS 17.0, *)
struct ContentView: View {
    @StateObject private var hproseInstance = HproseInstance.shared
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }
            .tag(0)
            .onChange(of: selectedTab) { newValue in
                if newValue == 0 {
                    // Pop to root when home tab is selected
                    NotificationCenter.default.post(
                        name: .popToRoot,
                        object: nil
                    )
                }
            }
            
            ComposeTweetView()
                .tabItem {
                    Label("Compose", systemImage: "square.and.pencil")
                }
                .tag(1)
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
