# Full Screen Mute State Fix

## Problem

When exiting full screen mode (MediaBrowser) which shares the video player with MediaCell, the player's mute state was not being properly synchronized with the global `MuteState`. This caused videos to either remain unmuted or have incorrect mute state when transitioning back to the MediaCell view.

## Root Cause

The video player's mute state was only being updated in specific scenarios:
1. `onDisappear` - When the view disappears
2. `onReceive(MuteState.shared.$isMuted)` - When global mute state changes
3. `onChange(of: isMuted)` - When the local muted binding changes

However, there was **no handler for when the `mode` changes**, which is the primary way the view transitions between MediaBrowser (full screen) and MediaCell modes.

## Solution

Added an `onChange(of: mode)` handler that explicitly manages the player's mute state during mode transitions:

```swift
.onChange(of: mode) { oldMode, newMode in
    // When mode changes, apply appropriate mute state
    guard let player = player else { return }
    
    if newMode == .mediaBrowser {
        // Entering full screen - force unmute
        player.isMuted = false
        NSLog("DEBUG: [VIDEO MODE CHANGE] Entered full screen (\(oldMode) -> \(newMode)), forced unmuted")
    } else if newMode == .mediaCell && oldMode == .mediaBrowser {
        // Exiting full screen to MediaCell - apply global mute state
        player.isMuted = MuteState.shared.isMuted
        NSLog("DEBUG: [VIDEO MODE CHANGE] Exited full screen to MediaCell (\(oldMode) -> \(newMode)), applied global mute state: \(MuteState.shared.isMuted)")
    } else if newMode == .mediaCell {
        // Any other transition to MediaCell - apply global mute state
        player.isMuted = MuteState.shared.isMuted
        NSLog("DEBUG: [VIDEO MODE CHANGE] Transitioned to MediaCell (\(oldMode) -> \(newMode)), applied global mute state: \(MuteState.shared.isMuted)")
    }
}
```

## How It Works

### Entering Full Screen (MediaCell → MediaBrowser)
1. User taps video to enter full screen
2. Mode changes from `mediaCell` to `mediaBrowser`
3. `onChange(of: mode)` detects the change
4. Player is force unmuted: `player.isMuted = false`
5. User enjoys full screen video with audio

### Exiting Full Screen (MediaBrowser → MediaCell)
1. User exits full screen
2. Mode changes from `mediaBrowser` to `mediaCell`
3. `onChange(of: mode)` detects the change  
4. Player mute state is synchronized with global state: `player.isMuted = MuteState.shared.isMuted`
5. Video returns to feed with correct mute state

### Other Transitions
Any other transition to MediaCell mode also applies the global mute state to ensure consistency.

## Benefits

1. **Immediate Response**: Mute state updates happen immediately when mode changes, not waiting for view lifecycle events
2. **Explicit Control**: Clear, intentional handling of mute state during mode transitions
3. **Complements Existing Logic**: Works alongside existing `onDisappear` and `onReceive` handlers
4. **Debug Visibility**: Comprehensive logging for troubleshooting mode transitions

## Testing

### Test Scenario 1: Muted Feed → Full Screen → Feed
1. Set global mute to ON (videos muted in feed)
2. Tap a video to enter full screen
3. **Expected**: Video plays unmuted in full screen
4. Exit full screen
5. **Expected**: Video returns muted in feed

### Test Scenario 2: Unmuted Feed → Full Screen → Feed
1. Set global mute to OFF (videos unmuted in feed)
2. Tap a video to enter full screen
3. **Expected**: Video plays unmuted in full screen
4. Exit full screen
5. **Expected**: Video returns unmuted in feed

### Test Scenario 3: Toggle Mute While in Feed
1. Video playing in feed (muted)
2. Toggle global mute to OFF
3. **Expected**: Video immediately unmutes (handled by existing `onReceive`)
4. Video continues playing unmuted in feed

### Debug Logs to Watch

Look for these log messages when testing:

```
DEBUG: [VIDEO MODE CHANGE] Entered full screen (mediaCell -> mediaBrowser), forced unmuted
DEBUG: [VIDEO MODE CHANGE] Exited full screen to MediaCell (mediaBrowser -> mediaCell), applied global mute state: true
```

## Files Modified

- `Sources/Features/MediaViews/SimpleVideoPlayer.swift`
  - Added `onChange(of: mode)` handler at line 313-330

## Related Code

The fix complements existing mute state handling:

1. **onDisappear (line 275-284)**: Restores mute state when exiting full screen view
2. **onReceive (line 340-351)**: Syncs with global mute state changes
3. **onChange(of: isMuted) (line 331-339)**: Handles local mute state changes
4. **Mode-specific logic throughout**: Ensures full screen is always unmuted, MediaCell respects global state

## Conclusion

This fix ensures that when videos transition between MediaCell and MediaBrowser (full screen) modes, the player's mute state is **always correctly synchronized with the global MuteState**, providing a consistent and predictable user experience.
