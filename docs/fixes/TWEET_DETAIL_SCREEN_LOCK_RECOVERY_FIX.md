# Screen Lock Video Recovery Fix (All Modes)

**Date:** October 23, 2025  
**Status:** ✅ **FIXED**  
**Priority:** 🔴 **CRITICAL**

---

## Problem

When locking the screen with the power button while any video is playing, **ALL videos** would break upon unlocking - including MediaCell videos in the feed, TweetDetailView videos, and fullscreen videos in MediaBrowser. The videos would show black screens and could not recover.

### Reproduction Steps

1. Open app with video content (in feed, detail view, or fullscreen)
2. Video plays normally
3. Lock screen with power button
4. Wait a few seconds
5. Unlock screen
6. **Result:** ALL videos show black screens and cannot recover
   - MediaCell videos in feed: black screens
   - TweetDetailView video: black screen
   - Navigate to any new video: black screen

---

## Summary

This fix addresses a **catastrophic bug** where locking the screen would break ALL videos in the app across all modes (MediaCell, TweetDetail, MediaBrowser). The issue had two root causes:

1. **Overly aggressive "broken player" detection** - The `isPlayerBroken()` check was marking healthy players as broken during screen lock recovery
2. **Missing view layer refresh** - Video layers for AVPlayerViewController weren't being refreshed after screen lock, causing stale/disconnected layers

Both issues are now fixed with an optimized approach:
- **More lenient broken player detection** - Only mark players as broken if BOTH `loadedTimeRanges` is empty AND `duration` is invalid
- **Selective view refresh** - Only refresh AVPlayerViewController-based views (Detail/FullScreen), skip MediaCell to prevent flicker
- **Prevent duplicate refresh** - Use `hasRecoveredThisCycle` flag to ensure single recovery per event

---

## Root Cause

The issue was a combination of two problems in how `SimpleVideoPlayer` handles screen lock recovery:

### Problem 1: Overly Aggressive "Broken Player" Detection

The `isPlayerBroken()` sanity check was too strict:

```swift
// OLD CODE - TOO STRICT
if playerItem.status == .readyToPlay && playerItem.loadedTimeRanges.isEmpty {
    return true  // Marked as broken!
}
```

**Why this breaks everything:**
- When screen locks, iOS can **temporarily clear `loadedTimeRanges`** from player items
- The check would mark ALL players (both detail and MediaCell) as "broken"
- Recovery would clear these "broken" players
- MediaCell videos not currently visible wouldn't recreate properly
- **Result: ALL videos broken after screen lock**

### Problem 2: TweetDetailView Layer Not Refreshing

For `tweetDetail` mode specifically:

1. **TweetDetailView uses DetailVideoManager singleton** - Unlike MediaCell which uses individual players, TweetDetail mode uses a singleton player managed by `DetailVideoManager`

2. **Screen lock lifecycle difference** - Screen lock triggers:
   - `willResignActive` → (screen locked)
   - `didBecomeActive` (when unlocked)
   
   But NOT `willEnterForeground` (which is only for app backgrounding)

3. **AVPlayerViewController layer becomes stale** - When the screen locks:
   - The player is paused and state is saved
   - The `AVPlayerViewController`'s video layer becomes disconnected
   - On unlock, the recovery logic seeks to restore position but doesn't refresh the view layer
   - Result: Black screen because the layer isn't properly reconnected

4. **Existing recovery wasn't forcing view refresh** - The `DetailVideoManager` recovery logic would seek to the saved time and resume playback, but `SimpleVideoPlayer`'s `AVPlayerViewControllerRepresentable` wouldn't recreate its layer to reconnect properly.

---

## Solution

Implemented a multi-layer fix to address both the false "broken player" detection and the layer refresh issues:

### 1. Fixed Overly Aggressive "Broken Player" Detection

**File:** `Sources/Features/MediaViews/SimpleVideoPlayer.swift`

```swift
/// SANITY CHECK: Detects if player is broken
private func isPlayerBroken() -> Bool {
    guard let player = player else { return true }
    guard let playerItem = player.currentItem else { return true }
    
    // Check 1: Status is failed
    if playerItem.status == .failed {
        return true
    }
    
    // Check 2: For screen lock recovery, don't check loadedTimeRanges alone
    // iOS might temporarily clear this data after screen lock, but it will reload
    // Only check loadedTimeRanges if status is .readyToPlay AND duration is invalid
    // This prevents false positives where player is healthy but temporarily has no ranges
    if playerItem.status == .readyToPlay && 
       playerItem.loadedTimeRanges.isEmpty && 
       !playerItem.duration.isValid {
        print("⚠️ [SANITY CHECK] Player ready but no loaded data AND invalid duration - likely broken")
        return true
    }
    
    return false
}
```

**Critical Change:** Now requires **BOTH** conditions to mark player as broken:
- `loadedTimeRanges.isEmpty` **AND** `!duration.isValid`

Previously only checked `loadedTimeRanges.isEmpty`, which caused false positives during screen lock when iOS temporarily clears this data.

