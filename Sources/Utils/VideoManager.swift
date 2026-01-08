import Foundation
import AVKit

class VideoManager: ObservableObject {
    @Published var currentVideoIndex: Int = -1
    @Published var videoMids: [String] = []
    
    // Static cache to persist current video index per tweet
    // Key: tweet ID, Value: (video MIDs array, current index, last access time)
    private static var tweetVideoStateCache: [String: (mids: [String], index: Int, lastAccess: Date)] = [:]
    private static let maxCacheSize = 100 // Maximum number of tweet video states to cache
    private static let cacheLock = NSLock()
    private static var observersSetup = false
    private static let observersLock = NSLock()
    private static var notificationObservers: [NSObjectProtocol] = []
    
    init() {
        Self.setupNotificationObserversOnce()
    }
    
    deinit {
        // Observers are static and shared, no need to remove per instance
    }
    
    // Setup notification observers only once (static observers shared across all instances)
    private static func setupNotificationObserversOnce() {
        observersLock.lock()
        defer { observersLock.unlock() }
        
        guard !observersSetup else { return }
        observersSetup = true
        
        // Clear cache on logout
        let logoutObserver = NotificationCenter.default.addObserver(
            forName: .userDidLogout,
            object: nil,
            queue: .main
        ) { _ in
            clearAllCache()
        }
        notificationObservers.append(logoutObserver)
        
        // Clear state for deleted tweets
        let tweetDeletedObserver = NotificationCenter.default.addObserver(
            forName: .tweetDeleted,
            object: nil,
            queue: .main
        ) { notification in
            if let tweetId = notification.userInfo?["tweetId"] as? String {
                clearSavedState(for: tweetId)
            }
        }
        notificationObservers.append(tweetDeletedObserver)
        // Removed repetitive setup log
    }
    
    func setupSequentialPlayback(for mids: [String], tweetId: String? = nil) async {
        // Update published properties on main thread
        await MainActor.run {
            videoMids = mids

            // Check if we have saved state for this tweet
            if let tweetId = tweetId, let savedState = Self.getSavedState(for: tweetId) {
                // Check if the video sequence is the same
                let isSameSequence = savedState.mids == mids

                if isSameSequence {
                    // Same sequence - restore saved index if valid
                    let savedIndex = savedState.index
                    if savedIndex >= 0 && savedIndex < mids.count {
                        currentVideoIndex = savedIndex
                        Self.updateLastAccess(for: tweetId)
                        // Removed repetitive restore log
                    } else {
                        // Invalid saved index - start from beginning
                        currentVideoIndex = 0
                        Self.saveState(tweetId: tweetId, mids: mids, index: 0)
                        print("DEBUG: [VideoManager] Invalid saved index, starting at index 0 for tweet \(tweetId)")
                    }
                } else {
                    // Different sequence - reset to beginning and update cache
                    currentVideoIndex = 0
                    Self.saveState(tweetId: tweetId, mids: mids, index: 0)
                    print("DEBUG: [VideoManager] Video sequence changed for tweet \(tweetId), resetting to index 0")
                }
            } else {
                // No saved state - first time or no tweet ID
                currentVideoIndex = 0
                if let tweetId = tweetId {
                    // Save initial state
                    Self.saveState(tweetId: tweetId, mids: mids, index: 0)
                }
                // Removed repetitive setup log
            }
        }
    }
    
    // Save current index for a tweet
    func saveCurrentIndex(for tweetId: String) {
        guard currentVideoIndex >= 0 && currentVideoIndex < videoMids.count else { return }
        Self.saveState(tweetId: tweetId, mids: videoMids, index: currentVideoIndex)
        // Removed repetitive save log
    }
    
    // Clear saved state for a tweet (when tweet is deleted or sequence changes)
    static func clearSavedState(for tweetId: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        tweetVideoStateCache.removeValue(forKey: tweetId)
        print("DEBUG: [VideoManager] Cleared saved state for tweet \(tweetId)")
    }
    
