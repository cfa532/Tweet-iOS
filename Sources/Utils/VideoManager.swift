import Foundation
import AVKit

class VideoManager: ObservableObject {
    @Published var currentVideoIndex: Int = -1
    @Published var videoMids: [String] = []
    @Published var isSequentialPlaybackEnabled: Bool = false
    
    // Static cache to persist current video index per tweet
    // Key: tweet ID, Value: (video MIDs array, current index)
    private static var tweetVideoStateCache: [String: (mids: [String], index: Int)] = [:]
    
    init() {}
    
    func setupSequentialPlayback(for mids: [String], tweetId: String? = nil) {
        videoMids = mids
        isSequentialPlaybackEnabled = mids.count > 1
        
        // Check if we have saved state for this tweet
        if let tweetId = tweetId, let savedState = Self.tweetVideoStateCache[tweetId] {
            // Check if the video sequence is the same
            let isSameSequence = savedState.mids == mids
            
            if isSameSequence {
                // Same sequence - restore saved index if valid
                let savedIndex = savedState.index
                if savedIndex >= 0 && savedIndex < mids.count {
                    currentVideoIndex = savedIndex
                    print("DEBUG: [VideoManager] Restored saved video index \(savedIndex) for tweet \(tweetId) (same sequence)")
                } else {
                    // Invalid saved index - start from beginning
                    currentVideoIndex = 0
                    Self.tweetVideoStateCache[tweetId] = (mids: mids, index: 0)
                    print("DEBUG: [VideoManager] Invalid saved index, starting at index 0 for tweet \(tweetId)")
                }
            } else {
                // Different sequence - reset to beginning and update cache
                currentVideoIndex = 0
                Self.tweetVideoStateCache[tweetId] = (mids: mids, index: 0)
                print("DEBUG: [VideoManager] Video sequence changed for tweet \(tweetId), resetting to index 0")
            }
        } else {
            // No saved state - first time or no tweet ID
            currentVideoIndex = 0
            if let tweetId = tweetId {
                // Save initial state
                Self.tweetVideoStateCache[tweetId] = (mids: mids, index: 0)
            }
            print("DEBUG: [VideoManager] Setup sequential playback for \(mids.count) videos - starting at index 0")
        }
    }
    
    // Save current index for a tweet
    func saveCurrentIndex(for tweetId: String) {
        guard currentVideoIndex >= 0 && currentVideoIndex < videoMids.count else { return }
        Self.tweetVideoStateCache[tweetId] = (mids: videoMids, index: currentVideoIndex)
        print("DEBUG: [VideoManager] Saved video index \(currentVideoIndex) for tweet \(tweetId)")
    }
    
    // Clear saved state for a tweet (when tweet is deleted or sequence changes)
    static func clearSavedState(for tweetId: String) {
        tweetVideoStateCache.removeValue(forKey: tweetId)
        print("DEBUG: [VideoManager] Cleared saved state for tweet \(tweetId)")
    }
    
    func stopSequentialPlayback() {
        videoMids = []
        currentVideoIndex = -1
        isSequentialPlaybackEnabled = false
    }
    
    func forceReset() {
        guard !videoMids.isEmpty else { return }
        currentVideoIndex = 0 // Force reset to first video
        print("DEBUG: [VideoManager] FORCE RESET - Reset to first video at index 0")
    }
    
    func restartSequentialPlayback() {
        guard !videoMids.isEmpty else { return }
        
        currentVideoIndex = 0 // Reset to first video
        isSequentialPlaybackEnabled = videoMids.count > 1
        print("DEBUG: [VideoManager] Restarted sequential playback from beginning")
    }
    
    func onVideoFinished(tweetId: String? = nil) {
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
            // Clear saved state if all videos finished
            if let tweetId = tweetId {
                Self.clearSavedState(for: tweetId)
            }
            // Clear the state to stop any further playback
            videoMids = []
            currentVideoIndex = -1
            isSequentialPlaybackEnabled = false
        }
    }
    
    func shouldPlayVideo(for mid: String) -> Bool {
        // If sequential playback is enabled, only play the current video in sequence
        if isSequentialPlaybackEnabled {
            guard currentVideoIndex >= 0 && currentVideoIndex < videoMids.count else { 
                print("DEBUG: [VideoManager] Invalid currentVideoIndex: \(currentVideoIndex), videoMids count: \(videoMids.count)")
                return false 
            }
            let shouldPlay = videoMids[currentVideoIndex] == mid
            print("DEBUG: [VideoManager] Sequential playback - video \(mid) should play: \(shouldPlay) (current index: \(currentVideoIndex))")
            return shouldPlay
        }
        
        // If sequential playback is not enabled but we have video MIDs, 
        // it means we have a single video that should play
        if !videoMids.isEmpty && videoMids.contains(mid) {
            let shouldPlay = videoMids[0] == mid // Single video should always be the first one
            return shouldPlay
        }
        return false
    }
    
    func getCurrentVideoMid() -> String? {
        guard currentVideoIndex >= 0 && currentVideoIndex < videoMids.count else { return nil }
        return videoMids[currentVideoIndex]
    }
}
