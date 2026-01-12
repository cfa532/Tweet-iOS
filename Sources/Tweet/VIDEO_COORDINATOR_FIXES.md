# VideoPlaybackCoordinator Fixes - January 2026

## Overview

This document outlines the comprehensive fixes applied to `VideoPlaybackCoordinator` to resolve critical issues with video playback in retweets, quoted tweets, and embedded videos.

## Problems Identified

### 1. 🔴 CRITICAL: Embedded/Quoted Tweet Videos Were Being Coordinated

**Problem:** The coordinator added ALL videos to its tracking list, including:
- Videos in quoted tweets (embedded previews)
- Videos in retweets
- Videos in regular tweets

But the app has **two separate playback systems**:
1. **Coordinated System** (VideoPlaybackCoordinator): Regular tweets, retweets
2. **Independent System** (MediaCell visibility-based): Embedded/quoted tweet videos

The coordinator didn't distinguish between these, causing:
- Multiple simultaneous play commands
- Videos playing before becoming visible
- Muted playback conflicts
- Race conditions

### 2. 🔴 CRITICAL: Mute State Not Passed in Notifications

**Problem:** The coordinator sent `.shouldPlayVideo` notifications without including the global mute state. This meant:
- Videos might play muted even when global state was unmuted
- Mute state was only applied after initial playback started
- Inconsistent mute behavior across videos

### 3. 🟡 MEDIUM: Duplicate Play Command Prevention Was Broken

**Problem:** The `videosSentPlayCommands` set was never cleared for individual videos that stopped playing. This meant:
- Videos scrolled off-screen and back wouldn't replay
- Only global `stopAllVideos()` cleared the set
- Memory leak from unbounded set growth

### 4. 🟡 MEDIUM: Race Condition in Phase Transitions

**Problem:** The `endSurveyPhase()` method wasn't atomic:
1. Check if `phase == .surveying` ✅
2. Start processing (invalidate timers, pause videos)
3. Another call: Check if `phase == .surveying` ✅ (still true!)
4. Both calls send play commands

### 5. 🟠 MINOR: Unbounded Retry Loop for Infrastructure Readiness

**Problem:** `handleForegroundRecovery()` had an infinite retry loop checking infrastructure readiness every 500ms, even though a notification-based system already exists.

### 6. 🟠 MINOR: No Safety Check for Video Context

**Problem:** The `handleVideoFinished()` method didn't verify that a finished video was actually in the coordinated list, potentially causing incorrect sequential playback.

---

## Solutions Implemented

### Fix 1: Added Video Context Tracking

**Changes:**
- Added `VideoContext` enum with cases: `.regular`, `.retweet`, `.quoted`, `.embedded`
- Updated `VideoPlaybackInfo` struct to include `context` field
- Added `shouldCoordinate` computed property to filter videos

**Code:**
```swift
enum VideoContext {
    case regular        // Main tweet video - fully coordinated
    case retweet       // Video from retweeted content - fully coordinated
    case quoted        // Video in quoted tweet - INDEPENDENT (not coordinated)
    case embedded      // Video in embedded preview - INDEPENDENT (not coordinated)
}

struct VideoPlaybackInfo: Equatable {
    let tweetId: String
    let videoMid: String
    let index: Int
    let context: VideoContext  // ✅ NEW
    
    var shouldCoordinate: Bool {
        switch context {
        case .regular, .retweet:
            return true
        case .quoted, .embedded:
            return false
        }
    }
}
```

### Fix 2: Improved Video List Building Logic

**Changes:**
- `buildVideoList()` now properly detects tweet types:
  - Pure retweet: No own content, has `originalTweetId` → context: `.retweet`
  - Quoted tweet: Has own content + `originalTweetId` → main videos: `.regular`, embedded videos: SKIPPED
  - Regular tweet: No `originalTweetId` → context: `.regular`
- Filters out non-coordinated videos before adding to `allVideos`
- Added extensive logging for debugging

