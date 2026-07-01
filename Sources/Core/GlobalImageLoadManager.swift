//
//  GlobalImageLoadManager.swift
//  Tweet
//
//  Global image loading manager with priority and concurrency control
//

import SwiftUI
import Foundation
import UIKit

// MARK: - Image Loading Priority
enum ImageLoadingPriority: Int, CaseIterable {
    case low = 0
    case normal = 1
    case high = 2
    case critical = 3
    
    var queue: DispatchQoS.QoSClass {
        switch self {
        case .low:
            return .utility
        case .normal:
            return .default
        case .high:
            return .userInitiated
        case .critical:
            return .userInteractive
        }
    }

    var taskPriority: TaskPriority {
        switch self {
        case .low:
            return .utility
        case .normal:
            return .medium
        case .high:
            return .userInitiated
        case .critical:
            return .userInitiated
        }
    }
}

// MARK: - Image Load Request
struct ImageLoadRequest {
    let id: String
    let url: URL
    let attachment: MimeiFileType
    let baseUrl: URL
    let priority: ImageLoadingPriority
    let completion: @MainActor (UIImage?) -> Void
    let onProgress: @MainActor (Double) -> Void
    
    init(id: String, url: URL, attachment: MimeiFileType, baseUrl: URL, priority: ImageLoadingPriority = .normal, completion: @escaping @MainActor (UIImage?) -> Void, onProgress: @escaping @MainActor (Double) -> Void = { _ in }) {
        self.id = id
        self.url = url
        self.attachment = attachment
        self.baseUrl = baseUrl
        self.priority = priority
        self.completion = completion
        self.onProgress = onProgress
    }
}

// MARK: - Global Image Load Manager
@MainActor
final class GlobalImageLoadManager: ObservableObject {
    static let shared = GlobalImageLoadManager()
    
    // MARK: - Configuration
    private let maxConcurrentLoads = 4   // Keep image fanout small so visible media gets bandwidth faster
    private let maxConcurrentCriticalLoads = 8 // Visible images may burst past the normal preload cap
    private let reservedHighPrioritySlots = 2  // Slots reserved for critical/high priority requests
    private let maxQueueSize = 50
    private let memoryWarningThreshold = 0.75 // Foreground cache can use more memory; background clears it
    
    // MARK: - State Management
    private var activeLoads: [String: Task<Void, Never>] = [:]
    private var activeLoadPriorities: [String: ImageLoadingPriority] = [:]
    private var activeLoadWaiters: [String: [ImageLoadRequest]] = [:]
    private var activeLoadKeyById: [String: String] = [:]
    private var activeLoadIdByKey: [String: String] = [:]
    private var pendingRequests: [ImageLoadRequest] = []
    private var completedRequests: Set<String> = []
    private var retryCounts: [String: Int] = [:] // Track retry attempts per request
    private var nonImageResponses: Set<String> = [] // Track requests that returned non-image content
    private var scheduledRetries: [String: DispatchWorkItem] = [:] // Track scheduled retries for cancellation
    private var permanentlyFailedRequests: Set<String> = [] // Track requests that have exhausted all retries
    private var focusedImageMID: String?
    
    // MARK: - Memory Management
    // Sampled off-main every ~2s by startMemorySampler(). isMemoryPressureHigh() reads these
    // cached values instead of running two task_info syscalls per loadImage() call — that was
    // the dominant per-request cost on the main actor during scroll.
    private let memorySampleLock = NSLock()
    private nonisolated(unsafe) var sampledMemoryUsage: UInt64 = 0
    private nonisolated(unsafe) var sampledMaxMemoryUsage: UInt64 = 0
    private nonisolated(unsafe) var sampledMemoryPressureHigh: Bool = false
    private var memorySamplerTask: Task<Void, Never>?

    // MARK: - Network Failure Tracking
    private var consecutiveNetworkFailures: Int = 0
    private let maxConsecutiveFailures = 3 // Trigger cleanup after 3 consecutive failures
    
    // MARK: - Statistics
    @Published var activeLoadCount: Int = 0
    @Published var pendingLoadCount: Int = 0
    @Published var completedLoadCount: Int = 0
    @Published var retryCount: Int = 0
    
    private init() {
        setupMemoryMonitoring()
        setupAppLifecycleNotifications()
        startPeriodicCleanup()
        startMemorySampler()
    }
    
    // MARK: - Public Interface

    /// Release transient image loading state when the app backgrounds.
    /// Disk cache is preserved; visible images reload from disk/network on foreground as needed.
    func prepareForBackground() {
        for task in activeLoads.values {
            task.cancel()
        }
        activeLoads.removeAll()
        activeLoadPriorities.removeAll()
        activeLoadWaiters.removeAll()
        activeLoadKeyById.removeAll()
        activeLoadIdByKey.removeAll()

        pendingRequests.removeAll()

        for workItem in scheduledRetries.values {
            workItem.cancel()
        }
        scheduledRetries.removeAll()

        completedRequests.removeAll()
        retryCounts.removeAll()
        permanentlyFailedRequests.removeAll()

        updateStatistics()
        print("🧹 [GlobalImageLoadManager] Released image loading state for background")
    }
    
