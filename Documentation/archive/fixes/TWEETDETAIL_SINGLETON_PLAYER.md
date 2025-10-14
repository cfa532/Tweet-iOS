# TweetDetailView Singleton Video Player

## Problem Statement

Videos in TweetDetailView were being stopped by MediaCell's `stopAllVideos` notification because they were sharing the same `AVPlayer` instance through `SharedAssetCache`.

## Root Cause

`SharedAssetCache.getOrCreatePlayer()` was ignoring the `tweetId` parameter and always caching players with just `mediaID`:

```swift
// BEFORE (WRONG):
let cacheKey = mediaID  // ❌ Ignores tweetId parameter
```

**Result**: MediaCell and TweetDetail used the same player instance, so when MediaCell paused it, TweetDetail video also stopped.

## Solution

### 1. Singleton Player in DetailVideoManager

TweetDetailView now uses `DetailVideoManager.shared` to store a persistent player:

```swift
// In SimpleVideoPlayer.setupPlayer():
if mode == .tweetDetail {
    // Check if singleton has this video
    if DetailVideoManager.shared.currentVideoMid == mid {
        // Reuse existing singleton player
        self.player = DetailVideoManager.shared.currentPlayer
        return
    }
    
    // Create new player and store in singleton
    let newPlayer = try await SharedAssetCache.shared.getOrCreatePlayer(
        for: uniquePlayerURL, 
        tweetId: "tweetDetail_\(mid)",  // ✅ Unique key
        mediaType: mediaType
    )
    
    DetailVideoManager.shared.currentPlayer = newPlayer
    DetailVideoManager.shared.currentVideoMid = mid
}
```

### 2. Fixed SharedAssetCache to Use tweetId

Modified `SharedAssetCache.getOrCreatePlayer()` to actually respect the `tweetId` parameter:

```swift
// AFTER (CORRECT):
let cacheKey = tweetId ?? mediaID  // ✅ Uses tweetId when provided
```

**Result**: 
- MediaCell: cached with key `"QmXXX"`
- TweetDetail: cached with key `"tweetDetail_QmXXX"`
- Completely separate player instances!

### 3. TweetDetail Ignores stopAllVideos

Updated `stopAllVideos` handler:

```swift
.onReceive(NotificationCenter.default.publisher(for: .stopAllVideos)) { _ in
    if mode == .mediaCell {
        player?.pause()
        player?.isMuted = true
    }
    // TweetDetail: DO NOTHING
}
```

### 4. No Pausing in onDisappear

TweetDetail's `onDisappear` does **nothing**:

```swift
else if mode == .tweetDetail {
    // DO ABSOLUTELY NOTHING
    // Singleton persists, view recreation doesn't affect it
}
```

### 5. Cleanup via .task

Proper cleanup when view is permanently dismissed:

```swift
.task {
    defer {
        // Runs when task is cancelled (view dismissed)
        DetailVideoManager.shared.currentPlayer?.pause()
        DetailVideoManager.shared.currentPlayer = nil
        DetailVideoManager.shared.currentVideoMid = nil
    }
    try? await Task.sleep(for: .seconds(3600))
}
```

## Architecture

```
TweetDetailView Opens
    ↓
SimpleVideoPlayer creates player with tweetId="tweetDetail_QmXXX"
    ↓
SharedAssetCache caches with key: "tweetDetail_QmXXX"
    ↓
DetailVideoManager.shared.currentPlayer = player
    ↓
TabView recreates DetailMediaCell → Reuses singleton player ✅
    ↓
MediaCell scrolls → stopAllVideos posted
    ↓
MediaCell players pause (key: "QmXXX")
TweetDetail player unaffected (key: "tweetDetail_QmXXX") ✅
    ↓
User exits TweetDetailView → .task cancelled → Cleanup ✅
```

## Files Modified

1. **SimpleVideoPlayer.swift**
   - Lines 155-162: Added `playerCacheKey` computed property (though ultimately we use `tweetId` parameter)
   - Lines 314-317: TweetDetail `onDisappear` does nothing
   - Lines 524-530: TweetDetail ignores `stopAllVideos` notification
   - Lines 776-822: Added singleton player logic for TweetDetail mode
   - Updated all `VideoStateCache` calls to use `playerCacheKey`

2. **SharedAssetCache.swift**
   - Line 484: Changed `cacheKey = mediaID` to `cacheKey = tweetId ?? mediaID` ✅
   - Lines 580-619: Added `getOrCreatePlayerItem()` method (for fresh items)

3. **TweetDetailView.swift**
   - Lines 508-521: Added `.task` with `defer` for proper cleanup

## Benefits

- ✅ **Separate player instances**: MediaCell and TweetDetail never share
- ✅ **Immune to stopAllVideos**: TweetDetail videos never pause unexpectedly
- ✅ **Survives view recreation**: TabView can recreate cells without affecting playback
- ✅ **Proper cleanup**: Player released when actually exiting TweetDetailView
- ✅ **Simple code**: Minimal changes, no complex logic

## Testing

### Test 1: Video Continues During Scroll
1. Open TweetDetailView with video
2. Video starts playing
3. Scroll the feed (MediaCell videos pause)
4. **Expected**: TweetDetail video continues playing ✅

### Test 2: Clean Exit
1. Play video in TweetDetailView
2. Navigate back to feed
3. **Expected**: Video stops, no audio bleeding ✅

### Test 3: Multiple Videos in TabView
1. Tweet has multiple videos
2. Swipe between them in TabView
3. **Expected**: Each video plays independently ✅

## Debug Logs

**Singleton player creation:**
```
DEBUG: [VIDEO SETUP] TweetDetail mode - checking singleton for QmXXX
DEBUG: [VIDEO SETUP] Creating new player for singleton (QmXXX)
DEBUG: [SHARED ASSET CACHE] Using cache key: tweetDetail_QmXXX
DEBUG: [VIDEO SETUP] ✅ Stored new player in singleton for QmXXX
```

**stopAllVideos notification:**
```
DEBUG: [SimpleVideoPlayer] stopAllVideos - paused MediaCell QmXXX
(No TweetDetail log - completely ignored)
```

**Cleanup:**
```
DEBUG: [TweetDetailView] Task cancelled - cleaned up singleton
```

## Technical Notes

### Why Singleton?

- TweetDetail is a **navigation destination**, not a mode change
- Views are frequently recreated by TabView (swiping between attachments)
- A singleton ensures the player persists across these recreations
- No interruptions, no black screens, seamless playback

### Why Separate Cache Keys?

- `tweetId` parameter allows different "contexts" to have different players
- MediaCell: `"QmXXX"` (shared with MediaBrowser)
- TweetDetail: `"tweetDetail_QmXXX"` (independent singleton)
- Clean separation, no conflicts

### Why Task-Based Cleanup?

- `.task` is cancelled when view is permanently dismissed
- `defer` guarantees cleanup runs
- Not affected by TabView recreation (only runs on final dismissal)
- More reliable than `onDisappear` which fires for temporary disappearances

## Conclusion

TweetDetailView now uses a **completely independent singleton player** that is:
- Stored in `DetailVideoManager.shared`
- Cached with a unique key in `SharedAssetCache`
- Immune to `stopAllVideos` notifications
- Properly cleaned up when exiting

This ensures **uninterrupted video playback** in TweetDetailView regardless of MediaCell activity.

