import SwiftUI

@available(iOS 16.0, *)
struct AppHeaderView: View {
    @State private var isLoginSheetPresented = false
    @State private var isSettingsSheetPresented = false
    @State private var showProfile = false
    @EnvironmentObject var hproseInstance: HproseInstance
    
    var onAppIconTap: () -> Void = {}
    
    var body: some View {
        HStack {
            // Left: User Avatar
            NavigationLink {

                    ProfileView(user: AppUser.shared)

            } label: {
                HStack {
                    if let avatar = AppUser.shared.avatar {
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
    }
}
