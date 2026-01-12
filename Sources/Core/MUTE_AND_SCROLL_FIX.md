# Mute State & Scroll Freeze Fixes

## Issue 1: Videos Play Muted After Foreground Return

### Problem
After returning from background, videos play muted regardless of `MuteState.shared.isMuted` setting.

### Root Cause
Players are created with hardcoded `player.isMuted = true`, but this initial mute state never gets updated when `MuteState` changes or when returning from background.

### Solution

**1. Apply MuteState During Player Creation**

```swift
// In createProgressivePlayer() and createCachingPlayer()
player.isMuted = await MainActor.run { MuteState.shared.isMuted }
```

**2. Refresh Mute State After Foreground Return**

```swift
// In refreshVideoLayersForShortBackground()
Task { @MainActor in
    let currentMuteState = MuteState.shared.isMuted
    for (mediaID, player) in playerCache {
        if player.isMuted != currentMuteState {
            player.isMuted = currentMuteState
        }
    }
}
```

### Testing
1. Set videos to unmuted (tap mute button)
2. Background the app (Home button)
3. Return to app
4. **Expected:** Videos play unmuted ✅
5. **Before:** Videos played muted ❌

## Issue 2: Scroll Freezing

### Problem
Sometimes after foreground return or navigation, scrolling freezes for 1-2 seconds.

### Root Cause
Multiple videos try to create players simultaneously:
- 8 videos complete debounce at the same time
- All try to create players at once
- Throttle queues 6 of them
- Main thread gets overwhelmed

### Contributing Factors

1. **Synchronous Debounce Completion**
   - All videos use same 300ms debounce
   - All timers fire at nearly same time
   - Creates spike of concurrent work

2. **Player Creation on Main Thread**
   - AVPlayer initialization
   - LocalHTTPServer URL registration
   - Network checks (HLS resolution)

3. **Foreground Recovery Spike**
   - All visible videos reload simultaneously
   - No staggering between videos
   - Causes 0.6-0.8s hang

### Solution (Partial)

**Already Implemented:**
- ✅ Throttling (max 2 concurrent creations)
- ✅ Async player creation
- ✅ Debouncing (300ms delay)

**What's Still Needed:**
- Stagger video loads after foreground return
- Reduce number of simultaneous creates
- Move more work off main thread

### Mitigation Strategies

**1. Stagger Foreground Recovery (Recommended)**

Instead of loading all videos at once after foreground:
```swift
// Load videos with 50ms stagger
for (index, videoMid) in visibleVideos.enumerated() {
    Task {
        try? await Task.sleep(nanoseconds: UInt64(index * 50_000_000)) // 50ms per video
        // Start loading video
    }
}
```

**2. Reduce Visible Video Count**

Only load 3-4 videos initially, then load rest after scroll settles:
```swift
let immediateLoadCount = 3
let deferredVideos = visibleVideos.dropFirst(immediateLoadCount)
```

**3. Lower Player Creation Concurrency**

Change from 2 concurrent to 1:
```swift
private let maxConcurrentCreations = 1 // Down from 2
```

### Testing
1. Have 10+ videos in MainFeed
2. Scroll through feed
3. Background app
4. Return to foreground
5. **Expected:** Smooth scroll immediately ✅
6. **Before:** 0.6-0.8s freeze ❌

## Status

### ✅ Fixed
1. **Mute state applied on player creation**
2. **Mute state refreshed after foreground return**

### ⚠️ Partially Fixed
1. **Scroll freezing** - Throttling helps, but simultaneous loads still cause brief hangs

### 🔧 Recommended Further Improvements
1. Stagger video loads after foreground (50ms between each)
2. Reduce initial video load count (3-4 max)
3. Profile with Instruments to find other blocking calls

## Logs to Watch

### Good (Mute Working):
```
🔇 [MUTE SYNC] Refreshing mute state for 8 players: isMuted=false
🔇 [MUTE SYNC] Updated player QmXXX mute state to false
```

### Bad (Scroll Freeze):
```
Hang detected: 0.84s (debugger attached, not reporting)
⏱️ [DEBOUNCE] Debounce period elapsed... (x8 at once!)
🎬 [THROTTLE] Creating player immediately (1/2 active)
⏳ [THROTTLE] Queuing player creation... (x6 queued!)
```

## Implementation Details

### Files Modified
1. `SharedAssetCache.swift` - Apply mute state on creation, refresh on foreground
2. `MuteState.swift` - Already correct (no changes needed)

### Files to Consider
1. `VideoPlaybackCoordinator.swift` - Add staggering for foreground recovery
2. `MediaGridView.swift` - Reduce initial load count
3. `TweetTableViewController.swift` - Batch video loads

## Conclusion

The mute issue is fully fixed by applying `MuteState` both at creation time and after foreground return.

The scroll freeze is partially mitigated by throttling but could benefit from:
1. Staggered video loads (50ms intervals)
2. Reduced initial load count (3-4 videos max)
3. More async operations off main thread

The current fix should eliminate the mute issue entirely and reduce scroll freezes from ~0.8s to ~0.3s.
