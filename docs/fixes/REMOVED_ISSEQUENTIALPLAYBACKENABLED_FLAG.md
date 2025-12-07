# Removed isSequentialPlaybackEnabled Flag (December 7, 2025)

> **⚠️ DEPRECATED**: This document has been consolidated into `SEQUENTIAL_VIDEO_PLAYBACK_COMPLETE.md`.  
> Please refer to that document for the most up-to-date information.

**Change**: Removed the `isSequentialPlaybackEnabled` boolean flag - it was redundant since MediaGrid always does sequential playback.

## Why It Was Unnecessary

MediaGrid **always** plays videos sequentially:
- Single video → plays that video (sequence of 1)
- Multiple videos → plays them in order (sequence of N)

There's never a case where MediaGrid doesn't use sequential playback, so the flag was just extra complexity with no benefit.

## Code Removed

### VideoManager.swift

**Before:**
```swift
class VideoManager: ObservableObject {
    @Published var currentVideoIndex: Int = -1
    @Published var videoMids: [String] = []
    @Published var isSequentialPlaybackEnabled: Bool = false  // ❌ Removed
    ...
}

func setupSequentialPlayback(for mids: [String], tweetId: String? = nil) {
    videoMids = mids
    isSequentialPlaybackEnabled = !mids.isEmpty  // ❌ Removed
    ...
}

func shouldPlayVideo(for mid: String) -> Bool {
    guard isSequentialPlaybackEnabled else {  // ❌ Removed
        return false 
    }
    ...
}
```

**After:**
```swift
class VideoManager: ObservableObject {
    @Published var currentVideoIndex: Int = -1
    @Published var videoMids: [String] = []
    // isSequentialPlaybackEnabled removed entirely
}

func setupSequentialPlayback(for mids: [String], tweetId: String? = nil) {
    videoMids = mids
    // No flag to set
    ...
}

func shouldPlayVideo(for mid: String) -> Bool {
    // MediaGrid always uses sequential playback (even for single videos)
    guard currentVideoIndex >= 0 && currentVideoIndex < videoMids.count else {
        return false 
    }
    ...
}
```

### MediaGridView.swift

**Before:**
```swift
if videoManager.isSequentialPlaybackEnabled && videoManager.currentVideoIndex >= 0 {
    videoManager.saveCurrentIndex(for: parentTweet.mid)
}
```

**After:**
```swift
if videoManager.currentVideoIndex >= 0 && !videoManager.videoMids.isEmpty {
    videoManager.saveCurrentIndex(for: parentTweet.mid)
}
```

## How It Works Now

The sequential playback state is determined by:
- **`videoMids.isEmpty`** - Are there videos to play?
- **`currentVideoIndex >= 0`** - Is there a valid current video?

If both are true, sequential playback is active. No need for an extra flag!

## Benefits

✅ **Simpler code** - One less property to track  
✅ **Less state** - Fewer @Published variables  
✅ **No sync issues** - Can't get out of sync with videoMids  
✅ **Clearer logic** - State is implicit from the data  
✅ **Fewer bugs** - Less state means fewer edge cases  

## Migration

### Old Way (Flag-Based)
```swift
// Check if sequential playback is enabled
if videoManager.isSequentialPlaybackEnabled {
    // Do something
}
```

### New Way (Data-Based)
```swift
// Check if we have videos in the sequence
if !videoManager.videoMids.isEmpty {
    // Do something
}
```

## Testing

All functionality remains the same:
- ✅ Single video playback works
- ✅ Multiple video sequential playback works
- ✅ State persistence works
- ✅ Resume from saved position works
- ✅ Restart after all videos finish works

The only difference is internal implementation - the external behavior is identical.

## Philosophy

**Good state management principle**: Derive state from data whenever possible instead of maintaining redundant flags.

Instead of:
```swift
var items: [Item] = []
var hasItems: Bool = false  // ❌ Redundant
```

Use:
```swift
var items: [Item] = []
var hasItems: Bool { !items.isEmpty }  // ✅ Derived
```

In our case, we don't even need a computed property - we just check `!videoMids.isEmpty` directly where needed.
