# Fullscreen Black Screen Fix

## Problem

Videos show content correctly in MediaCell (feed), but when opened in fullscreen (MediaBrowser), they display a black screen. The audio plays correctly but no video content is visible.

## Root Cause

This is a classic **AVPlayerLayer attachment conflict** issue in AVFoundation:

### The Problem

```
MediaCell (visible)
    ↓
  VideoPlayerRepresentable
    ↓
  AVPlayerLayer ← Player's layer attached here
    ↓
User taps to enter fullscreen
    ↓
Mode changes to MediaBrowser
    ↓
AVPlayerViewControllerRepresentable created
    ↓
Tries to attach same player's layer
    ↓
❌ BLACK SCREEN - Layer already attached to MediaCell!
```

### Technical Details

**AVPlayer has only ONE video layer** that can only be attached to ONE view at a time. When transitioning from MediaCell to fullscreen:

1. **MediaCell** uses `VideoPlayerRepresentable` which wraps `VideoPlayer` (SwiftUI)
2. **MediaBrowser** uses `AVPlayerViewControllerRepresentable` which wraps `AVPlayerViewController` (UIKit)
3. Both try to use the **same AVPlayer instance** (for seamless transition)
4. **Problem**: The player's layer is still attached to VideoPlayerRepresentable when AVPlayerViewController tries to use it

### Why This Happens

- **MediaCell doesn't disappear immediately** when entering fullscreen (it's still in the background)
- **VideoPlayerRepresentable still holds the layer** until SwiftUI decides to tear it down
- **AVPlayerViewController can't attach the layer** because it's already attached elsewhere
- **Result**: Black screen (player works, but no visual output)

## Solution

Force the VideoPlayerRepresentable to detach the player's layer **before** AVPlayerViewController tries to attach it.

### Implementation

Added explicit layer detachment in the `onChange(of: mode)` handler:

```swift
.onChange(of: mode) { oldMode, newMode in
    guard let player = player else { return }
    
    if newMode == .mediaBrowser {
        // Entering full screen
        player.isMuted = false
        
        // CRITICAL: Force layer detachment
        // Incrementing representableId forces SwiftUI to recreate VideoPlayerRepresentable
        // This causes the old instance to release the player's layer
        self.representableId += 1
        NSLog("DEBUG: Incremented representableId to force layer detachment from MediaCell")
    } else if newMode == .mediaCell && oldMode == .mediaBrowser {
        // Exiting full screen to MediaCell
        player.isMuted = MuteState.shared.isMuted
        
        // Force recreation to ensure fresh layer attachment
        self.representableId += 1
        NSLog("DEBUG: Incremented representableId for fresh MediaCell layer")
    }
}
```

### How It Works

1. **Detect mode change** to `.mediaBrowser` (entering fullscreen)
2. **Increment `representableId`** 
3. **SwiftUI sees the ID changed** → Destroys old `VideoPlayerRepresentable`
4. **Old representable's `dismantleUIView` called** → Detaches player layer
5. **AVPlayerViewController created** with free layer → Attaches successfully
6. **Video displays correctly** in fullscreen ✅

## Flow Comparison

### Before Fix

```
User taps video in MediaCell
    ↓
Mode changes to mediaBrowser
    ↓
AVPlayerViewController created
    ↓
Tries: uiViewController.player = player
    ↓
Layer still attached to MediaCell VideoPlayerRepresentable
    ↓
❌ Black screen - Layer conflict
```

### After Fix

```
User taps video in MediaCell
    ↓
Mode changes to mediaBrowser
    ↓
representableId incremented
    ↓
SwiftUI destroys old VideoPlayerRepresentable
    ↓
Player layer detached from MediaCell
    ↓
AVPlayerViewController created
    ↓
uiViewController.player = player
    ↓
✅ Layer attaches successfully
    ↓
✅ Video displays correctly
```

## Key Concepts

### representableId

This is a `@State` variable used to force SwiftUI to recreate `UIViewRepresentable` wrappers:

```swift
@State private var representableId: Int = 0

// In view
VideoPlayerRepresentable(player: player)
    .id(representableId)  // ← Forces recreation when this changes
```

When `representableId` changes:
1. SwiftUI calls `dismantleUIView` on the old instance
2. Old instance cleans up and releases resources
3. SwiftUI creates a new instance with `makeUIView`
4. New instance gets fresh state

### Layer Attachment Rules

AVFoundation rules for `AVPlayerLayer`:
- **One layer per player** - Can't clone or share
- **One attachment at a time** - Layer can only be in one view hierarchy
- **Explicit detachment required** - Must be removed from old parent before attaching to new parent
- **Black screen symptom** - Trying to attach already-attached layer results in black screen

## Benefits

1. ✅ **Smooth transitions**: Video plays seamlessly from MediaCell to fullscreen
2. ✅ **No black screens**: Layer properly detached before reattachment
3. ✅ **Bidirectional**: Works both entering and exiting fullscreen
4. ✅ **Reliable**: Forces explicit cleanup, doesn't rely on SwiftUI timing
5. ✅ **Minimal overhead**: Simple integer increment

