import Foundation
import AVKit

class VideoManager: ObservableObject {
    @Published var currentVideoIndex: Int = -1
    @Published var videoMids: [String] = []
    @Published var isSequentialPlaybackEnabled: Bool = false
    
    init() {}
    
    func setupSequentialPlayback(for mids: [String]) {
        videoMids = mids
        currentVideoIndex = 0 // Start with first video
        isSequentialPlaybackEnabled = mids.count > 1
        print("DEBUG: [VideoManager] Setup sequential playback for \(mids.count) videos")
    }
    
    func stopSequentialPlayback() {
        videoMids = []
        currentVideoIndex = -1
        isSequentialPlaybackEnabled = false
        print("DEBUG: [VideoManager] Stopped sequential playback")
    }
    
    func onVideoFinished() {
        guard isSequentialPlaybackEnabled else { return }
        
        let nextIndex = currentVideoIndex + 1
        if nextIndex < videoMids.count {
            currentVideoIndex = nextIndex
            print("DEBUG: [VideoManager] Video finished, moved to next video: \(nextIndex)")
        } else {
            // All videos finished, restart from beginning
            currentVideoIndex = 0
            print("DEBUG: [VideoManager] All videos finished, restarting from beginning")
        }
    }
    
    func shouldPlayVideo(for mid: String) -> Bool {
        // If sequential playback is enabled, only play the current video
        if isSequentialPlaybackEnabled {
            guard currentVideoIndex >= 0 && currentVideoIndex < videoMids.count else { return false }
            return videoMids[currentVideoIndex] == mid
        }
        
        // If sequential playback is not enabled but we have video MIDs, 
        // it means we have a single video that should play
        if !videoMids.isEmpty && videoMids.contains(mid) {
            return true
        }
        
        return false
    }
    
    func getCurrentVideoMid() -> String? {
        guard currentVideoIndex >= 0 && currentVideoIndex < videoMids.count else { return nil }
        return videoMids[currentVideoIndex]
    }
}
