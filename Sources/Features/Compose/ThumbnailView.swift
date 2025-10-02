import SwiftUI
import PhotosUI
import AVFoundation
import UIKit

@available(iOS 16.0, *)
struct ThumbnailView: View {
    let item: PhotosPickerItem
    @State private var thumbnail: UIImage?
    @State private var mediaType: MediaType = .unknown
    @State private var isLoading = true
    @State private var error: Error?

    // Static cache to avoid regenerating thumbnails for the same item
    // Using a more robust cache key that includes both item ID and media type
    private static var thumbnailCache: [String: UIImage] = [:]
    
    // Method to clean up cache entries for removed items
    static func clearCacheForItem(_ itemId: String) {
        let keysToRemove = thumbnailCache.keys.filter { $0.hasPrefix(itemId) }
        for key in keysToRemove {
            thumbnailCache.removeValue(forKey: key)
            print("DEBUG: [ThumbnailView] Removed cache entry for key: \(key)")
        }
    }
    
    var body: some View {
        Group {
            if let thumbnail = thumbnail {
                ZStack {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(.systemGray4), lineWidth: 1)
                        )
                    
                    // Add play button overlay for videos
                    if mediaType == .video {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .background(
                                Circle()
                                    .fill(Color.black)
                                    .frame(width: 40, height: 40)
                            )
                            .opacity(0.5)
                            .shadow(radius: 2)
                    }
                }
            } else if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(1.2)
            } else {
                // Fallback for errors or unknown types
                fallbackView
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(.systemGray4), lineWidth: 1)
                    )
            }
        }
        .task(id: item.itemIdentifier) {
            print("DEBUG: Starting thumbnail generation for item: \(item.itemIdentifier ?? "nil")")
            // Reset state when item changes
            thumbnail = nil
            mediaType = .unknown
            isLoading = true
            error = nil
            
            await generateThumbnail()
        }
    }
    
    @ViewBuilder
    private var fallbackView: some View {
        ZStack {
            Color.gray.opacity(0.3)
            
            switch mediaType {
            case .video:
                Image(systemName: "video.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white)
            case .audio:
                Image(systemName: "waveform")
                    .font(.system(size: 30))
                    .foregroundColor(.white)
            case .image:
                Image(systemName: "photo.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white)
            default:
                Image(systemName: "doc.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white)
            }
        }
    }
    
    private func generateThumbnail() async {
        isLoading = true
        error = nil
        
        // Generate a unique identifier for this item
        let itemId = item.itemIdentifier ?? UUID().uuidString
        print("DEBUG: [\(itemId)] Starting thumbnail generation")
        
        // First, detect the media type to create a proper cache key
        mediaType = detectMediaType()
        print("DEBUG: [\(itemId)] Detected media type: \(mediaType.rawValue)")
        print("DEBUG: [\(itemId)] Item supported content types: \(item.supportedContentTypes.map { $0.identifier })")
        
        // Create a cache key that includes both item ID and media type
        let cacheKey = "\(itemId)_\(mediaType.rawValue)"
        
        // Check cache first
        if let cachedThumbnail = Self.thumbnailCache[cacheKey] {
            print("DEBUG: [\(itemId)] Using cached thumbnail for key: \(cacheKey)")
            await MainActor.run {
                self.thumbnail = cachedThumbnail
                self.isLoading = false
            }
            return
        }
        
        print("DEBUG: [\(itemId)] No cached thumbnail found for key: \(cacheKey), generating new one")
        
        do {
            
            // If media type is unknown, try to detect from file data
            if mediaType == .unknown {
                print("DEBUG: [\(itemId)] Trying to detect media type from file data...")
                if let data = try? await item.loadTransferable(type: Data.self) {
                    mediaType = detectMediaTypeFromData(data)
                    print("DEBUG: [\(itemId)] Re-detected media type from data: \(mediaType.rawValue)")
                }
            }
            
            switch mediaType {
            case .video:
                print("DEBUG: [\(itemId)] Generating video thumbnail")
                thumbnail = try await generateVideoThumbnail()
            case .audio:
                print("DEBUG: [\(itemId)] Generating audio thumbnail")
                thumbnail = generateAudioThumbnail()
            case .image:
                print("DEBUG: [\(itemId)] Generating image thumbnail")
                thumbnail = try await generateImageThumbnail()
            default:
                print("DEBUG: [\(itemId)] Generating default thumbnail")
                thumbnail = generateDefaultThumbnail()
            }
            
            // Cache the generated thumbnail
            if let generatedThumbnail = thumbnail {
                Self.thumbnailCache[cacheKey] = generatedThumbnail
                print("DEBUG: [\(itemId)] Thumbnail cached with key: \(cacheKey)")
            }
            
            print("DEBUG: [\(itemId)] Thumbnail generation completed successfully")
        } catch {
            self.error = error
            print("DEBUG: [\(itemId)] Thumbnail generation failed: \(error)")
        }
        
        isLoading = false
    }
    
    private func detectMediaType() -> MediaType {
        let typeIdentifier = item.supportedContentTypes.first?.identifier ?? ""
        print("DEBUG: Type identifier: \(typeIdentifier)")
        
        // Use UTType for proper media type detection
        if let utType = UTType(typeIdentifier) {
            print("DEBUG: UTType: \(utType)")
            
            // Check if it's an image
            if utType.conforms(to: .image) {
                print("DEBUG: Detected as image via UTType")
                return .image
            }
            
            // Check if it's a video/movie
            if utType.conforms(to: .movie) || utType.conforms(to: .video) {
                print("DEBUG: Detected as video via UTType")
                return .video
            }
            
            // Check if it's audio
            if utType.conforms(to: .audio) {
                print("DEBUG: Detected as audio via UTType")
                return .audio
            }
            
            // Check specific image formats
            if utType.conforms(to: .jpeg) || 
               utType.conforms(to: .png) || 
               utType.conforms(to: .gif) || 
               utType.conforms(to: .heic) || 
               utType.conforms(to: .heif) ||
               utType.conforms(to: .tiff) ||
               utType.conforms(to: .bmp) ||
               utType.conforms(to: .webP) {
                print("DEBUG: Detected as image via specific UTType")
                return .image
            }
            
            // Check specific video formats
            if utType.conforms(to: .mpeg4Movie) || 
               utType.conforms(to: .quickTimeMovie) ||
               utType.conforms(to: .avi) ||
               utType.conforms(to: .mpeg) {
                print("DEBUG: Detected as video via specific UTType")
                return .video
            }
            
            // Check specific audio formats
            if utType.conforms(to: .mp3) || 
               utType.conforms(to: .mpeg4Audio) ||
               utType.conforms(to: .wav) ||
               utType.conforms(to: .aiff) {
                print("DEBUG: Detected as audio via specific UTType")
                return .audio
            }
        }
        
        // Fallback to string-based detection for edge cases
        if typeIdentifier.hasPrefix("public.image") || 
           typeIdentifier.contains("jpeg") || 
           typeIdentifier.contains("png") || 
           typeIdentifier.contains("gif") || 
           typeIdentifier.contains("heic") || 
           typeIdentifier.contains("heif") ||
           typeIdentifier.contains("tiff") ||
           typeIdentifier.contains("bmp") ||
           typeIdentifier.contains("webp") {
            print("DEBUG: Detected as image via string fallback")
            return .image
        } else if typeIdentifier.hasPrefix("public.movie") || 
                  typeIdentifier.contains("quicktime-movie") || 
                  typeIdentifier.contains("movie") ||
                  typeIdentifier.contains("video") ||
                  typeIdentifier.contains("mp4") ||
                  typeIdentifier.contains("mov") ||
                  typeIdentifier.contains("m4v") {
            print("DEBUG: Detected as video via string fallback")
            return .video
        } else if typeIdentifier.hasPrefix("public.audio") || 
                  typeIdentifier.contains("audio") ||
                  typeIdentifier.contains("mp3") ||
                  typeIdentifier.contains("m4a") ||
                  typeIdentifier.contains("wav") ||
                  typeIdentifier.contains("aac") {
            print("DEBUG: Detected as audio via string fallback")
            return .audio
        }
        
        print("DEBUG: Detected as unknown")
        return .unknown
    }
    
    private func detectMediaTypeFromData(_ data: Data) -> MediaType {
        // Check file signatures (magic numbers) to determine file type
        guard data.count >= 12 else { return .unknown }
        
        let bytes = [UInt8](data.prefix(12))
        
        // JPEG: FF D8 FF
        if bytes.count >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            print("DEBUG: Detected JPEG from file signature")
            return .image
        }
        
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if bytes.count >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 &&
           bytes[4] == 0x0D && bytes[5] == 0x0A && bytes[6] == 0x1A && bytes[7] == 0x0A {
            print("DEBUG: Detected PNG from file signature")
            return .image
        }
        
        // GIF: 47 49 46 38 (GIF8)
        if bytes.count >= 4 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38 {
            print("DEBUG: Detected GIF from file signature")
            return .image
        }
        
        // HEIC/HEIF: ftypheic, ftypheix, ftypheis, ftypheim, ftyphevc, ftyphevx
        if bytes.count >= 12 {
            let ftypString = String(bytes: bytes[4...11], encoding: .ascii) ?? ""
            if ftypString.hasPrefix("ftyp") && (ftypString.contains("heic") || ftypString.contains("heix") || 
                                               ftypString.contains("heis") || ftypString.contains("heim") ||
                                               ftypString.contains("hevc") || ftypString.contains("hevx")) {
                print("DEBUG: Detected HEIC/HEIF from file signature")
                return .image
            }
        }
        
        // MP4/MOV: ftyp
        if bytes.count >= 8 {
            let ftypString = String(bytes: bytes[4...7], encoding: .ascii) ?? ""
            if ftypString == "ftyp" {
                // Check for video codecs
                let codecString = String(bytes: bytes[8...11], encoding: .ascii) ?? ""
                if codecString.contains("mp4") || codecString.contains("M4V") || codecString.contains("isom") ||
                   codecString.contains("iso2") || codecString.contains("avc1") || codecString.contains("mp41") ||
                   codecString.contains("mp42") || codecString.contains("3gp") {
                    print("DEBUG: Detected MP4/MOV from file signature")
                    return .video
                }
            }
        }
        
        // MP3: ID3 or MPEG sync
        if bytes.count >= 3 {
            // ID3v2: 49 44 33 (ID3)
            if bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33 {
                print("DEBUG: Detected MP3 (ID3) from file signature")
                return .audio
            }
            // MPEG sync: FF FB or FF F3 or FF F2
            if bytes[0] == 0xFF && (bytes[1] == 0xFB || bytes[1] == 0xF3 || bytes[1] == 0xF2) {
                print("DEBUG: Detected MP3 (MPEG) from file signature")
                return .audio
            }
        }
        
        // WAV: 52 49 46 46 (RIFF)
        if bytes.count >= 4 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
            print("DEBUG: Detected WAV from file signature")
            return .audio
        }
        
        print("DEBUG: Could not determine type from file signature")
        return .unknown
    }
    
    private func generateVideoThumbnail() async throws -> UIImage {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw ThumbnailError.dataLoadingFailed
        }
        
        // Create temporary file for AVFoundation
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let asset = AVURLAsset(url: tempURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 400, height: 400) // Higher resolution for better quality
        
        // Try different time positions for thumbnail
        let timePositions: [Double] = [1.0, 0.5, 0.1, 0.0]
        
        for timePosition in timePositions {
            do {
                let time = CMTime(seconds: timePosition, preferredTimescale: 1)
                
                // Use the new async generateCGImageAsynchronouslyForTime method
                let cgImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
                    imageGenerator.generateCGImageAsynchronously(for: time) { cgImage, actualTime, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let cgImage = cgImage {
                            continuation.resume(returning: cgImage)
                        } else {
                            continuation.resume(throwing: NSError(domain: "ThumbnailGeneration", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate image"]))
                        }
                    }
                }
                
                let originalImage = UIImage(cgImage: cgImage)
                
                // Center-crop thumbnail to fill
                let targetSize = CGSize(width: 200, height: 200)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1.0
                let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
                let thumbnail = renderer.image { context in
                    let imageSize = originalImage.size
                    let scale = max(targetSize.width / imageSize.width, targetSize.height / imageSize.height)
                    let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                    let x = (targetSize.width - scaledSize.width) / 2
                    let y = (targetSize.height - scaledSize.height) / 2
                    let rect = CGRect(origin: CGPoint(x: x, y: y), size: scaledSize)
                    originalImage.draw(in: rect)
                }
                return thumbnail
            } catch {
                // Continue to next time position if this one fails
                continue
            }
        }
        
        // If all time positions fail, throw error
        throw ThumbnailError.thumbnailGenerationFailed
    }
    
    private func generateImageThumbnail() async throws -> UIImage {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw ThumbnailError.dataLoadingFailed
        }
        
        guard let image = UIImage(data: data) else {
            print("DEBUG: Failed to create UIImage from data")
            throw ThumbnailError.thumbnailGenerationFailed
        }
        
        print("DEBUG: Original image size: \(image.size)")
        
        // Fix image orientation if needed
        let fixedImage = image.fixOrientation()
        print("DEBUG: Fixed image size: \(fixedImage.size)")
        
        // Center-crop thumbnail to fill
        let targetSize = CGSize(width: 200, height: 200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let thumbnail = renderer.image { context in
            let imageSize = fixedImage.size
            let scale = max(targetSize.width / imageSize.width, targetSize.height / imageSize.height)
            let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let x = (targetSize.width - scaledSize.width) / 2
            let y = (targetSize.height - scaledSize.height) / 2
            let rect = CGRect(origin: CGPoint(x: x, y: y), size: scaledSize)
            fixedImage.draw(in: rect)
        }
        print("DEBUG: Thumbnail generated successfully")
        return thumbnail
    }
    
    private func generateSimpleImageThumbnail(from image: UIImage) throws -> UIImage {
        let targetSize = CGSize(width: 200, height: 200)
        
        UIGraphicsBeginImageContextWithOptions(targetSize, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        guard let context = UIGraphicsGetCurrentContext() else {
            throw ThumbnailError.thumbnailGenerationFailed
        }
        
        // Fill background
        UIColor.systemGray6.setFill()
        context.fill(CGRect(origin: .zero, size: targetSize))
        
        // Calculate aspect ratio preserving size
        let imageSize = image.size
        let scale = min(targetSize.width / imageSize.width, targetSize.height / imageSize.height)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        
        // Center the image
        let x = (targetSize.width - scaledSize.width) / 2
        let y = (targetSize.height - scaledSize.height) / 2
        let rect = CGRect(origin: CGPoint(x: x, y: y), size: scaledSize)
        
        // Draw the image
        image.draw(in: rect)
        
        guard let thumbnail = UIGraphicsGetImageFromCurrentImageContext() else {
            throw ThumbnailError.thumbnailGenerationFailed
        }
        
        print("DEBUG: Simple thumbnail generated successfully")
        return thumbnail
    }
    
    private func generateAudioThumbnail() -> UIImage {
        let size = CGSize(width: 200, height: 200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            // Background gradient
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    UIColor.systemBlue.cgColor,
                    UIColor.systemPurple.cgColor
                ] as CFArray,
                locations: [0.0, 1.0]
            )!
            
            // Create rounded rectangle path
            let rect = CGRect(origin: .zero, size: size)
            let cornerRadius: CGFloat = 8
            let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
            path.addClip()
            
            context.cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
            
            // Audio waveform icon
            let iconSize: CGFloat = 60
            let iconRect = CGRect(
                x: (size.width - iconSize) / 2,
                y: (size.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            
            // Draw waveform bars
            let barWidth: CGFloat = 4
            let barSpacing: CGFloat = 2
            let numberOfBars = 5
            let totalWidth = CGFloat(numberOfBars) * (barWidth + barSpacing) - barSpacing
            let startX = iconRect.midX - totalWidth / 2
            
            for i in 0..<numberOfBars {
                let barHeight = CGFloat.random(in: 20...50)
                let x = startX + CGFloat(i) * (barWidth + barSpacing)
                let y = iconRect.midY - barHeight / 2
                
                let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                UIColor.white.setFill()
                context.cgContext.fill(barRect)
            }
        }
    }
    
    private func generateDefaultThumbnail() -> UIImage {
        let size = CGSize(width: 200, height: 200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            // Create rounded rectangle path
            let rect = CGRect(origin: .zero, size: size)
            let cornerRadius: CGFloat = 8
            let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
            path.addClip()
            
            // Background
            UIColor.systemGray5.setFill()
            context.cgContext.fill(rect)
            
            // Document icon
            let iconSize: CGFloat = 60
            let iconRect = CGRect(
                x: (size.width - iconSize) / 2,
                y: (size.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            
            UIColor.systemGray.setFill()
            context.cgContext.fill(iconRect)
            
            // Document lines
            UIColor.white.setFill()
            for i in 0..<3 {
                let lineY = iconRect.minY + 15 + CGFloat(i) * 8
                let lineRect = CGRect(
                    x: iconRect.minX + 10,
                    y: lineY,
                    width: iconRect.width - 20,
                    height: 3
                )
                context.cgContext.fill(lineRect)
            }
        }
    }
}

// MARK: - Error Types
enum ThumbnailError: Error, LocalizedError {
    case dataLoadingFailed
    case thumbnailGenerationFailed
    
    var errorDescription: String? {
        switch self {
        case .dataLoadingFailed:
            return NSLocalizedString("Failed to load media data", comment: "Media data loading error")
        case .thumbnailGenerationFailed:
            return NSLocalizedString("Failed to generate thumbnail", comment: "Thumbnail generation error")
        }
    }
}

// MARK: - UIImage Extension
extension UIImage {
    func fixOrientation() -> UIImage {
        // If the image is already in the correct orientation, return it
        if imageOrientation == .up {
            return self
        }
        
        // Create a new CGContext with the correct orientation
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        defer { UIGraphicsEndImageContext() }
        
        guard let context = UIGraphicsGetCurrentContext() else {
            return self
        }
        
        // Apply the correct transform
        context.translateBy(x: size.width / 2, y: size.height / 2)
        
        switch imageOrientation {
        case .down, .downMirrored:
            context.rotate(by: .pi)
        case .left, .leftMirrored:
            context.rotate(by: .pi / 2)
        case .right, .rightMirrored:
            context.rotate(by: -.pi / 2)
        default:
            break
        }
        
        switch imageOrientation {
        case .upMirrored, .downMirrored:
            context.scaleBy(x: -1, y: 1)
        case .leftMirrored, .rightMirrored:
            context.scaleBy(x: 1, y: -1)
        default:
            break
        }
        
        context.translateBy(x: -size.width / 2, y: -size.height / 2)
        
        // Draw the image
        draw(in: CGRect(origin: .zero, size: size))
        
        return UIGraphicsGetImageFromCurrentImageContext() ?? self
    }
} 
