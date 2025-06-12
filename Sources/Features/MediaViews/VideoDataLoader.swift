//
//  VideoDataLoader.swift
//  Tweet
//
//  Helper class to handle video loading for problematic content types
//

import Foundation
import AVFoundation

class VideoDataLoader {
    static let shared = VideoDataLoader()
    private let session: URLSession
    private var downloadTasks: [URL: URLSessionDownloadTask] = [:]
    private let cacheDirectory: URL
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpMaximumConnectionsPerHost = 6
        config.allowsCellularAccess = true
        if #available(iOS 13.0, *) {
            config.allowsExpensiveNetworkAccess = true
            config.allowsConstrainedNetworkAccess = true
        }
        
        // Custom headers for better compatibility
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15",
            "Accept": "video/*,application/octet-stream,*/*",
            "Accept-Encoding": "identity"
        ]
        
        self.session = URLSession(configuration: config)
        
        // Setup cache directory
        let tempDir = FileManager.default.temporaryDirectory
        self.cacheDirectory = tempDir.appendingPathComponent("VideoCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    func loadVideo(from url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        // Check if already cached
        let cacheKey = url.lastPathComponent.isEmpty ? url.absoluteString.md5 : url.lastPathComponent
        let cachedURL = cacheDirectory.appendingPathComponent(cacheKey)
        
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            // Verify the cached file is valid
            if isValidVideoFile(at: cachedURL) {
                completion(.success(cachedURL))
                return
            } else {
                // Remove invalid cache
                try? FileManager.default.removeItem(at: cachedURL)
            }
        }
        
        // Cancel existing download if any
        downloadTasks[url]?.cancel()
        
        // Start new download
        let task = session.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self else { return }
            
            self.downloadTasks.removeValue(forKey: url)
            
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let tempURL = tempURL else {
                completion(.failure(VideoPlayerError.unknown))
                return
            }
            
            do {
                // Move to cache location
                if FileManager.default.fileExists(atPath: cachedURL.path) {
                    try FileManager.default.removeItem(at: cachedURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: cachedURL)
                
                // Verify it's a valid video
                if self.isValidVideoFile(at: cachedURL) {
                    completion(.success(cachedURL))
                } else {
                    try FileManager.default.removeItem(at: cachedURL)
                    completion(.failure(VideoPlayerError.notPlayable))
                }
            } catch {
                completion(.failure(error))
            }
        }
        
        downloadTasks[url] = task
        task.resume()
    }
    
    func cancelDownload(for url: URL) {
        downloadTasks[url]?.cancel()
        downloadTasks.removeValue(forKey: url)
    }
    
    private func isValidVideoFile(at url: URL) -> Bool {
        let asset = AVAsset(url: url)
        return asset.isPlayable && !asset.tracks.isEmpty
    }
    
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}

// String extension for simple hash (for cache key generation)
extension String {
    var md5: String {
        // Simple hash for cache key - not cryptographically secure but sufficient for our use
        let data = Data(self.utf8)
        return String(data.hashValue)
    }
} 