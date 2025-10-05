import Foundation
import AVFoundation

class ResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    private let url: URL
    private let mediaID: String?
    private let saveFilePath: String
    private weak var owner: CachingPlayerItem?

    init(url: URL, mediaID: String?, saveFilePath: String, owner: CachingPlayerItem) {
        self.url = url
        self.mediaID = mediaID
        self.saveFilePath = saveFilePath
        self.owner = owner
        super.init()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let requestURL = loadingRequest.request.url else {
            NSLog("DEBUG: [CachingPlayerItem] resourceLoader: No request URL")
            return false
        }
        
        NSLog("DEBUG: [CachingPlayerItem] resourceLoader: isHLS = true, requestURL = \(requestURL.absoluteString)")
        NSLog("DEBUG: [CachingPlayerItem] resourceLoader: original url = \(url.absoluteString)")
        NSLog("DEBUG: [CachingPlayerItem] resourceLoader: mediaID = \(mediaID ?? "nil")")
        NSLog("DEBUG: [CachingPlayerItem] resourceLoader: saveFilePath = \(saveFilePath)")
        
        // Convert custom scheme URL back to original URL
        guard let originalURL = convertCustomSchemeToOriginalURL(requestURL) else {
            NSLog("DEBUG: [CachingPlayerItem] resourceLoader: Failed to convert custom scheme URL")
            return false
        }
        
        NSLog("DEBUG: [CachingPlayerItem] resourceLoader: converted original URL = \(originalURL.absoluteString)")
        
        // Handle different types of requests
        if originalURL.pathExtension == "m3u8" {
            return handleHLSRequest(loadingRequest, url: originalURL)
        } else if originalURL.pathExtension == "ts" {
            return handleSegmentRequest(loadingRequest, url: originalURL)
        } else {
            NSLog("DEBUG: [CachingPlayerItem] resourceLoader: Unknown file type: \(originalURL.pathExtension)")
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
    
    private func handleHLSRequest(_ loadingRequest: AVAssetResourceLoadingRequest, url: URL) -> Bool {
        guard let requestURL = loadingRequest.request.url else { 
            NSLog("DEBUG: [CachingPlayerItem] handleHLSRequest: No request URL")
            return false 
        }
        
        NSLog("DEBUG: [CachingPlayerItem] handleHLSRequest: requestURL = \(requestURL.absoluteString)")
        NSLog("DEBUG: [CachingPlayerItem] handleHLSRequest: original url = \(url.absoluteString)")
        
        // For HLS videos, we serve content directly through ResourceLoaderDelegate
        // Check if this is the initial request (base URL without .m3u8)
        let requestPath = requestURL.path
        let baseUrlPath = url.path
        
        // If this is the initial request (the resolved HLS URL that was passed to CachingPlayerItem), 
        // download and cache the master playlist, then serve it directly
        if requestPath == baseUrlPath {
            NSLog("DEBUG: [CachingPlayerItem] handleHLSRequest: Initial HLS request - downloading and serving directly")
            
            // The URL is already resolved (it's the resolved HLS URL passed to CachingPlayerItem)
            NSLog("DEBUG: [CachingPlayerItem] handleHLSRequest: Using resolved HLS URL: \(url.absoluteString)")
            
            // Download and cache the master playlist
            startHLSPlaylistDownload(loadingRequest, playlistURL: url, cachePath: saveFilePath)
            return true
        } else {
            NSLog("DEBUG: [CachingPlayerItem] handleHLSRequest: Unexpected sub-request")
            return false
        }
    }
    
    private func handlePlaylistRequest(_ loadingRequest: AVAssetResourceLoadingRequest, resolvedURL: URL) -> Bool {
        guard let mediaID = mediaID else { 
            NSLog("DEBUG: [CachingPlayerItem] handlePlaylistRequest: No mediaID - FAILING REQUEST")
            let error = NSError(domain: "CachingPlayerItem", code: -1, userInfo: [NSLocalizedDescriptionKey: "No mediaID - cache issue"])
            loadingRequest.finishLoading(with: error)
            return false
        }
        
        guard loadingRequest.request.url != nil else {
            NSLog("DEBUG: [CachingPlayerItem] handlePlaylistRequest: No request URL")
            return false
        }
        
        NSLog("DEBUG: [CachingPlayerItem] handlePlaylistRequest: mediaID = \(mediaID)")
        
        // Use the resolved HLS URL instead of converting from requestURL
        // The resolvedURL contains the properly resolved master.m3u8 or playlist.m3u8 URL
        let actualPlaylistURL = resolvedURL
        
        NSLog("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Actual playlist URL = \(actualPlaylistURL.absoluteString)")
        
        // Check if we have a cached playlist for this specific URL
        let cachePath = getCachePath(for: actualPlaylistURL)
        
        if FileManager.default.fileExists(atPath: cachePath) {
            NSLog("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Serving cached playlist from \(cachePath)")
            
            do {
                let _ = try Data(contentsOf: URL(fileURLWithPath: cachePath))
                
                // Redirect to LocalHTTPServer instead of serving data directly
                let localURL = LocalHTTPServer.shared.getLocalURL(for: mediaID)
                if let localURL = localURL {
                    let redirectResponse = HTTPURLResponse(url: loadingRequest.request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [
                        "Location": localURL.absoluteString
                    ])
                    loadingRequest.response = redirectResponse
                    loadingRequest.finishLoading()
                    
                    NSLog("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Redirecting to LocalHTTPServer: \(localURL.absoluteString)")
                    return true
                }
                
                return true
            } catch {
                NSLog("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Failed to read cached playlist: \(error.localizedDescription)")
            }
        }
        
        // If not cached, download and serve
        NSLog("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Downloading playlist from \(actualPlaylistURL.absoluteString)")
        
        let session = URLSession.shared
        let task = session.dataTask(with: actualPlaylistURL) { [self] data, response, error in
            if let error = error {
                NSLog("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Download error: \(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
                return
            }
            
            guard let data = data else {
                NSLog("DEBUG: [CachingPlayerItem] handlePlaylistRequest: No data received")
                let error = NSError(domain: "CachingPlayerItem", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])
                loadingRequest.finishLoading(with: error)
                return
            }
            
            NSLog("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Successfully downloaded playlist, size: \(data.count) bytes")
            
            // Modify the playlist to use custom scheme URLs for segments and sub-playlists
            let modifiedPlaylistData = self.modifyPlaylistForCustomScheme(data, baseURL: actualPlaylistURL)
            
            // Cache the modified playlist
            do {
                try modifiedPlaylistData.write(to: URL(fileURLWithPath: cachePath))
                NSLog("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Cached modified playlist to \(cachePath)")
            } catch {
                NSLog("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Failed to cache playlist: \(error.localizedDescription)")
            }
            
            // Parse segments and start downloading them (only for sub-playlists that contain actual segments)
            let playlistString = String(data: data, encoding: .utf8) ?? ""
            let segments = self.parsePlaylistSegments(playlistString)
            NSLog("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Found \(segments.count) segments in sub-playlist: \(segments)")
            if !segments.isEmpty {
                // For sub-playlists, segments should be downloaded from the same directory as the playlist
                let baseURL = actualPlaylistURL.deletingLastPathComponent()
                NSLog("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Using baseURL for segment downloads: \(baseURL.absoluteString)")
                self.downloadHLSSegments(segments, baseURL: baseURL)
            }
            
            // Redirect to LocalHTTPServer instead of serving data directly
            let localURL = LocalHTTPServer.shared.getLocalURL(for: mediaID)
            if let localURL = localURL {
                let redirectResponse = HTTPURLResponse(url: loadingRequest.request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [
                    "Location": localURL.absoluteString
                ])
                loadingRequest.response = redirectResponse
            loadingRequest.finishLoading()
                
                NSLog("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Redirecting to LocalHTTPServer: \(localURL.absoluteString)")
            }
        }
        
        task.resume()
        return true
    }
    
    private func handleSegmentRequest(_ loadingRequest: AVAssetResourceLoadingRequest, url: URL) -> Bool {
        guard let requestURL = loadingRequest.request.url else {
            NSLog("DEBUG: [CachingPlayerItem] handleSegmentRequest: No request URL")
            return false
        }
        
        NSLog("DEBUG: [CachingPlayerItem] handleSegmentRequest: requestURL = \(requestURL.absoluteString)")
        NSLog("DEBUG: [CachingPlayerItem] handleSegmentRequest: resolvedURL = \(url.absoluteString)")
        
        // Check if we have a cached segment
        let cachePath = getCachePath(for: url)
        
        if FileManager.default.fileExists(atPath: cachePath) {
            do {
                let cachedData = try Data(contentsOf: URL(fileURLWithPath: cachePath))
                
                // Validate that the cached segment is not empty or too small (likely incomplete)
                if cachedData.count < 1000 { // Less than 1KB is likely an incomplete download
                    NSLog("DEBUG: [CachingPlayerItem] handleSegmentRequest: Cached segment too small (\(cachedData.count) bytes), likely incomplete - will re-download")
                } else {
                    NSLog("DEBUG: [CachingPlayerItem] handleSegmentRequest: Serving cached segment from \(cachePath) (size: \(cachedData.count) bytes)")
                    
                    // Redirect to LocalHTTPServer instead of serving data directly
                    guard let mediaID = mediaID else {
                        NSLog("DEBUG: [CachingPlayerItem] handleSegmentRequest: Missing mediaID - cannot redirect to LocalHTTPServer")
                        return false
                    }
                    let localURL = LocalHTTPServer.shared.getLocalURL(for: mediaID)
                    if let localURL = localURL {
                        let segmentName = url.lastPathComponent
                        let redirectURL = localURL.appendingPathComponent(segmentName)
                        
                        let redirectResponse = HTTPURLResponse(url: requestURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [
                            "Location": redirectURL.absoluteString
                        ])
                        loadingRequest.response = redirectResponse
                        loadingRequest.finishLoading()
                        
                        NSLog("DEBUG: [CachingPlayerItem] handleSegmentRequest: Redirecting to LocalHTTPServer: \(redirectURL.absoluteString)")
                        return true
                    }
                    
                    return true
                }
            } catch {
                NSLog("DEBUG: [CachingPlayerItem] handleSegmentRequest: Failed to read cached segment: \(error.localizedDescription)")
            }
        }
        
        // If not cached, download and serve
        NSLog("DEBUG: [CachingPlayerItem] handleSegmentRequest: Downloading segment from \(url.absoluteString)")
        
        let session = URLSession.shared
        let task = session.dataTask(with: url) { [self] data, response, error in
            if let error = error {
                NSLog("DEBUG: [CachingPlayerItem] handleSegmentRequest: Download error: \(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
                return
            }
            
            guard let data = data else {
                NSLog("DEBUG: [CachingPlayerItem] handleSegmentRequest: No data received")
                let error = NSError(domain: "CachingPlayerItem", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])
                loadingRequest.finishLoading(with: error)
                return
            }
            
            NSLog("DEBUG: [CachingPlayerItem] handleSegmentRequest: Successfully downloaded segment, size: \(data.count) bytes")
            
            // Cache the segment
            do {
                try data.write(to: URL(fileURLWithPath: cachePath))
                NSLog("DEBUG: [CachingPlayerItem] handleSegmentRequest: Cached segment to \(cachePath)")
            } catch {
                NSLog("DEBUG: [CachingPlayerItem] handleSegmentRequest: Failed to cache segment: \(error.localizedDescription)")
            }
            
            // Redirect to LocalHTTPServer instead of serving data directly
            guard let mediaID = mediaID else {
                NSLog("DEBUG: [CachingPlayerItem] handleSegmentRequest: Missing mediaID - cannot redirect to LocalHTTPServer")
                return
            }
            let localURL = LocalHTTPServer.shared.getLocalURL(for: mediaID)
            if let localURL = localURL {
                let segmentName = url.lastPathComponent
                let redirectURL = localURL.appendingPathComponent(segmentName)
                
                let redirectResponse = HTTPURLResponse(url: requestURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [
                    "Location": redirectURL.absoluteString
                ])
                loadingRequest.response = redirectResponse
                loadingRequest.finishLoading()
                
                NSLog("DEBUG: [CachingPlayerItem] handleSegmentRequest: Redirecting to LocalHTTPServer: \(redirectURL.absoluteString)")
            }
        }
        
        task.resume()
        return true
    }
    
    private func getCachePath(for url: URL) -> String {
        let fileName = url.lastPathComponent
        
        // Include mediaID in the cache path to prevent conflicts between different videos
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        
        if let mediaID = mediaID {
            // Create a subdirectory for each media ID
            let mediaCacheDir = cacheDir.appendingPathComponent(mediaID)
            return mediaCacheDir.appendingPathComponent(fileName).path
        } else {
            // Fallback to original behavior if no mediaID
            return cacheDir.appendingPathComponent(fileName).path
        }
    }
    
    private func startHLSPlaylistDownload(_ loadingRequest: AVAssetResourceLoadingRequest, playlistURL: URL, cachePath: String) {
        NSLog("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Starting download from \(playlistURL.absoluteString)")
        
        let session = URLSession.shared
        let task = session.dataTask(with: playlistURL) { [self] data, response, error in
            if let error = error {
                NSLog("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Download error: \(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
                return
            }
            
            guard let data = data else {
                NSLog("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: No data received")
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
            NSLog("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Serving modified playlist directly")
            
            // Create minimal response that AVPlayer expects for HLS playlists
            let response = HTTPURLResponse(url: loadingRequest.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "application/vnd.apple.mpegurl",
                "Content-Length": "\(modifiedPlaylistData.count)"
            ])
            loadingRequest.response = response
            loadingRequest.dataRequest?.respond(with: modifiedPlaylistData)
                loadingRequest.finishLoading()
            
            // Notify owner about download completion
            DispatchQueue.main.async {
                self.owner?.delegate?.playerItem?(self.owner!, didFinishDownloadingFileAt: cachePath)
            }
        }
        
        task.resume()
    }
    
    private func downloadHLSSegment(from url: URL, to localPath: String, loadingRequest: AVAssetResourceLoadingRequest) {
        print("DEBUG: [CachingPlayerItem] downloadHLSSegment: Starting download from \(url.absoluteString)")
        print("DEBUG: [CachingPlayerItem] downloadHLSSegment: Saving to \(localPath)")
        
        let session = URLSession.shared
        let task = session.dataTask(with: url) { [self] data, response, error in
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
        NSLog("DEBUG: [CachingPlayerItem] downloadHLSSegments: Starting download of \(segments.count) segments from baseURL: \(baseURL.absoluteString)")
        
        for segment in segments {
            // Create full URL for segment using the baseURL (original HTTP URL)
            let segmentURL = baseURL.appendingPathComponent(segment)
            let localPath = getCachePath(for: segmentURL)
            
            NSLog("DEBUG: [CachingPlayerItem] downloadHLSSegments: Downloading segment from: \(segmentURL.absoluteString)")
            
            // Download segment in background
            DispatchQueue.global(qos: .background).async {
                self.downloadSegmentInBackground(from: segmentURL, to: localPath)
            }
        }
    }
    
    private func downloadSegmentInBackground(from url: URL, to localPath: String) {
        let session = URLSession.shared
        let task = session.dataTask(with: url) { [self] data, response, error in
            if let error = error {
                NSLog("DEBUG: [CachingPlayerItem] downloadSegmentInBackground: Download error: \(error.localizedDescription)")
                    return
                }
                
            guard let data = data else {
                NSLog("DEBUG: [CachingPlayerItem] downloadSegmentInBackground: No data received")
                    return
                }
                
            NSLog("DEBUG: [CachingPlayerItem] downloadSegmentInBackground: Successfully downloaded segment, size: \(data.count) bytes")
            
            // Save to local path
            do {
                // Create directory if it doesn't exist
                let directory = URL(fileURLWithPath: localPath).deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
                
                try data.write(to: URL(fileURLWithPath: localPath))
                NSLog("DEBUG: [CachingPlayerItem] downloadSegmentInBackground: Saved segment to \(localPath)")
            } catch {
                NSLog("DEBUG: [CachingPlayerItem] downloadSegmentInBackground: Failed to save segment: \(error.localizedDescription)")
            }
        }
        
        task.resume()
    }
    
    private func parsePlaylistSegments(_ playlist: String) -> [String] {
        var segments: [String] = []
        let lines = playlist.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.hasSuffix(".ts") {
                segments.append(trimmedLine)
            }
        }
        
        return segments
    }
    
    private func modifyPlaylistForCustomScheme(_ playlistData: Data, baseURL: URL) -> Data {
        guard let playlistString = String(data: playlistData, encoding: .utf8) else {
            NSLog("DEBUG: [CachingPlayerItem] modifyPlaylistForCustomScheme: Failed to convert playlist data to string")
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
        
        NSLog("DEBUG: [CachingPlayerItem] modifyPlaylistForCustomScheme: urlPath = \(urlPath), isSubPlaylist = \(isSubPlaylist), resolutionFolder = \(resolutionFolder)")
        
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
                
                NSLog("DEBUG: [CachingPlayerItem] modifyPlaylistForCustomScheme: Processing segment: '\(segmentName)', baseURLWithoutFilename.path: '\(baseURLWithoutFilename.path)'")
                
                // Check if the segment name already contains the resolution folder
                let cleanSegmentName: String
                if segmentName.hasPrefix("\(resolutionFolder)/") {
                    // Segment name already contains resolution folder, remove it
                    cleanSegmentName = String(segmentName.dropFirst(resolutionFolder.count + 1))
                    NSLog("DEBUG: [CachingPlayerItem] modifyPlaylistForCustomScheme: Removed resolution folder from segment name: '\(segmentName)' -> '\(cleanSegmentName)'")
                } else {
                    // Segment name doesn't contain resolution folder, use as is
                    cleanSegmentName = segmentName
                }
                
                // For segments, always use the baseURLWithoutFilename path directly
                // The segments are in the same directory as the playlist
                let segmentPath = "\(baseURLWithoutFilename.path)/\(cleanSegmentName)"
                let customSchemeURL = "cachingPlayerItemScheme://\(hostWithPort)\(port)\(segmentPath)"
                
                modifiedPlaylist.replaceSubrange(range, with: customSchemeURL)
                NSLog("DEBUG: [CachingPlayerItem] modifyPlaylistForCustomScheme: Replaced \(segmentName) with \(customSchemeURL)")
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
                NSLog("DEBUG: [CachingPlayerItem] modifyPlaylistForCustomScheme: Replaced \(playlistName) with \(customSchemeURL)")
            }
        }
        
        guard let modifiedData = modifiedPlaylist.data(using: .utf8) else {
            NSLog("DEBUG: [CachingPlayerItem] modifyPlaylistForCustomScheme: Failed to convert modified playlist to data")
            return playlistData
        }
        
        NSLog("DEBUG: [CachingPlayerItem] modifyPlaylistForCustomScheme: Modified playlist for custom scheme")
        return modifiedData
    }
    
    // MARK: - Methods expected by CachingPlayerItem
    
    func invalidateAndCancelSession(shouldResetData: Bool = false) {
        // This method is expected by CachingPlayerItem but not used in our implementation
        NSLog("DEBUG: [CachingPlayerItem] invalidateAndCancelSession called with shouldResetData: \(shouldResetData)")
    }
    
    func startFileDownload(with url: URL) {
        // This method is expected by CachingPlayerItem but not used in our implementation
        NSLog("DEBUG: [CachingPlayerItem] startFileDownload called with URL: \(url.absoluteString)")
    }
}