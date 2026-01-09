# Video Spinner Stuck - No Autoplay After Foreground Fix

## Problem

After app returns from background, videos show loading spinners but **never autoplay**. Two distinct scenarios:

### Scenario 1: Player Recreated (Long Background)

Videos show spinner for a few seconds, spinner disappears, but video doesn't play. Videos remain paused with blank/black screen.

### Scenario 2: Player Preserved (Short Background)  

First video shows **permanent spinner** and never plays. When clicked, video immediately finishes (at end). Second video (partially visible) autoplays normally.

### User Reports

> "the app goes background for a few seconds, after back to foreground, the spinner covers the video a for few seconds, then nothing happens"

> "spinner keeps on the first video and it never played. The 2nd one, partially visible, autoplayed."

## Root Causes

### Scenario 1: Race Condition (Player Recreated)

**Race condition between coordinator play command and player readiness:**

### The Sequence

1. **App Returns from Background:**
   ```
   handleReloadVisibleVideosOnly() called
   → Player recreated (loadingState = .loading)
   → Spinner shows ✅
   ```

2. **Coordinator Sends Play Command:**
   ```
   VideoPlaybackCoordinator.startSurveyPhase()
   → Posts .shouldPlayVideo notification
   → handleCoordinatorPlayCommand() receives it
   → Sets coordinatorWantsToPlay = true ✅
   → Checks: loadingState == .loaded? NO (still loading)
   → Returns early ❌
   ```

3. **Player Finishes Loading:**
   ```
   Data loads from disk cache (fast)
   → loadingState = .loaded ✅
   → Spinner disappears ✅
   → But nobody tells player to start! ❌
   ```

4. **Buffer Observer Doesn't Fire:**
   ```
   Data already cached → loads instantly
   → Buffer observer doesn't fire (no new data event)
   → coordinatorWantsToPlay never checked ❌
   → Video stays paused ❌
   ```

### The Code (Before Fix)

**SimpleVideoPlayer.swift - handleCoordinatorPlayCommand (line 1756):**
```swift
// Set flag to play when ready
coordinatorWantsToPlay = true

// Only play if player is ready
guard let player = player, loadingState == .loaded else {
    return  // ← Returns early if still loading!
}
```

**The delayed check (line 2629) checks wrong condition:**
```swift
// If video should be playing, ensure it starts
if self.currentAutoPlay && self.loadingState.isLoaded {  // ← Wrong!
    // For MediaCell, currentAutoPlay might be false
    // Coordinator controls playback, not autoPlay flag
    self.checkPlaybackConditions(autoPlay: true, isVisible: true)
}
```

**Problem:** `currentAutoPlay` is separate from `coordinatorWantsToPlay`. For MediaCell videos, coordinator controls playback via notifications, not the autoPlay flag.

### Scenario 2: Stale Position (Player Preserved)

**Short backgrounds preserve players WITH their playback positions:**

### The Sequence

1. **Before Background:**
   ```
   Video playing near end (e.g., 28s of 30s)
   → App backgrounds
   → Player preserved ✅
   → Position saved: 28s ✅
   ```

2. **App Returns (135s = 2.25 min - Short Background):**
   ```
   AppDelegate: "KEEPING PLAYERS INTACT"
   → Players preserved, positions intact
   → Video still at 28s (near end)
   ```

3. **Coordinator Sends Play Command:**
   ```
   VideoOrchestrator: "Play first video!"
   → Video at 28s tries to play
   → Immediately finishes (only 2s left)
   → Shows spinner but stays finished ❌
   ```

4. **Result:**
   ```
   First video: Permanent spinner (finished)
   Second video: Autoplays normally ✅
   ```

### The Code (Before Fix)

**SimpleVideoPlayer.swift - handleReloadVisibleVideosOnly (line 2648):**
```swift
} else if player != nil {
    // Player is intact; re-evaluate autoplay conditions.
    
    // Check if loading state is stuck
    if loadingState.isLoading ... {
        loadingState = .loaded
    }
    
    // ❌ MISSING: Check if video is finished!
    // If video at end, it won't play even when coordinator commands it
    
    checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
    // ❌ Wrong flag! Uses currentAutoPlay instead of coordinatorWantsToPlay
}
```