    // Clear all cached video states (e.g., on logout)
    static func clearAllCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let count = tweetVideoStateCache.count
        tweetVideoStateCache.removeAll()
        print("DEBUG: [VideoManager] Cleared all \(count) cached video states")
    }
    
    // Private helper to get saved state with thread safety
    private static func getSavedState(for tweetId: String) -> (mids: [String], index: Int, lastAccess: Date)? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return tweetVideoStateCache[tweetId]
    }
    
    // Private helper to save state with thread safety and cache size management
    private static func saveState(tweetId: String, mids: [String], index: Int) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        // Update or add entry with current timestamp
        tweetVideoStateCache[tweetId] = (mids: mids, index: index, lastAccess: Date())
        
        // Prune cache if it exceeds max size
        if tweetVideoStateCache.count > maxCacheSize {
            pruneCache()
        }
    }
    
    // Private helper to update last access time
    private static func updateLastAccess(for tweetId: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        if var state = tweetVideoStateCache[tweetId] {
            state.lastAccess = Date()
            tweetVideoStateCache[tweetId] = state
        }
    }
    
    // Prune cache by removing oldest entries when cache exceeds max size
    private static func pruneCache() {
        let currentSize = tweetVideoStateCache.count
        let pruneCount = currentSize - maxCacheSize
        
        guard pruneCount > 0 else { return }
        
        // Sort entries by last access time and remove oldest
        let sortedEntries = tweetVideoStateCache.sorted { $0.value.lastAccess < $1.value.lastAccess }
        let entriesToRemove = sortedEntries.prefix(pruneCount)
        
        for (tweetId, _) in entriesToRemove {
            tweetVideoStateCache.removeValue(forKey: tweetId)
        }
        
        print("DEBUG: [VideoManager] Pruned \(pruneCount) oldest video state entries (cache was \(currentSize), now \(tweetVideoStateCache.count))")
    }
    
    func stopSequentialPlayback() async {
        await MainActor.run {
            videoMids = []
            currentVideoIndex = -1
        }
    }
    
    func forceReset() async {
        guard !videoMids.isEmpty else { return }
        await MainActor.run {
            currentVideoIndex = 0 // Force reset to first video
            print("DEBUG: [VideoManager] FORCE RESET - Reset to first video at index 0")
        }
    }
    
    func restartSequentialPlayback() async {
        guard !videoMids.isEmpty else { return }

        await MainActor.run {
            currentVideoIndex = 0 // Reset to first video
            print("DEBUG: [VideoManager] Restarted sequential playback from beginning")
        }
    }
    
    func onVideoFinished(tweetId: String? = nil) async {
        await MainActor.run {
            print("DEBUG: [VideoManager] onVideoFinished called - currentVideoIndex: \(currentVideoIndex), videoMids.count: \(videoMids.count), tweetId: \(tweetId ?? "nil")")
            let nextIndex = currentVideoIndex + 1
            if nextIndex < videoMids.count {
                currentVideoIndex = nextIndex
                print("DEBUG: [VideoManager] Video finished, moved to next video: \(nextIndex)")
                // Save the new index
                if let tweetId = tweetId {
                    saveCurrentIndex(for: tweetId)
                }
            } else {
                // All videos finished, stop sequential playback
                print("DEBUG: [VideoManager] All videos finished, stopping sequential playback")
                // Clear saved state if all videos finished to free memory
                if let tweetId = tweetId {
                    Self.clearSavedState(for: tweetId)
                }
                // Clear the state to stop any further playback
                videoMids = []
                currentVideoIndex = -1
            }
        }
    }
    
    func shouldPlayVideo(for mid: String) -> Bool {
        // MediaGrid always uses sequential playback (even for single videos)
        // Only play the video at the current index in the sequence
        guard currentVideoIndex >= 0 && currentVideoIndex < videoMids.count else { 
            // Only log if this is unexpected (not during normal state transitions)
            // Suppress logging during normal setup/teardown to reduce noise
            return false 
        }
        
        let shouldPlay = videoMids[currentVideoIndex] == mid
        // Removed verbose logging - this function is called very frequently
        // and causes performance issues and recomposition
        return shouldPlay
    }
    
    func getCurrentVideoMid() -> String? {
        guard currentVideoIndex >= 0 && currentVideoIndex < videoMids.count else { return nil }
        return videoMids[currentVideoIndex]
    }
}