    /// Load an image with priority and concurrency control
    func loadImage(request: ImageLoadRequest) {
        // ✅ CHECK BLACKLIST FIRST - Don't waste resources on known-bad images
        let mediaID = MimeiId(request.attachment.mid)
        if BlackList.shared.isBlacklisted(mediaID) {
            print("🚫 [IMAGE BLACKLIST] Skipping blacklisted image: \(mediaID)")
            // Call completion with nil to update UI - already on MainActor since class is @MainActor
            request.completion(nil)
            return
        }
        
        // Check if already completed successfully
        if completedRequests.contains(request.id) {
            // PERFORMANCE FIX: Only check memory cache on main thread (no disk I/O)
            // If not in memory, check disk asynchronously
            let cachedImage = ImageCacheManager.shared.getCompressedImageFromMemory(for: request.attachment)
            
            if let cachedImage = cachedImage {
                // Found in memory cache - return immediately
                request.completion(cachedImage)
                return
            } else {
                // Not in memory - check disk cache asynchronously
                Task.detached(priority: .userInitiated) {
                    let diskCachedImage = ImageCacheManager.shared.getCompressedImage(for: request.attachment)
                    await MainActor.run {
                        if let diskCachedImage = diskCachedImage {
                            request.completion(diskCachedImage)
                        } else {
                            // Image was evicted from cache, remove from completed so it can be reloaded
                            self.completedRequests.remove(request.id)
                            // Restart loading
                            self.loadImage(request: request)
                        }
                    }
                }
                return
            }
        }
        
        // Check if this request previously returned non-image content (don't retry)
        if nonImageResponses.contains(request.id) {
            // Call completion with nil to update UI state
            request.completion(nil)
            return
        }
        
        // Check if this request has permanently failed (exhausted all retries)
        if permanentlyFailedRequests.contains(request.id) {
            print("❌ [IMAGE LOAD] Skipping permanently failed image: \(request.id)")
            // Call completion with nil to update UI state
            request.completion(nil)
            return
        }
        
        // Check if already loading
        if activeLoads[request.id] != nil {
            // PERFORMANCE FIX: Only check memory cache on main thread (no disk I/O)
            let cachedImage = ImageCacheManager.shared.getCompressedImageFromMemory(for: request.attachment)
            if cachedImage != nil {
                // Found in memory cache, return it immediately
                request.completion(cachedImage)
            } else {
                activeLoadWaiters[request.id, default: []].append(request)
                if let activePriority = activeLoadPriorities[request.id],
                   request.priority.rawValue > activePriority.rawValue {
                    activeLoadPriorities[request.id] = request.priority
                }
            }
            return
        }

        // Requests from feed/detail/fullscreen use different UI ids, but the
        // underlying image is the same attachment. Join the active media load
        // instead of creating a second GlobalImageLoadManager task.
        if let key = imageCoalescingKey(for: request),
           let activeId = activeLoadIdByKey[key],
           activeId != request.id,
           activeLoads[activeId] != nil {
            let cachedImage = ImageCacheManager.shared.getCompressedImageFromMemory(for: request.attachment)
            if let cachedImage = cachedImage {
                request.completion(cachedImage)
            } else {
                activeLoadWaiters[activeId, default: []].append(request)
                if let activePriority = activeLoadPriorities[activeId],
                   request.priority.rawValue > activePriority.rawValue {
                    activeLoadPriorities[activeId] = request.priority
                }
                print("♻️ [IMAGE LOAD] Joining active load [\(request.priority)]: \(request.id) -> \(activeId)")
            }
            return
        }
        
        // If image reappears and we haven't completed it successfully, reset retry count
        // This allows images to be retried when they come back into view
        if let currentRetryCount = retryCounts[request.id], currentRetryCount > 0 {
            retryCounts[request.id] = 0
        }
        
        // Check memory pressure — only shed low-priority work, keep visible images loading
        if isMemoryPressureHigh() {
            print("DEBUG: [GlobalImageLoadManager] High memory pressure detected: \(activeLoads.count) active loads, \(scheduledRetries.count) scheduled retries")

            // Cancel ALL scheduled retries immediately to free memory
            for workItem in scheduledRetries.values {
                workItem.cancel()
            }
            scheduledRetries.removeAll()

            // Only drop low/normal priority pending requests; keep high/critical
            let beforeCount = pendingRequests.count
            pendingRequests.removeAll { $0.priority.rawValue < ImageLoadingPriority.high.rawValue }
            let droppedCount = beforeCount - pendingRequests.count
            if droppedCount > 0 {
                print("DEBUG: [GlobalImageLoadManager] Dropped \(droppedCount) low-priority pending requests due to memory pressure")
            }

            // Release memory cache moderately
            ImageCacheManager.shared.releasePartialCache(percentage: 20)

            if request.priority.rawValue < ImageLoadingPriority.high.rawValue {
                // Defer low priority requests during memory pressure
                deferRequest(request)
                return
            }
        }

        if isBlockedByFocusedImage(request) {
            addToPendingQueue(request)
            print("⏸️ [IMAGE LOAD] Holding \(request.id) while fullscreen image \(focusedImageMID ?? "") is focused")
            return
        }
        
        // Check if we can start loading immediately
        if canStartLoad(priority: request.priority) {
            startLoading(request)
        } else {
            // Add to pending queue
            addToPendingQueue(request)
        }
    }
    
    /// Cancel a specific image load request
    func cancelLoad(id: String) {
        let removedWaiters = removeWaitingRequests(id: id)
        if removedWaiters > 0 {
            print("DEBUG: [GlobalImageLoadManager] Removed \(removedWaiters) waiting image request(s) for: \(id)")
        }

        // Cancel active load only when no other UI request is attached to it.
        if let activeTask = activeLoads[id] {
            if let waiters = activeLoadWaiters[id], !waiters.isEmpty {
                print("DEBUG: [GlobalImageLoadManager] Keeping active image load \(id) for \(waiters.count) joined request(s)")
            } else {
                activeTask.cancel()
                activeLoadWaiters.removeValue(forKey: id)
                clearActiveLoadState(for: id)
            }
        }

        // Cancel any scheduled retry
        if scheduledRetries[id] != nil {
            scheduledRetries[id]?.cancel()
            scheduledRetries.removeValue(forKey: id)
            print("DEBUG: [GlobalImageLoadManager] Cancelled scheduled retry for: \(id)")
        }

        // ✅ CRITICAL FIX: Remove from pending queue to release closure-captured memory
        let removedCount = pendingRequests.count
        pendingRequests.removeAll { $0.id == id }
        let actualRemoved = removedCount - pendingRequests.count
        if actualRemoved > 0 {
            print("🧹 [GlobalImageLoadManager] Removed \(actualRemoved) pending request(s) for: \(id)")
        }

        updateStatistics()
    }

