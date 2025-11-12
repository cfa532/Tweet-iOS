import Foundation
import UIKit
import os.log

/// Manages memory usage with a 2GB cap to prevent OS termination
class MemoryCapManager {
    static let shared = MemoryCapManager()
    
    private init() {
        setupMemoryMonitoring()
        setupMemoryWarnings()
    }
    
    // MARK: - Configuration
    private let maxMemoryLimit: UInt64 = 2 * 1024 * 1024 * 1024 // 2GB in bytes - HARD CAP
    private let warningThreshold: Double = 0.70 // 70% of limit (start cleanup earlier)
    private let criticalThreshold: Double = 0.85 // 85% of limit (aggressive cleanup)
    private let emergencyThreshold: Double = 0.95 // 95% of limit (emergency cleanup)
    private let monitoringInterval: TimeInterval = 3.0 // Check every 3 seconds (more frequent)
    private let duplicateBlockThreshold: Double = 0.60 // 60% of limit - block duplicate fetches
    
    // MARK: - State
    private var monitoringTimer: Timer?
    private var currentMemoryUsage: UInt64 = 0
    private var isMemoryWarningActive = false
    private let logger = Logger(subsystem: "Tweet", category: "MemoryCapManager")
    
    // MARK: - Public Interface
    
    /// Get current memory usage in bytes
    var currentMemoryUsageBytes: UInt64 {
        return currentMemoryUsage
    }
    
    /// Get current memory usage as percentage of limit
    var memoryUsagePercentage: Double {
        return Double(currentMemoryUsage) / Double(maxMemoryLimit)
    }
    
    /// Check if memory usage is above warning threshold
    var isAboveWarningThreshold: Bool {
        return memoryUsagePercentage >= warningThreshold
    }
    
    /// Check if memory usage is above duplicate-request block threshold
    var isAboveDuplicateBlockThreshold: Bool {
        return memoryUsagePercentage >= duplicateBlockThreshold
    }
    
    /// Duplicate-request block threshold percentage (e.g., 0.60)
    var duplicateBlockThresholdPercentage: Double {
        return duplicateBlockThreshold
    }
    
    /// Check if memory usage is above critical threshold
    var isAboveCriticalThreshold: Bool {
        return memoryUsagePercentage >= criticalThreshold
    }
    
    /// Force immediate memory cleanup
    @MainActor
    func forceMemoryCleanup() {
        logger.warning("Force memory cleanup triggered - current usage: \(self.memoryUsagePercentage * 100, privacy: .public)%")
        
        // Perform aggressive cleanup
        performAggressiveCleanup()
        
        // Update memory usage after cleanup
        updateMemoryUsage()
    }
    
    // MARK: - Private Methods
    