**Problem:** Preserved players keep their positions. If video was near end before background, it stays near end. Coordinator can't make it play because it's already finished.

## Solution

### Fix 1: Check `coordinatorWantsToPlay` for Recreated Players

**Line 2628-2643 (player recreated path):**
```swift
// CRITICAL: Check if coordinator commanded playback while loading
// This handles the case where play command arrives before player is ready
if self.mode == .mediaCell && self.coordinatorWantsToPlay && self.loadingState.isLoaded && player.rate == 0 {
    print("▶️ [FOREGROUND RECOVERY] Playing video as coordinator requested (delayed)")
    player.isMuted = MuteState.shared.isMuted
    player.play()
    self.playbackState = .playing
} else if self.currentAutoPlay && self.loadingState.isLoaded {
    // Fallback: If video should be playing, ensure it starts
    let noOverlaysActive = !self.isCoveredByOverlay
    let noDetailViewActive = !DetailVideoManager.shared.isDetailViewActive()

    if noOverlaysActive && noDetailViewActive {
        self.checkPlaybackConditions(autoPlay: true, isVisible: true)
    }
}
```

### Fix 2: Reset Finished Videos & Wait for Seek Completion

**Line 2668-2718 (player preserved path):**

**Critical Issue:** `player.seek()` is **asynchronous**. If we call `play()` immediately after `seek()`, the player is still at the old position (7.5s), causing immediate finish again!

**Solution:** Use seek completion callback to play only after seek completes.

```swift
// CRITICAL FIX: Reset finished videos to beginning after foreground recovery
var needsSeekBeforePlay = false
if let player = player, let item = player.currentItem, item.status == .readyToPlay {
    let duration = item.duration.seconds
    let currentTime = player.currentTime().seconds
    
    // Check if video is finished (within 0.5s of end)
    if !duration.isNaN && !duration.isInfinite && duration > 0 {
        let isFinished = currentTime >= (duration - 0.5)
        if isFinished {
            print("🔄 [FOREGROUND RECOVERY] Resetting finished video from \(currentTime)s to beginning")
            needsSeekBeforePlay = true
            
            // CRITICAL: Seek is async - wait for completion before playing
            let shouldPlay = mode == .mediaCell && coordinatorWantsToPlay && loadingState == .loaded
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
                guard completed, let self = self else { return }
                Task { @MainActor in
                    self.playbackState = .notStarted  // Clear after seek completes
                    
                    // Now play if coordinator wants to
                    if shouldPlay, let player = self.player, player.rate == 0 {
                        print("▶️ [FOREGROUND RECOVERY] Playing video after seek completion")
                        player.play()
                        self.playbackState = .playing
                    }
                }
            }
        }
    }
}

// DON'T play immediately if we're seeking - wait for seek completion
if !needsSeekBeforePlay && coordinatorWantsToPlay {
    player.play()
}

// CRITICAL FIX: For MediaCell, check if coordinator wants to play
// Coordinator sends play commands during survey phase, but if player is intact,
// we need to explicitly check the flag since checkPlaybackConditions uses currentAutoPlay
if mode == .mediaCell && coordinatorWantsToPlay && loadingState == .loaded {
    if let player = player, player.rate == 0 {
        print("▶️ [FOREGROUND RECOVERY] Playing intact video as coordinator requested")
        player.isMuted = MuteState.shared.isMuted
        player.play()
        playbackState = .playing
    }
} else {
    // Fallback: normal playback condition check
    checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
}
```

### Fix 3: Check Coordinator Flag for Non-Seeking Videos

**Line 2700-2713:**
```swift
// CRITICAL: For MediaCell, check if coordinator wants to play
// DON'T play immediately if we're seeking - wait for seek completion
if !needsSeekBeforePlay && mode == .mediaCell && coordinatorWantsToPlay && loadingState == .loaded {
    if let player = player, player.rate == 0 {
        print("▶️ [FOREGROUND RECOVERY] Playing intact video as coordinator requested")
        player.play()
        playbackState = .playing
    }
}
```

