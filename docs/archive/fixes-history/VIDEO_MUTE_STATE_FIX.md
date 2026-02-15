# Video Mute State Fix

**Date**: October 17, 2025  
**Issue**: Videos play unmuted on app startup despite saved mute preference  
**Status**: ✅ RESOLVED

## Problem Description

Videos in MediaCell would play with audio on app startup, even though the user's saved preference was set to muted. The audio would play continuously until the user manually toggled the mute button.

### Symptoms

- First video loads with audio playing
- Saved mute preference is "muted" in database
- Audio continues indefinitely (not just 1 second)
- Only affects app startup, not background recovery
- Toggling mute button fixes it

## Root Cause

**AVPlayer instances were created unmuted by default**, and the mute state was only applied **after** the player was created and configured. This created a race condition where:

1. `AVPlayer(playerItem:)` creates player → **unmuted by default**
2. Player might start playing immediately
3. Later: `configurePlayer()` applies `MuteState.shared.isMuted`
4. Too late - audio already playing

### The Race

```
Time 0ms:  AVPlayer created (unmuted by default)
Time 5ms:   Player starts loading/playing
Time 10ms:  configurePlayer() sets isMuted = true
           ❌ Too late - audio already started!
```

## Solution

### Mute-at-Inception Pattern

Apply `isMuted = true` **immediately** after creating the `AVPlayer`, before any configuration:

```swift
// In SharedAssetCache.swift

// Progressive video creation
let player = AVPlayer(playerItem: playerItem)

// CRITICAL: Mute player at creation - will be unmuted by mode if needed
player.isMuted = true  // ← IMMEDIATELY after creation

// Then configure...
player.automaticallyWaitsToMinimizeStalling = false

// HLS video creation  
let player = AVPlayer(playerItem: cachingPlayerItem)

// CRITICAL: Mute player at creation - will be unmuted by mode if needed
player.isMuted = true  // ← IMMEDIATELY after creation

// Then configure...
player.automaticallyWaitsToMinimizeStalling = false
```

### Mode-Based Unmuting

Later in `SimpleVideoPlayer.configurePlayer()`, apply the correct state based on mode:

```swift
// Configure player mute state based on mode
if mode == .mediaCell {
    // MediaCell: Apply global mute state from preferences
    player.isMuted = MuteState.shared.isMuted
} else {
    // Fullscreen/Detail: Always unmute
    player.isMuted = false
}
```

**Flow:**
1. Player created **muted** (safe default)
2. If MediaCell mode → stays muted (or unmuted based on user preference)
3. If Fullscreen mode → explicitly unmuted
4. No race condition, no audio leaks

## Files Changed

### `/Sources/Core/SharedAssetCache.swift`

Added `player.isMuted = true` immediately after both:
- Progressive video player creation (line ~539)
- HLS video player creation (line ~599)

### `/Sources/Features/MediaViews/SimpleVideoPlayer.swift`

No changes needed - existing `configurePlayer()` already applies mode-based mute state correctly (line ~1131).

## Alternative Approaches Considered

### ❌ Approach 1: Apply mute before every `play()` call
- **Problem**: Too many `play()` call sites across nested structs
- **Problem**: Some calls in closures where `self` context is different
- **Complexity**: High maintenance burden

### ❌ Approach 2: Force mute in AppDelegate and block refreshFromPreferences
- **Problem**: Doesn't respect user's saved preference
- **Problem**: Forces all users to muted state
- **UX**: Poor - ignores user choice

### ✅ Approach 3: Mute-at-Inception + Mode-Based Configuration
- **Benefits**: Simple, single point of change
- **Benefits**: Respects user preferences
- **Benefits**: Works for all modes
- **Chosen**: This approach

## Testing Results

**Before Fix:**
- ❌ Videos play unmuted on startup
- ❌ Audio continues until manual toggle
- ❌ Ignores saved mute preference

**After Fix:**
- ✅ Videos respect saved mute preference
- ✅ MediaCell videos muted if preference is muted
- ✅ Fullscreen videos always unmuted (correct behavior)
- ✅ No audio leaks or race conditions

## Performance Impact

- **Zero performance impact** - Single assignment at player creation
- **No delays** - Synchronous property assignment
- **Thread-safe** - All operations on appropriate queues

## Key Learnings

1. **Always set safe defaults** - Mute by default, unmute explicitly when needed
2. **Apply state at inception** - Don't wait for later configuration
3. **Use mode-based logic** - Different video contexts need different behavior
4. **Test on real devices** - Race conditions may not appear in simulator/debug mode

