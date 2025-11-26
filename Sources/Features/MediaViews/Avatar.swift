//
//  Avatar.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI
import UIKit

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
        if user.mid == HproseInstance.shared.appUser.mid {
            AppUserAvatarImageView(user: user, size: size)
                .id("appUser-\(user.mid)")
        } else {
            RegularAvatarImageView(
                user: user,
                size: size,
                cachedImage: $cachedImage,
                isLoading: $isLoading,
                loadFailed: $loadFailed
            )
            .id(user.mid)
        }
    }
}

// MARK: - Regular User Avatar

private struct RegularAvatarImageView: View {
    @ObservedObject var user: User
    let size: CGFloat
    @Binding var cachedImage: UIImage?
    @Binding var isLoading: Bool
    @Binding var loadFailed: Bool
    
    var body: some View {
        Group {
            if let avatarUrl = user.avatarUrl {
                Group {
                    if let cachedImage = cachedImage {
                        Image(uiImage: cachedImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if loadFailed {
                        defaultAvatar
                    } else if isLoading {
                        loadingPlaceholder
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
                    if cachedImage == nil && !loadFailed {
                        loadAvatar(from: avatarUrl)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .avatarDidChange)) { notification in
                    guard let userId = notification.userInfo?["userId"] as? String,
                          userId == user.mid,
                          !isLoading else { return }
                    cachedImage = nil
                    loadFailed = false
                    if let avatarUrl = user.avatarUrl {
                        loadAvatar(from: avatarUrl)
                    }
                }
            } else {
                defaultAvatar
            }
        }
    }
    
    private var defaultAvatar: some View {
        Image("manyone")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .colorMultiply(Color.gray.opacity(0.3))
            .clipShape(Circle())
    }
    
    private var loadingPlaceholder: some View {
        Color.gray
            .overlay(
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.white)
            )
    }
    
    private func loadAvatar(from urlString: String) {
        guard !isLoading else { return }
        
        let cacheKey = user.avatar ?? (URL(string: urlString)?.lastPathComponent ?? urlString)
        let avatarAttachment = MimeiFileType(mid: cacheKey, mediaType: .image)
        let baseUrl = user.baseUrl ?? HproseInstance.baseUrl
        
        if let cached = ImageCacheManager.shared.getCompressedImage(for: avatarAttachment, baseUrl: baseUrl) {
            cachedImage = cached
            return
        }
        
        isLoading = true
        Task {
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
                    loadFailed = true
                }
                isLoading = false
            }
        }
    }
}

// MARK: - App User Avatar (Direct Link + In-Memory Bitmap)

private struct AppUserAvatarImageView: View {
    @ObservedObject var user: User
    let size: CGFloat
    
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var loadFailed = false
    
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if loadFailed || user.avatarUrl == nil {
                defaultIcon
            } else {
                Color.gray.opacity(0.2)
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .onAppear {
            loadAvatar(forceReload: false)
        }
        .onChange(of: user.avatarUrl) { _, _ in
            resetAndReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .avatarDidChange)) { notification in
            guard let userId = notification.userInfo?["userId"] as? String,
                  userId == user.mid else { return }
            resetAndReload()
        }
    }
    
    private var defaultIcon: some View {
        Image("tweet_icon")
            .resizable()
            .scaledToFill()
    }
    
    private func resetAndReload() {
        AppUserAvatarMemoryCache.shared.clear()
        image = nil
        loadFailed = false
        loadAvatar(forceReload: true)
    }
    
    private func loadAvatar(forceReload: Bool) {
        guard !isLoading else { return }
        
        if !forceReload, let cached = AppUserAvatarMemoryCache.shared.image(for: user.avatarUrl) {
            image = cached
            loadFailed = false
            return
        }
        
        guard let urlString = user.avatarUrl, let url = URL(string: urlString) else {
            loadFailed = true
            image = nil
            return
        }
        
        isLoading = true
        Task {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = 15
            
            do {
                let (data, response) = try await AppUserAvatarImageView.session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let downloadedImage = UIImage(data: data) else {
                    throw URLError(.badServerResponse)
                }
                
                await MainActor.run {
                    self.image = downloadedImage
                    self.loadFailed = false
                    AppUserAvatarMemoryCache.shared.store(downloadedImage, for: urlString)
                }
            } catch {
                await MainActor.run {
                    self.image = nil
                    self.loadFailed = true
                }
            }
            
            await MainActor.run {
                self.isLoading = false
            }
        }
    }
}

private final class AppUserAvatarMemoryCache {
    static let shared = AppUserAvatarMemoryCache()
    
    private var cachedImage: UIImage?
    private var cachedUrl: String?
    private let queue = DispatchQueue(label: "appUser.avatar.cache.queue")
    
    private init() {}
    
    func image(for url: String?) -> UIImage? {
        queue.sync {
            guard let cachedUrl, cachedUrl == url else { return nil }
            return cachedImage
        }
    }
    
    func store(_ image: UIImage, for url: String?) {
        queue.async {
            self.cachedImage = image
            self.cachedUrl = url
        }
    }
    
    func clear() {
        queue.async {
            self.cachedImage = nil
            self.cachedUrl = nil
        }
    }
}
