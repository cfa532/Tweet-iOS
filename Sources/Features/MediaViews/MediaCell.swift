//
//  MediaCell.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI
import AVKit
import CryptoKit

// MARK: - Image Cache Manager
class ImageCacheManager {
    static let shared = ImageCacheManager()
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let maxCacheAge: TimeInterval = 30 * 24 * 60 * 60 // 30 days in seconds
    
    private init() {
        // Get the cache directory
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDirectory.appendingPathComponent("ImageCache")
        
        // Create cache directory if it doesn't exist
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Set cache limits
        cache.countLimit = 100 // Maximum number of images in memory
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB limit
        
        // Start cleanup timer
        startCleanupTimer()
    }
    
    private func startCleanupTimer() {
        // Run cleanup every 24 hours
        Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            self?.cleanupOldCache()
        }
    }
    
    private func cleanupOldCache() {
        do {
            let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
            let now = Date()
            
            for fileURL in contents {
                if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                   let modificationDate = attributes[.modificationDate] as? Date {
                    if now.timeIntervalSince(modificationDate) > maxCacheAge {
                        try? fileManager.removeItem(at: fileURL)
                    }
                }
            }
        } catch {
            print("Error cleaning up cache: \(error)")
        }
    }
    
    private func getCacheKey(for attachment: MimeiFileType, baseUrl: String) -> String {
        if !attachment.mid.isEmpty {
            return attachment.mid
        }
        if let url = attachment.getUrl(baseUrl) {
            return url.lastPathComponent
        }
        return UUID().uuidString
    }
    
    private func getCacheFileURL(for key: String) -> URL {
        return cacheDirectory.appendingPathComponent(key)
    }
    
    func getImage(for attachment: MimeiFileType, baseUrl: String) -> UIImage? {
        let key = getCacheKey(for: attachment, baseUrl: baseUrl)
        
        // Check memory cache first
        if let cachedImage = cache.object(forKey: key as NSString) {
            return cachedImage
        }
        
        // Check disk cache
        let fileURL = getCacheFileURL(for: key)
        if let data = try? Data(contentsOf: fileURL),
           let image = UIImage(data: data) {
            // Add to memory cache
            cache.setObject(image, forKey: key as NSString)
            return image
        }
        
        return nil
    }
    
    func cacheImageData(_ data: Data, for attachment: MimeiFileType, baseUrl: String) {
        let key = getCacheKey(for: attachment, baseUrl: baseUrl)
        
        // Create UIImage from data
        guard let image = UIImage(data: data) else { return }
        
        // Compress image
        guard let compressedData = image.jpegData(compressionQuality: 0.7) else { return }
        
        // Save to disk
        let fileURL = getCacheFileURL(for: key)
        try? compressedData.write(to: fileURL)
        
        // Add to memory cache
        cache.setObject(image, forKey: key as NSString)
    }
    
    func loadAndCacheImage(from url: URL, for attachment: MimeiFileType, baseUrl: String) async -> UIImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            // Cache the data
            cacheImageData(data, for: attachment, baseUrl: baseUrl)
            
            // Return the image
            return UIImage(data: data)
        } catch {
            print("Error loading image: \(error)")
            return nil
        }
    }
}

// MARK: - MediaCell
struct MediaCell: View {
    let attachment: MimeiFileType
    let baseUrl: String
    var play: Bool = false
    @State private var cachedImage: UIImage?
    @State private var isLoading = false

    var body: some View {
        if attachment.type.lowercased() == "video", let url = attachment.getUrl(baseUrl) {
            VideoPlayerCacheView(url: url, attachment: attachment, play: play)
        } else {
            Group {
                if let cachedImage = cachedImage {
                    Image(uiImage: cachedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipped()
                } else if isLoading {
                    Color.gray
                } else {
                    Color.gray
                        .onAppear {
                            loadImage()
                        }
                }
            }
            .onAppear {
                // Try to load from cache first
                if let cached = ImageCacheManager.shared.getImage(for: attachment, baseUrl: baseUrl) {
                    cachedImage = cached
                } else {
                    loadImage()
                }
            }
        }
    }
    
    private func loadImage() {
        guard let url = attachment.getUrl(baseUrl), cachedImage == nil else { return }
        
        isLoading = true
        Task {
            if let image = await ImageCacheManager.shared.loadAndCacheImage(from: url, for: attachment, baseUrl: baseUrl) {
                await MainActor.run {
                    cachedImage = image
                    isLoading = false
                }
            } else {
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }
}



struct VideoPlayerCacheView: View {
    let url: URL
    let attachment: MimeiFileType
    var play: Bool

    @State private var player: AVPlayer?
    @State private var isPlaying: Bool = false
    @State private var isMuted: Bool = PreferenceHelper().getSpeakerMute()
    @State private var isVisible: Bool = false
    private let preferenceHelper = PreferenceHelper()

    var body: some View {
        ZStack {
            VideoPlayer(player: player)
                .onAppear {
                    if player == nil {
                        let asset = AVURLAsset(url: url)
                        let playerItem = AVPlayerItem(asset: asset)
                        player = AVPlayer(playerItem: playerItem)
                        player?.isMuted = isMuted
                    }
                    handlePlayback()
                }
                .onDisappear {
                    player?.pause()
                    player = nil
                    isPlaying = false
                }
                .clipped()
                .onVisibilityChanged { visible in
                    isVisible = visible
                    handlePlayback()
                }
            HStack(spacing: 20) {
                Button(action: {
                    if isPlaying {
                        player?.pause()
                    } else {
                        player?.play()
                    }
                    isPlaying.toggle()
                }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                }
                Button(action: {
                    isMuted.toggle()
                    player?.isMuted = isMuted
                    preferenceHelper.setSpeakerMute(isMuted)
                }) {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .clipped()
    }

    private func handlePlayback() {
        if isVisible && play {
            player?.play()
            isPlaying = true
        } else {
            player?.pause()
            isPlaying = false
        }
    }
}

// ViewModifier to detect visibility
struct VisibilityModifier: ViewModifier {
    let onChange: (Bool) -> Void
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .background(
                    Color.clear
                        .preference(key: VisibilityPreferenceKey.self, value: geometry.frame(in: .global))
                )
        }
        .onPreferenceChange(VisibilityPreferenceKey.self) { frame in
            let screen = UIScreen.main.bounds
            let isVisible = screen.intersects(frame)
            onChange(isVisible)
        }
    }
}

struct VisibilityPreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

extension View {
    func onVisibilityChanged(_ perform: @escaping (Bool) -> Void) -> some View {
        self.modifier(VisibilityModifier(onChange: perform))
    }
}
