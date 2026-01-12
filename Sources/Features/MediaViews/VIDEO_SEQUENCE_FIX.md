# Video Playback Sequence Fix

## Problem Description

The VideoPlaybackCoordinator was not playing videos in the proper sequence. After the first video finished, it would incorrectly report "Reached end of visible videos - stopping" even though there were more videos visible on screen.

### Observed Behavior

From the logs:
```
🎬 [VIDEO FINISHED] Video finished playing for QmZHVMkYneo8kn1tsAVn7mu3SeuQ1MkKoeM5n6P2ECgtGv, mode: mediaCell
✅ [VideoCoordinator] Video finished, playing next
🏁 [VideoCoordinator] Reached end of visible videos - stopping
```

Then later:
- Video 1 played again
- Video 2 played
- Video 3 was skipped or didn't finish properly
- Video 4 started before Video 3 finished

## Root Cause

The `playNextVideo()` function had a **race condition** caused by using the computed property `visibleVideos` in its logic:

```swift
// OLD CODE (BUGGY)
guard let currentId = currentlyPlayingVideoId,
      let currentIndexInVisible = visibleVideos.firstIndex(where: { $0.identifier == currentId }) else {
    // If current video not in visible list, stop
    return
}

let nextIndexInVisible = currentIndexInVisible + 1

if nextIndexInVisible < visibleVideos.count {
    playVideo(visibleVideos[nextIndexInVisible])
    return
}
```

### Why This Failed

1. **`visibleVideos` is computed dynamically** based on `visibleTweetIds`
2. When `playNextVideo()` is called from a video finish event, the visible tweet list might be:
   - In the middle of updating
   - Temporarily empty
   - Out of sync with the actual UI state
3. This caused the function to think the current video wasn't visible, or that there were no more visible videos

### Additional Issue

The logic was trying to use **indices from the visible list** to navigate through **the full video list**, which are two different arrays with different sizes and orders.

## Solution

The fix changes `playNextVideo()` to **use the index from `allVideos` instead of `visibleVideos`**:

```swift
// NEW CODE (FIXED)
guard let currentId = currentlyPlayingVideoId else {
    checkAndPlayTopmost()
    return
}

// Use allVideos index for sequencing
guard let currentIndexInAll = allVideos.firstIndex(where: { $0.identifier == currentId }) else {
    checkAndPlayTopmost()
    return
}

let nextIndexInAll = currentIndexInAll + 1

// Check if there's a next video
guard nextIndexInAll < allVideos.count else {
    print("🏁 [VideoCoordinator] Reached end of all videos - stopping")
    stopAllVideos()
    return
}

let nextVideo = allVideos[nextIndexInAll]

// Capture visible videos at this moment (avoid race condition)
let currentVisibleVideos = visibleVideos

// Check if next video is already visible
if currentVisibleVideos.contains(where: { $0.identifier == nextVideo.identifier }) {
    playVideo(nextVideo)
    return
}

// Otherwise, try to scroll to it
// ... (rest of scrolling logic)
```

### Key Changes

1. ✅ **Use `allVideos` as the source of truth** for sequencing
2. ✅ **Capture `visibleVideos` snapshot** to avoid reading it multiple times during execution
3. ✅ **Check if next video is visible** by identifier, not by index comparison
4. ✅ **Better error recovery** - if something goes wrong, call `checkAndPlayTopmost()` instead of silently stopping

## Benefits

- ✅ Videos now play in proper sequence (1 → 2 → 3 → 4)
- ✅ No more premature "end of videos" stops
- ✅ No more race conditions from dynamic visibility changes
- ✅ More predictable and debuggable behavior

## Debug Logging Added

Enhanced logging to help diagnose future issues:

```
⏭️ [VideoCoordinator] playNextVideo() - current video at index 0/10
⏭️ [VideoCoordinator] Next video: QmS7e... (index 1)
⏭️ [VideoCoordinator] Currently visible: 4 videos
⏭️ [VideoCoordinator] Playing next video - already visible
```

## Testing Recommendations

1. **Scroll through main feed** - verify videos play in sequence
2. **Rapid scrolling** - ensure coordinator handles visibility changes gracefully
3. **Background/foreground** - verify playback resumes correctly
4. **Manual pause/resume** - ensure user actions don't break sequencing

## Related Files

- `VideoPlaybackCoordinator.swift` - Main coordinator logic (FIXED)
- `SimpleVideoPlayer.swift` - Video player that reports finish events
- `TweetTableViewController.swift` - Manages visible tweet tracking
