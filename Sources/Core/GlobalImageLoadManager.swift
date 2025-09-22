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
class GlobalImageLoadManager: ObservableObject {
    static let shared = GlobalImageLoadManager()
    
    // MARK: - Configuration
    private let maxConcurrentLoads = 8
    private let maxQueueSize = 100
    private let memoryWarningThreshold = 0.8 // 80% of available memory
    
    // MARK: - State Management
    private var activeLoads: [String: Task<Void, Never>] = [:]
    private var pendingRequests: [ImageLoadRequest] = []
    private var completedRequests: Set<String> = []
    private var retryCounts: [String: Int] = [:] // Track retry attempts per request
    private var nonImageResponses: Set<String> = [] // Track requests that returned non-image content
    
    // MARK: - Memory Management
    private var currentMemoryUsage: UInt64 = 0
    private var maxMemoryUsage: UInt64 = 0
    
    // MARK: - Statistics
    @Published var activeLoadCount: Int = 0
    @Published var pendingLoadCount: Int = 0
    @Published var completedLoadCount: Int = 0
    @Published var retryCount: Int = 0
    
    private init() {
        setupMemoryMonitoring()
        setupAppLifecycleNotifications()
    }
    
    // MARK: - Public Interface
    
    /// Load an image with priority and concurrency control
    func loadImage(request: ImageLoadRequest) {
        // Check if already completed successfully
        if completedRequests.contains(request.id) {
            return
        }
        
        // Check if this request previously returned non-image content (don't retry)
        if nonImageResponses.contains(request.id) {
            return
        }
        
        // Check if already loading
        if activeLoads[request.id] != nil {
            return
        }
        
        // If image reappears and we haven't completed it successfully, reset retry count
        // This allows images to be retried when they come back into view
        if let currentRetryCount = retryCounts[request.id], currentRetryCount > 0 {
            retryCounts[request.id] = 0
        }
        
        // Check memory pressure
        if isMemoryPressureHigh() {
            if request.priority.rawValue < ImageLoadingPriority.high.rawValue {
                // Defer low priority requests during memory pressure
                deferRequest(request)
                return
            }
        }
        
        // Check if we can start loading immediately
        if activeLoads.count < maxConcurrentLoads {
            startLoading(request)
        } else {
            // Add to pending queue
            addToPendingQueue(request)
        }
    }
    
    /// Cancel a specific image load request
    func cancelLoad(id: String) {
        // Cancel active load
        activeLoads[id]?.cancel()
        activeLoads.removeValue(forKey: id)
        
        // Remove from pending queue
        pendingRequests.removeAll { $0.id == id }
        
        updateStatistics()
    }
    
    /// Force retry a failed image load
    func retryLoad(id: String) {
        // Remove from completed/failed tracking to allow retry
        completedRequests.remove(id)
        retryCounts.removeValue(forKey: id)
    }
    
    /// Cancel all loads for a specific priority or lower
    func cancelLoads(priority: ImageLoadingPriority) {
        let requestsToCancel = activeLoads.filter { request in
            // Find the request in pending queue to check priority
            if let pendingRequest = pendingRequests.first(where: { $0.id == request.key }) {
                return pendingRequest.priority.rawValue <= priority.rawValue
            }
            return false
        }
        
        for (id, _) in requestsToCancel {
            cancelLoad(id: id)
        }
    }
    
    /// Clear all completed request history
    func clearHistory() {
        completedRequests.removeAll()
        retryCounts.removeAll()
        nonImageResponses.removeAll()
        updateStatistics()
    }
    
    /// Get current loading statistics
    func getStatistics() -> (active: Int, pending: Int, completed: Int, retries: Int) {
        return (activeLoads.count, pendingRequests.count, completedRequests.count, retryCounts.values.reduce(0, +))
    }
    
    /// Get current memory usage information
    func getMemoryInfo() -> (current: UInt64, max: UInt64, pressure: Bool) {
        return (currentMemoryUsage, maxMemoryUsage, isMemoryPressureHigh())
    }
    
    /// Force cleanup of completed requests to free memory
    func forceCleanup() {
        completedRequests.removeAll()
        // Keep retry counts so images can still be retried when they reappear
        updateStatistics()
    }
    
    // MARK: - Private Methods
    
