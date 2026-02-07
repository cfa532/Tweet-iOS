import Foundation
import AVFoundation

public class ResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    private let url: URL
    private let mediaID: String?
    private let saveFilePath: String
    private weak var owner: CachingPlayerItem?

    // Track active URLSession tasks for proper cleanup on deallocation
    private var activeTasks: [Int: URLSessionDataTask] = [:]
    private let taskLock = NSLock()

    public init(url: URL, mediaID: String?, saveFilePath: String, owner: CachingPlayerItem) {
        self.url = url
        self.mediaID = mediaID
        self.saveFilePath = saveFilePath
        self.owner = owner
        super.init()
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let requestURL = loadingRequest.request.url else {
            print("DEBUG: [CachingPlayerItem] resourceLoader: No request URL")
            return false
        }
        
        // Removed repetitive resource loader logs
        
        // Convert custom scheme URL back to original URL
        guard let originalURL = convertCustomSchemeToOriginalURL(requestURL) else {
            print("DEBUG: [CachingPlayerItem] resourceLoader: Failed to convert custom scheme URL")
            return false
        }
        
        // Removed repetitive URL conversion log
        
        // Handle different types of requests
        if originalURL.pathExtension == "m3u8" {
            // Use dynamic cache path instead of fixed saveFilePath
            let dynamicCachePath = getCachePath(for: originalURL)
            print("DEBUG: [CachingPlayerItem] resourceLoader: dynamic cache path = \(dynamicCachePath)")
            return handleHLSRequest(loadingRequest, url: originalURL, cachePath: dynamicCachePath)
        } else if originalURL.pathExtension == "ts" {
            return handleSegmentRequest(loadingRequest, url: originalURL)
        } else if originalURL.pathExtension == "mp4" || originalURL.pathExtension == "mov" || originalURL.pathExtension == "m4v" {
            // Handle progressive video files (MP4, MOV, M4V)
            print("DEBUG: [CachingPlayerItem] resourceLoader: Handling progressive video: \(originalURL.pathExtension)")
            return handleProgressiveVideoRequest(loadingRequest, url: originalURL)
        } else {
            print("DEBUG: [CachingPlayerItem] resourceLoader: Unknown file type: \(originalURL.pathExtension)")
            return false
        }
    }

    private func convertCustomSchemeToOriginalURL(_ customSchemeURL: URL) -> URL? {
        guard customSchemeURL.scheme == "cachingPlayerItemScheme" else {
            return customSchemeURL
        }
        
        var components = URLComponents(url: customSchemeURL, resolvingAgainstBaseURL: false)
        components?.scheme = "http"
        return components?.url
    }
    
    private func handleHLSRequest(_ loadingRequest: AVAssetResourceLoadingRequest, url: URL, cachePath: String? = nil) -> Bool {
        guard let requestURL = loadingRequest.request.url else { 
            print("DEBUG: [CachingPlayerItem] handleHLSRequest: No request URL")
            return false 
        }
        
        // Removed repetitive HLS request logs
        
        // For HLS videos, we serve content directly through ResourceLoaderDelegate
        // Check if this is the initial request (base URL without .m3u8)
        let requestPath = requestURL.path
        let baseUrlPath = url.path
        
        // If this is the initial request (the resolved HLS URL that was passed to CachingPlayerItem), 
        // download and cache the master playlist, then serve it directly
        if requestPath == baseUrlPath {
            print("DEBUG: [CachingPlayerItem] handleHLSRequest: Initial HLS request - downloading and serving directly")
            
            // The URL is already resolved (it's the resolved HLS URL passed to CachingPlayerItem)
            print("DEBUG: [CachingPlayerItem] handleHLSRequest: Using resolved HLS URL: \(url.absoluteString)")
            
            // Download and cache the master playlist using dynamic cache path if provided
            let finalCachePath = cachePath ?? saveFilePath
            startHLSPlaylistDownload(loadingRequest, playlistURL: url, cachePath: finalCachePath)
            return true
        } else {
            print("DEBUG: [CachingPlayerItem] handleHLSRequest: Unexpected sub-request")
            return false
        }
    }
    
    private func handlePlaylistRequest(_ loadingRequest: AVAssetResourceLoadingRequest, resolvedURL: URL) -> Bool {
        guard let mediaID = mediaID else { 
            print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: No mediaID - FAILING REQUEST")
            let error = NSError(domain: "CachingPlayerItem", code: -1, userInfo: [NSLocalizedDescriptionKey: "No mediaID - cache issue"])
            loadingRequest.finishLoading(with: error)
            return false
        }
        
        guard loadingRequest.request.url != nil else {
            print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: No request URL")
            return false
        }
        
        // Removed repetitive playlist request log
        
        // Use the resolved HLS URL instead of converting from requestURL
        // The resolvedURL contains the properly resolved master.m3u8 or playlist.m3u8 URL
        let actualPlaylistURL = resolvedURL
        
        // Removed repetitive URL log
        
        // Check if we have a cached playlist for this specific URL
        let cachePath = getCachePath(for: actualPlaylistURL)
        
        if FileManager.default.fileExists(atPath: cachePath) {
            print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Serving cached playlist from \(cachePath)")
            
            do {
                _ = try Data(contentsOf: URL(fileURLWithPath: cachePath))
                
            // Redirect to LocalHTTPServer to serve the cached playlist
            guard let localURL = LocalHTTPServer.shared.getLocalURL(for: mediaID) else {
                print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Failed to get local URL")
                let error = NSError(domain: "CachingPlayerItem", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get local URL"])
                loadingRequest.finishLoading(with: error)
                return false
            }
            
            // Construct the full URL with the filename
            let filename = actualPlaylistURL.lastPathComponent
            let fullURL = localURL.appendingPathComponent(filename)
            
            let response = HTTPURLResponse(url: loadingRequest.request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [
                "Location": fullURL.absoluteString
            ])
            loadingRequest.response = response
            loadingRequest.finishLoading()
            
            print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Redirected to LocalHTTPServer for cached playlist: \(localURL.absoluteString)")
                return true
            } catch {
                print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Failed to read cached playlist: \(error.localizedDescription)")
            }
        }
        
        // If not cached, download and serve
        print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Downloading playlist from \(actualPlaylistURL.absoluteString)")

        let session = URLSession.shared
        var taskId: Int = 0
        let task = session.dataTask(with: actualPlaylistURL) { [weak self] data, response, error in
            defer { self?.removeTask(identifier: taskId) }
            guard let self = self else { return }

            if let error = error {
                print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Download error: \(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
                return
            }

            guard let data = data else {
                print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: No data received")
                let error = NSError(domain: "CachingPlayerItem", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])
                loadingRequest.finishLoading(with: error)
                return
            }

            print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Successfully downloaded playlist, size: \(data.count) bytes")

            // Modify the playlist to use custom scheme URLs for segments and sub-playlists
            let modifiedPlaylistData = self.modifyPlaylistForCustomScheme(data, baseURL: actualPlaylistURL)

            // Cache the modified playlist
            do {
                try modifiedPlaylistData.write(to: URL(fileURLWithPath: cachePath))
                print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Cached modified playlist to \(cachePath)")
            } catch {
                print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Failed to cache playlist: \(error.localizedDescription)")
            }

            // Parse segments and start downloading them (only for sub-playlists that contain actual segments)
            let playlistString = String(data: data, encoding: .utf8) ?? ""
            let segments = self.parsePlaylistSegments(playlistString)
            print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Found \(segments.count) segments in sub-playlist: \(segments)")
            if !segments.isEmpty {
                // For sub-playlists, segments should be downloaded from the same directory as the playlist
                let baseURL = actualPlaylistURL.deletingLastPathComponent()
                print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Using baseURL for segment downloads: \(baseURL.absoluteString)")
                self.downloadHLSSegments(segments, baseURL: baseURL)
            }

            // Serve playlist directly (no redirect!)
            print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Serving playlist DIRECTLY (no redirect!)")

            // Provide ContentInformationRequest for metadata
            if let contentRequest = loadingRequest.contentInformationRequest {
                contentRequest.contentType = "application/vnd.apple.mpegurl"
                contentRequest.contentLength = Int64(modifiedPlaylistData.count)
                contentRequest.isByteRangeAccessSupported = true
            }

            // Serve the modified playlist data directly
            if let dataRequest = loadingRequest.dataRequest {
                dataRequest.respond(with: modifiedPlaylistData)
                print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Served \(modifiedPlaylistData.count) bytes instantly (no redirect!)")
            }

            loadingRequest.finishLoading()
        }

        taskId = task.taskIdentifier
        trackTask(task)
        task.resume()
        return true
    }

    private func handleSegmentRequest(_ loadingRequest: AVAssetResourceLoadingRequest, url: URL) -> Bool {
        guard let requestURL = loadingRequest.request.url else {
            print("DEBUG: [CachingPlayerItem] handleSegmentRequest: No request URL")
            return false
        }
        
        print("DEBUG: [CachingPlayerItem] handleSegmentRequest: requestURL = \(requestURL.absoluteString)")
        print("DEBUG: [CachingPlayerItem] handleSegmentRequest: resolvedURL = \(url.absoluteString)")
        
        // Check if we have a cached segment
        let cachePath = getCachePath(for: url)
        
        if FileManager.default.fileExists(atPath: cachePath) {
            do {
                let cachedData = try Data(contentsOf: URL(fileURLWithPath: cachePath))
                
                // Validate that the cached segment is not empty or too small (likely incomplete)
                if cachedData.count < 1000 { // Less than 1KB is likely an incomplete download
                    print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Cached segment too small (\(cachedData.count) bytes), likely incomplete - will re-download")
                } else {
                    print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Serving cached segment DIRECTLY (no redirect!)")
                    
                    // CRITICAL: Serve data DIRECTLY (instant, no redirect!)
                    // Provide ContentInformationRequest for metadata
                    if let contentRequest = loadingRequest.contentInformationRequest {
                        contentRequest.contentType = "video/MP2T"
                        contentRequest.contentLength = Int64(cachedData.count)
                        contentRequest.isByteRangeAccessSupported = true
                    }
                    
                    // Serve the data directly, respecting byte-range requests
                    if let dataRequest = loadingRequest.dataRequest {
                        let requestedOffset = dataRequest.requestedOffset
                        let requestedLength = dataRequest.requestedLength
                        let currentOffset = dataRequest.currentOffset
                        
                        print("DEBUG: [CachingPlayerItem] handleSegmentRequest: dataRequest - requestedOffset=\(requestedOffset), requestedLength=\(requestedLength), currentOffset=\(currentOffset)")
                        
                        // Calculate the range to serve
                        let startOffset = Int(currentOffset)
                        let endOffset: Int
                        if dataRequest.requestsAllDataToEndOfResource {
                            endOffset = cachedData.count
                        } else {
                            endOffset = min(Int(requestedOffset) + requestedLength, cachedData.count)
                        }
                        
                        let rangeLength = endOffset - startOffset
                        if rangeLength > 0 && startOffset < cachedData.count {
                            let range = startOffset..<min(startOffset + rangeLength, cachedData.count)
                            let subdata = cachedData.subdata(in: range)
                            dataRequest.respond(with: subdata)
                            print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Served \(subdata.count) bytes instantly (range \(startOffset)-\(endOffset), no redirect!)")
                        }
                    }
                    
                    loadingRequest.finishLoading()
                    return true
                }
            } catch {
                print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Failed to read cached segment: \(error.localizedDescription)")
            }
        }
        
        // If not cached, download and serve
        print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Downloading segment from \(url.absoluteString)")

        // Create a custom URLSession with longer timeout to prevent cancellations
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60.0  // 60 seconds
        config.timeoutIntervalForResource = 300.0  // 5 minutes
        let session = URLSession(configuration: config)
        var taskId: Int = 0
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            defer { self?.removeTask(identifier: taskId) }
            guard let self = self else { return }

            if let error = error {
                print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Download error: \(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
                return
            }

            guard let data = data else {
                print("DEBUG: [CachingPlayerItem] handleSegmentRequest: No data received")
                let error = NSError(domain: "CachingPlayerItem", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])
                loadingRequest.finishLoading(with: error)
                return
            }

            print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Successfully downloaded segment, size: \(data.count) bytes")

            // Cache the segment
            do {
                try data.write(to: URL(fileURLWithPath: cachePath))
                print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Cached segment to \(cachePath)")
            } catch {
                print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Failed to cache segment: \(error.localizedDescription)")
            }

            // Redirect to LocalHTTPServer to serve the downloaded segment
            guard let mediaID = self.mediaID,
                  let localURL = LocalHTTPServer.shared.getLocalURL(for: mediaID) else {
                print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Failed to get local URL for downloaded segment")
                let error = NSError(domain: "CachingPlayerItem", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get local URL"])
                loadingRequest.finishLoading(with: error)
                return
            }

            // Construct the full URL with the filename
            let filename = url.lastPathComponent
            let fullURL = localURL.appendingPathComponent(filename)

            let response = HTTPURLResponse(url: requestURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [
                "Location": fullURL.absoluteString
            ])
            loadingRequest.response = response
            loadingRequest.finishLoading()

            print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Redirected to LocalHTTPServer for downloaded segment: \(localURL.absoluteString)")
        }

        taskId = task.taskIdentifier
        trackTask(task)
        task.resume()
        return true
    }
    
    private func handleProgressiveVideoRequest(_ loadingRequest: AVAssetResourceLoadingRequest, url: URL) -> Bool {
        guard let requestURL = loadingRequest.request.url else {
            print("DEBUG: [CachingPlayerItem] handleProgressiveVideoRequest: No request URL")
            return false
        }
        
        print("DEBUG: [CachingPlayerItem] handleProgressiveVideoRequest: requestURL = \(requestURL.absoluteString)")
        print("DEBUG: [CachingPlayerItem] handleProgressiveVideoRequest: resolvedURL = \(url.absoluteString)")
        
        // Check if we have a cached video file
        let cachePath = saveFilePath.isEmpty ? getCachePath(for: url) : saveFilePath
        
        if FileManager.default.fileExists(atPath: cachePath) {
            do {
                let cachedData = try Data(contentsOf: URL(fileURLWithPath: cachePath))
                
                // Validate that the cached file is not empty or too small
                if cachedData.count < 10000 { // Less than 10KB is likely incomplete
                    print("DEBUG: [CachingPlayerItem] handleProgressiveVideoRequest: Cached file too small (\(cachedData.count) bytes), likely incomplete - will re-download")
                } else {
                    print("DEBUG: [CachingPlayerItem] handleProgressiveVideoRequest: Serving cached video DIRECTLY (no redirect!)")
                    
                    // CRITICAL: Serve data DIRECTLY for progressive videos
                    // Provide ContentInformationRequest for metadata
                    if let contentRequest = loadingRequest.contentInformationRequest {
                        contentRequest.contentType = "video/mp4"
                        contentRequest.contentLength = Int64(cachedData.count)
                        contentRequest.isByteRangeAccessSupported = true
                    }
                    
                    // Serve the data directly, respecting byte-range requests
                    if let dataRequest = loadingRequest.dataRequest {
                        let requestedOffset = dataRequest.requestedOffset
                        let requestedLength = dataRequest.requestedLength
                        let currentOffset = dataRequest.currentOffset
                        
                        print("DEBUG: [CachingPlayerItem] handleProgressiveVideoRequest: dataRequest - requestedOffset=\(requestedOffset), requestedLength=\(requestedLength), currentOffset=\(currentOffset)")
                        
                        // Calculate the range to serve
                        let startOffset = Int(currentOffset)
                        let endOffset: Int
                        if dataRequest.requestsAllDataToEndOfResource {
                            endOffset = cachedData.count
                        } else {
                            endOffset = min(Int(requestedOffset) + requestedLength, cachedData.count)
                        }
                        
                        let rangeLength = endOffset - startOffset
                        if rangeLength > 0 && startOffset < cachedData.count {
                            let range = startOffset..<min(startOffset + rangeLength, cachedData.count)
                            let subdata = cachedData.subdata(in: range)
                            dataRequest.respond(with: subdata)
                            print("DEBUG: [CachingPlayerItem] handleProgressiveVideoRequest: Served \(subdata.count) bytes instantly (range \(startOffset)-\(endOffset))")
                        }
                    }
                    
                    loadingRequest.finishLoading()
                    return true
                }
            } catch {
                print("DEBUG: [CachingPlayerItem] handleProgressiveVideoRequest: Failed to read cached video: \(error.localizedDescription)")
            }
        }
        
        // If not cached, download and cache the video
        print("DEBUG: [CachingPlayerItem] handleProgressiveVideoRequest: Downloading video from \(url.absoluteString)")
        
        // Create a custom URLSession with longer timeout for video files
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0  // 30 seconds per request
        config.timeoutIntervalForResource = 300.0  // 5 minutes for the whole file
        let session = URLSession(configuration: config)
        
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("DEBUG: [CachingPlayerItem] handleProgressiveVideoRequest: Download error: \(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
                return
            }
            
            guard let data = data else {
                print("DEBUG: [CachingPlayerItem] handleProgressiveVideoRequest: No data received")
                let error = NSError(domain: "CachingPlayerItem", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])
                loadingRequest.finishLoading(with: error)
                return
            }
            
            print("DEBUG: [CachingPlayerItem] handleProgressiveVideoRequest: Successfully downloaded video, size: \(data.count) bytes")
            
            // Cache the video file
            do {
                // Ensure the directory exists
                let cacheURL = URL(fileURLWithPath: cachePath)
                let cacheDir = cacheURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                
                try data.write(to: cacheURL)
                print("DEBUG: [CachingPlayerItem] handleProgressiveVideoRequest: Cached video to \(cachePath)")
                
                // Notify owner that download completed
                if let owner = self.owner {
                    DispatchQueue.main.async {
                        owner.delegate?.playerItem?(owner, didFinishDownloadingFileAt: cachePath)
                    }
                }
            } catch {
                print("DEBUG: [CachingPlayerItem] handleProgressiveVideoRequest: Failed to cache video: \(error.localizedDescription)")
            }
            
            // Serve the downloaded data directly
            if let contentRequest = loadingRequest.contentInformationRequest {
                contentRequest.contentType = "video/mp4"
                contentRequest.contentLength = Int64(data.count)
                contentRequest.isByteRangeAccessSupported = true
            }
            
            if let dataRequest = loadingRequest.dataRequest {
                dataRequest.respond(with: data)
                print("DEBUG: [CachingPlayerItem] handleProgressiveVideoRequest: Served \(data.count) bytes after download")
            }
            
            loadingRequest.finishLoading()
        }
        
        task.resume()
        return true
    }
    
    private func getCachePath(for url: URL) -> String {
        let fileName = url.lastPathComponent
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        
        guard let mediaID = mediaID else {
            // Fallback to original behavior if no mediaID
            return cacheDir.appendingPathComponent(fileName).path
        }
        
        let mediaCacheDir = cacheDir.appendingPathComponent(mediaID)
        let urlPath = url.path
        let trimmedQueryPath = urlPath.components(separatedBy: "?").first ?? urlPath
        let relativePath: String
        if let range = trimmedQueryPath.range(of: "/ipfs/\(mediaID)/") {
            let suffix = trimmedQueryPath[range.upperBound...]
            relativePath = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else if let range = trimmedQueryPath.range(of: "/ipfs/\(mediaID)") {
            let suffix = trimmedQueryPath[range.upperBound...]
            relativePath = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            relativePath = ""
        }
        let finalComponent = relativePath.isEmpty ? fileName : relativePath
        let cacheURL = mediaCacheDir.appendingPathComponent(finalComponent)
        let directoryURL = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return cacheURL.path
    }
    
    private func startHLSPlaylistDownload(_ loadingRequest: AVAssetResourceLoadingRequest, playlistURL: URL, cachePath: String) {
        print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Starting download from \(playlistURL.absoluteString)")
        
            // Check if playlist is already cached
            if FileManager.default.fileExists(atPath: cachePath) {
                print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Playlist already cached at \(cachePath), validating cache")

                do {
                    let cachedData = try Data(contentsOf: URL(fileURLWithPath: cachePath))
                    let playlistString = String(data: cachedData, encoding: .utf8) ?? ""
                    
                    // Validate that the cached playlist contains segment references
                    // Check for both standard segment naming (segment000.ts) and custom naming (playlist_000.ts)
                    let hasValidSegments = playlistString.contains(".ts") && playlistString.split(separator: "\n").contains { line in
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.hasSuffix(".ts") && !trimmed.hasPrefix("#")
                    }
                    
                    if hasValidSegments {
                        print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Serving cached playlist, size: \(cachedData.count) bytes")

                        // Serve the cached playlist directly
                        let response = HTTPURLResponse(url: loadingRequest.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                            "Content-Type": "application/vnd.apple.mpegurl",
                            "Content-Length": "\(cachedData.count)"
                        ])
                        loadingRequest.response = response
                        loadingRequest.dataRequest?.respond(with: cachedData)
                        loadingRequest.finishLoading()

                        // Notify owner about serving from cache
                        DispatchQueue.main.async {
                            self.owner?.delegate?.playerItem?(self.owner!, didFinishDownloadingFileAt: cachePath)
                        }
                        return
                    } else {
                        print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Cached playlist is invalid (no segments), will re-download")
                        // Remove invalid cached playlist
                        try? FileManager.default.removeItem(atPath: cachePath)
                    }
                } catch {
                    print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Failed to read cached playlist: \(error.localizedDescription), will re-download")
                }
            }
        
        // Create a custom URLSession with longer timeout to prevent cancellations
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60.0  // 60 seconds
        config.timeoutIntervalForResource = 300.0  // 5 minutes
        let session = URLSession(configuration: config)
        var taskId: Int = 0
        let task = session.dataTask(with: playlistURL) { [weak self] data, response, error in
            defer { self?.removeTask(identifier: taskId) }
            guard let self = self else { return }

            if let error = error {
                print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Download error: \(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
                return
            }

            guard let data = data else {
                print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: No data received")
                let error = NSError(domain: "CachingPlayerItem", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])
                loadingRequest.finishLoading(with: error)
                return
            }

            print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Successfully downloaded playlist, size: \(data.count) bytes")

            // Modify the playlist to use custom scheme URLs for segments and sub-playlists
            let modifiedPlaylistData = self.modifyPlaylistForCustomScheme(data, baseURL: playlistURL)

            // Cache the modified playlist to the specific cache path
            do {
                try modifiedPlaylistData.write(to: URL(fileURLWithPath: cachePath))
                print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Cached modified playlist to \(cachePath)")
            } catch {
                print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Failed to cache playlist: \(error.localizedDescription)")
            }

            // Parse segments and start downloading them (only for master playlists)
            let playlistString = String(data: data, encoding: .utf8) ?? ""
            let segments = self.parsePlaylistSegments(playlistString)
            if !segments.isEmpty {
                // For master playlists, segments should be downloaded from the same directory as the playlist
                let baseURL = playlistURL.deletingLastPathComponent()
                self.downloadHLSSegments(segments, baseURL: baseURL)
            }

            // Serve the modified playlist directly
            print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Serving modified playlist directly")

            // Create minimal response that AVPlayer expects for HLS playlists
            let response = HTTPURLResponse(url: loadingRequest.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "application/vnd.apple.mpegurl",
                "Content-Length": "\(modifiedPlaylistData.count)"
            ])
            loadingRequest.response = response
            loadingRequest.dataRequest?.respond(with: modifiedPlaylistData)
            loadingRequest.finishLoading()

            // Notify owner about download completion
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.owner?.delegate?.playerItem?(self.owner!, didFinishDownloadingFileAt: cachePath)
            }
        }

        taskId = task.taskIdentifier

        trackTask(task)
        task.resume()
    }
    
    private func downloadHLSSegment(from url: URL, to localPath: String, loadingRequest: AVAssetResourceLoadingRequest) {
        print("DEBUG: [CachingPlayerItem] downloadHLSSegment: Starting download from \(url.absoluteString)")
        print("DEBUG: [CachingPlayerItem] downloadHLSSegment: Saving to \(localPath)")
        
        let session = URLSession.shared
        let task = session.dataTask(with: url) { data, response, error in
            if let error = error {
                print("DEBUG: [CachingPlayerItem] downloadHLSSegment: Download error: \(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
                return
            }
            
            guard let data = data else {
                print("DEBUG: [CachingPlayerItem] downloadHLSSegment: No data received")
                let error = NSError(domain: "CachingPlayerItem", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])
                loadingRequest.finishLoading(with: error)
                return
            }
            
            print("DEBUG: [CachingPlayerItem] downloadHLSSegment: Successfully downloaded segment, size: \(data.count) bytes")
            
            // Save to local path
            do {
                try data.write(to: URL(fileURLWithPath: localPath))
                print("DEBUG: [CachingPlayerItem] downloadHLSSegment: Saved segment to \(localPath)")
            } catch {
                print("DEBUG: [CachingPlayerItem] downloadHLSSegment: Failed to save segment: \(error.localizedDescription)")
            }
            
            // Try using NSURLResponse instead of HTTPURLResponse
            let response = URLResponse(url: loadingRequest.request.url!, mimeType: "video/mp2t", expectedContentLength: data.count, textEncodingName: nil)
            loadingRequest.response = response
            loadingRequest.dataRequest?.respond(with: data)
            loadingRequest.finishLoading()
        }
        
        task.resume()
    }
    
    private func downloadHLSSegments(_ segments: [String], baseURL: URL) {
        print("DEBUG: [CachingPlayerItem] downloadHLSSegments: Starting download of \(segments.count) segments from baseURL: \(baseURL.absoluteString)")
        
        for segment in segments {
            // Create full URL for segment using the baseURL (original HTTP URL)
            let segmentURL = baseURL.appendingPathComponent(segment)
            let localPath = getCachePath(for: segmentURL)
            
            print("DEBUG: [CachingPlayerItem] downloadHLSSegments: Downloading segment from: \(segmentURL.absoluteString)")
            
            // Download segment in background
            DispatchQueue.global(qos: .background).async {
                self.downloadSegmentInBackground(from: segmentURL, to: localPath)
            }
        }
    }
    
    private func downloadSegmentInBackground(from url: URL, to localPath: String) {
        // Create a custom URLSession with longer timeout to prevent cancellations
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60.0  // 60 seconds
        config.timeoutIntervalForResource = 300.0  // 5 minutes
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: url) { data, response, error in
            if let error = error {
                print("DEBUG: [CachingPlayerItem] downloadSegmentInBackground: Download error: \(error.localizedDescription)")
                    return
                }
                
            guard let data = data else {
                print("DEBUG: [CachingPlayerItem] downloadSegmentInBackground: No data received")
                    return
                }
                
            print("DEBUG: [CachingPlayerItem] downloadSegmentInBackground: Successfully downloaded segment, size: \(data.count) bytes")
            
            // Save to local path
            do {
                // Create directory if it doesn't exist
                let directory = URL(fileURLWithPath: localPath).deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
                
                try data.write(to: URL(fileURLWithPath: localPath))
                print("DEBUG: [CachingPlayerItem] downloadSegmentInBackground: Saved segment to \(localPath)")
            } catch {
                print("DEBUG: [CachingPlayerItem] downloadSegmentInBackground: Failed to save segment: \(error.localizedDescription)")
            }
        }
        
        task.resume()
    }
    
    private func parsePlaylistSegments(_ playlist: String) -> [String] {
        var segments: [String] = []
        let lines = playlist.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Parse segment name
            if trimmedLine.hasSuffix(".ts") {
                segments.append(trimmedLine)
            }
        }
        
        print("DEBUG: [CachingPlayerItem] parsePlaylistSegments: Parsed \(segments.count) segments")
        return segments
    }
    
    private func modifyPlaylistForCustomScheme(_ playlistData: Data, baseURL: URL) -> Data {
        guard let playlistString = String(data: playlistData, encoding: .utf8) else {
            print("DEBUG: [CachingPlayerItem] modifyPlaylistForCustomScheme: Failed to convert playlist data to string")
            return playlistData
        }
        
        var modifiedPlaylist = playlistString
        
        // Get the base URL without the filename to avoid double paths
        let baseURLWithoutFilename = baseURL.deletingLastPathComponent()
        
        // Determine if this is a sub-playlist (contains resolution folder like 480p/720p)
        // Check if the URL path contains a resolution folder before the filename
        let urlPath = baseURL.path
        let isSubPlaylist = urlPath.contains("/480p/") || urlPath.contains("/720p/")
        
        // Extract resolution folder from URL path
        let resolutionFolder: String
        if urlPath.contains("/480p/") {
            resolutionFolder = "480p"
        } else if urlPath.contains("/720p/") {
            resolutionFolder = "720p"
        } else {
            resolutionFolder = ""
        }
        
        print("DEBUG: [CachingPlayerItem] modifyPlaylistForCustomScheme: urlPath = \(urlPath), isSubPlaylist = \(isSubPlaylist), resolutionFolder = \(resolutionFolder)")
        
        // Replace relative segment URLs with custom scheme URLs
        // For sub-playlists: segment000.ts -> cachingPlayerItemScheme://originalHost:port/ipfs/{mediaID}/480p/segment000.ts
        // For master playlists: segment000.ts -> cachingPlayerItemScheme://originalHost:port/ipfs/{mediaID}/segment000.ts
        let segmentPattern = #"^([^#\n\r]+\.ts)$"#
        let regex = try! NSRegularExpression(pattern: segmentPattern, options: [.anchorsMatchLines])
        
        let matches = regex.matches(in: modifiedPlaylist, options: [], range: NSRange(location: 0, length: modifiedPlaylist.count))
        
        // Replace matches in reverse order to maintain string indices
        for match in matches.reversed() {
            if let range = Range(match.range, in: modifiedPlaylist) {
                let segmentName = String(modifiedPlaylist[range])
                let hostWithPort = baseURL.host ?? "localhost"
                let port = baseURL.port != nil ? ":\(baseURL.port!)" : ""
                
                print("DEBUG: [CachingPlayerItem] modifyPlaylistForCustomScheme: Processing segment: '\(segmentName)', baseURLWithoutFilename.path: '\(baseURLWithoutFilename.path)'")
                
                // Check if the segment name already contains the resolution folder
                let cleanSegmentName: String
                if segmentName.hasPrefix("\(resolutionFolder)/") {
                    // Segment name already contains resolution folder, remove it
                    cleanSegmentName = String(segmentName.dropFirst(resolutionFolder.count + 1))
                    print("DEBUG: [CachingPlayerItem] modifyPlaylistForCustomScheme: Removed resolution folder from segment name: '\(segmentName)' -> '\(cleanSegmentName)'")
                } else {
                    // Segment name doesn't contain resolution folder, use as is
                    cleanSegmentName = segmentName
                }
                
                // Use custom scheme (ResourceLoaderDelegate will serve directly, no redirect!)
                let segmentPath = "\(baseURLWithoutFilename.path)/\(cleanSegmentName)"
                let customSchemeURL = "cachingPlayerItemScheme://\(hostWithPort)\(port)\(segmentPath)"
                
                modifiedPlaylist.replaceSubrange(range, with: customSchemeURL)
                print("DEBUG: [CachingPlayerItem] modifyPlaylistForCustomScheme: Replaced \(segmentName) with custom scheme (delegate will serve directly!): \(customSchemeURL)")
            }
        }
        
        // Replace relative playlist URLs with custom scheme URLs
        // Pattern: 720p/playlist.m3u8 -> cachingPlayerItemScheme://originalHost:port/ipfs/{mediaID}/720p/playlist.m3u8
        let playlistPattern = #"^([^#\n\r]+\.m3u8)$"#
        let playlistRegex = try! NSRegularExpression(pattern: playlistPattern, options: [.anchorsMatchLines])
        
        let playlistMatches = playlistRegex.matches(in: modifiedPlaylist, options: [], range: NSRange(location: 0, length: modifiedPlaylist.count))
        
        // Replace matches in reverse order to maintain string indices
        for match in playlistMatches.reversed() {
            if let range = Range(match.range, in: modifiedPlaylist) {
                let playlistName = String(modifiedPlaylist[range])
                let hostWithPort = baseURL.host ?? "localhost"
                let port = baseURL.port != nil ? ":\(baseURL.port!)" : ""
                let customSchemeURL = "cachingPlayerItemScheme://\(hostWithPort)\(port)\(baseURLWithoutFilename.path)/\(playlistName)"
                modifiedPlaylist.replaceSubrange(range, with: customSchemeURL)
                print("DEBUG: [CachingPlayerItem] modifyPlaylistForCustomScheme: Replaced \(playlistName) with custom scheme (delegate will serve directly!): \(customSchemeURL)")
            }
        }
        
        guard let modifiedData = modifiedPlaylist.data(using: .utf8) else {
            print("DEBUG: [CachingPlayerItem] modifyPlaylistForCustomScheme: Failed to convert modified playlist to data")
            return playlistData
        }
        
        print("DEBUG: [CachingPlayerItem] modifyPlaylistForCustomScheme: Modified playlist for custom scheme")
        return modifiedData
    }
    
    // MARK: - Task Tracking for Memory Management

    private func trackTask(_ task: URLSessionDataTask) {
        taskLock.lock()
        activeTasks[task.taskIdentifier] = task
        taskLock.unlock()
    }

    private func removeTask(identifier: Int) {
        taskLock.lock()
        activeTasks.removeValue(forKey: identifier)
        taskLock.unlock()
    }

    // MARK: - Methods expected by CachingPlayerItem

    func invalidateAndCancelSession(shouldResetData: Bool = false) {
        taskLock.lock()
        let tasksToCancel = Array(activeTasks.values)
        activeTasks.removeAll()
        taskLock.unlock()

        for task in tasksToCancel {
            task.cancel()
        }
        print("DEBUG: [CachingPlayerItem] invalidateAndCancelSession: Cancelled \(tasksToCancel.count) active tasks")
    }

    func startFileDownload(with url: URL) {
        // This method is expected by CachingPlayerItem but not used in our implementation
        print("DEBUG: [CachingPlayerItem] startFileDownload called with URL: \(url.absoluteString)")
    }
}