//
//  Avatar.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI

struct Avatar: View {
    @ObservedObject var user: User
    let size: CGFloat
    @State private var cachedImage: UIImage?
    @State private var isLoading = false
    
    init(user: User, size: CGFloat = 40) {
        self.user = user
        self.size = size
    }
    
    var body: some View {
        Group {
            if let avatarUrl = user.avatarUrl {
                Group {
                    if let cachedImage = cachedImage {
                        Image(uiImage: cachedImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if isLoading {
                        Color.gray
                            .overlay(
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .tint(.white)
                            )
                    } else {
                        Color.gray
                            .onAppear {
                                loadAvatar(from: avatarUrl)
                            }
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .onAppear {
                    // Try to load from cache first when view appears
                    if cachedImage == nil {
                        loadAvatar(from: avatarUrl)
                    }
                }
                .onChange(of: user.avatarUrl) { _ in
                    // Reset and reload when avatar URL changes
                    cachedImage = nil
                    if let avatarUrl = user.avatarUrl {
                        loadAvatar(from: avatarUrl)
                    }
                }
            } else {
                Image("ic_splash")
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
        }
        .id(user.mid) // Force view update when user changes
    }
    
    private func loadAvatar(from urlString: String) {
        guard !isLoading else { return }
        
        // Use the filename from URL as the cache key - this is simpler and matches user's expectation
        let cacheKey = URL(string: urlString)?.lastPathComponent ?? urlString
        
        // Create a MimeiFileType with the filename as mid so existing cache logic works
        let avatarAttachment = MimeiFileType(
            mid: cacheKey,
            type: "image"
        )
        
        let baseUrl = user.baseUrl ?? HproseInstance.baseUrl
        
        // Check cache first
        if let cached = ImageCacheManager.shared.getCompressedImage(for: avatarAttachment, baseUrl: baseUrl) {
            cachedImage = cached
            return
        }
        
        // Load from network if not cached
        isLoading = true
        Task {
            if let url = URL(string: urlString),
               let image = await ImageCacheManager.shared.loadAndCacheImage(from: url, for: avatarAttachment, baseUrl: baseUrl) {
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
