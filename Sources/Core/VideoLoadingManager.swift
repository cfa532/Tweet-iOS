import Foundation
import AVKit
import Combine

/// Priority levels for video loading
enum VideoLoadingPriority: Int, CaseIterable {
    case high = 0      // Visible videos that should load immediately
    case normal = 1    // Videos that are about to become visible
    case low = 2       // Videos that are off-screen
    
    var delay: TimeInterval {
        switch self {
        case .high:
            return 0.0
        case .normal:
            return 0.5
        case .low:
            return 2.0
        }
    }
    
    var maxConcurrent: Int {
        switch self {
        case .high:
            return 3    // Allow 3 high priority videos to load simultaneously
        case .normal:
            return 2    // Allow 2 normal priority videos to load simultaneously
        case .low:
            return 1    // Only 1 low priority video at a time
        }
    }
}

/// Video loading request with priority
struct VideoLoadingRequest {
    let url: URL
    let mid: String
    let priority: VideoLoadingPriority
    let timestamp: Date
    
    init(url: URL, mid: String, priority: VideoLoadingPriority) {
        self.url = url
        self.mid = mid
        self.priority = priority
        self.timestamp = Date()
    }
}

/// Manages priority-based video loading with debouncing to prevent server overload
@MainActor
class VideoLoadingManager: ObservableObject {
    static let shared = VideoLoadingManager()
    
    private init() {
        startProcessingQueue()
    }
    
    // MARK: - Private Properties
    
    private var loadingQueue: [VideoLoadingRequest] = []
    private var activeLoads: [String: Task<Void, Never>] = [:]
    private var priorityCounts: [VideoLoadingPriority: Int] = [:]
    private var processingTimer: Timer?
    private var debounceTimer: Timer?
    
    // MARK: - Public Interface
    
    /// Request video loading with priority
    func requestVideoLoad(url: URL, mid: String, priority: VideoLoadingPriority) {
        // Check if already loading or cached
        if isAlreadyLoading(mid: mid) || isCached(url: url) {
            print("DEBUG: [VIDEO LOADING MANAGER] Skipping \(mid) - already loading or cached")
            return
        }
        
        // Remove existing request for same video (if any)
        loadingQueue.removeAll { $0.mid == mid }
        
        // Add new request
        let request = VideoLoadingRequest(url: url, mid: mid, priority: priority)
        loadingQueue.append(request)
        
        print("DEBUG: [VIDEO LOADING MANAGER] Added \(mid) to queue with priority \(priority)")
        
        // Start processing if not already running
        startProcessingQueue()
    }
    
    /// Cancel loading for a specific video
    func cancelLoading(mid: String) {
        // Remove from queue
        loadingQueue.removeAll { $0.mid == mid }
        
        // Cancel active load
        if let task = activeLoads[mid] {
            task.cancel()
            activeLoads.removeValue(forKey: mid)
            updatePriorityCount(for: mid, increment: false)
            print("DEBUG: [VIDEO LOADING MANAGER] Cancelled loading for \(mid)")
        }
    }
    
    /// Clear all pending loads
    func clearQueue() {
        loadingQueue.removeAll()
        
        // Cancel all active loads
        for (mid, task) in activeLoads {
            task.cancel()
            print("DEBUG: [VIDEO LOADING MANAGER] Cancelled active load for \(mid)")
        }
        activeLoads.removeAll()
        priorityCounts.removeAll()
        
        print("DEBUG: [VIDEO LOADING MANAGER] Cleared all loading queue")
    }
    
    // MARK: - Private Methods
    
