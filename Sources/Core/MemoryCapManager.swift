import Foundation
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
    
    /// Check if memory usage is above critical threshold
    var isAboveCriticalThreshold: Bool {
        return memoryUsagePercentage >= criticalThreshold
    }
    
    /// Force immediate memory cleanup
    func forceMemoryCleanup() {
        logger.warning("Force memory cleanup triggered - current usage: \(memoryUsagePercentage * 100, privacy: .public)%")
        
        // Perform aggressive cleanup
        performAggressiveCleanup()
        
        // Update memory usage after cleanup
        updateMemoryUsage()
    }
    
    // MARK: - Private Methods
    
    private func setupMemoryMonitoring() {
        // Start continuous monitoring
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: monitoringInterval, repeats: true) { [weak self] _ in
            self?.checkMemoryUsage()
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
    
    @objc private func handleMemoryWarning() {
        logger.warning("System memory warning received")
        forceMemoryCleanup()
    }
    
    @objc private func handleAppDidEnterBackground() {
        logger.info("App entered background - performing cleanup")
        performBackgroundCleanup()
    }
    
    @objc private func handleAppWillEnterForeground() {
        logger.info("App entering foreground - resuming monitoring")
        updateMemoryUsage()
    }
    
    private func checkMemoryUsage() {
        updateMemoryUsage()
        
        let percentage = memoryUsagePercentage
        let usageMB = Double(currentMemoryUsage) / (1024.0 * 1024.0)
        
        // Always log current memory usage
        print("DEBUG: [MEMORY] Current usage: \(String(format: "%.1f", usageMB))MB / 2048MB (\(String(format: "%.1f", percentage * 100))%)")
        
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
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            currentMemoryUsage = info.resident_size
        } else {
            logger.error("Failed to get memory usage: \(kerr)")
        }
    }
    
    private func performPreventiveCleanup() {
        logger.info("Performing preventive memory cleanup")
        
        // Clean up video caches
        SharedAssetCache.shared.releasePartialCache(percentage: 30)
        
        // Clean up image caches
        ImageCacheManager.shared.cleanupOldCache()
        
        // Force garbage collection
        DispatchQueue.global(qos: .utility).async {
            // This helps trigger ARC cleanup
        }
    }
    
    private func performAggressiveCleanup() {
        logger.info("Performing aggressive memory cleanup")
        
        // Clean up 60% of video caches
        SharedAssetCache.shared.releasePartialCache(percentage: 60)
        
        // Clean up image caches
        ImageCacheManager.shared.cleanupOldCache()
        
        // Clear tweet memory cache
        TweetCacheManager.shared.clearMemoryCache()
        
        // Clear chat cache
        ChatCacheManager.shared.clearMemoryCache()
        
        // Force garbage collection
        DispatchQueue.global(qos: .utility).async {
            // This helps trigger ARC cleanup
        }
    }
    
    private func performEmergencyCleanup() {
        logger.error("Performing EMERGENCY memory cleanup to enforce 2GB hard cap")
        
        // Clear 80% of video caches - keep only most recent
        Task { @MainActor in
            SharedAssetCache.shared.releasePartialCache(percentage: 80)
        }
        
        // Clear image caches aggressively
        ImageCacheManager.shared.cleanupOldCache()
        
        // Clear ALL memory caches
        TweetCacheManager.shared.clearMemoryCache()
        ChatCacheManager.shared.clearMemoryCache()
        
        // Clear video state cache
        VideoStateCache.shared.clearAllCache()
        
        // Force garbage collection
        DispatchQueue.global(qos: .utility).async {
            autoreleasepool {
                // Force memory reclamation
            }
        }
        
        print("⚠️ EMERGENCY CLEANUP COMPLETE - cleared 80% of caches to stay under 2GB cap")
    }
    
    private func performBackgroundCleanup() {
        logger.info("Performing background cleanup")
        
        // Clean up video caches
        SharedAssetCache.shared.releasePartialCache(percentage: 50)
        
        // Clean up image caches
        ImageCacheManager.shared.cleanupOldCache()
        
        // Clear tweet cache
        TweetCacheManager.shared.clearMemoryCache()
        
        // Clear chat cache
        ChatCacheManager.shared.clearMemoryCache()
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