    /// Boost priority of a pending request (e.g., when media becomes visible)
    func boostPriority(id: String, to newPriority: ImageLoadingPriority) {
        // If already loading, no need to boost (it's already active)
        if activeLoads[id] != nil {
            return
        }

        // Find request in pending queue
        guard let index = pendingRequests.firstIndex(where: { $0.id == id }) else {
            return
        }

        // Get the request
        let request = pendingRequests[index]

        // If already at or above target priority, no need to boost
        if request.priority.rawValue >= newPriority.rawValue {
            return
        }

        // Remove from current position
        pendingRequests.remove(at: index)

        // Create boosted request
        let boostedRequest = ImageLoadRequest(
            id: request.id,
            url: request.url,
            attachment: request.attachment,
            baseUrl: request.baseUrl,
            priority: newPriority,
            completion: request.completion,
            onProgress: request.onProgress
        )

        // Re-insert at appropriate position based on new priority
        let insertIndex = pendingRequests.firstIndex { $0.priority.rawValue < newPriority.rawValue } ?? pendingRequests.count
        pendingRequests.insert(boostedRequest, at: insertIndex)

        print("📈 [GlobalImageLoadManager] Boosted priority for \(id): \(request.priority) → \(newPriority)")

        // Try to process it immediately if we have capacity
        if canStartLoad(priority: newPriority) {
            processNextPendingRequest()
        }
    }
    
    /// Force retry a failed image load
    func retryLoad(id: String) {
        // Remove from completed/failed tracking to allow retry
        completedRequests.remove(id)
        retryCounts.removeValue(forKey: id)
        permanentlyFailedRequests.remove(id)
        
        // Cancel any pending retry
        scheduledRetries[id]?.cancel()
        scheduledRetries.removeValue(forKey: id)
    }
    
    /// Cancel all loads for a specific priority or lower
    func cancelLoads(priority: ImageLoadingPriority) {
        let activeIdsToCancel = activeLoadPriorities
            .filter { $0.value.rawValue <= priority.rawValue }
            .map(\.key)
        let pendingIdsToCancel = pendingRequests
            .filter { $0.priority.rawValue <= priority.rawValue }
            .map(\.id)

        for id in Set(activeIdsToCancel + pendingIdsToCancel) {
            cancelLoad(id: id)
        }
    }
    
    /// Clear all completed request history
    func clearHistory() {
        completedRequests.removeAll()
        retryCounts.removeAll()
        nonImageResponses.removeAll()
        permanentlyFailedRequests.removeAll()

        // Cancel all scheduled retries
        if !scheduledRetries.isEmpty {
            print("DEBUG: [GlobalImageLoadManager] Clearing history, cancelling \(scheduledRetries.count) scheduled retries")
            for workItem in scheduledRetries.values {
                workItem.cancel()
            }
            scheduledRetries.removeAll()
        }

        updateStatistics()
    }

    /// Clear ALL cache and cancel ALL operations (for settings cache clear)
    func clearAll() {
        print("DEBUG: [GlobalImageLoadManager] Clearing ALL cache and operations")

        // Cancel all active loads
        activeLoads.values.forEach { $0.cancel() }
        activeLoads.removeAll()
        activeLoadPriorities.removeAll()
        activeLoadWaiters.removeAll()
        activeLoadKeyById.removeAll()
        activeLoadIdByKey.removeAll()
        print("DEBUG: [GlobalImageLoadManager] Cancelled \(activeLoads.count) active loads")

        // Clear all pending requests
        pendingRequests.removeAll()
        print("DEBUG: [GlobalImageLoadManager] Cleared \(pendingRequests.count) pending requests")

        // Clear all history and retries
        clearHistory()
        print("DEBUG: [GlobalImageLoadManager] Cleared history and retries")

        updateStatistics()
        print("DEBUG: [GlobalImageLoadManager] Clear all complete")
    }
    
    /// Get current loading statistics
    func getStatistics() -> (active: Int, pending: Int, completed: Int, retries: Int) {
        return (activeLoads.count, pendingRequests.count, completedRequests.count, retryCounts.values.reduce(0, +))
    }

    /// True when an image is already active, queued, or waiting for retry in the global loader.
    /// Directional prewarm uses this to avoid starting a second request for visible-cell work.
    func hasLoad(id: String) -> Bool {
        activeLoads[id] != nil
            || pendingRequests.contains { $0.id == id }
            || scheduledRetries[id] != nil
    }

    /// Let the fullscreen image own image-download starts until it has a usable result.
    func beginFocusedImageLoad(for mid: String) {
        guard !mid.isEmpty else { return }
        focusedImageMID = mid
        cancelBlockedActiveLoadsForFocusedImage()
        print("🎯 [IMAGE LOAD] Focused image load started: \(mid)")
        processNextPendingRequest()
    }

    func endFocusedImageLoad(for mid: String) {
        guard focusedImageMID == mid else { return }
        focusedImageMID = nil
        print("🎯 [IMAGE LOAD] Focused image load ended: \(mid)")
        processNextPendingRequest()
    }
    
    /// Get current memory usage information (cached from the background sampler).
    func getMemoryInfo() -> (current: UInt64, max: UInt64, pressure: Bool) {
        memorySampleLock.lock(); defer { memorySampleLock.unlock() }
        return (sampledMemoryUsage, sampledMaxMemoryUsage, sampledMemoryPressureHigh)
    }
    
    /// Force cleanup of completed requests to free memory
    func forceCleanup() {
        completedRequests.removeAll()
        
        // Clean up old retry tracking to prevent unbounded growth
        // Only keep recent retry attempts (last 100)
        if retryCounts.count > 100 {
            let before = retryCounts.count
            let sortedKeys = Array(retryCounts.keys).suffix(100)
            let keysToKeep = Set(sortedKeys)
            retryCounts = retryCounts.filter { keysToKeep.contains($0.key) }
            print("DEBUG: [GlobalImageLoadManager] Trimmed retryCounts: \(before) -> \(retryCounts.count)")
        }
        
        // Limit permanently failed requests to prevent unbounded growth
        if permanentlyFailedRequests.count > 200 {
            let before = permanentlyFailedRequests.count
            let toRemove = permanentlyFailedRequests.count - 100
            let keysToRemove = Array(permanentlyFailedRequests.prefix(toRemove))
            permanentlyFailedRequests.subtract(keysToRemove)
            print("DEBUG: [GlobalImageLoadManager] Trimmed permanentlyFailed: \(before) -> \(permanentlyFailedRequests.count)")
        }
        
        updateStatistics()
    }
    
    // MARK: - Private Methods

    private func imageCoalescingKey(for request: ImageLoadRequest) -> String? {
        request.attachment.mid.isEmpty ? nil : request.attachment.mid
    }

    private func isBlockedByFocusedImage(_ request: ImageLoadRequest) -> Bool {
        guard let focusedImageMID else { return false }
        return request.attachment.mid != focusedImageMID
    }

