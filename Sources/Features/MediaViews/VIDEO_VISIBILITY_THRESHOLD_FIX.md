# Video Visibility Threshold Fix

## Problem Description

Videos were starting to play when **barely visible** and stopping when **still mostly on screen**, causing poor user experience during scrolling.

### User-Reported Issues

1. **Videos stop playing before fully scrolling out of view**
   - Video would stop when still 40-50% visible
   - Created jarring experience during slow scrolls

2. **Videos start playing when not yet visible**
   - Video would start when only 10-20% visible at bottom of screen
   - Users wouldn't see the beginning of videos

3. **Primary video changes too aggressively during scroll**
   - Rapid switching between videos as user scrolls
   - Videos interrupting each other unnecessarily

## Root Causes

### Issue 1: No Visibility Threshold in Coordinator

The `findTopmostFullyVisibleVideo()` function originally had two modes:
- **100% visible** (entire cell on screen) - too strict, rarely met
- **Fallback: Most visible** - any partial visibility, too lenient

```swift
// OLD CODE - Too strict or too lenient
let isFullyVisible = visibleRect.contains(cellFrame)  // Requires 100%

if topmostVideo == nil {
    // Fallback: pick ANY partially visible video
    if ratio > bestRatio {
        bestVideo = video  // Could be only 5% visible!
    }
}
```

### Issue 2: Includes Barely-Visible Tweets

`updateVisibleTweetsForVideoPlayback()` used `indexPathsForVisibleRows` which includes cells with **even 1 pixel visible**:

```swift
// OLD CODE - Any cell returned by UITableView
let visibleIndexPaths = tableView.indexPathsForVisibleRows ?? []
// This includes cells that are 99% off-screen!
```

### Issue 3: No Threshold Check for Current Video

The coordinator would stop a playing video if it wasn't in `visibleVideos`, but that list included barely-visible cells:

```swift
// OLD CODE - Checked simple boolean membership
if visibleVideos.contains(where: { $0.identifier == currentId }) {
    // Keep playing
}
// Problem: visibleVideos included 5% visible cells!
```

## Solution

Implemented **consistent 60% visibility threshold** across all visibility checks:

### Fix 1: Visibility Threshold in findTopmostFullyVisibleVideo()

```swift
// NEW CODE - Consistent 60% threshold
let visibilityThreshold: CGFloat = 0.60

let intersection = cellFrame.intersection(visibleRect)
let visibleRatio = intersection.height / cellFrame.height

// Video must meet visibility threshold
guard visibleRatio >= visibilityThreshold else { continue }

// Among videos meeting threshold, pick topmost
if cellFrame.minY < topmostY - 50 {
    topmostVideo = video
}
```

**Benefits:**
- ✅ Video must be **60% visible** to start playing
- ✅ Video must remain **60% visible** to keep playing
- ✅ Prevents switching to barely-visible videos
- ✅ More stable during scrolling

### Fix 2: Filter Barely-Visible Tweets

```swift
// NEW CODE - Only include tweets that are at least 10% visible
var visibleTweetIds = Set<String>()

for cell in tableView.visibleCells {
    let cellFrame = tableView.convert(cell.frame, to: tableView)
    let intersection = cellFrame.intersection(visibleRect)
    let visibleRatio = intersection.height / cellFrame.height
    
    // Only include if at least 10% visible
    if visibleRatio >= 0.10 {
        visibleTweetIds.insert(tweetId)
    }
}
```

**Benefits:**
- ✅ Reduces `visibleVideos` list to truly visible items
- ✅ Prevents coordinator from considering off-screen videos
- ✅ Improves performance (fewer videos to check)

### Fix 3: Check Threshold for Current Video

```swift
// NEW CODE - Verify current video still meets threshold
if let currentId = currentlyPlayingVideoId {
    if isVideoSufficientlyVisible(videoId: currentId) {
        // Still 60%+ visible, keep playing
        return
    } else {
        // Dropped below 60%, find new video
        print("⏹️ [VideoCoordinator] Current video no longer sufficiently visible")
    }
}

// Helper function
private func isVideoSufficientlyVisible(videoId: String) -> Bool {
    let visibleRatio = intersection.height / cellFrame.height
    return visibleRatio >= 0.60  // Same 60% threshold
}
```

**Benefits:**
- ✅ Current video keeps playing until it drops below 60%
- ✅ No premature stopping
- ✅ Smooth transition when scrolling past

### Fix 4: Enhanced Debug Logging

