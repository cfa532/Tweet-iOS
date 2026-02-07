# Coordinator Owns MediaCell Playback (Architectural Principle)

**Date:** January 9, 2026  
**Issue:** MediaCell videos resume independently, conflicting with coordinator's decisions  
**Solution:** MediaCell videos ALWAYS wait for coordinator commands  
**Files Modified:** `Sources/Features/MediaViews/SimpleVideoPlayer.swift`

---

## The Problem: Competing Playback Decisions

### What Went Wrong

```
Coordinator:       "Resume primary video (QmZHV)"
                   → Sends play command to QmZHV

SimpleVideoPlayer: "I was playing before background!"
                   → QmS7e resumes
                   → QmZ8d resumes

Result: THREE videos trying to play! ❌
        Primary (QmZHV) wins, others stuck with spinner
```

**Log evidence:**
```
🔄 [VideoOrchestrator] Resuming primary video after foreground
▶️ [FOREGROUND RECOVERY] Resuming QmS7e... that was playing before background
▶️ [FOREGROUND RECOVERY] Resuming QmZ8d... that was playing before background
🎬 [VIDEO FINISHED] Video finished playing for QmZHV... ← Primary!
```

---

## Root Cause: Dual Decision-Making

### The Architecture Conflict

```
MediaCell Videos:
├─ Managed by VideoPlaybackCoordinator
│  └─ Decides: Which video plays, when, for how long
│
└─ Also has individual state (wasPlayingBeforeBackground)
   └─ Decides: "I should resume!" ❌

→ CONFLICT: Two decision-makers!
```

### Why This Happened

During **survey phase**, ALL visible videos play simultaneously:
```
T=-2s: Survey starts
       → Video 1: playing → saves wasPlaying = true
       → Video 2: playing → saves wasPlaying = true
       → Video 3: playing → saves wasPlaying = true

T=0s:  Survey ends, Video 3 becomes primary
T=+5s: App backgrounds
T=+12s: App foregrounds

Coordinator: "Resume primary (Video 3)"
Videos 1,2,3: "We were all playing!" → All try to resume! ❌
```

---

## The Solution: Single Source of Truth

### Architectural Principle

```
For MediaCell videos:
  Coordinator = SOLE decision-maker
  SimpleVideoPlayer = Executor (waits for commands)

For Detail/Fullscreen videos:
  No coordinator
  SimpleVideoPlayer = Decision-maker (uses wasPlayingBeforeBackground)
```

### Implementation

```swift
// Step 3 of handleReloadVisibleVideosOnly (intact player path)

if mode == .mediaCell {
    // MediaCell: Coordinator owns playback
    // NEVER resume independently
    // Wait for coordinator command (~200ms)
    print("⏸️ [FOREGROUND RECOVERY] MediaCell waiting for coordinator")
    
} else if !isFinishedVideo && wasPlayingBeforeBackground {
    // Detail/Fullscreen: No coordinator, resume independently
    player.play()
}
```

---

## Behavior Matrix

| Video Mode | Coordinator | Before Background | After Foreground |
|------------|-------------|-------------------|------------------|
| **MediaCell** | Active | Was primary | Wait for coordinator → Resume ✅ |
| **MediaCell** | Active | Was in survey | Wait for coordinator → Don't play ✅ |
| **MediaCell** | Active | Was paused | Wait for coordinator → Don't play ✅ |
| **Detail** | None | Was playing | Resume independently ✅ |
| **Fullscreen** | None | Was playing | Resume independently ✅ |

---

## Example Flow

### MediaCell (Coordinator Managed)

```
Before background:  Survey phase, 3 videos playing
                    Survey ends → Video 3 becomes primary
                    
App backgrounds:    Video 1: saves wasPlaying = true
                    Video 2: saves wasPlaying = true  
                    Video 3: saves wasPlaying = true
                    
App foregrounds:    Coordinator preserves state
                    → Finds Video 3 (primary by videoMid)
                    → Sends play command to Video 3 ONLY
                    
SimpleVideoPlayer:  Video 1: "MediaCell, waiting for coordinator" ⏸️
                    Video 2: "MediaCell, waiting for coordinator" ⏸️
                    Video 3: Receives play command → plays! ▶️
                    
Result: Only Video 3 plays (correct!) ✅
```

### Detail View (No Coordinator)

```
Before background:  Detail video playing at 3.2s

App backgrounds:    Saves wasPlaying = true

App foregrounds:    No coordinator
                    
SimpleVideoPlayer:  "Detail mode, was playing, resuming"
                    → Resumes at 3.2s ▶️
                    
Result: Video continues (correct!) ✅
```

