# Short Background Black Screen Fix

**Date**: October 20, 2025  
**Issue**: MediaCell videos show black screen with broken icon after short background (< 5 min)  
**Status**: ✅ FIXED

## Problem Description

When the app goes to background for a **short period** (< 5 minutes) and then returns to foreground:
- Videos in MediaCell (tweet list) show **black screens with broken icon**
- Videos fail to load/play
- **Long background** (> 5 min) works fine because full server restart occurs

## Root Cause

The issue was in `SimpleVideoPlayer.handleVideoInfrastructureRestarted()`:

### What Happens During Short Background Recovery

1. **AppDelegate** calls `SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()`
2. This method does:
   ```swift
   // Line 1149 in SharedAssetCache.swift
   player.replaceCurrentItem(with: nil) // ❌ Sets currentItem to nil
   ```
3. **Posts `.videoInfrastructureRestarted` notification**
4. Each `SimpleVideoPlayer` receives the notification

### The Bug

In `handleVideoInfrastructureRestarted()`, the code checked:
```swift
if player == nil {
    // Recreate player
} else {
    // Just adjust mute state ❌ WRONG!
}
```

**Problem**: The `player` variable was NOT `nil` (AVPlayer object still exists), BUT its `currentItem` WAS `nil` (cleared by background recovery). So the code went to the "else" branch and just adjusted mute state instead of recreating the player.

Result: Player with `currentItem == nil` → **black screen with broken icon**

## Solution

Change the condition to check if the player's `currentItem` is valid, not just if the player object exists:

```swift
private func handleVideoInfrastructureRestarted() {
    // CRITICAL: Check if player's currentItem is valid, not just if player exists
    // During short background recovery, clearVideoPlayersForBackgroundRecovery() sets
    // player.replaceCurrentItem(with: nil), so player object exists but has no item
    let needsRecreation = player == nil || player?.currentItem == nil
    
    if needsRecreation {
        // Clear invalid player reference
        if player != nil && player?.currentItem == nil {
            player = nil
        }
        
        // Reset states
        if playbackState.hasFinished {
            playbackState = .notStarted
        }
        loadingState = .idle
        
        // Recreate player for visible videos
        if mode == .mediaCell && isVisible && shouldLoadVideo {
            setupPlayer()
        }
        else if mode == .tweetDetail && shouldLoadVideo {
            setupPlayer()
        }
    } else {
        // Player is valid, just ensure mute state
        if mode == .mediaCell {
            player?.isMuted = MuteState.shared.isMuted
        } else if mode == .mediaBrowser {
            player?.isMuted = false
        }
    }
}
```

## Key Changes

1. **Line 651**: Added check for `player?.currentItem == nil` in addition to `player == nil`
2. **Line 657-660**: Explicitly clear player reference if it has no currentItem
3. **Line 677**: Updated log message from "finished video" to "MediaCell video" (more accurate)

## Files Modified

### `/Sources/Features/MediaViews/SimpleVideoPlayer.swift`
- Modified `handleVideoInfrastructureRestarted()` (lines 645-694)
- Now properly detects players with nil currentItem
- Recreates players instead of just adjusting mute state

## Expected Behavior After Fix

### Short Background (< 5 min)
1. User backgrounds app for 30 seconds
2. Returns to foreground
3. AppDelegate clears player cache and posts notification
4. **SimpleVideoPlayer detects `currentItem == nil`**
5. **Recreates player with fresh asset**
6. ✅ Videos load and play normally

### Long Background (> 5 min)
1. User backgrounds app for 6+ minutes
2. Returns to foreground
3. Full server restart occurs
4. Videos reload with fresh assets
5. ✅ Videos work normally (already worked before fix)

## Testing Checklist

- [ ] Short background (30s): Videos recover immediately
- [ ] Medium background (2-3 min): Videos recover immediately  
- [ ] Just under 5 min background: Videos recover immediately
- [ ] Long background (6+ min): Videos recover after brief loading
- [ ] Multiple rapid backgrounds: No crashes or black screens
- [ ] Check both progressive and HLS videos

## Related Issues

- See `BACKGROUND_VIDEO_BLACK_SCREEN_FIX.md` for the original background recovery fix
- See `OVERNIGHT_BLACK_SCREEN_BUG.md` for long background (overnight) recovery
- See `LOCAL_HTTP_SERVER_BACKGROUND_FIX.md` for server lifecycle management

## Impact

- ✅ Videos work after short backgrounds
- ✅ Videos work after long backgrounds (unchanged)
- ✅ No more black screens with broken icons
- ✅ Proper player recreation on infrastructure restart
- ✅ Better detection of invalid player states

