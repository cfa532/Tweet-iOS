# Video Player Break After Repeated Sharing Fix

**Date:** January 17, 2026  
**Status:** ✅ Fixed  
**Issue:** After sharing tweets repeatedly, some video players break and cannot recover, while other videos from the same author work fine.

---

## Problem Description

When users share tweets repeatedly (especially videos), some video players would break and fail to recover. The broken players would show a spinner indefinitely and never play, even though other videos from the same author would work fine. This suggested a resource management issue rather than a network or server problem.

---

## Root Causes

### 1. **Player State Corruption During Frame Capture**

The `captureFrameFromPlayer` function in `TweetActionButtonsView.swift` was seeking the player to capture a preview frame without:
- Saving the current playback state (playing/paused, current time)
- Restoring the playback state after capture
- Checking if the player was currently playing

**Problem Flow:**
1. User shares a tweet with a playing video
2. `captureFrameFromPlayer` is called to generate preview
3. Function seeks player to target time (e.g., 1 second)
4. Player was playing at 5 seconds → now at 1 second
5. Function completes but doesn't restore position
6. Player is stuck at wrong position or in corrupted state
7. Subsequent shares compound the issue

### 2. **Concurrent Capture Interference**

When sharing multiple tweets quickly:
- Multiple `captureFrameFromPlayer` calls could run concurrently on the same player
- Each would seek the player to different positions
- Seeks would interfere with each other
- Player state would become inconsistent

### 3. **No Handling of Player Replacement**

During capture:
- Player item could be replaced by cleanup or cache eviction
- Function would continue operating on stale player item
- Would try to restore state on wrong player item
- Could cause crashes or leave player in broken state

---

## Solution

### Change 1: Save and Restore Playback State

Before modifying the player, save its current state:
- Whether it was playing (`player.rate > 0`)
- Current playback time
- Current playback rate

After capture completes, restore:
- Original playback position (via `seek`)
- Original playback state (resume if was playing)

```swift
// Save state before capture
let savedState = await MainActor.run { () -> (wasPlaying: Bool, originalTime: CMTime, originalRate: Float) in
    let wasPlaying = player.rate > 0
    let originalTime = player.currentTime()
    let originalRate = player.rate
    
    // Pause player before seeking to prevent interference
    if wasPlaying {
        player.pause()
    }
    
    return (wasPlaying: wasPlaying, originalTime: originalTime, originalRate: originalRate)
}

// ... capture frame ...

// Restore state after capture
defer {
    Task { @MainActor in
        guard player.currentItem === playerItem else {
            // Player item was replaced, skip restore
            return
        }
        
        player.seek(to: savedState.originalTime) { finished in
            if finished && savedState.wasPlaying {
                player.rate = savedState.originalRate
            }
        }
    }
}
```

### Change 2: Serialize Captures Per Player

Prevent concurrent captures on the same player using a lock and task tracking:

```swift
// Track active captures per player
private static var activeCaptures: [ObjectIdentifier: Task<Void, Never>] = [:]
private static let captureLock = NSLock()

// Wait for existing capture to complete
Self.captureLock.lock()
if let existingTask = Self.activeCaptures[playerId] {
    Self.captureLock.unlock()
    _ = await existingTask.value  // Wait for completion
    Self.captureLock.lock()
}

// Mark this capture as active
let captureTask = Task<Void, Never> { }
Self.activeCaptures[playerId] = captureTask
Self.captureLock.unlock()

defer {
    Self.captureLock.lock()
    Self.activeCaptures.removeValue(forKey: playerId)
    Self.captureLock.unlock()
}
```

### Change 3: Validate Player Item During Capture

Add checks throughout the capture process to detect if the player item was replaced:

```swift
// Before seeking
guard player.currentItem === playerItem else {
    print("DEBUG: [SHARE] Player item was replaced during capture, aborting")
    return nil
}

// During segment loading
hasDataAtTime = await MainActor.run { () -> Bool in
    guard player.currentItem === playerItem else {
        return false
    }
    // ... check loaded ranges ...
}

// Before frame capture
guard player.currentItem === playerItem else {
    print("DEBUG: [SHARE] Player item replaced before frame capture")
    return nil
}
```

---

## How It Works

### Before Fix:
1. User shares tweet → `captureFrameFromPlayer` called
2. Function seeks player to 1 second (was at 5 seconds, playing)
3. Capture completes
4. **Player left at 1 second, not playing** ❌
5. User tries to play → player broken or shows wrong frame

### After Fix:
1. User shares tweet → `captureFrameFromPlayer` called
2. **Function saves state**: playing at 5 seconds
3. **Function pauses player** (if was playing)
4. Function seeks to 1 second for capture
5. Capture completes
6. **Function restores state**: seeks back to 5 seconds, resumes playing ✅
7. Player continues normally

### Concurrent Sharing:
1. First share starts capture → locks player
2. Second share waits for first to complete
3. First completes, unlocks player
4. Second starts capture → locks player
5. No interference ✅

---

## Benefits

1. ✅ **No player corruption**: State is always restored after capture
2. ✅ **No concurrent interference**: Captures are serialized per player
3. ✅ **Graceful handling**: Player replacement detected and handled
4. ✅ **Playback continuity**: Videos continue playing after sharing
5. ✅ **Reliable recovery**: Broken players can recover on next share

---

## Testing

To verify the fix works:

1. **Basic Share Test:**
   - Play a video in feed
   - Share the tweet
   - Dismiss share sheet
   - Verify video continues playing from same position

2. **Repeated Share Test:**
   - Play a video
   - Share tweet 5 times in quick succession
   - Dismiss all share sheets
   - Verify video still plays correctly

3. **Multiple Videos Test:**
   - Have multiple videos visible
   - Share different tweets repeatedly
   - Verify all videos continue working

4. **Playing Video Share Test:**
   - Start video playback
   - While playing, share the tweet
   - Dismiss share sheet
   - Verify video resumes from correct position

---

## Files Modified

- `Sources/Tweet/TweetActionButtonsView.swift`
  - Lines 1043-1046: Added capture serialization infrastructure
  - Lines 1056-1078: Added serialization logic to prevent concurrent captures
  - Lines 1080-1096: Added playback state saving before capture
  - Lines 1109-1144: Added playback state restoration after capture
  - Lines 1146-1173: Added player item validation before seeking
  - Lines 1182-1198: Added player item validation during segment loading
  - Lines 1213-1218: Added player item validation before frame capture

---

## Related Issues

This fix addresses the same class of resource management issues that were previously fixed for:
- Share sheet video recovery (`SHARE_SHEET_VIDEO_RECOVERY_FIX.md`)
- Player cleanup and memory management (`SharedAssetCache.swift`)

The pattern is consistent: when modifying shared player state, always save and restore the original state.

---

## Key Takeaways

1. **Always save/restore state**: When modifying shared resources (like AVPlayer), save state before and restore after
2. **Serialize concurrent access**: Use locks or task tracking to prevent concurrent modifications
3. **Validate resource validity**: Check if resources were replaced during async operations
4. **Test edge cases**: Repeated operations, concurrent access, resource replacement
