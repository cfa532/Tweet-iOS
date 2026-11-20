import Foundation
import Network
import UIKit

private actor LocalHTTPServerReadinessRecovery {
    private var task: Task<Bool, Never>?

    func run(_ operation: @escaping @Sendable () async -> Bool) async -> Bool {
        if let task {
            return await task.value
        }

        let newTask = Task.detached(priority: .userInitiated) {
            await operation()
        }
        task = newTask

        let result = await newTask.value
        task = nil
        return result
    }
}

// MARK: - Active Downloads Actor (Swift 6 Concurrency-Safe)
/// Tracks media IDs whose preloads were cancelled so stale AVPlayer retries can be rejected.
private actor ActiveDownloadsActor {
    /// MediaIDs whose players have been cleared. Background retries for these mediaIDs should
    /// be skipped immediately rather than restarted.
    /// Cleared when a new player is registered for the same mediaID (fresh start).
    private var cancelledMediaIDs: Set<String> = []

    func cancelAllTasks() {
        cancelledMediaIDs.removeAll()
    }

    /// Mark this mediaID as cancelled so stale AVPlayer retries do not start fresh downloads.
    func cancelTasks(for mediaID: String) {
        cancelledMediaIDs.insert(mediaID)
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

/// Ensures a pool slot is released at most once, even when both the NWConnection-dead
/// callback and the IPFS completion callback both try to call releaseSlot.
private actor SlotReleaseGuard {
    private var released = false
    func tryRelease() -> Bool {
        if released { return false }
        released = true
        return true
    }
}

public class LocalHTTPServer: @unchecked Sendable {
    public static let shared = LocalHTTPServer()
#if DEBUG && VERBOSE_VIDEO_LOGS
    fileprivate static let verboseLogsEnabled = true
#else
    fileprivate static let verboseLogsEnabled = false
#endif

    // `listener` is read/written from several unsynchronized contexts: the concurrent
    // `queue`, the listener's own `listenerQueue` (via stateUpdateHandler), and the
    // cooperative pool via Task hops. Guard it with a dedicated lock (same pattern as
    // stateLock/_isRunning below) to prevent a retain/release race that could crash or
    // wedge every video load. All accesses are quick and synchronous, so no lock is held
    // across an await (no deadlock risk).
    private var _listener: NWListener?
    private let listenerLock = NSLock()
    private var listener: NWListener? {
        get { listenerLock.lock(); defer { listenerLock.unlock() }; return _listener }
        set { listenerLock.lock(); defer { listenerLock.unlock() }; _listener = newValue }
    }
    public private(set) var port: UInt16 = 8080  // Public read, private write
    /// Truncate a mediaID to 8 chars for log readability.
    private func shortMID(_ id: String) -> String { id.count > 8 ? String(id.prefix(8)) : id }

    private func isExpectedClientClose(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == "Network.NWError" else { return false }
        // AVPlayer closes proxy responses when it switches variants, has enough
        // buffered data, or the item is replaced. These are not server failures.
        return nsError.code == 89 || nsError.code == 32 || nsError.code == 57 || nsError.code == 54
    }

    private var mediaRealURLs: [String: URL] = [:] // mediaID -> real URL
    private let mediaLock = NSLock() // Protects mediaRealURLs
    // Concurrent queue: NWConnection serializes per-connection events internally, so different
    // connections can safely process in parallel. A serial queue here bottlenecks when many
    // connections have pending send completions (e.g., large progressive downloads to paused
    // preload AVPlayers with full TCP windows), delaying new primary connections.
    private let queue = DispatchQueue(label: "LocalHTTPServer", qos: .userInitiated, attributes: .concurrent)
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

    public func isHealthyAsync(timeout: TimeInterval = 0.75) async -> Bool {
        guard let port = currentPort,
              let url = URL(string: "\(Constants.LOCAL_HOST):\(port)/health") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Ensure the localhost proxy is accepting requests before creating AVPlayerItems
    /// that point at it. After iOS background suspension, `isRunning` can briefly be
    /// stale while the NWListener is dead or rebinding; a real health check closes that
    /// race so visible videos do not attach to a black, permanently waiting player.
    public func ensureReadyForPlaybackAsync(reason: String, timeout: TimeInterval = 0.75) async -> Bool {
        if await isHealthyAsync(timeout: timeout) {
            return true
        }

        return await readinessRecovery.run { [weak self] in
            guard let self else { return false }
            print("[LocalHTTPServer] ⚠️ Proxy not healthy before \(reason); restarting before player creation")
            let didRestart = await self.forceRestartAndWaitAsync()
            guard didRestart else { return false }
            return await self.isHealthyAsync(timeout: timeout)
        }
    }

    // DEDUPLICATION: Track active downloads to prevent duplicates
    private let activeDownloadsActor = ActiveDownloadsActor()
    private let readinessRecovery = LocalHTTPServerReadinessRecovery()

    private var hlsDataTasks: [String: [UUID: URLSessionTask]] = [:]
    private let hlsDataTasksLock = NSLock()

    private let progressiveStreamChunkSize = 256 * 1024  // 256KB chunks

    // Playback priority tracking — used to classify NodeConnectionPool slots.
    private var currentPrimaryMediaID: String?
    private var currentPrimaryBufferSatisfied = false
    private let primaryMediaIDLock = NSLock()
    private let primaryPreloadGateBufferSeconds: Double = 30.0
    private let visiblePreloadGateBufferSeconds: Double = 3.0
    private var visibleMediaIDs: Set<String> = []
    private var visibleBufferSatisfiedByMediaID: [String: Bool] = [:]
    private let visibleMediaIDsLock = NSLock()

    // Connection pool for efficient HTTP requests
    private var _connectionPool: URLSession?
    private let connectionPoolLock = NSLock()

    // Network failure tracking for emergency cleanup
    private let networkFailureLock = NSLock()
    private var _consecutiveNetworkFailures: Int = 0
    private let maxConsecutiveFailures = 3 // Trigger cleanup after 3 consecutive failures
    private let initializationSnapshotLock = NSLock()
    private var appInitializedSnapshot = false
    private var appUserBaseHostSnapshot: String?
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

    private func refreshConnectionPoolForRetry(mediaID: String, reason: String) {
        connectionPoolLock.lock()
        _connectionPool?.finishTasksAndInvalidate()
        _connectionPool = nil
        connectionPoolLock.unlock()

        if LocalHTTPServer.verboseLogsEnabled {
            print("🔄 [LocalHTTPServer] Refreshed upstream connection pool for retry (\(reason)) mediaID=\(mediaID)")
        }
    }

    func updateInitializationSnapshot(isAppInitialized: Bool, appUserBaseURL: URL?) {
        initializationSnapshotLock.lock()
        appInitializedSnapshot = isAppInitialized
        appUserBaseHostSnapshot = appUserBaseURL?.host
        initializationSnapshotLock.unlock()
    }
    
    private func canBypassInitialization(for mediaID: String? = nil, url: URL? = nil) -> Bool {
        initializationSnapshotLock.lock()
        let isInitialized = appInitializedSnapshot
        let appUserBaseHost = appUserBaseHostSnapshot
        initializationSnapshotLock.unlock()

        if isInitialized {
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
        
        if let baseHost = appUserBaseHost,
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
    
    @MainActor
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
    
    @MainActor
    @objc private func handleDidEnterBackground() {
        didEnterBackground = true
        // Once the app is truly backgrounded, AppDelegate performs a deterministic
        // media cleanup and stops the server. Do not keep our own background task alive.
        endBackgroundTask()
    }
    
    @MainActor
    @objc private func handleDidBecomeActive() {
        // End background task - no longer needed
        endBackgroundTask()

        // AppDelegate drives all foreground infrastructure recovery when
        // isVideoInfrastructureReady == false.  Running verifyServerHealth concurrently
        // creates a double-restart race: both paths serialise through the server queue,
        // causing an unnecessary stop→start→stop→start sequence that delays playback
        // and can make AppDelegate's isHealthyAsync() check return false mid-restart.
        guard AppDelegate.isVideoInfrastructureReady else { return }

        // Check server health and restart if needed (only when AppDelegate is not
        // already managing a recovery cycle).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.verifyServerHealth()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            let taskID = backgroundTaskID
            backgroundTaskID = .invalid
            Task { @MainActor in
                UIApplication.shared.endBackgroundTask(taskID)
            }
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
            print("[LocalHTTPServer] ⚠️ Listener waiting with error '\(error)' – restarting")
        case .failed(let error):
            print("[LocalHTTPServer] ⚠️ Listener failed with error '\(error)' – restarting")
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
    
    /// Start the server asynchronously and WAIT until it's ready (non-blocking)
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
    
    /// Internal stop that runs on the caller's context (must be called from `queue` or restart)
    private func stopInternal(clearMediaRegistration: Bool = true) {
        self.isStopping = true
        self.listener?.stateUpdateHandler = nil
        self.listener?.newConnectionHandler = nil
        self.listener?.cancel()
        self.listener = nil
        self.isRunning = false
        self.isStarting = false

        if clearMediaRegistration {
            // Clear media registration so we don't retain metadata when server is stopped.
            mediaLock.lock()
            mediaRealURLs.removeAll()
            mediaLock.unlock()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopInternal()
            // Reset per-node connection pools so stale slot counts and suspended
            // preload waiters don't carry over into the next server session.
            NodePoolRegistry.shared.resetAllPools()
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                self.isStopping = false
            }
        }
    }

    /// Deterministically rebuild the localhost proxy after long background suspension.
    /// `isRunning` can be stale when iOS suspends the NWListener overnight, so this
    /// intentionally ignores the current flag and always tears down before rebinding.
    /// Upstream connection pools are preserved; stale connections are handled by the
    /// normal request retry/refresh path when traffic resumes.
    public func forceRestartAndWaitAsync() async -> Bool {
        print("[LocalHTTPServer] forceRestartAndWaitAsync() called")

        let didRestart = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: false)
                    return
                }

                self.stopInternal(clearMediaRegistration: false)
                self.isStopping = false

                Task {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    await self.startServer()
                    continuation.resume(returning: self.isRunning)
                }
            }
        }

        if didRestart {
            print("[LocalHTTPServer] ✅ forceRestartAndWaitAsync() SUCCESS - Server ready on port \(port)")
        } else {
            print("[LocalHTTPServer] ❌ forceRestartAndWaitAsync() FAILED - Server not running")
        }

        return didRestart
    }

    /// Stop the server during app backgrounding without leaving cleanup queued behind
    /// suspended media work. Use this only from lifecycle cleanup, not normal playback paths.
    public func stopImmediatelyForBackground() {
        resetAllConnectionsImmediately()
        clearPrimaryRestriction()

        // Preserve mediaID -> real URL registrations across background suspension.
        // Existing AVPlayerItems may still hold localhost URLs when the app resumes;
        // if this map is cleared, those requests return 404 before the player has a
        // chance to recreate/register itself.
        stopInternal(clearMediaRegistration: false)
        isStopping = false
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

    /// Synchronous version — immediately cancels all stale upstream connections.  Uses dedicated locks (not the server queue) so it cannot
    /// deadlock even if the queue is blocked by in-flight requests.
    /// Call this on foreground return BEFORE any new video loading starts.
    public func resetAllConnectionsImmediately() {
        // 1. Kill the shared connection pool (cancels all pending upstream requests)
        connectionPoolLock.lock()
        _connectionPool?.invalidateAndCancel()
        _connectionPool = nil
        connectionPoolLock.unlock()

        // 2. Cancel tracked HLS segment tasks and drop strong task references.
        hlsDataTasksLock.lock()
        let hlsTasks = hlsDataTasks.values.flatMap { $0.values }
        hlsDataTasks.removeAll()
        hlsDataTasksLock.unlock()
        hlsTasks.forEach { $0.cancel() }

        // 3. Fire-and-forget: cancel tracked active downloads
        Task { await activeDownloadsActor.cancelAllTasks() }

        // 4. Reset per-node connection pools: clears stale slot counts and resumes
        //    any suspended preload continuations so they are not permanently leaked.
        NodePoolRegistry.shared.resetAllPools()
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

            // Reset connection pool
            self.connectionPoolLock.lock()
            self._connectionPool?.invalidateAndCancel()
            self._connectionPool = nil
            self.connectionPoolLock.unlock()

            print("DEBUG: [LocalHTTPServer] Emergency cleanup completed")
        }
    }
    
    /// Cancel all active downloads (HLS segment tasks + progressive range loads)
    /// for a specific mediaID.  Call this before deleting the media's disk cache so that
    /// in-flight writes don't fail with "file not found" and stale AVPlayer retries don't
    /// spawn fresh background downloads after cancellation.
    public func cancelDownloads(for mediaID: String) {
        ProgressiveResourceLoader.cancelRequests(for: mediaID)
        cancelHLSSegmentDownloads(for: mediaID)
    }

    /// Cancel only HLS segment tasks for a mediaID. Progressive streams are deliberately
    /// left alone so partial MP4 cache can continue growing after a preload/player is released.
    public func cancelHLSSegmentDownloads(for mediaID: String) {
        Task { await activeDownloadsActor.cancelTasks(for: mediaID) }
        hlsDataTasksLock.lock()
        let tasksToCancel = hlsDataTasks.removeValue(forKey: mediaID).map { Array($0.values) } ?? []
        hlsDataTasksLock.unlock()
        tasksToCancel.forEach { $0.cancel() }
    }

    /// Clear stale preload cancellation state when a media cell becomes visible.
    /// Visible cells own their own loading path; they must not inherit a cancelled
    /// directional-preload marker from before they entered the viewport.
    public func resumeVisibleDownloads(for mediaID: String) {
        Task {
            await activeDownloadsActor.clearCancelledMediaID(mediaID)
        }
    }

    public func hasCompleteProgressiveCache(for mediaID: String) -> Bool {
        let cache = ProgressiveRangeCache(mediaID: mediaID)
        guard FileManager.default.fileExists(atPath: cache.file.path),
              let state = try? cache.snapshot(), state.isComplete else { return false }
        return isValidProgressiveCache(fileURL: cache.file)
    }

    public func progressiveCacheFileForThumbnailIfAvailable(for mediaID: String) -> URL? {
        // A file asset cannot consult our coverage index. Partial caches (including
        // legacy prefixes that may acquire distant ranges) need the resource loader.
        let cache = ProgressiveRangeCache(mediaID: mediaID)
        guard let state = try? cache.snapshot(), state.isComplete,
              FileManager.default.fileExists(atPath: cache.file.path) else { return nil }
        return cache.file
    }

    private func trackHLSDataTask(_ task: URLSessionTask, mediaID: String, taskKey: UUID) {
        guard !mediaID.isEmpty else { return }
        hlsDataTasksLock.lock()
        var tasks = hlsDataTasks[mediaID, default: [:]]
        tasks[taskKey] = task
        hlsDataTasks[mediaID] = tasks
        hlsDataTasksLock.unlock()
    }

    private func untrackHLSDataTask(mediaID: String, taskKey: UUID) {
        guard !mediaID.isEmpty else { return }
        hlsDataTasksLock.lock()
        hlsDataTasks[mediaID]?.removeValue(forKey: taskKey)
        if hlsDataTasks[mediaID]?.isEmpty == true {
            hlsDataTasks.removeValue(forKey: mediaID)
        }
        hlsDataTasksLock.unlock()
    }

    /// Returns true if any HLS segment download is currently in-flight for the given mediaID.
    /// Synchronous — safe to call from the main thread (uses NSLock, not actor).
    /// Used by the duration-mismatch timer to avoid treating a quality-switch stall as a finished video.
    func hasActiveHLSSegmentDownloads(for mediaID: String) -> Bool {
        hlsDataTasksLock.lock()
        defer { hlsDataTasksLock.unlock() }
        return hlsDataTasks[mediaID]?.values.contains { task in
            relativeHLSSegmentPath(for: task, mediaID: mediaID) != nil
        } ?? false
    }

    private func relativeHLSSegmentPath(for task: URLSessionTask, mediaID: String) -> String? {
        relativeHLSSegmentPath(from: task.currentRequest?.url ?? task.originalRequest?.url, mediaID: mediaID)
    }

    private func relativeHLSSegmentPath(from url: URL?, mediaID: String) -> String? {
        guard let path = url?.path, path.hasSuffix(".ts") else { return nil }
        return relativeHLSPath(from: url, mediaID: mediaID)
    }

    private func relativeHLSPath(from url: URL?, mediaID: String) -> String? {
        guard let path = url?.path else { return nil }
        let prefix = "/ipfs/\(mediaID)/"
        if let range = path.range(of: prefix) {
            return String(path[range.upperBound...])
        }
        let mmPrefix = "/mm/\(mediaID)/"
        if let range = path.range(of: mmPrefix) {
            return String(path[range.upperBound...])
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func hlsLogPath(for url: URL, mediaID: String) -> String {
        relativeHLSPath(from: url, mediaID: mediaID) ?? url.lastPathComponent
    }

    private func duplicateSegmentWaitAttempts(for priority: NodeDownloadPriority) -> Int {
        switch priority {
        case .primary:
            return 1200 // 5 minutes, matching the URLSession resource timeout.
        case .visible:
            return 240 // 60 seconds: visible video should not fail from normal IPFS slowness.
        case .preload:
            return 40 // 10 seconds: keep preload cheap.
        }
    }

    private func duplicateSegmentUpstreamLimit(for priority: NodeDownloadPriority) -> Int {
        switch priority {
        case .primary:
            return 2
        case .visible, .preload:
            return 1
        }
    }

    private func activeHLSSegmentDownloadCount(for mediaID: String, relativePath: String) -> Int {
        hlsDataTasksLock.lock()
        defer { hlsDataTasksLock.unlock() }
        return hlsDataTasks[mediaID]?.values.filter { task in
            relativeHLSSegmentPath(for: task, mediaID: mediaID) == relativePath
        }.count ?? 0
    }

    private func waitForActiveHLSSegmentToCache(
        mediaID: String,
        relativePath: String,
        cachePath: String,
        connection: NWConnection,
        method: String,
        waitAttempts: Int,
        reason: String
    ) async -> (served: Bool, stillActive: Bool) {
        for _ in 0..<waitAttempts {
            try? await Task.sleep(nanoseconds: 250_000_000)
            switch connection.state { case .cancelled, .failed: return (true, true); default: break }

            if isUsableCachedFile(atPath: cachePath) {
                print("🎞️ [HLS SEGMENT] \(shortMID(mediaID)) served cached \(relativePath) after waiting for \(reason)")
                autoreleasepool {
                    serveFile(path: cachePath, connection: connection, method: method)
                }
                return (true, false)
            }

            if !hasActiveHLSSegmentDownload(for: mediaID, relativePath: relativePath) {
                return (false, false)
            }
        }

        return (false, hasActiveHLSSegmentDownload(for: mediaID, relativePath: relativePath))
    }

    private func hasActiveHLSSegmentDownload(for mediaID: String, relativePath: String) -> Bool {
        hlsDataTasksLock.lock()
        defer { hlsDataTasksLock.unlock() }
        return hlsDataTasks[mediaID]?.values.contains { task in
            relativeHLSSegmentPath(for: task, mediaID: mediaID) == relativePath
        } ?? false
    }

    private func hasActiveHLSDownload(for mediaID: String, relativePath: String) -> Bool {
        hlsDataTasksLock.lock()
        defer { hlsDataTasksLock.unlock() }
        return hlsDataTasks[mediaID]?.values.contains { task in
            relativeHLSPath(from: task.currentRequest?.url ?? task.originalRequest?.url, mediaID: mediaID) == relativePath
        } ?? false
    }

    /// Returns the relative paths of all in-flight HLS segments for a mediaID (e.g. ["480p/segment001.ts"]).
    /// Used by the duration-mismatch timer to log exactly which segment is blocking playback.
    func activeHLSSegmentKeys(for mediaID: String) -> [String] {
        hlsDataTasksLock.lock()
        defer { hlsDataTasksLock.unlock() }
        return hlsDataTasks[mediaID]?.values.compactMap { task in
            relativeHLSSegmentPath(for: task, mediaID: mediaID)
        }.sorted() ?? []
    }

    /// Returns true when a segment that AVPlayer is still waiting on has already
    /// landed in the disk cache. In that state the existing AVPlayerItem can stay
    /// wedged on its old request, while a fresh item will read the cached segment.
    func hasCachedActiveHLSSegment(for mediaID: String) -> Bool {
        hlsDataTasksLock.lock()
        let tasks: [URLSessionTask] = hlsDataTasks[mediaID].map { Array($0.values) } ?? []
        hlsDataTasksLock.unlock()

        return tasks.contains { task in
            guard relativeHLSSegmentPath(for: task, mediaID: mediaID) != nil,
                  let url = task.currentRequest?.url ?? task.originalRequest?.url else {
                return false
            }
            return isUsableCachedFile(atPath: getCachePath(for: url, mediaID: mediaID))
        }
    }

    /// Set the current primary mediaID so its segment requests bypass the concurrent download limit.
    /// Called immediately when the coordinator selects a primary (before the 1s cancel-others debounce).
    public func setPrimaryMediaID(_ mediaID: String?) {
        primaryMediaIDLock.lock()
        let previousPrimary = currentPrimaryMediaID
        currentPrimaryMediaID = mediaID
        if mediaID != previousPrimary {
            currentPrimaryBufferSatisfied = false
        }
        primaryMediaIDLock.unlock()
        if let mediaID {
            // Clear cancelled state so a preloaded-then-cancelled player can download once primary.
            Task { await activeDownloadsActor.clearCancelledMediaID(mediaID) }
            if mediaID != previousPrimary {
                NodePoolRegistry.shared.forceReleaseLowerPriority(primaryMediaID: mediaID)
            }
        }
        recomputePreloadPermission()
    }

    /// Clear primary restriction so all videos can download (e.g., when all playback stops).
    public func clearPrimaryRestriction() {
        primaryMediaIDLock.lock()
        currentPrimaryMediaID = nil
        currentPrimaryBufferSatisfied = false
        primaryMediaIDLock.unlock()
        NodePoolRegistry.shared.forceReleaseLowerPriority(primaryMediaID: nil)
        recomputePreloadPermission()
    }

    /// Clear the cancelled state for a mediaID so the proxy serves fresh downloads.
    public func clearCancelledState(for mediaID: String) {
        Task { await activeDownloadsActor.clearCancelledMediaID(mediaID) }
    }

    /// Returns true only if mediaID matches the current primary.
    /// When no primary is set, nothing is primary — all downloads respect the pool cap.
    private func isCurrentPrimary(_ mediaID: String) -> Bool {
        primaryMediaIDLock.lock()
        defer { primaryMediaIDLock.unlock() }
        guard let primary = currentPrimaryMediaID else { return false }
        return mediaID == primary
    }

    public func updateMediaBufferHealth(mediaID: String, bufferedAhead: Double) {
        var changed = false
        primaryMediaIDLock.lock()
        if currentPrimaryMediaID == mediaID {
            let satisfied = bufferedAhead >= primaryPreloadGateBufferSeconds
            if currentPrimaryBufferSatisfied != satisfied {
                currentPrimaryBufferSatisfied = satisfied
                changed = true
                print("🎰 [POOL] primary \(shortMID(mediaID)) preloadGate=\(satisfied) buffered=\(String(format: "%.1f", bufferedAhead))s")
            }
        }
        primaryMediaIDLock.unlock()

        visibleMediaIDsLock.lock()
        if visibleMediaIDs.contains(mediaID) {
            let satisfied = bufferedAhead >= visiblePreloadGateBufferSeconds
            if visibleBufferSatisfiedByMediaID[mediaID] != satisfied {
                visibleBufferSatisfiedByMediaID[mediaID] = satisfied
                changed = true
                print("🎰 [POOL] visible \(shortMID(mediaID)) preloadGate=\(satisfied) buffered=\(String(format: "%.1f", bufferedAhead))s")
            }
        }
        visibleMediaIDsLock.unlock()

        if changed {
            recomputePreloadPermission()
        }
    }

    public func markMediaVisible(_ mediaID: String) {
        visibleMediaIDsLock.lock()
        visibleMediaIDs.insert(mediaID)
        visibleBufferSatisfiedByMediaID[mediaID] = false
        visibleMediaIDsLock.unlock()
        Task { await activeDownloadsActor.clearCancelledMediaID(mediaID) }
        recomputePreloadPermission()
    }

    public func markMediaNotVisible(_ mediaID: String) {
        visibleMediaIDsLock.lock()
        visibleMediaIDs.remove(mediaID)
        visibleBufferSatisfiedByMediaID.removeValue(forKey: mediaID)
        visibleMediaIDsLock.unlock()
        recomputePreloadPermission()
    }

    private func isMediaVisible(_ mediaID: String) -> Bool {
        visibleMediaIDsLock.lock()
        defer { visibleMediaIDsLock.unlock() }
        return visibleMediaIDs.contains(mediaID)
    }

    /// Shared scheduling policy for the HTTP HLS path and direct progressive loader.
    func downloadPriority(for mediaID: String) -> NodeDownloadPriority {
        if isCurrentPrimary(mediaID) {
            return .primary
        }
        if isMediaVisible(mediaID) {
            return .visible
        }
        return .preload
    }

    private func recomputePreloadPermission() {
        primaryMediaIDLock.lock()
        let primary = currentPrimaryMediaID
        let primarySatisfied = currentPrimaryBufferSatisfied
        primaryMediaIDLock.unlock()

        visibleMediaIDsLock.lock()
        let visible = visibleMediaIDs
        let visibleSatisfiedByMediaID = visibleBufferSatisfiedByMediaID
        visibleMediaIDsLock.unlock()

        let visibleNonPrimary = visible.filter { $0 != primary }
        let visibleNonPrimarySatisfied = visibleNonPrimary.allSatisfy {
            visibleSatisfiedByMediaID[$0] == true
        }
        let preloadsAllowed = (primary == nil || primarySatisfied) && visibleNonPrimarySatisfied
        NodePoolRegistry.shared.setPreloadsAllowed(preloadsAllowed)
    }

    /// Thread-safe lookup of a registered real URL — safe to call from async contexts.
    private func getRealURL(for mediaID: String) -> URL? {
        mediaLock.lock()
        defer { mediaLock.unlock() }
        return mediaRealURLs[mediaID]
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
        if realURL.pathExtension.lowercased() == "m3u8" {
            print("📄 [HLS LOCAL] \(shortMID(mediaID)) registered \(realURL.lastPathComponent) -> \(localhostURL.path)")
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
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
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

            // NWListener and the timeout task can race; resume the continuation exactly once.
            final class ResumeOnceBox: @unchecked Sendable {
                private let lock = NSLock()
                private var hasResumed = false
                private let continuation: CheckedContinuation<Bool, Never>

                init(_ continuation: CheckedContinuation<Bool, Never>) {
                    self.continuation = continuation
                }

                func resume(_ result: Bool) {
                    lock.lock()
                    guard !hasResumed else {
                        lock.unlock()
                        return
                    }
                    hasResumed = true
                    lock.unlock()
                    continuation.resume(returning: result)
                }
            }
            let resumeOnce = ResumeOnceBox(continuation)

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
                        resumeOnce.resume(false)
                        return
                    }

                    switch state {
                    case .ready:
                        timeoutTaskBox.cancel()
                        self.isRunning = true
                        // Save successful port to preferences
                        Task { @MainActor in
                            PreferenceHelper().setLocalHTTPServerPort(tryPort)
                        }
                        // Store the listener
                        self.listener = listener
                        resumeOnce.resume(true)
                    case .failed, .cancelled:
                        timeoutTaskBox.cancel()
                        self.isRunning = false
                        listener.cancel()
                        resumeOnce.resume(false)
                    case .waiting, .setup:
                        break
                    @unknown default:
                        timeoutTaskBox.cancel()
                        self.isRunning = false
                        listener.cancel()
                        resumeOnce.resume(false)
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
                        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s timeout
                        // If we get here, timeout occurred - cancel listener
                        listener.cancel()
                        resumeOnce.resume(false)
                    } catch {
                        // Task was cancelled, ignore
                    }
                }
                timeoutTaskBox.set(timeoutTask)

            } catch {
                resumeOnce.resume(false)
            }
        }
    }
    
    // REMOVED: isPortAvailable() function - no longer needed
    // We now test ports by attempting to bind directly, which avoids the port release timing issue
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveNextRequest(connection: connection)
    }

    // Purely callback-based — no withCheckedContinuation, no cooperative thread blocked.
    // When stopInternal() cancels the listener, outstanding NWConnection receive callbacks
    // fire with an error and fall through to connection.cancel(); nothing can be leaked.
    private func receiveNextRequest(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
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

                // Only log unexpected errors (suppress connection-reset 54 and operation-canceled 89)
                if nwCode != 54 && nwCode != 89 {
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
                // Dispatch async request handling without holding a continuation.
                // With Connection: close each NWConnection is one request-response cycle;
                // sendResponse/serveFile/stream handlers manage their own TCP FIN.
                Task {
                    await self.handleRequest(request, connection: connection) { }
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                // No data yet — register next read without recursing on the stack.
                // This call returns immediately; the callback fires later on queue.
                self.receiveNextRequest(connection: connection)
            }
        }
    }
    
    private func handleRequest(_ request: String, connection: NWConnection, completion: @escaping () -> Void) async {
        guard isRunning else {
            connection.cancel()
            completion()
            return
        }

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
            await handleGetRequest(path: path, method: method, connection: connection, completion: completion)
        } else {
            sendResponse(connection: connection, statusCode: 405, headers: [:], body: nil)
            completion()
        }
    }
    
    private func handleGetRequest(path: String, method: String, connection: NWConnection, completion: @escaping () -> Void) async {
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
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let mediaDir = cacheDir.appendingPathComponent(mediaID)

        // The proxy serves HLS only: /ipfs/<mediaID>/<playlist or segment>. Progressive
        // videos load through ProgressiveVideoAsset's resource loader and never reach it.
        guard pathComponents.count > 2 else {
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
            completion()
            return
        }

        // Extract file path after /ipfs/mediaID/ for cache lookup (HLS playlists/segments)
        let filePathComponents = pathComponents[2...].joined(separator: "/")
        let potentialCachePath = mediaDir.appendingPathComponent(filePathComponents)
        
        if isUsableCachedFile(atPath: potentialCachePath.path) {
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
                        print("📄 [HLS LOCAL] \(shortMID(mediaID)) served cached \(filePathComponents) (\(modifiedData.count) bytes)")
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
        
        // Playlists and MPEG-TS segments are the only HLS files the app's clients produce
        // (every encoder uses -hls_segment_type mpegts).
        if relativePath.hasSuffix(".m3u8") {
            await handlePlaylistRequest(fullRealURL: fullRealURL, mediaID: mediaID, connection: connection, method: method)
        } else if relativePath.hasSuffix(".ts") {
            await handleSegmentRequest(fullRealURL: fullRealURL, mediaID: mediaID, connection: connection, method: method)
        } else {
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
        }
        completion()
    }

    private func serveCachedPlaylistIfAvailable(cachePath: String, mediaID: String, baseURL: URL, logPath: String, connection: NWConnection) -> Bool {
        guard isUsableCachedFile(atPath: cachePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
              let playlistString = String(data: data, encoding: .utf8) else {
            return false
        }

        let modifiedPlaylist = rewritePlaylistURLs(playlistString, mediaID: mediaID, baseURL: baseURL)
        guard let modifiedData = modifiedPlaylist.data(using: .utf8) else {
            return false
        }

        let headers: [String: String] = [
            "Content-Type": "application/vnd.apple.mpegurl",
            "Content-Length": "\(modifiedData.count)",
            "Accept-Ranges": "bytes"
        ]
        print("📄 [HLS LOCAL] \(shortMID(mediaID)) served cached \(logPath) (\(modifiedData.count) bytes)")
        sendResponse(connection: connection, statusCode: 200, headers: headers, body: modifiedData)
        return true
    }

    private func handlePlaylistRequest(fullRealURL: URL, mediaID: String, connection: NWConnection, method: String) async {
        let cachePath = getCachePath(for: fullRealURL, mediaID: mediaID)
        let isCached = isUsableCachedFile(atPath: cachePath)
        let logPath = hlsLogPath(for: fullRealURL, mediaID: mediaID)

        // Check cache first
        if isCached {
            if serveCachedPlaylistIfAvailable(cachePath: cachePath, mediaID: mediaID, baseURL: fullRealURL, logPath: logPath, connection: connection) {
                return
            }
            
            // Fallback: cache file is unreadable (corrupted or filesystem error).
            // Delete the bad file and re-fetch fresh so ENDLIST injection always applies.
            try? FileManager.default.removeItem(atPath: cachePath)
            fetchAndServe(url: fullRealURL, cachePath: cachePath, connection: connection, method: method, completion: nil)
            return
        }

        if hasActiveHLSDownload(for: mediaID, relativePath: logPath) {
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                switch connection.state { case .cancelled, .failed: return; default: break }
                if serveCachedPlaylistIfAvailable(cachePath: cachePath, mediaID: mediaID, baseURL: fullRealURL, logPath: logPath, connection: connection) {
                    return
                }
                if !hasActiveHLSDownload(for: mediaID, relativePath: logPath) {
                    break
                }
            }
        }
        
        // Not cached - fetch from real server.
        print("📄 [HLS LOCAL] \(shortMID(mediaID)) fetching \(logPath) from upstream")
        fetchAndServe(url: fullRealURL, cachePath: cachePath, connection: connection, method: method, completion: nil)
    }
    
    private func handleSegmentRequest(fullRealURL: URL, mediaID: String, connection: NWConnection, method: String) async {
        let cachePath = getCachePath(for: fullRealURL, mediaID: mediaID)
        let logPath = hlsLogPath(for: fullRealURL, mediaID: mediaID)

        // Check cache first — always serve cached content regardless of concurrency
        if isUsableCachedFile(atPath: cachePath) {
            print("🎞️ [HLS SEGMENT] \(shortMID(mediaID)) served cached \(logPath)")
            autoreleasepool {
                serveFile(path: cachePath, connection: connection, method: method)
            }
            return
        }

        // Guard: if this mediaID was cleared by the priority system, reject the segment request
        // immediately rather than starting a new IPFS download. Prevents the retry storm where
        // a cancelled non-primary AVPlayer keeps reconnecting (each failed connection triggers
        // an immediate AVPlayer retry). The short connection.cancel() here puts AVPlayer into
        // its built-in exponential backoff rather than an infinite fast-retry loop.
        // Note: clearCancelledMediaID is called when a fresh player is registered (on becoming
        // primary), so this guard only fires while the mediaID remains non-primary.
        if await activeDownloadsActor.isMediaIDCancelled(mediaID) {
            print("🎞️ [HLS SEGMENT] \(shortMID(mediaID)) rejected \(logPath) because media is cancelled")
            sendResponse(
                connection: connection,
                statusCode: 410,
                headers: [
                    "Content-Length": "0",
                    "Cache-Control": "no-store"
                ],
                body: nil
            )
            return
        }

        var requestPriority = downloadPriority(for: mediaID)

        if activeHLSSegmentDownloadCount(for: mediaID, relativePath: logPath) >= duplicateSegmentUpstreamLimit(for: requestPriority) {
            // AVPlayer can legitimately open duplicate requests for the same segment.
            // Primary may race two upstream fetches for the same segment; lower-priority
            // work coalesces after one so preloads cannot multiply IPFS pressure.
            let waitResult = await waitForActiveHLSSegmentToCache(
                mediaID: mediaID,
                relativePath: logPath,
                cachePath: cachePath,
                connection: connection,
                method: method,
                waitAttempts: duplicateSegmentWaitAttempts(for: requestPriority),
                reason: "duplicate fetch"
            )
            if waitResult.served {
                return
            }

            if waitResult.stillActive {
                print("🎞️ [HLS SEGMENT] \(shortMID(mediaID)) closed duplicate \(logPath) after waiting for active fetch")
                connection.cancel()
                return
            }
        }

        // Acquire a slot in the per-node connection pool before starting the IPFS download.
        // Primary bypasses the preload cap, but still honors its own segment cap.
        let nodeHost = NodePoolRegistry.nodeHost(from: fullRealURL)
        let pool = NodePoolRegistry.shared.pool(for: nodeHost)
        requestPriority = downloadPriority(for: mediaID)
        var lease = await pool.acquireSlot(mediaID: mediaID, priority: requestPriority, primarySlotCap: 3)
        // Poll when the cap is full. Primary bypasses the preload cap, but still honors
        // its own HLS segment cap so startup cannot launch parallel segment downloads.
        // Visible non-primary video gets more patience than off-screen preload so
        // AVPlayer does not treat normal backpressure as a corrupt HLS segment.
        if lease == nil {
            for attempt in 0..<240 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                switch connection.state { case .cancelled, .failed: return; default: break }
                requestPriority = downloadPriority(for: mediaID)
                lease = await pool.acquireSlot(mediaID: mediaID, priority: requestPriority, primarySlotCap: 3)
                if lease != nil { break }
                let shouldStopWaiting: Bool
                switch requestPriority {
                case .primary:
                    shouldStopWaiting = false
                case .visible:
                    shouldStopWaiting = attempt >= 59
                case .preload:
                    shouldStopWaiting = attempt >= 9
                }
                if shouldStopWaiting { break }
            }
        }
        guard let lease else {
            print("🎞️ [HLS SEGMENT] \(shortMID(mediaID)) rejected \(logPath) because no download slot was available")
            connection.cancel()
            return
        }

        // Another independent primary request may have populated the cache while
        // this request waited for the segment slot. Re-check before going upstream.
        if isUsableCachedFile(atPath: cachePath) {
            await pool.releaseSlot(lease)
            print("🎞️ [HLS SEGMENT] \(shortMID(mediaID)) served cached \(logPath) after waiting for segment slot")
            autoreleasepool {
                serveFile(path: cachePath, connection: connection, method: method)
            }
            return
        }

        requestPriority = downloadPriority(for: mediaID)
        if activeHLSSegmentDownloadCount(for: mediaID, relativePath: logPath) >= duplicateSegmentUpstreamLimit(for: requestPriority) {
            let waitResult = await waitForActiveHLSSegmentToCache(
                mediaID: mediaID,
                relativePath: logPath,
                cachePath: cachePath,
                connection: connection,
                method: method,
                waitAttempts: duplicateSegmentWaitAttempts(for: requestPriority),
                reason: "segment slot wait"
            )
            if waitResult.served {
                await pool.releaseSlot(lease)
                return
            }
            if waitResult.stillActive {
                await pool.releaseSlot(lease)
                print("🎞️ [HLS SEGMENT] \(shortMID(mediaID)) closed duplicate \(logPath) after segment slot wait")
                connection.cancel()
                return
            }
        }

        // SlotReleaseGuard prevents a double-release: both onConnectionDead (NWConnection closes
        // during bitrate switch) and the IPFS completion callback call releaseSlot. Without
        // the guard, if a new segment for the same mediaID acquired a slot between the two
        // fires, the second release would decrement the wrong slot count.
        let slotGuard = SlotReleaseGuard()

        print("🎞️ [HLS SEGMENT] \(shortMID(mediaID)) fetching \(logPath) from upstream")
        let releaseSegmentSlot: @Sendable () -> Void = {
            Task {
                if await slotGuard.tryRelease() {
                    await pool.releaseSlot(lease)
                }
            }
        }
        fetchAndServe(
            url: fullRealURL,
            cachePath: cachePath,
            connection: connection,
            method: method,
            onConnectionDead: releaseSegmentSlot,
            completion: releaseSegmentSlot
        )
    }
    
    // MARK: - Progressive Video Cache Helpers
    
    private func streamFileChunks(
        connection: NWConnection,
        fileHandle: FileHandle,
        remaining: Int64,
        completion: (@Sendable () -> Void)? = nil
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
                completion?()
                return
            }
            
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    if self?.isExpectedClientClose(error) != true {
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
    
    private func fetchAndServe(url: URL, cachePath: String, connection: NWConnection, method: String, onConnectionDead: (@Sendable () -> Void)? = nil, completion: (@Sendable () -> Void)? = nil) {
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

        let maxAttempts = isSegment ? 3 : 1  // Retry segment downloads (like ExoPlayer)
        if isSegment {
            fetchSegmentWithRetry(
                url: url,
                cachePath: cachePath,
                connection: connection,
                method: method,
                mediaID: mediaID,
                attempt: 1,
                maxAttempts: maxAttempts,
                onConnectionDead: onConnectionDead,
                completion: completion
            )
            return
        }
        fetchWithRetry(url: url, cachePath: cachePath, connection: connection, method: method, mediaID: mediaID, attempt: 1, maxAttempts: maxAttempts, completion: completion)
    }

    private func fetchSegmentWithRetry(
        url: URL,
        cachePath: String,
        connection: NWConnection,
        method: String,
        mediaID: String,
        attempt: Int,
        maxAttempts: Int,
        onConnectionDead: (@Sendable () -> Void)?,
        completion: (@Sendable () -> Void)?
    ) {
        let taskKey = UUID()
        let logPath = hlsLogPath(for: url, mediaID: mediaID)
        let task = connectionPool.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self else {
                completion?()
                return
            }
            self.untrackHLSDataTask(mediaID: mediaID, taskKey: taskKey)

            if let error = error {
                let nsError = error as NSError
                let isRetryable = nsError.code == NSURLErrorTimedOut ||
                                  nsError.code == NSURLErrorNetworkConnectionLost ||
                                  nsError.code == NSURLErrorNotConnectedToInternet

                if nsError.code == NSURLErrorCancelled {
                    completion?()
                    return
                }

                if nsError.code != NSURLErrorCancelled, attempt < maxAttempts, isRetryable {
                    let delay = Double(attempt)
                    if LocalHTTPServer.verboseLogsEnabled {
                        print("🔄 [LocalHTTPServer] Segment retry \(attempt)/\(maxAttempts - 1) for \(logPath) after \(delay)s")
                    }
                    self.refreshConnectionPoolForRetry(mediaID: mediaID, reason: "\(nsError.domain) \(nsError.code)")
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.fetchSegmentWithRetry(
                            url: url,
                            cachePath: cachePath,
                            connection: connection,
                            method: method,
                            mediaID: mediaID,
                            attempt: attempt + 1,
                            maxAttempts: maxAttempts,
                            onConnectionDead: onConnectionDead,
                            completion: completion
                        )
                    }
                    return
                }

                if !mediaID.isEmpty, nsError.code != NSURLErrorCancelled {
                    BlackList.shared.recordFailure(mediaID)
                }
                print("❌ [HLS SEGMENT] \(self.shortMID(mediaID)) \(logPath) network error \(nsError.domain) \(nsError.code)")
                self.sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil, completion: completion)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                if !mediaID.isEmpty {
                    BlackList.shared.recordFailure(mediaID)
                }
                print("❌ [HLS SEGMENT] \(self.shortMID(mediaID)) \(logPath) missing HTTP response")
                self.sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil, completion: completion)
                return
            }

            if httpResponse.statusCode >= 500, attempt < maxAttempts {
                let delay = Double(attempt)
                if LocalHTTPServer.verboseLogsEnabled {
                    print("🔄 [LocalHTTPServer] Segment retry \(attempt)/\(maxAttempts - 1) for \(logPath) (HTTP \(httpResponse.statusCode))")
                }
                self.refreshConnectionPoolForRetry(mediaID: mediaID, reason: "HTTP \(httpResponse.statusCode)")
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    self.fetchSegmentWithRetry(
                        url: url,
                        cachePath: cachePath,
                        connection: connection,
                        method: method,
                        mediaID: mediaID,
                        attempt: attempt + 1,
                        maxAttempts: maxAttempts,
                        onConnectionDead: onConnectionDead,
                        completion: completion
                    )
                }
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                if !mediaID.isEmpty {
                    BlackList.shared.recordFailure(mediaID)
                }
                print("❌ [HLS SEGMENT] \(self.shortMID(mediaID)) \(logPath) upstream HTTP \(httpResponse.statusCode)")
                self.sendResponse(connection: connection, statusCode: httpResponse.statusCode, headers: [:], body: nil, completion: completion)
                return
            }

            guard let tempURL = tempURL else {
                if !mediaID.isEmpty {
                    BlackList.shared.recordFailure(mediaID)
                }
                print("❌ [HLS SEGMENT] \(self.shortMID(mediaID)) \(logPath) missing temp file")
                self.sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil, completion: completion)
                return
            }

            let cacheURL = URL(fileURLWithPath: cachePath)
            guard FileManager.default.fileExists(atPath: cacheURL.deletingLastPathComponent().path) else {
                completion?()
                return
            }

            if self.isUsableCachedFile(atPath: cachePath) {
                try? FileManager.default.removeItem(at: tempURL)
                let attributes = try? FileManager.default.attributesOfItem(atPath: cachePath)
                let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                let headers: [String: String] = [
                    "Content-Type": self.getMimeType(for: cachePath),
                    "Content-Length": "\(fileSize)",
                    "Accept-Ranges": "bytes"
                ]
                print("🎞️ [HLS SEGMENT] \(self.shortMID(mediaID)) served cached \(logPath) after independent primary fetch")
                self.streamFileResponse(
                    connection: connection,
                    statusCode: 200,
                    headers: headers,
                    fileURL: cacheURL,
                    fileSize: fileSize,
                    method: method,
                    onConnectionDead: onConnectionDead,
                    completion: completion
                )
                return
            }

            do {
                self.removeCachedFileCompleteMarker(atPath: cachePath)
                try? FileManager.default.removeItem(at: cacheURL)
                do {
                    try FileManager.default.moveItem(at: tempURL, to: cacheURL)
                } catch {
                    try FileManager.default.copyItem(at: tempURL, to: cacheURL)
                    try? FileManager.default.removeItem(at: tempURL)
                }

                let attributes = try FileManager.default.attributesOfItem(atPath: cachePath)
                let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                guard fileSize > 0 else {
                    try? FileManager.default.removeItem(at: cacheURL)
                    self.removeCachedFileCompleteMarker(atPath: cachePath)
                    if !mediaID.isEmpty {
                        BlackList.shared.recordFailure(mediaID)
                    }
                    print("❌ [HLS SEGMENT] \(self.shortMID(mediaID)) \(logPath) upstream returned empty file")
                    self.sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil, completion: completion)
                    return
                }

                try? FileManager.default.removeItem(atPath: "\(cachePath).part")
                self.markCachedFileCompleteIfNeeded(atPath: cachePath)

                if !mediaID.isEmpty {
                    BlackList.shared.recordSuccess(mediaID)
                }

                let headers: [String: String] = [
                    "Content-Type": self.getMimeType(for: cachePath),
                    "Content-Length": "\(fileSize)",
                    "Accept-Ranges": "bytes"
                ]

                print("✅ [HLS SEGMENT] \(self.shortMID(mediaID)) served \(logPath) from upstream (\(fileSize) bytes)")
                self.streamFileResponse(
                    connection: connection,
                    statusCode: 200,
                    headers: headers,
                    fileURL: cacheURL,
                    fileSize: fileSize,
                    method: method,
                    onConnectionDead: onConnectionDead,
                    completion: completion
                )
            } catch {
                if !mediaID.isEmpty {
                    BlackList.shared.recordFailure(mediaID)
                }
                print("⚠️ [HLS SEGMENT] \(self.shortMID(mediaID)) failed to cache \(logPath): \(error.localizedDescription)")
                self.sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil, completion: completion)
            }
        }
        trackHLSDataTask(task, mediaID: mediaID, taskKey: taskKey)
        task.resume()
    }

    private func fetchWithRetry(url: URL, cachePath: String, connection: NWConnection, method: String, mediaID: String, attempt: Int, maxAttempts: Int, completion: (@Sendable () -> Void)?) {

        let taskKey = UUID()
        let isPlaylist = cachePath.hasSuffix(".m3u8")
        let isSegment = cachePath.hasSuffix(".ts")
        let logPath = hlsLogPath(for: url, mediaID: mediaID)
        let task = connectionPool.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            self.untrackHLSDataTask(mediaID: mediaID, taskKey: taskKey)

            // MEMORY FIX: Use autoreleasepool for large segment downloads (4-5MB each)
            autoreleasepool {
                // Check for retryable errors (timeout, network lost, etc.)
                if let error = error {
                    let nsError = error as NSError
                    let isRetryable = nsError.code == NSURLErrorTimedOut ||
                                      nsError.code == NSURLErrorNetworkConnectionLost ||
                                      nsError.code == NSURLErrorNotConnectedToInternet

                    if nsError.code == NSURLErrorCancelled {
                        completion?()
                        return
                    }

                    if nsError.code != NSURLErrorCancelled, attempt < maxAttempts, isRetryable {
                        let delay = Double(attempt) // 1s, 2s backoff
                        if LocalHTTPServer.verboseLogsEnabled {
                            print("🔄 [LocalHTTPServer] Retry \(attempt)/\(maxAttempts - 1) for \(logPath) after \(delay)s")
                        }
                        self.refreshConnectionPoolForRetry(mediaID: mediaID, reason: "\(nsError.domain) \(nsError.code)")
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                            self.fetchWithRetry(url: url, cachePath: cachePath, connection: connection, method: method, mediaID: mediaID, attempt: attempt + 1, maxAttempts: maxAttempts, completion: completion)
                        }
                        return
                    }

                    // Final failure — record and respond
                    if !mediaID.isEmpty, nsError.code != NSURLErrorCancelled {
                        BlackList.shared.recordFailure(mediaID)
                    }
                    if isPlaylist || isSegment {
                        print("❌ [HLS LOCAL] \(self.shortMID(mediaID)) \(logPath) network error \(nsError.domain) \(nsError.code)")
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
                    if isPlaylist || isSegment {
                        print("❌ [HLS LOCAL] \(self.shortMID(mediaID)) \(logPath) missing HTTP response")
                    }
                    self.sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
                    completion?()
                    return
                }

                // Retry on server errors (5xx)
                if httpResponse.statusCode >= 500, attempt < maxAttempts {
                    let delay = Double(attempt)
                    if LocalHTTPServer.verboseLogsEnabled {
                        print("🔄 [LocalHTTPServer] Retry \(attempt)/\(maxAttempts - 1) for \(logPath) (HTTP \(httpResponse.statusCode))")
                    }
                    self.refreshConnectionPoolForRetry(mediaID: mediaID, reason: "HTTP \(httpResponse.statusCode)")
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.fetchWithRetry(url: url, cachePath: cachePath, connection: connection, method: method, mediaID: mediaID, attempt: attempt + 1, maxAttempts: maxAttempts, completion: completion)
                    }
                    return
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    if !mediaID.isEmpty {
                        BlackList.shared.recordFailure(mediaID)
                    }
                    if isPlaylist || isSegment {
                        print("❌ [HLS LOCAL] \(self.shortMID(mediaID)) \(logPath) upstream HTTP \(httpResponse.statusCode)")
                    }
                    self.sendResponse(connection: connection, statusCode: httpResponse.statusCode, headers: [:], body: nil)
                    completion?()
                    return
                }

                guard let data = data, !data.isEmpty else {
                    if !mediaID.isEmpty {
                        BlackList.shared.recordFailure(mediaID)
                    }
                    if isPlaylist || isSegment {
                        print("❌ [HLS LOCAL] \(self.shortMID(mediaID)) \(logPath) upstream returned empty data")
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
                // and the next AVPlayer request can use the cache immediately.
                // autoreleasepool still protects memory during write
                let cacheURL = URL(fileURLWithPath: cachePath)
                // Skip silently if the parent directory was deleted (clearPlayerForMediaID)
                // while this download was in-flight — avoids spurious "file not found" warnings.
                    guard FileManager.default.fileExists(atPath: cacheURL.deletingLastPathComponent().path) else {
                        completion?()
                        return
                    }
                    do {
                        self.removeCachedFileCompleteMarker(atPath: cachePath)
                        try dataToCache.write(to: cacheURL, options: .atomic)
                        if cachePath.hasSuffix(".ts") {
                            try? FileManager.default.removeItem(atPath: "\(cachePath).part")
                        }
                        self.markCachedFileCompleteIfNeeded(atPath: cachePath)
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
                    if isPlaylist {
                        print("✅ [HLS LOCAL] \(self.shortMID(mediaID)) served \(logPath) from upstream (\(finalData.count) bytes)")
                    } else if isSegment {
                        print("✅ [HLS SEGMENT] \(self.shortMID(mediaID)) served \(logPath) from upstream (\(finalData.count) bytes)")
                    }
                    self.sendResponse(connection: connection, statusCode: 200, headers: headers, body: finalData)
                }
                // MEMORY FIX: All Data objects released when autoreleasepool exits

                // CRITICAL: Call completion AFTER file is written and served
                completion?()
            }
        }
        trackHLSDataTask(task, mediaID: mediaID, taskKey: taskKey)
        task.resume()
    }
    
    private func isUsableCachedFile(atPath path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }

        guard size.int64Value > 0 else {
            try? FileManager.default.removeItem(atPath: path)
            removeCachedFileCompleteMarker(atPath: path)
            print("⚠️ [LocalHTTPServer] Removed zero-byte cached file: \(URL(fileURLWithPath: path).lastPathComponent)")
            return false
        }

        if requiresCompleteMarker(atPath: path),
           !FileManager.default.fileExists(atPath: completeMarkerPath(for: path)) {
            return false
        }

        return true
    }

    private func requiresCompleteMarker(atPath path: String) -> Bool {
        path.hasSuffix(".ts")
    }

    private func completeMarkerPath(for path: String) -> String {
        "\(path).complete"
    }

    private func markCachedFileCompleteIfNeeded(atPath path: String) {
        guard requiresCompleteMarker(atPath: path) else { return }
        let markerURL = URL(fileURLWithPath: completeMarkerPath(for: path))
        do {
            try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("complete".utf8).write(to: markerURL, options: .atomic)
        } catch {
            print("⚠️ [LocalHTTPServer] Failed to write complete marker for \(URL(fileURLWithPath: path).lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func removeCachedFileCompleteMarker(atPath path: String) {
        guard requiresCompleteMarker(atPath: path) else { return }
        try? FileManager.default.removeItem(atPath: completeMarkerPath(for: path))
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

        guard isUsableCachedFile(atPath: path) else {
            sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
            return
        }
        
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard fileSize > 0 else {
                try? FileManager.default.removeItem(atPath: path)
                sendResponse(connection: connection, statusCode: 404, headers: [:], body: nil)
                return
            }

            let mimeType = getMimeType(for: path)
            let headers: [String: String] = [
                "Content-Type": mimeType,
                "Content-Length": "\(fileSize)",
                "Accept-Ranges": "bytes",
                "Cache-Control": "public, max-age=3600"
            ]

            streamFileResponse(
                connection: connection,
                statusCode: 200,
                headers: headers,
                fileURL: URL(fileURLWithPath: path),
                fileSize: fileSize,
                method: method
            )
        } catch {
            print("ERROR: [LocalHTTPServer] Failed to read file: \(error)")
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil)
        }
    }

    private func streamFileResponse(
        connection: NWConnection,
        statusCode: Int,
        headers: [String: String],
        fileURL: URL,
        fileSize: Int64,
        method: String,
        onConnectionDead: (@Sendable () -> Void)? = nil,
        completion: (@Sendable () -> Void)? = nil
    ) {
        switch connection.state {
        case .cancelled, .failed:
            onConnectionDead?()
            completion?()
            return
        default:
            break
        }

        if method == "HEAD" {
            sendResponse(connection: connection, statusCode: statusCode, headers: headers, body: nil, completion: completion)
            return
        }

        do {
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            let headerData = buildHTTPHeaderData(statusCode: statusCode, headers: headers)
            connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    let nsError = error as NSError
                    let isCancellation = nsError.domain == "Network.NWError" && (nsError.code == 89 || nsError.code == 32)
                    if !isCancellation {
                        print("⚠️ [LocalHTTPServer] Failed to send file headers: \(error.localizedDescription)")
                    }
                    try? fileHandle.close()
                    onConnectionDead?()
                    completion?()
                    return
                }

                self?.streamFileChunks(
                    connection: connection,
                    fileHandle: fileHandle,
                    remaining: fileSize
                ) {
                    connection.send(
                        content: nil,
                        contentContext: .defaultMessage,
                        isComplete: true,
                        completion: .contentProcessed { _ in completion?() }
                    )
                }
            })
        } catch {
            print("ERROR: [LocalHTTPServer] Failed to stream file: \(error.localizedDescription)")
            sendResponse(connection: connection, statusCode: 500, headers: [:], body: nil, completion: completion)
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
    
    private func sendResponse(connection: NWConnection, statusCode: Int, headers: [String: String], body: Data?, completion: (@Sendable () -> Void)? = nil) {
        // Guard: skip send on dead connections to avoid NWConnection
        // "Socket is not connected" warnings from the network framework.
        switch connection.state {
        case .cancelled, .failed:
            completion?()
            return
        default: break
        }

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
        case 410: return "Gone"
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
