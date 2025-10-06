import Foundation
import AVFoundation

/// Manages video segments with memory efficiency - only keeps current and upcoming segments in memory
class MemoryEfficientSegmentManager {
    static let shared = MemoryEfficientSegmentManager()
    
    private init() {}
    
    // MARK: - Configuration
    private let maxSegmentsInMemory = 5 // Keep current + next 4 segments
    private let cleanupDelay: TimeInterval = 2.0 // Delay before cleaning up played segments
    
    // MARK: - State Tracking
    private var segmentTrackers: [String: SegmentTracker] = [:] // mediaID -> tracker
    private var cleanupTimers: [String: Timer] = [:]
    private var optimizationThrottle: [String: Date] = [:] // mediaID -> last optimization time
    private let optimizationThrottleInterval: TimeInterval = 1.0 // Minimum 1 second between optimizations
    
    // MARK: - Segment Tracker
    private class SegmentTracker {
        let mediaID: String
        var segments: [String: SegmentInfo] = [:] // segmentName -> info
        var currentPlaybackTime: Double = 0
        var lastCleanupTime: Date = Date()
        
        init(mediaID: String) {
            self.mediaID = mediaID
        }
        
        struct SegmentInfo {
            let name: String
            let startTime: Double
            let endTime: Double
            let filePath: String
            var isPlayed: Bool = false
            var isInMemory: Bool = false
            let lastAccessed: Date = Date()
        }
    }
    
    // MARK: - Public Methods
    
    /// Register a new segment for tracking
    func registerSegment(_ segmentName: String, startTime: Double, endTime: Double, filePath: String, for mediaID: String) {
        print("DEBUG: [MemoryEfficientSegmentManager] Registering segment \(segmentName) for \(mediaID) (time: \(startTime)-\(endTime)s)")
        
        let tracker = getOrCreateTracker(for: mediaID)
        let segmentInfo = SegmentTracker.SegmentInfo(
            name: segmentName,
            startTime: startTime,
            endTime: endTime,
            filePath: filePath
        )
        
        tracker.segments[segmentName] = segmentInfo
        
        // Trigger memory optimization with throttling to avoid blocking UI
        throttleOptimization(for: mediaID)
    }
    
    /// Update playback position for a media ID
    func updatePlaybackPosition(_ currentTime: Double, for mediaID: String) {
        guard let tracker = segmentTrackers[mediaID] else { return }
        
        tracker.currentPlaybackTime = currentTime
        
        // Mark segments as played if they've been passed
        for (segmentName, var segmentInfo) in tracker.segments {
            if !segmentInfo.isPlayed && currentTime > segmentInfo.endTime {
                segmentInfo.isPlayed = true
                tracker.segments[segmentName] = segmentInfo
                
                print("DEBUG: [MemoryEfficientSegmentManager] Marked segment \(segmentName) as played for \(mediaID)")
                
                // Schedule cleanup for this segment
                scheduleCleanupForSegment(segmentName, mediaID: mediaID)
            }
        }
        
        // Trigger memory optimization with throttling to avoid blocking UI
        throttleOptimization(for: mediaID)
    }
    
    /// Clean up resources for a media ID (called when video is no longer needed)
    func cleanupMedia(_ mediaID: String) {
        print("DEBUG: [MemoryEfficientSegmentManager] Cleaning up all resources for \(mediaID)")
        
        // Cancel cleanup timer
        cleanupTimers[mediaID]?.invalidate()
        cleanupTimers.removeValue(forKey: mediaID)
        
        // Remove throttle tracking
        optimizationThrottle.removeValue(forKey: mediaID)
        
        // Remove tracker
        segmentTrackers.removeValue(forKey: mediaID)
    }
    
    /// Perform global cleanup for all media (called by MemoryCapManager)
    func performGlobalCleanup() {
        print("DEBUG: [MemoryEfficientSegmentManager] Performing global cleanup for all media")
        
        // Clean up all media
        for mediaID in segmentTrackers.keys {
            cleanupMedia(mediaID)
        }
        
        // Clear all timers
        cleanupTimers.removeAll()
        
        // Clear throttle tracking
        optimizationThrottle.removeAll()
        
        print("DEBUG: [MemoryEfficientSegmentManager] Global cleanup completed")
    }
    
    /// Get segments that should be kept in memory for a media ID
    func getSegmentsToKeepInMemory(for mediaID: String) -> [String] {
        guard let tracker = segmentTrackers[mediaID] else { return [] }
        
        let currentTime = tracker.currentPlaybackTime
        let sortedSegments = tracker.segments.values.sorted { $0.startTime < $1.startTime }
        
        // Find current and upcoming segments
        var segmentsToKeep: [String] = []
        
        for segment in sortedSegments {
            // Keep segments that are currently playing or will play soon
            if segment.startTime >= currentTime - 1.0 && segmentsToKeep.count < maxSegmentsInMemory {
                segmentsToKeep.append(segment.name)
            }
        }
        
        return segmentsToKeep
    }
    
