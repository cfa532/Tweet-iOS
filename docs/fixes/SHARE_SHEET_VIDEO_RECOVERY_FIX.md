# Share Sheet Video Player Recovery Fix

**Date:** December 21, 2025  
**Status:** ✅ Fixed  
**Issue:** Media cell video players breaking and failing to recover when users share tweet posts

---

## Problem Description

Video players in media cells would break and fail to recover after users shared tweets. The issue was caused by a race condition and improper overlay lifecycle management.

---

## Root Causes

### 1. **Timing Issue - Late Overlay Registration**

The overlay was registered too late in the lifecycle:

```swift
// OLD CODE - WRONG TIMING
.sheet(item: $shareSheetItems) { sheetData in
    ZStack { ... }
    .onAppear {
        // ❌ Called AFTER willResignActiveNotification has already fired
        OverlayVisibilityCoordinator.shared.beginOverlay(id: "shareSheet", ...)
    }
}
```

**Flow with timing issue:**
1. User taps share button → iOS presents UIActivityViewController
2. iOS fires `UIApplication.willResignActiveNotification`
3. Video players receive notification and try to handle background transition
4. **BUT** `isCoveredByOverlay` is still `false` (overlay not registered yet)
5. Share sheet's `onAppear` fires → overlay finally registered (too late)
6. Video state tracking becomes inconsistent

### 2. **Duplicate Overlay Cleanup**

The overlay was being ended twice:

```swift
// OLD CODE - DUPLICATE CLEANUP
.sheet(item: $shareSheetItems, onDismiss: {
    OverlayVisibilityCoordinator.shared.endOverlay(id: "shareSheet", ...)  // ✅ First call
}) { sheetData in
    ZStack { ... }
    .onDisappear {
        OverlayVisibilityCoordinator.shared.endOverlay(id: "shareSheet", ...)  // ❌ Second call
    }
}
```

This caused the `OverlayVisibilityCoordinator` state to become desynchronized.

### 3. **Recovery Race Condition**

When the share sheet was dismissed:
- `onDisappear` fired → `endOverlay` called → `handleActualVisibilityChange(true)` tried to resume video
- iOS fired `didBecomeActiveNotification` → `handleDidBecomeActive()` called → `recoverFromBackground()` executed
- These two recovery paths conflicted, breaking player state

---

## Solution

### Change 1: Register Overlay Before Sheet Presents

Move `beginOverlay` to the button tap handler, BEFORE the async Task that generates the preview:

```swift
DebounceButton(...) {
    isPreparingShare = true
    
    // ✅ CRITICAL FIX: Register overlay BEFORE presenting sheet
    OverlayVisibilityCoordinator.shared.beginOverlay(id: "shareSheet", source: "TweetActionButtonsView")
    
    Task {
        // Generate preview and present sheet...
    }
}
```

**Benefits:**
- `isCoveredByOverlay` is set to `true` BEFORE `willResignActiveNotification` fires
- Video players know they're covered before iOS sends the notification
- State tracking is consistent throughout the lifecycle

### Change 2: Remove Duplicate Cleanup

Keep cleanup only in `onDismiss`, remove from `onDisappear`:

```swift
.sheet(item: $shareSheetItems, onDismiss: {
    // Reset state when sheet is dismissed
    attachmentPreviewImage = nil
    isPreparingShare = false
    onShareVisibilityChange?(false)
    
    // ✅ Only cleanup point - most reliable
    OverlayVisibilityCoordinator.shared.endOverlay(id: "shareSheet", source: "TweetActionButtonsView")
}) { sheetData in
    ZStack { ... }
    .onAppear {
        isPreparingShare = false
        // ✅ REMOVED: beginOverlay - now called before sheet presents
    }
    // ✅ REMOVED: onDisappear with endOverlay
}
```

### Change 3: Add Error Handling

Ensure overlay is cleaned up even if sheet never presents:

```swift
Task {
    var sheetPresented = false
    defer {
        if !sheetPresented {
            // If sheet was never presented, clean up overlay
            Task { @MainActor in
                if self.shareSheetItems == nil {
                    OverlayVisibilityCoordinator.shared.endOverlay(id: "shareSheet", ...)
                    self.isPreparingShare = false
                }
            }
        }
    }
    
    // Generate preview and present sheet...
    shareSheetItems = ShareSheetData(items: items)
    sheetPresented = true
}
```

---

## Video Player Lifecycle Flow (After Fix)

### When Share Button is Tapped:

1. **Button tap handler (synchronous)**
   - `isPreparingShare = true`
   - `beginOverlay("shareSheet")` called ✅
   - `isCoveredByOverlay` becomes `true` for all media cell videos

2. **iOS presents share sheet**
   - `UIApplication.willResignActiveNotification` fires
   - Videos see `isCoveredByOverlay == true` ✅
   - Videos properly cache state and prepare for background

3. **Share sheet appears**
   - `onAppear` fires
   - `isPreparingShare = false` (hide spinner)
   - No overlay registration needed (already done)

### When Share Sheet is Dismissed:

1. **iOS dismisses share sheet**
   - `UIApplication.didBecomeActiveNotification` fires
   - `recoverFromBackground()` executes
   - Videos check `isCoveredByOverlay` (still `true`) ✅
   - Recovery deferred until overlay is removed

2. **Sheet `onDismiss` fires**
   - State cleaned up
   - `endOverlay("shareSheet")` called ✅
   - `isCoveredByOverlay` becomes `false`
   - `handleActualVisibilityChange(actuallyVisible: true)` fires
   - Videos resume playback cleanly ✅

---

## Testing

To verify the fix works:

1. **Basic Share Test:**
   - Scroll feed with playing video
   - Tap share button on video tweet
   - Verify video pauses cleanly
   - Dismiss share sheet
   - Verify video resumes playback

2. **Cancel Test:**
   - Tap share button
   - Immediately tap outside to dismiss
   - Verify video resumes (overlay cleanup via defer block)

3. **Background Test:**
   - Open share sheet
   - Switch to another app
   - Return to app
   - Dismiss share sheet
   - Verify video recovers properly

4. **Multiple Videos Test:**
   - Have multiple videos visible/paused
   - Share a tweet
   - Dismiss share sheet
   - Verify all videos recover state correctly

---

## Files Modified

- `Sources/Tweet/TweetActionButtonsView.swift`
  - Lines 477-479: Added early `beginOverlay` call
  - Lines 481-522: Added error handling with defer block
  - Lines 574: Removed `beginOverlay` from `onAppear`
  - Removed: `onDisappear` block with duplicate `endOverlay`

---

## Related Issues

This fix addresses the same class of timing issues that were previously fixed for:
- Screen lock recovery (`SCREEN_LOCK_RECOVERY_FIX_OCT_22_2025.md`)
- Profile video recovery (`PROFILE_VIDEO_SCREEN_LOCK_FIX_FINAL.md`)
- Background/foreground transitions

The pattern is consistent: overlay/lifecycle notifications must be registered BEFORE the event occurs, not in response to SwiftUI lifecycle callbacks that fire afterward.

---

## Key Takeaways

1. **Timing matters:** Register overlays before presenting, not in `onAppear`
2. **Avoid duplicates:** Use either `onChange` or `onDismiss`, not both
3. **Handle errors:** Add cleanup for cases where presentation fails
4. **Test edge cases:** Background, cancel, multiple videos, etc.

