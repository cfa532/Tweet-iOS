import Foundation
import Network

public class LocalHTTPServer: @unchecked Sendable {
    public static let shared = LocalHTTPServer()
    
    private var listener: NWListener?
    public private(set) var port: UInt16 = 8080  // Public read, private write
    private var mediaCache: [String: String] = [:] // mediaID -> cachePath
    private var mediaRealURLs: [String: URL] = [:] // mediaID -> real URL
    private let queue = DispatchQueue(label: "LocalHTTPServer", qos: .userInitiated)
    
    // Connection pool for efficient HTTP requests
    private lazy var connectionPool: URLSession = {
        let config = URLSessionConfiguration.default
        
        // Connection pool settings for better performance
        config.httpMaximumConnectionsPerHost = 6  // Multiple concurrent connections per node
        config.timeoutIntervalForRequest = 30     // 30 seconds per request
        config.timeoutIntervalForResource = 300   // 5 minutes total
        
        // Enable HTTP pipelining for better throughput
        config.httpShouldUsePipelining = true
        
        // Disable URLSession cache (we handle caching ourselves)
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        NSLog("DEBUG: [LocalHTTPServer] Connection pool initialized with max 6 connections per host")
        return URLSession(configuration: config)
    }()
    
    private init() {}
    
    public func start() {
        queue.async { [weak self] in
            self?.startServer()
        }
    }
    
