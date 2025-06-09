import SwiftUI

struct TweetReplyView: View {
    @State private var appUser: User = User(mid: Constants.GUEST_ID)
    
    var body: some View {
        // ... existing code ...
        .task {
            appUser = await AppUserStore.shared.getAppUser()
        }
    }
}

struct TweetReplyView_Previews: PreviewProvider {
    static var previews: some View {
        TweetReplyView()
    }
} 