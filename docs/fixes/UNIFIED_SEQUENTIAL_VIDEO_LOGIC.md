# Unified Sequential Video Logic (December 7, 2025)

**Change**: Unified video playback logic - single videos and multiple videos now use the same algorithm.

## Previous Approach (Inconsistent)

### For Multiple Videos (2+)
- `isSequentialPlaybackEnabled = true`
- Used sequential playback algorithm
- Videos advanced automatically
- Saved/restored playback position

### For Single Video (1)
- `isSequentialPlaybackEnabled = false`
- Special case handling in `shouldPlayVideo()`
- Different code path
- Less consistent behavior

## New Approach (Unified)

### For All Videos (1+)
- `isSequentialPlaybackEnabled = true` (always)
- Single video = sequential playback with 1 item
- Same algorithm for all cases
- Consistent behavior across the board

## Code Changes

### 1. MediaGridView.swift

**Before:**
```swift
if videoMids.count > 1 {
    videoManager.setupSequentialPlayback(...)
} else if videoMids.count == 1 {
    // Special handling for single videos
    videoManager.videoMids = videoMids
    videoManager.isSequentialPlaybackEnabled = false
    ...
}
```

**After:**
```swift
// Setup sequential playback for all videos (1 or more)
// Single video is just sequential playback with 1 item
if videoMids.count >= 1 {
    videoManager.setupSequentialPlayback(for: videoMids, tweetId: parentTweet.mid)
    
    // If all videos were finished, restart from beginning
    if videoManager.currentVideoIndex >= videoMids.count {
        videoManager.currentVideoIndex = 0
        videoManager.saveCurrentIndex(for: parentTweet.mid)
    }
}
```

### 2. VideoManager.swift - setupSequentialPlayback()

**Before:**
```swift
isSequentialPlaybackEnabled = mids.count > 1
```

**After:**
```swift
// Always enable sequential playback, even for single videos (it's just a sequence of 1)
isSequentialPlaybackEnabled = !mids.isEmpty
```

### 3. VideoManager.swift - shouldPlayVideo()

**Before:**
```swift
if isSequentialPlaybackEnabled {
    // Handle multiple videos
    return videoMids[currentVideoIndex] == mid
}

// Special case for single videos
if !videoMids.isEmpty && videoMids.contains(mid) {
    return videoMids[0] == mid
}
return false
```

**After:**
```swift
// Sequential playback is always enabled (even for single videos)
// Only play the video at the current index in the sequence
guard isSequentialPlaybackEnabled else { return false }

guard currentVideoIndex >= 0 && currentVideoIndex < videoMids.count else { 
    return false 
}

return videoMids[currentVideoIndex] == mid
```

### 4. VideoManager.swift - restartSequentialPlayback()

**Before:**
```swift
isSequentialPlaybackEnabled = videoMids.count > 1
```

**After:**
```swift
isSequentialPlaybackEnabled = true // Always enabled for consistency
```

## Benefits

✅ **Simpler Code**: Single code path instead of two  
✅ **Consistent Behavior**: All videos work the same way  
✅ **Less Edge Cases**: Fewer special cases to handle  
✅ **Easier Maintenance**: One algorithm to maintain  
✅ **Same Features**: Single videos now get state persistence too  

## Behavior

### Single Video (1 video)
1. Grid appears → Video plays from saved position (or beginning)
2. Scroll away → Saves current position
3. Scroll back → Resumes from saved position
4. Video finishes → Restarts from beginning on next appearance

### Multiple Videos (2+ videos)
1. Grid appears → First video plays (or resumes from saved index)
2. Video finishes → Next video starts automatically
3. Scroll away → Saves current video index
4. Scroll back → Resumes from saved video
5. All videos finish → Restarts from first video on next appearance

## Why This Makes Sense

A single video is mathematically just a special case of sequential playback:
- Sequential playback of [A, B, C] = play A, then B, then C
- Sequential playback of [A] = play A

There's no reason to treat them differently. The same algorithm handles both cases naturally.

## Testing

All previous functionality still works:
- ✅ Single video playback
- ✅ Multiple video sequential playback  
- ✅ State persistence and restoration
- ✅ Restart when all videos finish
- ✅ Resume from saved position

But now the code is simpler and more maintainable!
