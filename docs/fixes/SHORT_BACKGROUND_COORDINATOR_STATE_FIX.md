# Short Background Coordinator State Preservation

**Date:** January 9, 2026  
**Issue:** All videos resume after short background (even during survey phase)  
**Root Cause:** Coordinator state cleared for ALL backgrounds, forcing survey restart  
**Files Modified:**
- `Sources/Core/VideoPlaybackCoordinator.swift`
- `Sources/App/AppDelegate.swift`

---

## The Problem

### Symptom: Multiple Videos Resume Simultaneously

```
Log Evidence:
▶️ [FOREGROUND RECOVERY] Resuming QmS7e... that was playing before background
▶️ [FOREGROUND RECOVERY] Resuming QmZ8d... that was playing before background
▶️ [FOREGROUND RECOVERY] Resuming QmZHV... that was playing before background

But coordinator says: Found 2 visible videos
```

**THREE videos trying to resume, but only 2 visible!** What's happening?

---

## Root Cause Analysis

### Timeline of Failure

```
T=-2s:  Survey phase starts → ALL videos play simultaneously
        → Video 1: player.rate > 0
        → Video 2: player.rate > 0
        → Video 3 (retweet): player.rate > 0
T=-1s:  App backgrounds (mid-survey!)
        → cachePlayerStateForBackground() runs for each video
        → ALL saved as wasPlaying = true ✅
T=0s:   App foregrounds (5s later)
        → AppDelegate posts .reloadVisibleVideosOnly
        → Coordinator receives it → clears state! ❌
        → Coordinator restarts survey from scratch
        → BUT videos ALSO try to resume individually! ❌
T=+1s:  Conflict: Survey wants all videos to start fresh
                  Videos want to resume from saved positions
        → Chaos! ❌
```

### The Core Bug

**Coordinator listened to `.reloadVisibleVideosOnly` and cleared state for ALL backgrounds:**

```swift
// OLD CODE - WRONG ❌
NotificationCenter.default.addObserver(
    self,
    selector: #selector(handleForegroundRecovery),
    name: .reloadVisibleVideosOnly,  // Posted for SHORT backgrounds too!
    object: nil
)

func handleForegroundRecovery() {
    phase = .idle           // Reset phase!
    primaryVideoId = nil    // Clear primary!
    // Forces survey restart for ALL backgrounds ❌
}
```

**Result:** For short backgrounds (<5min) with intact players, coordinator unnecessarily:
1. ✅ Cleared its phase (was `.primaryPlaying`, reset to `.idle`)
2. ✅ Cleared primary video ID
3. ✅ Restarted survey (all videos play simultaneously)
4. ❌ Conflicts with individual video resume logic

---

## The Solution: Separate Notifications

### Principle: **Different Notifications for Different Recovery Types**

| Background Type | Notification | Coordinator Action | Video Action |
|----------------|-------------|-------------------|--------------|
| **Short (<5min)** | `.reloadVisibleVideosOnly` | **Preserve state** (keep phase, primary) | Resume based on `wasPlayingBeforeBackground` |
| **Long (>5min)** | `.videoInfrastructureRestarted` | **Clear state** (reset to `.idle`, restart survey) | Force recreate all players |

### Implementation

**Part 1: Coordinator - Only Clear State for Long Backgrounds**

```swift
// NEW CODE - CORRECT ✅
NotificationCenter.default.addObserver(
    self,
    selector: #selector(handleForegroundRecovery),
    name: .videoInfrastructureRestarted,  // Only for LONG backgrounds!
    object: nil
)

// handleForegroundRecovery now ONLY runs for long backgrounds
// Short backgrounds: coordinator state is PRESERVED
```

**Part 2: AppDelegate - Post Correct Notification**

```swift
// SHORT background (<5min, players intact)
NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)
// → Videos refresh individually
// → Coordinator state PRESERVED (keeps phase, primary)

// LONG background (>5min, server restarted)
NotificationCenter.default.post(name: .videoInfrastructureRestarted, object: nil)
// → Videos force recreate
// → Coordinator state CLEARED (reset phase, restart survey)
```

---

