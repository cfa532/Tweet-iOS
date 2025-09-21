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
        print("DEBUG: [GlobalImageLoadManager] loadImage called for \(request.id), priority: \(request.priority), active: \(activeLoads.count)/\(maxConcurrentLoads), pending: \(pendingRequests.count)")
        
        // Check if already completed successfully
        if completedRequests.contains(request.id) {
            print("DEBUG: [GlobalImageLoadManager] Request \(request.id) already completed successfully, skipping")
            return
        }
        
        // Check if this request previously returned non-image content (don't retry)
        if nonImageResponses.contains(request.id) {
            print("DEBUG: [GlobalImageLoadManager] Request \(request.id) previously returned non-image content, skipping retry")
            return
        }
        
        // Check if already loading
        if activeLoads[request.id] != nil {
            print("DEBUG: [GlobalImageLoadManager] Request \(request.id) already loading, skipping")
            return
        }
        
        // If image reappears and we haven't completed it successfully, reset retry count
        // This allows images to be retried when they come back into view
        if let currentRetryCount = retryCounts[request.id], currentRetryCount > 0 {
            print("DEBUG: [GlobalImageLoadManager] Image \(request.id) reappeared, resetting retry count from \(currentRetryCount) to 0")
            retryCounts[request.id] = 0
        }
        
        // Check memory pressure
        if isMemoryPressureHigh() {
            if request.priority.rawValue < ImageLoadingPriority.high.rawValue {
                // Defer low priority requests during memory pressure
                print("DEBUG: [GlobalImageLoadManager] Memory pressure high, deferring \(request.id)")
                deferRequest(request)
                return
            }
        }
        
        // Check if we can start loading immediately
        if activeLoads.count < maxConcurrentLoads {
            print("DEBUG: [GlobalImageLoadManager] Starting load for \(request.id) immediately")
            startLoading(request)
        } else {
            // Add to pending queue
            print("DEBUG: [GlobalImageLoadManager] Adding \(request.id) to pending queue")
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
        
        print("DEBUG: [GlobalImageLoadManager] Force retry requested for: \(id)")
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
        print("DEBUG: [GlobalImageLoadManager] Forced cleanup of completed requests")
    }
    
    // MARK: - Private Methods
    
    private func handleLoadFailure(_ request: ImageLoadRequest) {
        let currentRetryCount = retryCounts[request.id] ?? 0
        let newRetryCount = currentRetryCount + 1
        retryCounts[request.id] = newRetryCount
        
        print("DEBUG: [GlobalImageLoadManager] Load failed for \(request.id), retry count: \(newRetryCount)/3")
        
        if newRetryCount < 3 {
            // Schedule retry with exponential backoff
            let delay = Double(newRetryCount) * 2.0 // 2s, 4s, 6s delays
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                print("DEBUG: [GlobalImageLoadManager] Retrying \(request.id) (attempt \(newRetryCount + 1))")
                self.loadImage(request: request)
            }
        } else {
            print("DEBUG: [GlobalImageLoadManager] Max retries exceeded for \(request.id), giving up")
        }
    }
    
    private func startLoading(_ request: ImageLoadRequest) {
        print("DEBUG: [GlobalImageLoadManager] startLoading for \(request.id), active count: \(activeLoads.count)")
        
        let task = Task {
            // Check if image is already cached
            if let cachedImage = ImageCacheManager.shared.getCompressedImage(for: request.attachment, baseUrl: request.baseUrl) {
                print("DEBUG: [GlobalImageLoadManager] Found cached image for \(request.id)")
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
            print("DEBUG: [GlobalImageLoadManager] Loading from network for \(request.id)")
            let image = await loadImageFromNetwork(request)
            
            await MainActor.run {
                if let image = image {
                    print("DEBUG: [GlobalImageLoadManager] Successfully loaded \(request.id)")
                    request.completion(image)
                    self.completedRequests.insert(request.id)
                    self.retryCounts.removeValue(forKey: request.id) // Clear retry count on success
                } else {
                    print("DEBUG: [GlobalImageLoadManager] Image processing failed for \(request.id)")
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
                print("DEBUG: [GlobalImageLoadManager] Invalid HTTP response for \(request.id): \(response)")
                return nil
            }
            
            // Update progress
            await MainActor.run {
                request.onProgress(1.0)
            }
            
            // Get content type
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            print("DEBUG: [GlobalImageLoadManager] Downloaded \(data.count) bytes for \(request.id), content-type: \(contentType)")
            
            // Check if data is empty
            guard !data.isEmpty else {
                print("DEBUG: [GlobalImageLoadManager] Empty data received for \(request.id)")
                return nil
            }
            
            // Check if we received HTML instead of an image (common server error response)
            if contentType.lowercased().contains("text/html") {
                print("DEBUG: [GlobalImageLoadManager] Server returned HTML instead of image for \(request.id) - likely 404 or server error")
                await MainActor.run {
                    self.nonImageResponses.insert(request.id)
                }
                return nil
            }
            
            // Check if content type indicates it's not an image
            let imageContentTypes = ["image/jpeg", "image/jpg", "image/png", "image/gif", "image/webp", "image/bmp", "image/tiff"]
            let isImageContentType = imageContentTypes.contains { contentType.lowercased().contains($0) }
            
            if !isImageContentType && contentType != "unknown" {
                print("DEBUG: [GlobalImageLoadManager] Non-image content type for \(request.id): \(contentType)")
                await MainActor.run {
                    self.nonImageResponses.insert(request.id)
                }
                return nil
            }
            
            // Cache the image data
            ImageCacheManager.shared.cacheImageData(data, for: request.attachment, baseUrl: request.baseUrl)
            
            // Try to get the compressed image first
            if let compressedImage = ImageCacheManager.shared.getCompressedImage(for: request.attachment, baseUrl: request.baseUrl) {
                print("DEBUG: [GlobalImageLoadManager] Successfully loaded compressed image for \(request.id)")
                return compressedImage
            }
            
            // If compressed image retrieval failed, try to create UIImage directly from data
            if let directImage = UIImage(data: data) {
                print("DEBUG: [GlobalImageLoadManager] Using direct UIImage creation for \(request.id) (compression may have failed)")
                return directImage
            }
            
            // If both methods fail, this is a real failure - log more details
            print("DEBUG: [GlobalImageLoadManager] Failed to create UIImage from data for \(request.id) - data size: \(data.count) bytes, first 20 bytes: \(data.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " "))")
            return nil
            
        } catch {
            print("DEBUG: [GlobalImageLoadManager] Network error for \(request.id): \(error)")
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
            print("Error loading optimized image: \(error)")
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
            return Double(currentMemoryUsage) / Double(availableMemory) > memoryWarningThreshold
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
        // Cancel all low priority requests
        cancelLoads(priority: .low)
        
        // Clear completed request history to free memory
        completedRequests.removeAll()
        // Keep retry counts so images can still be retried when they reappear
        
        // Force garbage collection
        updateStatistics()
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
}
