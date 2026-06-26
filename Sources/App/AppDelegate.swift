import UIKit
import BackgroundTasks
import UserNotifications
import AVFoundation
import Darwin

class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.all
    /// Public flag for video views to decide whether to attempt recovery/play.
    /// During long background recovery we restart LocalHTTPServer + clear players asynchronously; attempting
    /// to recover/play while this is in-flight causes "zombie" players (nil currentItem / NaN time).
    static var isVideoInfrastructureReady = true
    
    // Track if app has finished launching to distinguish startup from background recovery
    private var hasFinishedLaunching = false
    private var didLaunchInBackground = false
    private var hasEnteredBackgroundInCurrentProcess = false
    
    // Track ongoing infrastructure restart to prevent overlapping restarts
    private var infrastructureRestartTask: Task<Void, Never>?
    private var isRestartingInfrastructure = false

    private var backgroundCleanupTask: UIBackgroundTaskIdentifier = .invalid
    /// True once background memory release has actually run.
    /// When false on foreground return, players and server are still intact → fast path.
    private(set) static var didPerformAggressiveCleanup = false
    
    private enum BackgroundMessageCheck {
        static let identifier = "com.example.ZZ.messageCheck"
        static let interval: TimeInterval = 15 * 60
    }

    private enum BackgroundMainFeedCheck {
        static let identifier = "com.example.ZZ.mainFeedCheck"
        static let interval: TimeInterval = 5 * 60
    }

    private static let logFileName = "app.log"
    private static let legacyLogFileNames = ["app-debug.log"]
    private static let logRetentionInterval: TimeInterval = 72 * 60 * 60
    private static var consoleMirror: ConsoleMirror?

    private final class ConsoleMirror {
        private let logURL: URL
        private var logFile: FileHandle?
        private var logCreatedAt: Date?
        private let originalStdout: Int32
        private let originalStderr: Int32
        private let queue = DispatchQueue(label: "app.console.mirror")
        private var stdoutSource: DispatchSourceRead?
        private var stderrSource: DispatchSourceRead?

        init?(logURL: URL) {
            guard let openedLog = Self.openLogFile(at: logURL) else { return nil }

            let originalStdout = dup(STDOUT_FILENO)
            let originalStderr = dup(STDERR_FILENO)
            guard originalStdout >= 0, originalStderr >= 0 else {
                if originalStdout >= 0 { close(originalStdout) }
                if originalStderr >= 0 { close(originalStderr) }
                openedLog.fileHandle.closeFile()
                return nil
            }

            var stdoutPipe = [Int32](repeating: -1, count: 2)
            var stderrPipe = [Int32](repeating: -1, count: 2)
            guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
                Self.closePipe(stdoutPipe)
                Self.closePipe(stderrPipe)
                close(originalStdout)
                close(originalStderr)
                openedLog.fileHandle.closeFile()
                return nil
            }

            fflush(stdout)
            fflush(stderr)

            let stdoutRedirected = dup2(stdoutPipe[1], STDOUT_FILENO)
            let stderrRedirected = dup2(stderrPipe[1], STDERR_FILENO)
            guard stdoutRedirected >= 0, stderrRedirected >= 0 else {
                dup2(originalStdout, STDOUT_FILENO)
                dup2(originalStderr, STDERR_FILENO)
                Self.closePipe(stdoutPipe)
                Self.closePipe(stderrPipe)
                close(originalStdout)
                close(originalStderr)
                openedLog.fileHandle.closeFile()
                return nil
            }

            close(stdoutPipe[1])
            close(stderrPipe[1])
            setvbuf(stdout, nil, _IONBF, 0)
            setvbuf(stderr, nil, _IONBF, 0)

            self.logURL = logURL
            self.logFile = openedLog.fileHandle
            self.logCreatedAt = openedLog.createdAt
            self.originalStdout = originalStdout
            self.originalStderr = originalStderr
            self.stdoutSource = makeSource(readFileDescriptor: stdoutPipe[0], originalFileDescriptor: originalStdout)
            self.stderrSource = makeSource(readFileDescriptor: stderrPipe[0], originalFileDescriptor: originalStderr)
        }

        deinit {
            stdoutSource?.cancel()
            stderrSource?.cancel()
            close(originalStdout)
            close(originalStderr)
            logFile?.closeFile()
        }

        private static func openLogFile(at logURL: URL) -> (fileHandle: FileHandle, createdAt: Date)? {
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: logURL.path) {
                fileManager.createFile(atPath: logURL.path, contents: nil)
            }

            guard let logFile = try? FileHandle(forWritingTo: logURL) else { return nil }
            logFile.seekToEndOfFile()

            let attributes = try? fileManager.attributesOfItem(atPath: logURL.path)
            let createdAt = attributes?[.creationDate] as? Date
                ?? attributes?[.modificationDate] as? Date
                ?? Date()
            return (logFile, createdAt)
        }

        private static func closePipe(_ pipeFileDescriptors: [Int32]) {
            for fileDescriptor in pipeFileDescriptors where fileDescriptor >= 0 {
                close(fileDescriptor)
            }
        }

        private func makeSource(readFileDescriptor: Int32, originalFileDescriptor: Int32) -> DispatchSourceRead {
            let source = DispatchSource.makeReadSource(fileDescriptor: readFileDescriptor, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let availableBytes = max(1, min(Int(source.data), 8 * 1024))
                var buffer = [UInt8](repeating: 0, count: availableBytes)
                let byteCount = Darwin.read(readFileDescriptor, &buffer, buffer.count)

                guard byteCount > 0 else {
                    source.cancel()
                    return
                }

                buffer.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return }
                    Self.writeAll(to: originalFileDescriptor, bytes: baseAddress, count: byteCount)
                }
                writeToLogFile(Data(buffer.prefix(byteCount)))
            }
            source.setCancelHandler {
                close(readFileDescriptor)
            }
            source.resume()
            return source
        }

        private func writeToLogFile(_ data: Data) {
            rotateLogFileIfNeeded()
            logFile?.write(data)
        }

        private func rotateLogFileIfNeeded() {
            guard let createdAt = logCreatedAt,
                  Date().timeIntervalSince(createdAt) >= AppDelegate.logRetentionInterval else {
                return
            }

            logFile?.closeFile()
            logFile = nil
            try? FileManager.default.removeItem(at: logURL)

            guard let openedLog = Self.openLogFile(at: logURL) else { return }
            logFile = openedLog.fileHandle
            logCreatedAt = openedLog.createdAt

            if let marker = "\n--- App log file rotated: \(Date()) ---\n".data(using: .utf8) {
                logFile?.write(marker)
            }
        }

        private static func writeAll(to fileDescriptor: Int32, bytes: UnsafeRawPointer, count: Int) {
            var remainingByteCount = count
            var cursor = bytes.assumingMemoryBound(to: UInt8.self)

            while remainingByteCount > 0 {
                let writtenByteCount = Darwin.write(fileDescriptor, cursor, remainingByteCount)
                guard writtenByteCount > 0 else { break }
                remainingByteCount -= writtenByteCount
                cursor = cursor.advanced(by: writtenByteCount)
            }
        }
    }
    
    /// Mirror stdout/stderr (all `print()`/`NSLog`) to Documents so troubleshooting
    /// logs survive app suspension and process relaunches.
    private static func redirectConsoleToLogFile() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        deleteExpiredLogFiles(in: docs)
        let logURL = docs.appendingPathComponent(logFileName)
        consoleMirror = ConsoleMirror(logURL: logURL)
        print("\n--- App log session started: \(Date()) pid=\(ProcessInfo.processInfo.processIdentifier) ---")
        print("📂 [LOG] Console output mirrored to \(logURL.path)")
    }

    private static func deleteExpiredLogFiles(in directory: URL) {
        for fileName in [logFileName] + legacyLogFileNames {
            let logURL = directory.appendingPathComponent(fileName)
            guard shouldDeleteLogFile(at: logURL) else { continue }
            try? FileManager.default.removeItem(at: logURL)
        }
    }

    private static func shouldDeleteLogFile(at logURL: URL, now: Date = Date()) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let createdAt = attributes[.creationDate] as? Date
                ?? attributes[.modificationDate] as? Date else {
            return false
        }

        return now.timeIntervalSince(createdAt) >= logRetentionInterval
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Lock app to portrait orientation by default
        AppDelegate.lockOrientation(.portrait)

        // Mirror all print()/NSLog output to Documents so overnight troubleshooting
        // logs survive app backgrounding and relaunches.
        Self.redirectConsoleToLogFile()

        // Register background tasks before application finishes launching
        registerBackgroundTasks()
        
        // Setup app lifecycle notifications
        setupAppLifecycleNotifications()
        
        // Initialize memory warning manager
        _ = MemoryWarningManager.shared
        
        // CRITICAL: Initialize MuteState early to ensure it's ready before videos load
        // This prevents race condition where videos play unmuted at app startup
        _ = MuteState.shared
        print("[AppDelegate] MuteState initialized early")
        
        // CRITICAL: Initialize SimpleVideoPlayerStateHelper early for persistent state
        _ = SimpleVideoPlayerStateHelper.shared
        print("[AppDelegate] SimpleVideoPlayerStateHelper initialized for detail view video state")
        
        // Start LocalHTTPServer early to ensure it's ready before videos load
        LocalHTTPServer.shared.start()
        print("[AppDelegate] LocalHTTPServer started on app launch")
        
        // Handle URL if app was launched from a deeplink
        if let url = launchOptions?[.url] as? URL {
            print("[AppDelegate] App launched from URL: \(url.absoluteString)")
            // Delay posting notification to ensure ContentView is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(
                    name: .deeplinkReceived,
                    object: nil,
                    userInfo: ["url": url]
                )
            }
        }
        
        // Request notification permissions
        Task {
            await requestNotificationPermission()
        }

        // Listen for app initialization to check messages
        setupMessageCheckOnInitialization()
        
        // Listen for app initialization to fetch app URLs
        setupAppUrlsFetch()

        // Schedule initial background message check
        print("[AppDelegate] 🚀 Scheduling initial background message check on app launch")
        Task { @MainActor in
            self.scheduleNextMessageCheck()
            self.scheduleNextMainFeedCheck()
        }
        
        didLaunchInBackground = application.applicationState == .background
        if didLaunchInBackground {
            print("[AppDelegate] App launched in background - preserving background timestamp for foreground recovery")
        } else {
            // CRITICAL: Clear any stale background timestamp from previous session
            // This ensures normal app startup is not misclassified as returning from background.
            UserDefaults.standard.removeObject(forKey: "lastBackgroundTimestamp")
        }
        
        // Mark that app has finished launching
        hasFinishedLaunching = true
        
        return true
    }
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
    
    static func lockOrientation(_ orientation: UIInterfaceOrientationMask) {
        orientationLock = orientation
        refreshSupportedInterfaceOrientations(preferredOrientation: orientation)
        print("DEBUG: [AppDelegate] Locked orientation to: \(orientation)")
    }
    
    static func unlockOrientation() {
        orientationLock = .all
        refreshSupportedInterfaceOrientations(preferredOrientation: .all)
        print("DEBUG: [AppDelegate] Unlocked orientation")
    }

    private static func refreshSupportedInterfaceOrientations(preferredOrientation: UIInterfaceOrientationMask) {
        DispatchQueue.main.async {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .forEach { windowScene in
                    windowScene.windows
                        .first(where: { $0.isKeyWindow })?
                        .rootViewController?
                        .setNeedsUpdateOfSupportedInterfaceOrientations()

                    windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: preferredOrientation)) { error in
                        print("DEBUG: [AppDelegate] Orientation geometry update failed: \(error.localizedDescription)")
                    }
                }
        }
    }
    
    // MARK: - Background Task Registration
    
    private func registerBackgroundTasks() {
        // Register background task for checking new messages every 15 minutes
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundMessageCheck.identifier, using: nil) { task in
            print("[AppDelegate] 🎯 Background task triggered: \(task.identifier)")
            self.handleMessageCheckBackgroundTask(task: task as! BGAppRefreshTask)
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundMainFeedCheck.identifier, using: nil) { task in
            print("[AppDelegate] 🎯 Background task triggered: \(task.identifier)")
            self.handleMainFeedCheckBackgroundTask(task: task as! BGAppRefreshTask)
        }

        print("[AppDelegate] 📋 Background tasks registered")
    }
    
    private func handleMessageCheckBackgroundTask(task: BGAppRefreshTask) {
        didLaunchInBackground = didLaunchInBackground || UIApplication.shared.applicationState == .background
        print("[AppDelegate] 🔄 Background message check task STARTED")

        // Schedule the next background task
        Task { @MainActor in
            self.scheduleNextMessageCheck()
        }

        // Set up task expiration handler
        task.expirationHandler = {
            print("[AppDelegate] ⏰ Background message check task EXPIRED")
            task.setTaskCompleted(success: false)
        }

        // Perform the message check
        Task {
            print("[AppDelegate] 📨 Starting background message check...")
            // Check for new messages from all chat sessions
            await ChatSessionManager.shared.checkBackendForNewMessages()

            // Mark task as completed successfully
            task.setTaskCompleted(success: true)
            print("[AppDelegate] ✅ Background message check completed successfully")
        }
    }

    private func handleMainFeedCheckBackgroundTask(task: BGAppRefreshTask) {
        didLaunchInBackground = didLaunchInBackground || UIApplication.shared.applicationState == .background
        print("[AppDelegate] 🔄 Background main feed check task STARTED")

        Task { @MainActor in
            self.scheduleNextMainFeedCheck()
        }

        let checkTask = Task {
            if #available(iOS 16.0, *) {
                if HproseInstance.shared.appUser.isGuest {
                    print("[AppDelegate] Skipping background main feed check for guest user")
                } else {
                    await FollowingsTweetViewModel.shared.performBackgroundFeedCheck()
                }
            }
            task.setTaskCompleted(success: true)
            print("[AppDelegate] ✅ Background main feed check completed successfully")
        }

        task.expirationHandler = {
            print("[AppDelegate] ⏰ Background main feed check task EXPIRED")
            checkTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }
    
    @MainActor
    private func scheduleNextMessageCheck() {
        guard UIApplication.shared.backgroundRefreshStatus == .available else {
            print("[AppDelegate] ℹ️ Background message check not scheduled; Background App Refresh is \(backgroundRefreshStatusDescription())")
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: BackgroundMessageCheck.identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: BackgroundMessageCheck.interval)

        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundMessageCheck.identifier)
            try BGTaskScheduler.shared.submit(request)
            print("[AppDelegate] 📅 Next background message check scheduled for \(request.earliestBeginDate ?? Date())")
        } catch {
            logMessageCheckSchedulingFailure(error)
        }
    }

    @MainActor
    private func scheduleNextMainFeedCheck() {
        guard UIApplication.shared.backgroundRefreshStatus == .available else {
            print("[AppDelegate] ℹ️ Background main feed check not scheduled; Background App Refresh is \(backgroundRefreshStatusDescription())")
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: BackgroundMainFeedCheck.identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: BackgroundMainFeedCheck.interval)

        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundMainFeedCheck.identifier)
            try BGTaskScheduler.shared.submit(request)
            print("[AppDelegate] 📅 Next background main feed check scheduled for \(request.earliestBeginDate ?? Date())")
        } catch {
            logBackgroundTaskSchedulingFailure(error, taskDescription: "main feed check")
        }
    }
    
    private func logMessageCheckSchedulingFailure(_ error: Error) {
        logBackgroundTaskSchedulingFailure(error, taskDescription: "message check")
    }

    private func logBackgroundTaskSchedulingFailure(_ error: Error, taskDescription: String) {
        let nsError = error as NSError
        guard nsError.domain == "BGTaskSchedulerErrorDomain" else {
            print("[AppDelegate] ❌ Failed to schedule background \(taskDescription): \(error)")
            return
        }

        switch nsError.code {
        case 1:
            print("[AppDelegate] ℹ️ Background \(taskDescription) not scheduled because BGTaskScheduler is unavailable in this environment")
        case 2:
            print("[AppDelegate] ⚠️ Background \(taskDescription) not scheduled because too many background task requests are pending")
        case 3:
            print("[AppDelegate] ❌ Background \(taskDescription) is not permitted; verify BGTaskSchedulerPermittedIdentifiers and UIBackgroundModes in Info.plist")
        default:
            print("[AppDelegate] ❌ Failed to schedule background \(taskDescription): \(error)")
        }
    }
    
    @MainActor
    private func backgroundRefreshStatusDescription() -> String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:
            return "available"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }
    
    // MARK: - App Lifecycle Notifications
    
    private func setupAppLifecycleNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        print("[AppDelegate] App lifecycle notifications setup completed")
    }
    
    @objc private func handleAppWillResignActive() {
        print("[AppDelegate] App will resign active - storing timestamp for screen lock detection")
        
        // Cancel any ongoing infrastructure restart task
        infrastructureRestartTask?.cancel()
        infrastructureRestartTask = nil
        isRestartingInfrastructure = false
        
        // Store timestamp when app loses focus (screen lock or background)
        // This helps distinguish between screen lock and background scenarios
        UserDefaults.standard.set(Date(), forKey: "lastResignActiveTimestamp")
    }
    
    /// Handle app becoming active (from screen lock or app switcher)
    ///
    /// This method handles app becoming active from screen lock scenarios:
    ///
    /// **Screen Lock Recovery:**
    /// - Long screen lock (>5 min): Full server restart
    ///   - Clears video players
    ///   - Posts .reloadVisibleVideosOnly notification (only visible videos reload)
    /// - Short screen lock (<5 min): Lightweight refresh
    ///   - Keeps players intact when possible
    ///   - Resets connection pool
    ///   - Posts .reloadVisibleVideosOnly notification (only visible videos reload)
    ///
    /// **State Management:**
    /// - Clears stale video states (older than 1 hour)
    /// - Refreshes mute state from preferences
    /// - Posts .appDidBecomeActive for other listeners
    ///
    /// - Note: Only visible videos reload automatically; off-screen videos load when scrolled into view
    @objc private func handleAppDidBecomeActive() {
        print("[AppDelegate] App did become active - checking for screen lock recovery")
        
        // Clear stale video states (older than 1 hour)
        PersistentVideoStateManager.shared.clearStaleStates()
        
        // Check if this is a screen lock recovery (not background recovery)
        if let resignActiveDate = UserDefaults.standard.object(forKey: "lastResignActiveTimestamp") as? Date,
           let backgroundDate = UserDefaults.standard.object(forKey: "lastBackgroundTimestamp") as? Date {
            
            // If resignActive was more recent than background, this is screen lock recovery
            if resignActiveDate > backgroundDate {
                let timeInactive = Date().timeIntervalSince(resignActiveDate)
                print("[AppDelegate] Screen lock recovery detected - inactive for \(Int(timeInactive))s")
                
                AppDelegate.isVideoInfrastructureReady = false
                infrastructureRestartTask = Task.detached(priority: .userInitiated) {
                    let kind = timeInactive > 300 ? "long" : "short"
                    await self.recoverVideoInfrastructureAfterForeground(reason: "\(kind) screen lock \(Int(timeInactive))s")
                }
            }
        }
        
        // Clear stale video state cache
        VideoStateCache.shared.clearStaleCache()
        
        // Refresh mute state from preferences when app becomes active
        // This ensures videos respect the current mute setting even if it was changed while app was in background
        MuteState.shared.refreshFromPreferences()
        
        // Post notification to restore video state (handled by SimpleVideoPlayer)
        NotificationCenter.default.post(name: .appDidBecomeActive, object: nil)
    }
    
    @objc private func handleAppDidEnterBackground() {
        print("🌙🌙🌙 [AppDelegate] ===== DID ENTER BACKGROUND =====")
        hasEnteredBackgroundInCurrentProcess = true

        // Store timestamp when app went to background
        UserDefaults.standard.set(Date(), forKey: "lastBackgroundTimestamp")

        // Note: TweetTableViewController's background handler shows cached thumbnails
        // on visible video cells before this runs, preventing black player layers.
        AppDelegate.didPerformAggressiveCleanup = false
        AppDelegate.isVideoInfrastructureReady = false

        NotificationCenter.default.post(name: .prepareVisibleVideosForBackground, object: nil)

        if backgroundCleanupTask == .invalid {
            backgroundCleanupTask = UIApplication.shared.beginBackgroundTask(withName: "BackgroundMemoryRelease") { [weak self] in
                print("⚠️ [AppDelegate] Background memory release time expired")
                self?.endBackgroundCleanupTask()
            }
        }

        // Run on the next main turn so view controllers can prepare the app-switcher snapshot first.
        DispatchQueue.main.async { [weak self] in
            guard UIApplication.shared.applicationState == .background else {
                print("⚡ [AppDelegate] Background memory release skipped; app returned before cleanup")
                AppDelegate.isVideoInfrastructureReady = true
                self?.endBackgroundCleanupTask()
                return
            }

            print("🔥 [AppDelegate] Performing immediate background memory release")
            MemoryCapManager.shared.performBackgroundMemoryRelease()
            AppDelegate.didPerformAggressiveCleanup = true

            print("[AppDelegate] 🚀 Performing IMMEDIATE background message check after cleanup")
            self?.performImmediateBackgroundCheck()

            self?.endBackgroundCleanupTask()
            print("✅ [AppDelegate] Background memory release complete")
        }
    }

    private func endBackgroundCleanupTask() {
        if backgroundCleanupTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundCleanupTask)
            backgroundCleanupTask = .invalid
        }
    }
    
    /// Handle app returning to foreground from background state
    ///
    /// This method coordinates the app's recovery when returning from background:
    ///
    /// **AppUser IP Refresh:**
    /// - Calls `refreshAppUserIP()` which delegates to `refreshAppUserFromServer()`
    /// - Uses `getProviderIP()` for intelligent IP resolution with health checks and automatic fallback
    /// - Prevents using stale IPs if backend moved during suspension
    ///
    /// **Video Infrastructure Recovery:**
    /// - Long background (>5 min): Full server restart required
    ///   - Clears all video players to release old URLs
    ///   - Posts .reloadVisibleVideosOnly notification (only visible videos reload)
    /// - Short background (<5 min): Lightweight recovery
    ///   - Clears players for predictable clean state
    ///   - Resets connection pool
    ///   - Ensures LocalHTTPServer is running
    ///   - Posts .reloadVisibleVideosOnly notification (only visible videos reload)
    ///
    /// **Message Check:**
    /// - Checks for new messages via `checkMessagesForBadgeOnly()`
    /// - Updates badge count without showing notifications
    ///
    /// - Note: Skips recovery if app hasn't finished launching
    /// - Note: Duration-based recovery is more reliable than isRunning checks
    /// - Note: Only visible videos reload automatically; off-screen videos load when scrolled into view
    @objc private func handleAppWillEnterForeground() {
        print("☀️☀️☀️ [AppDelegate] ===== WILL ENTER FOREGROUND =====")

        // CRITICAL: Skip recovery routine on app startup - server is already started in didFinishLaunchingWithOptions
        // willEnterForeground can be called immediately after launch, so check if we've finished launching
        if !hasFinishedLaunching {
            print("🚀 [AppDelegate] App still launching - skipping recovery (server starting in didFinishLaunching)")
            return
        }

        endBackgroundCleanupTask()

        guard let backgroundDate = UserDefaults.standard.object(forKey: "lastBackgroundTimestamp") as? Date else {
            if didLaunchInBackground {
                print("⚠️ [AppDelegate] Background-launched app entered foreground without timestamp - running foreground recovery")
                didLaunchInBackground = false
                AppDelegate.isVideoInfrastructureReady = false
                scheduleMainFeedCheckAfterForegroundReturn()
                infrastructureRestartTask = Task.detached(priority: .userInitiated) {
                    await self.recoverVideoInfrastructureAfterForeground(reason: "foreground after background launch without timestamp")
                }
                Task {
                    print("[AppDelegate] 📬 Checking for new messages on foreground return")
                    await checkMessagesForBadgeOnly()
                }
            } else {
                print("🚀 [AppDelegate] No background timestamp - skipping foreground recovery during startup")
                AppDelegate.isVideoInfrastructureReady = true
            }
            return
        }
        didLaunchInBackground = false

        scheduleMainFeedCheckAfterForegroundReturn()

        // FAST PATH: background memory release didn't run — server & players are intact
        // Safety: if process was suspended before cleanup could fire AND we were
        // gone >5 minutes, the NWListener is likely dead. Fall through to slow path.
        if !AppDelegate.didPerformAggressiveCleanup {
            let timeInBackground = Int(Date().timeIntervalSince(backgroundDate))

            if timeInBackground < 300 {
                print("⚡ [AppDelegate] Fast recovery (\(timeInBackground)s) — checking proxy health")
                AppDelegate.isVideoInfrastructureReady = false
                infrastructureRestartTask = Task.detached(priority: .userInitiated) {
                    await self.recoverVideoInfrastructureAfterForeground(reason: "fast foreground \(timeInBackground)s")
                }

                // Refresh IP and check messages in background (non-blocking)
                Task {
                    print("[AppDelegate] 📬 Checking for new messages on foreground return")
                    await checkMessagesForBadgeOnly()
                }
                Task.detached(priority: .background) { [weak self] in
                    await self?.refreshAppUserIP()
                }
                return
            } else {
                // Process was frozen before background release ran, but >5min elapsed.
                // NWListener likely dead; force the slow recovery path.
                print("⚠️ [AppDelegate] Long suspension (\(timeInBackground)s) without cleanup — forcing slow path")
                AppDelegate.didPerformAggressiveCleanup = true
            }
        }

        // SLOW PATH: Aggressive cleanup already happened — need full recovery
        // Check how long app was in background
        let timeInBackground = Date().timeIntervalSince(backgroundDate)
        print("☀️ [AppDelegate] App returning from \(Int(timeInBackground))s background (aggressive cleanup performed)")

        // CRITICAL: Use DURATION-based recovery, not isRunning check
        // isRunning can be TRUE even when NWListener is suspended by iOS (overnight)
        if timeInBackground > 300 {  // 5 minutes
            print("🔄 [AppDelegate] Long background (\(Int(timeInBackground))s) - checking proxy health")
            AppDelegate.isVideoInfrastructureReady = false
            infrastructureRestartTask = Task.detached(priority: .userInitiated) {
                await self.recoverVideoInfrastructureAfterForeground(reason: "long foreground \(Int(timeInBackground))s")
            }
        } else {
            // SHORT background (<5min) but aggressive cleanup happened
            print("🔄 [AppDelegate] Short background (\(Int(timeInBackground))s) - recovery after aggressive cleanup")

            AppDelegate.isVideoInfrastructureReady = false
            infrastructureRestartTask = Task.detached(priority: .userInitiated) {
                await self.recoverVideoInfrastructureAfterForeground(reason: "short foreground after cleanup \(Int(timeInBackground))s")
            }
        }

        // Check for new messages when returning to foreground (only updates badge, no notifications)
        Task {
            print("[AppDelegate] 📬 Checking for new messages on foreground return")
            await checkMessagesForBadgeOnly()
        }
    }

    private func scheduleMainFeedCheckAfterForegroundReturn() {
        Task { @MainActor in
            self.scheduleNextMainFeedCheck()
        }

        guard hasEnteredBackgroundInCurrentProcess else {
            print("[AppDelegate] Skipping foreground main feed check during app startup")
            if #available(iOS 16.0, *) {
                Task { @MainActor in
                    FollowingsTweetViewModel.shared.clearPendingNewTweetsBanner(reason: "app startup foreground")
                }
            }
            return
        }

        Task {
            if #available(iOS 16.0, *) {
                guard !HproseInstance.shared.appUser.isGuest else {
                    print("[AppDelegate] Skipping foreground main feed check for guest user")
                    return
                }
                await FollowingsTweetViewModel.shared.performForegroundFeedRefresh()
            }
        }
    }
    
    /// Refresh appUser's provider IP when app returns from background
    ///
    /// This method ensures the app uses fresh server IP addresses after returning from background:
    ///
    /// **Process:**
    /// 1. Skips refresh for guest users (returns early)
    /// 2. Calls `HproseInstance.refreshAppUserFromServer()` which:
    ///    - Uses `getProviderIP()` to resolve the user's provider IP with health checks
    ///    - Automatically falls back to resolving firstIP if needed (via handleProviderIPFallback)
    ///    - Updates both HproseInstance.baseUrl and appUser.baseUrl
    /// 3. Saves updated user data to cache
    ///
    /// **Why this is needed:**
    /// - Backend servers can change IPs while app is suspended
    /// - iOS can suspend network connections during long backgrounds
    /// - Stale IPs would cause network errors after app resumes
    ///
    /// **When this runs:**
    /// - Called by `handleAppWillEnterForeground()` when app returns from background
    /// - Runs asynchronously (non-blocking) to avoid delaying foreground transition
    ///
    /// - Note: Errors are logged but non-fatal - app continues with cached data
    /// - Note: No need to manually resolve firstIP - getProviderIP() handles fallback automatically
    private func refreshAppUserIP() async {
        let appUser = HproseInstance.shared.appUser
        
        // Only refresh for logged-in users
        guard !appUser.isGuest else {
            print("[AppDelegate] Skipping IP refresh for guest user")
            return
        }
        
        let hproseInstance = HproseInstance.shared
        
        // Refresh appUser inline so callers can truly await completion.
        // getProviderIP() inside refreshAppUserFromServer() will handle all IP resolution.
        do {
            print("[AppDelegate] Refreshing appUser from server (getProviderIP handles IP resolution)...")
            try await hproseInstance.refreshAppUserFromServer()
            print("[AppDelegate] ✅ Successfully refreshed appUser from server")
            
            // Save updated user to cache
            await MainActor.run {
                TweetCacheManager.shared.saveUser(hproseInstance.appUser)
                print("[AppDelegate] ✅ Saved refreshed appUser to cache")
            }
        } catch {
            print("[AppDelegate] ⚠️ Failed to refresh appUser: \(error)")
            // Non-fatal - we'll continue with cached data and retry on next API call
        }
    }

    private func recoverVideoInfrastructureAfterForeground(reason: String) async {
        guard !Task.isCancelled else { return }

        let isProxyHealthy = await LocalHTTPServer.shared.isHealthyAsync()
        if isProxyHealthy {
            await MainActor.run {
                AppDelegate.isVideoInfrastructureReady = true
                SharedAssetCache.shared.refreshVideoLayersForShortBackground()
                NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)
                print("✅ [AppDelegate] Proxy health OK after \(reason) - posted reloadVisibleVideosOnly")
            }
            // Refresh the upstream IP for IPFS cache misses AFTER the proxy is up and video
            // has resumed. Previously this blocked reloadVisibleVideosOnly behind a
            // failing/retrying fetchUser (~2s) before playback could restart. Non-fatal.
            if shouldRefreshAppUserBeforeForegroundVideoReload(reason: reason) {
                print("[AppDelegate] 🔄 Refreshing appUser IP after foreground video reload...")
                await refreshAppUserIP()
                print("[AppDelegate] ✅ AppUser IP refresh complete")
            }
            return
        }

        guard !isRestartingInfrastructure else {
            print("[AppDelegate] Proxy health failed after \(reason), but infrastructure restart is already in progress")
            return
        }

        print("⚠️ [AppDelegate] Proxy health failed after \(reason) - restarting video infrastructure")
        await MainActor.run {
            AppDelegate.isVideoInfrastructureReady = false
        }

        // Restart the proxy FIRST so cached HLS serves immediately and video can resume.
        // The appUser IP refresh is only needed for IPFS cache misses (lazy upstream URL
        // resolution), so it runs AFTER the restart instead of before. Previously a
        // failing/retrying fetchUser blocked the restart + reload for ~2s.
        let didRestart = await restartVideoInfrastructureAsync()

        await MainActor.run {
            AppDelegate.isVideoInfrastructureReady = didRestart
            if didRestart {
                NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)
                print("✅ [AppDelegate] Proxy restarted after \(reason) - posted reloadVisibleVideosOnly")
            } else {
                print("❌ [AppDelegate] Proxy restart failed after \(reason) - visible videos will wait for next retry")
            }
        }

        print("[AppDelegate] 🔄 Refreshing appUser IP after video recovery...")
        await refreshAppUserIP()
        print("[AppDelegate] ✅ AppUser IP refresh complete")
    }

    private func shouldRefreshAppUserBeforeForegroundVideoReload(reason: String) -> Bool {
        // Fast foreground keeps existing players/items alive and already kicks IP
        // refresh in parallel. After aggressive cleanup, long suspension, or screen
        // lock recovery, visible players are recreated and regular-video proxy misses
        // need a fresh upstream URL before playback is restarted.
        !reason.hasPrefix("fast foreground")
    }
    
    /// Synchronous restart (for cases where blocking is acceptable)
    private func restartVideoInfrastructure() {
        print("[AppDelegate] Restarting video infrastructure after long background")
        
        // CRITICAL: Clear ALL video players FIRST to release their URLs
        // This prevents players from trying to use old port numbers after server restart
        SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
        
        // DON'T clear VideoStateCache - it stores playback position/state
        // Preserving it allows videos to resume from where they left off after reload
        
        // Stop the server completely and wait for cleanup
        LocalHTTPServer.shared.stop()
        Thread.sleep(forTimeInterval: 0.5) // BLOCKING sleep - ensure port is released
        
        // Restart the server SYNCHRONOUSLY - wait until ready
        LocalHTTPServer.shared.startAndWait()
        
        print("[AppDelegate] Video infrastructure restart complete")
    }
    
    /// Async restart (non-blocking - allows UI to remain interactive)
    private func restartVideoInfrastructureAsync() async -> Bool {
        // Check if already cancelled
        guard !Task.isCancelled else {
            print("[AppDelegate] Infrastructure restart cancelled before starting")
            isRestartingInfrastructure = false
            return false
        }
        
        // Mark as restarting
        isRestartingInfrastructure = true
        
        print("[AppDelegate] Restarting video infrastructure asynchronously (non-blocking)")
        let startTime = Date()
        
        // CRITICAL: Clear ALL video players FIRST to release their URLs (async for speed)
        // Run clearing in parallel with server operations
        let clearTask = Task.detached(priority: .userInitiated) { @MainActor in
            SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
        }
        
        // DON'T clear VideoStateCache - it stores playback position/state
        // Preserving it allows videos to resume from where they left off after reload
        
        // Check if cancelled
        guard !Task.isCancelled else {
            print("[AppDelegate] Infrastructure restart cancelled before proxy restart")
            await clearTask.value
            isRestartingInfrastructure = false
            return false
        }

        var didRestartProxy = await LocalHTTPServer.shared.forceRestartAndWaitAsync()
        if !didRestartProxy {
            print("[AppDelegate] Proxy restart did not become ready; retrying once")
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !Task.isCancelled {
                didRestartProxy = await LocalHTTPServer.shared.forceRestartAndWaitAsync()
            }
        }
        
        // Check if cancelled
        guard !Task.isCancelled else {
            print("[AppDelegate] Infrastructure restart cancelled after proxy restart")
            await clearTask.value
            isRestartingInfrastructure = false
            return false
        }
        
        // Wait for player clearing to complete (runs in parallel)
        await clearTask.value
        
        // Check if cancelled before restarting
        guard !Task.isCancelled else {
            print("[AppDelegate] Infrastructure restart cancelled before restart")
            isRestartingInfrastructure = false
            return false
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("[AppDelegate] Video infrastructure restart complete (async) in \(String(format: "%.2f", elapsed))s")
        
        // Mark as complete
        isRestartingInfrastructure = false
        infrastructureRestartTask = nil
        return didRestartProxy
    }
    
    private func performImmediateBackgroundCheck() {
        print("[AppDelegate] ⚡ Performing immediate background message check")
        Task {
            await ChatSessionManager.shared.checkBackendForNewMessages()
            print("[AppDelegate] ✅ Immediate background message check completed")

            // Also schedule the regular background task for future checks
            await MainActor.run {
                self.scheduleNextMessageCheck()
            }
        }
    }

    /// Setup message checking when app is initialized
    private func setupMessageCheckOnInitialization() {
        // Listen for app user ready notification
        NotificationCenter.default.addObserver(
            forName: .appUserReady,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Check for new messages after app is initialized (only updates badge, no notifications)
            Task {
                print("[AppDelegate] 📬 Checking for new messages after app initialization")
                await self?.checkMessagesForBadgeOnly()
            }
        }
    }
    
    /// Setup app URLs fetching when app user is initialized
    private func setupAppUrlsFetch() {
        // Listen for app user ready notification
        NotificationCenter.default.addObserver(
            forName: .appUserReady,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Fetch and set app URLs after appUser is initialized
            Task {
                print("[AppDelegate] 🔧 AppUser initialized - fetching app URLs")
                await self?.fetchAndSetAppUrls()
            }
        }
    }

    /// Check for new messages and update badge only (no notifications)
    /// Used when app starts or returns to foreground
    private func checkMessagesForBadgeOnly() async {
        // Only check if user is not guest
        let hproseInstance = HproseInstance.shared
        guard !hproseInstance.appUser.isGuest else {
            print("[AppDelegate] Skipping message check for guest user")
            return
        }

        // Check for new messages without triggering notifications
        // This will update the unreadMessageCount which automatically updates the badge
        await ChatSessionManager.shared.checkBackendForNewMessages(suppressNotifications: true)
        print("[AppDelegate] ✅ Badge-only message check completed")
    }

    // MARK: - Test Methods (for debugging)

    /// Test method to manually trigger background message check
    func testBackgroundMessageCheck() {
        print("[AppDelegate] 🧪 Manually triggering background message check for testing")
        Task {
            await ChatSessionManager.shared.checkBackendForNewMessages()
            print("[AppDelegate] ✅ Manual background message check completed")
        }
    }


    // MARK: - Notification Permission

    private func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            print("[AppDelegate] Notification permission granted: \(granted)")
        } catch {
            print("[AppDelegate] Error requesting notification permission: \(error)")
        }
    }
    
    // MARK: - App URLs Initialization
    
    /// Fetch app URLs from entry MimeiId provider and save to preferences
    ///
    /// This method runs after app initialization to:
    /// 1. Resolve provider IP for `AppConfig.entryMimeiId` using `getProviderIP()`
    /// 2. Fetch content from `http://ip/mm/entryMimeiId`
    /// 3. Parse response and save URLs via `PreferenceHelper.setAppUrls()`
    ///
    /// **Process:**
    /// - Uses `getProviderIP()` for intelligent IP resolution with health checks
    /// - Makes HTTP GET request to retrieve app URLs configuration
    /// - Parses response as comma-separated URLs or JSON array
    /// - Saves to UserDefaults for app-wide access
    ///
    /// **Error Handling:**
    /// - Logs errors but doesn't block app launch
    /// - App continues with existing cached URLs if fetch fails
    private func fetchAndSetAppUrls() async {
        print("[AppDelegate] 🔧 Fetching app URLs from entry MimeiId provider...")
        
        do {
            // Step 1: Get provider IP for entryMimeiId
            let entryMimeiId = AppConfig.entryMimeiId
            print("[AppDelegate] Resolving provider IP for entryMimeiId: \(entryMimeiId)")
            
            guard let providerIP = try await HproseInstance.shared.getProviderIP(entryMimeiId) else {
                print("[AppDelegate] ⚠️ Failed to resolve provider IP for entryMimeiId")
                return
            }
            
            print("[AppDelegate] ✅ Resolved provider IP: \(providerIP)")
            
            // Step 2: Fetch content from http://ip/mm/entryMimeiId
            let urlString = "http://\(providerIP)/mm/\(entryMimeiId)"
            guard let url = URL(string: urlString) else {
                print("[AppDelegate] ❌ Invalid URL: \(urlString)")
                return
            }
            
            print("[AppDelegate] Fetching app URLs from: \(urlString)")
            
            var request = URLRequest(url: url)
            request.timeoutInterval = 10.0
            request.cachePolicy = .reloadIgnoringLocalCacheData
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            // Check HTTP response
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                print("[AppDelegate] ❌ Invalid HTTP response: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            
            print("[AppDelegate] ✅ Successfully fetched app URLs data (\(data.count) bytes)")
            
            // Step 3: Parse response and save URLs
            let urls = try parseAppUrls(from: data)
            
            if urls.isEmpty {
                print("[AppDelegate] ⚠️ No URLs found in response")
                return
            }
            
            print("[AppDelegate] Parsed \(urls.count) URL(s): \(urls)")
            
            // Step 4: Save to preferences
            let preferenceHelper = PreferenceHelper()
            preferenceHelper.setAppUrls(urls)
            
            print("[AppDelegate] ✅ Successfully saved app URLs to preferences")
            
        } catch {
            print("[AppDelegate] ❌ Error fetching app URLs: \(error)")
            // Non-fatal - app continues with existing URLs
        }
    }
    
    /// Parse app URLs from response data
    ///
    /// Supports multiple formats:
    /// - JSON array: ["http://url1.com", "http://url2.com"]
    /// - JSON object with "urls" or "data" key: {"urls": ["http://url1.com"]}
    /// - Plain text comma-separated: "http://url1.com,http://url2.com"
    /// - Plain text newline-separated: "http://url1.com\nhttp://url2.com"
    private func parseAppUrls(from data: Data) throws -> Set<String> {
        // Try parsing as JSON first
        if let json = try? JSONSerialization.jsonObject(with: data) {
            // Case 1: JSON array of strings
            if let urlArray = json as? [String] {
                return Set(urlArray.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
            
            // Case 2: JSON object with "urls" or "data" key
            if let jsonDict = json as? [String: Any] {
                if let urlArray = jsonDict["urls"] as? [String] {
                    return Set(urlArray.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                }
                if let urlArray = jsonDict["data"] as? [String] {
                    return Set(urlArray.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                }
                
                // Case 3: Single URL string in object
                if let urlString = jsonDict["urls"] as? String {
                    let urls = urlString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    return Set(urls.filter { !$0.isEmpty })
                }
                if let urlString = jsonDict["data"] as? String {
                    let urls = urlString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    return Set(urls.filter { !$0.isEmpty })
                }
            }
        }
        
        // Try parsing as plain text (comma or newline separated)
        if let text = String(data: data, encoding: .utf8) {
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Try comma-separated first
            if trimmedText.contains(",") {
                let urls = trimmedText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                return Set(urls.filter { !$0.isEmpty })
            }
            
            // Try newline-separated
            if trimmedText.contains("\n") {
                let urls = trimmedText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                return Set(urls.filter { !$0.isEmpty })
            }
            
            // Single URL
            if !trimmedText.isEmpty {
                return Set([trimmedText])
            }
        }
        
        return Set()
    }
    
    // MARK: - URL Handling (Deeplinks)
    
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        print("[AppDelegate] ✅ Received deeplink URL (app running): \(url.absoluteString)")
        print("[AppDelegate] URL scheme: \(url.scheme ?? "nil"), host: \(url.host ?? "nil"), path: \(url.path)")
        
        // Post notification with URL for ContentView to handle
        // Use async dispatch to ensure ContentView is ready
        DispatchQueue.main.async {
            print("[AppDelegate] Posting deeplink notification...")
            NotificationCenter.default.post(
                name: .deeplinkReceived,
                object: nil,
                userInfo: ["url": url]
            )
            print("[AppDelegate] Deeplink notification posted")
        }
        
        return true
    }
    
    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Handle Universal Links
        if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
           let url = userActivity.webpageURL {
            print("[AppDelegate] Received Universal Link: \(url.absoluteString)")
            
            NotificationCenter.default.post(
                name: .deeplinkReceived,
                object: nil,
                userInfo: ["url": url]
            )
            
            return true
        }
        
        return false
    }
}
