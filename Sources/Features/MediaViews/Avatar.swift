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
    @State private var loadFailed = false // Track if load failed/timed out
    
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
                    } else if loadFailed {
                        // Load failed/timed out - show default avatar
                        Image("manyone")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .colorMultiply(Color.gray.opacity(0.3))
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
                    if cachedImage == nil && !loadFailed {
                        loadAvatar(from: avatarUrl)
                    }
                }
                .onChange(of: user.avatarUrl) { _, _ in
                    // Reset and reload when avatar URL changes
                    cachedImage = nil
                    loadFailed = false
                    if let avatarUrl = user.avatarUrl {
                        loadAvatar(from: avatarUrl)
                    }
                }
                .onChange(of: user.avatar) { _, newAvatar in
                    // CRITICAL: Also observe avatar changes directly
                    // This ensures views update when user.avatar loads
                    if newAvatar != nil && cachedImage == nil && !isLoading {
                        if let avatarUrl = user.avatarUrl {
                            loadAvatar(from: avatarUrl)
                        }
                    }
                }
            } else {
                Image("manyone")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .colorMultiply(Color.gray.opacity(0.3))
                    .clipShape(Circle())
            }
        }
        .id("\(user.mid)_\(user.avatar ?? "nil")") // Force view update when user or avatar changes
    }
    
    private func loadAvatar(from urlString: String) {
        guard !isLoading else { return }
        
        // IMPORTANT: Use user's avatar MimeiId as the cache key (stable identifier)
        // NOT the URL which can change when baseUrl changes
        let cacheKey = user.avatar ?? (URL(string: urlString)?.lastPathComponent ?? urlString)
        
        // Create a MimeiFileType with the user's avatar MimeiId so caching works correctly
        let avatarAttachment = MimeiFileType(
            mid: cacheKey,
            mediaType: .image
        )
        
        let baseUrl = user.baseUrl ?? HproseInstance.baseUrl
        
        // Check cache first
        if let cached = ImageCacheManager.shared.getCompressedImage(for: avatarAttachment, baseUrl: baseUrl) {
            cachedImage = cached
            return
        }
        
        // Load from network using regular image loading (no special avatar treatment)
        isLoading = true
        Task {
            // Use standard image loading with deduplication
            guard let url = URL(string: urlString) else {
                await MainActor.run {
                    loadFailed = true
                    isLoading = false
                }
                return
            }
            
            let result = await ImageCacheManager.shared.loadAndCacheImage(from: url, for: avatarAttachment, baseUrl: baseUrl)
            
            await MainActor.run {
                if let image = result {
                    cachedImage = image
                    loadFailed = false
                } else {
                    // Load failure - mark as failed to show default avatar
                    loadFailed = true
                }
                isLoading = false
            }
        }
    }
}