**Key Changes:**
```swift
if isQuotedTweet {
    // Process ONLY main body videos
    // Embedded tweet videos are NOT coordinated
    // They use independent autoplay logic
}
```

### Fix 3: Added Mute State to All Notifications

**Changes:**
- All `.shouldPlayVideo` notifications now include `"isMuted": MuteState.shared.isMuted`
- This ensures videos respect global mute state from the moment they start
- Applied to:
  - `playVideoForSurvey()` - Survey phase videos
  - `endSurveyPhase()` - Primary video selection
  - `playNextVisibleVideo()` - Sequential playback
  - Foreground recovery methods

**Example:**
```swift
NotificationCenter.default.post(
    name: .shouldPlayVideo,
    object: nil,
    userInfo: [
        "tweetId": video.tweetId,
        "videoMid": video.videoMid,
        "videoIndex": video.index,
        "isSurvey": true,
        "isMuted": MuteState.shared.isMuted  // ✅ NEW
    ]
)
```

### Fix 4: Clear Play Commands on Individual Pause

**Changes:**
- `pauseVideo()` now clears `videosSentPlayCommands.remove(videoId)`
- Videos can now receive new play commands after being paused
- Prevents memory leak from unbounded set growth

**Code:**
```swift
private func pauseVideo(_ video: VideoPlaybackInfo) {
    let videoId = video.identifier
    currentlyPlayingVideoIds.remove(videoId)
    videosSentPlayCommands.remove(videoId)  // ✅ NEW
    
    NotificationCenter.default.post(...)
}
```

### Fix 5: Made Phase Transition Atomic

**Changes:**
- Moved `phase = .primaryPlaying` to the top of `endSurveyPhase()`
- This makes the transition atomic and prevents race conditions
- Second call will now fail the guard check immediately

**Before:**
```swift
guard phase == .surveying else { return }
// ... processing ...
phase = .primaryPlaying  // ❌ Too late
```

**After:**
```swift
guard phase == .surveying else { return }
phase = .primaryPlaying  // ✅ Atomic
// ... processing ...
```

### Fix 6: Removed Unbounded Retry Loop

**Changes:**
- Removed infinite retry loop in `handleForegroundRecovery()`
- Now relies on `handleVideoInfrastructureChanged()` notification
- When infrastructure becomes ready, that handler automatically restarts videos

**Before:**
```swift
guard AppDelegate.isVideoInfrastructureReady else {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.handleForegroundRecovery(notification)  // ❌ Infinite loop
    }
    return
}
```

**After:**
```swift
guard AppDelegate.isVideoInfrastructureReady else {
    print("Will auto-restart when ready (via notification)")
    return  // ✅ No retry, notification will handle it
}
```

### Fix 7: Added Safety Checks for Video Finished Events

**Changes:**
- `handleVideoFinished()` now verifies video is in `allVideos` list
- Prevents embedded videos from triggering sequential playback
- Added better logging for debugging

**Code:**
```swift
// Only respond to coordinated videos (mediaCell mode)
guard let modeString = notification.userInfo?["mode"] as? String,
      modeString == "mediaCell" else {
    return
}

// Verify video is in coordinated list
guard allVideos.contains(where: { $0.videoMid == videoMid }) else {
    print("Video not in coordinated list - ignoring")
    return
}
```

---

## Testing Checklist

### Basic Playback
- [ ] Regular tweet with single video plays correctly
- [ ] Regular tweet with multiple videos surveys then picks primary
- [ ] Videos respect global mute state from start
- [ ] Sequential playback works (primary → next → next)

### Retweets
- [ ] Pure retweet videos play correctly (coordinated)
- [ ] Pure retweet videos respect mute state
- [ ] Pure retweet videos participate in sequential playback

### Quoted Tweets
- [ ] Main body videos play correctly (coordinated)
- [ ] Embedded quoted tweet videos DO NOT play automatically
- [ ] Embedded videos use independent visibility-based autoplay
- [ ] Main body and embedded videos don't conflict
- [ ] Embedded videos only play when user scrolls to them

