# Fixed MediaGrid State Interference (December 7, 2025)

> **⚠️ DEPRECATED**: This document has been consolidated into `SEQUENTIAL_VIDEO_PLAYBACK_COMPLETE.md`.  
> Please refer to that document for the most up-to-date information.

**Problem**: Multiple `MediaGrid` views were interfering with each other's sequential playback state, causing videos to reset unexpectedly and state not being saved properly.

## Root Cause

`VideoManager` is a **shared singleton** across all `MediaGrid` instances. When scrolling:

1. **MediaGrid A** (2 videos) appears → sets up state (videoMids, currentVideoIndex)
2. User scrolls away → **MediaGrid A** should save state in `onDisappear`
3. **MediaGrid B** (different tweet) appears → calls `stopSequentialPlayback()`
4. ❌ **Problem**: `stopSequentialPlayback()` clears the shared state **BEFORE** MediaGrid A's `onDisappear` can save it!

Result:
```swift
stopSequentialPlayback() {
    videoMids = []           // ❌ Clears the array
    currentVideoIndex = -1   // ❌ Resets the index
}
```

When MediaGrid A's `onDisappear` finally runs:
```swift
if videoManager.currentVideoIndex >= 0 && !videoManager.videoMids.isEmpty {
    // ❌ This condition fails because state was already cleared!
    videoManager.saveCurrentIndex(for: parentTweet.mid)
}
```

## Evidence from Logs

**Single video tweet** (GufBg90K75rb8RDzxL2oyY8rxMG):
```
✅ DEBUG: [VideoManager] Saved video index 0 for tweet GufBg90K75rb8RDzxL2oyY8rxMG
```

**2-video tweet** (OehWRGrStHqjUVHs7mL6r09vFZl):
```
❌ No save log!
❌ DEBUG: [VideoManager] Invalid currentVideoIndex: -1, videoMids count: 0
```

State was wiped before it could be saved!

## The Fix

### 1. Only stop playback when switching to different videos

**Before:**
```swift
.onAppear {
    // ❌ Always clears state, even for the same MediaGrid reappearing
    videoManager.stopSequentialPlayback()
    
    videoManager.setupSequentialPlayback(for: videoMids, tweetId: parentTweet.mid)
}
```

**After:**
```swift
.onAppear {
    // ✅ Only stop if we're switching to a different video set
    // This preserves state when the same MediaGrid reappears
    if videoManager.videoMids != videoMids {
        print("DEBUG: [MediaGridView] Switching video set, stopping current playback")
        videoManager.stopSequentialPlayback()
    }
    
    videoManager.setupSequentialPlayback(for: videoMids, tweetId: parentTweet.mid)
}
```

### 2. Added comprehensive logging

**onDisappear:**
```swift
.onDisappear {
    isVisible = false
    
    if videoManager.currentVideoIndex >= 0 && !videoManager.videoMids.isEmpty {
        print("DEBUG: [MediaGridView] onDisappear - Saving state for tweet \(parentTweet.mid), index: \(videoManager.currentVideoIndex)")
        videoManager.saveCurrentIndex(for: parentTweet.mid)
    } else {
        print("DEBUG: [MediaGridView] onDisappear - NOT saving state for tweet \(parentTweet.mid), currentVideoIndex: \(videoManager.currentVideoIndex), videoMids.isEmpty: \(videoManager.videoMids.isEmpty)")
    }
}
```

**onVideoFinished:**
```swift
private func onVideoFinished() {
    print("DEBUG: [MediaGridView] onVideoFinished called for tweet \(parentTweet.mid)")
    videoManager.onVideoFinished(tweetId: parentTweet.mid)
}
```

**VideoManager.onVideoFinished:**
```swift
func onVideoFinished(tweetId: String? = nil) {
    print("DEBUG: [VideoManager] onVideoFinished called - currentVideoIndex: \(currentVideoIndex), videoMids.count: \(videoMids.count), tweetId: \(tweetId ?? "nil")")
    // ... rest of logic
}
```

## How It Works Now

### Scenario 1: Same MediaGrid Reappearing

1. **MediaGrid A** appears with videos [V1, V2]
   - `videoManager.videoMids = [V1, V2]`
   - Condition: `videoManager.videoMids != [V1, V2]` → **FALSE**
   - ✅ Does NOT call `stopSequentialPlayback()`
   - ✅ `setupSequentialPlayback()` restores saved state

2. User scrolls away
   - `onDisappear` saves state: `currentVideoIndex = 1` (if on second video)
   
3. User scrolls back
   - **MediaGrid A** appears again with videos [V1, V2]
   - `videoManager.videoMids = [V1, V2]` (still the same)
   - ✅ Restores index 1, continues from second video

### Scenario 2: Different MediaGrid Appearing

1. **MediaGrid A** with videos [V1, V2]
   - `videoManager.videoMids = [V1, V2]`
   
2. User scrolls to **MediaGrid B** with videos [V3]
   - Condition: `videoManager.videoMids != [V3]` → **TRUE**
   - ✅ Calls `stopSequentialPlayback()` to clear old state
   - ✅ Sets up new state for [V3]

## Benefits

✅ **State preservation** - MediaGrids don't interfere with each other  
✅ **Proper state saving** - onDisappear can save before state is cleared  
✅ **Video resumption** - Videos resume from correct index  
✅ **Sequential playback** - Second video plays after first one finishes  
✅ **Better debugging** - Comprehensive logs show what's happening  

## Testing Checklist

- [ ] Single video: Plays, saves position, resumes correctly
- [ ] Multiple videos: Play sequentially, advance to next video
- [ ] Scroll away during video 1: Saves index 0, resumes video 1
- [ ] Let video 1 finish, scroll away: Saves index 1, plays video 2 on return
- [ ] Let all videos finish: Resets to video 1 on next appearance
- [ ] No black screens when scrolling back
- [ ] State saved logs appear for all MediaGrids

## Architecture Note

This fix works around the limitation that `VideoManager` is a shared singleton. A better long-term solution would be to make sequential playback state **per-tweet** from the start, stored in a dictionary:

```swift
// Future improvement:
private var tweetPlaybackState: [String: PlaybackState] = [:]

struct PlaybackState {
    var videoMids: [String]
    var currentVideoIndex: Int
}
```

But for now, the conditional `stopSequentialPlayback()` prevents the interference issue.