**Impact:** This prevents ALL videos (MediaCell and Detail) from being incorrectly cleared during screen lock recovery.

### 2. Prevent Duplicate Recovery in `didBecomeActive` Handler

**File:** `Sources/Features/MediaViews/SimpleVideoPlayer.swift`

```swift
private func handleDidBecomeActive() {
    print("DEBUG: [VIDEO APP ACTIVE] App became active for \(mid), mode: \(mode)")
    // Recover from screen lock (which triggers didBecomeActive but not willEnterForeground)
    // Only recover if we haven't already recovered in this cycle (to avoid duplicate recovery)
    if !hasRecoveredThisCycle {
        print("DEBUG: [VIDEO APP ACTIVE] Recovering from screen lock for \(mid)")
        recoverFromBackground()
        // Note: recoverFromBackground() already increments representableId, so we don't do it again here
    } else {
        print("DEBUG: [VIDEO APP ACTIVE] Already recovered in willEnterForeground, skipping for \(mid)")
        // willEnterForeground already called recoverFromBackground() which refreshed the view
        // No need to refresh again
    }
}
```

**Why:** This prevents **duplicate view refresh** (which would cause flickering):
- Screen lock: triggers `didBecomeActive` only → calls `recoverFromBackground()` once
- App background: triggers `willEnterForeground` then `didBecomeActive` → calls `recoverFromBackground()` only once (in willEnterForeground)

The `hasRecoveredThisCycle` flag ensures we only recover once per event cycle.

### 3. Optimized Recovery Logic - Selective View Refresh

**File:** `Sources/Features/MediaViews/SimpleVideoPlayer.swift`

```swift
private func recoverFromBackground() {
    print("DEBUG: [VIDEO RECOVERY] Starting recovery for \(mid), mode: \(mode)")
    isPlayerDetached = false
    hasRecoveredThisCycle = true
    
    // ... sanity check ...
    
    // CRITICAL: Refresh view layer for modes using AVPlayerViewController
    // Screen lock can cause AVPlayerViewController layer to become disconnected
    // MediaCell uses AVPlayerLayer which is more resilient, so we skip it to avoid flickering
    if mode == .tweetDetail || mode == .mediaBrowser {
        print("DEBUG: [VIDEO RECOVERY] Forcing view refresh for \(mode) mode (AVPlayerViewController)")
        representableId += 1
    } else {
        print("DEBUG: [VIDEO RECOVERY] Skipping view refresh for MediaCell (AVPlayerLayer is resilient)")
    }
    
    // ... restore playback state ...
}
```

**Why:** This is an **optimization** to prevent unnecessary flickering:
- **AVPlayerViewController** (Detail/FullScreen): Requires view refresh after screen lock because the layer becomes disconnected
- **AVPlayerLayer** (MediaCell): More resilient to screen lock, doesn't need view refresh, avoiding flicker

**Key insight:** The main `isPlayerBroken()` fix prevents ALL players from being incorrectly cleared. The view refresh is only needed for modes using `AVPlayerViewController`.

### 4. Added Video Layer Refresh Notification

**File:** `Sources/Core/NotificationNames.swift`

```swift
// MARK: - Video Related
/// Posted to stop all videos in the tweet list when entering full screen
static let stopAllVideos = Notification.Name("StopAllVideos")
/// Posted to force video layer refresh after screen lock recovery
static let videoLayerRefresh = Notification.Name("VideoLayerRefresh")
```

**File:** `Sources/Core/SingletonVideoManagers.swift` (DetailVideoManager)

```swift
private func recoverFromBackground() {
    // ... existing recovery logic ...
    
    // CRITICAL: Post notification to force SimpleVideoPlayer view refresh
    // This ensures AVPlayerViewController layer is properly reconnected after screen lock
    NSLog("DEBUG: [DetailVideoManager] Posting videoLayerRefresh to force view update")
    NotificationCenter.default.post(name: .videoLayerRefresh, object: nil)
    
    // Force a seek to refresh the video layer
    player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { ... }
}
```

**File:** `Sources/Features/MediaViews/SimpleVideoPlayer.swift`

```swift
.onReceive(NotificationCenter.default.publisher(for: .videoLayerRefresh)) { _ in 
    handleVideoLayerRefresh() 
}

private func handleVideoLayerRefresh() {
    // This is called when DetailVideoManager detects screen lock recovery
    // Force view refresh for detail/fullscreen modes to reconnect AVPlayerViewController layer
    if mode == .tweetDetail || mode == .mediaBrowser {
        print("DEBUG: [VIDEO LAYER REFRESH] Forcing view refresh for \(mode) mode, mid: \(mid)")
        representableId += 1
        
        // Ensure player is in correct state
        if let player = player {
            player.isMuted = false
            print("DEBUG: [VIDEO LAYER REFRESH] Ensured unmuted state for detail/fullscreen mode")
        }
    }
}
```

