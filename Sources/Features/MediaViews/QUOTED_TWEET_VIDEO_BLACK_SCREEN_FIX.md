# Quoted Tweet Video Black Screen Fix

## Issue Description

When navigating from an outer tweet's detail view to a quoted tweet's detail view, the video shows a **black screen** instead of playing. The logs showed:

```
🎥 [SimpleVideoPlayer.setupPlayer] tweetDetail mode for QmYzrC9xLYQ1KoMqPrBM79i1Mt9A36PE3u8ddoSQXLPhDs
🔄 [SimpleVideoPlayer.setupPlayer] Creating new singleton player
...
DEBUG: [TweetDetailView] ===== VIEW DISAPPEARED =====
📱 [DetailVideoManager] Deactivated - lifecycle observers removed
📝 [VIDEO STATE] Saved state for QmYzrC9xLYQ1KoMqPrBM79i1Mt9A36PE3u8ddoSQXLPhDs: time=0.0s
💾 [DETAIL VIDEO MANAGER] Saved playback state before clearing: 0.0s, wasPlaying: false
DEBUG: [DetailVideoManager] Replaced player item with nil to stop playback  ← PLAYER CLEARED!
```

## Root Cause

The `DetailVideoManager` singleton uses an `activeDetailViewCount` to track how many detail views are active, with a 0.3-second delayed cleanup to handle detail → detail transitions gracefully. However, the `activateForDetail()` and `deactivate()` functions had a critical bug:

### The Bug

```swift
// OLD CODE (BUGGY)
func activateForDetail() {
    guard !isActive else { return }  // ← RETURNS EARLY ON SECOND DETAIL VIEW!
    isActive = true
    registerLifecycleObservers()
    beginDetailViewSession()  // ← NEVER CALLED FOR SECOND VIEW
}

func deactivate() {
    guard isActive else { return }
    isActive = false
    teardownAppLifecycleNotifications()
    endDetailViewSession()
}
```

### The Problem Flow

1. **First detail view appears** (outer tweet):
   - `activateForDetail()` → `isActive = true` → `beginDetailViewSession()` (count = 1)

2. **Second detail view appears** (quoted tweet):
   - `activateForDetail()` → **returns early because `isActive` is already true**
   - `beginDetailViewSession()` is **never called** → count stays at 1

3. **Second detail view creates player**:
   - `SimpleVideoPlayer.setupPlayer()` creates player in singleton

4. **First detail view disappears**:
   - `deactivate()` → `endDetailViewSession()` (count = 0)
   - Scheduled clear task starts (0.3s delay)

5. **0.3 seconds pass**:
   - Clear task executes → `clearCurrentVideo()` → `currentPlayer = nil`
   - **New player gets cleared while still being used!**

6. **Result**: Black screen in quoted tweet's detail view

## Solution

The fix separates the **session counting** (which must happen for every view) from the **lifecycle observer management** (which only needs to happen once):

```swift
// NEW CODE (FIXED)
func activateForDetail() {
    // CRITICAL: Always increment session count, even if already active
    beginDetailViewSession()
    
    // Only register lifecycle observers once
    guard !isActive else {
        print("📱 [DetailVideoManager] Already active - incremented session count to \(activeDetailViewCount)")
        return
    }
    isActive = true
    registerLifecycleObservers()
    print("📱 [DetailVideoManager] Activated - lifecycle observers registered")
}

func deactivate() {
    // CRITICAL: Always decrement session count
    endDetailViewSession()
    
    // Only teardown lifecycle observers when count reaches 0
    guard isActive && activeDetailViewCount == 0 else {
        print("📱 [DetailVideoManager] Session ended - count now \(activeDetailViewCount)")
        return
    }
    isActive = false
    teardownAppLifecycleNotifications()
    print("📱 [DetailVideoManager] Deactivated - lifecycle observers removed")
}
```

## Fixed Flow

1. **First detail view appears** (outer tweet):
   - `activateForDetail()` → `beginDetailViewSession()` (count = 1) → `isActive = true`

2. **Second detail view appears** (quoted tweet):
   - `activateForDetail()` → `beginDetailViewSession()` (count = 2) → returns (already active)

3. **Second detail view creates player**:
   - `SimpleVideoPlayer.setupPlayer()` creates player in singleton

4. **First detail view disappears**:
   - `deactivate()` → `endDetailViewSession()` (count = 1)
   - `activeDetailViewCount > 0` → **clear task NOT scheduled** ✅

5. **Second detail view continues**:
   - Player remains intact and continues playing ✅

6. **Second detail view disappears**:
   - `deactivate()` → `endDetailViewSession()` (count = 0)
   - Scheduled clear task starts (0.3s delay)
   - After 0.3s: `clearCurrentVideo()` cleans up properly

## Key Insights

### The Root Issue
The old code conflated two different concerns:
- **Lifecycle observer management** (should only happen once per app session)
- **Active view counting** (should happen for every detail view)

By checking `isActive` before calling `beginDetailViewSession()`, the second detail view's session was never counted, causing premature cleanup.

### Why the 0.3s Delay?
The delay in `endDetailViewSession()` is crucial for smooth detail → detail navigation. Without it:
- First view disappears → immediate clear
- Second view appears → sees cleared player → has to recreate
- Result: Visible black flash during transition

With the delay:
- First view disappears → delayed clear (0.3s)
- Second view appears → increments count → cancels clear task
- Result: Smooth reuse of existing player

## Testing

Test the fix by:

1. Open a tweet with a quoted tweet containing video
2. Open the outer tweet's detail view
3. Navigate to the quoted tweet's detail view
4. ✅ Video should load and play (not black screen)
5. Navigate back to outer tweet
6. Navigate to quoted tweet again
7. ✅ Video should still work on repeated navigation

## Impact

- **Before**: Black screen on detail → detail navigation
- **After**: Smooth video playback with proper player reuse
- **Side benefit**: Better memory efficiency (player reuse instead of recreation)

## Related Files

- `SingletonVideoManagers.swift` - DetailVideoManager lifecycle fix
- `SimpleVideoPlayer.swift` - Video player setup and singleton usage
- `TweetDetailView.swift` - Calls activateForDetail/deactivate

## Additional Optimization: HLS URL Caching

While fixing this issue, we also added **HLS URL resolution caching** to reduce network overhead:

- **Added**: `resolvedHLSURLCache` dictionary in `SharedAssetCache`
- **Caches**: Resolved HLS URLs (master.m3u8 or playlist.m3u8) for 1 hour
- **Benefit**: Eliminates 0.3-0.35s network checks on subsequent video loads
- **Impact**: Faster load times and reduced network traffic

This optimization is independent but complements the main fix by reducing the initial load time for videos.
