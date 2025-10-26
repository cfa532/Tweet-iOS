# Video Background Detachment Optimization

**Date:** October 26, 2025  
**Status:** ✅ **IMPLEMENTED**  
**Priority:** 🟢 **UX Improvement**

---

## Problem

Users experienced an unnecessary black screen flash when returning from screen lock or app backgrounding. This occurred because the video system was:

1. **Going to background:** Hiding the video view by setting `isPlayerDetached = true`
2. **Coming to foreground:** Re-showing the video view and refreshing the layer

This detachment → reattachment cycle caused a visible black screen transition that degraded user experience.

---

## Root Cause

### Previous Implementation

**File:** `Sources/Features/MediaViews/SimpleVideoPlayer.swift`

```swift
// OLD APPROACH - Caused black screen flash

// Going to background:
private func handleWillResignActive() {
    detachPlayerForBackground()  // Sets isPlayerDetached = true
}

private func detachPlayerForBackground() {
    // ... cache state ...
    player.pause()
    isPlayerDetached = true  // ← HIDES THE VIDEO VIEW
}

// View rendering:
if let player = player {
    if !isPlayerDetached {  // ← Only show if not detached
        // Video player view
    }
}

// Coming to foreground:
private func recoverFromBackground() {
    isPlayerDetached = false  // ← RE-SHOWS THE VIDEO VIEW
    // ... refresh layer ...
}
```

### What Users Saw

1. **Before lock:** Video playing normally
2. **Lock screen:** Last frame visible (iOS pauses rendering)
3. **Unlock:** 
   - Video view hidden → **BLACK SCREEN** (isPlayerDetached = true removed view)
   - Layer refresh happens
   - Video view re-shown → **FLASH** as video reappears
4. **After recovery:** Video playing normally

The black screen flash was **completely unnecessary** - we were hiding the view ourselves, not iOS!

---

## Solution: Skip Detachment, Keep View Visible

### New Implementation

The optimization removes the detachment step entirely:

```swift
// NEW APPROACH - No black screen flash

// Going to background:
private func handleWillResignActive() {
    cacheStateForBackground()  // Does NOT hide the view
}

private func cacheStateForBackground() {
    // Cache state for restoration
    VideoStateCache.shared.cacheVideoState(...)
    
    // Pause to save resources
    player.pause()
    
    // DON'T set isPlayerDetached = true
    // View stays visible with last frame
}

// View rendering:
if let player = player {
    // ALWAYS visible - no conditional hiding
    // Video player view
}

// Coming to foreground:
private func recoverFromBackground() {
    // No need to set isPlayerDetached = false
    // View was never hidden
    // Just refresh layer (which we were already doing)
    representableId += 1
}
```

### What Users See Now

1. **Before lock:** Video playing normally
2. **Lock screen:** Last frame visible (iOS pauses rendering)
3. **Unlock:** 
   - Last frame **STILL VISIBLE** (view never hidden)
   - Layer refresh happens seamlessly
   - Video resumes playing
4. **After recovery:** Video playing normally

**No black screen flash!** The transition is smooth because the video view stays visible throughout the entire lifecycle.

---

## Technical Details

### Changes Made

**File:** `Sources/Features/MediaViews/SimpleVideoPlayer.swift`

#### 1. Renamed and Simplified Background Handler

```swift
// Line 570-583
private func handleWillResignActive() {
    hasRecoveredThisCycle = false
    didEnterBackground = false
    
    // Cache state but DON'T detach player view
    // This keeps the last frame visible instead of showing black screen
    cacheStateForBackground()  // ← NEW: Doesn't hide view
}
```

#### 2. New Cache Method (Doesn't Hide View)

```swift
// Lines 1727-1750
private func cacheStateForBackground() {
    guard let player = player else { return }
    
    let wasPlaying = player.rate > 0
    let currentTime = player.currentTime()
    
    // Cache the state for restoration
    VideoStateCache.shared.cacheVideoState(
        for: mid,
        player: player,
        time: currentTime,
        wasPlaying: wasPlaying,
        originalMuteState: mode == .mediaCell ? isMuted : MuteState.shared.isMuted
    )
    
    // Pause the player to save resources
    // But DON'T hide the view - keep last frame visible to avoid black screen
    player.pause()
    
    print("DEBUG: [VIDEO CACHE STATE] Cached state for \(mid) - wasPlaying: \(wasPlaying), time: \(CMTimeGetSeconds(currentTime))s")
}
```