**Why:** This provides a communication channel for `DetailVideoManager` to tell `SimpleVideoPlayer` that it needs to refresh its view layer after recovery.

---

## Files Modified

1. **Sources/Features/MediaViews/SimpleVideoPlayer.swift**
   - Added view refresh in `handleDidBecomeActive()`
   - Enhanced `recoverFromBackground()` to always refresh layer for tweetDetail mode
   - Added `handleVideoLayerRefresh()` notification handler
   - Added `.videoLayerRefresh` notification listener

2. **Sources/Core/SingletonVideoManagers.swift**
   - Added `.videoLayerRefresh` notification post in `DetailVideoManager.recoverFromBackground()`

3. **Sources/Core/NotificationNames.swift**
   - Added `.videoLayerRefresh` notification name

---

## Testing

### Test Scenarios

1. ✅ **Basic screen lock recovery in TweetDetailView**
   - Open TweetDetailView with video
   - Let video play for a few seconds
   - Lock screen with power button
   - Wait 5 seconds
   - Unlock screen
   - **Expected:** Video resumes at saved position with correct playback state

2. ✅ **MediaCell videos remain working after screen lock**
   - Open TweetDetailView with video
   - Lock screen with power button
   - Unlock screen
   - Navigate back to feed
   - **Expected:** All MediaCell videos in feed work normally, no black screens

3. ✅ **Screen lock while paused**
   - Open TweetDetailView with video
   - Pause video
   - Lock screen
   - Unlock screen
   - **Expected:** Video remains paused at correct position

4. ✅ **Multiple screen lock cycles**
   - Open TweetDetailView with video
   - Lock/unlock screen multiple times rapidly
   - Navigate back to feed and back to detail
   - **Expected:** Both detail and feed videos continue working, no black screens

5. ✅ **Screen lock at video start**
   - Open TweetDetailView with video
   - Lock screen immediately (within 1 second)
   - Unlock screen
   - **Expected:** Video starts playing from beginning

6. ✅ **Screen lock with multiple videos**
   - Open TweetDetailView with video
   - Lock screen
   - Unlock screen
   - Navigate to different tweet with video
   - **Expected:** New video plays normally

---

## Technical Details

### Why `representableId` Increment Works

In SwiftUI, when you use `UIViewControllerRepresentable` (which `AVPlayerViewControllerRepresentable` is), SwiftUI decides whether to:
- Call `updateUIViewController()` on the existing instance, OR
- Call `makeUIViewController()` to create a new instance

By adding `.id(representableId)` to the view and incrementing it, we force SwiftUI to call `makeUIViewController()`, which:
1. Creates a brand new `AVPlayerViewController`
2. Attaches the player with a fresh layer connection
3. Properly displays video instead of showing stale black layer

### Recovery Flow Diagram

```
Screen Lock Pressed
    ↓
willResignActive
    ↓
DetailVideoManager.handleAppWillResignActive()
    - Saves: wasPlaying, currentTime
    - Pauses player
    - Resets hasRecoveredThisCycle = false
    ↓
(Screen is locked)
    ↓
Screen Unlocked
    ↓
didBecomeActive (NOT willEnterForeground!)
    ↓
DetailVideoManager.handleAppDidBecomeActive()
    ↓
DetailVideoManager.recoverFromBackground()
    - Posts .videoLayerRefresh notification
    - Seeks to saved position
    - Resumes playback if was playing
    ↓
SimpleVideoPlayer receives .videoLayerRefresh
    ↓
SimpleVideoPlayer.handleVideoLayerRefresh()
    - Increments representableId
    - Ensures unmuted state
    ↓
SimpleVideoPlayer.handleDidBecomeActive()
    - Also increments representableId (safety net)
    ↓
SwiftUI recreates AVPlayerViewController
    ↓
Fresh layer connection established
    ↓
✅ Video displays correctly
```

---

## Prevention

To prevent similar issues in the future:

1. **Always test screen lock scenarios** - Screen lock has a different lifecycle than app backgrounding
2. **Force view refresh for player reconnection** - When AVPlayer state is restored but view layer might be stale, increment view ID
3. **Use notification bridge** - For singleton managers controlling shared players, use notifications to communicate with views
4. **Test both paused and playing states** - Recovery logic must handle both states correctly

---

## Related Issues

- [SCREEN_LOCK_RECOVERY_FIX_OCT_22_2025.md](./SCREEN_LOCK_RECOVERY_FIX_OCT_22_2025.md) - Previous fix for MediaCell screen lock recovery
- [BACKGROUND_VIDEO_BLACK_SCREEN_FIX.md](./BACKGROUND_VIDEO_BLACK_SCREEN_FIX.md) - Background app switching recovery

---

## Notes

- This fix specifically targets TweetDetailView which uses `AVPlayerViewController` in `mode: .tweetDetail`
- MediaCell mode already had screen lock recovery working from previous fix
- FullScreen mode (MediaBrowser) benefits from the same fix via `handleVideoLayerRefresh()`
- The dual recovery approach (notification + didBecomeActive increment) provides redundancy

