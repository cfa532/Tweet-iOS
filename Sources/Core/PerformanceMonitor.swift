//
//  PerformanceMonitor.swift
//  Tweet
//
//  Monitors performance and prevents UI freezes during video loading
//

import Foundation
import UIKit

@MainActor
class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()
    
    private init() {
        setupMonitoring()
    }
    
    // MARK: - State
    @Published private(set) var isSystemUnderLoad = false
    @Published private(set) var activeVideoLoads = 0
    @Published private(set) var lastFreezeDetection = Date()
    
    // MARK: - Configuration
    private let maxConcurrentVideoLoads = 3
    private let freezeThreshold: TimeInterval = 0.1 // 100ms threshold for freeze detection
    private let loadCooldownPeriod: TimeInterval = 2.0 // 2 seconds cooldown after freeze
    
    // MARK: - Monitoring
    private var lastMainThreadCheck = Date()
    private var freezeCount = 0
    private var isInCooldown = false
    
    // MARK: - Public Methods
    
    /// Check if the system can handle more video loads
    func canLoadMoreVideos() -> Bool {
        if isInCooldown {
            let timeSinceFreeze = Date().timeIntervalSince(lastFreezeDetection)
            if timeSinceFreeze < loadCooldownPeriod {
                return false
            } else {
                isInCooldown = false
            }
        }
        
        return activeVideoLoads < maxConcurrentVideoLoads && !isSystemUnderLoad
    }
    
    /// Notify that a video load is starting
    func videoLoadStarted() {
        activeVideoLoads += 1
        print("DEBUG: [PerformanceMonitor] Video load started. Active loads: \(activeVideoLoads)")
        
        if activeVideoLoads >= maxConcurrentVideoLoads {
            isSystemUnderLoad = true
            print("DEBUG: [PerformanceMonitor] System under load - max concurrent loads reached")
        }
    }
    
    /// Notify that a video load completed
    func videoLoadCompleted() {
        activeVideoLoads = max(0, activeVideoLoads - 1)
        print("DEBUG: [PerformanceMonitor] Video load completed. Active loads: \(activeVideoLoads)")
        
        if activeVideoLoads < maxConcurrentVideoLoads {
            isSystemUnderLoad = false
        }
    }
    
    /// Check for UI freeze conditions
    func checkForFreeze() {
        let now = Date()
        let timeSinceLastCheck = now.timeIntervalSince(lastMainThreadCheck)
        
        if timeSinceLastCheck > freezeThreshold {
            freezeCount += 1
            lastFreezeDetection = now
            isInCooldown = true
            
            print("DEBUG: [PerformanceMonitor] Potential UI freeze detected! Time since last check: \(timeSinceLastCheck)s")
            print("DEBUG: [PerformanceMonitor] Freeze count: \(freezeCount), entering cooldown period")
            
            // Trigger emergency cleanup if needed
            if freezeCount > 3 {
                emergencyCleanup()
            }
        }
        
        lastMainThreadCheck = now
    }
    
    /// Get performance status for debugging
    func getPerformanceStatus() -> String {
        return """
        Performance Status:
        - Active video loads: \(activeVideoLoads)/\(maxConcurrentVideoLoads)
        - System under load: \(isSystemUnderLoad)
        - In cooldown: \(isInCooldown)
        - Freeze count: \(freezeCount)
        - Time since last freeze: \(Date().timeIntervalSince(lastFreezeDetection))s
        """
    }
    
    // MARK: - Private Methods
    
    private func setupMonitoring() {
        // Monitor main thread performance
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                self.checkForFreeze()
            }
        }
        
        // Reset freeze count periodically
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            Task { @MainActor in
                if self.freezeCount > 0 {
                    self.freezeCount = max(0, self.freezeCount - 1)
                }
            }
        }
    }
    
    private func emergencyCleanup() {
        print("DEBUG: [PerformanceMonitor] Emergency cleanup triggered!")
        
        // Cancel all pending video loads
        NotificationCenter.default.post(name: .stopAllVideos, object: nil)
        
        // Clear video caches
        Task { @MainActor in
            SharedAssetCache.shared.clearAllCaches()
            VideoStateCache.shared.clearAllCache()
        }
        
        // Reset performance state
        activeVideoLoads = 0
        isSystemUnderLoad = false
        isInCooldown = false
        freezeCount = 0
        
        print("DEBUG: [PerformanceMonitor] Emergency cleanup completed")
    }
}
