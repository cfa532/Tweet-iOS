# Short Background Recovery - Complete Rewrite

**Date:** January 9, 2026  
**Issue:** Multiple race conditions and stale state causing wrong videos to play after foreground  
**Files Modified:** 
- `Sources/Features/MediaViews/SimpleVideoPlayer.swift`
- `Sources/Core/VideoPlaybackCoordinator.swift`

---

## Problems Identified

### 1. **Multiple Overlapping Play Attempts with Stale State**

The previous code had THREE different attempts to play videos in `handleReloadVisibleVideosOnly`:

```swift
// Attempt 1: Play if coordinator wants (STALE FLAG!)
if coordinatorWantsToPlay && !needsSeekBeforePlay { 
    player.play()
}

// Attempt 2: Fallback to autoplay conditions
else if !needsSeekBeforePlay {
    checkPlaybackConditions(...)
}

// Attempt 3: Resume if was playing OR coordinator wants (DUPLICATE!)
if wasPlayingBeforeBackground || coordinatorWantsToPlay {
    player.play()
}
```

**The Core Problem:** All three checks used `coordinatorWantsToPlay`, which is **stale** (from before background)!

**Timeline of Failure:**
```
T=-5s:   Video 1 playing → coordinatorWantsToPlay[video1] = true
T=0s:    App backgrounds → wasPlayingBeforeBackground[video1] = true ✅
T=+5s:   App foregrounds
T=+5ms:  handleReloadVisibleVideosOnly() called
         → Checks coordinatorWantsToPlay[video1] = true (STALE!)
         → Plays Video 2 because IT also has stale coordinatorWantsToPlay! ❌
T=+200ms: Coordinator sends FRESH play commands (too late!)
```

### 2. **Finished Videos Not Resuming After Reset**

When a video finished and was reset to beginning:
- Old code: Tried to play immediately (caused race with seek)
- My first fix: Didn't play at all (waited for coordinator)
- Problem: Coordinator's play command arrived DURING seek, got ignored

### 3. **Videos Finishing During Survey Phase**

After foreground recovery, coordinator starts 2-second survey phase. If a video finishes during survey (short video or was already near end), the finish event was ignored!

```swift
// OLD CODE - WRONG
if phase == .primaryPlaying {  // Ignores .surveying!
    playNextVisibleVideo()
}
```

---

## Solution: Clear Separation of Concerns

### Principle: **One Source of Truth for Each Decision**

| Decision | Source of Truth | NOT |
|----------|----------------|-----|
| "Resume after background?" | `wasPlayingBeforeBackground` | ❌ `coordinatorWantsToPlay` (stale) |
| "Start new playback?" | Coordinator's FRESH command | ❌ `coordinatorWantsToPlay` (stale) |
| "Advance to next video?" | Video finish event | ❌ Survey timer (fixed duration) |

---

## Implementation

### Part 1: SimpleVideoPlayer - Intact Player Recovery

**File:** `Sources/Features/MediaViews/SimpleVideoPlayer.swift` (lines 2674-2736)

```swift
// SHORT BACKGROUND RECOVERY: Preserve and restore player state
// CRITICAL: coordinatorWantsToPlay is STALE (from before background).
// DO NOT use it! Only use wasPlayingBeforeBackground.
// Coordinator will send FRESH commands in 200ms.

// Step 1: Get saved state
let cachedState = VideoStateCache.shared.getCachedPlaybackInfo(for: self.mid)
let wasPlayingBeforeBackground = cachedState?.wasPlaying ?? false

// Step 2: Check if finished
var isFinishedVideo = false
if currentTime >= (duration - 0.5) {
    isFinishedVideo = true
    // Reset to beginning (async seek)
    player.seek(to: .zero) { completed in
        Task { @MainActor in
            // After seek: check if coordinator sent play command while seeking
            if self.coordinatorWantsToPlay && self.loadingState == .loaded {
                player.play()  // Play with FRESH coordinator flag
            }
        }
    }
}

// Step 3: Resume ONLY if actually playing before background
if !isFinishedVideo && wasPlayingBeforeBackground {
    player.play()  // Resume from saved position
} else if !isFinishedVideo {
    // Wait for coordinator's FRESH command
}
```

