import SwiftUI

@available(iOS 16.0, *)
struct AppHeaderView: View {
    @State private var isLoginSheetPresented = false
    @State private var isSettingsSheetPresented = false
    @State private var showProfile = false
    @EnvironmentObject private var hproseInstance: HproseInstance

    var onAppIconTap: () -> Void = {}
    
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
                Avatar(user: hproseInstance.appUser, size: 32)
            }
            .background(
                NavigationLink(
                    destination: ProfileView(user: hproseInstance.appUser, onLogout: {}), // Replace [] with actual tweets
                    isActive: $showProfile
                ) {
                    EmptyView()
                }
                .hidden()
            )
            
            Spacer()
            
            // Middle: App Logo
            Button(action: { onAppIconTap() }) {
                Image("AppIcon") // Make sure to add this to your asset catalog
                    .resizable()
                    .scaledToFit()
                    .frame(height: 32)
            }
            
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
    }
}
