import SwiftUI

// Main ContentView
@available(iOS 17.0, *)
struct ContentView: View {
    @StateObject private var hproseInstance = HproseInstance.shared
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var selectedTab = 0
    @State private var showComposeSheet = false
    @State private var isNavigationVisible = true
    @State private var navigationPath = NavigationPath()
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Main content area
            VStack(spacing: 0) {
                if selectedTab == 0 {
                    NavigationStack(path: $navigationPath) {
                        HomeView(
                            navigationPath: $navigationPath,
                            onNavigationVisibilityChanged: { isVisible in
                                isNavigationVisible = isVisible
                            },
                            onReturnToHome: {
                                selectedTab = 0
                            }
                        )
                    }
                } else if selectedTab == 1 {
                    ChatListScreen()
                } else if selectedTab == 3 {
                    SearchScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: isNavigationVisible ? 40 : 0)
            }
            
            // Custom Tab Bar
            HStack(spacing: 0) {
                // Home Tab
                Button(action: {
                    if selectedTab != 0 {
                        selectedTab = 0
                    } else if !navigationPath.isEmpty {
                        navigationPath.removeLast(navigationPath.count)
                        selectedTab = 0
                    }
                }) {
                    Image(systemName: "house")
                        .font(.system(size: 24))
                        .foregroundColor(navigationPath.isEmpty && selectedTab == 0 ? .blue : .gray)
                }
                .frame(maxWidth: .infinity)
                
                // Chat Tab
                Button(action: {
                    selectedTab = 1
                }) {
                    ZStack {
                        Image(systemName: "message")
                            .font(.system(size: 24))
                            .foregroundColor(selectedTab == 1 ? .blue : .gray)
                        
                        // Badge for unread messages
                        BadgeView(count: 0) // TODO: Update with actual unread count
                            .offset(x: 12, y: -12)
                    }
                }
                .frame(maxWidth: .infinity)
                
                // Compose Tab
                Button(action: {
                    showComposeSheet = true
                }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 24))
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
                
                // Search Tab
                Button(action: {
                    selectedTab = 3
                }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundColor(selectedTab == 3 ? .blue : .gray)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 16)
            .padding(.bottom, 2)
            .background(
                isNavigationVisible ? 
                Color(.systemBackground).opacity(1.0) : 
                Color.clear
            )
            .shadow(color: Color(.systemBlue).opacity(0.3), radius: 1, x: 0, y: -1)
            .opacity(isNavigationVisible ? 1.0 : 0.3)
            .allowsHitTesting(true)
            .animation(.easeInOut(duration: 0.3), value: isNavigationVisible)
        }
        .sheet(isPresented: $showComposeSheet) {
            ComposeTweetView()
        }
        .environmentObject(hproseInstance)
        .environmentObject(themeManager)
    }
}

@available(iOS 17.0, *)
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(ThemeManager.shared)
    }
} 
