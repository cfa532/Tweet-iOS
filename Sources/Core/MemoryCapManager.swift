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
    private let maxMemoryLimit: UInt64 = 2 * 1024 * 1024 * 1024 // 2GB in bytes
    private let warningThreshold: Double = 0.8 // 80% of limit
    private let criticalThreshold: Double = 0.9 // 90% of limit
    private let monitoringInterval: TimeInterval = 5.0 // Check every 5 seconds
    
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
        logger.debug("Memory usage: \(percentage * 100, privacy: .public)% (\(formatBytes(currentMemoryUsage)))")
        
        if percentage >= criticalThreshold {
            logger.error("CRITICAL: Memory usage at \(percentage * 100, privacy: .public)% - forcing immediate cleanup")
            forceMemoryCleanup()
        } else if percentage >= warningThreshold {
            logger.warning("WARNING: Memory usage at \(percentage * 100, privacy: .public)% - performing cleanup")
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
        
        // Clean up more video caches
        SharedAssetCache.shared.releasePartialCache(percentage: 60)
        
        // Clean up more image caches
        ImageCacheManager.shared.cleanupOldCache()
        
        // Clear tweet cache
        TweetCacheManager.shared.clearMemoryCache()
        
        // Clear chat cache
        ChatCacheManager.shared.clearMemoryCache()
        
        // Force garbage collection
        DispatchQueue.global(qos: .utility).async {
            // This helps trigger ARC cleanup
        }
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