    public func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
        }
    }
    
    public func registerMedia(mediaID: String, cachePath: String) {
        queue.async { [weak self] in
            self?.mediaCache[mediaID] = cachePath
            NSLog("DEBUG: [LocalHTTPServer] Registered media \(mediaID) -> \(cachePath)")
        }
    }
    
    public func registerAndGetURL(for mediaID: String, realURL: URL) -> URL {
        // Store the mapping (synchronous to ensure it's available immediately)
        queue.sync {
            mediaRealURLs[mediaID] = realURL
        }
        
        // Return localhost URL: http://localhost:8080/mediaID/path
        // AVPlayer will request this, and we'll serve from cache or fetch from realURL
        let localhostURL = URL(string: "http://127.0.0.1:\(port)/\(mediaID)\(realURL.path)")!
        NSLog("DEBUG: [LocalHTTPServer] Registered \(mediaID): localhost=\(localhostURL.absoluteString), real=\(realURL.absoluteString)")
        return localhostURL
    }
    
    public func getLocalURL(for mediaID: String) -> URL? {
        return URL(string: "http://localhost:\(port)/media/\(mediaID)/")
    }
    
    private func startServer() {
        // Don't start if already listening
        if listener?.state == .ready {
            NSLog("DEBUG: [LocalHTTPServer] Already running on port \(port)")
            return
        }
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        // Try to find an available port, starting from 8080
        let maxAttempts = 10
        var startPort = port
        
        for attempt in 0..<maxAttempts {
            let tryPort = startPort + UInt16(attempt)
            
            do {
                let testListener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: tryPort))
                
                // Check if it started successfully
                var didStart = false
                testListener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        didStart = true
                        self?.port = tryPort
                        NSLog("DEBUG: [LocalHTTPServer] ✅ Successfully started on port \(tryPort)")
                    case .failed(let error):
                        NSLog("DEBUG: [LocalHTTPServer] Port \(tryPort) failed: \(error)")
                    default:
                        break
                    }
                }
                
                testListener.newConnectionHandler = { [weak self] connection in
                    self?.handleConnection(connection)
                }
                
                testListener.start(queue: queue)
                
                // Store the successful listener
                self.listener = testListener
                
                // Port found successfully
                NSLog("DEBUG: [LocalHTTPServer] Attempting to bind to port \(tryPort)...")
                return
                
            } catch {
                NSLog("DEBUG: [LocalHTTPServer] Port \(tryPort) unavailable: \(error.localizedDescription)")
                continue
            }
        }
        
        NSLog("DEBUG: [LocalHTTPServer] ❌ Failed to find available port after \(maxAttempts) attempts")
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveNextRequest(connection: connection)
    }
    
    private func receiveNextRequest(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("DEBUG: [LocalHTTPServer] Receive error: \(error), isComplete: \(isComplete)")
            }
            
            if let data = data, !data.isEmpty {
                let request = String(data: data, encoding: .utf8) ?? ""
                let requestLine = request.components(separatedBy: .newlines).first ?? ""
                NSLog("DEBUG: [LocalHTTPServer] Received request: \(requestLine)")
                
                // Handle the request
                self.handleRequest(request, connection: connection) {
                    // After handling, continue listening for more requests
                    if !isComplete && error == nil {
                        NSLog("DEBUG: [LocalHTTPServer] Waiting for next request on same connection...")
                        self.receiveNextRequest(connection: connection)
                    } else {
                        NSLog("DEBUG: [LocalHTTPServer] Connection complete or error, closing")
                        connection.cancel()
                    }
                }
            } else if isComplete || error != nil {
                NSLog("DEBUG: [LocalHTTPServer] No data, connection complete or error - closing")
                connection.cancel()
            } else {
                // No data yet, keep waiting
                self.receiveNextRequest(connection: connection)
            }
        }
    }
    
    private func handleRequest(_ request: String, connection: NWConnection, completion: @escaping () -> Void) {
        let lines = request.components(separatedBy: .newlines)
        guard let firstLine = lines.first else {
            completion()
            return
        }
        
        let components = firstLine.components(separatedBy: " ")
        guard components.count >= 3 else {
            completion()
            return
        }
        
        let method = components[0]
        let path = components[1]
        
        if method == "GET" || method == "HEAD" {
            handleGetRequest(path: path, method: method, connection: connection, completion: completion)
        } else {
            sendResponse(connection: connection, statusCode: 405, headers: [:], body: nil)
            completion()
        }
    }
    
    private func handleGetRequest(path: String, method: String, connection: NWConnection, completion: @escaping () -> Void) {
        // NEW FORMAT: /mediaID/ipfs/hash/path (e.g., /QmAbc.../ipfs/QmAbc.../master.m3u8)
        // Extract mediaID (first component after /)
        let pathComponents = path.components(separatedBy: "/").filter { !$0.isEmpty }
        guard pathComponents.count >= 1 else {
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
            completion()
            return
        }
        
        let mediaID = pathComponents[0]
        
        // Reconstruct the relative path (everything after mediaID)
        let relativePath = "/" + pathComponents[1...].joined(separator: "/")
        
        NSLog("DEBUG: [LocalHTTPServer] Request: mediaID=\(mediaID), relativePath=\(relativePath)")
        
        // Get real URL for this media
        guard let realURL = mediaRealURLs[mediaID] else {
            NSLog("DEBUG: [LocalHTTPServer] No real URL found for mediaID: \(mediaID)")
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
            completion()
            return
        }
        
        // Construct full real URL for this specific file
        // CRITICAL: Strip query params (like ?dig=XXXX) - they're only for AVPlayer cache-busting
        // Remote server might not handle them correctly
        guard var components = URLComponents(url: realURL, resolvingAgainstBaseURL: false) else {
            NSLog("DEBUG: [LocalHTTPServer] Failed to parse URL components")
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
            completion()
            return
        }
        
        // Replace path with requested file
        components.path = relativePath
        
        // CRITICAL: Remove query params - remote server should ignore them but might not!
        let hadQuery = components.query != nil
        components.query = nil
        
        guard let fullRealURL = components.url else {
            NSLog("DEBUG: [LocalHTTPServer] Failed to construct URL")
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
            completion()
            return
        }
        
        if hadQuery {
            NSLog("DEBUG: [LocalHTTPServer] Resolved (stripped query): \(fullRealURL.absoluteString)")
        } else {
            NSLog("DEBUG: [LocalHTTPServer] Resolved: \(fullRealURL.absoluteString)")
        }
        
        // Check if this is a playlist (.m3u8) or segment (.ts)
        if relativePath.hasSuffix(".m3u8") {
            handlePlaylistRequest(fullRealURL: fullRealURL, mediaID: mediaID, connection: connection, method: method)
            completion()
        } else if relativePath.hasSuffix(".ts") {
            handleSegmentRequest(fullRealURL: fullRealURL, mediaID: mediaID, connection: connection, method: method)
            completion()
        } else {
            NSLog("DEBUG: [LocalHTTPServer] Unknown file type: \(relativePath)")
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
            completion()
        }
    }
    
    private func handlePlaylistRequest(fullRealURL: URL, mediaID: String, connection: NWConnection, method: String) {
        let cachePath = getCachePath(for: fullRealURL, mediaID: mediaID)
        
        // Check cache first
        if FileManager.default.fileExists(atPath: cachePath) {
            NSLog("DEBUG: [LocalHTTPServer] Serving cached playlist: \(cachePath)")
            
            // Read, rewrite URLs, and serve
            if let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
               let playlistString = String(data: data, encoding: .utf8) {
                let modifiedPlaylist = rewritePlaylistURLs(playlistString, mediaID: mediaID, baseURL: fullRealURL)
                if let modifiedData = modifiedPlaylist.data(using: .utf8) {
                    let headers: [String: String] = [
                        "Content-Type": "application/vnd.apple.mpegurl",
                        "Content-Length": "\(modifiedData.count)",
                        "Accept-Ranges": "bytes"
                    ]
                    sendResponse(connection: connection, statusCode: 200, headers: headers, body: modifiedData)
                    NSLog("DEBUG: [LocalHTTPServer] Served cached playlist with rewritten URLs")
                    return
                }
            }
            
            // Fallback to original file if rewrite fails
            serveFile(path: cachePath, connection: connection, method: method)
            return
        }
        
        // Not cached - fetch from real server
        NSLog("DEBUG: [LocalHTTPServer] Fetching playlist from: \(fullRealURL.absoluteString)")
        fetchAndServe(url: fullRealURL, cachePath: cachePath, connection: connection, method: method)
    }
    
    private func handleSegmentRequest(fullRealURL: URL, mediaID: String, connection: NWConnection, method: String) {
        let cachePath = getCachePath(for: fullRealURL, mediaID: mediaID)
        
        // Check cache first
        if FileManager.default.fileExists(atPath: cachePath) {
            NSLog("DEBUG: [LocalHTTPServer] Serving cached segment: \(cachePath)")
            serveFile(path: cachePath, connection: connection, method: method)
            return
        }
        
        // Not cached - fetch from real server
        NSLog("DEBUG: [LocalHTTPServer] Fetching segment from: \(fullRealURL.absoluteString)")
        fetchAndServe(url: fullRealURL, cachePath: cachePath, connection: connection, method: method)
    }
    
    private func getCachePath(for url: URL, mediaID: String) -> String {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let mediaDir = cacheDir.appendingPathComponent(mediaID)
        
        // CRITICAL: Preserve full path structure (including /720p, /480p folders)
        // Extract path after /ipfs/mediaID/
        let urlPath = url.path
        if let range = urlPath.range(of: "/ipfs/\(mediaID)/") {
            // Get everything after /ipfs/mediaID/ (e.g., "720p/playlist.m3u8" or "segment000.ts")
            let relativePath = String(urlPath[range.upperBound...])
            let cleanPath = relativePath.components(separatedBy: "?")[0] // Remove query params
            let fullCacheURL = mediaDir.appendingPathComponent(cleanPath)
            
            // Create subdirectories if needed (e.g., /720p, /480p)
            let subdirURL = fullCacheURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
            
            return fullCacheURL.path
        }
        
        // Fallback: just use filename (shouldn't happen with proper URLs)
        let filename = url.lastPathComponent.components(separatedBy: "?")[0]
        return mediaDir.appendingPathComponent(filename).path
    }
    
    private func fetchAndServe(url: URL, cachePath: String, connection: NWConnection, method: String) {
        let task = connectionPool.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("DEBUG: [LocalHTTPServer] Fetch error: \(error.localizedDescription)")
                self.sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
                return
            }
            
            // CRITICAL: Validate HTTP response status
            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("DEBUG: [LocalHTTPServer] Invalid HTTP response")
                self.sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
                return
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                NSLog("DEBUG: [LocalHTTPServer] Server returned error status: \(httpResponse.statusCode)")
                self.sendResponse(connection: connection, statusCode: httpResponse.statusCode, headers: [:], body: nil)
                return
            }
            
            guard let data = data, !data.isEmpty else {
                NSLog("DEBUG: [LocalHTTPServer] Empty data received")
                self.sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
                return
            }
            
            // Cache the original data (trust HTTP 200 status, ignore incorrect content-type headers)
            try? data.write(to: URL(fileURLWithPath: cachePath))
            NSLog("DEBUG: [LocalHTTPServer] Cached to: \(cachePath) (size: \(data.count) bytes)")
            
            // For playlists, rewrite URLs to point to localhost
            var finalData = data
            if cachePath.hasSuffix(".m3u8"), let playlistString = String(data: data, encoding: .utf8) {
                // CRITICAL: Extract actual mediaID (the Qm... hash folder)
                let pathComponents = cachePath.components(separatedBy: "/")
                let mediaID = pathComponents.first(where: { $0.starts(with: "Qm") }) ?? ""
                
                let modifiedPlaylist = self.rewritePlaylistURLs(playlistString, mediaID: mediaID, baseURL: url)
                if let modifiedData = modifiedPlaylist.data(using: .utf8) {
                    finalData = modifiedData
                    NSLog("DEBUG: [LocalHTTPServer] Rewrote playlist URLs for localhost")
                }
            }
            
            // Serve it
            let mimeType = self.getMimeType(for: cachePath)
            let headers: [String: String] = [
                "Content-Type": mimeType,
                "Content-Length": "\(finalData.count)",
                "Accept-Ranges": "bytes"
            ]
            
            if method == "HEAD" {
                self.sendResponse(connection: connection, statusCode: 200, headers: headers, body: nil)
            } else {
                self.sendResponse(connection: connection, statusCode: 200, headers: headers, body: finalData)
            }
            
            NSLog("DEBUG: [LocalHTTPServer] Served fresh data (size: \(finalData.count) bytes)")
        }
        task.resume()
    }
    
    private func serveFile(path: String, connection: NWConnection, method: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
            return
        }
        
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let mimeType = getMimeType(for: path)
            
            let headers: [String: String] = [
                "Content-Type": mimeType,
                "Content-Length": "\(data.count)",
                "Accept-Ranges": "bytes",
                "Cache-Control": "public, max-age=3600"
            ]
            
            if method == "HEAD" {
                sendResponse(connection: connection, statusCode: 200, headers: headers, body: nil)
            } else {
                sendResponse(connection: connection, statusCode: 200, headers: headers, body: data)
            }
            
            NSLog("DEBUG: [LocalHTTPServer] Served file: \(path) (size: \(data.count) bytes)")
        } catch {
            NSLog("DEBUG: [LocalHTTPServer] Failed to read file: \(error)")
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
        }
    }
    
    private func rewritePlaylistURLs(_ playlistString: String, mediaID: String, baseURL: URL) -> String {
        var modified = playlistString
        
        // Extract the directory path for relative URL resolution
        // For http://server/ipfs/hash/720p/playlist.m3u8 → /ipfs/hash/720p
        let playlistDirectory = baseURL.deletingLastPathComponent().path
        
        NSLog("DEBUG: [LocalHTTPServer] Rewriting playlist URLs, mediaID=\(mediaID), baseURL=\(baseURL.absoluteString)")
        NSLog("DEBUG: [LocalHTTPServer] Playlist directory: \(playlistDirectory)")
        NSLog("DEBUG: [LocalHTTPServer] Original playlist:\n\(playlistString)")
        
        // CRITICAL: Add #EXT-X-PLAYLIST-TYPE:VOD if missing (tells AVPlayer it's VOD, not live)
        if modified.contains("#EXTINF:") && !modified.contains("#EXT-X-PLAYLIST-TYPE") {
            // This is a segment playlist without type - add VOD tag after #EXTM3U
            if let extm3uRange = modified.range(of: "#EXTM3U") {
                let insertIndex = modified.index(extm3uRange.upperBound, offsetBy: 0)
                modified.insert(contentsOf: "\n#EXT-X-PLAYLIST-TYPE:VOD", at: insertIndex)
                NSLog("DEBUG: [LocalHTTPServer] Added #EXT-X-PLAYLIST-TYPE:VOD to playlist")
            }
        }
        
        // Rewrite relative .m3u8 URLs (sub-playlists)
        // Pattern matches lines like "720p/playlist.m3u8"
        let playlistPattern = "^([^#\\n\\r]+\\.m3u8)$"
        if let playlistRegex = try? NSRegularExpression(pattern: playlistPattern, options: [.anchorsMatchLines]) {
            let matches = playlistRegex.matches(in: modified, options: [], range: NSRange(location: 0, length: modified.count))
            NSLog("DEBUG: [LocalHTTPServer] Found \(matches.count) playlist URLs to rewrite")
            for match in matches.reversed() {
                if let range = Range(match.range, in: modified) {
                    let relativeName = String(modified[range])
                    // Construct: http://127.0.0.1:port/mediaID/playlistDirectory/relativeName
                    let localhostURL = "http://127.0.0.1:\(port)/\(mediaID)\(playlistDirectory)/\(relativeName)"
                    modified.replaceSubrange(range, with: localhostURL)
                    NSLog("DEBUG: [LocalHTTPServer] Rewrote: \(relativeName) → \(localhostURL)")
                }
            }
        }
        
        // Rewrite relative .ts URLs (segments)
        let segmentPattern = "^([^#\\n\\r]+\\.ts)$"
        if let segmentRegex = try? NSRegularExpression(pattern: segmentPattern, options: [.anchorsMatchLines]) {
            let matches = segmentRegex.matches(in: modified, options: [], range: NSRange(location: 0, length: modified.count))
            NSLog("DEBUG: [LocalHTTPServer] Found \(matches.count) segment URLs to rewrite")
            for match in matches.reversed() {
                if let range = Range(match.range, in: modified) {
                    let relativeName = String(modified[range])
                    // Construct: http://127.0.0.1:port/mediaID/playlistDirectory/relativeName
                    let localhostURL = "http://127.0.0.1:\(port)/\(mediaID)\(playlistDirectory)/\(relativeName)"
                    NSLog("DEBUG: [LocalHTTPServer] Rewriting segment '\(relativeName)' -> port:\(port), mediaID:'\(mediaID)', dir:'\(playlistDirectory)'")
                    NSLog("DEBUG: [LocalHTTPServer] Final URL: \(localhostURL)")
                    modified.replaceSubrange(range, with: localhostURL)
                }
            }
        }
        
        NSLog("DEBUG: [LocalHTTPServer] Modified playlist:\n\(modified)")
        return modified
    }
    
    private func getMimeType(for path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "m3u8":
            return "application/vnd.apple.mpegurl"
        case "ts":
            return "video/mp2t"
        default:
            return "application/octet-stream"
        }
    }
    
    private func sendResponse(connection: NWConnection, statusCode: Int, headers: [String: String], body: Data?) {
        var response = "HTTP/1.1 \(statusCode) \(getStatusText(statusCode))\r\n"
        
        // Add default headers first
        response += "Connection: keep-alive\r\n"  // CRITICAL for HTTP keep-alive!
        
        // Add custom headers
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        
        response += "\r\n"
        
        let responseData = response.data(using: .utf8) ?? Data()
        var allData = responseData
        
        if let body = body {
            allData.append(body)
        }
        
        connection.send(content: allData, completion: .contentProcessed { error in
            if let error = error {
                NSLog("DEBUG: [LocalHTTPServer] Send error: \(error)")
            }
        })
    }
    
    private func getStatusText(_ statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}
