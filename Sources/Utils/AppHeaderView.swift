import SwiftUI

@available(iOS 16.0, *)
struct AppHeaderView: View {
    @State private var isLoginSheetPresented = false
    @State private var isSettingsSheetPresented = false
    @State private var hproseInstance = HproseInstanceState.shared
    
    var body: some View {
        HStack {
            // Left: User Avatar
            if hproseInstance.appUser.isGuest {
                Button(action: {
                    isLoginSheetPresented = true
                }) {
                    Avatar(user: hproseInstance.appUser, size: 36)
                }
            } else {
                NavigationLink(value: hproseInstance.appUser) {
                    Avatar(user: hproseInstance.appUser, size: 36)
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            Spacer()
            
            // Middle: App Logo
            Image("tweet_icon")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            
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
