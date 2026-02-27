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
    private let sessionCleanup: () -> Void

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
        contiguousSizeUpdate: @escaping (Int64) -> Void,
        sessionCleanup: @escaping () -> Void
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
        self.sessionCleanup = sessionCleanup
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

            // Clean up the streaming session entry
            sessionCleanup()
        }

        if let error = error {
            let nsError = error as NSError
            let isTransient = nsError.code == NSURLErrorCancelled ||
                              nsError.code == NSURLErrorTimedOut ||
                              nsError.code == NSURLErrorNetworkConnectionLost ||
                              nsError.code == NSURLErrorNotConnectedToInternet
            if isTransient {
                // Don't BlackList transient errors — AVPlayer will re-request remaining bytes
                print("⚠️ [PROGRESSIVE STREAM] Transient error for \(mediaID) (code \(nsError.code)): \(error.localizedDescription)")
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
/// Tracks which segment downloads are in progress using a simple Set.
/// Waiters poll with Task.sleep — no CheckedContinuation, no leak risk.
private actor ActiveDownloadsActor {
    private var activeDownloads: Set<String> = []

    /// MediaIDs whose players have been cleared.  Any pending dedup waiter or background
    /// retry for these mediaIDs should be skipped immediately rather than retried.
    /// Cleared when a new player is registered for the same mediaID (fresh start).
    private var cancelledMediaIDs: Set<String> = []

    func hasDownload(for key: String) -> Bool {
        return activeDownloads.contains(key)
    }

    func markDownloadStarted(for key: String) {
        activeDownloads.insert(key)
    }

    func markDownloadCompleted(for key: String) {
        activeDownloads.remove(key)
    }

    func cancelAllTasks() {
        activeDownloads.removeAll()
    }

    /// Remove all active download keys containing the given mediaID
    /// and mark it as cancelled so in-flight URLSession completions don't retry.
    func cancelTasks(for mediaID: String) {
        cancelledMediaIDs.insert(mediaID)
        activeDownloads = activeDownloads.filter { !$0.contains(mediaID) }
    }

    /// Remove active download keys for this mediaID without marking it as permanently
    /// cancelled. Used to free download slots for non-primary videos whose downloads
    /// stalled — future segment requests will still be served normally.
    func releaseStalledDownloads(for mediaID: String) {
        activeDownloads = activeDownloads.filter { !$0.contains(mediaID) }
    }

    /// Returns true if the player for this mediaID was cleared while a download was in-flight.
    func isMediaIDCancelled(_ mediaID: String) -> Bool {
        return cancelledMediaIDs.contains(mediaID)
    }

    /// Clear the cancelled state when a fresh player is registered for a mediaID.
    func clearCancelledMediaID(_ mediaID: String) {
        cancelledMediaIDs.remove(mediaID)
    }
}

public class LocalHTTPServer: @unchecked Sendable {
    public static let shared = LocalHTTPServer()

    private var listener: NWListener?
    public private(set) var port: UInt16 = 8080  // Public read, private write
    private var mediaCache: [String: String] = [:] // mediaID -> cachePath
    private var mediaRealURLs: [String: URL] = [:] // mediaID -> real URL
    private let mediaLock = NSLock() // Protects mediaCache and mediaRealURLs
    private let queue = DispatchQueue(label: "LocalHTTPServer", qos: .userInitiated)
    private var preferenceHelper: PreferenceHelper?
    private let stateLock = NSLock() // Protects isStarting, isRunning, isStopping
    private var _isStarting = false
    private var _isRunning = false
    private var _isStopping = false

    private var isStarting: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isStarting }
        set { stateLock.lock(); defer { stateLock.unlock() }; _isStarting = newValue }
    }
    public var isRunning: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isRunning }
        set { stateLock.lock(); defer { stateLock.unlock() }; _isRunning = newValue }
    }
    private var isStopping: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isStopping }
        set { stateLock.lock(); defer { stateLock.unlock() }; _isStopping = newValue }
    }

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

    // Log deduplication: suppress duplicate CACHE MISS logs for same mediaID+range within 3s
    private var recentCacheMissLogs: [String: Date] = [:]
    private let cacheMissLogLock = NSLock()
    
    // Connection pool for efficient HTTP requests
    private var _connectionPool: URLSession?
    private let connectionPoolLock = NSLock()

    // Network failure tracking for emergency cleanup
    private let networkFailureLock = NSLock()
    private var _consecutiveNetworkFailures: Int = 0
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
        
        if let mediaID = mediaID {
            mediaLock.lock()
            let registeredURL = mediaRealURLs[mediaID]
            mediaLock.unlock()
            if let registeredURL = registeredURL,
               let host = registeredURL.host,
               !host.isEmpty,
               host != "127.0.0.1" {
                return true
            }
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
        // Stop current instance synchronously (no dispatch — already on queue or safe context)
        stopInternal()

        // Small delay to ensure port release
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        isStopping = false

        // Start fresh
        await startServer()

        if !isRunning {
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
    
    /// Internal stop that runs on the caller's context (must be called from `queue` or restart)
    private func stopInternal() {
        if self.listener != nil {
            self.isStopping = true
            self.listener?.cancel()
            self.listener = nil
            self.isRunning = false
            self.isStarting = false
            // Clear media registration so we don't retain metadata when server is stopped
            mediaLock.lock()
            mediaCache.removeAll()
            mediaRealURLs.removeAll()
            mediaLock.unlock()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopInternal()
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                self.isStopping = false
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

    /// Synchronous version — immediately cancels all stale upstream connections and
    /// streaming sessions.  Uses dedicated locks (not the server queue) so it cannot
    /// deadlock even if the queue is blocked by in-flight requests.
    /// Call this on foreground return BEFORE any new video loading starts.
    public func resetAllConnectionsImmediately() {
        // 1. Kill the shared connection pool (cancels all pending upstream requests)
        connectionPoolLock.lock()
        _connectionPool?.invalidateAndCancel()
        _connectionPool = nil
        connectionPoolLock.unlock()

        // 2. Kill per-stream proxy sessions
        streamingSessionsLock.lock()
        for (_, session) in streamingSessions {
            session.invalidateAndCancel()
        }
        streamingSessions.removeAll()
        streamingSessionsLock.unlock()

        // 3. Fire-and-forget: cancel tracked active downloads
        Task { await activeDownloadsActor.cancelAllTasks() }
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
    
    /// Cancel all active downloads (HLS segment tasks + progressive streaming sessions)
    /// for a specific mediaID.  Call this before deleting the media's disk cache so that
    /// in-flight writes don't fail with "file not found" and pending dedup waiters don't
    /// spawn untracked background retries.
    public func cancelDownloads(for mediaID: String) {
        // 1. Cancel tracked HLS segment download tasks
        Task { await activeDownloadsActor.cancelTasks(for: mediaID) }

        // 2. Cancel progressive streaming sessions for this mediaID
        streamingSessionsLock.lock()
        let sessionKeysToRemove = streamingSessions.keys.filter { $0.hasPrefix(mediaID) }
        for key in sessionKeysToRemove {
            streamingSessions[key]?.invalidateAndCancel()
            streamingSessions.removeValue(forKey: key)
        }
        streamingSessionsLock.unlock()
    }

    /// Release stalled download slots for a non-primary video without marking the mediaID
    /// as permanently cancelled.  Frees network concurrency for other videos while keeping
    /// the existing AVPlayer and its buffer intact.  Future segment requests from AVPlayer
    /// will still be served normally (unlike `cancelDownloads` which blocks them).
    public func releaseStalledDownloads(for mediaID: String) {
        // 1. Clear dedup keys so new requests aren't stuck waiting for the stalled download
        Task { await activeDownloadsActor.releaseStalledDownloads(for: mediaID) }

        // 2. Cancel the URLSession tasks to free network slots
        streamingSessionsLock.lock()
        let sessionKeysToRemove = streamingSessions.keys.filter { $0.hasPrefix(mediaID) }
        for key in sessionKeysToRemove {
            streamingSessions[key]?.invalidateAndCancel()
            streamingSessions.removeValue(forKey: key)
        }
        streamingSessionsLock.unlock()
    }

    /// Thread-safe lookup of a registered real URL — safe to call from async contexts.
    private func getRealURL(for mediaID: String) -> URL? {
        mediaLock.lock()
        defer { mediaLock.unlock() }
        return mediaRealURLs[mediaID]
    }

    public func registerMedia(mediaID: String, cachePath: String) {
        mediaLock.lock()
        mediaCache[mediaID] = cachePath
        mediaLock.unlock()
    }

    public func registerAndGetURL(for mediaID: String, realURL: URL) -> URL {
        mediaLock.lock()
        mediaRealURLs[mediaID] = realURL
        mediaLock.unlock()

        // A new player is being created for this mediaID — clear any cancelled state so
        // fresh downloads for this media are served normally.
        Task { await activeDownloadsActor.clearCancelledMediaID(mediaID) }

        // Return localhost URL: http://localhost:8080/ipfs/mediaID (clean format without redundancy)
        // AVPlayer will request this, and we'll serve from cache or fetch from realURL
        guard let localhostURL = URL(string: "\(Constants.LOCAL_HOST):\(port)\(realURL.path)") else {
            // Fallback: percent-encode the path for URLs with special characters
            let encodedPath = realURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? realURL.path
            return URL(string: "\(Constants.LOCAL_HOST):\(port)\(encodedPath)")!
        }
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
                        var shouldCleanup = false
                        self.networkFailureLock.lock()
                        self._consecutiveNetworkFailures += 1
                        let count = self._consecutiveNetworkFailures
                        if count >= self.maxConsecutiveFailures {
                            shouldCleanup = true
                            self._consecutiveNetworkFailures = 0
                        }
                        self.networkFailureLock.unlock()

                        print("DEBUG: [LocalHTTPServer] Network failure count: \(count)/\(self.maxConsecutiveFailures)")
                        if shouldCleanup {
                            print("DEBUG: [LocalHTTPServer] Too many consecutive network failures, triggering cleanup")
                            self.handleNetworkFailureCleanup()
                        }
                    }

                    // Only log non-connection-reset errors
                    if nwCode != 54 {
                        print("DEBUG: [LocalHTTPServer] Receive error (code \(nwCode)): \(error)")
                    }
                } else {
                    // Reset network failure counter on successful receive
                    self.networkFailureLock.lock()
                    self._consecutiveNetworkFailures = 0
                    self.networkFailureLock.unlock()
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
            let realURL = getRealURL(for: mediaID)
            guard let realURL = realURL else {
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
        let realURL = getRealURL(for: mediaID)
        guard let realURL = realURL else {
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
        let isCached = FileManager.default.fileExists(atPath: cachePath)
        print("🎞️ [HLS DATA] Playlist request mediaID: \(mediaID), cached: \(isCached)")

        // Check cache first
        if isCached {
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
        let segmentName = URL(fileURLWithPath: cachePath).lastPathComponent

        // Check cache first
        if FileManager.default.fileExists(atPath: cachePath) {
            // Serve cached segment - this reads from disk, no memory bloat
            autoreleasepool {
                serveFile(path: cachePath, connection: connection, method: method)
            }
            return
        }

        print("🎞️ [HLS DATA] Segment cache miss mediaID: \(mediaID), segment: \(segmentName), path: \(cachePath) - fetching")

        // DEDUPLICATION FIX: Check if this segment is already being downloaded
        let downloadKey = cachePath

        // DEDUPLICATION: Check if another request is already downloading this segment.
        // Waiters poll with Task.sleep — no CheckedContinuation, no leak risk.
        let hasExisting = await activeDownloadsActor.hasDownload(for: downloadKey)

        if hasExisting {
            print("🎞️ [HLS DATA] Segment dedup wait mediaID: \(mediaID), segment: \(segmentName)")
            // Check connection state before waiting
            switch connection.state {
            case .cancelled, .failed:
                return
            default:
                break
            }

            // Poll until: file appears on disk, download removed from active set, or 120s timeout.
            // IPFS segments can take 30-90s due to DHT lookup overhead — 15s was too short,
            // causing the dedup waiter to time out and leave NWConnections hanging.
            let pollInterval: UInt64 = 500_000_000 // 0.5s
            let maxPolls = 240 // 240 × 0.5s = 120s

            for _ in 0..<maxPolls {
                try? await Task.sleep(nanoseconds: pollInterval)

                // File appeared on disk — serve it
                if FileManager.default.fileExists(atPath: cachePath) {
                    autoreleasepool {
                        serveFile(path: cachePath, connection: connection, method: method)
                    }
                    return
                }

                // Download finished (removed from active set) but file missing — download failed
                if !(await activeDownloadsActor.hasDownload(for: downloadKey)) {
                    break
                }

                // Player was cleared — don't retry
                if await activeDownloadsActor.isMediaIDCancelled(mediaID) { return }

                // Connection closed — just return
                switch connection.state {
                case .cancelled, .failed: return
                default: break
                }
            }

            // After timeout or download failure, check again
            if await activeDownloadsActor.isMediaIDCancelled(mediaID) { return }

            switch connection.state {
            case .cancelled, .failed: return
            default: break
            }

            // Fall through to become a new downloader (no untracked background spawns)
        }

        // This request becomes the downloader — mark active, fetch, then mark completed.
        await activeDownloadsActor.markDownloadStarted(for: downloadKey)
        print("🎞️ [HLS DATA] Segment download start mediaID: \(mediaID), segment: \(segmentName)")

        fetchAndServe(url: fullRealURL, cachePath: cachePath, connection: connection, method: method) {
            Task { await self.activeDownloadsActor.markDownloadCompleted(for: downloadKey) }
        }
    }
    
    private func fetchHEADWithRetry(url: URL, mediaID: String, attempt: Int = 1, maxAttempts: Int = 3, completion: @escaping (HTTPURLResponse?) -> Void) {
        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        headRequest.timeoutInterval = 10

        let headTask = connectionPool.dataTask(with: headRequest) { [weak self] _, response, error in
            guard let self = self else {
                completion(nil)
                return
            }

            if let error = error {
                let nsError = error as NSError
                let isRetryable = nsError.code == NSURLErrorTimedOut ||
                                  nsError.code == NSURLErrorNetworkConnectionLost ||
                                  nsError.code == NSURLErrorNotConnectedToInternet

                if nsError.code != NSURLErrorCancelled && attempt < maxAttempts && isRetryable {
                    let delay = Double(attempt)
                    print("🔄 [PROGRESSIVE HEAD] Retry \(attempt)/\(maxAttempts - 1) for \(mediaID) after \(delay)s")
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.fetchHEADWithRetry(url: url, mediaID: mediaID, attempt: attempt + 1, maxAttempts: maxAttempts, completion: completion)
                    }
                    return
                }

                print("❌ [PROGRESSIVE HEAD] Failed for \(mediaID): \(error.localizedDescription)")
                if nsError.code != NSURLErrorCancelled {
                    BlackList.shared.recordFailure(mediaID)
                }
                completion(nil)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("❌ [PROGRESSIVE HEAD] Bad status for \(mediaID)")
                BlackList.shared.recordFailure(mediaID)
                completion(nil)
                return
            }

            completion(httpResponse)
        }
        headTask.resume()
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
        // Deduplicate: suppress identical cache miss logs within 3 seconds
        let logKey = "\(mediaID)_\(rangeStr)"
        let now = Date()
        cacheMissLogLock.lock()
        let lastLog = recentCacheMissLogs[logKey]
        let shouldLog = lastLog == nil || now.timeIntervalSince(lastLog!) >= 3.0
        if shouldLog { recentCacheMissLogs[logKey] = now }
        // Prune old entries periodically
        if recentCacheMissLogs.count > 50 {
            recentCacheMissLogs = recentCacheMissLogs.filter { now.timeIntervalSince($0.value) < 5.0 }
        }
        cacheMissLogLock.unlock()
        if shouldLog {
            print("❌ [PROGRESSIVE CACHE MISS] mediaID: \(mediaID), range: \(rangeStr), isProbe: \(isProbeRequest) - will fetch from network")
        }
        
        // CACHE MISS - fetch from real server
        // CRITICAL: Block NEW network requests until app initialized (but cached content is OK)
        guard canBypassInitialization(for: mediaID, url: fullRealURL) else {
            print("⚠️ [LocalHTTPServer] App not initialized, refusing NETWORK request for \(mediaID). Cache miss - video won't load until app initializes.")
            self.sendResponse(connection: connection, statusCode: 503, headers: [:], body: nil)
            return
        }
        
        // STREAMING: First get file size with HEAD, then stream data in chunks
        let requestedStart = rangeStart ?? 0
        
        self.fetchHEADWithRetry(url: fullRealURL, mediaID: mediaID) { [weak self] httpResponse in
            guard let self = self else { return }

            guard let httpResponse = httpResponse else {
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
                    
                    let sessionKey = mediaID + "_\(streamStart)"
                    let sessionCleanup: () -> Void = { [weak self] in
                        guard let self = self else { return }
                        self.streamingSessionsLock.lock()
                        self.streamingSessions.removeValue(forKey: sessionKey)
                        self.streamingSessionsLock.unlock()
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
                        contiguousSizeUpdate: contiguousUpdate,
                        sessionCleanup: sessionCleanup
                    )

                    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

                    self.streamingSessionsLock.lock()
                    self.streamingSessions[sessionKey] = session
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

        // Extract mediaID from cachePath for BlackList tracking
        let pathComponents = cachePath.components(separatedBy: "/")
        let mediaID = pathComponents.first(where: { $0.starts(with: "Qm") }) ?? ""
        let isSegment = cachePath.hasSuffix(".ts")

        // Stream .ts segments to AVPlayer as bytes arrive from IPFS.
        // AVPlayer can render the first frame after the initial keyframe (~100–300 KB)
        // instead of waiting for the full 4–5 MB segment to download.
        // HEAD requests are routed through fetchWithRetry (we only need headers, not a stream).
        if isSegment && method == "GET" {
            streamSegmentAndServe(url: url, cachePath: cachePath, connection: connection, mediaID: mediaID, completion: completion ?? {})
            return
        }

        let maxAttempts = isSegment ? 3 : 1  // Retry segment downloads (like ExoPlayer)
        fetchWithRetry(url: url, cachePath: cachePath, connection: connection, method: method, mediaID: mediaID, attempt: 1, maxAttempts: maxAttempts, completion: completion)
    }
    
    /// Stream a `.ts` segment from IPFS to `connection` byte-by-byte as the download progresses,
    /// then write the completed segment to disk for caching.
    ///
    /// Unlike `fetchWithRetry` (which buffers the whole response before serving), this method
    /// forwards `URLSessionDataDelegate.didReceive data` chunks directly to the `NWConnection`
    /// so AVPlayer can start rendering the first video frame as soon as the initial keyframe
    /// bytes arrive (~100–300 KB), rather than waiting for the full 4–5 MB segment.
    ///
    /// The session is registered in `streamingSessions` so `cancelDownloads(for:)` can cancel
    /// it when the player is cleared.
    private func streamSegmentAndServe(url: URL, cachePath: String, connection: NWConnection, mediaID: String, completion: @escaping () -> Void) {
        // Use the relative path (e.g., "480p/segment000.ts") instead of just the filename
        // to avoid session key collisions between quality variants of the same segment.
        let cacheURL = URL(fileURLWithPath: cachePath)
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let mediaDir = cacheDir.appendingPathComponent(mediaID)
        let relativePath: String
        if cachePath.hasPrefix(mediaDir.path) {
            // Strip the media directory prefix to get e.g. "480p/segment000.ts"
            relativePath = String(cachePath.dropFirst(mediaDir.path.count + 1))
        } else {
            relativePath = cacheURL.lastPathComponent
        }
        let sessionKey = "\(mediaID)/stream/\(relativePath)"

        let delegate = SegmentStreamDelegate(
            connection: connection,
            cachePath: cachePath,
            mediaID: mediaID,
            sessionKey: sessionKey,
            buildHeaders: { [weak self] statusCode, headers in
                self?.buildHTTPHeaderData(statusCode: statusCode, headers: headers) ?? Data()
            },
            sendFallbackError: { [weak self] conn in
                self?.sendResponse(connection: conn, statusCode: 500, headers: [:], body: nil)
            },
            removeSession: { [weak self] key in
                self?.streamingSessionsLock.lock()
                self?.streamingSessions.removeValue(forKey: key)
                self?.streamingSessionsLock.unlock()
            },
            completion: completion
        )

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 300
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        // Track session so cancelDownloads(for: mediaID) can invalidate it.
        streamingSessionsLock.lock()
        streamingSessions[sessionKey] = session
        streamingSessionsLock.unlock()

        session.dataTask(with: url).resume()
        // `session` and `delegate` are kept alive by the running task until completion.
    }

    /// Download and cache file without serving (for background downloads when connection is closing)
    private func downloadAndCacheOnly(url: URL, cachePath: String, completion: (() -> Void)? = nil) {
        // CRITICAL: Block NEW network requests until app initialized
        guard canBypassInitialization(url: url) else {
            print("⚠️ [LocalHTTPServer] App not initialized, refusing download for \(url.path)")
            completion?()
            return
        }

        // Extract mediaID from cachePath for BlackList tracking
        let pathComponents = cachePath.components(separatedBy: "/")
        let mediaID = pathComponents.first(where: { $0.starts(with: "Qm") }) ?? ""
        let isSegment = cachePath.hasSuffix(".ts")
        let maxAttempts = isSegment ? 3 : 1  // Retry segment downloads (like ExoPlayer)

        downloadWithRetry(url: url, cachePath: cachePath, mediaID: mediaID, attempt: 1, maxAttempts: maxAttempts, completion: completion)
    }
    
    /// Download and cache without serving (used when connection is closing)
    private func downloadWithRetry(url: URL, cachePath: String, mediaID: String, attempt: Int, maxAttempts: Int, completion: (() -> Void)?) {
        let task = connectionPool.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else {
                completion?()
                return
            }

            // MEMORY FIX: Use autoreleasepool for large segment downloads (4-5MB each)
            autoreleasepool {
                // Check for retryable errors (timeout, network lost, etc.)
                if let error = error {
                    let nsError = error as NSError
                    let isRetryable = nsError.code == NSURLErrorTimedOut ||
                                      nsError.code == NSURLErrorNetworkConnectionLost ||
                                      nsError.code == NSURLErrorNotConnectedToInternet

                    if nsError.code != NSURLErrorCancelled, attempt < maxAttempts, isRetryable {
                        let delay = Double(attempt) // 1s, 2s backoff
                        print("🔄 [LocalHTTPServer] Download retry \(attempt)/\(maxAttempts - 1) for \(url.lastPathComponent) after \(delay)s")
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                            self.downloadWithRetry(url: url, cachePath: cachePath, mediaID: mediaID, attempt: attempt + 1, maxAttempts: maxAttempts, completion: completion)
                        }
                        return
                    }

                    // Final failure — record but don't respond (no connection to respond to)
                    if !mediaID.isEmpty, nsError.code != NSURLErrorCancelled {
                        BlackList.shared.recordFailure(mediaID)
                    }
                    completion?()
                    return
                }

                // CRITICAL: Validate HTTP response status
                guard let httpResponse = response as? HTTPURLResponse else {
                    if !mediaID.isEmpty {
                        BlackList.shared.recordFailure(mediaID)
                    }
                    completion?()
                    return
                }

                // Retry on server errors (5xx)
                if httpResponse.statusCode >= 500, attempt < maxAttempts {
                    let delay = Double(attempt)
                    print("🔄 [LocalHTTPServer] Download retry \(attempt)/\(maxAttempts - 1) for \(url.lastPathComponent) (HTTP \(httpResponse.statusCode))")
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.downloadWithRetry(url: url, cachePath: cachePath, mediaID: mediaID, attempt: attempt + 1, maxAttempts: maxAttempts, completion: completion)
                    }
                    return
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    if !mediaID.isEmpty {
                        BlackList.shared.recordFailure(mediaID)
                    }
                    completion?()
                    return
                }

                guard let data = data, !data.isEmpty else {
                    if !mediaID.isEmpty {
                        BlackList.shared.recordFailure(mediaID)
                    }
                    completion?()
                    return
                }

                // For playlists, strip to relative paths for caching (port-independent!)
                var dataToCache = data
                if cachePath.hasSuffix(".m3u8"), let playlistString = String(data: data, encoding: .utf8) {
                    // Strip URLs to relative paths for caching (remove scheme/host/port)
                    let relativePlaylist = self.stripPlaylistToRelativePaths(playlistString, baseURL: url)
                    if let relativeData = relativePlaylist.data(using: .utf8) {
                        dataToCache = relativeData
                    }
                }

                // CRITICAL: Write to cache (this is the only thing we do - no serving)
                let cacheURL = URL(fileURLWithPath: cachePath)
                // Skip silently if the parent directory was deleted (clearPlayerForMediaID)
                guard FileManager.default.fileExists(atPath: cacheURL.deletingLastPathComponent().path) else {
                    completion?()
                    return
                }
                do {
                    try dataToCache.write(to: cacheURL)
                    print("✅ [LocalHTTPServer] Downloaded and cached: \(url.lastPathComponent)")
                } catch {
                    print("⚠️ [LocalHTTPServer] Failed to write cache: \(error.localizedDescription)")
                }

                // Record successful fetch for this mediaID
                if !mediaID.isEmpty {
                    BlackList.shared.recordSuccess(mediaID)
                }

                completion?()
            }
        }
        task.resume()
    }

    private func fetchWithRetry(url: URL, cachePath: String, connection: NWConnection, method: String, mediaID: String, attempt: Int, maxAttempts: Int, completion: (() -> Void)?) {

        let task = connectionPool.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }

            // MEMORY FIX: Use autoreleasepool for large segment downloads (4-5MB each)
            autoreleasepool {
                // Check for retryable errors (timeout, network lost, etc.)
                if let error = error {
                    let nsError = error as NSError
                    let isRetryable = nsError.code == NSURLErrorTimedOut ||
                                      nsError.code == NSURLErrorNetworkConnectionLost ||
                                      nsError.code == NSURLErrorNotConnectedToInternet

                    if nsError.code != NSURLErrorCancelled, attempt < maxAttempts, isRetryable {
                        let delay = Double(attempt) // 1s, 2s backoff
                        print("🔄 [LocalHTTPServer] Retry \(attempt)/\(maxAttempts - 1) for \(url.lastPathComponent) after \(delay)s")
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                            self.fetchWithRetry(url: url, cachePath: cachePath, connection: connection, method: method, mediaID: mediaID, attempt: attempt + 1, maxAttempts: maxAttempts, completion: completion)
                        }
                        return
                    }

                    // Final failure — record and respond
                    if !mediaID.isEmpty, nsError.code != NSURLErrorCancelled {
                        BlackList.shared.recordFailure(mediaID)
                    }
                    self.sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
                    completion?()
                    return
                }

                // CRITICAL: Validate HTTP response status
                guard let httpResponse = response as? HTTPURLResponse else {
                    if !mediaID.isEmpty {
                        BlackList.shared.recordFailure(mediaID)
                    }
                    self.sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
                    completion?()
                    return
                }

                // Retry on server errors (5xx)
                if httpResponse.statusCode >= 500, attempt < maxAttempts {
                    let delay = Double(attempt)
                    print("🔄 [LocalHTTPServer] Retry \(attempt)/\(maxAttempts - 1) for \(url.lastPathComponent) (HTTP \(httpResponse.statusCode))")
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.fetchWithRetry(url: url, cachePath: cachePath, connection: connection, method: method, mediaID: mediaID, attempt: attempt + 1, maxAttempts: maxAttempts, completion: completion)
                    }
                    return
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    if !mediaID.isEmpty {
                        BlackList.shared.recordFailure(mediaID)
                    }
                    self.sendResponse(connection: connection, statusCode: httpResponse.statusCode, headers: [:], body: nil)
                    completion?()
                    return
                }

                guard let data = data, !data.isEmpty else {
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
                // Skip silently if the parent directory was deleted (clearPlayerForMediaID)
                // while this download was in-flight — avoids spurious "file not found" warnings.
                guard FileManager.default.fileExists(atPath: cacheURL.deletingLastPathComponent().path) else {
                    completion?()
                    return
                }
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

        // CRITICAL: Add #EXT-X-ENDLIST if missing. Without this tag AVPlayer treats the
        // playlist as potentially live — it keeps polling for new segments, isPlaybackBufferFull
        // stays false, buffer never reaches 100%, and the player stalls at the end.
        if modified.contains("#EXTINF:") && !modified.contains("#EXT-X-ENDLIST") {
            if !modified.hasSuffix("\n") {
                modified += "\n"
            }
            modified += "#EXT-X-ENDLIST\n"
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
        
        print("🎞️ [HLS PLAYLIST] Serving to AVPlayer (mediaID: \(mediaID), base: \(baseURL.lastPathComponent)):\n\(modified)")
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
        // Always use Connection: close. The proxy handles exactly one request per
        // NWConnection — after sendResponse it never reads from the connection again.
        // With keep-alive, AVPlayer reuses the connection for the next request (e.g.
        // segment001.ts) but the proxy never reads it, silently losing the request.
        // This caused segment001.ts to never be fetched, item.status to stay at
        // .unknown, and the video to stall.
        response += "Connection: close\r\n"
        for (key, value) in headers where key != "Connection" {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        return response.data(using: .utf8) ?? Data()
    }
    
    private func sendResponse(connection: NWConnection, statusCode: Int, headers: [String: String], body: Data?, completion: (() -> Void)? = nil) {
        let headerData = buildHTTPHeaderData(statusCode: statusCode, headers: headers)

        guard let body = body, !body.isEmpty else {
            // Send headers only, then TCP FIN (Connection: close requires actual close).
            connection.send(content: headerData, isComplete: false, completion: .contentProcessed { _ in
                connection.send(content: nil, contentContext: .defaultMessage, isComplete: true,
                               completion: .contentProcessed { _ in completion?() })
            })
            return
        }

        var allData = Data(headerData)
        allData.append(body)

        // Send headers + body, then TCP FIN (Connection: close requires actual close).
        connection.send(content: allData, isComplete: false, completion: .contentProcessed { _ in
            connection.send(content: nil, contentContext: .defaultMessage, isComplete: true,
                           completion: .contentProcessed { _ in completion?() })
        })
    }
    
    private func getStatusText(_ statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
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

// MARK: - SegmentStreamDelegate

/// `URLSessionDataDelegate` that pipes MPEG-TS segment bytes from IPFS to an AVPlayer
/// `NWConnection` as they arrive, rather than buffering the whole download first.
///
/// **Why this matters for IPFS**: A typical HLS segment is 4–5 MB.  On a slow IPFS node
/// the full download can take 20–30 s, keeping `AVPlayerItem.status` stuck at `.unknown`
/// (black screen) the whole time.  By forwarding each `didReceive data` chunk immediately,
/// AVPlayer sees real bytes and can transition to `.readyToPlay` once it has decoded the
/// first keyframe — usually within the first 100–300 KB (~1–3 s on a slow connection).
///
/// Disk caching still happens: the full segment is written to disk after the download
/// finishes so subsequent requests are served instantly from cache.
private class SegmentStreamDelegate: NSObject, URLSessionDataDelegate {
    private let connection: NWConnection
    private let cachePath: String
    private let mediaID: String
    private let sessionKey: String
    /// Returns the raw bytes for an HTTP response status line + headers.
    private let buildHeaders: (Int, [String: String]) -> Data
    /// Sends an error response on `connection` when the download fails before any bytes
    /// were forwarded (so AVPlayer knows to stop waiting rather than hanging).
    private let sendFallbackError: (NWConnection) -> Void
    /// Removes this session from `LocalHTTPServer.streamingSessions` on completion.
    private let removeSession: (String) -> Void
    private let completion: () -> Void

    private var diskBuffer = Data()
    private var headersSent = false
    private var contentLength: Int64 = -1

    init(connection: NWConnection,
         cachePath: String,
         mediaID: String,
         sessionKey: String,
         buildHeaders: @escaping (Int, [String: String]) -> Data,
         sendFallbackError: @escaping (NWConnection) -> Void,
         removeSession: @escaping (String) -> Void,
         completion: @escaping () -> Void) {
        self.connection = connection
        self.cachePath = cachePath
        self.mediaID = mediaID
        self.sessionKey = sessionKey
        self.buildHeaders = buildHeaders
        self.sendFallbackError = sendFallbackError
        self.removeSession = removeSession
        self.completion = completion
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            sendFallbackError(connection)
            completionHandler(.cancel)
            completion()
            return
        }

        contentLength = http.expectedContentLength
        var headers: [String: String] = [
            "Content-Type": "video/mp2t",
            "Accept-Ranges": "bytes"
        ]
        if contentLength > 0 {
            headers["Content-Length"] = "\(contentLength)"
            // Content-Length known: keep-alive is valid (default in buildHTTPHeaderData)
        } else {
            // No Content-Length (IPFS chunked transfer). Use Connection: close so AVPlayer
            // uses TCP FIN to detect end-of-body instead of an ill-formed keep-alive response.
            // Without this, AVPlayerItem.status stays stuck at .unknown indefinitely.
            headers["Connection"] = "close"
        }

        // Send HTTP response headers to AVPlayer immediately.
        // AVPlayer starts reading the body stream and will render the first frame
        // as soon as it receives enough bytes to decode the initial keyframe.
        let headerData = buildHeaders(200, headers)
        connection.send(content: headerData, isComplete: false, completion: .contentProcessed { _ in })
        headersSent = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        diskBuffer.append(data)
        // NWConnection queues sends internally and delivers them in order over TCP.
        connection.send(content: data, isComplete: false, completion: .contentProcessed { _ in })
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        defer {
            removeSession(sessionKey)
            completion()
        }

        if let error = error {
            let nsError = error as NSError
            if !headersSent && nsError.code != NSURLErrorCancelled {
                // Headers never sent — tell AVPlayer the request failed so it retries.
                sendFallbackError(connection)
                BlackList.shared.recordFailure(mediaID)
            } else if headersSent {
                // Headers were already sent — close the connection so AVPlayer detects the
                // incomplete response. Without this, the connection stays open and AVPlayer
                // waits forever for more data (especially for Connection: close responses).
                connection.send(content: nil, contentContext: .defaultMessage, isComplete: true,
                               completion: .contentProcessed { _ in })
            }
            return
        }

        // Write the fully-downloaded segment to disk for instant cache hits on future requests.
        let segName = URL(fileURLWithPath: cachePath).lastPathComponent
        print("🎞️ [HLS DATA] Segment download completed mediaID: \(mediaID), segment: \(segName)")
        let cacheURL = URL(fileURLWithPath: cachePath)
        guard FileManager.default.fileExists(atPath: cacheURL.deletingLastPathComponent().path) else {
            // Signal end-of-body so AVPlayer isn't left waiting.
            connection.send(content: nil, contentContext: .defaultMessage, isComplete: true,
                           completion: .contentProcessed { _ in })
            return // Cache directory was deleted by clearPlayerForMediaID — skip write
        }
        try? diskBuffer.write(to: cacheURL)
        print("✅ [SegmentCache] Wrote \(diskBuffer.count) bytes to disk: \(cachePath) (mediaID: \(mediaID))")
        BlackList.shared.recordSuccess(mediaID)

        // Signal end of HTTP response body by sending TCP FIN.
        // All responses use Connection: close, so AVPlayer expects the TCP connection
        // to actually close after the body. Without FIN, AVPlayer waits indefinitely
        // for the connection to close, item.status stays at .unknown, and the video
        // never starts playing — even if all Content-Length bytes were received.
        connection.send(content: nil, contentContext: .defaultMessage, isComplete: true,
                       completion: .contentProcessed { _ in })
    }
}
