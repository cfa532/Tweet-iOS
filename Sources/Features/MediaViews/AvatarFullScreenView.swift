import SwiftUI
import SDWebImageSwiftUI

struct AvatarFullScreenView: View {
    let user: User
    @Binding var isPresented: Bool
    @State private var cachedPlaceholderImage: UIImage?
    
    private let baseUrl: URL
    
    init(user: User, isPresented: Binding<Bool>) {
        self.user = user
        self._isPresented = isPresented
        self.baseUrl = user.baseUrl ?? HproseInstance.baseUrl
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            
            VStack {
                Spacer()
                if let avatarUrl = user.avatarUrl, let url = URL(string: avatarUrl) {
                    ZoomableImageView(
                        imageURL: url,
                        placeholderImage: cachedPlaceholderImage,
                        contentMode: .fit
                    )
                    .onAppear {
                        loadCachedPlaceholder()
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
                        Text(baseUrl.absoluteString)
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
    
    private func loadCachedPlaceholder() {
        guard let avatarUrl = user.avatarUrl,
              let url = URL(string: avatarUrl) else { return }
        
        // Create a MimeiFileType for the avatar using the URL's lastPathComponent as mid
        let avatarAttachment = MimeiFileType(
            mid: url.lastPathComponent,
            type: "image"
        )
        
        // Load cached compressed image as placeholder
        if let compressedImage = ImageCacheManager.shared.getCompressedImage(for: avatarAttachment, baseUrl: baseUrl) {
            cachedPlaceholderImage = compressedImage
        }
    }
} 
