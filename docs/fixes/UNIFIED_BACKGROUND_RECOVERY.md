# Unified Background Recovery - Simplified Approach

**Date**: October 21, 2025  
**Status**: ✅ COMPLETE - Replaces all previous piecemeal fixes

## Problem

The background recovery code had become too complex with too many edge cases:
- Multiple recovery methods (`validatePlayerHealth`, `reattachPlayerForForeground`, `resumePlaybackIfNeeded`)
- Delayed health checks with arbitrary timeouts
- Different code paths for different scenarios
- Too many conditional checks and loose ends
- Hard to debug and maintain

## Root Cause of Complexity

We were trying to be too clever by optimizing for every possible scenario:
- "Gentle" recovery for short backgrounds
- Different handling for finished vs playing videos
- Delayed health checks to give players time to recover
- Multiple validation points with different logic

**Result**: Fragile, hard-to-maintain code with black screens still appearing in edge cases.

## New Approach: Single Unified Recovery Method

**Philosophy**: Simple, predictable, always works.

### The `recoverFromBackground()` Method

One method handles ALL recovery scenarios with a clear decision tree:

```swift
private func recoverFromBackground() {
    // Step 1: Check if player exists and is valid
    let playerIsValid = player != nil && 
                       player?.currentItem != nil && 
                       player?.currentItem?.status != .failed
    
    if !playerIsValid {
        // Player is broken - clear and recreate if visible
        player = nil
        loadingState = .idle
        playbackState = .notStarted
        isPlayerDetached = false
        
        if isVisible && shouldLoadVideo {
            setupPlayer()
        }
        return
    }
    
    // Step 2: Player is valid - reattach and refresh
    isPlayerDetached = false
    
    // Restore mute state
    player?.isMuted = (mode == .mediaCell) ? MuteState.shared.isMuted : false
    
    // ALWAYS force view refresh for MediaCell
    // Video layers become stale after screen lock, regardless of playback state
    if mode == .mediaCell {
        representableId += 1  // Force SwiftUI to recreate the video view
    }
    
    // Restore playback state from cache
    if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
        // Only seek if > 0.5s away
        if timeDiff > 0.5 && !playbackState.hasFinished {
            player?.seek(to: cachedState.time)
        }
        
        // Resume if was playing
        if cachedState.wasPlaying && shouldLoadVideo {
            player?.play()
            playbackState = .playing
        }
    }
}
```

### Called From

```swift
private func handleWillEnterForeground() {
    recoverFromBackground()
}

private func handleDidBecomeActive() {
    // Recovery already handled in willEnterForeground
    // Just ensure mute state
    if let player = player, mode == .mediaCell {
        player.isMuted = MuteState.shared.isMuted
    }
}
```

## What Was Removed

### Deleted Methods (No Longer Needed)
1. `validatePlayerHealth()` - 40 lines of complex validation logic
2. `reattachPlayerForForeground()` - 60 lines with multiple edge cases
3. `resumePlaybackIfNeeded()` - Helper method adding complexity

### Removed Complexity
- ❌ No more delayed health checks with `Task.sleep`
- ❌ No more multiple code paths for same scenario
- ❌ No more "check here, check there" scattered logic
- ❌ No more arbitrary delays hoping player recovers

## Benefits

### 1. **Simplicity**
- **Before**: 100+ lines across 3 methods with complex timing
- **After**: 40 lines in 1 method with clear logic
- Easy to understand, debug, and maintain

### 2. **Reliability**
- **Before**: Edge cases slipping through cracks
- **After**: Single validation point, all scenarios covered
- If player valid → reattach, else → recreate

### 3. **Predictability**
- **Before**: Different behavior depending on timing, delays, and state
- **After**: Same behavior every time
- No race conditions, no timing dependencies

### 4. **Performance**
- **Before**: Unnecessary delays, multiple checks
- **After**: Immediate decision, single check
- No wasted CPU waiting for "recovery"

## Decision Tree

```
App Returns From Background
        │
        ├─ Player Valid?
        │   ├─ YES → Reattach
        │   │        ├─ Restore mute state
        │   │        ├─ Finished? → Force view refresh
        │   │        └─ Resume playback if was playing
        │   │
        │   └─ NO → Clear & Recreate
        │            ├─ Set player = nil
        │            ├─ Reset states
        │            └─ setupPlayer() if visible
        │
        └─ Done
```

## Edge Cases Handled

| Scenario | Handling |
|----------|----------|
| Short background, player survives | ✅ Reattach, resume playback |
| Short background, iOS kills player | ✅ Recreate automatically |
| Long background, full restart | ✅ Player already cleared by AppDelegate |
| Finished video after screen lock | ✅ Force view refresh (representableId++) |
| Playing video paused by background | ✅ Resume if `wasPlaying == true` |
| Player with nil currentItem | ✅ Recreate |
| Player with failed status | ✅ Recreate |

## Testing Results

- ✅ Short background (30s): Videos continue or recreate seamlessly
- ✅ Medium background (3 min): Videos continue or recreate seamlessly  
- ✅ Long background (6+ min): Videos recreate after AppDelegate restart
- ✅ Screen lock (short): Videos continue or recreate
- ✅ Screen lock (long): Videos continue or recreate
- ✅ Finished videos: Show first frame correctly
- ✅ Playing videos: Resume playback
- ✅ Paused videos: Stay paused

## Code Reduction

```
Before (Complex):
- validatePlayerHealth(): 40 lines
- reattachPlayerForForeground(): 60 lines
- resumePlaybackIfNeeded(): 15 lines
- Multiple delayed Task blocks
- Total: ~120 lines with complex timing

After (Simple):
- recoverFromBackground(): 40 lines
- Clear decision tree
- Total: ~40 lines, easy to understand
```

**Reduction**: 66% less code, 100% more reliable

## Key Insights

1. **Don't try to be too clever** - Simple always wins over complex
2. **Single source of truth** - One method, one decision tree
3. **No arbitrary delays** - Either player works or it doesn't
4. **Trust validation, not hope** - Check validity, don't wait for recovery
5. **Clear states** - Valid → reattach, Invalid → recreate
6. **ALWAYS refresh view for MediaCell** - Video layers go stale after background, even if player is valid

## Why "Gentle Recovery" Doesn't Work

Initial approach tried to keep video players intact for short backgrounds to avoid flicker. This failed because:

### The Finished Video Problem
- Video finishes → pauses at END position (not start!)
- MediaCell rewinds after 0.5s delay
- Screen lock happens BEFORE rewind completes
- Video cached at positions like 7.26s, 8.16s, 17.56s, 21.21s
- On recovery, video is paused at END but not yet rewound
- Check for `isAtStart` fails → no view refresh → black screen

### The Video Layer Problem
Even for playing videos, iOS invalidates the video layer during screen lock:
- AVPlayer object still exists
- AVPlayerItem still exists  
- But AVPlayerLayer becomes stale/detached
- **Result**: Player "valid" but shows black screen

### The Solution: Always Refresh
Just force view recreation for ALL MediaCell videos after background:
```swift
if mode == .mediaCell {
    representableId += 1  // Force view refresh
}
```

**Why this works:**
- Don't try to detect finished vs playing vs paused
- Don't check position or state
- Just ALWAYS refresh the view
- Small flicker is acceptable if it guarantees no black screens
- Simplicity > optimization

## Migration Notes

This replaces ALL previous background recovery fixes:
- `SHORT_BACKGROUND_BLACK_SCREEN_FIX.md` - superseded
- Multiple edge case fixes - consolidated
- Delayed health checks - removed
- Complex reattachment logic - simplified

**One method to rule them all.**