**Key Changes:**
1. ✅ **Single Play Decision:** Resume if `wasPlayingBeforeBackground`, else wait
2. ✅ **Ignore Stale Flags:** Never use `coordinatorWantsToPlay` for resume decision
3. ✅ **Reset Without Autoplay:** Finished videos reset but wait for coordinator
4. ✅ **Fresh State After Seek:** Check coordinator flag AFTER seek completes

### Part 2: SimpleVideoPlayer - Coordinator Command Handling

**File:** `Sources/Features/MediaViews/SimpleVideoPlayer.swift` (lines 1744-1764)

```swift
private func handleCoordinatorPlayCommand(notification: Notification) {
    // Set flag first (will be checked after seek if seeking)
    coordinatorWantsToPlay = true
    
    // If seeking, let seek completion handle playback
    if isSeekingToBeginning {
        print("Play command while seeking - will play after seek")
        return
    }
    
    // Otherwise play immediately if ready
    guard let player = player, loadingState == .loaded else { return }
    player.play()
}
```

**Key Changes:**
1. ✅ **Seek Protection:** Don't play during async seek
2. ✅ **Deferred Playback:** Flag set for seek completion to check
3. ✅ **Clear Logging:** Shows exact state when command received

### Part 3: VideoPlaybackCoordinator - Survey Phase Finish Handling

**File:** `Sources/Core/VideoPlaybackCoordinator.swift` (lines 560-580)

```swift
@objc private func handleVideoFinished(_ notification: Notification) {
    guard let videoMid = notification.userInfo?["videoMid"] as? String else { return }

    // If in survey phase, video finishing means end survey early
    if phase == .surveying {
        print("Video finished during survey - ending survey early")
        endSurveyPhase()  // Select primary now
        return
    }

    // If in primary phase, advance to next
    if phase == .primaryPlaying,
       let primaryId = primaryVideoId,
       primaryId.contains(videoMid) {
        playNextVisibleVideo()
    }
}
```

**Key Changes:**
1. ✅ **Handle Survey Finishes:** Videos can finish during 2s survey
2. ✅ **Immediate Transition:** End survey early, select primary
3. ✅ **Sequential Playback:** Ensures next video plays after finish

---

## Behavior Matrix

| Scenario | Before Background | After Foreground | Correct Behavior |
|----------|------------------|------------------|------------------|
| **Mid-playback** | Video 1 at 3.2s, playing | Resume at 3.2s ✅ | Uses `wasPlayingBeforeBackground = true` |
| **Paused** | Video 1 at 5.0s, paused | Stay paused, wait for coordinator ✅ | Ignores stale `coordinatorWantsToPlay` |
| **Finished** | Video 1 at 7.5s (end) | Reset to 0s, play when coordinator says ✅ | Seek completes, then checks fresh flag |
| **Short video during survey** | Video 1 finishes in 1s | Survey ends early, Video 2 becomes primary ✅ | `handleVideoFinished` during `.surveying` |

---

## Critical Bug Found and Fixed

### Issue: Finished Videos Saved as "Was Playing"

**Discovered:** January 9, 2026 (during testing)

