import UIKit
import SwiftUI
import BackgroundTasks
import UserNotifications
import AVFoundation
import ffmpegkit

class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.all
    /// Public flag for video views to decide whether to attempt recovery/play.
    /// During long background recovery we restart LocalHTTPServer + clear players asynchronously; attempting
    /// to recover/play while this is in-flight causes "zombie" players (nil currentItem / NaN time).
    static var isVideoInfrastructureReady = true
    
    // Loading overlay window for server restart
    private var loadingWindow: UIWindow?
    
    // Track if app has finished launching to distinguish startup from background recovery
    private var hasFinishedLaunching = false
    
    // Track ongoing infrastructure restart to prevent overlapping restarts
    private var infrastructureRestartTask: Task<Void, Never>?
    private var isRestartingInfrastructure = false

    // Deferred aggressive cleanup: server stop + player item removal delayed 3s
    // If app returns before it fires, we cancel it for instant video recovery
    private var deferredCleanupWorkItem: DispatchWorkItem?
    /// True once the deferred aggressive cleanup has actually executed.
    /// When false on foreground return, players and server are still intact → fast path.
    private(set) static var didPerformAggressiveCleanup = false
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Configure FFmpegKit to suppress verbose logs (only show errors)
        // AV_LOG_ERROR = 16 - only show fatal errors, suppress INFO/WARNING/DEBUG
        FFmpegKitConfig.setLogLevel(16)
        
        // Lock app to portrait orientation by default
        AppDelegate.lockOrientation(.portrait)
        
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
        scheduleNextMessageCheck()
        
        // CRITICAL: Clear any stale background timestamp from previous session
        // This ensures we can distinguish app startup from returning from background
        UserDefaults.standard.removeObject(forKey: "lastBackgroundTimestamp")
        
        // Mark that app has finished launching
        hasFinishedLaunching = true
        
        return true
    }
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
    
    static func lockOrientation(_ orientation: UIInterfaceOrientationMask) {
        orientationLock = orientation
        print("DEBUG: [AppDelegate] Locked orientation to: \(orientation)")
    }
    
    static func unlockOrientation() {
        orientationLock = .all
        print("DEBUG: [AppDelegate] Unlocked orientation")
    }
    
    // MARK: - Background Task Registration
    
    private func registerBackgroundTasks() {
        // Register background task for checking new messages every 15 minutes
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.example.ZZ.messageCheck", using: nil) { task in
            print("[AppDelegate] 🎯 Background task triggered: \(task.identifier)")
            self.handleMessageCheckBackgroundTask(task: task as! BGAppRefreshTask)
        }

        print("[AppDelegate] 📋 Background tasks registered")
    }
    
    private func handleMessageCheckBackgroundTask(task: BGAppRefreshTask) {
        print("[AppDelegate] 🔄 Background message check task STARTED")

        // Schedule the next background task
        scheduleNextMessageCheck()

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
    
    private func scheduleNextMessageCheck() {
        let request = BGAppRefreshTaskRequest(identifier: "com.example.ZZ.messageCheck")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes from now

        do {
            try BGTaskScheduler.shared.submit(request)
            print("[AppDelegate] 📅 Next background message check scheduled for \(request.earliestBeginDate ?? Date())")
        } catch {
            print("[AppDelegate] ❌ Failed to schedule background message check: \(error)")
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
    ///   - Shows loading overlay during restart
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
                
                // Use same time-based threshold as background recovery (5 minutes)
                if timeInactive > 300 {
                    // LONG screen lock (>5min) - full restart needed
                    print("[AppDelegate] Long screen lock (\(Int(timeInactive))s) - forcing full restart")
                    
                    // Check if already restarting
                    if isRestartingInfrastructure {
                        print("[AppDelegate] Infrastructure restart already in progress, skipping")
                        return
                    }
                    
                    AppDelegate.isVideoInfrastructureReady = false
                    SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
                    
                    // Show loading indicator (non-blocking - allows user to scroll)
                    showLoadingOverlay()
                    
                    // Restart infrastructure asynchronously (non-blocking)
                    infrastructureRestartTask = Task.detached(priority: .userInitiated) {
                        // CRITICAL: Refresh appUser IP FIRST for long screen locks
                        // Network connections may have changed during extended lock
                        print("[AppDelegate] 🔄 Refreshing appUser IP before video recovery...")
                        await self.refreshAppUserIP()
                        print("[AppDelegate] ✅ AppUser IP refresh complete")
                        
                        // Restart server in background
                        await self.restartVideoInfrastructureAsync()
                        
                        // Hide loading indicator and notify visible videos to reload
                        await MainActor.run {
                            self.hideLoadingOverlay()
                            AppDelegate.isVideoInfrastructureReady = true
                            // Post notification for visible videos to reload
                            NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)
                            print("[AppDelegate] Server restarted after long screen lock - posted reloadVisibleVideosOnly notification")
                        }
                    }
                } else {
                    // SHORT screen lock (<5min) - gentle refresh, keep players intact
                    print("[AppDelegate] Short screen lock (\(Int(timeInactive))s) - gentle refresh (keeping players)")
                    
                    if LocalHTTPServer.shared.isRunning {
                        // Server still alive - just refresh, don't clear players
                        SharedAssetCache.shared.refreshVideoLayersForShortBackground()
                        LocalHTTPServer.shared.resetConnectionPool()
                        print("[AppDelegate] Short screen lock recovery complete - videos kept intact")
                        // Post notification for visible videos to check health (they skip if seeking)
                        NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)
                        print("[AppDelegate] Short screen lock recovery - posted reloadVisibleVideosOnly notification")
                    } else {
                        // Server killed during screen lock - restart it
                        print("[AppDelegate] Server killed during screen lock, restarting...")
                        
                        // Check if already restarting
                        if isRestartingInfrastructure {
                            print("[AppDelegate] Infrastructure restart already in progress, skipping")
                            return
                        }
                        
                        AppDelegate.isVideoInfrastructureReady = false
                        SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
                        
                        // Show loading indicator (non-blocking)
                        showLoadingOverlay()
                        
                        // Restart server asynchronously (non-blocking)
                        infrastructureRestartTask = Task.detached(priority: .userInitiated) {
                            // CRITICAL: Refresh appUser IP FIRST before restarting server
                            // This ensures videos load with fresh IPs after server restart
                            print("[AppDelegate] 🔄 Refreshing appUser IP before video recovery...")
                            await self.refreshAppUserIP()
                            print("[AppDelegate] ✅ AppUser IP refresh complete")
                            
                            // Restart server in background (async - doesn't block!)
                            await LocalHTTPServer.shared.startAndWaitAsync()

                            // Hide loading indicator and notify visible videos to reload
                            await MainActor.run {
                                self.hideLoadingOverlay()
                                AppDelegate.isVideoInfrastructureReady = true
                                // Post notification for visible videos to reload
                                NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)
                                print("[AppDelegate] Server restarted after screen lock - posted reloadVisibleVideosOnly notification")
                            }
                        }
                    }
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

        // Store timestamp when app went to background
        UserDefaults.standard.set(Date(), forKey: "lastBackgroundTimestamp")

        // Perform immediate background message check when entering background
        print("[AppDelegate] 🚀 Performing IMMEDIATE background message check on app background")
        performImmediateBackgroundCheck()

        // Note: TweetTableViewController's background handler shows cached thumbnails
        // on visible video cells before this runs, preventing black player layers.

        // Phase 1 (immediate): Lightweight cleanup — pause players, clear caches
        // Players keep their items so health checks pass on quick foreground return
        print("💾 [AppDelegate] Phase 1: Lightweight cleanup (pausing players, clearing caches)")
        SharedAssetCache.shared.pauseAllPlayers()
        VideoStateCache.shared.clearAllCache()
        ImageCacheManager.shared.clearMemoryCache()

        AppDelegate.didPerformAggressiveCleanup = false

        // Phase 2 (deferred 3s): Aggressive cleanup — release player items + stop server
        // If app returns before this fires, we cancel it for instant video recovery
        deferredCleanupWorkItem?.cancel()
        let cleanupItem = DispatchWorkItem { [weak self] in
            guard self != nil else { return }
            print("🔥 [AppDelegate] Phase 2: Deferred aggressive cleanup")

            SharedAssetCache.shared.releaseVideoMemoryButKeepPlayers()

            LocalHTTPServer.shared.resetConnectionPool()

            print("🔌 [AppDelegate] Stopping LocalHTTPServer")
            LocalHTTPServer.shared.stop()

            AppDelegate.didPerformAggressiveCleanup = true
            print("✅ [AppDelegate] Deferred aggressive cleanup complete")
        }
        deferredCleanupWorkItem = cleanupItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: cleanupItem)

        print("✅ [AppDelegate] Phase 1 complete — Phase 2 deferred 3s")
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
    ///   - Shows loading overlay during restart
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

        // Cancel deferred aggressive cleanup if it hasn't fired yet
        deferredCleanupWorkItem?.cancel()
        deferredCleanupWorkItem = nil

        // FAST PATH: Deferred cleanup didn't run — server & players are intact
        // Safety: if process was suspended before deferred cleanup could fire AND we were
        // gone >5 minutes, the NWListener is likely dead. Fall through to slow path.
        if !AppDelegate.didPerformAggressiveCleanup {
            let timeInBackground: Int
            if let backgroundDate = UserDefaults.standard.object(forKey: "lastBackgroundTimestamp") as? Date {
                timeInBackground = Int(Date().timeIntervalSince(backgroundDate))
            } else {
                timeInBackground = 0
            }

            if timeInBackground < 300 {
                print("⚡ [AppDelegate] Fast recovery (\(timeInBackground)s) — server & players preserved")

                // CRITICAL: Synchronously kill ALL stale upstream connections before
                // any video cell tries to load.  The async resetConnectionPool() can be
                // delayed if the server queue is blocked by in-flight timeout requests.
                LocalHTTPServer.shared.resetConnectionPool()
                AppDelegate.isVideoInfrastructureReady = true

                // Notify coordinator to resume playback on visible videos
                NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)

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
                // Process was frozen before deferred cleanup ran, but >5min elapsed
                // NWListener likely dead — force aggressive cleanup flag and fall through
                print("⚠️ [AppDelegate] Long suspension (\(timeInBackground)s) without cleanup — forcing slow path")
                AppDelegate.didPerformAggressiveCleanup = true
            }
        }

        // SLOW PATH: Aggressive cleanup already happened — need full recovery
        // Check how long app was in background
        if let backgroundDate = UserDefaults.standard.object(forKey: "lastBackgroundTimestamp") as? Date {
            let timeInBackground = Date().timeIntervalSince(backgroundDate)
            print("☀️ [AppDelegate] App returning from \(Int(timeInBackground))s background (aggressive cleanup performed)")

            // CRITICAL: Use DURATION-based recovery, not isRunning check
            // isRunning can be TRUE even when NWListener is suspended by iOS (overnight)
            if timeInBackground > 300 {  // 5 minutes
                // LONG background - ALWAYS do full restart
                // Even if isRunning=true, the listener may be suspended and unresponsive
                print("🔄 [AppDelegate] Long background (\(Int(timeInBackground))s) - forcing full restart")

                // Check if already restarting
                if isRestartingInfrastructure {
                    print("[AppDelegate] Infrastructure restart already in progress, skipping")
                    return
                }

                // Show loading indicator (non-blocking - allows user to scroll)
                showLoadingOverlay()
                AppDelegate.isVideoInfrastructureReady = false

                // Restart infrastructure asynchronously (non-blocking)
                // Videos will show loading state until server is ready, but UI remains interactive
                infrastructureRestartTask = Task.detached(priority: .userInitiated) {
                    // CRITICAL: Refresh appUser IP FIRST before restarting server
                    // This ensures videos load with fresh IPs, not stale ones that would timeout
                    print("[AppDelegate] 🔄 Refreshing appUser IP before video recovery...")
                    await self.refreshAppUserIP()
                    print("[AppDelegate] ✅ AppUser IP refresh complete")

                    // Restart server in background
                    await self.restartVideoInfrastructureAsync()

                    // Hide loading indicator and notify visible videos to reload
                    await MainActor.run {
                        self.hideLoadingOverlay()
                        AppDelegate.isVideoInfrastructureReady = true

                        // Post notification for visible videos to reload
                        // Coordinator will intelligently decide whether to preserve or reset state
                        NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)
                        print("✅ [AppDelegate] Server fully restarted - posted reloadVisibleVideosOnly notification")
                    }
                }
            } else {
                // SHORT background (<5min) but aggressive cleanup happened
                print("🔄 [AppDelegate] Short background (\(Int(timeInBackground))s) - recovery after aggressive cleanup")

                Task.detached(priority: .userInitiated) {
                    print("[AppDelegate] 🔄 Refreshing appUser IP before video recovery...")
                    await self.refreshAppUserIP()
                    print("[AppDelegate] ✅ AppUser IP refresh complete")

                    // Server was stopped by deferred cleanup - restart it
                    let wasServerRunning = LocalHTTPServer.shared.isRunning
                    let oldPort = LocalHTTPServer.shared.currentPort

                    if !wasServerRunning {
                        print("⚠️ [AppDelegate] Server not running, restarting...")

                        await MainActor.run {
                            AppDelegate.isVideoInfrastructureReady = false
                            SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
                        }

                        await LocalHTTPServer.shared.startAndWaitAsync()

                        let newPort = LocalHTTPServer.shared.currentPort
                        print("✅ [AppDelegate] Server restarted - port changed from \(oldPort ?? 0) to \(newPort ?? 0)")

                        await MainActor.run {
                            AppDelegate.isVideoInfrastructureReady = true
                            NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)
                            print("[AppDelegate] Posted reloadVisibleVideosOnly after port change")
                        }
                    } else {
                        print("✅ [AppDelegate] Server still running on port \(oldPort ?? 0) - KEEPING PLAYERS INTACT")

                        await MainActor.run {
                            SharedAssetCache.shared.refreshVideoLayersForShortBackground()
                            LocalHTTPServer.shared.resetConnectionPool()

                            print("✅ [AppDelegate] Short background recovery complete - players preserved")

                            NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)
                            print("[AppDelegate] Posted reloadVisibleVideosOnly for stale player check")
                        }
                    }
                }
            }
        } else {
            // No background timestamp - this means app was just launched or killed
            print("🚀 [AppDelegate] App startup or crash recovery - ensuring server is running")
            if !LocalHTTPServer.shared.isRunning {
                LocalHTTPServer.shared.start()
            } else {
                print("✅ [AppDelegate] Server already running - no recovery needed")
            }
            AppDelegate.isVideoInfrastructureReady = true
        }

        // Check for new messages when returning to foreground (only updates badge, no notifications)
        Task {
            print("[AppDelegate] 📬 Checking for new messages on foreground return")
            await checkMessagesForBadgeOnly()
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
        
        // Refresh appUser from server in background (non-blocking)
        // getProviderIP() inside refreshAppUserFromServer() will handle all IP resolution
        Task.detached {
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
    }
    
    /// Synchronous restart (for cases where blocking is acceptable)
    private func restartVideoInfrastructure() {
        print("[AppDelegate] Restarting video infrastructure after long background")
        
        // CRITICAL: Clear ALL video players FIRST to release their URLs
        // This prevents players from trying to use old port numbers after server restart
        SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
        
        // DON'T clear VideoStateCache - it stores playback position/state
        // Preserving it allows videos to resume from where they left off after reload
        
        // Reset LocalHTTPServer connection pool
        LocalHTTPServer.shared.resetConnectionPool()
        
        // Stop the server completely and wait for cleanup
        LocalHTTPServer.shared.stop()
        Thread.sleep(forTimeInterval: 0.5) // BLOCKING sleep - ensure port is released
        
        // Restart the server SYNCHRONOUSLY - wait until ready
        LocalHTTPServer.shared.startAndWait()
        
        print("[AppDelegate] Video infrastructure restart complete")
    }
    
    /// Async restart (non-blocking - allows UI to remain interactive)
    private func restartVideoInfrastructureAsync() async {
        // Check if already cancelled
        guard !Task.isCancelled else {
            print("[AppDelegate] Infrastructure restart cancelled before starting")
            isRestartingInfrastructure = false
            return
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
        
        // Reset LocalHTTPServer connection pool (fast operation)
        LocalHTTPServer.shared.resetConnectionPool()
        
        // Check if cancelled
        guard !Task.isCancelled else {
            print("[AppDelegate] Infrastructure restart cancelled during reset")
            await clearTask.value
            isRestartingInfrastructure = false
            return
        }
        
        // OPTIMIZATION: Only stop if server is running, skip stop if already stopped
        // This avoids unnecessary wait if server was already stopped
        let needsStop = LocalHTTPServer.shared.isRunning
        if needsStop {
            LocalHTTPServer.shared.stop()
            // Reduced wait time - stop() is async and usually completes quickly
            // Server stop just cancels the listener, which is fast
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s instead of 0.5s
        }
        
        // Check if cancelled
        guard !Task.isCancelled else {
            print("[AppDelegate] Infrastructure restart cancelled during stop")
            await clearTask.value
            isRestartingInfrastructure = false
            return
        }
        
        // Wait for player clearing to complete (runs in parallel)
        await clearTask.value
        
        // Check if cancelled before restarting
        guard !Task.isCancelled else {
            print("[AppDelegate] Infrastructure restart cancelled before restart")
            isRestartingInfrastructure = false
            return
        }
        
        // Restart the server - use faster method if possible
        // OPTIMIZATION: If server is already running (rare), skip restart
        if !LocalHTTPServer.shared.isRunning {
            await LocalHTTPServer.shared.startAndWaitAsync()  // ✅ Async - doesn't block!
        } else {
            print("[AppDelegate] Server already running - skipping restart")
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("[AppDelegate] Video infrastructure restart complete (async) in \(String(format: "%.2f", elapsed))s")
        
        // Mark as complete
        isRestartingInfrastructure = false
        infrastructureRestartTask = nil
    }
    
    private func performImmediateBackgroundCheck() {
        print("[AppDelegate] ⚡ Performing immediate background message check")
        Task {
            await ChatSessionManager.shared.checkBackendForNewMessages()
            print("[AppDelegate] ✅ Immediate background message check completed")

            // Also schedule the regular background task for future checks
            scheduleNextMessageCheck()
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
    
    // MARK: - Loading Overlay
    
    private func showLoadingOverlay() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return
        }
        
        // Create loading view
        let loadingView = LoadingOverlayView()
        let hostingController = UIHostingController(rootView: loadingView)
        hostingController.view.backgroundColor = .clear
        
        // Create window
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = hostingController
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.makeKeyAndVisible()
        
        loadingWindow = window
    }
    
    private func hideLoadingOverlay() {
        UIView.animate(withDuration: 0.2, animations: {
            self.loadingWindow?.alpha = 0
        }) { _ in
            self.loadingWindow?.isHidden = true
            self.loadingWindow = nil
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

// MARK: - Loading Overlay View

private struct LoadingOverlayView: View {
    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.3)
                .edgesIgnoringSafeArea(.all)
            
            // Just a spinner
            ProgressView()
                .scaleEffect(1.5)
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
        }
    }
} 