### Edge Cases
- [ ] Scrolling video off-screen then back works (no duplicate command error)
- [ ] Background → Foreground maintains correct state
- [ ] Long background (>5min) infrastructure restart works
- [ ] Multiple videos visible simultaneously during scroll works
- [ ] Phase transitions don't cause duplicate play commands

### Mute State
- [ ] Toggle mute while video playing updates immediately
- [ ] New videos respect current mute state
- [ ] Foreground recovery preserves mute state

---

## Impact Analysis

### What Changed
1. **VideoPlaybackInfo struct**: Added `context` field
2. **buildVideoList()**: Improved tweet type detection, filters embedded videos
3. **All play notifications**: Now include `isMuted` parameter
4. **pauseVideo()**: Clears `videosSentPlayCommands` entry
5. **endSurveyPhase()**: Phase transition is now atomic
6. **handleForegroundRecovery()**: Removed retry loop
7. **handleVideoFinished()**: Added safety checks

### What Didn't Change
- Notification names
- Basic coordinator flow (survey → primary → sequential)
- MediaCell's independent autoplay logic
- FullScreenVideoManager integration

### Breaking Changes
**None** - All changes are backward compatible. The coordinator now **ignores** videos it shouldn't manage, rather than breaking existing behavior.

---

## Future Improvements

### Potential Enhancements
1. **Preloading Strategy**: Preload next video during primary playback
2. **Visibility Scoring**: Better algorithm for primary video selection
3. **User Preferences**: Allow users to disable autoplay per context
4. **Analytics**: Track which videos complete vs skip
5. **Network Awareness**: Adjust behavior based on connection quality

### Known Limitations
1. Quoted tweet detection relies on presence of `originalTweetId` + `attachments`
2. Synchronous `fetchTweetSync()` call may block if cache miss
3. No distinction between different types of embeds (quote vs reply preview)

---

## Debugging Tips

### Enable Verbose Logging
All methods now include detailed logging with emoji prefixes:
- 🎬 Video list building
- ✅ Video added to coordination
- 🚫 Video skipped (independent)
- 📤 Play command sent
- ⏸️ Video paused
- ▶️ Video resumed
- 🔄 State recovery

### Check These When Debugging
1. Is video in `allVideos` list? (Should be if coordinated)
2. What's the video's `context`? (Check logs for "context: regular/retweet")
3. Is `phase` correct? (Should be idle → surveying → primaryPlaying)
4. Is video in `videosSentPlayCommands`? (Should be cleared on pause)
5. Is `shouldLoadVideo` flag set correctly in MediaGridView?

### Common Issues
**Video won't play:**
- Check if in `allVideos` (search logs for videoMid)
- Check if mode is "mediaCell" vs "embeddedDetail"
- Verify infrastructure is ready

**Video plays muted despite unmuted state:**
- Check notification userInfo includes "isMuted"
- Verify MuteState.shared.isMuted is correct
- Check if video respects notification parameter

**Duplicate play commands:**
- Check if video is in both `currentlyPlayingVideoIds` AND `videosSentPlayCommands`
- Should only be in both if currently playing
- Should be cleared from both when paused

---

## Related Files

### Modified
- `VideoPlaybackCoordinator.swift` - All fixes applied

### Potentially Affected (No Changes Needed)
- `MediaCell.swift` - Receives notifications (backward compatible)
- `MediaGridView.swift` - Passes `isEmbedded` flag (already correct)
- `TweetItemBodyView.swift` - Sets `isEmbedded` for quoted tweets (already correct)
- `SimpleVideoPlayer.swift` - Handles notifications (should respect new `isMuted` param)

### Related Systems
- `MuteState` - Global mute state singleton
- `VideoStateCache` - Video player caching
- `FullScreenVideoManager` - Receives same video list
- `AppDelegate` - Infrastructure readiness notifications

---

## Version History

**January 12, 2026** - Initial comprehensive fix
- Added video context tracking
- Fixed mute state propagation
- Resolved duplicate play command issue
- Made phase transitions atomic
- Improved embedded video handling
- Enhanced logging and safety checks
