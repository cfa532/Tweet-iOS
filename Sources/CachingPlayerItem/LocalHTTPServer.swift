import Foundation
import Network
import UIKit

public class LocalHTTPServer: @unchecked Sendable {
    public static let shared = LocalHTTPServer()
    
    private var listener: NWListener?
    public private(set) var port: UInt16 = 8080  // Public read, private write
    private var mediaCache: [String: String] = [:] // mediaID -> cachePath
    private var mediaRealURLs: [String: URL] = [:] // mediaID -> real URL
    private let queue = DispatchQueue(label: "LocalHTTPServer", qos: .userInitiated)
    private var preferenceHelper: PreferenceHelper?
    private var isStarting = false  // Track if server is currently starting
    public private(set) var isRunning = false   // Track if server is running (public read)
    private var isStopping = false  // Track if server is currently stopping
    
    // Connection pool for efficient HTTP requests
    private var _connectionPool: URLSession?
    private let connectionPoolLock = NSLock()
    private var connectionPool: URLSession {
        connectionPoolLock.lock()
        defer { connectionPoolLock.unlock() }
        
        if let pool = _connectionPool {
            return pool
        }
        
        let config = URLSessionConfiguration.default
        
        // Connection pool settings for better performance
        config.httpMaximumConnectionsPerHost = 12  // Increased from 6 for better network utilization
        config.timeoutIntervalForRequest = 30     // 30 seconds per request
        config.timeoutIntervalForResource = 300   // 5 minutes total
        
        // Enable HTTP pipelining for better throughput
        config.httpShouldUsePipelining = true
        
        // Disable URLSession cache (we handle caching ourselves)
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        let pool = URLSession(configuration: config)
        _connectionPool = pool
        NSLog("DEBUG: [LocalHTTPServer] Connection pool initialized with max 12 connections per host")
        return pool
    }
    
    // Screen lock resilience
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var didEnterBackground = false
    
    private init() {
        // Initialize preference helper for port persistence
        self.preferenceHelper = PreferenceHelper()
        // Load saved port from preferences
        if let helper = preferenceHelper {
            let savedPort = helper.getLocalHTTPServerPort()
            self.port = savedPort
            NSLog("DEBUG: [LocalHTTPServer] Loaded saved port from preferences: \(savedPort)")
        }
        
        // Setup app lifecycle listeners for screen lock resilience
        setupLifecycleListeners()
    }
    