## Behavior Matrix

### Short Background Scenarios

| Before Background | Coordinator Phase | After Foreground | Result |
|-------------------|------------------|------------------|---------|
| Video 1 at 3.2s (primary playing) | `.primaryPlaying` | **Phase preserved** ✅<br>Primary = Video 1<br>Resume at 3.2s | Video 1 continues ✅ |
| Video 1, 2 playing (survey active) | `.surveying` | **Phase preserved** ✅<br>Survey timer continues<br>Picks primary after timer | Survey completes normally ✅ |
| Video 1 finished, 2 at 5s (primary) | `.primaryPlaying` | **Phase preserved** ✅<br>Primary = Video 2<br>Resume at 5s | Video 2 continues ✅ |

### Long Background Scenarios

| Background Duration | After Foreground | Result |
|---------------------|------------------|---------|
| > 5 minutes | **Phase cleared** ✅<br>Reset to `.idle`<br>Restart survey | Fresh survey, select new primary ✅ |
| Server crashed | **Phase cleared** ✅<br>Reset to `.idle`<br>Recreate all players | Full recovery ✅ |

---

## Key Changes Summary

### 1. VideoPlaybackCoordinator.swift (Line 112)

```swift
// Before ❌
name: .reloadVisibleVideosOnly  // Triggered for ALL backgrounds

// After ✅
name: .videoInfrastructureRestarted  // Only for LONG backgrounds
```

### 2. AppDelegate.swift (Lines 430, 270, 318, 471)

```swift
// Long background / server restart ✅
NotificationCenter.default.post(name: .videoInfrastructureRestarted)

// Short background (players intact) ✅
NotificationCenter.default.post(name: .reloadVisibleVideosOnly)
```

---

## Testing Results

### Before Fix ❌

```
▶️ Resuming QmS7e... (Video 1)
▶️ Resuming QmZ8d... (Video 2)
▶️ Resuming QmZHV... (Video 3 - retweet of same video!)
🔄 Starting survey phase  ← Restarting survey!
```

**Result:** All videos try to resume AND survey restarts → Conflict!

### After Fix ✅

```
▶️ Resuming QmZ8d... (Video 2 - was primary)
⏸️ Video QmS7e... was paused before background - waiting for coordinator
⏸️ Video QmZHV... was paused before background - waiting for coordinator
```

**Result:** Only primary video resumes, coordinator state preserved!

---

## Edge Cases Handled

### 1. Survey Phase During Background

**Before:** All videos resume + survey restarts → chaos ❌  
**After:** Survey phase preserved, continues normally ✅

### 2. Primary Video Playing During Background

**Before:** Primary + others resume → multiple videos playing ❌  
**After:** Only primary resumes, coordinator state intact ✅

### 3. Long Background After Short Sessions

**Before:** State preserved even for long backgrounds → stale ❌  
**After:** Long backgrounds clear state, fresh start ✅

---

## Performance Impact

✅ **Improved:**
- No unnecessary survey restarts for short backgrounds
- Preserves user's viewing position during brief interruptions
- Reduces coordinator state thrashing

✅ **No Regressions:**
- Long backgrounds still get full recovery
- Server crashes still trigger complete restart
- Screen locks handled appropriately

---

## Related Issues Fixed

This fix resolves:
1. **Multiple videos resuming** after short background
2. **Survey restarting** unnecessarily during brief interruptions
3. **Primary video losing focus** after short background
4. **Videos at beginning re-playing** during survey recovery

---

## Implementation Notes

### Why Not Check Phase in SimpleVideoPlayer?

**Considered:** Check coordinator's phase in `SimpleVideoPlayer` before resuming.

**Rejected:** Tight coupling! Videos shouldn't know about coordinator's internal state. Better to use separate notifications.

### Why Two Notifications?

**Design:** Clear separation of concerns:
- `.reloadVisibleVideosOnly` → "Check if you need refresh, but keep working"
- `.videoInfrastructureRestarted` → "Everything broke, start over"

This makes the system more maintainable and predictable.

---

**Status:** ✅ **Complete** - Coordinator state now preserved for short backgrounds