    private func setupMemoryMonitoring() {
        // Start continuous monitoring
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: monitoringInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkMemoryUsage()
            }
        }
        
        // Initial memory check
        updateMemoryUsage()
        
        logger.info("Memory monitoring started with 2GB limit")
    }
    
    private func setupMemoryWarnings() {
        // Listen for system memory warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        
        // Listen for app lifecycle events
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
    }
    
    @MainActor
    @objc private func handleMemoryWarning() {
        logger.warning("System memory warning received")
        
        // Check memory usage before cleanup (don't cleanup at low usage)
        let memoryUsageMB = currentMemoryUsage / (1024 * 1024)
        logger.info("Current memory usage: \(memoryUsageMB)MB")
        
        // Only cleanup if usage exceeds 1.4GB (preventive cleanup threshold)
        if memoryUsageMB > 1400 {
            logger.warning("Memory usage exceeds 1.4GB, performing cleanup")
            forceMemoryCleanup()
        } else {
            logger.info("Memory usage under 1.4GB, ignoring system warning (likely false alarm)")
        }
    }
    
    @MainActor
    @objc private func handleAppDidEnterBackground() {
        logger.info("App entered background - performing cleanup")
        performBackgroundCleanup()
    }
    
    @objc private func handleAppWillEnterForeground() {
        logger.info("App entering foreground - resuming monitoring")
        updateMemoryUsage()
    }
    
    @MainActor
    private func checkMemoryUsage() {
        updateMemoryUsage()
        
        let percentage = memoryUsagePercentage
        
        // Only log when memory usage is 60% or higher
        if percentage >= 0.6 {
            logger.debug("Memory usage: \(percentage * 100, privacy: .public)% (\(self.formatBytes(self.currentMemoryUsage)))")
        }
        
        // Only log when above warning threshold
        if percentage >= emergencyThreshold {
            logger.error("EMERGENCY: Memory at \(percentage * 100, privacy: .public)% - HARD CAP enforcement")
            print("⚠️ EMERGENCY: Memory at \(String(format: "%.1f", percentage * 100))% - performing emergency cleanup")
            performEmergencyCleanup()
        } else if percentage >= criticalThreshold {
            logger.error("CRITICAL: Memory at \(percentage * 100, privacy: .public)% - aggressive cleanup")
            print("⚠️ CRITICAL: Memory at \(String(format: "%.1f", percentage * 100))% - performing aggressive cleanup")
            performAggressiveCleanup()
        } else if percentage >= warningThreshold {
            logger.warning("WARNING: Memory at \(percentage * 100, privacy: .public)% - preventive cleanup")
            print("⚠️ WARNING: Memory at \(String(format: "%.1f", percentage * 100))% - performing preventive cleanup")
            performPreventiveCleanup()
        }
    }
    
    private func updateMemoryUsage() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / mach_msg_type_number_t(MemoryLayout<natural_t>.size)
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_,
                         task_flavor_t(TASK_VM_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            // Use phys_footprint for accurate memory measurement (matches Xcode)
            currentMemoryUsage = UInt64(info.phys_footprint)
        } else {
            logger.error("Failed to get memory usage: \(kerr)")
        }
    }
    
    @MainActor
    private func performPreventiveCleanup() {
        logger.info("Performing preventive memory cleanup")
        
        // Clean up video caches (memory)
        SharedAssetCache.shared.releasePartialCache(percentage: 30)
        
        // Clean up image caches
        ImageCacheManager.shared.cleanupOldCache()
        
        // Force garbage collection
        DispatchQueue.global(qos: .utility).async {
            // This helps trigger ARC cleanup
        }
    }
    
    @MainActor
    private func performAggressiveCleanup() {
        logger.info("Performing aggressive memory cleanup")
        
        // CRITICAL: Cancel active downloads first to stop memory growth
        SharedAssetCache.shared.cancelAllLoadingTasks()
        
        // Clean up more video caches (memory)
        SharedAssetCache.shared.releasePartialCache(percentage: 60)
        
        // Clean up more image caches
        ImageCacheManager.shared.cleanupOldCache()
        
        // Clear tweet cache
        TweetCacheManager.shared.clearMemoryCache()
        
        // Clear chat cache
        ChatCacheManager.shared.clearMemoryCache()
        
        // Notify user about memory pressure
        let memoryMB = currentMemoryUsage / (1024 * 1024)
        NotificationCenter.default.post(
            name: .memoryWarningCritical,
            object: nil,
            userInfo: ["memoryMB": memoryMB, "severity": "high"]
        )
        
        // Force garbage collection
        DispatchQueue.global(qos: .utility).async {
            // This helps trigger ARC cleanup
        }
    }
    
    @MainActor
    private func performEmergencyCleanup() {
        logger.error("Performing EMERGENCY memory cleanup to enforce 2GB hard cap")
        
        // CRITICAL: Cancel ALL active downloads IMMEDIATELY to stop memory growth
        SharedAssetCache.shared.cancelAllLoadingTasks()
        
        // Clear 80% of video caches - keep only most recent
        SharedAssetCache.shared.releasePartialCache(percentage: 80)
        
        // Clear image caches aggressively
        ImageCacheManager.shared.cleanupOldCache()
        
        // Clear ALL memory caches
        TweetCacheManager.shared.clearMemoryCache()
        ChatCacheManager.shared.clearMemoryCache()
        
        // Clear video state cache
        VideoStateCache.shared.clearAllCache()
        
        // Notify user about critical memory situation
        let memoryMB = currentMemoryUsage / (1024 * 1024)
        NotificationCenter.default.post(
            name: .memoryWarningCritical,
            object: nil,
            userInfo: ["memoryMB": memoryMB, "severity": "critical"]
        )
        
        // Force garbage collection
        DispatchQueue.global(qos: .utility).async {
            autoreleasepool {
                // Force memory reclamation
            }
        }
        
        print("⚠️ EMERGENCY CLEANUP COMPLETE - cancelled all downloads, cleared 80% of caches to stay under 2GB cap")
    }
    
    @MainActor
    private func performBackgroundCleanup() {
        logger.info("Performing background cleanup")
        
        // Check current memory usage
        let percentage = memoryUsagePercentage
        logger.info("Memory usage at background: \(percentage * 100, privacy: .public)%")
        
        // Only perform aggressive cleanup if memory usage is high
        if percentage >= warningThreshold {
            logger.info("Memory above warning threshold, performing cleanup")
            
            // Clean up video caches
            SharedAssetCache.shared.releasePartialCache(percentage: 30)
            
            // Clean up image caches
            ImageCacheManager.shared.cleanupOldCache()
            
            // Clear tweet cache
            TweetCacheManager.shared.clearMemoryCache()
            
            // Clear chat cache
            ChatCacheManager.shared.clearMemoryCache()
        } else {
            logger.info("Memory usage normal, skipping background cleanup to preserve caches")
        }
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    deinit {
        monitoringTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Memory Statistics
extension MemoryCapManager {
    
    /// Get detailed memory statistics
    func getMemoryStatistics() -> (currentUsage: UInt64, limit: UInt64, percentage: Double, status: String) {
        let percentage = memoryUsagePercentage
        let status: String
        
        if percentage >= criticalThreshold {
            status = "CRITICAL"
        } else if percentage >= warningThreshold {
            status = "WARNING"
        } else {
            status = "NORMAL"
        }
        
        return (
            currentUsage: currentMemoryUsage,
            limit: maxMemoryLimit,
            percentage: percentage,
            status: status
        )
    }
    
    /// Get memory usage as formatted string
    func getFormattedMemoryUsage() -> String {
        let stats = getMemoryStatistics()
        return "\(formatBytes(stats.currentUsage)) / \(formatBytes(stats.limit)) (\(Int(stats.percentage * 100))%)"
    }
}

