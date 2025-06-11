import SwiftUI

struct AvatarFullScreenView: View {
    let user: User
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            VStack {
                Spacer()
                if let avatarUrl = user.avatarUrl, let url = URL(string: avatarUrl) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Color.gray
                    }
                } else {
                    Image("ic_splash")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Text(user.mid)
                    if let baseUrl = user.baseUrl {
                        Text(baseUrl)
                    }
                    if let hostId = user.hostIds?.first {
                        Text(hostId)
                    }
                }
                .foregroundColor(.white)
                .padding()
                .background(Color.black.opacity(0.7))
                .cornerRadius(12)
                .padding(.bottom, 32)
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.white)
                            .padding()
                    }
                }
                Spacer()
            }
        }
    }
} 
