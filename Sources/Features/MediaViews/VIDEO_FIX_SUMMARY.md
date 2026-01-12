# Video Visibility Fix - Quick Summary

## What Was Fixed

### Problem 1: Videos Stopped Too Early ❌
- Video would stop when still 40-50% visible
- User would see video suddenly stop while still mostly on screen

### Problem 2: Videos Started Too Early ❌
- Video would start when only 10-20% visible at edge of screen
- Users missed the beginning of videos

### Problem 3: Aggressive Switching During Scroll ❌
- Videos would rapidly switch as user scrolled
- Jarring experience with constant starts/stops

## The Solution ✅

### Single Change: 60% Visibility Threshold

Videos now:
- **Start playing** only when **≥60% visible**
- **Keep playing** as long as **≥60% visible**
- **Stop playing** when drops below **60% visible**

### What This Means for Users

**Before:**
```
User scrolls down...
Video 1: 100% → 80% → 60% → 40% ⏹️ STOPS (too early!)
Video 2: 20% ▶️ STARTS (can't see it yet!)
```

**After:**
```
User scrolls down...
Video 1: 100% → 80% → 60% → 40% ⏹️ STOPS (just right)
Video 2: 20% ... 40% ... 60% ▶️ STARTS (perfectly timed)
```

## Code Changes

### 1. VideoPlaybackCoordinator.swift
- Added `isVideoSufficientlyVisible()` helper function
- Updated `findTopmostFullyVisibleVideo()` to use 60% threshold
- Updated `checkAndPlayTopmost()` to check threshold before switching

### 2. TweetTableViewController.swift
- Updated `updateVisibleTweetsForVideoPlayback()` to filter out barely-visible cells
- Only includes tweets that are at least 10% visible

## Testing

Watch the debug logs while scrolling:

```
👁️ [VISIBILITY] Checking 4 videos:
👁️   ❌ QmZHVMkYneo8k... - 25% visible, Y:120
👁️   ✅ QmS7eJeGzHPPF... - 85% visible, Y:350  ← This will play
👁️   ✅ QmZ8dqcPBGfjy... - 95% visible, Y:680
👁️   ❌ QmYzrC9xLYQ1K... - 45% visible, Y:920
```

## Tuning (if needed)

If you want to adjust the threshold:

```swift
// VideoPlaybackCoordinator.swift, line ~299
let visibilityThreshold: CGFloat = 0.60  // Change to 0.50-0.80
```

- **0.50** = More lenient, videos start earlier
- **0.70** = Stricter, videos must be more centered
- **0.60** = Default, good balance

## Benefits

✅ Videos play when users can actually see them  
✅ No more premature stopping  
✅ Smoother scrolling experience  
✅ Better video-to-video transitions  
✅ Less jarring during rapid scrolls  