    private func handleLoadFailure(_ request: ImageLoadRequest) {
        let currentRetryCount = retryCounts[request.id] ?? 0
        let newRetryCount = currentRetryCount + 1
        retryCounts[request.id] = newRetryCount
        
        if newRetryCount < 3 {
            // Schedule retry with exponential backoff
            let delay = Double(newRetryCount) * 2.0 // 2s, 4s, 6s delays
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.loadImage(request: request)
            }
        }
    }
    
    private func startLoading(_ request: ImageLoadRequest) {
        let task = Task {
            // Check if image is already cached
            if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: request.attachment, baseUrl: request.baseUrl) {
                await MainActor.run {
                    request.completion(cachedImage)
                    self.completedRequests.insert(request.id)
                    self.activeLoads.removeValue(forKey: request.id)
                    self.updateStatistics()
                    self.processNextPendingRequest()
                }
                return
            }
            
            // Load from network
            let image = await loadImageFromNetwork(request)
            
            await MainActor.run {
                if let image = image {
                    request.completion(image)
                    self.completedRequests.insert(request.id)
                    self.retryCounts.removeValue(forKey: request.id) // Clear retry count on success
                } else {
                    self.handleLoadFailure(request)
                }
                self.activeLoads.removeValue(forKey: request.id)
                self.updateStatistics()
                self.processNextPendingRequest()
            }
        }
        
        activeLoads[request.id] = task
        updateStatistics()
    }
    
    private func loadImageFromNetwork(_ request: ImageLoadRequest) async -> UIImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: request.url)
            
            // Check if we got a valid response
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            
            // Update progress
            await MainActor.run {
                request.onProgress(1.0)
            }
            
            // Check if data is empty
            guard !data.isEmpty else {
                return nil
            }
            
            // Cache the image data
            ImageCacheManager.shared.cacheImageData(data, for: request.attachment, baseUrl: request.baseUrl)
            
            // Create UIImage directly from data
            if let image = UIImage(data: data) {
                return image
            }
            
            return nil
            
        } catch {
            return nil
        }
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
        if activeLoads.count < maxConcurrentLoads {
            startLoadingOptimized(request, maxSize: maxSize)
        } else {
            // Add to pending queue with special handling
            addToPendingQueue(request)
        }
    }
    
    private func startLoadingOptimized(_ request: ImageLoadRequest, maxSize: CGSize) {
        let task = Task {
            do {
                // Check if image is already cached
                if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: request.attachment, baseUrl: request.baseUrl) {
                    await MainActor.run {
                        request.completion(cachedImage)
                        self.completedRequests.insert(request.id)
                        self.activeLoads.removeValue(forKey: request.id)
                        self.updateStatistics()
                        self.processNextPendingRequest()
                    }
                    return
                }
                
                // Load from network with size optimization
                let optimizedImage = await loadImageFromNetworkOptimized(request, maxSize: maxSize)
                
                await MainActor.run {
                    request.completion(optimizedImage)
                    if optimizedImage != nil {
                        self.completedRequests.insert(request.id)
                        self.retryCounts.removeValue(forKey: request.id) // Clear retry count on success
                    } else {
                        self.handleLoadFailure(request)
                    }
                    self.activeLoads.removeValue(forKey: request.id)
                    self.updateStatistics()
                    self.processNextPendingRequest()
                }
            }
        }
        
        activeLoads[request.id] = task
        updateStatistics()
    }
    
    private func loadImageFromNetworkOptimized(_ request: ImageLoadRequest, maxSize: CGSize) async -> UIImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: request.url)
            
            // Check if we got a valid response
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            
            // Update progress
            await MainActor.run {
                request.onProgress(1.0)
            }
            
            // Create UIImage from data
            guard let originalImage = UIImage(data: data) else { return nil }
            
            // Resize image to fit within maxSize while maintaining aspect ratio
            let resizedImage = resizeImage(originalImage, toFit: maxSize)
            
            // Cache the resized image
            if let resizedData = resizedImage.jpegData(compressionQuality: 0.8) {
                ImageCacheManager.shared.cacheImageData(resizedData, for: request.attachment, baseUrl: request.baseUrl)
            }
            
            return resizedImage
        } catch {
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
    
    private func processNextPendingRequest() {
        guard activeLoads.count < maxConcurrentLoads,
              !pendingRequests.isEmpty else {
            return
        }
        
        // Get the highest priority request
        let nextRequest = pendingRequests.removeFirst()
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
    
    private func isMemoryPressureHigh() -> Bool {
        var memoryInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &memoryInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            currentMemoryUsage = memoryInfo.resident_size
            if currentMemoryUsage > maxMemoryUsage {
                maxMemoryUsage = currentMemoryUsage
            }
            
            // Simple heuristic: if we're using more than 80% of available memory
            let availableMemory = ProcessInfo.processInfo.physicalMemory
            let memoryUsageRatio = Double(currentMemoryUsage) / Double(availableMemory)
            let isHigh = memoryUsageRatio > memoryWarningThreshold
            
            if isHigh {
                print("DEBUG: [GlobalImageLoadManager] High memory pressure detected: \(String(format: "%.1f", memoryUsageRatio * 100))% of available memory used")
            }
            
            return isHigh
        }
        
        return false
    }
    
    private func updateStatistics() {
        activeLoadCount = activeLoads.count
        pendingLoadCount = pendingRequests.count
        completedLoadCount = completedRequests.count
        retryCount = retryCounts.values.reduce(0, +)
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
                print("DEBUG: [GlobalImageLoadManager] System memory warning received")
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
        // Check if memory usage exceeds 1GB before taking action
        let memoryUsage = getCurrentMemoryUsage()
        let memoryUsageMB = memoryUsage / (1024 * 1024)
        
        print("DEBUG: [GlobalImageLoadManager] Memory warning - current usage: \(memoryUsageMB)MB")
        
        // Only take action if memory usage exceeds 1GB
        if memoryUsageMB > 1024 {
            print("DEBUG: [GlobalImageLoadManager] Memory usage exceeds 1GB, performing cleanup")
            
            // Cancel all low priority requests
            cancelLoads(priority: .low)
            
            // Clear completed request history to free memory
            completedRequests.removeAll()
            // Keep retry counts so images can still be retried when they reappear
            
            // Force garbage collection
            updateStatistics()
        } else {
            print("DEBUG: [GlobalImageLoadManager] Memory usage under 1GB, no action needed")
        }
    }
    
    private func handleAppBackgrounded() {
        // Cancel all non-critical requests when app goes to background
        cancelLoads(priority: .normal)
    }
    
    private func handleAppForegrounded() {
        // Resume processing pending requests
        processNextPendingRequest()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Convenience Extensions

extension GlobalImageLoadManager {
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
            return info.resident_size
        } else {
            return 0
        }
    }
}