**Problem:** When a video finished RIGHT BEFORE app backgrounded, `playbackState` was still `.playing` (finish handler hadn't run yet). This caused it to be saved as `wasPlayingBeforeBackground = true`, leading to incorrect resume attempts!

```
Timeline of Bug:
T=-1s:  Video finishes, position = 7.5s
T=-0.5s: Finish handler queued but not run yet
T=0s:   App backgrounds → cachePlayerStateForBackground()
        → playbackState == .playing (still!) ❌
        → Saved as wasPlaying = true (WRONG!)
T=+5s:  App foregrounds
        → Tries to resume at 7.5s (immediately finishes again!) ❌
```

**Fix:** Check actual position when saving state:

```swift
// Before (WRONG) ❌
let wasPlaying = player.rate > 0 || playbackState == .playing

// After (CORRECT) ✅
let isAtEndPosition = currentTime >= (duration - 0.5)
let wasPlaying = (player.rate > 0 || playbackState == .playing) && !isAtEndPosition
```

**Result:** Finished videos are now correctly saved as `wasPlaying = false`, preventing bogus resume attempts.

---

## Testing Checklist

### Short Background (5-18 seconds)

- [x] **Mid-playback resume:** Video at 3s → resumes at 3s ✅
- [x] **Paused stays paused:** Video paused → stays paused until coordinator ✅
- [x] **Finished resets:** Video at end → resets to 0s, plays on coordinator command ✅
- [x] **Sequential playback:** Video 1 finishes → Video 2 autoplays ✅
- [x] **Survey finish handling:** Short video finishes during survey → next video plays ✅
- [x] **Finished + playing:** Video 1 finished, Video 2 playing → only Video 2 resumes ✅

### Edge Cases

- [x] **Multiple finished videos:** Both videos at end → both reset, coordinator picks primary ✅
- [x] **Seek during coordinator command:** Command arrives while seeking → plays after seek ✅
- [x] **No visible videos:** App foregrounds to different screen → no crashes ✅
- [x] **Finish right before background:** Video finishes 0.5s before background → NOT saved as playing ✅

---

## Key Insights

### 1. **Stale State is Root of All Evil**

The fundamental problem was using flags (`coordinatorWantsToPlay`) that persist across app lifecycle transitions:

```swift
// BEFORE - WRONG
if coordinatorWantsToPlay {  // Set 5 seconds ago!
    player.play()
}

// AFTER - RIGHT
if wasPlayingBeforeBackground {  // Saved at background time
    player.play()
}
// Coordinator will send FRESH commands later
```

### 2. **Async Operations Need State Capture**

When you start an async operation (seek), capture what you need NOW:

```swift
// BEFORE - WRONG
player.seek(to: .zero) { completed in
    if self.coordinatorWantsToPlay {  // Stale!
        player.play()
    }
}

// AFTER - RIGHT
player.seek(to: .zero) { completed in
    // Check FRESH state after seek completes
    if self.coordinatorWantsToPlay {  // Might have been set during seek
        player.play()
    }
}
```

### 3. **Fixed Timers Miss Real Events**

Survey phase was 2 seconds fixed, but videos can finish in 1 second:

```swift
// BEFORE - WRONG
surveyTimer = Timer(timeInterval: 2.0) {
    endSurveyPhase()  // Even if video finished at 1s!
}

// AFTER - RIGHT
if phase == .surveying && videoFinished {
    endSurveyPhase()  // End immediately
}
```

---

## Performance Impact

✅ **Improved:**
- Eliminated 3 duplicate play attempts → Single clear decision
- Removed unnecessary `checkPlaybackConditions()` calls
- Survey ends early when appropriate (not waiting full 2s)

✅ **No Regressions:**
- Still uses `VideoStateCache` for position tracking
- Still respects visibility/detail view checks
- Still handles broken players separately

---

## Related Fixes

This fix supersedes and replaces:
- `VIDEO_SPINNER_NO_AUTOPLAY_AFTER_FOREGROUND.md` (stale coordinator flag)
- `SINGLETON_MANAGER_LIFECYCLE_FIX.md` (notification interference)
- All previous "band-aid" fixes for foreground recovery

---

## Lessons Learned

1. **Never use persistent flags for transient state**
   - `coordinatorWantsToPlay` should be cleared on background
   - Or better: Don't rely on it for resume decisions

2. **Separate "restore" from "start new" logic**
   - Restore = use saved state (`wasPlayingBeforeBackground`)
   - Start new = wait for explicit command

3. **Event-driven beats timer-driven**
   - React to video finish events, don't wait for timers
   - Fixed-duration timers can't handle variable-duration content

4. **Clear code beats clever code**
   - 3 overlapping play attempts → 1 clear decision path
   - Each check has a clear purpose and source of truth

---

**Status:** ✅ **Complete** - Tested all scenarios, ready for production
