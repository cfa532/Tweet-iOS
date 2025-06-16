import Foundation
import MetricKit
import OSLog

@available(iOS 13.0, *)
class MetricKitManager: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitManager()
    private let logger = Logger(subsystem: "com.tweet", category: "MetricKit")
    
    private override init() {
        super.init()
        MXMetricManager.shared.add(self)
    }
    
    deinit {
        MXMetricManager.shared.remove(self)
    }
    
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            // Process memory metrics
            if let memoryMetrics = payload.memoryMetrics {
                let peakMemoryUsage = memoryMetrics.peakMemoryUsage
                
                logger.info("""
                    Memory Metrics:
                    Peak Memory Usage: \(peakMemoryUsage) bytes
                    """)
            }
            
            // Process CPU metrics
            if let cpuMetrics = payload.cpuMetrics {
                logger.info("""
                    CPU Metrics:
                    Cumulative CPU Time: \(cpuMetrics.cumulativeCPUTime)
                    Cumulative CPU Instructions: \(cpuMetrics.cumulativeCPUInstructions)
                    """)
            }
            
            // Process disk I/O metrics
            if let diskIOMetrics = payload.diskIOMetrics {
                logger.info("""
                    Disk I/O Metrics:
                    Cumulative Logical Writes: \(diskIOMetrics.cumulativeLogicalWrites)
                    """)
            }
        }
    }
    
    func pauseMetricCollection() {
        MXMetricManager.shared.remove(self)
    }
    
    func resumeMetricCollection() {
        MXMetricManager.shared.add(self)
    }
} 