#### 3. Removed Detachment Flag from Recovery

```swift
// Line 636-638
private func recoverFromBackground() {
    print("DEBUG: [VIDEO RECOVERY] Starting recovery for \(mid)...")
    // REMOVED: isPlayerDetached = false
    hasRecoveredThisCycle = true
    
    // Rest of recovery logic unchanged
    // Layer refresh (representableId += 1) handles visual update
}
```

#### 4. Removed Conditional Rendering

```swift
// Lines 855-860
if let player = player {
    ZStack {
        // Main video player - always visible to avoid black screen flashes
        // REMOVED: if !isPlayerDetached check
        if mode == .mediaBrowser || mode == .tweetDetail {
            AVPlayerViewControllerRepresentable(player: player, isBuffering: $isBuffering)
```

#### 5. Removed Unused State Variable

```swift
// Lines 148-152
@State private var loadingState: LoadingState = .idle
@State private var playbackState: PlaybackState = .notStarted
@State private var isLongPressing = false
// REMOVED: @State private var isPlayerDetached = false
@State private var hasRecoveredThisCycle = false
```

---

## Benefits

### ✅ Better User Experience

1. **No black screen flash** when unlocking or returning to app
2. **Smooth transitions** - video view stays visible throughout
3. **Last frame visible** during background instead of black screen
4. **Professional appearance** - no jarring visual transitions

### ✅ Simpler Code

1. **Removed complexity** - No need to manage detachment state
2. **Fewer conditionals** - View always rendered when player exists
3. **Easier to understand** - One less flag to track
4. **Fewer edge cases** - No desync between detachment flag and actual state

### ✅ Same Functionality

1. **State caching still works** - Position, playback status, mute state preserved
2. **Resource management unchanged** - Player still paused on background
3. **Recovery logic intact** - Layer refresh and player recreation still happen
4. **All scenarios covered** - Screen lock, app background, long background

---

## Testing

### Test Case 1: Screen Lock (Power Button)

**Steps:**
1. Play video in feed or profile
2. Press power button to lock
3. Wait 2-3 seconds
4. Unlock device

**Expected Behavior:**
- ✅ Video pauses when locked
- ✅ **Last frame stays visible** (no black screen)
- ✅ Video resumes smoothly on unlock
- ✅ **No flash or transition**

**Logs:**
```
DEBUG: [VIDEO RESIGN ACTIVE] App will resign active for QmXXX
DEBUG: [VIDEO CACHE STATE] Cached state for QmXXX - wasPlaying: true, time: 5.2s
DEBUG: [VIDEO APP ACTIVE] App became active for QmXXX
DEBUG: [VIDEO RECOVERY] Starting recovery for QmXXX, didEnterBackground: false
DEBUG: [VIDEO RECOVERY] Screen lock detected - FORCE recreating MediaCell player
```

### Test Case 2: Auto Screen Lock

**Steps:**
1. Play video in feed or profile
2. Wait for auto-lock (1-2 minutes)
3. Unlock with Face ID/passcode

**Expected Behavior:**
- ✅ Video pauses when locked
- ✅ **Last frame visible during lock**
- ✅ Video recovers on unlock
- ✅ **Smooth transition, no black screen**

### Test Case 3: Quick App Switch

**Steps:**
1. Play video in feed
2. Swipe up to home or check notification
3. Return to app after 1-2 seconds

**Expected Behavior:**
- ✅ **Last frame visible in app switcher**
- ✅ Video continues smoothly on return
- ✅ **No black flash**
- ✅ Playback position maintained

**Logs:**
```
DEBUG: [VIDEO RESIGN ACTIVE] App will resign active for QmXXX
DEBUG: [VIDEO CACHE STATE] Cached state for QmXXX - wasPlaying: true, time: 8.7s
DEBUG: [VIDEO BACKGROUND] App entering background for QmXXX
DEBUG: [VIDEO FOREGROUND] App will enter foreground for QmXXX
DEBUG: [VIDEO RECOVERY] Starting recovery for QmXXX, didEnterBackground: true
DEBUG: [VIDEO RECOVERY] Player healthy - gentle recovery with view layer refresh
```

### Test Case 4: Long Background

**Steps:**
1. Play video in feed
2. Background app for 10+ minutes
3. Return to app

**Expected Behavior:**
- ✅ AppDelegate restarts infrastructure
- ✅ Video recreates fresh
- ✅ **No black screen flash even during recreation**
- ✅ Smooth user experience

---

## Why This Works

