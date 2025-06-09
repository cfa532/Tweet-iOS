import SwiftUI

@available(iOS 16.0, *)
struct AppHeaderView: View {
    @State private var isLoginSheetPresented = false
    @State private var isSettingsSheetPresented = false
    @State private var showProfile = false
    @EnvironmentObject private var appUserStore: AppUserStore
    @EnvironmentObject var hproseInstance: HproseInstance
    @State private var currentUser: User?
    
    var onAppIconTap: () -> Void = {}
    
    var body: some View {
        HStack {
            // Left: User Avatar
            NavigationLink {
                if let user = currentUser {
                    ProfileView(user: user)
                }
            } label: {
                HStack {
                    if let avatar = currentUser?.avatar {
                        AsyncImage(url: URL(string: avatar)) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Image(systemName: "person.circle.fill")
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.circle.fill")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 32, height: 32)
                            .foregroundColor(.gray)
                    }
                    Text(currentUser?.name ?? "No One")
                        .font(.headline)
                        .foregroundColor(.primary)
                }
            }
            
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
        .task {
            currentUser = await appUserStore.appUser
        }
    }
}
