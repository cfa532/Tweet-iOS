import SwiftUI

// Main ContentView
@available(iOS 17.0, *)
struct ContentView: View {
    @StateObject private var userViewModel = UserViewModel()
    
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
        .environmentObject(userViewModel)
    }
}

@available(iOS 17.0, *)
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
} 
