# TweetDetailView Player Cleanup Fix

## Problem

When exiting TweetDetailView, the video player was not being properly stopped and released. This caused:

1. **Video continues playing** in the background even after leaving the detail view
2. **Memory leaks** as the player instance remained in memory
3. **Audio bleeding** where video audio continues playing after navigation
4. **Resource waste** with unnecessary player instances

## Root Cause

The `onDisappear` handler in `SimpleVideoPlayer.swift` had different logic for different display modes:

- **MediaCell**: Player was paused and released ✅
- **MediaBrowser** (fullscreen): Player was kept alive (intentionally, as it shares with MediaCell) ✅
- **TweetDetail**: Player was **NOT** released ❌

The issue was in the comment: *"For other modes, don't release - VideoManager and stopAllVideos handle pausing"*

However, **TweetDetailView uses a separate player instance** that is NOT shared with MediaCell, so it should be properly stopped and released when exiting, just like MediaCell.

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

Updated the `onDisappear` handler to properly handle TweetDetail mode:

```swift
// For MediaCell and TweetDetail modes, release player to force fresh creation on next appearance
// This avoids AVPlayerLayer corruption from reusing the same AVPlayer instance
// TweetDetail uses a separate player instance that should be stopped when exiting
if mode == .mediaCell {
    player?.pause()
    player = nil
    NSLog("DEBUG: [VIDEO DISAPPEAR] MediaCell - released player for \(mid), will create fresh on next appearance")
} else if mode == .tweetDetail {
    player?.pause()
    player = nil
    NSLog("DEBUG: [VIDEO DISAPPEAR] TweetDetail - stopped and released player for \(mid)")
}

// For mediaBrowser mode, don't release - it shares the player with MediaCell
// VideoManager and stopAllVideos handle pausing for shared players
```

## How It Works

### Exiting TweetDetailView
1. User navigates back from TweetDetailView
2. `onDisappear` is triggered
3. Mode is detected as `.tweetDetail`
4. Player is paused: `player?.pause()`
5. Player is released: `player = nil`
6. Video stops immediately
7. Resources are freed

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

This fix ensures that **TweetDetailView properly cleans up its video player when exiting**, preventing audio bleeding, memory leaks, and resource waste. The player lifecycle is now correctly managed for all three display modes: MediaCell, MediaBrowser, and TweetDetail.
