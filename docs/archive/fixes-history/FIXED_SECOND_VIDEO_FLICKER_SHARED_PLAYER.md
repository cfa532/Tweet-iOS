# Fixed: Second Video Flicker and Instant Completion in Sequential Playback

## Problem

When playing videos sequentially in a MediaGrid:
- The first video played normally
- The second video would **flicker black** and appear to reload before playing
- Sometimes the second video would finish **instantly** without actually playing
- Logs showed the video was at `time=0.00s` but `AVPlayerItemDidPlayToEndTime` fired immediately

## Root Cause

**Shared AVPlayer Instances + Automatic Rewind = State Corruption**

The codebase uses `SharedAssetCache` to reuse `AVPlayer` instances across multiple `SimpleVideoPlayer` views for performance. When videos in sequential playback finished, this code ran:

```swift
// OLD CODE (Line 2532-2535)
if mode == .mediaCell {
    if playbackState == .finished {
        NSLog("🔄 [VIDEO RESET] Resetting prematurely finished video to start: \(mid)")
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)  // ← BUG!
        playbackState = .notStarted
    }
}
```

### What Was Happening

1. Video 1 (`QmQ1Vjquzna...`) plays and finishes
2. `VideoManager` advances `currentVideoIndex` to 1 (Video 2)
3. Video 1's `autoPlay` changes to `false` (no longer active)
4. `checkPlaybackConditions(autoPlay: false)` runs for Video 1
5. Detects `playbackState == .finished` → **Calls `player?.seek(to: .zero)`**
6. **BUT Video 1's player is the SAME instance as Video 2's player!** (via `SharedAssetCache`)
7. Seeking to `.zero` corrupts Video 2's AVPlayerItem internal state
8. Video 2 becomes approved and calls `player?.play()`
9. AVFoundation fires `AVPlayerItemDidPlayToEndTime` instantly because internal state is broken

### Why Shared Players Were Affected

```
Video 1 View → AVPlayer (0x12345) → AVPlayerItem A (finished)
Video 2 View → AVPlayer (0x12345) → AVPlayerItem B (same player, different item)

When Video 1 seeked to .zero:
- AVPlayer's internal state got confused
- AVPlayerItem B thought it was "done" even though it was at 0.00s
- Calling play() immediately triggered completion notification
```

## Solution

**Stop automatically rewinding finished videos when `autoPlay` becomes false.**

Each `SimpleVideoPlayer` should manage its own playback state independently. When a video actually needs to play, it will handle seeking to start as part of its normal playback flow.

### Changes Made

#### 1. Removed Automatic Rewind on autoPlay=false

**File:** `Sources/Features/MediaViews/SimpleVideoPlayer.swift`

```swift
// Line ~2529 (NEW CODE)
if mode == .mediaCell {
    // Don't reset finished videos here - they may have legitimately played to completion
    // The AVPlayer instance might be shared between multiple SimpleVideoPlayer views
    // Resetting one video could corrupt the state of another video using the same player
    // Let each video manage its own state when it becomes active
}
```

**Removed:**
```swift
if playbackState == .finished {
    NSLog("🔄 [VIDEO RESET] Resetting prematurely finished video to start: \(mid)")
    player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    playbackState = .notStarted
}
```

#### 2. Added Proactive Seek for Clean Start

**File:** `Sources/Features/MediaViews/SimpleVideoPlayer.swift` (Line ~2461)

When a video becomes approved for playback and hasn't played yet (`playbackState == .notStarted`), seek to `.zero` to ensure clean state:

```swift
// CRITICAL: For mediaCell mode, if video was never actually played (only first frame shown),
// seek to start to ensure clean state before playing
if mode == .mediaCell && playbackState == .notStarted {
    NSLog("🔄 [PLAYBACK] Seeking to start for clean playback: \(mid)")
    player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    // Brief delay to let seek complete
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        if self.player?.rate == 0 {
            NSLog("▶️ [PLAYBACK] Starting playback after seek: \(self.mid)")
            self.player?.play()
            self.playbackState = .playing
        }
    }
    return
}
```

This ensures that when Video 2 becomes active, it seeks to `.zero` on **its own terms**, not as a side effect of Video 1's state change.

## Verification

### Before Fix

```
🎬 [VIDEO FINISHED] Video finished: QmQ1Vjquzna... (Video 1)
DEBUG: [VideoManager] Video finished, moved to next video: 1
DEBUG: [VIDEO AUTOPLAY CHANGE] MediaCell autoPlay changed to false for QmQ1Vjquzna...
🔄 [VIDEO RESET] Resetting prematurely finished video to start: QmQ1Vjquzna...  ← CORRUPTS SHARED PLAYER
DEBUG: [VIDEO AUTOPLAY CHANGE] MediaCell autoPlay changed to true for QmaEC37DGF...
🔍 [PLAYBACK CHECK] Video QmaEC37DGF...: time=0.00s/4.44s, atEnd=false
🎬 [VIDEO FINISHED] Video finished: QmaEC37DGF...  ← INSTANT FINISH (no actual playback)
```

### After Fix

```
🎬 [VIDEO FINISHED] Video finished: QmQ1Vjquzna... (Video 1)
DEBUG: [VideoManager] Video finished, moved to next video: 1
DEBUG: [VIDEO AUTOPLAY CHANGE] MediaCell autoPlay changed to false for QmQ1Vjquzna...
(No automatic rewind - Video 1 just stops)
DEBUG: [VIDEO AUTOPLAY CHANGE] MediaCell autoPlay changed to true for QmaEC37DGF...
🔄 [PLAYBACK] Seeking to start for clean playback: QmaEC37DGF...  ← Video 2 manages its own state
▶️ [PLAYBACK] Starting playback after seek: QmaEC37DGF...
(Video 2 plays normally to completion)
```

## Impact

✅ **Fixed:** Black flicker between sequential videos  
✅ **Fixed:** Second video appearing to reload before playing  
✅ **Fixed:** Videos instantly finishing without playing  
✅ **Improved:** Cleaner separation of concerns - each video manages its own lifecycle  
✅ **Preserved:** Shared player caching for performance (just safer now)

## Related Files

- `Sources/Features/MediaViews/SimpleVideoPlayer.swift` - Main fix location
- `Sources/Utils/VideoManager.swift` - Sequential playback coordinator (unchanged)
- `Sources/Features/MediaViews/MediaGridView.swift` - Orchestrates sequential playback (unchanged)
- `Sources/Core/SharedAssetCache.swift` - Player caching mechanism (unchanged)

## Key Lesson

**When using shared resources (like AVPlayer instances), be extremely careful about side effects.**

Operations on one view's state should not automatically modify shared resources in ways that affect other views. Each view should:
1. Request control of the shared resource
2. Configure it for its own needs
3. Release control cleanly
4. Never assume exclusive ownership

## Date

December 7, 2025
