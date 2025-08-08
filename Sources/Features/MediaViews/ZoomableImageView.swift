import SwiftUI
import SDWebImageSwiftUI

struct ZoomableImageView: View {
    let imageURL: URL?
    let placeholderImage: UIImage?
    let contentMode: ContentMode
    
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var isImageLoaded = false
    
    init(imageURL: URL?, placeholderImage: UIImage? = nil, contentMode: ContentMode = .fit) {
        self.imageURL = imageURL
        self.placeholderImage = placeholderImage
        self.contentMode = contentMode
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                
                if let imageURL = imageURL {
                    WebImage(url: imageURL, options: [.progressiveLoad])
                        .onSuccess { image, data, cacheType in
                            isImageLoaded = true
                        }
                        .onFailure { error in
                            // Handle error state
                        }
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .overlay(
                            Group {
                                if !isImageLoaded {
                                    if let placeholderImage = placeholderImage {
                                        Image(uiImage: placeholderImage)
                                            .resizable()
                                            .aspectRatio(contentMode: contentMode)
                                            .foregroundColor(.gray)
                                    } else {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                            .scaleEffect(1.5)
                                    }
                                }
                            }
                        )
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            SimultaneousGesture(
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
                                    },
                                DragGesture()
                                    .onChanged { value in
                                        let delta = CGSize(
                                            width: value.translation.width - lastOffset.width,
                                            height: value.translation.height - lastOffset.height
                                        )
                                        lastOffset = value.translation
                                        
                                        // Only allow dragging when zoomed in
                                        if scale > 1.0 {
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
                } else if let placeholderImage = placeholderImage {
                    Image(uiImage: placeholderImage)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .foregroundColor(.gray)
                } else {
                    VStack {
                        Image(systemName: "photo")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        Text("No image available")
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                }
            }
        }
        .clipped()
    }
}

// MARK: - Full Screen Image View
struct FullScreenImageView: View {
    let imageURL: URL?
    let placeholderImage: UIImage?
    @Binding var isPresented: Bool
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
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
            .zIndex(1)
            
            ZoomableImageView(
                imageURL: imageURL,
                placeholderImage: placeholderImage,
                contentMode: .fit
            )
        }
    }
} 