### The Key Insight

The `isPlayerDetached` flag was **self-inflicted complexity**:

1. **We were hiding the view** by setting `isPlayerDetached = true`
2. **Then re-showing it** by setting `isPlayerDetached = false`
3. **This caused the black screen flash** that we were trying to prevent!

### What Actually Happens

**iOS Behavior:**
- When app goes to background, iOS **automatically** suspends rendering
- When app returns to foreground, iOS **automatically** resumes rendering
- The AVPlayerLayer continues to show the **last rendered frame** when suspended

**Old Approach (Wrong):**
- We **manually** hid the view on background
- Created **artificial black screen**
- Had to **manually** re-show the view
- Caused **visible flash**

**New Approach (Correct):**
- Let iOS handle rendering suspension
- **Keep view visible** at all times
- Only **refresh the layer** when returning (which we were doing anyway)
- **No black screen**, smooth transition

### Layer Refresh Still Needed

Even though we keep the view visible, we still need to refresh the layer when returning:

```swift
representableId += 1  // Force SwiftUI to recreate the UIViewRepresentable
```

**Why?**
- iOS may invalidate the AVPlayerLayer internally during background
- The layer needs to be "reconnected" to the player
- Incrementing `representableId` forces SwiftUI to recreate the representable
- This happens **seamlessly** because the view never disappeared

**User sees:**
- Last frame visible → (unlock) → **brief refresh** → video playing
- **NO black screen** in between!

---

## Comparison

| Aspect | Old Approach | New Approach |
|--------|--------------|--------------|
| **Going to background** | Pause + Hide view | Pause only |
| **User sees (locked)** | Black screen | Last frame |
| **Coming to foreground** | Show view + Refresh | Refresh only |
| **User sees (unlock)** | Black → Flash → Video | Last frame → Video |
| **Code complexity** | Higher (manage detachment) | Lower (no flag) |
| **State variables** | 6 flags | 5 flags |
| **Conditional rendering** | Yes (if !isPlayerDetached) | No |
| **User experience** | ❌ Black screen flash | ✅ Smooth transition |

---

## Impact

### Before This Fix

Users would see:
1. Video playing
2. **Lock screen → BLACK SCREEN**
3. **Unlock → FLASH → Video appears**

**Feels janky and unprofessional**

### After This Fix

Users see:
1. Video playing
2. **Lock screen → Last frame visible**
3. **Unlock → Video smoothly continues**

**Feels polished and professional**

---

## Future Improvements

### Potential Enhancements

1. **Pre-buffer on unlock** - Start buffering immediately when app becomes active
2. **Faster layer refresh** - Optimize the representable recreation time
3. **Smooth seek** - Animate position restoration instead of jumping
4. **Background audio** - Continue audio playback during background (if desired)

### Not Needed

1. ❌ More aggressive detachment - We removed it for good reason
2. ❌ More flags to track state - Simpler is better
3. ❌ Delayed recovery - Immediate recovery works great

---

## Related Documentation

- `VIDEO_SYSTEM.md` - Overall video architecture
- `PROFILE_VIDEO_SCREEN_LOCK_FINAL_SOLUTION.md` - Screen lock recovery strategy
- `UNIFIED_BACKGROUND_RECOVERY.md` - Background recovery approach
- `VideoPlaybackAlgorithm.md` - Sequential playback algorithm

---

## Key Takeaways

### 1. Question Every "Safety" Mechanism

The `isPlayerDetached` flag was meant to "prevent black screens" but was actually **causing** them. Always verify that defensive code is actually helping, not harming.

### 2. Trust the Platform

iOS already handles view lifecycle correctly. We don't need to manually hide/show views. Trust the platform's built-in behavior.

### 3. Less Is More

Removing complexity often improves both code quality and user experience. The simplest solution is usually the best.

### 4. Test What Users See

Focus on the actual user experience, not just logs or code correctness. The black screen flash was obvious to users but might be missed in technical testing.

### 5. Optimize for the Common Case

Most users lock/unlock their device frequently. Even small improvements to this flow have significant impact on perceived quality.

---

## Summary

This optimization eliminates unnecessary black screen flashes during app lifecycle transitions by:

1. **Removing view detachment** when going to background
2. **Keeping video view visible** at all times
3. **Simplifying code** by removing the `isPlayerDetached` flag
4. **Trusting iOS** to handle rendering suspension correctly

**Result:** Smoother, more professional user experience with simpler code.

**Status:** ✅ Ready for production


