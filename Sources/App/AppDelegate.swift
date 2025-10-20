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
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.example.Tweet.messageCheck", using: nil) { task in
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
        let request = BGAppRefreshTaskRequest(identifier: "com.example.Tweet.messageCheck")
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
        print("[AppDelegate] App will resign active")
    }
    
    @objc private func handleAppDidBecomeActive() {
        print("[AppDelegate] App did become active - posting notification")
        
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
                // LONG background - ALWAYS do full restart with BLOCKING
                // Even if isRunning=true, the listener may be suspended and unresponsive
                NSLog("🔄 [AppDelegate] Long background (\(Int(timeInBackground))s) - forcing full restart")
                
                // Show loading indicator and wait for it to render
                showLoadingOverlay()
                Thread.sleep(forTimeInterval: 0.1) // Give UI time to render
                
                // Restart infrastructure - this is synchronous and blocks until complete
                restartVideoInfrastructure()
                
                // Hide loading indicator
                hideLoadingOverlay()
                
                NSLog("✅ [AppDelegate] Server fully restarted - videos ready")
            } else {
                // SHORT background (<5min) - just clear players, server should be responsive
                NSLog("🔄 [AppDelegate] Short background (\(Int(timeInBackground))s) - clearing players only")
                
                // Check if server is still running
                if LocalHTTPServer.shared.isRunning {
                    // Server still alive - just clear video players for fresh connections
                    // DON'T clear VideoStateCache - videos will resume from where they left off
                    SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
                    
                    // CRITICAL: Reset connection pool to close stale connections
                    // Without this, we get "Connection reset by peer" errors causing video blinking
                    NSLog("DEBUG: [AppDelegate] Resetting connection pool for short background recovery")
                    LocalHTTPServer.shared.resetConnectionPool()
                    
                    NSLog("✅ [AppDelegate] Players cleared, server still running")
                    
                    // Notify views to reload media (critical after cache clear + immediate background)
                    NotificationCenter.default.post(name: .videoInfrastructureRestarted, object: nil)
                    print("[AppDelegate] Posted videoInfrastructureRestarted notification for short background")
                } else {
                    // Server was killed even in short background - restart it
                    NSLog("⚠️ [AppDelegate] Server killed in short background, restarting...")
                    SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
                    // DON'T clear VideoStateCache - preserve playback position for smooth resume
                    
                    // Show brief spinner for server restart
                    showLoadingOverlay()
                    Thread.sleep(forTimeInterval: 0.05)
                    
                    LocalHTTPServer.shared.startAndWait()
                    
                    hideLoadingOverlay()
                    NSLog("✅ [AppDelegate] Server restarted")
                    
                    // Notify views to reload media
                    NotificationCenter.default.post(name: .videoInfrastructureRestarted, object: nil)
                    print("[AppDelegate] Posted videoInfrastructureRestarted notification after server restart")
                }
            }
        } else {
            NSLog("⚠️ [AppDelegate] No background timestamp, starting server")
            LocalHTTPServer.shared.start()
        }
        
        // Foreground handling is now done by SimpleVideoPlayer's notification observers
    }
    
    /// Refresh appUser's IP address when app returns from background
    /// This prevents using stale IPs if the server moved while app was suspended
    private func refreshAppUserIP() async {
        let appUser = HproseInstance.shared.appUser
        
        // Only refresh for logged-in users
        guard !appUser.isGuest else {
            print("[AppDelegate] Skipping IP refresh for guest user")
            return
        }
        
        // Get fresh IP from server
        do {
            print("[AppDelegate] Refreshing appUser IP address...")
            let hproseInstance = HproseInstance.shared
            
            // Get current provider IP
            guard let freshIP = try await hproseInstance.getProviderIP(appUser.mid) else {
                print("[AppDelegate] Failed to get provider IP for appUser")
                return
            }
            
            let oldIP = appUser.baseUrl?.host ?? "nil"
            let newIP = freshIP
            
            // Update appUser's baseUrl if IP has changed
            await MainActor.run {
                appUser.baseUrl = URL(string: "http://\(freshIP)")
                
                if oldIP != newIP {
                    print("[AppDelegate] ✅ AppUser IP updated: \(oldIP) → \(newIP)")
                } else {
                    print("[AppDelegate] ✅ AppUser IP unchanged: \(newIP)")
                }
            }
            
            // Also update the HproseInstance base URL if this is the primary user
            if HproseInstance.baseUrl.host != freshIP {
                HproseInstance.baseUrl = URL(string: "http://\(freshIP)")!
                hproseInstance.client.uri = HproseInstance.baseUrl.appendingPathComponent("/webapi/").absoluteString
                print("[AppDelegate] Updated HproseInstance baseUrl to: \(freshIP)")
            }
            
        } catch {
            print("[AppDelegate] ⚠️ Failed to refresh appUser IP: \(error)")
            // Non-fatal - we'll continue with cached IP and retry on next API call
        }
    }
    
    private func restartVideoInfrastructure() {
        print("[AppDelegate] Restarting video infrastructure after long background")
        
        // CRITICAL: Clear ALL video players FIRST to release their URLs
        // This prevents players from trying to use old port numbers after server restart
        // Note: We're already on main thread (called from willEnterForeground), so just call directly
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