    // MARK: - Private Methods
    
    /// Throttled optimization to prevent excessive calls
    private func throttleOptimization(for mediaID: String) {
        let now = Date()
        
        // Check if we should throttle this optimization
        if let lastOptimization = optimizationThrottle[mediaID],
           now.timeIntervalSince(lastOptimization) < optimizationThrottleInterval {
            return // Skip this optimization due to throttling
        }
        
        // Update throttle timestamp
        optimizationThrottle[mediaID] = now
        
        // Perform optimization asynchronously
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.optimizeMemoryForMedia(mediaID)
        }
    }
    
    private func getOrCreateTracker(for mediaID: String) -> SegmentTracker {
        if let existing = segmentTrackers[mediaID] {
            return existing
        }
        
        let tracker = SegmentTracker(mediaID: mediaID)
        segmentTrackers[mediaID] = tracker
        print("DEBUG: [MemoryEfficientSegmentManager] Created new tracker for \(mediaID)")
        
        return tracker
    }
    
    private func optimizeMemoryForMedia(_ mediaID: String) {
        guard let tracker = segmentTrackers[mediaID] else { return }
        
        let segmentsToKeep = getSegmentsToKeepInMemory(for: mediaID)
        
        // Clean up segments that shouldn't be in memory
        for (segmentName, var segmentInfo) in tracker.segments {
            let shouldKeep = segmentsToKeep.contains(segmentName)
            
            if !shouldKeep && segmentInfo.isInMemory {
                // Remove from memory (but keep file on disk for caching)
                segmentInfo.isInMemory = false
                tracker.segments[segmentName] = segmentInfo
                
                print("DEBUG: [MemoryEfficientSegmentManager] Removed segment \(segmentName) from memory for \(mediaID) (file kept on disk)")
            }
        }
    }
    
    private func scheduleCleanupForSegment(_ segmentName: String, mediaID: String) {
        // Cancel existing timer for this media
        cleanupTimers[mediaID]?.invalidate()
        
        // Schedule new cleanup
        let timer = Timer.scheduledTimer(withTimeInterval: cleanupDelay, repeats: false) { [weak self] _ in
            self?.performCleanupForMedia(mediaID)
        }
        cleanupTimers[mediaID] = timer
        
        print("DEBUG: [MemoryEfficientSegmentManager] Scheduled cleanup for \(mediaID) in \(cleanupDelay)s")
    }
    
    private func performCleanupForMedia(_ mediaID: String) {
        guard let tracker = segmentTrackers[mediaID] else { return }
        
        print("DEBUG: [MemoryEfficientSegmentManager] Performing cleanup for \(mediaID)")
        
        let segmentsToKeep = getSegmentsToKeepInMemory(for: mediaID)
        
        // Clean up played segments that are not needed
        for (segmentName, segmentInfo) in tracker.segments {
            let shouldKeep = segmentsToKeep.contains(segmentName)
            
            if !shouldKeep && segmentInfo.isPlayed {
                // Remove from tracker (but keep file on disk for caching)
                tracker.segments.removeValue(forKey: segmentName)
                
                print("DEBUG: [MemoryEfficientSegmentManager] Cleaned up segment \(segmentName) from tracking for \(mediaID) (file kept on disk)")
            }
        }
        
        // Update last cleanup time
        tracker.lastCleanupTime = Date()
    }
    
}

// MARK: - Memory Monitoring Extension
extension MemoryEfficientSegmentManager {
    
    /// Get memory usage statistics
    func getMemoryStats() -> (totalSegments: Int, segmentsInMemory: Int, memoryUsage: String) {
        var totalSegments = 0
        var segmentsInMemory = 0
        
        for tracker in segmentTrackers.values {
            totalSegments += tracker.segments.count
            segmentsInMemory += tracker.segments.values.filter { $0.isInMemory }.count
        }
        
        let memoryUsage = "\(segmentsInMemory)/\(totalSegments) segments in memory"
        
        return (totalSegments, segmentsInMemory, memoryUsage)
    }
    
    /// Force cleanup of all played segments (for memory pressure)
    func forceCleanupPlayedSegments() {
        print("DEBUG: [MemoryEfficientSegmentManager] Force cleanup of all played segments")
        
        for mediaID in segmentTrackers.keys {
            performCleanupForMedia(mediaID)
        }
    }
}
