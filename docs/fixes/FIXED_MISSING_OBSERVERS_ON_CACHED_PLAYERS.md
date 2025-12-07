# Fixed Missing Observers on Cached Players (December 7, 2025)

> **⚠️ DEPRECATED**: This document has been consolidated into `SEQUENTIAL_VIDEO_PLAYBACK_COMPLETE.md`.  
> Please refer to that document for the most up-to-date information.

**Problem**: Sequential video playback worked on the first round but failed on the second round. The second video never played after the first video finished.

## Root Cause

When players are **reused from cache**, the `restoreFromCache()` function was not setting up video completion observers. This meant:

1. **First round** (new player):
   - Player created → `configurePlayer()` called → observers set up ✅
   - First video finishes → `handleVideoFinished()` called → advances to second video ✅
   
2. **Second round** (cached player):
   - Player restored from cache → `restoreFromCache()` called → **NO observers set up** ❌
   - First video finishes → **NO callback fired** → second video never plays ❌

## Evidence from Logs

### First Round (Works)
```
✅ [OBSERVER SETUP] videoCompletionObserver attached for QmQ1VjquznaDE2bnAAJcWMPuxpDd3AHaZ2iRHjxz3U3w7c
🎬 [VIDEO FINISHED] Video finished playing for ...
🎬 [VIDEO FINISHED] Calling onVideoFinished callback
DEBUG: [VideoManager] Video finished, moved to next video: 1
```

### Second Round (Fails)
```
DEBUG: [VIDEO CACHE] ✅ Found shared player for QmQ1VjquznaDE2bnAAJcWMPuxpDd3AHaZ2iRHjxz3U3w7c
❌ No [OBSERVER SETUP] logs
❌ No [VIDEO FINISHED] logs
❌ Index stays at 0, second video never plays
```

## The Bug

### Before (SimpleVideoPlayer.swift - restoreFromCache)

```swift
private func restoreFromCache(_ cachedState: ...) {
    // ... validation code ...
    
    let playerChanged = self.player !== cachedState.player
    
    // ❌ Just assign the player - NO observer setup!
    self.player = cachedState.player
    
    if playerChanged && mode == .mediaCell {
        self.representableId += 1
    }
    
    // ... rest of function ...
}
```

The observer was **only** set up in `configurePlayer()`, which is called when creating a **new** player from `SharedAssetCache`, but NOT when restoring from `VideoStateCache`.

## The Fix

### After (SimpleVideoPlayer.swift - restoreFromCache)

```swift
private func restoreFromCache(_ cachedState: ...) {
    // ... validation code ...
    
    let playerChanged = self.player !== cachedState.player
    
    // ✅ CRITICAL: Always set up observers for cached player
    // This is essential for sequential video playback - without observers, onVideoFinished never fires!
    NSLog("DEBUG: [VIDEO CACHE] Setting up observers for cached player: \(mid)")
    removePlayerObservers()
    setupPlayerObservers(cachedState.player)
    
    // ✅ Verify observer was set up successfully (handle race conditions)
    if mode == .mediaCell && videoCompletionObserver == nil && cachedState.player.currentItem != nil {
        NSLog("⚠️ [VIDEO CACHE] videoCompletionObserver is nil after setupPlayerObservers for \(mid) - retrying")
        setupPlayerObservers(cachedState.player)
    }
    
    // Restore the cached player (AFTER setting mute state and observers)
    self.player = cachedState.player
    
    if playerChanged && mode == .mediaCell {
        self.representableId += 1
    }
    
    // ... rest of function ...
}
```

## How It Works Now

### Code Flow

1. **MediaGrid appears** with 2 videos
   ```
   videoManager.setupSequentialPlayback(for: [V1, V2], tweetId: "...")
   currentVideoIndex = 0
   ```

2. **First video becomes visible**
   ```swift
   SimpleVideoPlayer.handleVisibilityChange()
   → setupPlayer()
   → Check VideoStateCache
   → Found cached player!
   → restoreFromCache(cachedState)
   → ✅ removePlayerObservers()
   → ✅ setupPlayerObservers(cachedState.player)  // NEW!
   → self.player = cachedState.player
   ```

3. **First video plays to completion**
   ```swift
   AVPlayerItemDidPlayToEndTime notification
   → videoCompletionObserver callback fires  // Now works!
   → handleVideoFinished()
   → onVideoFinished()  // Callback set by MediaCell
   → MediaGridView.onVideoFinished()
   → videoManager.onVideoFinished(tweetId: ...)
   → currentVideoIndex = 1  // Advance to second video
   ```

4. **Second video auto-plays**
   ```swift
   VideoManager.currentVideoIndex changed from 0 → 1
   → SwiftUI re-evaluates MediaCell views
   → videoManager.shouldPlayVideo(for: V2) returns true
   → Second video's autoPlay changes to true
   → Video plays automatically
   ```

## Why This Was Missed Before

The player caching system has **two levels**:

1. **SharedAssetCache** - Caches the `AVPlayer` instance itself (used when creating new players)
2. **VideoStateCache** - Caches player + playback state (used when restoring previously visible videos)

The bug was in the **VideoStateCache** restoration path. When a video scrolls away and back:
- It uses `VideoStateCache.getCachedState()` to get the player
- Calls `restoreFromCache()` directly (bypasses `configurePlayer()`)
- ❌ Observers were never set up

When creating a brand new player:
- Uses `SharedAssetCache.getOrCreatePlayer()` 
- Calls `configurePlayer()` which sets up observers
- ✅ Works correctly

## Testing Checklist

### Single Video
- [x] First appearance: Plays correctly
- [x] Scroll away and back: Resumes from saved position
- [x] Video finishes: Can replay on next appearance

### Multiple Videos (Sequential Playback)
- [x] **First round**: Video 1 plays → finishes → Video 2 plays automatically
- [x] **Second round**: Scroll away and back → Video 1 plays → finishes → Video 2 plays automatically
- [x] **Third round**: Same behavior as second round
- [x] **After all finish**: Next appearance restarts from Video 1
- [x] **No black screens** when scrolling back

### Logs to Verify
Look for these logs in second+ rounds:
```
✅ [VIDEO CACHE] Setting up observers for cached player: ...
✅ [OBSERVER SETUP] videoCompletionObserver attached for ...
🎬 [VIDEO FINISHED] Video finished playing for ...
🎬 [VIDEO FINISHED] Calling onVideoFinished callback
DEBUG: [VideoManager] Video finished, moved to next video: 1
```

## Benefits

✅ **Sequential playback works consistently** - Not just on first appearance  
✅ **Observers always attached** - Whether player is new or cached  
✅ **Better error handling** - Retry logic if observer setup fails  
✅ **Comprehensive logging** - Easy to debug future issues  
✅ **No performance impact** - Observer setup is lightweight  

## Related Files

- `Sources/Features/MediaViews/SimpleVideoPlayer.swift` - Main fix in `restoreFromCache()`
- `Sources/Features/MediaViews/MediaGridView.swift` - Sequential playback orchestration
- `Sources/Utils/VideoManager.swift` - Manages sequential video state
- `Sources/Utils/VideoStateCache.swift` - Caches player state for reuse

## Architecture Note

This highlights the importance of **explicit lifecycle management** when caching stateful objects like `AVPlayer`. When restoring from cache, we must:

1. ✅ Re-establish all observers
2. ✅ Verify state is correct
3. ✅ Handle race conditions (player item may not be ready yet)
4. ✅ Log for debugging

Simply assigning a cached object is not enough - we must restore its **full operational state**, not just the object reference.
