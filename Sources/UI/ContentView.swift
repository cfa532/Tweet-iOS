import SwiftUI

// Main ContentView
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
} 
