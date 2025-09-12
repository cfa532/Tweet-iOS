import SwiftUI
import SDWebImageSwiftUI

struct AvatarFullScreenView: View {
    let user: User
    @Binding var isPresented: Bool
    @State private var imageState: AvatarImageState = .loading
    @State private var showCopyToast = false
    @State private var copyToastMessage = ""
    
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
                    AvatarImageThumbnail(
                        url: url,
                        imageState: imageState
                    )
                    .onAppear {
                        loadAvatarImageIfNeeded(url: url)
                    }
                } else {
                    Image("manyone")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                Spacer()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text(user.mid)
                        .onLongPressGesture {
                            copyToClipboard(user.mid, label: "User ID")
                        }
                    
                    if let baseUrl = user.baseUrl {
                        Text(baseUrl.absoluteString)
                            .onLongPressGesture {
                                copyToClipboard(baseUrl.absoluteString, label: "Base URL")
                            }
                    }
                    
                    if let hostId = user.hostIds?.first {
                        Text(hostId)
                            .onLongPressGesture {
                                copyToClipboard(hostId, label: "Host ID")
                            }
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
            
            // Copy toast overlay
            if showCopyToast {
                VStack {
                    Spacer()
                    Text(copyToastMessage)
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(8)
                        .padding(.bottom, 100)
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: showCopyToast)
            }
        }
    }
    
    private func copyToClipboard(_ text: String, label: String) {
        UIPasteboard.general.string = text
        copyToastMessage = "\(label) copied to clipboard"
        showCopyToast = true
        
        // Hide toast after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            showCopyToast = false
        }
    }
    
    private func loadAvatarImageIfNeeded(url: URL) {
        // Create a MimeiFileType for the avatar using the URL's lastPathComponent as mid
        let avatarAttachment = MimeiFileType(
            mid: url.lastPathComponent,
            mediaType: .image
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

// MARK: - Avatar Image State
enum AvatarImageState {
    case loading
    case placeholder(UIImage)
    case loaded(UIImage)
    case error
}

// MARK: - Avatar Image Thumbnail
struct AvatarImageThumbnail: View {
    let url: URL
    let imageState: AvatarImageState
    
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
    }
} 
