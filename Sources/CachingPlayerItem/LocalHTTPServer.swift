import Foundation
import Network
import UIKit

// MARK: - Streaming Download Delegate
private class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate {
    private let connection: NWConnection
    private let mediaID: String
    private let cacheStart: Int64
    private let totalExpectedSize: Int64?
    private let isProbeRequest: Bool
    private let cacheFileHandle: FileHandle?
    private let cacheFilePath: String?
    private let initialCachedSize: Int64
    private let contiguousSizeUpdate: (Int64) -> Void
    
    private var sentBytesCount: Int64 = 0
    private var cachedBytesCount: Int64
    private let maxCacheSize: Int64 = 50 * 1024 * 1024  // 50MB safety cap
    private let writeLock = NSLock()
    private var lastPersistedContiguousSize: Int64
    private let persistInterval: Int64 = 512 * 1024
    
    init(
        connection: NWConnection,
        mediaID: String,
        cacheStart: Int64,
        totalExpectedSize: Int64?,
        isProbeRequest: Bool,
        cacheFileHandle: FileHandle?,
        cacheFilePath: String?,
        initialCachedSize: Int64,
        contiguousSizeUpdate: @escaping (Int64) -> Void
    ) {
        self.connection = connection
        self.mediaID = mediaID
        self.cacheStart = cacheStart
        self.totalExpectedSize = totalExpectedSize
        self.isProbeRequest = isProbeRequest
        self.cacheFileHandle = cacheFileHandle
        self.cacheFilePath = cacheFilePath
        self.initialCachedSize = initialCachedSize
        self.cachedBytesCount = initialCachedSize
        self.contiguousSizeUpdate = contiguousSizeUpdate
        self.lastPersistedContiguousSize = initialCachedSize
        
        if !isProbeRequest && cacheStart > initialCachedSize {
            // Non-contiguous request - streaming only, no caching
        }
    }
    
    // Receive data in chunks
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        autoreleasepool {
            let chunkLength = Int64(data.count)
            guard chunkLength > 0 else { return }
            
            let writeOffset = cacheStart + sentBytesCount
            
            // Stream chunk to AVPlayer immediately
            connection.send(content: data, completion: .contentProcessed { _ in })
            sentBytesCount += chunkLength
            
            // Write chunk to disk cache (if not probe request)
            guard !isProbeRequest,
                  let fileHandle = cacheFileHandle,
                  cachedBytesCount < maxCacheSize else {
                return
            }
            
            // Only write sequential data to avoid sparse files
            guard writeOffset <= cachedBytesCount else {
                return
            }
            
            var sizeToPersist: Int64?
            
            writeLock.lock()
            defer {
                writeLock.unlock()
                if let size = sizeToPersist {
                    contiguousSizeUpdate(size)
                }
            }
            
            let remainingAllowance = maxCacheSize - cachedBytesCount
            guard remainingAllowance > 0 else { return }
            
            var bytesToWrite = min(chunkLength, remainingAllowance)
            var chunkToWrite = data.prefix(Int(bytesToWrite))
            var targetOffset = writeOffset
            
            if targetOffset < cachedBytesCount {
                let alreadyCached = cachedBytesCount - targetOffset
                if alreadyCached >= bytesToWrite {
                    return
                }
                bytesToWrite -= alreadyCached
                
                let trimmedData = data.dropFirst(Int(alreadyCached))
                chunkToWrite = trimmedData.prefix(Int(bytesToWrite))
                targetOffset = cachedBytesCount
            }
            
            do {
                if #available(iOS 13.0, *) {
                    try fileHandle.seek(toOffset: UInt64(targetOffset))
                    try fileHandle.write(contentsOf: chunkToWrite)
                } else {
                    fileHandle.seek(toFileOffset: UInt64(targetOffset))
                    fileHandle.write(chunkToWrite)
                }
                
                let newEnd = targetOffset + bytesToWrite
                if newEnd > cachedBytesCount {
                    cachedBytesCount = newEnd
                }
                
                let delta = cachedBytesCount - lastPersistedContiguousSize
                if delta >= persistInterval || cachedBytesCount == maxCacheSize {
                    lastPersistedContiguousSize = cachedBytesCount
                    sizeToPersist = cachedBytesCount
                }
            } catch {
                print("❌ [PROGRESSIVE CACHE WRITE] Failed to write chunk for \(mediaID): \(error.localizedDescription)")
            }
            
            if cachedBytesCount >= maxCacheSize {
                print("⚠️ [PROGRESSIVE CACHE LIMIT] Reached 50MB cache limit for \(mediaID) - further data won't be cached")
            }
        }
    }
    
    // Handle completion
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var finalSizeToPersist: Int64?
        
        defer {
            // Close file handle
            writeLock.lock()
            let finalSize = cachedBytesCount
            if finalSize > lastPersistedContiguousSize {
                lastPersistedContiguousSize = finalSize
                finalSizeToPersist = finalSize
            }
            if #available(iOS 13.0, *) {
                try? cacheFileHandle?.synchronize()
            } else {
                cacheFileHandle?.synchronizeFile()
            }
            try? cacheFileHandle?.close()
            writeLock.unlock()
            
            if let size = finalSizeToPersist {
                contiguousSizeUpdate(size)
            }
        }
        
        if let error = error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                // Don't count cancellations (e.g. from emergency cleanup or scroll-away) as real failures
                print("⚠️ [PROGRESSIVE STREAM] Cancelled for \(mediaID) - not recording as failure")
            } else {
                print("❌ [PROGRESSIVE STREAM] Failed for \(mediaID): \(error.localizedDescription)")
                BlackList.shared.recordFailure(mediaID)
            }
        } else {
            // Stream completed successfully
        }
    }
}