---

## Why This Architecture

### Separation of Concerns

```
Coordinator:
  ✓ Manages RELATIONSHIPS between videos
    - Survey phase (play all)
    - Primary selection (play one)
    - Sequential playback (advance to next)
  
SimpleVideoPlayer:
  ✓ Manages INDIVIDUAL video state
    - Loading, buffering
    - Position tracking
    - Player lifecycle
  
❌ DON'T: Let SimpleVideoPlayer make playback decisions for MediaCell
          (conflicts with coordinator!)
```

### Single Responsibility Principle

```swift
// BEFORE (WRONG): SimpleVideoPlayer decides ❌
if wasPlayingBeforeBackground {
    player.play()  // Conflicts with coordinator!
}

// AFTER (CORRECT): Coordinator decides ✅
// Coordinator: "Play Video 3"
NotificationCenter.post(.shouldPlayVideo, videoMid: "QmZHV")

// SimpleVideoPlayer: "Received command, executing"
func handleCoordinatorPlayCommand() {
    player.play()
}
```

---

## Edge Cases Handled

### 1. All Videos Were Playing (Survey Phase)

```
Before: Survey phase, 3 videos playing
After:  Only primary resumes ✅
        (other 2 wait for coordinator, don't get command)
```

### 2. Primary Changed During Background

```
Before: Video 1 primary
Background: Tweets refresh, Video 1 replaced by Video 4
After: Coordinator finds Video 1 by videoMid
       → Not found
       → Restarts survey with visible videos ✅
```

### 3. Detail View Playing

```
Before: Detail video playing (no coordinator)
After:  Video resumes independently ✅
        (Detail mode uses wasPlayingBeforeBackground)
```

---

## Performance Impact

### Before (Competing Decisions)

```
3 videos try to resume:
- Video 1: Tries to play → Coordinator doesn't approve → Spinner stuck ❌
- Video 2: Tries to play → Coordinator doesn't approve → Spinner stuck ❌
- Video 3: Tries to play → Coordinator approves → Plays ✅

User sees: 2 spinners, 1 playing video (bad UX)
```

### After (Coordinator Owns)

```
Only primary tries to play:
- Video 1: Waits → No command → Stays paused ✅
- Video 2: Waits → No command → Stays paused ✅
- Video 3: Waits → Receives command → Plays ✅

User sees: 1 playing video (clean UX!)
```

---

## Testing Strategy

```swift
// Test 1: Primary resumes, others don't
testPrimaryResumesOthersWait() {
    // Setup: Survey phase, 3 videos playing
    // Action: Background, select primary, foreground
    // Assert: Only primary plays, others paused
}

// Test 2: Detail video resumes independently
testDetailVideoResumesIndependently() {
    // Setup: Detail video playing
    // Action: Background, foreground
    // Assert: Detail video resumes (no coordinator)
}

// Test 3: Coordinator changes primary
testCoordinatorSelectsNewPrimary() {
    // Setup: Video 1 primary
    // Action: Background, coordinator selects Video 2
    // Assert: Video 2 plays, Video 1 doesn't
}
```

---

## Related Principles

### 1. Command Pattern

```
Coordinator = Commander (issues commands)
SimpleVideoPlayer = Executor (executes commands)

Commands:
- .shouldPlayVideo
- .shouldPauseVideo
- .shouldStopVideo
```

### 2. Hollywood Principle

```
"Don't call us, we'll call you"

❌ SimpleVideoPlayer: "I should play now!"
✅ Coordinator: "Play now!" → SimpleVideoPlayer executes
```

### 3. Single Source of Truth

```
For MediaCell playback decisions:
  ❌ Multiple sources: Coordinator + SimpleVideoPlayer
  ✅ Single source: Coordinator only
```

---

## Migration Notes

### Breaking Changes

None! External API unchanged.

### Behavior Changes

```
Before: MediaCell videos could resume independently
After:  MediaCell videos ONLY play via coordinator commands

Impact: Better! No more conflicts, cleaner UX
```

---

## Lessons Learned

### 1. Beware of Dual Ownership

```
When two components can make the same decision → conflict!
Solution: Designate ONE owner
```

### 2. Context Matters

```
Same component (SimpleVideoPlayer) behaves differently based on context:
- MediaCell: Managed (wait for coordinator)
- Detail: Autonomous (decide independently)
```

### 3. State vs Commands

```
❌ State-based: "I was playing, so I resume"
✅ Command-based: "Coordinator says play, so I play"
```

---

**Status:** ✅ **Complete** - Coordinator is sole decision-maker for MediaCell playback!
