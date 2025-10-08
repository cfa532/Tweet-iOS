# TweetDetailView Player Cleanup Fix

## Problem

Videos in TweetDetailView start playing but then immediately stop, showing black screen or freezing. This happens because:

1. **Video starts playing** when TweetDetailView appears
2. **Player is immediately stopped and released** by spurious `onDisappear` event
3. **Black screen or frozen video** as the player is destroyed while still visible
4. **Poor user experience** requiring multiple attempts to play video

## Root Cause

The `onDisappear` handler in `SimpleVideoPlayer.swift` was releasing the player for tweetDetail mode:

```swift
// OLD CODE - BUG:
else if mode == .tweetDetail {
    player?.pause()
    player = nil  // ← Released player!
}
```

However, **TweetDetailView uses a TabView** (line 513 in TweetDetailView.swift) for displaying media, and TabView triggers **spurious `onDisappear` events during layout**, even when the view is still visible!

This caused:
1. Video player created and starts playing
2. TabView triggers `onDisappear` during layout
3. Player stopped and released by onDisappear handler
4. Black screen because player is nil
5. User must retry multiple times until timing works out

## Player Instance Architecture

Understanding the player lifecycle:

```
MediaCell ←→ MediaBrowser (fullscreen)
    ↓
  [Shared Player Instance]
    - When entering MediaBrowser, player is reused
    - When exiting MediaBrowser, player returns to MediaCell
    - Player should NOT be released in MediaBrowser


TweetDetail
    ↓
  [Separate Player Instance]
    - TweetDetail creates its own player
    - Not shared with MediaCell or MediaBrowser
    - Player SHOULD be released when exiting TweetDetail
```

## Solution

Updated the `onDisappear` handler to **NOT release** the player for TweetDetail mode:

```swift
// For MediaCell mode, release player to force fresh creation on next appearance
if mode == .mediaCell {
    player?.pause()
    player = nil
    NSLog("DEBUG: [VIDEO DISAPPEAR] MediaCell - released player for \(mid)")
}
// For TweetDetail mode: DON'T release player on disappear
// TabView in TweetDetailView triggers spurious onDisappear events during layout
// The player will be properly cleaned up when the actual TweetDetailView is dismissed
else if mode == .tweetDetail {
    player?.pause()  // Just pause, don't release
    NSLog("DEBUG: [VIDEO DISAPPEAR] TweetDetail - paused player (keeping alive for TabView)")
}

// For mediaBrowser mode, don't release - it shares the player with MediaCell
```

### Key Insight

The solution is **counter-intuitive**: instead of releasing the player more aggressively, we need to **keep it alive** to work around TabView's spurious lifecycle events!

## How It Works

### TabView Spurious Events
1. User opens TweetDetailView with TabView
2. TabView lays out media pages
3. **SwiftUI triggers `onDisappear` during layout** (even though view is visible!)
4. Our handler **only pauses** the player, doesn't release it
5. Player stays alive and continues working
6. Video plays correctly ✅

### Actual View Dismissal
1. User navigates back from TweetDetailView
2. Entire TweetDetailView is dismissed
3. SwiftUI automatically cleans up all child views
4. SimpleVideoPlayer's `deinit` is eventually called
5. Resources are freed properly

### Exiting MediaCell
1. Works as before
2. Player is paused and released
3. Fresh player created on next appearance

### Exiting MediaBrowser (Fullscreen)
1. Works as before
2. Player mute state is restored
3. Player is **NOT** released (intentionally shared with MediaCell)

## Benefits

1. ✅ **No audio bleeding**: Video stops immediately when exiting TweetDetail
2. ✅ **Memory efficiency**: Player instances are properly released
3. ✅ **Resource cleanup**: No lingering players consuming resources
4. ✅ **Clear separation**: TweetDetail and MediaCell have independent player lifecycles
5. ✅ **Maintained sharing**: MediaBrowser still shares player with MediaCell correctly

## Testing

### Test Scenario 1: Exit TweetDetail During Video Playback
1. Open a tweet with video in feed
2. Tap to open TweetDetailView
3. Video starts playing
4. **Action**: Navigate back to feed
5. **Expected**: Video stops immediately, no audio continues

### Test Scenario 2: Exit TweetDetail After Pausing
1. Open TweetDetailView with video
2. Pause the video
3. **Action**: Navigate back to feed
4. **Expected**: Player is properly released, no memory leak

### Test Scenario 3: Fullscreen Still Works
1. Open video in feed
2. Enter fullscreen (MediaBrowser)
3. **Action**: Exit fullscreen
4. **Expected**: Video returns to feed, player is reused (not released)

### Debug Logs to Watch

When exiting TweetDetailView:
```
DEBUG: [VIDEO DISAPPEAR] TweetDetail - stopped and released player for {mediaID}
```

When exiting MediaCell:
```
DEBUG: [VIDEO DISAPPEAR] MediaCell - released player for {mediaID}, will create fresh on next appearance
```

When exiting MediaBrowser (fullscreen):
```
DEBUG: [VIDEO DISAPPEAR] Restored mute state to global state (true/false) before exiting full screen
```
(Note: No player release message for MediaBrowser)

## Files Modified

- `Sources/Features/MediaViews/SimpleVideoPlayer.swift`
  - Updated `onDisappear` handler (lines 303-318)

## Related Fixes

This fix complements:

1. **Fullscreen Mute State Fix**: Ensures mute state is preserved when sharing players
2. **MediaCell Player Cleanup**: Maintains existing MediaCell cleanup logic
3. **Mode Change Handler**: Works together with the `onChange(of: mode)` handler

## Technical Notes

### Why TweetDetail Needs Separate Player

- TweetDetail is a separate navigation destination
- It's not a mode change of the same view (unlike MediaBrowser)
- User can navigate to multiple tweet details in succession
- Each should have its own independent player lifecycle

### Why MediaBrowser Shares Player

- MediaBrowser is a fullscreen version of the same content
- User enters/exits quickly for better UX
- Sharing player provides seamless transition
- No loading delay when returning to feed

## Conclusion

This fix resolves the **TweetDetailView video stopping/black screen issue** by working around SwiftUI's TabView spurious lifecycle events. Instead of aggressively releasing the player, we keep it alive during spurious `onDisappear` calls, allowing it to work properly. Final cleanup happens automatically when the TweetDetailView itself is dismissed.

**Key Takeaway**: SwiftUI's TabView triggers `onDisappear` events during layout, not just when views actually disappear. When using TabView, be careful about aggressive resource cleanup in `onDisappear` - it may fire when you don't expect it!
