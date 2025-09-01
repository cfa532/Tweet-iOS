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
    private let maxConcurrentVideoLoads = 5 // Increased from 3 to 5 for better performance
    private let freezeThreshold: TimeInterval = 0.2 // Increased from 0.1 to 200ms for less aggressive detection
    private let loadCooldownPeriod: TimeInterval = 1.0 // Reduced from 2.0 to 1 second for faster recovery
    
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
            if freezeCount > 5 { // Increased from 3 to 5 to be less aggressive
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
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in // Increased from 0.05 to 0.1 for less frequent monitoring
            Task { @MainActor in
                self.checkForFreeze()
            }
        }
        
        // Reset freeze count periodically
        Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { _ in // Reduced from 30.0 to 20.0 for faster recovery
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
        
        // Note: Video caches are preserved to maintain user experience
        // Only cancel operations, don't clear cached data
        
        // Reset performance state
        activeVideoLoads = 0
        isSystemUnderLoad = false
        isInCooldown = false
        freezeCount = 0
        
        print("DEBUG: [PerformanceMonitor] Emergency cleanup completed (video caches preserved)")
    }
}