    private func cancelBlockedActiveLoadsForFocusedImage() {
        guard let focusedImageMID else { return }

        var cancelled = 0
        for id in Array(activeLoads.keys) {
            let mediaID = activeLoadKeyById[id] ?? id
            guard mediaID != focusedImageMID else { continue }

            activeLoads[id]?.cancel()
            ImageCacheManager.shared.cancelImageLoad(forMid: mediaID)
            activeLoadWaiters.removeValue(forKey: id)
            clearActiveLoadState(for: id)
            cancelled += 1
        }

        if cancelled > 0 {
            print("🛑 [IMAGE LOAD] Cancelled \(cancelled) active non-focused image load(s) for fullscreen image \(focusedImageMID)")
            updateStatistics()
        }
    }

    private func clearActiveLoadState(for id: String) {
        activeLoads.removeValue(forKey: id)
        activeLoadPriorities.removeValue(forKey: id)
        if let key = activeLoadKeyById.removeValue(forKey: id),
           activeLoadIdByKey[key] == id {
            activeLoadIdByKey.removeValue(forKey: key)
        }
    }

    @discardableResult
    private func removeWaitingRequests(id: String) -> Int {
        var removed = 0
        for activeId in Array(activeLoadWaiters.keys) {
            let original = activeLoadWaiters[activeId] ?? []
            let filtered = original.filter { $0.id != id }
            removed += original.count - filtered.count
            if filtered.isEmpty {
                activeLoadWaiters.removeValue(forKey: activeId)
            } else {
                activeLoadWaiters[activeId] = filtered
            }
        }
        return removed
    }

    private func completeRequest(_ request: ImageLoadRequest, with image: UIImage?) {
        let waiters = activeLoadWaiters.removeValue(forKey: request.id) ?? []
        request.completion(image)
        for waiter in waiters {
            waiter.completion(image)
            if image != nil {
                completedRequests.insert(waiter.id)
                retryCounts.removeValue(forKey: waiter.id)
            }
        }
    }

    private func focusedRetryRequest(for request: ImageLoadRequest) -> ImageLoadRequest? {
        guard focusedImageMID == request.attachment.mid else { return nil }
        let candidates = [request] + (activeLoadWaiters[request.id] ?? [])
        return candidates.first { $0.id.hasPrefix("browser_") } ?? candidates.first
    }
    
    private func handleLoadFailure(_ request: ImageLoadRequest) {
        let currentRetryCount = retryCounts[request.id] ?? 0
        let newRetryCount = currentRetryCount + 1
        retryCounts[request.id] = newRetryCount
        
        // REDUCED: Only 2 retries instead of 3, with longer delays during network issues
        let maxRetries = 2
        
        if newRetryCount < maxRetries {
            // Cancel any existing scheduled retry for this request
            scheduledRetries[request.id]?.cancel()
            
            // Longer delays with exponential backoff: 5s, 10s
            let delay = Double(newRetryCount) * 5.0
            let focusedRetryRequest = focusedRetryRequest(for: request)
            
            // ✅ CRITICAL MEMORY LEAK FIX: Only capture minimal data, NOT completion handlers
            // Completion handlers may capture views, creating retain cycles via DispatchWorkItem
            // Instead of capturing the completion handler, we mark request as "needs retry"
            // and let the cell request it again when it reappears
            let requestId = request.id
            let retryRequestId = focusedRetryRequest?.id
            
            // Create a weak reference to avoid retain cycles
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                // Remove the work item from tracking
                self.scheduledRetries.removeValue(forKey: requestId)
                if let retryRequestId {
                    self.scheduledRetries.removeValue(forKey: retryRequestId)
                }

                if let focusedRetryRequest,
                   self.focusedImageMID == focusedRetryRequest.attachment.mid {
                    self.completedRequests.remove(requestId)
                    self.completedRequests.remove(focusedRetryRequest.id)
                    self.permanentlyFailedRequests.remove(focusedRetryRequest.id)
                    self.retryCounts[focusedRetryRequest.id] = newRetryCount
                    print("🔄 [GlobalImageLoadManager] Retrying focused fullscreen image: \(focusedRetryRequest.id)")
                    self.loadImage(request: focusedRetryRequest)
                    return
                }
                
                // ✅ MEMORY FIX: Check if request was cancelled before retry
                // If cancelLoad() was called, don't retry (cell disappeared)
                if !self.activeLoads.keys.contains(requestId) && 
                   !self.pendingRequests.contains(where: { $0.id == requestId }) {
                    print("🧹 [GlobalImageLoadManager] Skipping retry - request was cancelled: \(requestId)")
                    // Remove from completed so cell can retry when it reappears
                    self.completedRequests.remove(requestId)
                    return
                }
                
                // Check memory pressure before retry - if high, skip retry
                if self.isMemoryPressureHigh() {
                    print("DEBUG: [GlobalImageLoadManager] Skipping retry due to memory pressure: \(requestId)")
                    self.permanentlyFailedRequests.insert(requestId)
                    self.retryCounts.removeValue(forKey: requestId)
                    return
                }
                
                // ✅ CRITICAL MEMORY LEAK FIX: Don't capture request or completion handler
                // Instead, just remove from completedRequests so cell can retry when visible
                // This prevents memory leak from holding completion handlers in DispatchWorkItem
                self.completedRequests.remove(requestId)
                print("🔄 [GlobalImageLoadManager] Retry time reached for \(requestId) - removed from completed, cell will reload when visible")
            }
            
            scheduledRetries[request.id] = workItem
            if let retryRequestId {
                scheduledRetries[retryRequestId] = workItem
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            print("DEBUG: [GlobalImageLoadManager] Scheduled retry #\(newRetryCount) in \(delay)s for: \(request.id)")
        } else {
            // After retries, mark as permanently failed to prevent further attempts
            permanentlyFailedRequests.insert(request.id)
            retryCounts.removeValue(forKey: request.id)
            print("❌ [IMAGE LOAD] Permanently failed after \(maxRetries) retries: \(request.id)")
        }
    }
    
