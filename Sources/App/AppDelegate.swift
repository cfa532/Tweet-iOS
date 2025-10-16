import UIKit
import SwiftUI
import BackgroundTasks
import UserNotifications
import AVFoundation
import ffmpegkit

class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.all
    
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
        print("[AppDelegate] App did enter background")
        
        // Stop LocalHTTPServer and release the port to free system resources
        LocalHTTPServer.shared.stop()
        
        // Store timestamp when app went to background
        UserDefaults.standard.set(Date(), forKey: "lastBackgroundTimestamp")
        
        // Background handling is now done by SimpleVideoPlayer's notification observers
    }
    
    @objc private func handleAppWillEnterForeground() {
        print("[AppDelegate] App will enter foreground")
        
        // Restart LocalHTTPServer (it was stopped when app went to background)
        LocalHTTPServer.shared.start()
        
        // Proactively refresh appUser's IP address when returning from background
        // This ensures we don't use stale IPs if the server changed while app was suspended
        Task {
            await refreshAppUserIP()
        }
        
        // Check how long app was in background
        if let backgroundDate = UserDefaults.standard.object(forKey: "lastBackgroundTimestamp") as? Date {
            let timeInBackground = Date().timeIntervalSince(backgroundDate)
            print("[AppDelegate] App was in background for \(timeInBackground) seconds")
            
            // If app was in background for more than 5 minutes, reset connection pool
            // and clear video player caches to force fresh initialization
            if timeInBackground > 300 { // 5 minutes
                print("[AppDelegate] Long background period detected, resetting connection pool")
                
                // Reset connection pool to recover from long background suspension
                LocalHTTPServer.shared.resetConnectionPool()
                
                // Restart video infrastructure
                Task {
                    await restartVideoInfrastructure()
                }
            }
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
    
    private func restartVideoInfrastructure() async {
        print("[AppDelegate] Restarting video infrastructure after long background")
        
        // Reset LocalHTTPServer connection pool
        LocalHTTPServer.shared.resetConnectionPool()
        
        // Restart the server
        LocalHTTPServer.shared.stop()
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        LocalHTTPServer.shared.start()
        
        // Clear video player caches to force fresh initialization
        await MainActor.run {
            SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
        }
        
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
} 