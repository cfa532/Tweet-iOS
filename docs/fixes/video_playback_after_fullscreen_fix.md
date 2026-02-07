# Video Playback Issues Fix - MediaCell and Fullscreen

## Date
December 25, 2025

## Problems Identified

### Problem 1: Fullscreen Video Stuck with Loading Spinner
**Symptom:** When opening a video in fullscreen, sometimes it would show only a loading spinner indefinitely, even though the video was already cached and buffered in the MediaCell.

**Root Cause:** 
- When `FullScreenVideoManager` created a new `AVPlayerItem` from a cached `AVAsset`, the playerItem started with status `.unknown` (0)
- At line 528-530 of `SingletonVideoManagers.swift`, the code set `self.isPlaying = true` but **never called `play()`** when the playerItem became ready
- The observer in `SingletonVideoPlayerView` (lines 982-993 of `MediaBrowserView.swift`) only logged "FullScreenVideoManager will handle playback" but didn't actually start playback
- This was a broken handoff - neither component took responsibility for starting playback

**Log Evidence:**
```
DEBUG: [FullScreenVideoManager] Cached playerItem not ready yet (status: 0), will play when ready
🔄 [FULLSCREEN WAITING] Showing spinner
🔄 [FULLSCREEN RETRY] Player stuck at 0.0s, seeking to trigger segment load
⚠️ [FULLSCREEN RETRY] Timeout waiting for data, will retry on next cycle
```

### Problem 2: MediaCell Video Doesn't Play After Closing Fullscreen
**Symptom:** After closing fullscreen and returning to the feed, sometimes the MediaCell video would remain paused and not restart playback, even though it was visible and should be playing.

**Root Cause:**
- When fullscreen was stuck (Problem 1), the video state was saved as `0.0s, wasPlaying=false`
- When returning to MediaCell, the `.reloadVisibleVideosOnly` notification triggered `handleReloadVisibleVideosOnly()`
- For "healthy" players, it called `checkPlaybackConditions()`, but this didn't restart the paused video
- The player was deemed healthy but remained paused at 0.0s

**Log Evidence:**
```
📝 [VIDEO STATE] Saved state for Qmeapo48Fu4oVnNcwFCZZyD49XXexQJETTg4FSzQA2m6Fp: time=0.0s, wasPlaying=false, context=fullscreen
DEBUG: [VIDEO RELOAD VISIBLE] Reload requested for visible video Qmeapo48Fu4oVnNcwFCZZyD49XXexQJETTg4FSzQA2m6Fp
DEBUG: [VIDEO RELOAD] Intact player appears healthy, no refresh needed for Qmeapo48Fu4oVnNcwFCZZyD49XXexQJETTg4FSzQA2m6Fp
```

## Solutions Implemented

### Fix 1: Observe PlayerItem Status in FullScreenVideoManager
**File:** `Sources/Core/SingletonVideoManagers.swift`
**Lines:** 531-599 (added after line 530)

Added a KVO observer on `playerItem.status` that:
1. Waits for the playerItem to become `.readyToPlay`
2. Checks if video finished in mediaCell (restart from beginning if so)
3. Restores saved position if available
4. Starts playback by calling `play()`
5. Cleans up the observer after handling

This ensures fullscreen videos always start playing when the cached playerItem becomes ready, fixing the infinite spinner issue.

**Key Code Addition:**
```swift
// CRITICAL: Observe playerItem status to start playback when it becomes ready
self.itemStatusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
    guard let self = self else { return }
    
    DispatchQueue.main.async {
        guard item.status == .readyToPlay else { return }
        
        print("✅ [FullScreenVideoManager] Cached playerItem became ready, starting playback")
        
        // Check for finished videos, restore position, and start playback
        // ... (full implementation in file)
    }
}
```

### Fix 2: Explicitly Restart Paused Videos After Fullscreen
**File:** `Sources/Features/MediaViews/SimpleVideoPlayer.swift`
**Lines:** 2317-2333 (added after line 2315)

Added explicit handling in `handleReloadVisibleVideosOnly()` to:
1. Check if player is paused (`rate == 0`) after `checkPlaybackConditions()` is called
2. Verify video should be playing (VideoManager approval, visibility, etc.)
3. Explicitly restart playback by calling `playWithResumeIfNeeded()`

This ensures MediaCell videos restart after returning from fullscreen, even if the previous fullscreen session was stuck.

**Key Code Addition:**
```swift
// CRITICAL FIX: After returning from fullscreen, explicitly restart playback if needed
// Sometimes checkPlaybackConditions doesn't restart paused videos (e.g. saved at 0.0s from stuck fullscreen)
if let player = self.player, player.rate == 0, currentAutoPlay {
    // Check if video should be playing according to VideoManager
    let approved = self.videoManager?.shouldPlayVideo(for: self.mid) ?? true
    let actuallyVisible = !self.isCoveredByOverlay
    let noDetailViewActive = !DetailVideoManager.shared.isDetailViewActive()
    let isReady = player.currentItem?.status == .readyToPlay
    
    if approved && actuallyVisible && noDetailViewActive && isReady {
        print("🔄 [VIDEO RELOAD] Explicitly restarting paused video after fullscreen for \(self.mid)")
        player.isMuted = MuteState.shared.isMuted
        playWithResumeIfNeeded(player)
        playbackState = .playing
    }
}
```

## Expected Behavior After Fix

### Fullscreen Videos
- When opening fullscreen with a cached video, the playerItem will be observed until it becomes ready
- Once ready, playback will start automatically
- No more infinite loading spinners for cached videos
- Proper state restoration (position, finished status)

### MediaCell Videos
- After closing fullscreen, visible MediaCell videos will explicitly check if they need to restart
- Paused videos that should be playing will be restarted automatically
- Sequential playback will work correctly with VideoManager approval
- No more stuck paused videos in the feed

## Testing Recommendations

1. **Test Fullscreen with Cached Videos:**
   - Play a video in MediaCell until it buffers
   - Open fullscreen - should start playing immediately, no spinner
   - Repeat with multiple videos

2. **Test MediaCell After Fullscreen:**
   - Play a video in MediaCell
   - Open fullscreen, then close immediately (before playback starts)
   - Return to feed - MediaCell video should restart playing
   - Repeat with different videos

3. **Test Sequential Playback:**
   - Let video 1 play in MediaCell
   - Open fullscreen for video 1, close it
   - Scroll to video 2 - should start playing as next in sequence
   - Return to video 1 - should restart from beginning

## Related Files
- `Sources/Core/SingletonVideoManagers.swift` - Fullscreen video management
- `Sources/Features/MediaViews/SimpleVideoPlayer.swift` - MediaCell video playback
- `Sources/Features/MediaViews/MediaBrowserView.swift` - Fullscreen UI and lifecycle

## Architecture Notes

The fix maintains the existing architecture:
- MediaCell uses individual `AVPlayer` instances (one per video)
- Fullscreen uses a singleton `AVPlayer` that creates new `AVPlayerItem` instances from cached assets
- `SharedAssetCache` provides cached assets to avoid re-downloading
- `VideoStateCache` / `PersistentVideoStateManager` handle position restoration
- `VideoManager` coordinates sequential playback in the feed

The key insight is that creating a new `AVPlayerItem` from a cached `AVAsset` requires time for the playerItem to become ready, even though the asset is already loaded. Both video contexts (MediaCell and Fullscreen) now handle this transition properly.

