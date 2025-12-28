//
//  Avatar.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/5/20.
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
                    // Always check cache even if loadFailed is true, as the avatar might have been loaded elsewhere
                    if cachedImage == nil {
                        let cacheKey = user.avatar ?? (URL(string: avatarUrl)?.lastPathComponent ?? avatarUrl)
                        let avatarAttachment = MimeiFileType(mid: cacheKey, mediaType: .image)
                        
                        // CRITICAL: Use memory-only cache check to avoid blocking disk I/O in view body
                        if let cached = ImageCacheManager.shared.getCompressedImageFromMemory(for: avatarAttachment) {
                            // Found in cache - use it and reset failed state
                            cachedImage = cached
                            loadFailed = false
                        } else if !loadFailed {
                            // Not in cache and haven't failed before - try loading from network
                            loadAvatar(from: avatarUrl)
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .avatarDidChange)) { notification in
                    // Only reload for this specific user, and only if not already loading
                    guard let userId = notification.userInfo?["userId"] as? String,
                          userId == user.mid,
                          !isLoading else { return }
                    
                    // Clear cached state and reload (loadAvatar will manage isLoading flag)
                    cachedImage = nil
                    loadFailed = false
                    
                    if let avatarUrl = user.avatarUrl {
                        loadAvatar(from: avatarUrl)
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
        .onReceive(NotificationCenter.default.publisher(for: .userDidUpdate)) { notification in
            // When user is updated (e.g., baseUrl resolved), reload avatar if avatarUrl is now available
            guard let userId = notification.userInfo?["userId"] as? String,
                  userId == user.mid,
                  !isLoading,
                  let avatarUrl = user.avatarUrl,
                  cachedImage == nil else { return }
            
            // baseUrl was resolved, avatarUrl is now available - start loading
            loadFailed = false
            loadAvatar(from: avatarUrl)
        }
        .onReceive(NotificationCenter.default.publisher(for: .appUserReady)) { _ in
            // When app user is ready (baseUrl resolved), reload avatar if it wasn't loaded before
            guard user.mid == HproseInstance.shared.appUser.mid,
                  !isLoading,
                  let avatarUrl = user.avatarUrl,
                  cachedImage == nil else { return }
            
            // baseUrl was resolved, avatarUrl is now available - start loading
            loadFailed = false
            loadAvatar(from: avatarUrl)
        }
        .id(user.mid) // Stable ID - notification handles avatar changes
    }
    
    private func loadAvatar(from urlString: String) {
        
        guard !isLoading else { 
            return 
        }
        
        // IMPORTANT: Use user's avatar MimeiId as the cache key (stable identifier)
        // NOT the URL which can change when baseUrl changes
        let cacheKey = user.avatar ?? (URL(string: urlString)?.lastPathComponent ?? urlString)
        
        // Create a MimeiFileType with the user's avatar MimeiId so caching works correctly
        let avatarAttachment = MimeiFileType(
            mid: cacheKey,
            mediaType: .image
        )
                
        // Check cache first (disk check is OK in async context like onAppear/loadAvatar)
        if let cached = ImageCacheManager.shared.getCompressedImage(for: avatarAttachment) {
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
            
            let result = await ImageCacheManager.shared.loadAndCacheImage(from: url, for: avatarAttachment)
            
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
