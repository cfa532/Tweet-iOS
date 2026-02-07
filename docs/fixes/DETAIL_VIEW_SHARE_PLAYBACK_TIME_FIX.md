# Detail View Share - Playback Time Fix

**Date:** January 9, 2026  
**Status:** ✅ Fixed

---

## Problem

When sharing a video from TweetDetailView, the screenshot was captured at the **wrong playback time** - not matching what the user was actually seeing on screen.

**Example:**
- User watches video to 30 seconds
- User taps share button
- Screenshot shows frame from 1 second or completely wrong timestamp

---

## Root Cause

**Architecture Mismatch:**

1. **TweetDetailView uses `DetailVideoManager.shared.currentPlayer`**  
   - This is a **singleton independent player** (lines 3436, 3462 in `SimpleVideoPlayer.swift`)
   - Created specifically to avoid conflicts with MediaCell players
   - NOT stored in SharedAssetCache

2. **Share button looked in `SharedAssetCache.shared.getCachedPlayer()`**  
   - Lines 896, 934 in `TweetActionButtonsView.swift`
   - This returns either:
     - A **different player** (from MediaCell/grid view) with different playback position
     - `nil` (no cached player), causing fallback to static timestamp

**From SimpleVideoPlayer.swift (lines 3418-3420):**
```swift
// Different video or no singleton - create an INDEPENDENT player and store in singleton.
// IMPORTANT: Do NOT reuse SharedAssetCache's cached AVPlayer here, otherwise MediaCell's
// onDisappear() will pause the same player instance and TweetDetail will "play briefly then stop".
```

**Result:** Share button captured screenshot from wrong player or wrong timestamp.

---

## Solution

Check `DetailVideoManager.shared.currentPlayer` **first** when `isInDetailView` is true, before falling back to SharedAssetCache.

### Implementation

**File:** `Sources/Tweet/TweetActionButtonsView.swift`

**Added before existing cache lookup logic:**

```swift
// CRITICAL: TweetDetailView uses DetailVideoManager singleton, not SharedAssetCache
// Check DetailVideoManager first when in detail view context
if isInDetailView,
   let detailPlayer = DetailVideoManager.shared.currentPlayer,
   DetailVideoManager.shared.currentVideoMid == mediaID,
   let playerItem = detailPlayer.currentItem {
    print("DEBUG: [SHARE] Found DetailVideoManager singleton player for: \(mediaID)")
    
    let duration = try? await playerItem.asset.load(.duration)
    if let duration = duration {
        let durationSeconds = CMTimeGetSeconds(duration)
        let currentTime = CMTimeGetSeconds(playerItem.currentTime())
        print("DEBUG: [SHARE] DetailVideoManager player duration: \(durationSeconds)s, currentTime: \(currentTime)s")
        
        if durationSeconds > 0 && !durationSeconds.isNaN && !durationSeconds.isInfinite {
            // Use current position, or fallback to 1s if at beginning
            let captureTime = currentTime > 0.1 ? currentTime : min(1.0, durationSeconds * 0.1)
            print("DEBUG: [SHARE] Capturing frame from DetailVideoManager at \(String(format: "%.2f", captureTime))s")
            
            if let image = await captureFrameFromPlayer(detailPlayer, at: captureTime) {
                let elapsed = Date().timeIntervalSince(startTime)
                print("DEBUG: [SHARE] Preview generated from DetailVideoManager in \(String(format: "%.2f", elapsed))s")
                return image
            }
        }
    }
}
```

---

## Technical Details

### Player Lookup Priority (when `isInDetailView` is true):

1. **FullScreenVideoManager.shared.singletonPlayer** (if in fullscreen)
2. **DetailVideoManager.shared.currentPlayer** ⭐ **NEW - This fixes the bug**
3. **SharedAssetCache.shared.getCachedPlayer()** (fallback for MediaCell)
4. **Asset-based capture** (final fallback if no player found)

