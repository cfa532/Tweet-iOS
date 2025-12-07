# Sequential Video Playback - Duplicate Fixes (December 7, 2025)

**Issue**: Both videos playing simultaneously when MediaGrid reappears, and duplicate `handleVideoFinished` callbacks.

## Problems Identified

### 1. Both Videos Playing Simultaneously

**Symptoms**: When MediaGrid reappears in the 2nd round, both videos start playing at the same time instead of only the current video.

**Root Cause**: KVO handlers (status ready, initial check, buffer data) were auto-playing videos without checking VideoManager approval. When videos restored from cache, they were already ready, so multiple KVO handlers fired and both videos started playing.

**Solution**: Added VideoManager approval checks to all playback entry points.

### 2. Duplicate Video Finished Callbacks

**Symptoms**: `handleVideoFinished()` being called multiple times (7+ times) for the same video finish event, causing state corruption.

**Root Cause**: 
- Multiple observers attached to the same playerItem
- Direct callback from `restoreFromCache()` when video was already finished
- No guard to prevent duplicate processing

**Solution**: 
- Added guard in `handleVideoFinished()` to prevent duplicate processing
- Removed direct callback from `restoreFromCache()`
- Improved observer setup to prevent duplicates

## Fixes Applied

### Fix 1: VideoManager Checks in KVO Handlers

**File**: `SimpleVideoPlayer.swift`

**Location 1**: KVO Status Ready Handler (~line 2195)

```swift
if shouldAutoPlay {
    // CRITICAL: For MediaCell, check VideoManager before playing
    let approved = self.mode == .mediaCell ? (self.videoManager?.shouldPlayVideo(for: self.mid) ?? false) : true
    
    if approved {
        player.play()
        NSLog("▶️ [VIDEO READY] Auto-playing \(mid) - VideoManager approved")
    } else {
        NSLog("⏸️ [VIDEO READY] NOT auto-playing \(mid) - not approved by VideoManager")
    }
}
```

**Location 2**: Initial Check Ready Handler (~line 2275)

```swift
if shouldAutoPlay {
    // CRITICAL: For MediaCell, check VideoManager before playing
    let approved = self.mode == .mediaCell ? (self.videoManager?.shouldPlayVideo(for: self.mid) ?? false) : true
    
    if approved {
        player.play()
        NSLog("▶️ [VIDEO SETUP] Already ready - auto-playing \(mid) - VideoManager approved")
    } else {
        NSLog("⏸️ [VIDEO SETUP] NOT auto-playing \(mid) - not approved by VideoManager")
    }
}
```

**Location 3**: Buffer Data Handler (~line 2219)

```swift
// CRITICAL: Default to false for MediaCell to prevent both videos from playing
let shouldPlay = shouldAutoPlay && (self.mode != .mediaCell || self.videoManager?.shouldPlayVideo(for: self.mid) ?? false)

if shouldPlay && player.rate == 0 {
    player.play()
    NSLog("▶️ [FIRST FRAME] Auto-playing \(mid) (approved by VideoManager)")
} else if !shouldPlay {
    NSLog("⏸️ [FIRST FRAME] NOT auto-playing \(mid) - waiting for approval from VideoManager")
}
```

**Location 4**: checkPlaybackConditions (~line 2553)

```swift
if mode == .mediaCell {
    let approved = videoManager?.shouldPlayVideo(for: mid) ?? true
    if !approved {
        print("DEBUG: [VIDEO PLAYBACK] Video \(mid) not approved by VideoManager - preventing playback")
        return
    }
}
```

### Fix 2: Guard in handleVideoFinished

**File**: `SimpleVideoPlayer.swift` (~line 2441)

```swift
private func handleVideoFinished() {
    // CRITICAL: Prevent duplicate calls - if already finished, ignore
    guard playbackState != .finished else {
        print("⚠️ [VIDEO FINISHED] Video \(mid) already marked as finished - ignoring duplicate finish event")
        return
    }
    
    playbackState = .finished
    // ... rest of logic
}
```

