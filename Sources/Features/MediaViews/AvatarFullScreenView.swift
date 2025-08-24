import SwiftUI
import SDWebImageSwiftUI

struct AvatarFullScreenView: View {
    let user: User
    @Binding var isPresented: Bool
    @State private var imageState: AvatarImageState = .loading
    
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
                    AvatarImageViewWithPlaceholder(
                        url: url,
                        imageState: imageState
                    )
                    .onAppear {
                        loadAvatarImageIfNeeded(url: url)
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
    
    private func loadAvatarImageIfNeeded(url: URL) {
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

// MARK: - Avatar Image State
enum AvatarImageState {
    case loading
    case placeholder(UIImage)
    case loaded(UIImage)
    case error
}

// MARK: - Avatar Image View With Placeholder
struct AvatarImageViewWithPlaceholder: View {
    let url: URL
    let imageState: AvatarImageState
    
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                
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
                .scaleEffect(scale)
                .offset(offset)
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let delta = value / lastScale
                            lastScale = value
                            scale = min(max(scale * delta, 1.0), 4.0)
                        }
                        .onEnded { _ in
                            lastScale = 1.0
                            // Snap back to bounds if needed
                            if scale < 1.0 {
                                withAnimation(.easeOut(duration: 0.3)) {
                                    scale = 1.0
                                    offset = .zero
                                }
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 15)
                        .onChanged { value in
                            // Only handle drag when zoomed in
                            if scale > 1.0 {
                                let delta = CGSize(
                                    width: value.translation.width - lastOffset.width,
                                    height: value.translation.height - lastOffset.height
                                )
                                lastOffset = value.translation
                                
                                let maxOffsetX = (geometry.size.width * (scale - 1.0)) / 2
                                let maxOffsetY = (geometry.size.height * (scale - 1.0)) / 2
                                
                                offset = CGSize(
                                    width: max(-maxOffsetX, min(maxOffsetX, offset.width + delta.width)),
                                    height: max(-maxOffsetY, min(maxOffsetY, offset.height + delta.height))
                                )
                            }
                        }
                        .onEnded { _ in
                            lastOffset = .zero
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        if scale > 1.0 {
                            scale = 1.0
                            offset = .zero
                        } else {
                            scale = 2.0
                        }
                    }
                }
            }
        }
        .clipped()
    }
} 
