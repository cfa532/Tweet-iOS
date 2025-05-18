import SwiftUI

// Main ContentView
@available(iOS 16.0, *)
struct ContentView: View {
    @StateObject private var userViewModel = UserViewModel()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HeaderView()
                    .padding(.vertical, 8)
                
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
            .navigationBarHidden(true)
        }
        .environmentObject(userViewModel)
    }
}

@available(iOS 16.0, *)
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
} 
