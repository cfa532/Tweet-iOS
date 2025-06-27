import UIKit
import Foundation

class MediaImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading: Bool = false
    private let imageCache = ImageCacheManager.shared
    
    func loadImage(for attachment: MimeiFileType, baseUrl: URL) {
        guard let url = attachment.getUrl(baseUrl) else { return }
        // Try to get cached image immediately
        if let cachedImage = imageCache.getCompressedImage(for: attachment, baseUrl: baseUrl) {
            self.image = cachedImage
            return
        }
        // If no cached image, start loading
        isLoading = true
        Task {
            if let loadedImage = await imageCache.loadAndCacheImage(from: url, for: attachment, baseUrl: baseUrl) {
                await MainActor.run {
                    self.image = loadedImage
                    self.isLoading = false
                }
            } else {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }
} 