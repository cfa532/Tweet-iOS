import SwiftUI

// Main ContentView
@available(iOS 17.0, *)
struct ContentView: View {
    @StateObject private var hproseInstance = HproseInstance.shared
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var selectedTab = 0
    @State private var showComposeSheet = false
    @State private var isNavigationVisible = true
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Main content area
            VStack(spacing: 0) {
                if selectedTab == 0 {
                    NavigationStack {
                        HomeView(onNavigationVisibilityChanged: { isVisible in
                            isNavigationVisible = isVisible
                        })
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Custom Tab Bar (always present, fades out when navigation is hidden)
            HStack(spacing: 0) {
                Button(action: {
                    selectedTab = 0
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: "house")
                            .font(.system(size: 24))
                        Text("Home")
                            .font(.caption)
                    }
                    .foregroundColor(selectedTab == 0 ? .blue : .gray)
                }
                .frame(maxWidth: .infinity)
                
                Button(action: {
                    showComposeSheet = true
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 24))
                        Text("Compose")
                            .font(.caption)
                    }
                    .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 8)
            .background(isNavigationVisible ? Color(.systemBackground) : Color.clear)
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color(.separator)),
                alignment: .top
            )
            .opacity(isNavigationVisible ? 1.0 : 0.2)
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