```swift
print("👁️ [VISIBILITY] Checking \(visibleVideos.count) videos:")
for (mid, ratio, y) in debugInfo.prefix(5) {
    let status = ratio >= visibilityThreshold ? "✅" : "❌"
    print("👁️   \(status) \(mid) - \(Int(ratio * 100))% visible, Y:\(Int(y))")
}
```

**Sample output:**
```
👁️ [VISIBILITY] Checking 4 videos:
👁️   ❌ QmZHVMkYneo8k... - 25% visible, Y:120
👁️   ✅ QmS7eJeGzHPPF... - 85% visible, Y:350
👁️   ✅ QmZ8dqcPBGfjy... - 95% visible, Y:680
👁️   ❌ QmYzrC9xLYQ1K... - 45% visible, Y:920
👁️ [VISIBILITY] Selected: QmS7eJeGzHPP... (85% visible)
```

## Threshold Values Explained

### Why 60% for Playing?

- **60% visible** = Video is clearly on screen and user can watch it
- **Less than 60%** = Video is either:
  - Entering view (not ready yet)
  - Leaving view (should stop)
  - Too close to edge for comfortable viewing

### Why 10% for Visible Tweets?

- **10% visible** = Generous buffer for tweet visibility
- Allows coordinator to be **aware** of upcoming/leaving videos
- But won't **play** them until they reach 60%
- Prevents completely off-screen tweets from being considered

### Hysteresis Effect

The difference between 10% (visible) and 60% (playable) creates **hysteresis**:
- Videos won't start until 60% visible (prevents early starts)
- Videos keep playing down to 60% visible (prevents early stops)
- But videos can be "prepared" starting at 10% visible (smooth transitions)

## Expected Behavior

### Scenario 1: Scrolling Down Slowly

```
Initial state: Video 1 playing (80% visible)

User scrolls down...
  Video 1: 80% → 70% → 60% → 50%
           ✅ Keep  ✅ Keep  ✅ Keep  ⏹️ Stop
  
  Video 2: 40% → 50% → 60% → 70%
           ❌ Wait  ❌ Wait  ▶️ Play  ✅ Keep
```

### Scenario 2: Scrolling Up

```
Video 2 playing (75% visible)

User scrolls up...
  Video 2: 75% → 65% → 55%
           ✅ Keep  ✅ Keep  ⏹️ Stop
  
  Video 1: 45% → 55% → 65%
           ❌ Wait  ❌ Wait  ▶️ Play
```

### Scenario 3: Rapid Scroll

```
User flicks scroll quickly

Video 1: 90% → 70% → 30% → 5%
         ✅      ✅      ⏹️
         
Video 2: 10% → 40% → 70% → 95%
         (preparing...) ▶️
```

Even during rapid scrolls, videos only switch when crossing 60% threshold.

## Performance Impact

✅ **Minimal performance cost**:
- Visibility calculations already cached
- Intersection math is very fast
- Runs only during scroll (throttled to 0.1s intervals)
- Reduces unnecessary video switches (actually improves performance)

## Testing Checklist

- [ ] **Slow scroll down** - Videos transition smoothly at 60% threshold
- [ ] **Slow scroll up** - Videos don't stop prematurely
- [ ] **Fast flick scroll** - No rapid video switching
- [ ] **Stop mid-scroll** - Video plays if > 60% visible, stops if < 60%
- [ ] **Video finishes** - Next video plays if > 60% visible
- [ ] **Background/foreground** - Correct video resumes based on visibility
- [ ] **Rotate device** - Threshold still works after orientation change

## Tuning Options

If 60% feels wrong, you can adjust:

```swift
// In findTopmostFullyVisibleVideo()
let visibilityThreshold: CGFloat = 0.60  // Adjust between 0.5 and 0.8

// In updateVisibleTweetsForVideoPlayback()
if visibleRatio >= 0.10  // Adjust between 0.05 and 0.20
```

**Recommendations:**
- **Stricter (70-80%)**: Video must be very centered - good for short videos
- **Lenient (50-60%)**: Video starts earlier - good for long videos
- **Current (60%)**: Good balance for typical social media video lengths

## Related Files

- `VideoPlaybackCoordinator.swift` - Visibility threshold logic (FIXED)
- `TweetTableViewController.swift` - Visible tweet filtering (FIXED)
- `SimpleVideoPlayer.swift` - Video player (no changes needed)

## Migration Notes

No breaking changes - this is purely an improvement to existing logic. All existing video playback features continue to work.
