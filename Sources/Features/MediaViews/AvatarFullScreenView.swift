import SwiftUI

struct AvatarFullScreenView: View {
    @ObservedObject var user: User
    @Binding var isPresented: Bool
    @State private var imageState: AvatarImageState = .loading
    @State private var showCopyToast = false
    @State private var copyToastMessage = ""
    
    init(user: User, isPresented: Binding<Bool>) {
        self._user = ObservedObject(wrappedValue: user)
        self._isPresented = isPresented
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
                    .onChange(of: user.baseUrl) { _, _ in
                        // Reload avatar when baseUrl changes (e.g., after IP resolution)
                        // avatarUrl is computed from baseUrl, so it will also change
                        if let newAvatarUrl = user.avatarUrl, let newUrl = URL(string: newAvatarUrl) {
                            loadAvatarImageIfNeeded(url: newUrl)
                        }
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
        // Always start with loading state - bypass cache entirely for full-screen view
        imageState = .loading
        
        // Load original image directly from source, bypassing all caches
        Task {
            do {
                var request = URLRequest(url: url)
                // Bypass all caches (memory, disk, and network cache)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.timeoutInterval = 15
                
                // Use URLSession with ephemeral configuration to ensure no caching
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil
                config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                let session = URLSession(configuration: config)
                
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let image = UIImage(data: data) else {
                    throw URLError(.badServerResponse)
                }
                
                await MainActor.run {
                    imageState = .loaded(image)
                }
            } catch {
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
