import SwiftUI

// Main ContentView
@available(iOS 17.0, *)
struct ContentView: View {
    @StateObject private var hproseInstance = HproseInstance.shared
    
    var body: some View {
        TabView {
            NavigationView {
                HomeView()
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }
            
            ComposeTweetView()
                .tabItem {
                    Label("Compose", systemImage: "square.and.pencil")
                }
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