    private func setupLifecycleListeners() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    @objc private func handleWillResignActive() {
        NSLog("[LocalHTTPServer] App will resign active - preparing for screen lock/background")
        didEnterBackground = false
        
        // Request background time to keep server alive during screen lock
        if backgroundTaskID == .invalid {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
                // If iOS needs to end our background task, end it gracefully
                self?.endBackgroundTask()
            }
            NSLog("[LocalHTTPServer] Background task started: \(backgroundTaskID.rawValue)")
        }
    }
    
    @objc private func handleDidEnterBackground() {
        NSLog("[LocalHTTPServer] App entering background")
        didEnterBackground = true
        // Keep background task active - we need the server for quick app returns
    }
    
    @objc private func handleDidBecomeActive() {
        let isScreenLock = !didEnterBackground
        NSLog("[LocalHTTPServer] App became active - isScreenLock: \(isScreenLock)")
        
        // End background task - no longer needed
        endBackgroundTask()
        
        // Check server health and restart if needed
        queue.async { [weak self] in
            self?.verifyServerHealth()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            NSLog("[LocalHTTPServer] Ending background task: \(backgroundTaskID.rawValue)")
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
    
    private func verifyServerHealth() {
        guard isRunning else {
            NSLog("[LocalHTTPServer] Server not running, no health check needed")
            return
        }
        
        // Check if listener is still healthy
        guard listener != nil else {
            NSLog("[LocalHTTPServer] ⚠️ Listener is nil but isRunning=true, restarting")
            restart()
            return
        }
        
        // Quick health check - try to create a test connection
        let testURL = URL(string: "http://127.0.0.1:\(port)/health")!
        var request = URLRequest(url: testURL, timeoutInterval: 1.0)
        request.httpMethod = "HEAD"
        
        let semaphore = DispatchSemaphore(value: 0)
        var isHealthy = false
        
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let httpResponse = response as? HTTPURLResponse {
                // Server responded - it's alive
                isHealthy = true
                NSLog("[LocalHTTPServer] ✓ Health check passed (status: \(httpResponse.statusCode))")
            } else if let error = error {
                NSLog("[LocalHTTPServer] ✗ Health check failed: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        task.resume()
        
        // Wait up to 1 second for health check
        let result = semaphore.wait(timeout: .now() + 1.0)
        
        if result == .timedOut || !isHealthy {
            NSLog("[LocalHTTPServer] ⚠️ Server unhealthy after wake, restarting")
            restart()
        } else {
            NSLog("[LocalHTTPServer] ✓ Server healthy and responsive")
        }
    }
    
    private func restart() {
        NSLog("[LocalHTTPServer] Restarting server...")
        
        // Stop current instance
        stop()
        
        // Small delay to ensure clean shutdown
        Thread.sleep(forTimeInterval: 0.1)
        
        // Start fresh
        startServer()
        
        if isRunning {
            NSLog("[LocalHTTPServer] ✓ Server restarted successfully on port \(port)")
        } else {
            NSLog("[LocalHTTPServer] ✗ Server restart failed")
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        endBackgroundTask()
    }
    
    /// Start the server synchronously and WAIT until it's ready
    /// Use this for app launch and background recovery to ensure server is ready before videos load
    public func startAndWait() {
        print("[LocalHTTPServer] startAndWait() called")
        
        // If already running, return immediately
        if isRunning {
            print("[LocalHTTPServer] Already running on port \(port)")
            return
        }
        
        let semaphore = DispatchSemaphore(value: 0)
        var didStart = false
        
        queue.async { [weak self] in
            guard let self = self else {
                semaphore.signal()
                return
            }
            
            // Wait for any stop operation
            while self.isStopping {
                Thread.sleep(forTimeInterval: 0.05)
            }
            
            if self.isRunning {
                didStart = true
                semaphore.signal()
                return
            }
            
            self.startServer()
            didStart = self.isRunning
            semaphore.signal()
        }
        
        // Wait up to 5 seconds for server to start
        let result = semaphore.wait(timeout: .now() + .seconds(5))
        
        if result == .timedOut {
            print("[LocalHTTPServer] ❌ startAndWait() TIMEOUT after 5s!")
        } else if didStart {
            print("[LocalHTTPServer] ✅ startAndWait() SUCCESS - Server ready on port \(port)")
        } else {
            print("[LocalHTTPServer] ❌ startAndWait() FAILED - Server not running")
        }
    }
    
    public func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // If currently stopping, wait for it to finish
            if self.isStopping {
                NSLog("DEBUG: [LocalHTTPServer] Waiting for stop to complete before starting...")
                // Wait on the same queue - stop() will finish and set isStopping=false
                var waitCount = 0
                while self.isStopping && waitCount < 10 {
                    Thread.sleep(forTimeInterval: 0.1)
                    waitCount += 1
                }
                if self.isStopping {
                    NSLog("DEBUG: [LocalHTTPServer] Stop didn't complete in time, forcing start anyway")
                }
            }
            
            // Don't start if already running or starting
            if self.isRunning || self.isStarting {
                NSLog("DEBUG: [LocalHTTPServer] Already running/starting, skipping duplicate start")
                return
            }
            
            self.startServer()
        }
    }
    
    public func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            if self.listener != nil {
                self.isStopping = true
                NSLog("DEBUG: [LocalHTTPServer] Stopping server and releasing port \(self.port)")
                self.listener?.cancel()
                self.listener = nil
                self.isRunning = false
                self.isStarting = false
                
                // Give iOS time to actually release the port (important!)
                Thread.sleep(forTimeInterval: 0.2)
                
                self.isStopping = false
                NSLog("DEBUG: [LocalHTTPServer] Port \(self.port) released (waited for OS cleanup)")
            }
        }
    }
    
    /// Reset the connection pool to recover from background suspension
    /// This should be called when the app returns from a long background period
    public func resetConnectionPool() {
        queue.async { [weak self] in
            guard let self = self else { return }
            NSLog("DEBUG: [LocalHTTPServer] Resetting connection pool for background recovery")
            
            // Thread-safe reset with lock
            self.connectionPoolLock.lock()
            self._connectionPool?.invalidateAndCancel()
            self._connectionPool = nil
            self.connectionPoolLock.unlock()
            
            // Next access will create a new session
            NSLog("DEBUG: [LocalHTTPServer] Connection pool reset complete")
        }
    }
    
    public func registerMedia(mediaID: String, cachePath: String) {
        queue.async { [weak self] in
            self?.mediaCache[mediaID] = cachePath
            // Removed repetitive registration log
        }
    }
    
    public func registerAndGetURL(for mediaID: String, realURL: URL) -> URL {
        // Store the mapping (synchronous to ensure it's available immediately)
        queue.sync {
            mediaRealURLs[mediaID] = realURL
        }
        
        // Return localhost URL: http://localhost:8080/mediaID/path
        // AVPlayer will request this, and we'll serve from cache or fetch from realURL
        let localhostURL = URL(string: "\(Constants.LOCAL_HOST):\(port)/\(mediaID)\(realURL.path)")!
        // Removed repetitive registration log
        return localhostURL
    }
    
    public func getLocalURL(for mediaID: String) -> URL? {
        return URL(string: "http://localhost:\(port)/media/\(mediaID)/")
    }
    
    private func startServer() {
        // Don't start if already listening
        if listener?.state == .ready {
            NSLog("DEBUG: [LocalHTTPServer] Already running on port \(port)")
            isRunning = true
            return
        }
        
        // Extra check: if listener exists but not ready, cancel it first
        if listener != nil {
            NSLog("DEBUG: [LocalHTTPServer] Found stale listener, cleaning up before restart")
            listener?.cancel()
            listener = nil
            isRunning = false
        }
        
        isStarting = true
        defer { isStarting = false }
        
        // Load saved port from preferences as starting point
        let savedPort: UInt16
        if let helper = preferenceHelper {
            savedPort = helper.getLocalHTTPServerPort()
            NSLog("DEBUG: [LocalHTTPServer] Will try saved port first: \(savedPort)")
        } else {
            savedPort = 8080
            NSLog("DEBUG: [LocalHTTPServer] Will try default port first: 8080")
        }
        
        // FAST PATH: Try saved port first (most common case - should succeed immediately)
        if tryBindToPort(savedPort) {
            return
        }
        
        NSLog("DEBUG: [LocalHTTPServer] Saved port \(savedPort) unavailable, searching for alternative...")
        
        // SLOW PATH: Saved port in use, search for available port
        let maxAttempts = 20
        
        for attempt in 0..<maxAttempts {
            // Sequential search starting from saved port
            let tryPort = savedPort + UInt16(attempt) + 1
            
            // Skip invalid ports
            guard tryPort <= 65535 else {
                NSLog("DEBUG: [LocalHTTPServer] Port \(tryPort) exceeds valid range, stopping search")
                break
            }
            
            if tryBindToPort(tryPort) {
                return
            }
        }
        
        NSLog("DEBUG: [LocalHTTPServer] ❌ Failed to find available port after \(maxAttempts) attempts starting from port \(savedPort)")
    }
    
    /// Try to bind to a specific port - returns true if successful
    private func tryBindToPort(_ tryPort: UInt16) -> Bool {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: tryPort))
            
            // Use a semaphore to wait for binding result
            let semaphore = DispatchSemaphore(value: 0)
            var bindingSucceeded = false
            
            // CRITICAL: Use a separate queue for this listener to avoid deadlock
            let listenerQueue = DispatchQueue(label: "LocalHTTPServer.listener.\(tryPort)", qos: .userInitiated)
            
            // CRITICAL: Update port BEFORE starting listener so URLs use correct port
            self.port = tryPort
            
            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .setup:
                    break // Silent
                case .ready:
                    self.isRunning = true
                    bindingSucceeded = true
                    semaphore.signal()
                    NSLog("DEBUG: [LocalHTTPServer] ✅ Successfully bound to port \(tryPort)")
                    // Save successful port to preferences
                    self.preferenceHelper?.setLocalHTTPServerPort(tryPort)
                case .failed(let error):
                    self.isRunning = false
                    bindingSucceeded = false
                    semaphore.signal()
                    
                    // Only log if it's not a simple "port in use" error
                    let errorDesc = error.localizedDescription.lowercased()
                    if !errorDesc.contains("address already in use") && !errorDesc.contains("address in use") && !errorDesc.contains("eaddrinuse") {
                        NSLog("DEBUG: [LocalHTTPServer] Port \(tryPort) failed: \(error)")
                    }
                case .waiting(let error):
                    NSLog("DEBUG: [LocalHTTPServer] Port \(tryPort) waiting: \(error)")
                case .cancelled:
                    break // Silent
                @unknown default:
                    break
                }
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            // Start on separate queue to avoid deadlock
            listener.start(queue: listenerQueue)
            
            // Wait up to 200ms for binding to succeed or fail (faster than before)
            let result = semaphore.wait(timeout: .now() + .milliseconds(200))
            
            if result == .timedOut {
                listener.cancel()
                return false
            }
            
            if bindingSucceeded {
                // Store the listener
                self.listener = listener
                NSLog("DEBUG: [LocalHTTPServer] Server started successfully on port \(tryPort)")
                return true
            } else {
                // Binding failed
                listener.cancel()
                return false
            }
            
        } catch {
            return false
        }
    }
    
    // REMOVED: isPortAvailable() function - no longer needed
    // We now test ports by attempting to bind directly, which avoids the port release timing issue
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveNextRequest(connection: connection)
    }
    
    private func receiveNextRequest(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                // Only log non-connection-reset errors
                if (error as NSError).code != 54 {  // 54 = Connection reset by peer
                    NSLog("ERROR: [LocalHTTPServer] Receive error: \(error)")
                }
            }
            
            if let data = data, !data.isEmpty {
                let request = String(data: data, encoding: .utf8) ?? ""
                
                // Handle the request
                self.handleRequest(request, connection: connection) {
                    // After handling, continue listening for more requests
                    if !isComplete && error == nil {
                        self.receiveNextRequest(connection: connection)
                    } else {
                        connection.cancel()
                    }
                }
            } else if isComplete || error != nil {
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
            handleGetRequest(path: path, method: method, requestLines: lines, connection: connection, completion: completion)
        } else {
            sendResponse(connection: connection, statusCode: 405, headers: [:], body: nil)
            completion()
        }
    }
    
    private func handleGetRequest(path: String, method: String, requestLines: [String], connection: NWConnection, completion: @escaping () -> Void) {
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
        
        // Removed repetitive request log
        
        // Check if mediaID is blacklisted before attempting fetch
        if BlackList.shared.isBlacklisted(mediaID) {
            NSLog("DEBUG: [LocalHTTPServer] MediaID \(mediaID) is blacklisted, returning 404")
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
            completion()
            return
        }
        
        // CRITICAL: Check cache FIRST before requiring real URL
        // This allows cached content to be served during app startup before baseUrl is resolved
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let mediaDir = cacheDir.appendingPathComponent(mediaID)
        let potentialCachePath = mediaDir.appendingPathComponent(relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath)
        
        if FileManager.default.fileExists(atPath: potentialCachePath.path) {
            NSLog("DEBUG: [LocalHTTPServer] Serving cached file: \(relativePath) for mediaID: \(mediaID)")
            // CACHE HIT - serve immediately without needing real URL
            NSLog("DEBUG: [LocalHTTPServer] Found cached file at: \(potentialCachePath.path)")
            
            if relativePath.hasSuffix(".m3u8") {
                // For playlists, rewrite URLs to localhost
                if let data = try? Data(contentsOf: potentialCachePath),
                   let playlistString = String(data: data, encoding: .utf8) {
                    NSLog("DEBUG: [LocalHTTPServer] Read cached playlist, size: \(data.count) bytes")
                    // Reconstruct a baseURL from the relative path for proper URL rewriting
                    // Example: /master.m3u8 -> http://placeholder/ipfs/mediaID/master.m3u8
                    let reconstructedBaseURL = URL(string: "http://placeholder/ipfs/\(mediaID)\(relativePath)")!
                    let modifiedPlaylist = rewritePlaylistURLs(playlistString, mediaID: mediaID, baseURL: reconstructedBaseURL)
                    if let modifiedData = modifiedPlaylist.data(using: .utf8) {
                        let headers: [String: String] = [
                            "Content-Type": "application/vnd.apple.mpegurl",
                            "Content-Length": "\(modifiedData.count)",
                            "Accept-Ranges": "bytes"
                        ]
                        sendResponse(connection: connection, statusCode: 200, headers: headers, body: modifiedData)
                        NSLog("DEBUG: [LocalHTTPServer] Served cached playlist (no realURL needed)")
                        completion()
                        return
                    } else {
                        NSLog("DEBUG: [LocalHTTPServer] Failed to convert modified playlist to data")
                    }
                } else {
                    NSLog("DEBUG: [LocalHTTPServer] Failed to read or decode cached playlist")
                }
            }
            
            // For segments and other files, serve directly
            NSLog("DEBUG: [LocalHTTPServer] Serving cached file directly: \(relativePath)")
            serveFile(path: potentialCachePath.path, connection: connection, method: method)
            completion()
            return
        }
        
        // CACHE MISS - need real URL to fetch from network
        guard let realURL = mediaRealURLs[mediaID] else {
            NSLog("DEBUG: [LocalHTTPServer] No real URL found for mediaID: \(mediaID), and no cache available")
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
            completion()
            return
        }
        
        // Construct full real URL for this specific file
        guard var components = URLComponents(url: realURL, resolvingAgainstBaseURL: false) else {
            NSLog("DEBUG: [LocalHTTPServer] Failed to parse URL components")
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
            completion()
            return
        }
        
        // Replace path with requested file
        components.path = relativePath
        
        // Remove query params
        components.query = nil
        
        guard let fullRealURL = components.url else {
            NSLog("DEBUG: [LocalHTTPServer] Failed to construct URL")
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
            completion()
            return
        }
        
        // Check if this is a playlist (.m3u8), segment (.ts), or progressive video
        if relativePath.hasSuffix(".m3u8") {
            handlePlaylistRequest(fullRealURL: fullRealURL, mediaID: mediaID, connection: connection, method: method)
            completion()
        } else if relativePath.hasSuffix(".ts") {
            handleSegmentRequest(fullRealURL: fullRealURL, mediaID: mediaID, connection: connection, method: method)
            completion()
        } else {
            // Progressive video - proxy with Content-Type fix
            handleProgressiveVideoRequest(fullRealURL: fullRealURL, mediaID: mediaID, connection: connection, method: method, requestHeaders: requestLines)
            completion()
        }
    }
    
    private func handlePlaylistRequest(fullRealURL: URL, mediaID: String, connection: NWConnection, method: String) {
        let cachePath = getCachePath(for: fullRealURL, mediaID: mediaID)
        
        // Check cache first
        if FileManager.default.fileExists(atPath: cachePath) {
            // Removed repetitive cache hit log
            
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
        // Removed repetitive fetch log
        fetchAndServe(url: fullRealURL, cachePath: cachePath, connection: connection, method: method)
    }
    
    private func handleSegmentRequest(fullRealURL: URL, mediaID: String, connection: NWConnection, method: String) {
        let cachePath = getCachePath(for: fullRealURL, mediaID: mediaID)
        
        // Check cache first
        if FileManager.default.fileExists(atPath: cachePath) {
            // Removed repetitive cache hit log
            serveFile(path: cachePath, connection: connection, method: method)
            return
        }
        
        // Not cached - fetch from real server
        // Removed repetitive fetch log
        fetchAndServe(url: fullRealURL, cachePath: cachePath, connection: connection, method: method)
    }
    
    private func handleProgressiveVideoRequest(fullRealURL: URL, mediaID: String, connection: NWConnection, method: String, requestHeaders: [String]) {
        // Parse Range header from client request
        var rangeHeader: String? = nil
        for line in requestHeaders {
            if line.lowercased().hasPrefix("range:") {
                rangeHeader = String(line.dropFirst(6).trimmingCharacters(in: .whitespaces))
                break
            }
        }
        
        // Parse byte range for caching (e.g., "bytes=0-65535")
        var rangeStart: Int64? = nil
        var rangeEnd: Int64? = nil
        if let range = rangeHeader, range.lowercased().hasPrefix("bytes=") {
            let bytesRange = range.dropFirst(6)  // Remove "bytes="
            let parts = bytesRange.split(separator: "-")
            if parts.count >= 1, let start = Int64(parts[0]) {
                rangeStart = start
            }
            if parts.count >= 2, !parts[1].isEmpty, let end = Int64(parts[1]) {
                rangeEnd = end
            }
        }
        
        // Calculate request size for caching decision
        let requestSize = rangeEnd != nil ? (rangeEnd! - (rangeStart ?? 0) + 1) : Int64.max
        let isProbeRequest = requestSize < 1024  // Requests < 1KB are just probes
        
        // Check cache for this specific range (skip probes)
        // CRITICAL: If no range header, try to serve full file from cache (range 0-end)
        let effectiveStart = rangeStart ?? 0
        let effectiveEnd = rangeEnd
        
        if !isProbeRequest, let cachedData = readCachedProgressiveRange(mediaID: mediaID, start: effectiveStart, end: effectiveEnd) {
            // Validate cached data size
            if cachedData.count >= 1024 {
                // CACHE HIT - serve from cache instantly
                let rangeStr = rangeHeader != nil ? "\(effectiveStart)-\(effectiveEnd?.description ?? "end")" : "full-file"
                NSLog("🎯 [PROGRESSIVE CACHE HIT] mediaID: \(mediaID), range: \(rangeStr), size: \(cachedData.count) bytes")
                
                var headers: [String: String] = [
                    "Content-Type": "video/mp4",
                    "Content-Length": "\(cachedData.count)",
                    "Accept-Ranges": "bytes"
                ]
                
                if rangeHeader != nil, let end = effectiveEnd {
                    headers["Content-Range"] = "bytes \(effectiveStart)-\(end)/*"
                }
                
                let statusCode = rangeHeader != nil ? 206 : 200
                sendResponse(connection: connection, statusCode: statusCode, headers: headers, body: cachedData)
                return
            } else {
                // Delete corrupted cache
                NSLog("⚠️ [PROGRESSIVE CACHE] Deleting corrupted cache: \(cachedData.count) bytes for mediaID: \(mediaID)")
                deleteCachedProgressiveRange(mediaID: mediaID, start: effectiveStart, end: effectiveEnd)
            }
        } else if !isProbeRequest {
            let rangeStr = rangeHeader != nil ? "\(effectiveStart)-\(effectiveEnd?.description ?? "end")" : "full-file"
            NSLog("❌ [PROGRESSIVE CACHE MISS] mediaID: \(mediaID), range: \(rangeStr) - will fetch from network")
        }
        
        // CACHE MISS - fetch from real server
        // CRITICAL: Block NEW network requests until app initialized (but cached content is OK)
        guard HproseInstance.shared.isAppInitialized else {
            NSLog("⚠️ [LocalHTTPServer] App not initialized, refusing NETWORK request for \(mediaID). Cache miss - video won't load until app initializes.")
            self.sendResponse(connection: connection, statusCode: 503, headers: [:], body: nil)
            return
        }
        
        var request = URLRequest(url: fullRealURL)
        request.httpMethod = method
        request.timeoutInterval = 30
        
        if let range = rangeHeader {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        
        // Fetch from real server
        let task = connectionPool.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("DEBUG: [LocalHTTPServer] Progressive fetch error: \(error.localizedDescription)")
                
                // Record failure for this mediaID (attachment mid)
                if !mediaID.isEmpty {
                    BlackList.shared.recordFailure(mediaID)
                    NSLog("DEBUG: [LocalHTTPServer] Recorded progressive fetch failure for mediaID: \(mediaID)")
                }
                
                self.sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                // Record failure for error status
                if !mediaID.isEmpty {
                    BlackList.shared.recordFailure(mediaID)
                }
                
                self.sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
                return
            }
            
            guard let data = data else {
                // Record failure for empty data
                if !mediaID.isEmpty {
                    BlackList.shared.recordFailure(mediaID)
                }
                
                self.sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
                return
            }
            
            // Cache this byte range for future requests (skip tiny probe requests)
            if !isProbeRequest, let start = rangeStart, data.count >= 1024 {
                let rangeStr = rangeEnd != nil ? "\(start)-\(rangeEnd!)" : "\(start)-end"
                NSLog("💾 [PROGRESSIVE CACHE WRITE] mediaID: \(mediaID), range: \(rangeStr), size: \(data.count) bytes")
                self.cacheProgressiveRange(mediaID: mediaID, start: start, end: rangeEnd, data: data)
            }
            
            // Record successful fetch for this mediaID
            if !mediaID.isEmpty {
                BlackList.shared.recordSuccess(mediaID)
            }
            
            // Build response headers with FIXED Content-Type
            var headers: [String: String] = [
                "Content-Type": "video/mp4",  // Fix from application/octet-stream
                "Content-Length": "\(data.count)",
                "Accept-Ranges": "bytes"
            ]
            
            // Preserve Content-Range if present
            if let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range") {
                headers["Content-Range"] = contentRange
            }
            
            // Send response
            self.sendResponse(connection: connection, statusCode: httpResponse.statusCode, headers: headers, body: data)
        }
        
        task.resume()
    }
    
    // MARK: - Progressive Video Byte-Range Cache Helpers
    
    private func readCachedProgressiveRange(mediaID: String, start: Int64, end: Int64?) -> Data? {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let mediaDir = cacheDir.appendingPathComponent(mediaID).appendingPathComponent("ranges")
        
        // First try exact match (fast path)
        let rangeFileName = "r_\(start)_\(end?.description ?? "end")"
        let exactCachePath = mediaDir.appendingPathComponent(rangeFileName)
        
        if FileManager.default.fileExists(atPath: exactCachePath.path) {
            return try? Data(contentsOf: exactCachePath)
        }
        
        // No exact match - look for overlapping ranges that contain this request
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: mediaDir.path) else {
            return nil
        }
        
        let requestEnd = end ?? Int64.max
        
        // Parse cached range files and find one that fully contains the requested range
        for file in files where file.hasPrefix("r_") {
            let components = file.dropFirst(2).split(separator: "_")
            guard components.count == 2,
                  let cachedStart = Int64(components[0]) else {
                continue
            }
            
            let cachedEnd: Int64
            if components[1] == "end" {
                cachedEnd = Int64.max
            } else if let parsed = Int64(components[1]) {
                cachedEnd = parsed
            } else {
                continue
            }
            
            // Check if cached range fully contains requested range
            // CRITICAL: When end is nil (full file request), accept any cache starting at requested position
            let containsRequest = cachedStart <= start && (end == nil ? true : cachedEnd >= requestEnd)
            
            if containsRequest {
                let cachePath = mediaDir.appendingPathComponent(file)
                guard let fullData = try? Data(contentsOf: cachePath) else {
                    continue
                }
                
                // Calculate offset into cached file
                let offset = Int(start - cachedStart)
                let length = end != nil ? Int(requestEnd - start + 1) : fullData.count - offset
                
                // Validate bounds
                guard offset >= 0, offset < fullData.count, offset + length <= fullData.count else {
                    continue
                }
                
                // Extract the requested subrange from cached data
                let subrange = fullData.subdata(in: offset..<(offset + length))
                
                NSLog("🎯 [PROGRESSIVE CACHE] Found overlapping range - cached: \(cachedStart)-\(cachedEnd == Int64.max ? "end" : String(cachedEnd)), requested: \(start)-\(end?.description ?? "end"), offset: \(offset), length: \(length)")
                
                return subrange
            }
        }
        
        return nil
    }
    
    private func cacheProgressiveRange(mediaID: String, start: Int64, end: Int64?, data: Data) {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let mediaDir = cacheDir.appendingPathComponent(mediaID).appendingPathComponent("ranges")
        
        // Create ranges directory if needed
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        
        let rangeFileName = "r_\(start)_\(end?.description ?? "end")"
        let cachePath = mediaDir.appendingPathComponent(rangeFileName)
        
        do {
            try data.write(to: cachePath)
            NSLog("✅ [PROGRESSIVE CACHE SAVED] mediaID: \(mediaID), file: \(rangeFileName), path: \(cachePath.path)")
        } catch {
            NSLog("❌ [PROGRESSIVE CACHE ERROR] Failed to save mediaID: \(mediaID), error: \(error)")
        }
    }
    
    private func deleteCachedProgressiveRange(mediaID: String, start: Int64, end: Int64?) {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let mediaDir = cacheDir.appendingPathComponent(mediaID).appendingPathComponent("ranges")
        let rangeFileName = "r_\(start)_\(end?.description ?? "end")"
        let cachePath = mediaDir.appendingPathComponent(rangeFileName)
        
        try? FileManager.default.removeItem(at: cachePath)
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
        // CRITICAL: Block NEW network requests until app initialized
        guard HproseInstance.shared.isAppInitialized else {
            NSLog("⚠️ [LocalHTTPServer] App not initialized, refusing network fetch for \(url.path)")
            self.sendResponse(connection: connection, statusCode: 503, headers: [:], body: nil)
            return
        }
        
        let task = connectionPool.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            // Extract mediaID from cachePath for BlackList tracking
            let pathComponents = cachePath.components(separatedBy: "/")
            let mediaID = pathComponents.first(where: { $0.starts(with: "Qm") }) ?? ""
            
            if let error = error {
                NSLog("DEBUG: [LocalHTTPServer] Fetch error: \(error.localizedDescription)")
                
                // Record failure for this mediaID (attachment mid)
                if !mediaID.isEmpty {
                    BlackList.shared.recordFailure(mediaID)
                    NSLog("DEBUG: [LocalHTTPServer] Recorded fetch failure for mediaID: \(mediaID)")
                }
                
                self.sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
                return
            }
            
            // CRITICAL: Validate HTTP response status
            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("DEBUG: [LocalHTTPServer] Invalid HTTP response")
                
                // Record failure for invalid response
                if !mediaID.isEmpty {
                    BlackList.shared.recordFailure(mediaID)
                }
                
                self.sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
                return
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                NSLog("DEBUG: [LocalHTTPServer] Server returned error status: \(httpResponse.statusCode)")
                
                // Record failure for error status
                if !mediaID.isEmpty {
                    BlackList.shared.recordFailure(mediaID)
                }
                
                self.sendResponse(connection: connection, statusCode: httpResponse.statusCode, headers: [:], body: nil)
                return
            }
            
            guard let data = data, !data.isEmpty else {
                NSLog("DEBUG: [LocalHTTPServer] Empty data received")
                
                // Record failure for empty data
                if !mediaID.isEmpty {
                    BlackList.shared.recordFailure(mediaID)
                }
                
                self.sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
                return
            }
            
            // For playlists, strip to relative paths for caching (port-independent!)
            var dataToCache = data
            var finalData = data
            if cachePath.hasSuffix(".m3u8"), let playlistString = String(data: data, encoding: .utf8) {
                // Strip URLs to relative paths for caching (remove scheme/host/port)
                let relativePlaylist = self.stripPlaylistToRelativePaths(playlistString, baseURL: url)
                if let relativeData = relativePlaylist.data(using: .utf8) {
                    dataToCache = relativeData
                    NSLog("DEBUG: [LocalHTTPServer] Stripped playlist to relative paths for caching")
                }
                
                // Rewrite with current port for serving
                let modifiedPlaylist = self.rewritePlaylistURLs(relativePlaylist, mediaID: mediaID, baseURL: url)
                if let modifiedData = modifiedPlaylist.data(using: .utf8) {
                    finalData = modifiedData
                    NSLog("DEBUG: [LocalHTTPServer] Rewrote playlist URLs for localhost")
                }
            }
            
            // Cache the relative-path version (port-independent!)
            try? dataToCache.write(to: URL(fileURLWithPath: cachePath))
            NSLog("DEBUG: [LocalHTTPServer] Cached to: \(cachePath) (size: \(dataToCache.count) bytes)")
            
            // Record successful fetch for this mediaID
            if !mediaID.isEmpty {
                BlackList.shared.recordSuccess(mediaID)
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
            // Removed: Served fresh data log (too frequent)
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
            // Removed: Served file log (too frequent)
        } catch {
            NSLog("ERROR: [LocalHTTPServer] Failed to read file: \(error)")
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
        }
    }
    
    /// Strip playlist URLs to relative paths only (remove scheme/host/port) for port-independent caching
    private func stripPlaylistToRelativePaths(_ playlistString: String, baseURL: URL) -> String {
        var modified = playlistString
        
        // Pattern to match full URLs: http://anything or https://anything
        let urlPattern = "(https?://[^\\s]+\\.(m3u8|ts))"
        guard let urlRegex = try? NSRegularExpression(pattern: urlPattern, options: []) else {
            return playlistString
        }
        
        let matches = urlRegex.matches(in: modified, options: [], range: NSRange(location: 0, length: modified.count))
        
        // Replace matches in reverse order to maintain string indices
        for match in matches.reversed() {
            if let range = Range(match.range, in: modified) {
                let fullURL = String(modified[range])
                
                // Extract FULL path (keep everything after scheme://host:port)
                if let url = URL(string: fullURL) {
                    // Just use the path component (removes scheme, host, port)
                    // e.g., "http://server:8081/ipfs/QmHash/720p/playlist.m3u8" -> "/ipfs/QmHash/720p/playlist.m3u8"
                    let relativePath = url.path
                    modified.replaceSubrange(range, with: relativePath)
                }
            }
        }
        
        return modified
    }
    
    private func rewritePlaylistURLs(_ playlistString: String, mediaID: String, baseURL: URL) -> String {
        var modified = playlistString
        
        // Extract the directory path for relative URL resolution
        // For http://server/ipfs/hash/720p/playlist.m3u8 → /ipfs/hash/720p
        let playlistDirectory = baseURL.deletingLastPathComponent().path
        
        // CRITICAL: Add #EXT-X-PLAYLIST-TYPE:VOD if missing (tells AVPlayer it's VOD, not live)
        if modified.contains("#EXTINF:") && !modified.contains("#EXT-X-PLAYLIST-TYPE") {
            // This is a segment playlist without type - add VOD tag after #EXTM3U
            if let extm3uRange = modified.range(of: "#EXTM3U") {
                let insertIndex = modified.index(extm3uRange.upperBound, offsetBy: 0)
                modified.insert(contentsOf: "\n#EXT-X-PLAYLIST-TYPE:VOD", at: insertIndex)
            }
        }
        
        // Rewrite .m3u8 URLs (sub-playlists) - handles both relative and absolute paths
        // Pattern matches lines like "720p/playlist.m3u8" or "/ipfs/QmHash/720p/playlist.m3u8"
        let playlistPattern = "^([^#\\n\\r]+\\.m3u8)$"
        if let playlistRegex = try? NSRegularExpression(pattern: playlistPattern, options: [.anchorsMatchLines]) {
            let matches = playlistRegex.matches(in: modified, options: [], range: NSRange(location: 0, length: modified.count))
            for match in matches.reversed() {
                if let range = Range(match.range, in: modified) {
                    let pathString = String(modified[range])
                    let localhostURL: String
                    if pathString.hasPrefix("/") {
                        // Absolute path: /ipfs/QmHash/720p/playlist.m3u8 -> http://127.0.0.1:port/mediaID/ipfs/QmHash/720p/playlist.m3u8
                        localhostURL = "\(Constants.LOCAL_HOST):\(port)/\(mediaID)\(pathString)"
                    } else {
                        // Relative path: 720p/playlist.m3u8 -> http://127.0.0.1:port/mediaID/playlistDirectory/720p/playlist.m3u8
                        localhostURL = "\(Constants.LOCAL_HOST):\(port)/\(mediaID)\(playlistDirectory)/\(pathString)"
                    }
                    modified.replaceSubrange(range, with: localhostURL)
                }
            }
        }
        
        // Rewrite .ts URLs (segments) - handles both relative and absolute paths
        let segmentPattern = "^([^#\\n\\r]+\\.ts)$"
        if let segmentRegex = try? NSRegularExpression(pattern: segmentPattern, options: [.anchorsMatchLines]) {
            let matches = segmentRegex.matches(in: modified, options: [], range: NSRange(location: 0, length: modified.count))
            for match in matches.reversed() {
                if let range = Range(match.range, in: modified) {
                    let pathString = String(modified[range])
                    let localhostURL: String
                    if pathString.hasPrefix("/") {
                        // Absolute path: /ipfs/QmHash/segment000.ts -> http://127.0.0.1:port/mediaID/ipfs/QmHash/segment000.ts
                        localhostURL = "\(Constants.LOCAL_HOST):\(port)/\(mediaID)\(pathString)"
                    } else {
                        // Relative path: segment000.ts -> http://127.0.0.1:port/mediaID/playlistDirectory/segment000.ts
                        localhostURL = "\(Constants.LOCAL_HOST):\(port)/\(mediaID)\(playlistDirectory)/\(pathString)"
                    }
                    modified.replaceSubrange(range, with: localhostURL)
                }
            }
        }
        
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