**Why the `needsSeekBeforePlay` check?**
- Prevents calling `play()` while async seek is in progress
- Seek completion callback will handle playback after seek finishes
- Avoids race condition: play() → still at old position → immediate finish

## Why This Works

### Before Fix - Scenario 1 (Player Recreated)

```
Foreground Recovery
    └─ Player recreated (loading)
        └─ Coordinator: "Play!" → coordinatorWantsToPlay = true
            └─ Check: loaded? NO → return early ❌
                └─ Player loads from cache (instant)
                    └─ Delayed check runs
                        └─ Check: currentAutoPlay? NO (coordinator controls it) ❌
                            └─ Video stays paused ❌
```

### Before Fix - Scenario 2 (Player Preserved)

```
Foreground Recovery (135s - Short Background)
    └─ Player preserved (position: 28s of 30s)
        └─ Coordinator: "Play!" → coordinatorWantsToPlay = true
            └─ Player intact path runs
                └─ Check: currentAutoPlay? NO ❌
                    └─ checkPlaybackConditions() runs but no effect
                        └─ Video at 28s tries to play
                            └─ Immediately finishes (2s left)
                                └─ Shows permanent spinner ❌
```

### After Fix - Both Scenarios

```
Foreground Recovery
    ├─ Path A: Player Recreated
    │   └─ Player recreated (loading)
    │       └─ Coordinator: "Play!" → coordinatorWantsToPlay = true ✅
    │           └─ Check: loaded? NO → return early (expected)
    │               └─ Player loads from cache (instant)
    │                   └─ Delayed check runs
    │                       └─ Check: coordinatorWantsToPlay? YES! ✅
    │                           └─ player.play() ✅
    │                               └─ Video plays! ✅
    │
    └─ Path B: Player Preserved
        └─ Player preserved (position: 28s of 30s)
            └─ Check: Is video finished? YES
                └─ Seek to beginning ✅
                    └─ Clear finished state ✅
            └─ Coordinator: "Play!" → coordinatorWantsToPlay = true ✅
                └─ Check: coordinatorWantsToPlay? YES! ✅
                    └─ player.play() from beginning ✅
                        └─ Video plays! ✅
```

## Key Insights

### 1. Two Separate Playback Control Mechanisms

**autoPlay flag:**
- Used for non-MediaCell modes (tweetDetail, mediaBrowser)
- Direct autoplay without coordinator

**coordinatorWantsToPlay flag:**
- Used for MediaCell mode
- Controlled by VideoPlaybackCoordinator via notifications
- Enables survey phase and sequential playback

### 2. Buffer Observer Not Reliable After Recovery

The buffer observer (line 4122) already checks `coordinatorWantsToPlay`:
```swift
if coordinatorWantsToPlay && player.rate == 0 {
    player.play()
}
```

**But** after foreground recovery with cached data:
- Data loads instantly from disk cache
- Buffer observer might not fire (no buffer events)
- So the check never happens
- **Solution:** Also check in delayed recovery handler

### 3. Delayed Check is the Right Place

The delayed check in `handleReloadVisibleVideosOnly` (lines 2597-2640):
- Waits for player to be ready (up to 3 seconds)
- Checks if loading state is stuck
- **Now also checks** `coordinatorWantsToPlay`
- Perfect place to catch this edge case

## Testing

### Test Case 1: Short Background - Player Recreated

1. Open app, videos autoplay
2. Background app for 12 seconds
3. Return to foreground
4. **Expected:**
   - Spinner shows briefly (0.5-1s) ✅
   - Spinner disappears ✅
   - Video autoplays immediately ✅
5. **Log:**
   ```
   ▶️ [FOREGROUND RECOVERY] Playing video as coordinator requested (delayed)
   ```

### Test Case 2: Short Background - Player Preserved with Finished Video