## Testing

### Test Scenario 1: Enter Fullscreen

1. Scroll to video in feed (MediaCell)
2. Video plays in MediaCell ✓
3. **Action**: Tap video to enter fullscreen
4. **Expected**: Video continues playing in fullscreen with controls
5. **Verify**: No black screen, video content visible

### Test Scenario 2: Exit Fullscreen

1. Video playing in fullscreen
2. **Action**: Exit fullscreen (swipe down or tap close)
3. **Expected**: Video returns to MediaCell view
4. **Verify**: Video continues playing in feed

### Test Scenario 3: Rapid Transitions

1. Enter fullscreen
2. Immediately exit
3. Immediately enter again
4. **Expected**: No black screens or glitches
5. **Verify**: Smooth transitions both directions

### Test Scenario 4: Multiple Videos

1. Play video A in MediaCell
2. Enter fullscreen
3. Exit fullscreen
4. Scroll to video B
5. Enter fullscreen for video B
6. **Expected**: Both transitions work correctly
7. **Verify**: No layer conflicts between different videos

### Debug Logs to Watch

When entering fullscreen:
```
DEBUG: [VIDEO MODE CHANGE] Entered full screen (mediaCell -> mediaBrowser), forced unmuted
DEBUG: [VIDEO MODE CHANGE] Incremented representableId to {N} to force layer detachment from MediaCell
DEBUG: [AVPlayerViewController] Created controller for player, will attach in update
DEBUG: [AVPlayerViewController] Updating with player: true
DEBUG: [AVPlayerViewController] Setting NEW player instance
DEBUG: [AVPlayerViewController] Player ready, triggering play() now that layer is attached
```

When exiting fullscreen:
```
DEBUG: [VIDEO MODE CHANGE] Exited full screen to MediaCell (mediaBrowser -> mediaCell), applied global mute state: true
DEBUG: [VIDEO MODE CHANGE] Incremented representableId to {N} for fresh MediaCell layer
```

## Files Modified

- `Sources/Features/MediaViews/SimpleVideoPlayer.swift`
  - Updated `onChange(of: mode)` handler (lines 319-351)

## Related Components

### VideoPlayerRepresentable

Used in **MediaCell** and **TweetDetail** modes:
- SwiftUI wrapper for UIKit's `VideoPlayer`
- Manages `AVPlayerLayer` lifecycle
- Simplified playback interface

### AVPlayerViewControllerRepresentable

Used in **MediaBrowser** (fullscreen) mode:
- SwiftUI wrapper for UIKit's `AVPlayerViewController`
- Native fullscreen experience
- Built-in playback controls
- Handles layer attachment in `updateUIViewController`

### Mode Transitions

The app has three display modes:
1. **mediaCell**: Video in feed/grid
2. **mediaBrowser**: Fullscreen video browser
3. **tweetDetail**: Single tweet detail view

Mode transitions trigger different player behaviors, layer management, and UI presentations.

## Common Pitfalls Avoided

### ❌ Don't: Rely on SwiftUI timing alone

```swift
// BAD: Hoping SwiftUI cleans up in time
if mode == .mediaBrowser {
    // No explicit cleanup
    // AVPlayerViewController might attach before MediaCell detaches
}
```

### ✅ Do: Force explicit cleanup

```swift
// GOOD: Force cleanup before transition
if mode == .mediaBrowser {
    self.representableId += 1  // Force detachment
    // Now AVPlayerViewController can safely attach
}
```

### ❌ Don't: Create new player instance

```swift
// BAD: Loses buffered content, causes flicker
if mode == .mediaBrowser {
    player = nil
    player = createNewPlayer()  // Restart from beginning
}
```

### ✅ Do: Reuse same player

```swift
// GOOD: Seamless transition, preserves playback state
if mode == .mediaBrowser {
    // Keep same player instance
    // Just manage layer attachment
}
```

## Performance Impact

**Negligible**:
- Integer increment: O(1)
- View recreation: Already optimized by SwiftUI
- No network requests
- No buffer reloading
- Seamless user experience

## Future Enhancements

Possible improvements:
1. **Preemptive detachment**: Detach slightly before mode change
2. **Layer pooling**: Reuse layers across transitions (complex)
3. **Explicit layer API**: Custom layer management (more control, more complexity)
4. **Transition animations**: Smooth visual transitions during mode changes

## Conclusion

This fix ensures that **AVPlayerLayer is properly detached and reattached** during mode transitions, preventing the black screen issue when entering fullscreen. The solution is lightweight, reliable, and works bidirectionally.

**Key Takeaway**: When sharing `AVPlayer` instances across different view types (VideoPlayer vs AVPlayerViewController), explicitly manage layer lifecycle to prevent attachment conflicts.
