# TweetDetailView Video Resume Fix

## Problem Identified

The logs showed that `SimpleVideoPlayer` (with `mode: .tweetDetail`) was saving state to its own cache:
```
DEBUG: [VIDEO BACKGROUND] Caching state for QmNw... - wasPlaying: true, time: 2.291512039
```

But this state was **not** being saved to `PersistentVideoStateManager`, which is what we need for state to survive player recreation.

## Root Cause

`TweetDetailView` uses `SimpleVideoPlayer` instead of `DetailVideoManager` directly, and `SimpleVideoPlayer` has its own separate state management that doesn't integrate with `PersistentVideoStateManager`.

## Solution Applied

### **Quick Fix: Bridge in DetailMediaCell**

Since we don't have direct access to modify `SimpleVideoPlayer`, we added a bridge in `DetailMediaCell` that:

1. **On Appear**: Checks for saved state and restores position
2. **On Disappear**: Saves current position to `PersistentVideoStateManager`

### Changes Made to `TweetDetailView.swift`:

**1. Added State Tracking:**
```swift
@State private var hasRestoredPosition = false // Prevent duplicate restoration
```

**2. Enhanced `onAppear`:**
- Checks `PersistentVideoStateManager` for saved state
- If found, waits 0.5s for player to be ready
- Seeks to saved position via `DetailVideoManager`
- Resumes playback if was playing before

**3. Added `onDisappear`:**
- Saves current playback state to `PersistentVideoStateManager`
- Captures time and playing status
- Ensures state persists for next appearance

## How It Works Now

### Screen Lock Flow:
```
1. Video playing at 2.5s
2. Screen locks → SimpleVideoPlayer saves to its cache
                → DetailMediaCell.onDisappear saves to PersistentVideoStateManager
3. Screen unlocks → DetailMediaCell.onAppear checks PersistentVideoStateManager
                  → Finds saved state: time=2.5s, wasPlaying=true
                  → Seeks to 2.5s and resumes ✅
```

### Navigation Flow:
```
1. Video playing at 5.0s in detail view
2. User navigates back → DetailMediaCell.onDisappear saves state
3. User returns to detail → DetailMediaCell.onAppear restores from 5.0s ✅
```

## Testing

After applying this fix, you should see these logs:

**On Screen Lock:**
```
💾 [DetailMediaCell] Saved state on disappear: time=2.5s, wasPlaying=true
```

**On Screen Unlock:**
```
🔄 [DetailMediaCell] Found saved state for {videoMid}: time=2.5s
✅ [DetailMediaCell] Restored position to 2.5s
▶️ [DetailMediaCell] Resumed playback
```

## Future Enhancement

**Proper Fix**: Modify `SimpleVideoPlayer` to integrate with `PersistentVideoStateManager` directly:

```swift
// In SimpleVideoPlayer.swift
func handleAppWillResignActive() {
    // Existing code...
    
    // ADD: Save to persistent storage
    if mode == .tweetDetail {
        PersistentVideoStateManager.shared.saveState(
            videoMid: mid,
            currentTime: currentTime,
            wasPlaying: wasPlaying,
            context: .detailView
        )
    }
}

func onAppear() {
    // Check for saved state
    if mode == .tweetDetail,
       let savedState = PersistentVideoStateManager.shared.getState(videoMid: mid) {
        // Restore position...
    }
}
```

This would eliminate the need for the bridge in `DetailMediaCell`.

## Known Limitations

1. **0.5s delay**: We wait 0.5s for player to be ready before seeking. This is necessary but could be improved with proper ready callbacks.

2. **Bridge approach**: This is a workaround. The proper fix is to integrate `PersistentVideoStateManager` directly into `SimpleVideoPlayer`.

3. **State duplication**: State is now saved in both `SimpleVideoPlayer`'s cache AND `PersistentVideoStateManager`. This is redundant but harmless.

## Verification Checklist

- [ ] Video in detail view saves position on screen lock
- [ ] Video in detail view resumes from saved position on unlock
- [ ] Video in detail view saves position when navigating away
- [ ] Video in detail view resumes from saved position when returning
- [ ] Multiple videos each remember their own position
- [ ] State expires after 5 minutes (as intended)

## Debug Commands

If resume still doesn't work, check logs for:

```bash
# State is being saved:
grep "💾 \[DetailMediaCell\] Saved state" console.log

# State is being found:
grep "🔄 \[DetailMediaCell\] Found saved state" console.log

# Position is being restored:
grep "✅ \[DetailMediaCell\] Restored position" console.log

# If missing, check:
grep "⚠️ \[VIDEO STATE\]" console.log  # Shows why state isn't restoring
```