    private func startLoading(_ request: ImageLoadRequest) {
        let task = Task.detached(priority: request.priority.taskPriority) { [self] in
            // Check if image is already cached (disk I/O runs off main actor in detached task)
            if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: request.attachment) {
                await MainActor.run {
                    guard !Task.isCancelled else {
                        self.activeLoadWaiters.removeValue(forKey: request.id)
                        self.clearActiveLoadState(for: request.id)
                        self.updateStatistics()
                        self.processNextPendingRequest()
                        return
                    }
                    self.completeRequest(request, with: cachedImage)
                    self.completedRequests.insert(request.id)
                    self.clearActiveLoadState(for: request.id)
                    self.updateStatistics()
                    self.processNextPendingRequest()
                }
                return
            }

            // Load from network
            let image = await self.loadImageFromNetwork(request)
            
            await MainActor.run {
                let mediaID = MimeiId(request.attachment.mid)

                guard !Task.isCancelled else {
                    print("DEBUG: [GlobalImageLoadManager] Task cancelled for \(request.id) - skipping completion/retry")
                    self.activeLoadWaiters.removeValue(forKey: request.id)
                    self.clearActiveLoadState(for: request.id)
                    self.updateStatistics()
                    self.processNextPendingRequest()
                    return
                }

                if let image = image {
                    // ✅ RECORD SUCCESS TO BLACKLIST
                    BlackList.shared.recordSuccess(mediaID)

                    self.completeRequest(request, with: image)
                    self.completedRequests.insert(request.id)
                    self.retryCounts.removeValue(forKey: request.id) // Clear retry count on success
                } else {
                    // Check if task was cancelled before treating as failure
                    if Task.isCancelled {
                        print("DEBUG: [GlobalImageLoadManager] Task cancelled for \(request.id) - skipping retry")
                    } else {
                        // ❌ RECORD FAILURE TO BLACKLIST
                        BlackList.shared.recordFailure(mediaID)

                        // Only retry for real failures, not cancellations
                        self.handleLoadFailure(request)
                    }

                    // Always call completion on real failures so UI can update isLoading state.
                    self.completeRequest(request, with: nil)
                }
                self.clearActiveLoadState(for: request.id)
                self.updateStatistics()
                self.processNextPendingRequest()
            }
        }
        