// MARK: - Active Downloads Actor (Swift 6 Concurrency-Safe)
private actor ActiveDownloadsActor {
    private var activeDownloads: [String: Task<Void, Never>] = [:]
    
    func getTask(for key: String) -> Task<Void, Never>? {
        return activeDownloads[key]
    }
    
    func setTask(_ task: Task<Void, Never>, for key: String) {
        activeDownloads[key] = task
    }
    
    func removeTask(for key: String) {
        activeDownloads.removeValue(forKey: key)
    }

    func cancelAllTasks() {
        for (_, task) in activeDownloads {
            task.cancel()
        }
        activeDownloads.removeAll()
    }
}

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
    
    // Computed property for current port (returns nil if not running)
    public var currentPort: UInt16? {
        return isRunning ? port : nil
    }
    
    // DEDUPLICATION: Track active downloads to prevent duplicates
    private let activeDownloadsActor = ActiveDownloadsActor()
    
    // Streaming download sessions
    private var streamingSessions: [String: URLSession] = [:]
    private let streamingSessionsLock = NSLock()
    
    private let progressiveStreamChunkSize = 256 * 1024  // 256KB chunks
    private let progressiveDiskCacheLimit: Int64 = 50 * 1024 * 1024
    
    // Connection pool for efficient HTTP requests
    private var _connectionPool: URLSession?
    private let connectionPoolLock = NSLock()

    // Network failure tracking for emergency cleanup
    private var consecutiveNetworkFailures: Int = 0
    private let maxConsecutiveFailures = 3 // Trigger cleanup after 3 consecutive failures
    private var connectionPool: URLSession {
        connectionPoolLock.lock()
        defer { connectionPoolLock.unlock() }
        
        if let pool = _connectionPool {
            return pool
        }
        
        let config = URLSessionConfiguration.default
        
        // Connection pool settings for high load scenarios
        config.httpMaximumConnectionsPerHost = 20  // Increased for better concurrent request handling
        config.timeoutIntervalForRequest = 90     // 90 seconds per request (slow network!)
        config.timeoutIntervalForResource = 300   // 5 minutes total
        
        // Enable HTTP pipelining for better throughput
        config.httpShouldUsePipelining = true
        
        // Disable URLSession cache (we handle caching ourselves)
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        let pool = URLSession(configuration: config)
        _connectionPool = pool
        return pool
    }
    
    private func canBypassInitialization(for mediaID: String? = nil, url: URL? = nil) -> Bool {
        if HproseInstance.shared.isAppInitialized {
            return true
        }
        
        if let url = url, let host = url.host, !host.isEmpty, host != "127.0.0.1" {
            return true
        }
        
        if let mediaID = mediaID,
           let registeredURL = mediaRealURLs[mediaID],
           let host = registeredURL.host,
           !host.isEmpty,
           host != "127.0.0.1" {
            return true
        }
        
        if let baseHost = HproseInstance.shared.appUser.baseUrl?.host,
           !baseHost.isEmpty {
            return true
        }
        
        return false
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
        didEnterBackground = false
        
        // Request background time to keep server alive during screen lock
        if backgroundTaskID == .invalid {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
                // If iOS needs to end our background task, end it gracefully
                self?.endBackgroundTask()
            }
        }
    }
    
    @objc private func handleDidEnterBackground() {
        didEnterBackground = true
        // Keep background task active - we need the server for quick app returns
    }
    
    @objc private func handleDidBecomeActive() {
        let _ = !didEnterBackground  // Track if this was screen lock vs background
        
        // End background task - no longer needed
        endBackgroundTask()
        
        // Check server health and restart if needed
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.verifyServerHealth()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
    
    private func verifyServerHealth() {
        let serverState = queue.sync { () -> (Bool, NWListener.State?, UInt16) in
            return (isRunning, listener?.state, port)
        }
        
        let (running, listenerState, _) = serverState
        
        guard running else {
            return
        }
        
        guard let state = listenerState else {
            print("[LocalHTTPServer] ⚠️ Listener is nil but isRunning=true, restarting")
            queue.async { [weak self] in
                Task {
                    await self?.restart()
                }
            }
            return
        }
        
        switch state {
        case .ready:
            return
        case .waiting(let error):
            print("[LocalHTTPServer] ⚠️ Listener waiting with error '\(error.localizedDescription)' – restarting")
        case .failed(let error):
            print("[LocalHTTPServer] ⚠️ Listener failed with error '\(error.localizedDescription)' – restarting")
        case .cancelled:
            print("[LocalHTTPServer] ⚠️ Listener was cancelled – restarting")
        default:
            print("[LocalHTTPServer] ⚠️ Listener state \(state) – restarting for safety")
        }

        queue.async { [weak self] in
            Task {
                await self?.restart()
            }
        }
    }
    
    private func restart() async {

        // Stop current instance
        stop()

        // Small delay to ensure clean shutdown
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // Start fresh
        await startServer()

        if isRunning {
        } else {
            print("[LocalHTTPServer] ✗ Server restart failed")
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        endBackgroundTask()
    }
    
    /// Start the server synchronously and WAIT until it's ready
    /// ⚠️ DEPRECATED: Use startAndWaitAsync() instead to avoid blocking main thread
    /// This method is kept for backwards compatibility but should not be used
    public func startAndWait() {
        print("[LocalHTTPServer] ⚠️ startAndWait() DEPRECATED - use startAndWaitAsync() instead!")
        
        // If already running, return immediately
        if isRunning {
            print("[LocalHTTPServer] Already running on port \(port)")
            return
        }
        
        // DON'T block with semaphore - just start async
        queue.async { [weak self] in
            Task {
                guard let self = self else { return }

                if !self.isRunning {
                    await self.startServer()
                }
            }
        }
        
        // Give it a moment to start (don't block with semaphore!)
        // NOTE: This is still using Thread.sleep because this is a deprecated sync method
        // Users should migrate to startAndWaitAsync() instead
        Thread.sleep(forTimeInterval: 0.1)
        
        if isRunning {
            print("[LocalHTTPServer] ✅ Server started")
        } else {
            print("[LocalHTTPServer] ⚠️ Server starting in background...")
        }
    }
    
    /// Start the server asynchronously and WAIT until it's ready (non-blocking)
    /// Use this instead of startAndWait() to avoid blocking the main thread
    public func startAndWaitAsync() async {
        print("[LocalHTTPServer] startAndWaitAsync() called")
        
        // If already running, return immediately
        if isRunning {
            print("[LocalHTTPServer] Already running on port \(port)")
            return
        }
        
        // Use async/await instead of semaphores (doesn't block thread!)
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                Task {
                    guard let self = self else {
                        continuation.resume()
                        return
                    }

                    // Wait for any stop operation
                    var stopWaitCount = 0
                    while self.isStopping && stopWaitCount < 20 { // Max 1 second
                        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
                        stopWaitCount += 1
                    }

                    if self.isRunning {
                        continuation.resume()
                        return
                    }

                    await self.startServer()
                    continuation.resume()
                }
            }
        }
        
        if isRunning {
            print("[LocalHTTPServer] ✅ startAndWaitAsync() SUCCESS - Server ready on port \(port)")
        } else {
            print("[LocalHTTPServer] ❌ startAndWaitAsync() FAILED - Server not running")
        }
    }
    
    public func start() {
        // If already running, return immediately
        if isRunning {
            return
        }

        // Use a dispatch group to wait for server startup
        let group = DispatchGroup()
        group.enter()

        queue.async { [weak self] in
            guard let self = self else {
                group.leave()
                return
            }

            Task {
                // If currently stopping, wait for it to finish
                if self.isStopping {
                    var waitCount = 0
                    while self.isStopping && waitCount < 10 {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                        waitCount += 1
                    }
                }

                // Don't start if already running or starting
                if self.isRunning || self.isStarting {
                    group.leave()
                    return
                }

                await self.startServer()
                group.leave()
            }
        }

        // Wait for server to start (with timeout)
        let result = group.wait(timeout: .now() + 2.0) // 2 second timeout
        if result == .timedOut {
            print("⚠️ [LocalHTTPServer] start() timed out waiting for server to start")
        }
    }
    
    public func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            if self.listener != nil {
                self.isStopping = true
                self.listener?.cancel()
                self.listener = nil
                self.isRunning = false
                self.isStarting = false
                
                // OPTIMIZATION: Reduced wait time for faster recovery
                // Port release is usually fast - 0.1s is typically enough
                Task {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    self.isStopping = false
                }
            }
        }
    }
    
    /// Reset the connection pool to recover from background suspension
    /// This should be called when the app returns from a long background period
    public func resetConnectionPool() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Thread-safe reset with lock
            self.connectionPoolLock.lock()
            self._connectionPool?.invalidateAndCancel()
            self._connectionPool = nil
            self.connectionPoolLock.unlock()
            
            // Next access will create a new session
        }
    }

    /// Emergency cleanup during network failures
    public func handleNetworkFailureCleanup() {
        queue.async { [weak self] in
            guard let self = self else { return }

            print("DEBUG: [LocalHTTPServer] Network failure detected, performing emergency cleanup")

            // Cancel all active download tasks
            Task {
                await self.activeDownloadsActor.cancelAllTasks()
            }

            // Reset streaming sessions
            self.streamingSessionsLock.lock()
            for (_, session) in self.streamingSessions {
                session.invalidateAndCancel()
            }
            self.streamingSessions.removeAll()
            self.streamingSessionsLock.unlock()

            // Reset connection pool
            self.connectionPoolLock.lock()
            self._connectionPool?.invalidateAndCancel()
            self._connectionPool = nil
            self.connectionPoolLock.unlock()

            print("DEBUG: [LocalHTTPServer] Emergency cleanup completed")
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

        // Return localhost URL: http://localhost:8080/ipfs/mediaID (clean format without redundancy)
        // AVPlayer will request this, and we'll serve from cache or fetch from realURL
        let localhostURL = URL(string: "\(Constants.LOCAL_HOST):\(port)\(realURL.path)")!
        return localhostURL
    }
    
    public func getLocalURL(for mediaID: String) -> URL? {
        return URL(string: "http://localhost:\(port)/media/\(mediaID)/")
    }
    
    private func startServer() async {
        // Don't start if already listening
        if listener?.state == .ready {
            isRunning = true
            return
        }

        // Extra check: if listener exists but not ready, cancel it first
        if listener != nil {
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
        } else {
            savedPort = 8080
        }

        // FAST PATH: Try saved port first (most common case - should succeed immediately)
        if await tryBindToPort(savedPort) {
            return
        }


        // SLOW PATH: Saved port in use, search for available port
        let maxAttempts = 20

        for attempt in 0..<maxAttempts {
            // Sequential search starting from saved port
            let tryPort = savedPort + UInt16(attempt) + 1

            // Skip invalid ports
            guard tryPort <= 65535 else {
                break
            }

            if await tryBindToPort(tryPort) {
                return
            }
        }

    }
    
    /// Try to bind to a specific port - returns true if successful (async version)
    private func tryBindToPort(_ tryPort: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            // Use a flag to ensure continuation is only resumed once
            var hasResumed = false
            let resumeOnce: (Bool) -> Void = { result in
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: result)
            }

            do {
                let listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: tryPort))

                // CRITICAL: Use a separate queue for this listener to avoid deadlock
                let listenerQueue = DispatchQueue(label: "LocalHTTPServer.listener.\(tryPort)", qos: .userInitiated)

                // CRITICAL: Update port BEFORE starting listener so URLs use correct port
                self.port = tryPort

                // Create a sendable wrapper for the timeout task
                final class TimeoutTaskBox: @unchecked Sendable {
                    private let lock = NSLock()
                    private var task: Task<Void, Never>?

                    func set(_ task: Task<Void, Never>) {
                        lock.lock()
                        defer { lock.unlock() }
                        self.task = task
                    }

                    func cancel() {
                        lock.lock()
                        defer { lock.unlock() }
                        task?.cancel()
                        task = nil
                    }
                }

                let timeoutTaskBox = TimeoutTaskBox()

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self = self else {
                        timeoutTaskBox.cancel()
                        resumeOnce(false)
                        return
                    }

                    switch state {
                    case .ready:
                        timeoutTaskBox.cancel()
                        self.isRunning = true
                        // Save successful port to preferences
                        self.preferenceHelper?.setLocalHTTPServerPort(tryPort)
                        // Store the listener
                        self.listener = listener
                        resumeOnce(true)
                    case .failed, .cancelled:
                        timeoutTaskBox.cancel()
                        self.isRunning = false
                        listener.cancel()
                        resumeOnce(false)
                    case .waiting, .setup:
                        break
                    @unknown default:
                        timeoutTaskBox.cancel()
                        self.isRunning = false
                        listener.cancel()
                        resumeOnce(false)
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    self?.handleConnection(connection)
                }

                // Start on separate queue to avoid deadlock
                listener.start(queue: listenerQueue)

                // Set timeout using Task
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: 200_000_000) // 200ms timeout
                        // If we get here, timeout occurred - cancel listener
                        listener.cancel()
                        resumeOnce(false)
                    } catch {
                        // Task was cancelled, ignore
                    }
                }
                timeoutTaskBox.set(timeoutTask)

            } catch {
                resumeOnce(false)
            }
        }
    }
    
    // REMOVED: isPortAvailable() function - no longer needed
    // We now test ports by attempting to bind directly, which avoids the port release timing issue
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task {
            await receiveNextRequest(connection: connection)
        }
    }
    
    private func receiveNextRequest(connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self = self else {
                    continuation.resume()
                    return
                }

                if let error = error {
                    let nwCode = (error as NSError).code
                    // Only count non-benign errors toward emergency cleanup.
                    // Code 54 (connection reset) and 89 (cancelled) are normal
                    // when AVPlayer closes/reopens local connections.
                    let isBenign = (nwCode == 54 || nwCode == 89 || nwCode == NSURLErrorCancelled)
                    if !isBenign {
                        consecutiveNetworkFailures += 1
                        print("DEBUG: [LocalHTTPServer] Network failure count: \(consecutiveNetworkFailures)/\(maxConsecutiveFailures)")

                        if consecutiveNetworkFailures >= maxConsecutiveFailures {
                            print("DEBUG: [LocalHTTPServer] Too many consecutive network failures, triggering cleanup")
                            handleNetworkFailureCleanup()
                            consecutiveNetworkFailures = 0
                        }
                    }

                    // Only log non-connection-reset errors
                    if nwCode != 54 {
                        print("DEBUG: [LocalHTTPServer] Receive error (code \(nwCode)): \(error)")
                    }
                } else {
                    // Reset network failure counter on successful receive
                    consecutiveNetworkFailures = 0
                }

                if let data = data, !data.isEmpty {
                    let request = String(data: data, encoding: .utf8) ?? ""

                    // Handle the request
                    Task {
                        await self.handleRequest(request, connection: connection) {
                            // After handling, continue listening for more requests
                            if !isComplete && error == nil {
                                Task {
                                    await self.receiveNextRequest(connection: connection)
                                }
                            } else {
                                connection.cancel()
                            }
                        }
                        continuation.resume()
                    }
                } else if isComplete || error != nil {
                    connection.cancel()
                    continuation.resume()
                } else {
                    // No data yet, keep waiting
                    Task {
                        await self.receiveNextRequest(connection: connection)
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    private func handleRequest(_ request: String, connection: NWConnection, completion: @escaping () -> Void) async {
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
            await handleGetRequest(path: path, method: method, requestLines: lines, connection: connection, completion: completion)
        } else {
            sendResponse(connection: connection, statusCode: 405, headers: [:], body: nil)
            completion()
        }
    }
    
    private func handleGetRequest(path: String, method: String, requestLines: [String], connection: NWConnection, completion: @escaping () -> Void) async {
        // Health check endpoint
        if path == "/health" {
            let headers = [
                "Content-Length": "0",
                "Content-Type": "text/plain"
            ]
            sendResponse(connection: connection, statusCode: 200, headers: headers, body: nil)
            completion()
            return
        }
        
        // FORMAT: /ipfs/hash or /ipfs/hash/path (e.g., /ipfs/QmAbc... or /ipfs/QmAbc.../master.m3u8)
        // Extract mediaID from /ipfs/ path
        let pathComponents = path.components(separatedBy: "/").filter { !$0.isEmpty }
        guard pathComponents.count >= 2, pathComponents[0] == "ipfs" else {
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
            completion()
            return
        }
        
        let mediaID = pathComponents[1]
        
        // Reconstruct relative path for real URL requests
        let relativePath = path
        
        // Removed repetitive request log
        
        // Check if mediaID is blacklisted before attempting fetch
        if BlackList.shared.isBlacklisted(mediaID) {
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
            completion()
            return
        }
        
        // CRITICAL: Check cache FIRST before requiring real URL
        // This allows cached content to be served during app startup before baseUrl is resolved
        // Only check cache if there's a specific file requested (not just /ipfs/mediaID for progressive video)
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let mediaDir = cacheDir.appendingPathComponent(mediaID)
        
        // Skip cache check for progressive video requests (just /ipfs/mediaID with no filename)
        // These are handled by progressive video proxy logic below
        guard pathComponents.count > 2 else {
            // No filename specified - this is a progressive video request, skip cache
            // (Progressive videos use range requests and aren't fully cached as single files)
            // Continue to real URL handling below
            guard let realURL = mediaRealURLs[mediaID] else {
                sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
                completion()
                return
            }
            
            // Construct full real URL
            guard var components = URLComponents(url: realURL, resolvingAgainstBaseURL: false) else {
                sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
                completion()
                return
            }
            
            components.path = relativePath
            components.query = nil
            
            guard let fullRealURL = components.url else {
                sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
                completion()
                return
            }
            
            // Progressive video - proxy with Content-Type fix
            handleProgressiveVideoRequest(fullRealURL: fullRealURL, mediaID: mediaID, connection: connection, method: method, requestHeaders: requestLines)
            completion()
            return
        }
        
        // Extract file path after /ipfs/mediaID/ for cache lookup (HLS playlists/segments)
        let filePathComponents = pathComponents[2...].joined(separator: "/")
        let potentialCachePath = mediaDir.appendingPathComponent(filePathComponents)
        
        if FileManager.default.fileExists(atPath: potentialCachePath.path) {
            // CACHE HIT - serve immediately without needing real URL
            
            if relativePath.hasSuffix(".m3u8") {
                // For playlists, rewrite URLs to localhost
                if let data = try? Data(contentsOf: potentialCachePath),
                   let playlistString = String(data: data, encoding: .utf8) {
                    // Reconstruct a baseURL from the relative path for proper URL rewriting
                    // relativePath already includes /ipfs/mediaID/, so just use it directly
                    let reconstructedBaseURL = URL(string: "http://placeholder\(relativePath)")!
                    let modifiedPlaylist = rewritePlaylistURLs(playlistString, mediaID: mediaID, baseURL: reconstructedBaseURL)
                    if let modifiedData = modifiedPlaylist.data(using: .utf8) {
                        let headers: [String: String] = [
                            "Content-Type": "application/vnd.apple.mpegurl",
                            "Content-Length": "\(modifiedData.count)",
                            "Accept-Ranges": "bytes"
                        ]
                        sendResponse(connection: connection, statusCode: 200, headers: headers, body: modifiedData)
                        completion()
                        return
                    } else {
                    }
                } else {
                }
            }
            
            // For segments and other files, serve directly
            serveFile(path: potentialCachePath.path, connection: connection, method: method)
            completion()
            return
        }
        
        // CACHE MISS - need real URL to fetch from network
        guard let realURL = mediaRealURLs[mediaID] else {
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
            completion()
            return
        }
        
        // Construct full real URL for this specific file
        guard var components = URLComponents(url: realURL, resolvingAgainstBaseURL: false) else {
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
            completion()
            return
        }
        
        // Replace path with requested file
        components.path = relativePath
        
        // Remove query params
        components.query = nil
        
        guard let fullRealURL = components.url else {
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
            completion()
            return
        }
        
        // Check if this is a playlist (.m3u8), segment (.ts), or progressive video
        if relativePath.hasSuffix(".m3u8") {
            handlePlaylistRequest(fullRealURL: fullRealURL, mediaID: mediaID, connection: connection, method: method)
            completion()
        } else if relativePath.hasSuffix(".ts") {
            await handleSegmentRequest(fullRealURL: fullRealURL, mediaID: mediaID, connection: connection, method: method)
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
                    return
                }
            }
            
            // Fallback to original file if rewrite fails
            serveFile(path: cachePath, connection: connection, method: method)
            return
        }
        
        // Not cached - fetch from real server (no deduplication for non-.ts files)
        // Removed repetitive fetch log
        fetchAndServe(url: fullRealURL, cachePath: cachePath, connection: connection, method: method, completion: nil)
    }
    
    private func handleSegmentRequest(fullRealURL: URL, mediaID: String, connection: NWConnection, method: String) async {
        let cachePath = getCachePath(for: fullRealURL, mediaID: mediaID)
        
        // Check cache first
        if FileManager.default.fileExists(atPath: cachePath) {
            // Serve cached segment - this reads from disk, no memory bloat
            autoreleasepool {
                serveFile(path: cachePath, connection: connection, method: method)
            }
            return
        }
        
        // DEDUPLICATION FIX: Check if this segment is already being downloaded
        let downloadKey = cachePath

        // Extract quality level for logging (dynamic - no hardcoding!)
        let pathComponents = cachePath.components(separatedBy: "/")
        // Look for any component that ends with 'p' (e.g., "480p", "720p", "1080p", "4k", etc.)
        let _ = pathComponents.first(where: { component in
            // Matches patterns like "480p", "720p", "1080p", etc.
            component.hasSuffix("p") && component.dropLast().allSatisfy({ $0.isNumber })
        }) ?? "unknown"

        // Use actor for thread-safe access
        let existingTask = await activeDownloadsActor.getTask(for: downloadKey)
        
        if existingTask == nil {
            // This is the first request for this segment - create a task placeholder
            await activeDownloadsActor.setTask(Task {}, for: downloadKey)
        }

        // Wait for existing task if there is one
        if let existingTask = existingTask {
            // Another request is already downloading this segment
            // Wait for it to complete, then serve the cached file
            await existingTask.value

            // Now check if the file exists and serve it
            if FileManager.default.fileExists(atPath: cachePath) {
                autoreleasepool {
                    serveFile(path: cachePath, connection: connection, method: method)
                }
            } else {
                // File still doesn't exist - something went wrong with the download
                // Start our own download as fallback
                fetchAndServe(url: fullRealURL, cachePath: cachePath, connection: connection, method: method, completion: nil)
            }
            return
        }

        // This request is the downloader - fetch from server and cache
        let downloadStartTime = Date()

        // Create the actual download task
        let downloadTask = Task {
            // Wait for fetchAndServe to complete
            await withCheckedContinuation { continuation in
                fetchAndServe(url: fullRealURL, cachePath: cachePath, connection: connection, method: method) {
                    continuation.resume()
                }
            }

            let _ = Date().timeIntervalSince(downloadStartTime)

            if FileManager.default.fileExists(atPath: cachePath) {
                let _ = (try? FileManager.default.attributesOfItem(atPath: cachePath)[.size] as? Int) ?? 0
            } else {
                print("⚠️ [DEDUP] Download completed but file not found - something went wrong: \(fullRealURL.lastPathComponent)")
            }

            // Remove the completed task from active downloads
            await self.activeDownloadsActor.removeTask(for: downloadKey)
        }

        // Store the actual download task
        await activeDownloadsActor.setTask(downloadTask, for: downloadKey)
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
        
        // Check cache for this specific range - ALWAYS check, even for probes
        // CRITICAL: If no range header, try to serve full file from cache (range 0-end)
        // For cache operations, use ORIGINAL rangeEnd (not capped) - we can serve from cache without memory issues
        let effectiveStart = rangeStart ?? 0
        let effectiveEnd = rangeEnd
        
        if serveProgressiveCacheIfAvailable(
            mediaID: mediaID,
            start: effectiveStart,
            end: effectiveEnd,
            rangeHeader: rangeHeader,
            method: method,
            connection: connection
        ) {
            return
        }
        
        let rangeStr = rangeHeader != nil ? "\(effectiveStart)-\(effectiveEnd?.description ?? "end")" : "full-file"
        print("❌ [PROGRESSIVE CACHE MISS] mediaID: \(mediaID), range: \(rangeStr), isProbe: \(isProbeRequest) - will fetch from network")
        
        // CACHE MISS - fetch from real server
        // CRITICAL: Block NEW network requests until app initialized (but cached content is OK)
        guard canBypassInitialization(for: mediaID, url: fullRealURL) else {
            print("⚠️ [LocalHTTPServer] App not initialized, refusing NETWORK request for \(mediaID). Cache miss - video won't load until app initializes.")
            self.sendResponse(connection: connection, statusCode: 503, headers: [:], body: nil)
            return
        }
        
        // STREAMING: First get file size with HEAD, then stream data in chunks
        let requestedStart = rangeStart ?? 0
        
        var headRequest = URLRequest(url: fullRealURL)
        headRequest.httpMethod = "HEAD"
        headRequest.timeoutInterval = 10
        
        
        let headTask = connectionPool.dataTask(with: headRequest) { [weak self] _, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ [PROGRESSIVE HEAD] Failed for \(mediaID): \(error.localizedDescription)")
                if (error as NSError).code != NSURLErrorCancelled {
                    BlackList.shared.recordFailure(mediaID)
                }
                self.sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("❌ [PROGRESSIVE HEAD] Bad status for \(mediaID)")
                BlackList.shared.recordFailure(mediaID)
                self.sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
                return
            }
            
            // Get total file size
            var totalFileSize: Int64?
            if let contentLength = httpResponse.allHeaderFields["Content-Length"] as? String, let size = Int64(contentLength) {
                totalFileSize = size
                self.storeProgressiveTotalSize(mediaID: mediaID, totalSize: size)
            } else {
                print("⚠️ [PROGRESSIVE HEAD] \(mediaID): totalSize unknown")
            }
            
            // Calculate response size based on what AVPlayer actually requested
            let requestedSize: Int64
            if let end = rangeEnd {
                requestedSize = end - requestedStart + 1
            } else if let total = totalFileSize {
                requestedSize = total - requestedStart
            } else {
                requestedSize = 0
            }
            
            // Build response headers - match exactly what AVPlayer requested
            var responseHeaders: [String: String] = [
                "Content-Type": "video/mp4",
                "Content-Length": "\(requestedSize)",
                "Accept-Ranges": "bytes"
            ]
            
            if rangeHeader != nil, let totalSize = totalFileSize {
                let actualEnd = rangeEnd ?? (totalSize - 1)
                responseHeaders["Content-Range"] = "bytes \(requestedStart)-\(actualEnd)/\(totalSize)"
            }
            
            let statusCode = rangeHeader != nil ? 206 : 200
            
            // Send HTTP headers first
            var headerData = Data()
            headerData.append("HTTP/1.1 \(statusCode) \(statusCode == 200 ? "OK" : "Partial Content")\r\n".data(using: .utf8)!)
            for (key, value) in responseHeaders {
                headerData.append("\(key): \(value)\r\n".data(using: .utf8)!)
            }
            headerData.append("\r\n".data(using: .utf8)!)
            
            let resolvedRequestedEnd: Int64? = {
                if let end = rangeEnd {
                    return end
                } else if let total = totalFileSize {
                    return total - 1
                }
                return nil
            }()
            
            let cacheFileURL = self.progressiveCacheFileURL(for: mediaID)
            let contiguousSize = self.cachedContiguousSize(for: mediaID, cacheFileURL: cacheFileURL)
            let cachedOverlapStart = max(requestedStart, Int64(0))
            var cachedSegmentLength: Int64 = 0
            if FileManager.default.fileExists(atPath: cacheFileURL.path), contiguousSize > cachedOverlapStart {
                let overlapEnd = min(contiguousSize - 1, resolvedRequestedEnd ?? (contiguousSize - 1))
                if overlapEnd >= cachedOverlapStart {
                    let potentialLength = overlapEnd - cachedOverlapStart + 1
                    cachedSegmentLength = requestedSize > 0 ? min(potentialLength, requestedSize) : potentialLength
                }
            }
            
            connection.send(content: headerData, completion: .contentProcessed { [weak self] headerError in
                guard let self = self else { return }
                if let headerError = headerError {
                    print("⚠️ [PROGRESSIVE HEADERS] Failed to send headers for \(mediaID): \(headerError.localizedDescription)")
                    return
                }
                
                
                guard method.uppercased() == "GET" else { return }
                
                let startNetworkStreaming: () -> Void = {
                    let remainderNeeded = requestedSize <= 0 || cachedSegmentLength < requestedSize
                    guard remainderNeeded else { return }
                    
                    let streamStart = requestedStart + cachedSegmentLength
                    if let resolvedEnd = resolvedRequestedEnd, streamStart > resolvedEnd {
                        return
                    }
                    
                    var streamRequest = URLRequest(url: fullRealURL)
                    streamRequest.httpMethod = method
                    streamRequest.timeoutInterval = 90
                    
                    var forwardedRange: String?
                    if let resolvedEnd = resolvedRequestedEnd {
                        forwardedRange = "bytes=\(streamStart)-\(resolvedEnd)"
                    } else if streamStart > requestedStart || rangeHeader != nil {
                        forwardedRange = "bytes=\(streamStart)-"
                    }
                    
                    if let rangeValue = forwardedRange {
                        streamRequest.setValue(rangeValue, forHTTPHeaderField: "Range")
                    } else if let originalRange = rangeHeader {
                        streamRequest.setValue(originalRange, forHTTPHeaderField: "Range")
                    }
                    
                    var cacheFileHandle: FileHandle?
                    var cacheFilePath: String?
                    var initialCachedSize = min(contiguousSize, self.progressiveDiskCacheLimit)
                    
                    if !isProbeRequest {
                        let cacheDir = self.progressiveCacheDirectory(for: mediaID)
                        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                        
                        cacheFilePath = cacheFileURL.path
                        let fileManager = FileManager.default
                        if !fileManager.fileExists(atPath: cacheFilePath!) {
                            fileManager.createFile(atPath: cacheFilePath!, contents: nil)
                        }
                        
                        if initialCachedSize == 0,
                           let attributes = try? fileManager.attributesOfItem(atPath: cacheFilePath!),
                           let sizeNumber = attributes[.size] as? NSNumber {
                            initialCachedSize = min(sizeNumber.int64Value, self.progressiveDiskCacheLimit)
                            if initialCachedSize > 0 {
                                self.storeProgressiveContiguousSize(mediaID: mediaID, contiguousSize: initialCachedSize)
                            }
                        }
                        
                        if initialCachedSize >= self.progressiveDiskCacheLimit {
                            print("⚠️ [PROGRESSIVE CACHE LIMIT] Disk cache already at 50MB for \(mediaID) - skipping additional caching")
                            cacheFileHandle = nil
                            cacheFilePath = nil
                        } else {
                            #if swift(>=5.3)
                            if #available(iOS 13.0, macOS 10.15, *) {
                                do {
                                    cacheFileHandle = try FileHandle(forUpdating: cacheFileURL)
                                } catch {
                                    print("⚠️ [PROGRESSIVE CACHE] Failed to open cache file for updating (\(mediaID)): \(error.localizedDescription)")
                                    cacheFileHandle = try? FileHandle(forWritingTo: cacheFileURL)
                                }
                            } else {
                                cacheFileHandle = FileHandle(forUpdatingAtPath: cacheFilePath!)
                            }
                            #else
                            cacheFileHandle = FileHandle(forUpdatingAtPath: cacheFilePath!)
                            #endif
                            
                            if cacheFileHandle == nil {
                                cacheFileHandle = FileHandle(forWritingAtPath: cacheFilePath!)
                            }
                            
                            if let fileHandle = cacheFileHandle {
                                do {
                                    try fileHandle.seek(toOffset: UInt64(streamStart))
                                } catch {
                                    print("⚠️ [PROGRESSIVE CACHE] Failed to seek cache file for \(mediaID) to \(streamStart): \(error.localizedDescription)")
                                }
                            } else {
                                print("⚠️ [PROGRESSIVE CACHE] Could not obtain writable handle for \(mediaID) - caching disabled for this request")
                            }
                        }
                    }
                    
                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = 90
                    config.timeoutIntervalForResource = 300
                    
                    let contiguousUpdate: (Int64) -> Void = { [weak self] newSize in
                        guard let self = self else { return }
                        self.queue.async {
                            self.storeProgressiveContiguousSize(mediaID: mediaID, contiguousSize: newSize)
                        }
                    }
                    
                    let delegate = StreamingDownloadDelegate(
                        connection: connection,
                        mediaID: mediaID,
                        cacheStart: streamStart,
                        totalExpectedSize: totalFileSize,
                        isProbeRequest: isProbeRequest,
                        cacheFileHandle: cacheFileHandle,
                        cacheFilePath: cacheFilePath,
                        initialCachedSize: initialCachedSize,
                        contiguousSizeUpdate: contiguousUpdate
                    )
                    
                    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                    
                    self.streamingSessionsLock.lock()
                    self.streamingSessions[mediaID + "_\(streamStart)"] = session
                    self.streamingSessionsLock.unlock()
                    
                    let streamTask = session.dataTask(with: streamRequest)
                    streamTask.resume()
                    
                    _ = resolvedRequestedEnd.map { "\($0)" } ?? "end"
                }
                
                if cachedSegmentLength > 0 {
                    let _ = cachedOverlapStart + cachedSegmentLength - 1
                    self.streamFileRange(
                        connection: connection,
                        fileURL: cacheFileURL,
                        offset: cachedOverlapStart,
                        length: cachedSegmentLength,
                        completion: startNetworkStreaming
                    )
                } else {
                    startNetworkStreaming()
                }
            })
        }
        
        headTask.resume()
    }
    
    // MARK: - Progressive Video Cache Helpers
    
    private func progressiveCacheDirectory(for mediaID: String) -> URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cacheDir.appendingPathComponent(mediaID)
    }
    
    private func progressiveCacheFileURL(for mediaID: String) -> URL {
        progressiveCacheDirectory(for: mediaID).appendingPathComponent("video.mp4")
    }
    
    private func progressiveMetaFileURL(for mediaID: String) -> URL {
        progressiveCacheDirectory(for: mediaID).appendingPathComponent("video.meta")
    }
    
    private func progressiveContiguousFileURL(for mediaID: String) -> URL {
        progressiveCacheDirectory(for: mediaID).appendingPathComponent("video.contiguous")
    }
    
    private func storeProgressiveContiguousSize(mediaID: String, contiguousSize: Int64) {
        let url = progressiveContiguousFileURL(for: mediaID)
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = "\(contiguousSize)".data(using: .utf8)
            try data?.write(to: url, options: .atomic)
        } catch {
            print("⚠️ [PROGRESSIVE META] Failed to store contiguous size for \(mediaID): \(error.localizedDescription)")
        }
    }
    
    private func loadProgressiveContiguousSize(mediaID: String) -> Int64? {
        let url = progressiveContiguousFileURL(for: mediaID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            guard let string = String(data: data, encoding: .utf8),
                  let value = Int64(string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            return value
        } catch {
            print("⚠️ [PROGRESSIVE META] Failed to load contiguous size for \(mediaID): \(error.localizedDescription)")
            return nil
        }
    }
    
    private func cachedContiguousSize(for mediaID: String, cacheFileURL: URL) -> Int64 {
        if let stored = loadProgressiveContiguousSize(mediaID: mediaID), stored > 0 {
            return min(stored, progressiveDiskCacheLimit)
        }
        
        guard let inferred = inferContiguousSizeIfAvailable(mediaID: mediaID, cacheFileURL: cacheFileURL) else {
            return 0
        }
        
        if inferred > 0 {
            storeProgressiveContiguousSize(mediaID: mediaID, contiguousSize: inferred)
        }
        return min(inferred, progressiveDiskCacheLimit)
    }
    
    private func inferContiguousSizeIfAvailable(mediaID: String, cacheFileURL: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else {
            return nil
        }
        
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: cacheFileURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let cappedSize = min(fileSize, progressiveDiskCacheLimit)
            guard cappedSize > 0 else { return nil }
            
            guard let handle = try? FileHandle(forReadingFrom: cacheFileURL) else {
                return nil
            }
            defer { try? handle.close() }
            
            let chunkSize = 256 * 1024
            var contiguous: Int64 = 0
            while contiguous < cappedSize {
                let remaining = cappedSize - contiguous
                let readLength = Int(min(Int64(chunkSize), remaining))
                if readLength <= 0 { break }
                
                let chunk: Data
                do {
                    chunk = try handle.read(upToCount: readLength) ?? Data()
                } catch {
                    print("⚠️ [PROGRESSIVE CACHE] Failed to read cache chunk for \(mediaID): \(error.localizedDescription)")
                    break
                }
                
                if chunk.isEmpty {
                    break
                }
                
                if chunk.allSatisfy({ $0 == 0 }) {
                    break
                }
                
                contiguous += Int64(chunk.count)
                
                if chunk.count < readLength {
                    break
                }
            }
            
            if contiguous > 0 {
            }
            return contiguous
        } catch {
            print("⚠️ [PROGRESSIVE CACHE] Failed to infer contiguous size for \(mediaID): \(error.localizedDescription)")
            return nil
        }
    }
    
    private func storeProgressiveTotalSize(mediaID: String, totalSize: Int64) {
        let metaURL = progressiveMetaFileURL(for: mediaID)
        let directory = metaURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = "\(totalSize)".data(using: .utf8)
        do {
            try data?.write(to: metaURL, options: .atomic)
        } catch {
            print("⚠️ [PROGRESSIVE META] Failed to store total size for \(mediaID): \(error.localizedDescription)")
        }
    }
    
    private func loadProgressiveTotalSize(mediaID: String) -> Int64? {
        let metaURL = progressiveMetaFileURL(for: mediaID)
        
        // Only load from meta file - don't guess from video.mp4 size
        // because partial downloads would give wrong total size
        if FileManager.default.fileExists(atPath: metaURL.path),
           let data = try? Data(contentsOf: metaURL),
           let string = String(data: data, encoding: .utf8),
           let value = Int64(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return value
        }
        
        // No meta file = we don't know the real total size
        // Return nil so caller can handle appropriately (e.g., fetch from network)
        return nil
    }
    
    private func serveProgressiveCacheIfAvailable(
        mediaID: String,
        start: Int64,
        end: Int64?,
        rangeHeader: String?,
        method: String,
        connection: NWConnection
    ) -> Bool {
        let cacheFileURL = progressiveCacheFileURL(for: mediaID)
        if FileManager.default.fileExists(atPath: cacheFileURL.path) {
            let totalSize = loadProgressiveTotalSize(mediaID: mediaID)
            let contiguousSize = cachedContiguousSize(for: mediaID, cacheFileURL: cacheFileURL)
            let cachedSize: Int64
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: cacheFileURL.path)
                let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                let cappedFileSize = min(fileSize, progressiveDiskCacheLimit)
                cachedSize = contiguousSize > 0 ? min(contiguousSize, cappedFileSize) : cappedFileSize
            } catch {
                print("⚠️ [PROGRESSIVE CACHE] Failed to read cached file attributes for \(mediaID): \(error.localizedDescription)")
                return false
            }
            
            let shouldValidate: Bool = {
                guard let totalSize = totalSize else { return false }
                let tolerance: Int64 = 512 * 1024 // 512KB tolerance
                return cachedSize + tolerance >= totalSize
            }()
            
            if shouldValidate {
                let hasRealDataAtStart: Bool = {
                    do {
                        let fileHandle = try FileHandle(forReadingFrom: cacheFileURL)
                        defer { try? fileHandle.close() }
                        let prefix = try fileHandle.read(upToCount: 8192) ?? Data()
                        return prefix.contains { $0 != 0 }
                    } catch {
                        print("⚠️ [PROGRESSIVE CACHE] Failed to inspect cache prefix for \(mediaID): \(error.localizedDescription)")
                        return false
                    }
                }()
                
                if !hasRealDataAtStart {
                } else if !isValidProgressiveCache(fileURL: cacheFileURL) {
                    print("⚠️ [PROGRESSIVE CACHE] Invalid/corrupted COMPLETE cache for \(mediaID), deleting entire cache directory")
                    // Delete the entire cache directory (including legacy per-range files)
                    let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    let mediaCacheDir = cacheDir.appendingPathComponent(mediaID)
                    try? FileManager.default.removeItem(at: mediaCacheDir)
                    // Fall through to network fetch
                    return false
                }
            } else if totalSize != nil {
            }
            
            guard start < cachedSize else {
                return false
            }
            
            let availableLength = cachedSize - start
            
            let requestedLength: Int64
            if let end = end {
                // Explicit range request - honor it fully if available
                let rangeLength = end - start + 1
                requestedLength = min(availableLength, rangeLength)
            } else {
                // Open-ended request - return all available cached data
                requestedLength = availableLength
            }
            
            guard requestedLength > 0 else {
                return false
            }
            
            let actualEnd = start + requestedLength - 1
            
            // Ensure the requested range actually has non-zero data (avoid sparse holes)
            do {
                let probeHandle = try FileHandle(forReadingFrom: cacheFileURL)
                defer { try? probeHandle.close() }
                try probeHandle.seek(toOffset: UInt64(start))
                let probeCount = min(Int(requestedLength), 4096)
                let probeData = try probeHandle.read(upToCount: probeCount) ?? Data()
                let hasRealData: Bool
                if requestedLength < 8 || probeData.count < 8 {
                    hasRealData = true
                } else {
                    hasRealData = probeData.contains { $0 != 0 }
                }
                if !hasRealData {
                    return false
                }
            } catch {
                print("⚠️ [PROGRESSIVE CACHE] Failed to inspect cache data for \(mediaID): \(error.localizedDescription)")
                return false
            }
            
            // If the requested range extends beyond the cached data, fall back to the network
            // so we can stitch cached + network bytes in a single response.
            let requestedEnd = end ?? (totalSize.map { $0 - 1 } ?? Int64.max)
            if actualEnd < requestedEnd {
                return false
            }

            var headers: [String: String] = [
                "Content-Type": "video/mp4",
                "Content-Length": "\(requestedLength)",
                "Accept-Ranges": "bytes"
            ]
            
            var statusCode = 200
            
            if rangeHeader != nil {
                if let total = totalSize {
                    headers["Content-Range"] = "bytes \(start)-\(actualEnd)/\(total)"
                } else {
                    headers["Content-Range"] = "bytes \(start)-\(actualEnd)/*"
                }
                statusCode = 206
            }
            let _ = rangeHeader != nil ? "\(start)-\(actualEnd)" : "full-file"
            
            if method == "HEAD" {
                sendResponse(connection: connection, statusCode: statusCode, headers: headers, body: nil)
                return true
            }
            
            sendHeadersAndStreamRange(
                connection: connection,
                statusCode: statusCode,
                headers: headers,
                fileURL: cacheFileURL,
                offset: start,
                length: requestedLength
            )
            return true
        }
        
        // Legacy fallback: check old range-based cache (no validation - legacy files may be partial)
        return serveLegacyProgressiveCacheIfAvailable(
            mediaID: mediaID,
            start: start,
            end: end,
            rangeHeader: rangeHeader,
            method: method,
            connection: connection
        )
    }
    
    private func serveLegacyProgressiveCacheIfAvailable(
        mediaID: String,
        start: Int64,
        end: Int64?,
        rangeHeader: String?,
        method: String,
        connection: NWConnection
    ) -> Bool {
        let cacheDir = progressiveCacheDirectory(for: mediaID).appendingPathComponent("ranges")
        guard FileManager.default.fileExists(atPath: cacheDir.path),
              let files = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path) else {
            return false
        }
        
        let requestEnd = end ?? Int64.max
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
            
            let overlaps = cachedStart <= start && cachedEnd >= start
            if overlaps {
                let cachePath = cacheDir.appendingPathComponent(file)
                guard let fullData = try? Data(contentsOf: cachePath) else {
                    continue
                }
                
                let offset = Int(start - cachedStart)
                let availableLength = fullData.count - offset
                guard offset >= 0, availableLength > 0 else {
                    continue
                }
                
                // Cap response size to prevent connection timeouts (same as new cache system)
                let maxChunkSize = 2 * 1024 * 1024 // 2MB max per response
                let cappedLength = min(availableLength, maxChunkSize)
                
                let requestedLength = end != nil ? Int(min(Int64(cappedLength), requestEnd - start + 1)) : cappedLength
                guard requestedLength > 0 else {
                    continue
                }
                
                let endIndex = min(offset + requestedLength, fullData.count)
                let subrange = fullData.subdata(in: offset..<endIndex)
                let actualEnd = start + Int64(subrange.count) - 1
                let totalSize = Int64(fullData.count)
                
                var headers: [String: String] = [
                    "Content-Type": "video/mp4",
                    "Content-Length": "\(subrange.count)",
                    "Accept-Ranges": "bytes"
                ]
                
                if rangeHeader != nil {
                    headers["Content-Range"] = "bytes \(start)-\(actualEnd)/\(totalSize)"
                }
                
                let statusCode = rangeHeader != nil ? 206 : 200
                let _ = rangeHeader != nil ? "\(start)-\(actualEnd)" : "full-file"
                
                if method == "HEAD" {
                    sendResponse(connection: connection, statusCode: statusCode, headers: headers, body: nil)
                } else {
                    sendResponse(connection: connection, statusCode: statusCode, headers: headers, body: subrange)
                }
                return true
            }
        }
        
        return false
    }
    
    private func sendHeadersAndStreamRange(
        connection: NWConnection,
        statusCode: Int,
        headers: [String: String],
        fileURL: URL,
        offset: Int64,
        length: Int64,
        completion: (() -> Void)? = nil
    ) {
        do {
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            try fileHandle.seek(toOffset: UInt64(offset))
            
            let headerData = buildHTTPHeaderData(statusCode: statusCode, headers: headers)
            connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    // Check if this is a normal cancellation (NWError 89 - Operation canceled)
                    let nsError = error as NSError
                    let isCancellation = nsError.domain == "Network.NWError" && nsError.code == 89
                    
                    if !isCancellation {
                        // Only log non-cancellation errors
                        print("⚠️ [PROGRESSIVE CACHE] Failed to send headers: \(error.localizedDescription)")
                    }
                    try? fileHandle.close()
                    return
                }
                
                self?.streamFileChunks(
                    connection: connection,
                    fileHandle: fileHandle,
                    remaining: length,
                    completion: completion
                )
            })
        } catch {
            print("⚠️ [PROGRESSIVE CACHE] Failed to read cache file: \(error.localizedDescription)")
        }
    }
    
    private func streamFileChunks(
        connection: NWConnection,
        fileHandle: FileHandle,
        remaining: Int64,
        completion: (() -> Void)? = nil
    ) {
        guard remaining > 0 else {
            try? fileHandle.close()
            completion?()
            return
        }
        
        let chunkSize = Int(min(Int64(progressiveStreamChunkSize), remaining))
        
        do {
            guard let chunk = try fileHandle.read(upToCount: chunkSize), !chunk.isEmpty else {
                try? fileHandle.close()
                return
            }
            
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    // Check if this is a normal cancellation (NWError 89 - Operation canceled)
                    // This is expected when AVPlayer cancels requests (e.g., after buffering enough or seeking)
                    let nsError = error as NSError
                    let isCancellation = nsError.domain == "Network.NWError" && nsError.code == 89
                    
                    if isCancellation {
                        // Normal cancellation - don't log as warning, just close and return silently
                        // AVPlayer often cancels requests when it has enough data or when seeking
                    } else {
                        // Actual error - log as warning
                        print("⚠️ [PROGRESSIVE CACHE] Send error: \(error.localizedDescription)")
                    }
                    try? fileHandle.close()
                    completion?()
                    return
                }
                
                self?.streamFileChunks(
                    connection: connection,
                    fileHandle: fileHandle,
                    remaining: remaining - Int64(chunk.count),
                    completion: completion
                )
            })
        } catch {
            print("⚠️ [PROGRESSIVE CACHE] Failed to read cache chunk: \(error.localizedDescription)")
            try? fileHandle.close()
            completion?()
        }
    }

    private func streamFileRange(
        connection: NWConnection,
        fileURL: URL,
        offset: Int64,
        length: Int64,
        completion: (() -> Void)? = nil
    ) {
        guard length > 0 else {
            completion?()
            return
        }
        
        do {
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            try fileHandle.seek(toOffset: UInt64(offset))
            streamFileChunks(
                connection: connection,
                fileHandle: fileHandle,
                remaining: length,
                completion: completion
            )
        } catch {
            print("⚠️ [PROGRESSIVE CACHE] Failed to stream cached range (\(offset)-\(offset + length - 1)) for \(fileURL.lastPathComponent): \(error.localizedDescription)")
            completion?()
        }
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
    
    private func fetchAndServe(url: URL, cachePath: String, connection: NWConnection, method: String, completion: (() -> Void)? = nil) {
        // CRITICAL: Block NEW network requests until app initialized
        guard canBypassInitialization(url: url) else {
            print("⚠️ [LocalHTTPServer] App not initialized, refusing network fetch for \(url.path)")
            self.sendResponse(connection: connection, statusCode: 503, headers: [:], body: nil)
            completion?()
            return
        }
        
        let startTime = Date()
        
        let task = connectionPool.dataTask(with: url) { [weak self] data, response, error in
            let _ = Date().timeIntervalSince(startTime)
            guard let self = self else { return }
            
            // MEMORY FIX: Use autoreleasepool for large segment downloads (4-5MB each)
            autoreleasepool {
                // Extract mediaID from cachePath for BlackList tracking
                let pathComponents = cachePath.components(separatedBy: "/")
                let mediaID = pathComponents.first(where: { $0.starts(with: "Qm") }) ?? ""
                
                if let error = error {
                    // Don't count cancellations (e.g. from emergency cleanup) as real failures
                    if !mediaID.isEmpty, (error as NSError).code != NSURLErrorCancelled {
                        BlackList.shared.recordFailure(mediaID)
                    }

                    self.sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
                    completion?()
                    return
                }
                
                // CRITICAL: Validate HTTP response status
                guard let httpResponse = response as? HTTPURLResponse else {
                    
                    // Record failure for invalid response
                    if !mediaID.isEmpty {
                        BlackList.shared.recordFailure(mediaID)
                    }
                    
                    self.sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
                    completion?()
                    return
                }
                
                guard (200...299).contains(httpResponse.statusCode) else {
                    
                    // Record failure for error status
                    if !mediaID.isEmpty {
                        BlackList.shared.recordFailure(mediaID)
                    }
                    
                    self.sendResponse(connection: connection, statusCode: httpResponse.statusCode, headers: [:], body: nil)
                    completion?()
                    return
                }
                
                guard let data = data, !data.isEmpty else {
                    
                    // Record failure for empty data
                    if !mediaID.isEmpty {
                        BlackList.shared.recordFailure(mediaID)
                    }
                    
                    self.sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
                    completion?()
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
                    }
                    
                    // Rewrite with current port for serving
                    let modifiedPlaylist = self.rewritePlaylistURLs(relativePlaylist, mediaID: mediaID, baseURL: url)
                    if let modifiedData = modifiedPlaylist.data(using: .utf8) {
                        finalData = modifiedData
                    }
                }
                
                // CRITICAL FIX: Write synchronously so file exists when fetchAndServe returns
                // This ensures deduplication polling finds the file immediately
                // autoreleasepool still protects memory during write
                let cacheURL = URL(fileURLWithPath: cachePath)
                do {
                    try dataToCache.write(to: cacheURL)
                } catch {
                    print("⚠️ [LocalHTTPServer] Failed to write cache: \(error.localizedDescription)")
                }
                
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
                // MEMORY FIX: All Data objects released when autoreleasepool exits
                
                // CRITICAL: Call completion AFTER file is written and served
                completion?()
            }
        }
        task.resume()
    }
    
    private func serveFile(path: String, connection: NWConnection, method: String) {
        // CRITICAL: Check if connection is still alive before trying to serve
        // After long waits (22+ seconds), AVPlayer may have closed the connection
        let connectionState = connection.state
        switch connectionState {
        case .cancelled, .failed:
            print("⚠️ [LocalHTTPServer] Connection closed while waiting, cannot serve: \(path.components(separatedBy: "/").last ?? path)")
            return
        default:
            break
        }

        
        guard FileManager.default.fileExists(atPath: path) else {
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
            return
        }
        
        do {
            // MEMORY FIX: Use autoreleasepool for large files to release memory immediately
            try autoreleasepool {
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
                // data released here when autoreleasepool exits
            }
        } catch {
            print("ERROR: [LocalHTTPServer] Failed to read file: \(error)")
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
                        // Absolute path: /ipfs/QmHash/720p/playlist.m3u8 -> http://127.0.0.1:port/ipfs/QmHash/720p/playlist.m3u8
                        localhostURL = "\(Constants.LOCAL_HOST):\(port)\(pathString)"
                    } else {
                        // Relative path: 720p/playlist.m3u8 -> http://127.0.0.1:port/playlistDirectory/720p/playlist.m3u8
                        localhostURL = "\(Constants.LOCAL_HOST):\(port)\(playlistDirectory)/\(pathString)"
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
                        // Absolute path: /ipfs/QmHash/segment000.ts -> http://127.0.0.1:port/ipfs/QmHash/segment000.ts
                        localhostURL = "\(Constants.LOCAL_HOST):\(port)\(pathString)"
                    } else {
                        // Relative path: segment000.ts -> http://127.0.0.1:port/playlistDirectory/segment000.ts
                        localhostURL = "\(Constants.LOCAL_HOST):\(port)\(playlistDirectory)/\(pathString)"
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
    
    private func buildHTTPHeaderData(statusCode: Int, headers: [String: String]) -> Data {
        var response = "HTTP/1.1 \(statusCode) \(getStatusText(statusCode))\r\n"
        response += "Connection: keep-alive\r\n"
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        return response.data(using: .utf8) ?? Data()
    }
    
    private func sendResponse(connection: NWConnection, statusCode: Int, headers: [String: String], body: Data?, completion: (() -> Void)? = nil) {
        let headerData = buildHTTPHeaderData(statusCode: statusCode, headers: headers)
        
        guard let body = body, !body.isEmpty else {
            connection.send(content: headerData, completion: .contentProcessed { _ in
                completion?()
            })
            return
        }
        
        var allData = Data(headerData)
        allData.append(body)
        
        connection.send(content: allData, completion: .contentProcessed { _ in
            completion?()
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
    
    /// Validates that a cached progressive video file is playable by checking for moov atom near the beginning.
    /// Some progressive MP4s place the moov atom slightly deeper than the first 8KB, so we scan up to 512KB.
    private func isValidProgressiveCache(fileURL: URL) -> Bool {
        do {
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { try? fileHandle.close() }
            
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let maxScanBytes = Int(min(max(fileSize, 0), 4 * 1024 * 1024)) // Scan up to 4MB
            let chunkSize = 128 * 1024
            var buffer = Data(capacity: maxScanBytes)
            
            while buffer.count < maxScanBytes {
                let remaining = maxScanBytes - buffer.count
                let toRead = min(chunkSize, remaining)
                guard let chunk = try fileHandle.read(upToCount: toRead), !chunk.isEmpty else {
                    break
                }
                buffer.append(chunk)
                
                if buffer.range(of: Data([0x6D, 0x6F, 0x6F, 0x76])) != nil { // "moov"
                    return true
                }
            }
            
            if buffer.range(of: Data([0x66, 0x74, 0x79, 0x70])) != nil { // "ftyp"
                print("⚠️ [PROGRESSIVE CACHE] moov atom not found within first \(buffer.count) bytes, but ftyp is present – assuming valid progressive file")
                return true
            }
            
            print("⚠️ [PROGRESSIVE CACHE] No moov atom found in first \(buffer.count) bytes - file may not be streamable")
            return false
            
        } catch {
            print("⚠️ [PROGRESSIVE CACHE] Failed to validate cache file: \(error.localizedDescription)")
            return false
        }
    }
}
