import SwiftUI

struct AvatarFullScreenView: View {
    let user: User
    @Binding var isPresented: Bool
    @State private var imageState: ImageState = .loading
    
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
                if let avatarUrl = user.avatarUrl {
                    AvatarImageViewWithPlaceholder(
                        avatarUrl: avatarUrl,
                        baseUrl: baseUrl,
                        imageState: imageState
                    )
                    .onAppear {
                        loadAvatarIfNeeded()
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
    
    private func loadAvatarIfNeeded() {
        guard let avatarUrl = user.avatarUrl,
              let url = URL(string: avatarUrl) else { return }
        
        // Create a MimeiFileType for the avatar using the URL's lastPathComponent as mid
        let avatarAttachment = MimeiFileType(
            mid: url.lastPathComponent,
            type: "image"
        )
        
        // Show compressed image as placeholder first
        if let compressedImage = ImageCacheManager.shared.getCompressedImage(for: avatarAttachment, baseUrl: baseUrl) {
            imageState = .placeholder(compressedImage)
        } else {
            imageState = .loading
        }
        
        // Load original image from backend
        Task {
            if let originalImage = await ImageCacheManager.shared.loadOriginalImage(from: url, for: avatarAttachment, baseUrl: baseUrl) {
                await MainActor.run {
                    imageState = .loaded(originalImage)
                }
            } else {
                await MainActor.run {
                    imageState = .error
                }
            }
        }
    }
}

// MARK: - Avatar Image View With Placeholder
struct AvatarImageViewWithPlaceholder: View {
    let avatarUrl: String
    let baseUrl: URL
    let imageState: ImageState
    
    var body: some View {
        Group {
            switch imageState {
            case .loading:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.5)
                
            case .placeholder(let placeholderImage):
                Image(uiImage: placeholderImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay(
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.0)
                            .background(Color.black.opacity(0.3))
                            .clipShape(Circle())
                            .padding(),
                        alignment: .topTrailing
                    )
                
            case .loaded(let image):
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                
            case .error:
                VStack {
                    Image(systemName: "person.circle")
                        .font(.system(size: 50))
                        .foregroundColor(.gray)
                    Text(LocalizedStringKey("Failed to load avatar"))
                        .foregroundColor(.gray)
                        .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
} 
