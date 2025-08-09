import Foundation
import AVKit

class VideoManager: ObservableObject {
    @Published var currentVideoIndex: Int = -1
    @Published var videoMids: [String] = []
    @Published var isSequentialPlaybackEnabled: Bool = false
    
    init() {}
    
    func setupSequentialPlayback(for mids: [String]) {
        // Check if this is a new sequence or the same sequence
        let isNewSequence = videoMids != mids && !videoMids.isEmpty
        
        videoMids = mids
        currentVideoIndex = 0 // Always start with first video
        isSequentialPlaybackEnabled = mids.count > 1
        
        if isNewSequence {
            print("DEBUG: [VideoManager] Setup NEW sequential playback for \(mids.count) videos - starting at index 0")
            // New sequence - no need to reset players since we use independent instances
        } else {
            print("DEBUG: [VideoManager] Setup \(videoMids.isEmpty ? "FIRST TIME" : "EXISTING") sequential playback for \(mids.count) videos - starting at index 0")
        }
    }
    
    func stopSequentialPlayback() {
        videoMids = []
        currentVideoIndex = -1
        isSequentialPlaybackEnabled = false
        print("DEBUG: [VideoManager] Stopped sequential playback")
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
    
    func onVideoFinished() {
        let nextIndex = currentVideoIndex + 1
        if nextIndex < videoMids.count {
            currentVideoIndex = nextIndex
            print("DEBUG: [VideoManager] Video finished, moved to next video: \(nextIndex)")
        } else {
            // All videos finished, stop sequential playback
            print("DEBUG: [VideoManager] All videos finished, stopping sequential playback")
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
            print("DEBUG: [VideoManager] Single video playback - video \(mid) should play: \(shouldPlay)")
            return shouldPlay
        }
        
        print("DEBUG: [VideoManager] Video \(mid) should not play - no matching conditions")
        return false
    }
    
    func getCurrentVideoMid() -> String? {
        guard currentVideoIndex >= 0 && currentVideoIndex < videoMids.count else { return nil }
        return videoMids[currentVideoIndex]
    }
}
