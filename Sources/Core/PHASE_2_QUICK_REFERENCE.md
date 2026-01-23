# Phase 2 Quick Reference Card

## TL;DR

**Phase 2 centralizes all primary video playback through `SharedVideoPlayerManager`.**

---

## Before & After

### Playing a Video

❌ **Before (Don't do this anymore):**
```swift
NotificationCenter.default.post(
    name: .shouldPlayVideo,
    userInfo: [
        "tweetId": tweetId,
        "videoMid": videoMid,
        "videoIndex": index,
        "isPrimary": true
    ]
)
```

✅ **After (Do this):**
```swift
SharedVideoPlayerManager.shared.playVideo(
    videoId: "\(tweetId)_\(videoMid)_\(index)",
    videoMid: videoMid,
    cellTweetId: tweetId
)
```

### Stopping a Video

❌ **Before (Don't do this anymore):**
```swift
NotificationCenter.default.post(
    name: .shouldStopVideo,
    userInfo: ["videoMid": videoMid]
)
```

✅ **After (Do this):**
```swift
if SharedVideoPlayerManager.shared.currentVideoMid == videoMid {
    SharedVideoPlayerManager.shared.stopCurrentVideo()
}
```

### Pausing a Video

**Primary video:**
```swift
if SharedVideoPlayerManager.shared.currentVideoMid == videoMid {
    SharedVideoPlayerManager.shared.pauseCurrentVideo()
}
```

**Background videos:**
```swift
// Direct notifications OK for non-primary videos
NotificationCenter.default.post(
    name: .shouldPauseVideo,
    userInfo: ["videoMid": videoMid]
)
```

---

## Querying State

### Is a video currently playing?
```swift
if SharedVideoPlayerManager.shared.isPlaying() {
    // A video is playing
}
```

### Which video is playing?
```swift
if let currentMid = SharedVideoPlayerManager.shared.currentVideoMid {
    print("Currently playing: \(currentMid)")
}
```

### Get current playback time
```swift
let currentTime = SharedVideoPlayerManager.shared.getCurrentTime()
```

### Get video duration
```swift
let duration = SharedVideoPlayerManager.shared.getDuration()
```

---

## Rules of Thumb

### When to use SharedVideoPlayerManager

✅ **Always use for primary video:**
- Starting playback
- Stopping playback
- Querying state

### When direct notifications are OK

✅ **Use for background videos:**
- Pausing non-primary videos
- Cleanup operations
- Videos not managed by coordinator

---

## Common Patterns

### Pattern 1: Start Primary Video
```swift
// Coordinator decides which video
let primary = identifyPrimaryVideo()

// Use manager to coordinate
SharedVideoPlayerManager.shared.playVideo(
    videoId: primary.identifier,
    videoMid: primary.videoMid,
    cellTweetId: primary.cellTweetId
)
```

### Pattern 2: Switch to New Primary
```swift
// Stop old primary if it's the current one
if SharedVideoPlayerManager.shared.currentVideoMid == oldVideo.videoMid {
    SharedVideoPlayerManager.shared.stopCurrentVideo()
}

// Pause background videos (direct notifications OK)
backgroundVideos.forEach { video in
    NotificationCenter.default.post(
        name: .shouldPauseVideo,
        userInfo: ["videoMid": video.videoMid]
    )
}

// Start new primary
SharedVideoPlayerManager.shared.playVideo(
    videoId: newVideo.identifier,
    videoMid: newVideo.videoMid,
    cellTweetId: newVideo.cellTweetId
)
```

### Pattern 3: Check Before Acting
```swift
// Always check if this is the current video before using manager
if SharedVideoPlayerManager.shared.currentVideoMid == video.videoMid {
    // This is the primary video - use manager
    SharedVideoPlayerManager.shared.stopCurrentVideo()
} else {
    // This is a background video - direct notification OK
    NotificationCenter.default.post(
        name: .shouldStopVideo,
        userInfo: ["videoMid": video.videoMid]
    )
}
```

---

## Debugging

### Check Current State
```swift
// In debugger or logs
print("🎬 Current video: \(SharedVideoPlayerManager.shared.currentVideoMid ?? "none")")
print("🎬 Is playing: \(SharedVideoPlayerManager.shared.isPlaying())")
print("🎬 Debug info:")
print(SharedVideoPlayerManager.shared.debugInfo())
```

### Set Breakpoint
Put breakpoint in `SharedVideoPlayerManager.playVideo()` - all primary video plays go through there.

### Check Logs
Look for Phase 2 markers:
```
🎬 [SHARED PLAYER] Coordinating playback for video: {videoId}
⏹️ [SHARED PLAYER] Stopping video: {videoId}
⏸️ [SHARED PLAYER] Pausing video: {videoId}
```

---

## Architecture Overview

```
┌─────────────────────────────────┐
│  VideoPlaybackCoordinator       │
│  (Decides which video to play)  │
└────────────┬────────────────────┘
             │
             │ All primary operations
             ▼
┌─────────────────────────────────┐
│  SharedVideoPlayerManager       │
│  (State owner & coordinator)    │
│  • currentVideoMid             │
│  • currentlyPlayingVideoId     │
└────────────┬────────────────────┘
             │
             │ Posts notifications
             ▼
┌─────────────────────────────────┐
│  SimpleVideoPlayer              │
│  (Listens & plays)              │
└─────────────────────────────────┘
```

---

## Key Points

1. **Coordinator decides** which video should play
2. **Manager coordinates** the actual playback and owns state
3. **Player renders** the video based on notifications
4. **Only one primary video** at any time
5. **Background videos** can use direct notifications for lightweight operations

---

## Migration Checklist

If you're adding new video playback code:

- [ ] For primary video play → Use `SharedVideoPlayerManager.shared.playVideo()`
- [ ] For primary video stop → Use `SharedVideoPlayerManager.shared.stopCurrentVideo()`
- [ ] For primary video pause → Use `SharedVideoPlayerManager.shared.pauseCurrentVideo()`
- [ ] For state queries → Use `SharedVideoPlayerManager.shared.*` properties/methods
- [ ] For background videos → Direct notifications OK
- [ ] Add "PHASE 2" comment to clarify architectural choice

---

## Quick Fixes

### Issue: Video doesn't start
**Check:**
```swift
print(SharedVideoPlayerManager.shared.currentVideoMid ?? "none")
// Should match the video you expect to play
```

### Issue: Multiple videos playing
**Check:**
```swift
// Should only have ONE currentVideoMid
print(SharedVideoPlayerManager.shared.debugInfo())
```

### Issue: State out of sync
**Fix:**
```swift
// Always update manager state BEFORE posting notifications
SharedVideoPlayerManager.shared.playVideo(...)
// This handles state update + notification in correct order
```

---

## Resources

- **Full implementation details:** PHASE_2_IMPLEMENTATION_SUMMARY.md
- **Architecture diagrams:** PHASE_2_ARCHITECTURE_DIAGRAM.md
- **Testing guide:** PHASE_2_TESTING_GUIDE.md
- **Complete summary:** PHASE_2_COMPLETE_SUMMARY.md

---

**Version:** Phase 2 (January 23, 2026)  
**Status:** ✅ Implementation Complete