    private func startProcessingQueue() {
        guard processingTimer == nil else { return }
        
        processingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.processQueue()
            }
        }
        
        print("DEBUG: [VIDEO LOADING MANAGER] Started processing queue")
    }
    
    private func processQueue() {
        // Sort queue by priority and timestamp
        loadingQueue.sort { request1, request2 in
            if request1.priority.rawValue != request2.priority.rawValue {
                return request1.priority.rawValue < request2.priority.rawValue
            }
            return request1.timestamp < request2.timestamp
        }
        
        // Process high priority requests first
        for priority in VideoLoadingPriority.allCases {
            let requestsForPriority = loadingQueue.filter { $0.priority == priority }
            let currentCount = priorityCounts[priority] ?? 0
            let maxAllowed = priority.maxConcurrent - currentCount
            
            if maxAllowed > 0 {
                let requestsToProcess = Array(requestsForPriority.prefix(maxAllowed))
                
                for request in requestsToProcess {
                    startLoading(request: request)
                }
            }
        }
    }
    
    private func startLoading(request: VideoLoadingRequest) {
        // Remove from queue
        loadingQueue.removeAll { $0.mid == request.mid }
        
        // Check if we can start loading based on priority limits
        let currentCount = priorityCounts[request.priority] ?? 0
        guard currentCount < request.priority.maxConcurrent else {
            print("DEBUG: [VIDEO LOADING MANAGER] Cannot start \(request.mid) - priority \(request.priority) limit reached (\(currentCount)/\(request.priority.maxConcurrent))")
            return
        }
        
        // Create loading task with delay
        let task = Task {
            do {
                // Apply priority-based delay
                if request.priority.delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(request.priority.delay * 1_000_000_000))
                }
                
                // Check if task was cancelled during delay
                try Task.checkCancellation()
                
                print("DEBUG: [VIDEO LOADING MANAGER] Starting load for \(request.mid) with priority \(request.priority)")
                
                // Use SharedAssetCache to load the asset
                let asset = try await SharedAssetCache.shared.getAsset(for: request.url)
                
                // Create player
                let playerItem = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: playerItem)
                
                // Cache the player
                await MainActor.run {
                    SharedAssetCache.shared.cachePlayer(player, for: request.url)
                    print("DEBUG: [VIDEO LOADING MANAGER] Successfully loaded and cached \(request.mid)")
                }
                
            } catch is CancellationError {
                print("DEBUG: [VIDEO LOADING MANAGER] Load cancelled for \(request.mid)")
            } catch {
                print("DEBUG: [VIDEO LOADING MANAGER] Load failed for \(request.mid): \(error)")
            }
            
            // Clean up
            await MainActor.run {
                self.activeLoads.removeValue(forKey: request.mid)
                self.updatePriorityCount(for: request.mid, increment: false)
            }
        }
        
        // Store task and update counts
        activeLoads[request.mid] = task
        updatePriorityCount(for: request.mid, increment: true)
        
        print("DEBUG: [VIDEO LOADING MANAGER] Started loading task for \(request.mid) with priority \(request.priority)")
    }
    
    private func updatePriorityCount(for mid: String, increment: Bool) {
        // Find the priority for this video
        if let request = loadingQueue.first(where: { $0.mid == mid }) {
            let priority = request.priority
            let currentCount = priorityCounts[priority] ?? 0
            priorityCounts[priority] = increment ? currentCount + 1 : max(0, currentCount - 1)
        }
        
        // Also check active loads
        if activeLoads[mid] != nil {
            // We need to track priority for active loads separately
            // For now, we'll use a simple approach
        }
    }
    
    private func isAlreadyLoading(mid: String) -> Bool {
        return activeLoads[mid] != nil || loadingQueue.contains { $0.mid == mid }
    }
    
    private func isCached(url: URL) -> Bool {
        return SharedAssetCache.shared.getCachedPlayer(for: url) != nil
    }
    
    // MARK: - Cleanup
    
    deinit {
        processingTimer?.invalidate()
        debounceTimer?.invalidate()
        
        // Cancel all active loads
        for (_, task) in activeLoads {
            task.cancel()
        }
        
        print("DEBUG: [VIDEO LOADING MANAGER] Deinitialized")
    }
}

// MARK: - Convenience Extensions

extension VideoLoadingManager {
    /// Request high priority loading (for visible videos)
    func requestHighPriorityLoad(url: URL, mid: String) {
        requestVideoLoad(url: url, mid: mid, priority: .high)
    }
    
    /// Request normal priority loading (for videos about to become visible)
    func requestNormalPriorityLoad(url: URL, mid: String) {
        requestVideoLoad(url: url, mid: mid, priority: .normal)
    }
    
    /// Request low priority loading (for off-screen videos)
    func requestLowPriorityLoad(url: URL, mid: String) {
        requestVideoLoad(url: url, mid: mid, priority: .low)
    }
}
