import SwiftUI

@available(iOS 16.0, *)
struct AppHeaderView: View {
    @State private var isLoginSheetPresented = false
    @State private var isSettingsSheetPresented = false
    @State private var showProfile = false
    @EnvironmentObject private var hproseInstance: HproseInstance
    
    var body: some View {
        HStack {
            // Left: User Avatar
            Button(action: {
                if hproseInstance.appUser.isGuest {
                    isLoginSheetPresented = true
                } else {
                    showProfile = true
                }
            }) {
                Avatar(user: hproseInstance.appUser, size: 36)
            }
            
            Spacer()
            
            // Middle: App Logo
            Image("AppIcon") // Make sure to add this to your asset catalog
                .resizable()
                .scaledToFit()
                .frame(height: 32)
            
            Spacer()
            
            // Right: Settings Button
            Button(action: {
                isSettingsSheetPresented = true
            }) {
                Image(systemName: "gearshape.fill")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundColor(.primary)
            }
        }
        .padding(.horizontal)
        .sheet(isPresented: $isLoginSheetPresented) {
            LoginView()
        }
        .sheet(isPresented: $isSettingsSheetPresented) {
            SettingsView()
        }
        .navigationDestination(isPresented: $showProfile) {
            ProfileView(user: hproseInstance.appUser, onLogout: {})
        }
    }
}
