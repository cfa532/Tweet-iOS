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
            } else {
                Image("manyone")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .colorMultiply(Color.gray.opacity(0.3))
                    .clipShape(Circle())
            }
        }
        .id(user.mid) // Force view update when user changes
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
        
        // Load from network if not cached, with timeout and throttling
        isLoading = true
        Task {
            // Create the load task using throttled avatar loading
            let loadTask = Task { () -> UIImage? in
                if let url = URL(string: urlString),
                   let image = await ImageCacheManager.shared.loadAndCacheAvatar(from: url, for: avatarAttachment, baseUrl: baseUrl) {
                    return image
                }
                return nil
            }
            
            // Create a timeout task
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds timeout
            }
            
            // Wait for either the load to complete or timeout
            let result = await withTaskGroup(of: UIImage?.self) { group in
                group.addTask {
                    await loadTask.value
                }
                group.addTask {
                    await timeoutTask.value
                    return nil // Timeout returns nil
                }
                
                // Return the first completed task result
                let firstResult = await group.next()
                group.cancelAll() // Cancel the other task
                return firstResult ?? nil
            }
            
            await MainActor.run {
                if let image = result {
                    cachedImage = image
                    loadFailed = false
                } else {
                    // Timeout or load failure - mark as failed to show default avatar
                    loadFailed = true
                }
                isLoading = false
            }
        }
    }
}