        activeLoads[request.id] = task
        activeLoadPriorities[request.id] = request.priority
        if let key = imageCoalescingKey(for: request) {
            activeLoadKeyById[request.id] = key
            activeLoadIdByKey[key] = request.id
        }
        updateStatistics()
    }
    
    private func loadImageFromNetwork(_ request: ImageLoadRequest) async -> UIImage? {
        let startTime = Date()
        print("📥 [IMAGE LOAD] Starting [\(request.priority)] \(request.id): \(request.url.lastPathComponent)")

        let image = await ImageCacheManager.shared.loadAndCacheImage(
            from: request.url,
            for: request.attachment,
            priority: request.priority
        )

        if let image {
            consecutiveNetworkFailures = 0
            let elapsed = Date().timeIntervalSince(startTime)
            await MainActor.run {
                request.onProgress(1.0)
            }
            print("✅ [IMAGE LOAD] Completed [\(request.priority)] \(request.id) in \(String(format: "%.1f", elapsed))s: \(request.url.lastPathComponent)")
            return image
        }

        if Task.isCancelled {
            print("DEBUG: [GlobalImageLoadManager] Image load cancelled (user scrolled): \(request.url.lastPathComponent)")
            return nil
        }

        print("❌ [IMAGE LOAD] Failed for \(request.url.lastPathComponent)")
        consecutiveNetworkFailures += 1
        print("DEBUG: [GlobalImageLoadManager] Network failure count: \(consecutiveNetworkFailures)/\(maxConsecutiveFailures)")

        if consecutiveNetworkFailures >= maxConsecutiveFailures {
            print("DEBUG: [GlobalImageLoadManager] Too many consecutive network failures, triggering cleanup")
            Task { @MainActor in
                self.handleNetworkFailureCleanup()
            }
            consecutiveNetworkFailures = 0
        }

        return nil
    }
    
    private func loadImageOptimized(request: ImageLoadRequest, maxSize: CGSize) {
        // Check if already completed successfully
        if completedRequests.contains(request.id) {
            return
        }
        
        // Check if already loading
        if activeLoads[request.id] != nil {
            return
        }
        
        // If image reappears and we haven't completed it successfully, reset retry count
        if let currentRetryCount = retryCounts[request.id], currentRetryCount > 0 {
            retryCounts[request.id] = 0
        }
        
        // Check if we can start loading immediately
        if canStartLoad(priority: request.priority) {
            startLoadingOptimized(request, maxSize: maxSize)
        } else {
            // Add to pending queue with special handling
            addToPendingQueue(request)
        }
    }
    
    private func startLoadingOptimized(_ request: ImageLoadRequest, maxSize: CGSize) {
        let task = Task.detached(priority: request.priority.taskPriority) { [self] in
            do {
                // Check cancellation early
                try Task.checkCancellation()

                // Check if image is already cached (disk I/O runs off main actor in detached task)
                if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: request.attachment) {
                    await MainActor.run {
                        // Check cancellation again before completing
                        guard !Task.isCancelled else {
                            self.activeLoads.removeValue(forKey: request.id)
                            self.activeLoadPriorities.removeValue(forKey: request.id)
                            self.updateStatistics()
                            return
                        }
                        request.completion(cachedImage)
                        self.completedRequests.insert(request.id)
                        self.activeLoads.removeValue(forKey: request.id)
                        self.activeLoadPriorities.removeValue(forKey: request.id)
                        self.updateStatistics()
                        self.processNextPendingRequest()
                    }
                    return
                }

                // Check cancellation before network request
                try Task.checkCancellation()

                // Load from network with size optimization
                let optimizedImage = try await self.loadImageFromNetworkOptimized(request, maxSize: maxSize)
                
                await MainActor.run {
                    // Check cancellation before completing - don't call completion if cancelled
                    guard !Task.isCancelled else {
                        // Clean up if cancelled
                        self.activeLoads.removeValue(forKey: request.id)
                        self.activeLoadPriorities.removeValue(forKey: request.id)
                        self.updateStatistics()
                        return
                    }
                    
                    request.completion(optimizedImage)
                    if optimizedImage != nil {
                        // Reset network failure counter on successful load
                        self.consecutiveNetworkFailures = 0
                        self.completedRequests.insert(request.id)
                        self.retryCounts.removeValue(forKey: request.id) // Clear retry count on success
                    } else {
                        self.handleLoadFailure(request)
                    }
                    self.activeLoads.removeValue(forKey: request.id)
                    self.activeLoadPriorities.removeValue(forKey: request.id)
                    self.updateStatistics()
                    self.processNextPendingRequest()
                }
            } catch {
                // Handle cancellation silently - don't treat it as a failure
                if error is CancellationError {
                    await MainActor.run {
                        // Clean up cancelled task
                        self.activeLoads.removeValue(forKey: request.id)
                        self.activeLoadPriorities.removeValue(forKey: request.id)
                        self.updateStatistics()
                    }
                    return
                }
                
                // Handle actual errors
                await MainActor.run {
                    // Only handle failure if not cancelled
                    guard !Task.isCancelled else {
                        self.activeLoads.removeValue(forKey: request.id)
                        self.activeLoadPriorities.removeValue(forKey: request.id)
                        self.updateStatistics()
                        return
                    }

                    // Track consecutive network failures
                    self.consecutiveNetworkFailures += 1
                    print("DEBUG: [GlobalImageLoadManager] Network failure count: \(self.consecutiveNetworkFailures)/\(self.maxConsecutiveFailures)")

                    // Trigger emergency cleanup if too many consecutive failures
                    if self.consecutiveNetworkFailures >= self.maxConsecutiveFailures {
                        print("DEBUG: [GlobalImageLoadManager] Too many consecutive network failures, triggering cleanup")
                        self.handleNetworkFailureCleanup()
                        self.consecutiveNetworkFailures = 0 // Reset counter after cleanup
                    }

                    self.handleLoadFailure(request)
                    self.activeLoads.removeValue(forKey: request.id)
                    self.activeLoadPriorities.removeValue(forKey: request.id)
                    self.updateStatistics()
                    self.processNextPendingRequest()
                }
            }
        }
        
        activeLoads[request.id] = task
        activeLoadPriorities[request.id] = request.priority
        updateStatistics()
    }
    
    private func loadImageFromNetworkOptimized(_ request: ImageLoadRequest, maxSize: CGSize) async throws -> UIImage? {
        do {
            // Check cancellation before network request
            try Task.checkCancellation()
            
            // Create URLRequest with timeout
            var urlRequest = URLRequest(url: request.url)
            urlRequest.timeoutInterval = Constants.IMAGE_LOAD_TIMEOUT
            urlRequest.cachePolicy = .returnCacheDataElseLoad
            
            let (localURL, response) = try await URLSession.shared.download(for: urlRequest)
            defer {
                try? FileManager.default.removeItem(at: localURL)
            }
            
            // Check cancellation after network request
            try Task.checkCancellation()
            
            // Check if we got a valid response
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("❌ [IMAGE LOAD] HTTP \(statusCode) for optimized \(request.url.lastPathComponent)")
                return nil
            }

            // Update progress (only if not cancelled)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                request.onProgress(1.0)
            }

            // Check cancellation before image processing
            try Task.checkCancellation()

            let data = try Data(contentsOf: localURL, options: .mappedIfSafe)

            // Create UIImage from downloaded file data
            guard let originalImage = UIImage(data: data) else {
                print("❌ [IMAGE LOAD] Failed to decode optimized image data (\(data.count) bytes) for \(request.url.lastPathComponent)")
                return nil
            }
            
            // Check cancellation before resizing
            try Task.checkCancellation()
            
            // Resize image to fit within maxSize while maintaining aspect ratio
            let resizedImage = resizeImage(originalImage, toFit: maxSize)
            
            // Check cancellation before caching
            try Task.checkCancellation()
            
            if let resizedData = resizedImage.jpegData(compressionQuality: 0.8) {
                if let cachedImage = ImageCacheManager.shared.cacheImageData(resizedData, for: request.attachment) {
                    return cachedImage
                }
            }
            
            return resizedImage
        } catch {
            // Re-throw Task cancellation errors so they can be handled upstream
            if error is CancellationError {
                throw error
            }

            // Re-throw URL cancellation errors (user scrolled away)
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                throw error
            }

            return nil
        }
    }
    
    private func resizeImage(_ image: UIImage, toFit maxSize: CGSize) -> UIImage {
        let imageSize = image.size
        
        // Calculate scale factor to fit within maxSize
        let widthScale = maxSize.width / imageSize.width
        let heightScale = maxSize.height / imageSize.height
        let scale = min(widthScale, heightScale, 1.0) // Don't upscale
        
        // If image is already smaller, return original
        if scale >= 1.0 {
            return image
        }
        
        // Calculate new size
        let newSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        
        // Create resized image
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return resizedImage ?? image
    }
    
    private func addToPendingQueue(_ request: ImageLoadRequest) {
        if let existingIndex = pendingRequests.firstIndex(where: { $0.id == request.id }) {
            let existing = pendingRequests[existingIndex]
            guard request.priority.rawValue > existing.priority.rawValue else { return }
            pendingRequests.remove(at: existingIndex)
        }

        // Insert request in priority order (highest priority first)
        let insertIndex = pendingRequests.firstIndex { $0.priority.rawValue < request.priority.rawValue } ?? pendingRequests.count
        pendingRequests.insert(request, at: insertIndex)
        
        // Limit queue size
        if pendingRequests.count > maxQueueSize {
            // Remove lowest priority requests
            let requestsToRemove = pendingRequests.suffix(pendingRequests.count - maxQueueSize)
            for requestToRemove in requestsToRemove {
                pendingRequests.removeAll { $0.id == requestToRemove.id }
            }
        }
        
        updateStatistics()
    }
    
    /// Check if a new load can start given priority-based slot reservation.
    /// Last `reservedHighPrioritySlots` slots are reserved for critical/high priority requests.
    private func canStartLoad(priority: ImageLoadingPriority) -> Bool {
        let active = activeLoads.count
        if priority == .critical {
            return active < maxConcurrentCriticalLoads
        }
        if active < maxConcurrentLoads - reservedHighPrioritySlots {
            return true // Unreserved slots available for any priority
        }
        // Only critical/high priority can use reserved slots
        return active < maxConcurrentLoads && priority.rawValue >= ImageLoadingPriority.high.rawValue
    }

    private func processNextPendingRequest() {
        guard !pendingRequests.isEmpty else { return }

        guard let nextIndex = pendingRequests.firstIndex(where: { request in
            !isBlockedByFocusedImage(request) && canStartLoad(priority: request.priority)
        }) else { return }

        // Get the highest priority request that is allowed to start now.
        let nextRequest = pendingRequests.remove(at: nextIndex)
        startLoading(nextRequest)
    }
    
    private func deferRequest(_ request: ImageLoadRequest) {
        // Add to end of pending queue with lower priority
        let deferredRequest = ImageLoadRequest(
            id: request.id,
            url: request.url,
            attachment: request.attachment,
            baseUrl: request.baseUrl,
            priority: .low, // Downgrade priority
            completion: request.completion,
            onProgress: request.onProgress
        )
        pendingRequests.append(deferredRequest)
        updateStatistics()
    }
    
    /// Cached, syscall-free check read on the main actor (loadImage / handleLoadFailure).
    /// Updated off-main by startMemorySampler() every ~2s.
    private func isMemoryPressureHigh() -> Bool {
        memorySampleLock.lock(); defer { memorySampleLock.unlock() }
        return sampledMemoryPressureHigh
    }

    // MARK: - Background Memory Sampling

    /// Periodically sample phys_footprint off the main actor so loadImage() never pays the
    /// two task_info syscalls per call. Runs for the lifetime of the singleton.
    private func startMemorySampler() {
        memorySamplerTask?.cancel()
        memorySamplerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let sample = self?.sampleMemoryUsage()
                self?.applyMemorySample(sample)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Nonisolated: does the mach syscalls on the cooperative pool. Reads only the
    /// `let memoryWarningThreshold` constant (immutable → safe off-main).
    private nonisolated func sampleMemoryUsage() -> (usage: UInt64, high: Bool) {
        var memoryInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &memoryInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return (0, false) }

        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / mach_msg_type_number_t(MemoryLayout<natural_t>.size)
        let vmKerr = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }

        let usage: UInt64
        if vmKerr == KERN_SUCCESS {
            usage = UInt64(vmInfo.phys_footprint)
        } else {
            usage = memoryInfo.resident_size // Fallback
        }

        let availableMemory = ProcessInfo.processInfo.physicalMemory
        let ratio = availableMemory > 0 ? Double(usage) / Double(availableMemory) : 0
        let usageMB = Double(usage) / (1024.0 * 1024.0)
        let high = ratio > memoryWarningThreshold || usageMB > 1400.0
        return (usage, high)
    }

    /// Nonisolated: writes the sampled values under memorySampleLock. Called from the
    /// detached sampler task.
    private nonisolated func applyMemorySample(_ sample: (usage: UInt64, high: Bool)?) {
        guard let sample else { return }
        memorySampleLock.lock()
        defer { memorySampleLock.unlock() }
        sampledMemoryUsage = sample.usage
        if sample.usage > sampledMaxMemoryUsage { sampledMaxMemoryUsage = sample.usage }
        let becameHigh = sample.high && !sampledMemoryPressureHigh
        sampledMemoryPressureHigh = sample.high
        if becameHigh {
            let mb = Double(sample.usage) / (1024.0 * 1024.0)
            print("DEBUG: [GlobalImageLoadManager] High memory pressure sampled: \(String(format: "%.0f", mb)) MB")
        }
    }
    
    private func updateStatistics() {
        activeLoadCount = activeLoads.count
        pendingLoadCount = pendingRequests.count
        completedLoadCount = completedRequests.count
        retryCount = retryCounts.values.reduce(0, +)
    }

    /// Emergency cleanup during network failures
    func handleNetworkFailureCleanup() {
        print("DEBUG: [GlobalImageLoadManager] Network failure detected, performing emergency cleanup")

        // Cancel all active loads
        for (requestId, task) in activeLoads {
            print("DEBUG: [GlobalImageLoadManager] Cancelling active load due to network failure: \(requestId)")
            task.cancel()
        }
        activeLoads.removeAll()
        activeLoadPriorities.removeAll()
        activeLoadWaiters.removeAll()
        activeLoadKeyById.removeAll()
        activeLoadIdByKey.removeAll()

        // Cancel all scheduled retries
        for workItem in scheduledRetries.values {
            workItem.cancel()
        }
        scheduledRetries.removeAll()

        // Clear most pending requests (keep only high priority ones)
        let originalCount = pendingRequests.count
        pendingRequests = pendingRequests.filter { $0.priority == .critical }
        let removedCount = originalCount - pendingRequests.count
        print("DEBUG: [GlobalImageLoadManager] Cleared \(removedCount) pending requests due to network failure")

        // Clear retry counts for failed requests
        retryCounts.removeAll()

        // Release cache
        ImageCacheManager.shared.releasePartialCache(percentage: 30)

        updateStatistics()
    }
    
    // MARK: - Periodic Cleanup

    private nonisolated(unsafe) var periodicCleanupTimer: Timer?

    /// MEMORY LEAK FIX: Periodically trim tracking sets that grow unbounded during a session
    private func startPeriodicCleanup() {
        periodicCleanupTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performPeriodicCleanup()
            }
        }
    }

    private func performPeriodicCleanup() {
        // Trim completedRequests if too large (IDs of successfully loaded images)
        // Keep generous threshold — these are just String IDs (~50 bytes each)
        if completedRequests.count > 2000 {
            let excess = completedRequests.count - 1000
            let keysToRemove = Array(completedRequests.prefix(excess))
            completedRequests.subtract(keysToRemove)
        }

        // Trim permanentlyFailedRequests to prevent unbounded growth
        if permanentlyFailedRequests.count > 200 {
            let excess = permanentlyFailedRequests.count - 100
            let keysToRemove = Array(permanentlyFailedRequests.prefix(excess))
            permanentlyFailedRequests.subtract(keysToRemove)
        }

        // Trim nonImageResponses - these are never cleaned automatically
        if nonImageResponses.count > 200 {
            let excess = nonImageResponses.count - 100
            let keysToRemove = Array(nonImageResponses.prefix(excess))
            nonImageResponses.subtract(keysToRemove)
        }

        // Trim retryCounts
        if retryCounts.count > 100 {
            let keysToKeep = Set(Array(retryCounts.keys).suffix(50))
            retryCounts = retryCounts.filter { keysToKeep.contains($0.key) }
        }
    }

    // MARK: - Memory Monitoring

    private func setupMemoryMonitoring() {
        // Monitor memory warnings
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleMemoryWarning()
            }
        }
    }
    
    private func setupAppLifecycleNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppBackgrounded()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppForegrounded()
            }
        }
    }
    
    private func handleMemoryWarning() {
        let memoryUsage = getCurrentMemoryUsage()
        let memoryUsageMB = memoryUsage / (1024 * 1024)

        // Skip entirely below 900MB; foreground caches are allowed to be useful.
        guard memoryUsageMB > 900 else { return }

        print("🚨 [GlobalImageLoadManager] Memory warning - current usage: \(memoryUsageMB)MB")

        // Only perform aggressive cleanup if memory usage exceeds 1.5GB.
        guard memoryUsageMB > 1500 else { return }
        
        // AGGRESSIVE cleanup on memory warning when usage is high
        print("🧹 [GlobalImageLoadManager] Performing aggressive cleanup")
        
        // Cancel all low and normal priority requests
        cancelLoads(priority: .normal)
        
        // Cancel ALL scheduled retries immediately
        if !scheduledRetries.isEmpty {
            print("🧹 [GlobalImageLoadManager] Cancelling \(scheduledRetries.count) scheduled retries")
            for workItem in scheduledRetries.values {
                workItem.cancel()
            }
            scheduledRetries.removeAll()
        }
        
        // ✅ CRITICAL FIX: Clear pending queue to release closure-captured memory
        // This is the main source of memory buildup - closures capturing SwiftUI views
        let totalPending = pendingRequests.count
        if totalPending > 0 {
            // Keep only critical priority requests
            let criticalRequests = pendingRequests.filter { $0.priority == .critical }
            let removedCount = totalPending - criticalRequests.count
            pendingRequests = criticalRequests
            
            if removedCount > 0 {
                print("🧹 [GlobalImageLoadManager] Removed \(removedCount) pending requests (freed closure memory!)")
                print("🧹 [GlobalImageLoadManager] Kept \(criticalRequests.count) critical requests")
            }
        }
        
        // Clear completed request history to free memory
        let completedCount = completedRequests.count
        completedRequests.removeAll()
        if completedCount > 0 {
            print("🧹 [GlobalImageLoadManager] Cleared \(completedCount) completed requests")
        }
        
        // Clean up retry tracking
        retryCounts.removeAll()
        
        // Clear permanently failed to allow retry after memory recovers
        permanentlyFailedRequests.removeAll()
        
        // Force garbage collection
        updateStatistics()
        
        // Trim cached images on high memory pressure, but keep enough warm cache for scrolling.
        ImageCacheManager.shared.releasePartialCache(percentage: 40)
        
        print("✅ [GlobalImageLoadManager] Cleanup complete")
    }
    
    private func handleAppBackgrounded() {
        // AppDelegate owns the background grace window. Quick backgrounds leave
        // image/video loading state alone; MemoryCapManager calls prepareForBackground()
        // only after the aggressive cleanup path is reached.
    }
    
    private func handleAppForegrounded() {
        // Resume processing pending requests
        processNextPendingRequest()
    }
    
    deinit {
        periodicCleanupTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Convenience Extensions

extension GlobalImageLoadManager {
    /// Load image with critical priority (for currently visible images on screen)
    func loadImageCriticalPriority(id: String, url: URL, attachment: MimeiFileType, baseUrl: URL, completion: @escaping @MainActor (UIImage?) -> Void) {
        let request = ImageLoadRequest(
            id: id,
            url: url,
            attachment: attachment,
            baseUrl: baseUrl,
            priority: .critical,
            completion: completion
        )
        loadImage(request: request)
    }

    /// Load image with high priority (for visible images)
    func loadImageHighPriority(id: String, url: URL, attachment: MimeiFileType, baseUrl: URL, completion: @escaping @MainActor (UIImage?) -> Void) {
        let request = ImageLoadRequest(
            id: id,
            url: url,
            attachment: attachment,
            baseUrl: baseUrl,
            priority: .high,
            completion: completion
        )
        loadImage(request: request)
    }
    
    /// Load image optimized for display with size limits (prevents memory issues)
    func loadImageOptimizedForDisplay(
        id: String,
        url: URL,
        attachment: MimeiFileType,
        baseUrl: URL,
        maxSize: CGSize,
        completion: @escaping @MainActor (UIImage?) -> Void
    ) {
        let request = ImageLoadRequest(
            id: id,
            url: url,
            attachment: attachment,
            baseUrl: baseUrl,
            priority: .high,
            completion: completion
        )
        loadImageOptimized(request: request, maxSize: maxSize)
    }
    
    /// Load image with normal priority (for thumbnails)
    func loadImageNormalPriority(id: String, url: URL, attachment: MimeiFileType, baseUrl: URL, completion: @escaping @MainActor (UIImage?) -> Void) {
        let request = ImageLoadRequest(
            id: id,
            url: url,
            attachment: attachment,
            baseUrl: baseUrl,
            priority: .normal,
            completion: completion
        )
        loadImage(request: request)
    }
    
    /// Load image with low priority (for preloading)
    func loadImageLowPriority(id: String, url: URL, attachment: MimeiFileType, baseUrl: URL, completion: @escaping @MainActor (UIImage?) -> Void) {
        let request = ImageLoadRequest(
            id: id,
            url: url,
            attachment: attachment,
            baseUrl: baseUrl,
            priority: .low,
            completion: completion
        )
        loadImage(request: request)
    }
    
    /// Get current memory usage in bytes
    private func getCurrentMemoryUsage() -> UInt64 {
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
            // Use phys_footprint for accurate measurement
            var vmInfo = task_vm_info_data_t()
            var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / mach_msg_type_number_t(MemoryLayout<natural_t>.size)
            let vmKerr = withUnsafeMutablePointer(to: &vmInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
                }
            }
            
            if vmKerr == KERN_SUCCESS {
                return UInt64(vmInfo.phys_footprint)
            } else {
                return info.resident_size // Fallback
            }
        } else {
            return 0
        }
    }
}