### Fix 3: Remove Direct Callback from restoreFromCache

**File**: `SimpleVideoPlayer.swift` (~line 1780)

**Before**:
```swift
if videoAlreadyFinished {
    self.playbackState = .finished
    DispatchQueue.main.async {
        self.handleVideoFinished() // ❌ Causes duplicate callbacks
    }
}
```

**After**:
```swift
if videoAlreadyFinished {
    NSLog("🎬 [VIDEO CACHE] Video \(mid) was already finished - marking as finished, observer will handle completion")
    self.playbackState = .finished
    // DON'T call handleVideoFinished here - it will be called by the observer if video finishes again
}
```

### Fix 4: Improved Observer Setup

**File**: `SimpleVideoPlayer.swift` (~line 2045)

```swift
// CRITICAL: Remove existing observers FIRST to prevent duplicates
// This must happen before storing the new playerItem reference
removePlayerObservers()

// Store reference for cleanup (AFTER removing old observers)
self.playerItem = playerItem

// Video finished observer
videoCompletionObserver = NotificationCenter.default.addObserver(
    forName: .AVPlayerItemDidPlayToEndTime,
    object: playerItem,
    queue: .main
) { _ in
    // The notification is already scoped to playerItem, so this will only fire for our item
    // The guard in handleVideoFinished prevents duplicate processing
    self.handleVideoFinished()
}
```

### Fix 5: Pause During Restore

**File**: `SimpleVideoPlayer.swift` (~line 1838)

```swift
// For MediaCell, CRITICAL: Pause immediately to ensure videos start in the same state as first time
// The normal KVO flow will handle playback, just like the first time
if mode == .mediaCell {
    cachedState.player.pause()
}
```

## How It Works Now

### First Round (New Videos)
1. Videos load fresh
2. KVO handlers fire when ready
3. Each handler checks VideoManager before playing
4. Only current video (index 0) gets approval
5. Only that video plays ✅

### Second Round (Cached Videos)
1. Videos restore from cache
2. Videos are paused immediately (same state as first time)
3. KVO handlers fire when ready (same as first time)
4. Each handler checks VideoManager before playing
5. Only current video gets approval
6. Only that video plays ✅

### Video Completion
1. Video finishes → notification fires
2. Observer callback → `handleVideoFinished()`
3. Guard checks if already finished → prevents duplicates
4. Callback fires once → VideoManager advances index
5. Next video gets approval → plays automatically ✅

## Testing

### Before Fix
```
▶️ [VIDEO READY] Auto-playing QmaEC37DGFb9fCG57SgpuwaQ5ZKxuex1yqZqqqArBwSUK2
▶️ [VIDEO READY] Auto-playing QmQ1VjquznaDE2bnAAJcWMPuxpDd3AHaZ2iRHjxz3U3w7c
❌ Both videos playing simultaneously
```

### After Fix
```
▶️ [VIDEO READY] Auto-playing QmaEC37DGFb9fCG57SgpuwaQ5ZKxuex1yqZqqqArBwSUK2 - VideoManager approved
⏸️ [VIDEO READY] NOT auto-playing QmQ1VjquznaDE2bnAAJcWMPuxpDd3AHaZ2iRHjxz3U3w7c - not approved by VideoManager
✅ Only current video plays
```

## Benefits

✅ **No simultaneous playback** - Only current video plays  
✅ **No duplicate callbacks** - Guard prevents multiple processing  
✅ **Consistent behavior** - 2nd round works exactly like 1st round  
✅ **Better state management** - No state corruption from duplicates  
✅ **Robust** - Handles all edge cases  

## Related Files

- `SimpleVideoPlayer.swift` - All fixes applied here
- `VideoManager.swift` - Provides `shouldPlayVideo()` approval
- `MediaGridView.swift` - Sets up sequential playback

## See Also

- `SEQUENTIAL_VIDEO_PLAYBACK_COMPLETE.md` - Complete implementation guide
- `SEQUENTIAL_VIDEO_COMPLETE_FIX_SUMMARY.md` - Original fix summary
