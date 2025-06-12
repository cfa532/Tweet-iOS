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
    private var pendingCompletions: [URL: [(Result<URL, Error>) -> Void]] = [:]
    private let cacheDirectory: URL
    private let queue = DispatchQueue(label: "com.tweet.videoloader")
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.httpMaximumConnectionsPerHost = 6
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        if #available(iOS 13.0, *) {
            config.allowsExpensiveNetworkAccess = true
            config.allowsConstrainedNetworkAccess = true
        }
        
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
        
        print("VideoDataLoader: Loading video from \(url.lastPathComponent)")
        
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            // Verify the cached file is valid
            if isValidVideoFile(at: cachedURL) {
                print("VideoDataLoader: Found cached video at \(cachedURL.path)")
                completion(.success(cachedURL))
                return
            } else {
                // Remove invalid cache
                print("VideoDataLoader: Removing invalid cache (file size check failed)")
                try? FileManager.default.removeItem(at: cachedURL)
            }
        }
        
        // Check if already downloading
        if let existingTask = downloadTasks[url] {
            if existingTask.state == .running {
                print("VideoDataLoader: Download already in progress, waiting for completion")
                // Store the completion handler to be called when download finishes
                queue.sync {
                    if pendingCompletions[url] == nil {
                        pendingCompletions[url] = []
                    }
                    pendingCompletions[url]?.append(completion)
                }
                return
            } else {
                // Remove the old task if it's not running
                downloadTasks.removeValue(forKey: url)
            }
        }
        
        print("VideoDataLoader: Starting new download")
        
        // Create download request with custom headers
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("video/*,application/octet-stream,*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120 // Increase timeout for unstable connections
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        
        // Retry logic for network failures
        var retryCount = 0
        let maxRetries = 3
        
        func attemptDownload() {
            let task = session.downloadTask(with: request) { [weak self] tempURL, response, error in
                guard let self = self else { return }
                
                self.queue.sync {
                    self.downloadTasks.removeValue(forKey: url)
                }
                
                // Get all pending completions
                let completions = self.queue.sync { () -> [(Result<URL, Error>) -> Void] in
                    let pending = self.pendingCompletions[url] ?? []
                    self.pendingCompletions.removeValue(forKey: url)
                    return pending + [completion]
                }
                
                if let error = error as NSError? {
                    if error.code == NSURLErrorCancelled {
                        print("VideoDataLoader: Download was cancelled")
                        completions.forEach { $0(.failure(error)) }
                        return
                    } else if (error.code == NSURLErrorNetworkConnectionLost || error.code == NSURLErrorTimedOut) && retryCount < maxRetries {
                        retryCount += 1
                        print("VideoDataLoader: Network error, retrying (\(retryCount)/\(maxRetries)) - \(error.localizedDescription)")
                        
                        // Re-add completions for retry
                        self.queue.sync {
                            self.pendingCompletions[url] = completions
                        }
                        
                        // Retry after a short delay
                        DispatchQueue.global().asyncAfter(deadline: .now() + Double(retryCount)) {
                            attemptDownload()
                        }
                        return
                    } else {
                        print("VideoDataLoader: Download failed - \(error.localizedDescription)")
                        completions.forEach { $0(.failure(error)) }
                        return
                    }
                }
                
                guard let tempURL = tempURL else {
                    print("VideoDataLoader: No temp URL received")
                    completions.forEach { $0(.failure(VideoPlayerError.unknown)) }
                    return
                }
                
                do {
                    print("VideoDataLoader: Download complete, moving to cache")
                    
                    // Move to cache location
                    if FileManager.default.fileExists(atPath: cachedURL.path) {
                        try FileManager.default.removeItem(at: cachedURL)
                    }
                    
                    // Copy instead of move to ensure file is complete
                    try FileManager.default.copyItem(at: tempURL, to: cachedURL)
                    
                    // Verify it's a valid video
                    if self.isValidVideoFile(at: cachedURL) {
                        print("VideoDataLoader: Video cached successfully")
                        
                        // Try to fix container format if needed
                        if let response = response as? HTTPURLResponse,
                           response.mimeType == "application/octet-stream" {
                            print("VideoDataLoader: Fixing container format for octet-stream")
                            self.fixVideoContainer(at: cachedURL) { fixedURL in
                                if let fixedURL = fixedURL {
                                    completions.forEach { $0(.success(fixedURL)) }
                                } else {
                                    completions.forEach { $0(.success(cachedURL)) }
                                }
                            }
                        } else {
                            completions.forEach { $0(.success(cachedURL)) }
                        }
                    } else {
                        print("VideoDataLoader: Downloaded file is not valid")
                        try FileManager.default.removeItem(at: cachedURL)
                        completions.forEach { $0(.failure(VideoPlayerError.notPlayable)) }
                    }
                } catch {
                    print("VideoDataLoader: Error moving file - \(error.localizedDescription)")
                    completions.forEach { $0(.failure(error)) }
                }
            }
            
            downloadTasks[url] = task
            task.resume()
            print("VideoDataLoader: Download task started (attempt \(retryCount + 1))")
        }
        
        // Start the first download attempt
        attemptDownload()
    }
    
    func cancelDownload(for url: URL) {
        queue.sync {
            downloadTasks[url]?.cancel()
            downloadTasks.removeValue(forKey: url)
            
            // Notify any pending completions
            if let pending = pendingCompletions[url] {
                let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [NSLocalizedDescriptionKey: "Download cancelled"])
                pending.forEach { $0(.failure(error)) }
                pendingCompletions.removeValue(forKey: url)
            }
        }
    }
    
    private func isValidVideoFile(at url: URL) -> Bool {
        // For local files, we can do a basic check
        // The actual playability will be verified when playing
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            // Check if file has reasonable size (at least 1KB)
            return fileSize > 1024
        } catch {
            return false
        }
    }
    
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    func clearCacheForURL(_ url: URL) {
        let cacheKey = url.lastPathComponent.isEmpty ? url.absoluteString.md5 : url.lastPathComponent
        let cachedURL = cacheDirectory.appendingPathComponent(cacheKey)
        
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            try? FileManager.default.removeItem(at: cachedURL)
            print("VideoDataLoader: Cleared cache for \(url.lastPathComponent)")
        }
    }
    
    private func fixVideoContainer(at url: URL, completion: @escaping (URL?) -> Void) {
        // Create a new URL with .mp4 extension
        let fixedURL = url.deletingPathExtension().appendingPathExtension("mp4")
        
        do {
            // Copy the file to the new location
            if FileManager.default.fileExists(atPath: fixedURL.path) {
                try FileManager.default.removeItem(at: fixedURL)
            }
            try FileManager.default.copyItem(at: url, to: fixedURL)
            
            // Verify the fixed file
            let asset = AVAsset(url: fixedURL)
            Task {
                do {
                    let isPlayable = try await asset.load(.isPlayable)
                    if isPlayable {
                        print("VideoDataLoader: Successfully fixed container format")
                        completion(fixedURL)
                    } else {
                        print("VideoDataLoader: Failed to fix container format")
                        try? FileManager.default.removeItem(at: fixedURL)
                        completion(nil)
                    }
                } catch {
                    print("VideoDataLoader: Error verifying fixed file: \(error)")
                    try? FileManager.default.removeItem(at: fixedURL)
                    completion(nil)
                }
            }
        } catch {
            print("VideoDataLoader: Error fixing container format: \(error)")
            completion(nil)
        }
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