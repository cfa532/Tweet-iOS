import UIKit
import SwiftUI
import BackgroundTasks
import UserNotifications
import AVFoundation
import ffmpegkit

class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.all
    static var isVideoInfrastructureReady = true // Public flag for videos to check
    
    // Loading overlay window for server restart
    private var loadingWindow: UIWindow?
    
    // Track if app has finished launching to distinguish startup from background recovery
    private var hasFinishedLaunching = false
    
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
        
        // Start LocalHTTPServer early to ensure it's ready before videos load
        LocalHTTPServer.shared.start()
        print("[AppDelegate] LocalHTTPServer started on app launch")
        
        // Request notification permissions
        Task {
            await requestNotificationPermission()
        }
        
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
            self.handleMessageCheckBackgroundTask(task: task as! BGAppRefreshTask)
        }
        
        print("[AppDelegate] Background tasks registered")
    }
    
    private func handleMessageCheckBackgroundTask(task: BGAppRefreshTask) {
        // Schedule the next background task
        scheduleNextMessageCheck()
        
        // Set up task expiration handler
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        
        // Perform the message check
        Task {
            // Check for new messages from all chat sessions
            await ChatSessionManager.shared.checkBackendForNewMessages()
            
            // Mark task as completed successfully
            task.setTaskCompleted(success: true)
            print("[AppDelegate] Background message check completed successfully")
        }
    }
    
    private func scheduleNextMessageCheck() {
        let request = BGAppRefreshTaskRequest(identifier: "com.example.ZZ.messageCheck")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes from now
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[AppDelegate] Next background message check scheduled for 15 minutes from now")
        } catch {
            print("[AppDelegate] Failed to schedule background message check: \(error)")
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
        
        // Store timestamp when app loses focus (screen lock or background)
        // This helps distinguish between screen lock and background scenarios
        UserDefaults.standard.set(Date(), forKey: "lastResignActiveTimestamp")
    }
    
    @objc private func handleAppDidBecomeActive() {
        print("[AppDelegate] App did become active - checking for screen lock recovery")
        
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
                    
                    SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
                    
                    // Show loading indicator (non-blocking - allows user to scroll)
                    showLoadingOverlay()
                    
                    // Restart infrastructure asynchronously (non-blocking)
                    Task.detached(priority: .userInitiated) {
                        // Restart server in background
                        await self.restartVideoInfrastructureAsync()
                        
                        // Hide loading indicator and notify videos when ready
                        await MainActor.run {
                            self.hideLoadingOverlay()
                            NotificationCenter.default.post(name: .videoInfrastructureRestarted, object: nil)
                            print("[AppDelegate] Posted videoInfrastructureRestarted notification for long screen lock")
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
                        // Post notification to trigger video recovery (fixes profile video black screens)
                        NotificationCenter.default.post(name: .videoInfrastructureRestarted, object: nil)
                        print("[AppDelegate] Posted videoInfrastructureRestarted notification for short screen lock recovery")
                    } else {
                        // Server killed during screen lock - restart it
                        print("[AppDelegate] Server killed during screen lock, restarting...")
                        SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
                        
                        // Show loading indicator (non-blocking)
                        showLoadingOverlay()
                        
                        // Restart server asynchronously (non-blocking)
                        Task.detached(priority: .userInitiated) {
                            // Restart server in background
                            LocalHTTPServer.shared.startAndWait()
                            
                            // Hide loading indicator and notify videos when ready
                            await MainActor.run {
                                self.hideLoadingOverlay()
                                NotificationCenter.default.post(name: .videoInfrastructureRestarted, object: nil)
                                print("[AppDelegate] Server restarted after screen lock")
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
        NSLog("🌙🌙🌙 [AppDelegate] ===== DID ENTER BACKGROUND =====")
        
        // Store timestamp when app went to background
        UserDefaults.standard.set(Date(), forKey: "lastBackgroundTimestamp")
        
        // DON'T stop LocalHTTPServer - iOS keeps network listeners alive for short backgrounds
        // Only stop for long backgrounds (>5 min) to avoid race conditions and port changes
        
        // Background handling is now done by SimpleVideoPlayer's notification observers
    }
    
    @objc private func handleAppWillEnterForeground() {
        NSLog("☀️☀️☀️ [AppDelegate] ===== WILL ENTER FOREGROUND =====")
        
        // CRITICAL: Skip recovery routine on app startup - server is already started in didFinishLaunchingWithOptions
        // willEnterForeground can be called immediately after launch, so check if we've finished launching
        if !hasFinishedLaunching {
            NSLog("🚀 [AppDelegate] App still launching - skipping recovery (server starting in didFinishLaunching)")
            return
        }
        
        // Proactively refresh appUser's IP address when returning from background
        // This ensures we don't use stale IPs if the server changed while app was suspended
        Task {
            await refreshAppUserIP()
        }
        
        // Check how long app was in background
        if let backgroundDate = UserDefaults.standard.object(forKey: "lastBackgroundTimestamp") as? Date {
            let timeInBackground = Date().timeIntervalSince(backgroundDate)
            NSLog("☀️ [AppDelegate] App returning from \(Int(timeInBackground))s background")
            
            // CRITICAL: Use DURATION-based recovery, not isRunning check
            // isRunning can be TRUE even when NWListener is suspended by iOS (overnight)
            if timeInBackground > 300 {  // 5 minutes
                // LONG background - ALWAYS do full restart
                // Even if isRunning=true, the listener may be suspended and unresponsive
                NSLog("🔄 [AppDelegate] Long background (\(Int(timeInBackground))s) - forcing full restart")
                
                // Show loading indicator (non-blocking - allows user to scroll)
                showLoadingOverlay()
                
                // Restart infrastructure asynchronously (non-blocking)
                // Videos will show loading state until server is ready, but UI remains interactive
                Task.detached(priority: .userInitiated) {
                    // Restart server in background
                    await self.restartVideoInfrastructureAsync()
                    
                    // Hide loading indicator and notify videos when ready
                    await MainActor.run {
                        self.hideLoadingOverlay()
                        NotificationCenter.default.post(name: .videoInfrastructureRestarted, object: nil)
                        NSLog("✅ [AppDelegate] Server fully restarted - videos ready")
                    }
                }
            } else {
                // SHORT background (<5min) - simple approach: always clear and let videos recreate
                NSLog("🔄 [AppDelegate] Short background (\(Int(timeInBackground))s) - clearing players for clean state")
                
                // Always clear players for predictable recovery
                // Trying to keep them "intact" creates too many edge cases
                SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
                
                // Reset connection pool
                LocalHTTPServer.shared.resetConnectionPool()
                
                // Ensure server is running
                if !LocalHTTPServer.shared.isRunning {
                    NSLog("⚠️ [AppDelegate] Server not running, restarting...")
                    LocalHTTPServer.shared.startAndWait()
                }
                
                NSLog("✅ [AppDelegate] Short background recovery complete - players cleared")
                
                // Notify views to reload videos
                NotificationCenter.default.post(name: .videoInfrastructureRestarted, object: nil)
            }
        } else {
            // No background timestamp - this means app was just launched or killed
            // Server should already be started in didFinishLaunchingWithOptions
            // Just ensure it's running, but don't do full recovery
            NSLog("🚀 [AppDelegate] App startup or crash recovery - ensuring server is running")
            if !LocalHTTPServer.shared.isRunning {
                // Fast non-blocking start for app startup
                LocalHTTPServer.shared.start()
            } else {
                NSLog("✅ [AppDelegate] Server already running - no recovery needed")
            }
        }
        
        // Foreground handling is now done by SimpleVideoPlayer's notification observers
    }
    
    /// Refresh appUser's provider IP when app returns from background
    /// This prevents using stale IPs if the server moved while app was suspended
    private func refreshAppUserIP() async {
        let appUser = HproseInstance.shared.appUser
        
        // Only refresh for logged-in users
        guard !appUser.isGuest else {
            print("[AppDelegate] Skipping IP refresh for guest user")
            return
        }
        
        let hproseInstance = HproseInstance.shared
        
        // Refresh provider IP in background (non-blocking)
        Task.detached {
            do {
                print("[AppDelegate] Refreshing appUser provider IP...")
                
                // Force IP re-evaluation by passing empty baseUrl
                let refreshedUser = try await hproseInstance.fetchUser(appUser.mid, baseUrl: "")
                print("[AppDelegate] Successfully refreshed appUser provider IP")
                
                // Save updated user to cache if fetch was successful
                if let refreshedUser = refreshedUser {
                    TweetCacheManager.shared.saveUser(refreshedUser)
                    print("[AppDelegate] Saved refreshed appUser to cache")
                }
            } catch {
                print("[AppDelegate] ⚠️ Failed to refresh appUser IP: \(error)")
                // Non-fatal - we'll continue with cached IP and retry on next API call
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
        
        // OPTIMIZATION: Only stop if server is running, skip stop if already stopped
        // This avoids unnecessary wait if server was already stopped
        let needsStop = LocalHTTPServer.shared.isRunning
        if needsStop {
            LocalHTTPServer.shared.stop()
            // Reduced wait time - stop() is async and usually completes quickly
            // Server stop just cancels the listener, which is fast
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s instead of 0.5s
        }
        
        // Wait for player clearing to complete (runs in parallel)
        await clearTask.value
        
        // Restart the server - use faster method if possible
        // OPTIMIZATION: If server is already running (rare), skip restart
        if !LocalHTTPServer.shared.isRunning {
            LocalHTTPServer.shared.startAndWait()
        } else {
            print("[AppDelegate] Server already running - skipping restart")
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("[AppDelegate] Video infrastructure restart complete (async) in \(String(format: "%.2f", elapsed))s")
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