1. Open app, let video play near end (28s of 30s)
2. Background app for 135 seconds
3. Return to foreground
4. **Expected:**
   - Video resets to beginning ✅
   - Spinner shows briefly ✅
   - Video autoplays from start ✅
5. **Logs:**
   ```
   🔄 [FOREGROUND RECOVERY] Resetting finished video QmZHV... from 28.5s to beginning
   ▶️ [FOREGROUND RECOVERY] Playing intact video as coordinator requested
   ```

### Test Case 3: Long Background

1. Open app, videos autoplay
2. Background app for 10 minutes
3. Return to foreground
4. **Expected:**
   - Loading overlay shows during server restart
   - Spinners show briefly
   - Videos autoplay after infrastructure ready
5. **Result:** Same fix applies (Path A) ✅

### Test Case 4: Video at End When Backgrounded

1. Let video play to completion (or near completion)
2. Background app
3. Return to foreground
4. **Expected:** Video resets to beginning and autoplays ✅
5. **Before Fix:** Permanent spinner, video stays finished ❌

## Performance Impact

**Minimal:**
- Only adds one extra condition check in existing delayed handler
- No additional delays or timers
- Same 0.1s polling loop (already existed)
- Fixes stuck videos without adding overhead

## Alternative Approaches Considered

### 1. Remove Guard from handleCoordinatorPlayCommand
```swift
// Option: Always set flag, even if not ready
coordinatorWantsToPlay = true
// Don't check loadingState here
```
**Rejected:** Would lose the immediate play optimization when player is ready

### 2. Always Fire Buffer Observer
```swift
// Option: Force buffer observer to fire after cache load
```
**Rejected:** Fragile, might cause duplicate play commands

### 3. Use Notification for Player Ready
```swift
// Option: Post notification when player ready, check flag then
```
**Rejected:** Over-engineered, delayed check already exists

## Related Issues Fixed

This also fixes:
- Videos stuck with black screen after foreground recovery
- Sequential playback not resuming after background
- Survey phase starting but no videos playing
- Coordinator play commands being lost during loading

## Additional Issue: Singleton Managers Interfering

### Problem

Even after the main fix, singleton managers (`FullScreenVideoManager`, `DetailVideoManager`) were posting `reloadVisibleVideosOnly` during delayed health checks (1s after foreground return). This caused MediaCell videos to clear and recreate, showing spinners again.

**Why:** Singleton managers had **stale players** from previous fullscreen/detail view usage. When they detected these were broken, they posted `reloadVisibleVideosOnly` globally, affecting all videos including MediaCell videos.

### Solution

**Sources/Core/SingletonVideoManagers.swift:**

Remove `reloadVisibleVideosOnly` notification from singleton manager health checks:

```swift
// Before:
if isPlayerBroken() {
    clearBrokenPlayer()
    NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)  // ❌ Affects all videos!
}

// After:
if isPlayerBroken() {
    clearBrokenPlayer()
    // Don't post notification - this would interfere with MediaCell videos
    // Singleton managers only manage fullscreen/detail videos, not MediaCell videos
}
```

**Why this works:**
- Singleton managers only manage fullscreen/detail videos
- MediaCell videos are managed by `VideoPlaybackCoordinator`
- When singleton managers clear stale players, they shouldn't trigger MediaCell video reloads
- If fullscreen/detail view is actually active, it has its own recovery logic

## Files Changed

1. **Sources/Features/MediaViews/SimpleVideoPlayer.swift**
   - Updated `handleReloadVisibleVideosOnly` delayed check (line 2628-2643)
   - Reset finished videos to beginning (line 2666-2681)
   - Check `coordinatorWantsToPlay` for preserved players (line 2690-2703)
   - Include coordinator flag in resume logic (line 2712)

2. **Sources/Core/SingletonVideoManagers.swift**
   - Removed `reloadVisibleVideosOnly` notification from health checks (line 207, 232)
   - Prevents singleton managers from interfering with MediaCell videos

## Date

January 9, 2026