### Why DetailVideoManager Uses Independent Player

From the architecture documentation:
- **MediaCell players** must be pausable by scrolling/navigation events
- **TweetDetailView player** must be immune to MediaCell lifecycle
- **Solution:** DetailVideoManager stores a singleton that's separate from SharedAssetCache

This prevents MediaCell's `onDisappear()` from pausing the detail view video.

---

## Files Modified

### TweetActionButtonsView.swift
- Added DetailVideoManager.shared.currentPlayer check when `isInDetailView` is true
- Captures current playback time from the actual singleton player being displayed
- Falls back to SharedAssetCache for MediaCell context

---

## Benefits

### ✅ Accurate Screenshots
- Share button now captures **exact frame user is watching** in detail view
- No more mismatch between displayed video and shared screenshot
- Respects current playback position (e.g., user at 30s → screenshot at 30s)

### ✅ Respects Architecture
- Follows existing singleton pattern for DetailVideoManager
- Doesn't break MediaCell player isolation
- No changes needed to player management logic

### ✅ Backward Compatible
- Feed/grid sharing still works through SharedAssetCache
- Fullscreen sharing still works through FullScreenVideoManager
- Only adds DetailVideoManager check for detail view context

---

## Testing Checklist

### ✅ Detail View Video Sharing
1. Open tweet with video in TweetDetailView
2. Play video to 30 seconds
3. Pause video
4. Tap share button
5. **Expected:** Screenshot shows frame at ~30 seconds
6. **Verify:** Debug log shows "Found DetailVideoManager singleton player"

### ✅ Feed Video Sharing (unchanged)
1. Play video in feed (MediaCell)
2. Tap share on tweet
3. **Expected:** Works as before (uses SharedAssetCache)

### ✅ Fullscreen Video Sharing (unchanged)
1. Open video fullscreen (MediaBrowser)
2. Play to specific timestamp
3. Tap share
4. **Expected:** Works as before (uses FullScreenVideoManager)

---

## Debug Logging

When sharing from TweetDetailView, you should see:

```
DEBUG: [SHARE] Starting video preview generation for: [url]
DEBUG: [SHARE] Extracted mediaID: QmXXX
DEBUG: [SHARE] In TweetDetailView context, using cache key: QmXXX
DEBUG: [SHARE] Found DetailVideoManager singleton player for: QmXXX
DEBUG: [SHARE] DetailVideoManager player duration: 45.2s, currentTime: 30.1s
DEBUG: [SHARE] Capturing frame from DetailVideoManager at 30.10s
DEBUG: [SHARE] Preview generated from DetailVideoManager in 0.25s
```

---

## Related Issues

This completes the November 14, 2025 sharing system enhancement:
- [SHARING_SYSTEM_ENHANCEMENT_NOV_14_2025.md](./SHARING_SYSTEM_ENHANCEMENT_NOV_14_2025.md) - Fixed cache key lookup
- **This fix** - Fixed player source lookup to use correct singleton

---

## Related Documentation

- [**SingletonVideoManagers.swift**](../Sources/Core/SingletonVideoManagers.swift) - DetailVideoManager implementation
- [**SHARING_SYSTEM.md**](../SHARING_SYSTEM.md) - Complete sharing system documentation
- [**TWEETDETAIL_SINGLETON_PLAYER.md**](../docs/archive/fixes/TWEETDETAIL_SINGLETON_PLAYER.md) - Why DetailVideoManager uses independent player
- [**VIDEO_SYSTEM.md**](../VIDEO_SYSTEM.md) - Video player architecture

---

## Code Quality

### Clean Implementation
- Single conditional check before existing logic
- No code duplication
- Clear debug logging for verification

### Well-Documented
- Inline comments explain the architecture reason
- Debug logs show which player source was used
- Links to related documentation

### Future-Proof
- Maintains proper fallback chain
- Doesn't break other sharing contexts
- Easy to extend if new singleton managers are added
