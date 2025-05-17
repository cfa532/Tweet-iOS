import SwiftUI

// Main ContentView
@available(iOS 16.0, *)
struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }
            
            ComposeTweetView()
                .tabItem {
                    Label("Compose", systemImage: "square.and.pencil")
                }
            
        }
    }
}

@available(iOS 16.0, *)
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
} 
