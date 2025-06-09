import SwiftUI

struct UserSearchView: View {
    @State private var appUser: User = User(mid: Constants.GUEST_ID)
    @EnvironmentObject private var appUserStore: AppUserStore
    
    var body: some View {
        // ... existing code ...

    }
}

struct UserSearchView_Previews: PreviewProvider {
    static var previews: some View {
        UserSearchView()
    }
} 
