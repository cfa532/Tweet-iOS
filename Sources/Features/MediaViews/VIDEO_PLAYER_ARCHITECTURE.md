# Video Player Architecture & AVKit Timer Optimization

## Summary

Your app has **two video player implementations** with different purposes. The 1ms AVKit timer hang you discovered only affects one of them, and it's already been fixed.

---

## Video Player Implementations

### 1. `SimpleVideoPlayer.swift` ✅ (Already Optimized!)

**Used in**: Feed videos (`MediaCell`)

**Architecture**:
- ✅ **MediaCell mode**: Uses custom `AVPlayerLayerView` (direct `AVPlayerLayer`)
- ✅ **No `AVPlayerViewController`** in feed = **No timer overhead**
- ✅ **No `AVMobileGlassControlsViewController`** = **No 1ms hangs**
- Uses `AVPlayerViewController` only for fullscreen/detail views (where native controls are needed)

```swift
// Line 3097 in SimpleVideoPlayer.swift
if mode == .mediaBrowser || mode == .tweetDetail {
    AVPlayerViewControllerRepresentable(...)  // With controls
} else {
    AVPlayerLayerView(player: player)  // ✅ NO controls overhead!
}
```

**Verdict**: ✅ **Already optimized** - No changes needed!

---

### 2. `CachingVideoPlayer.swift` ✅ (Now Optimized!)

**Used in**: Likely MediaBrowserView (fullscreen viewer)

**Architecture** (after fix):
- ✅ **Without controls** (`showNativeControls: false`): Uses `LightweightVideoPlayer`
- ✅ **With controls** (`showNativeControls: true`): Uses SwiftUI's `VideoPlayer`

```swift
// Line 77-95 in CachingVideoPlayer.swift (UPDATED)
if showNativeControls {
    VideoPlayer(player: player)  // Full controls for fullscreen
} else {
    LightweightVideoPlayer(player: player)  // ✅ NO controls overhead!
}
```

**Verdict**: ✅ **Now optimized** - Uses lightweight player when controls aren't needed!

---

## The AVKit Timer Issue

### What Causes It

SwiftUI's `VideoPlayer` internally creates an `AVPlayerViewController`, which spawns control UI components even when hidden:

```
VideoPlayer (showNativeControls: false)
    └─ AVPlayerViewController (always created!)
        └─ AVMobileGlassControlsViewController
            ├─ Volume slider auto-hide timer ❌ (1ms every few seconds)
            ├─ Transport controls timer ❌
            └─ ~500KB memory overhead ❌
```

### Where It Was a Problem

- ❌ **`CachingVideoPlayer` with `showNativeControls: false`** - Used `VideoPlayer` (now fixed!)
- ✅ **`SimpleVideoPlayer` in MediaCell mode** - Already used `AVPlayerLayerView` (no issue!)

---

## Custom Volume Button

You mentioned there's a custom volume button overlaid on the player. Let me verify where it is:

<function_calls>
<invoke name="find_text_in_file">
<parameter name="context_lines">5