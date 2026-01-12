# VideoPlaybackCoordinator Migration Guide

## Overview

This guide helps developers migrate code that interacts with VideoPlaybackCoordinator from v1.0 to v2.0.

**Version 2.0 Changes:** Added context tracking to distinguish coordinated vs independent videos.

---

## Breaking Changes

### ⚠️ VideoPlaybackInfo Structure Changed

**Before (v1.0):**
```swift
struct VideoPlaybackInfo {
    let tweetId: String
    let videoMid: String
    let index: Int
}
```

**After (v2.0):**
```swift
struct VideoPlaybackInfo {
    let tweetId: String
    let videoMid: String
    let index: Int
    let context: VideoContext  // ✅ NEW
    
    var shouldCoordinate: Bool { /* ... */ }  // ✅ NEW
}
```

**Impact:** 
- Any code creating `VideoPlaybackInfo` must now provide `context`
- FullScreenVideoManager receives updated structure

**Migration:**
```swift
// Old code:
let videoInfo = VideoPlaybackInfo(
    tweetId: tweet.mid,
    videoMid: video.mid,
    index: 0
)

// New code:
let videoInfo = VideoPlaybackInfo(
    tweetId: tweet.mid,
    videoMid: video.mid,
    index: 0,
    context: .regular  // ✅ Add context
)
```

---

## Non-Breaking Changes

### ✅ Notification UserInfo Enhanced

**Change:** All `.shouldPlayVideo` notifications now include `isMuted` parameter.

**Before (v1.0):**
```swift
NotificationCenter.default.post(
    name: .shouldPlayVideo,
    userInfo: [
        "videoMid": videoMid,
        "tweetId": tweetId
    ]
)
```

**After (v2.0):**
```swift
NotificationCenter.default.post(
    name: .shouldPlayVideo,
    userInfo: [
        "videoMid": videoMid,
        "tweetId": tweetId,
        "isMuted": MuteState.shared.isMuted  // ✅ NEW
    ]
)
```

**Impact:** 
- Video players can now respect mute state immediately
- Old code continues to work (parameter is optional)

**Recommended Update:**
```swift
// In video player notification handler:
.onReceive(NotificationCenter.default.publisher(for: .shouldPlayVideo)) { notification in
    // Old code (still works):
    player.isMuted = MuteState.shared.isMuted
    
    // New code (better):
    if let isMuted = notification.userInfo?["isMuted"] as? Bool {
        player.isMuted = isMuted  // ✅ Use notification value
    }
}
```

---

## Behavioral Changes

### 📝 buildVideoList() Filters Embedded Videos

**What Changed:**
- v1.0: Added all videos to `allVideos[]`
- v2.0: Only adds videos with `shouldCoordinate == true`

**Impact:**
- Quoted tweet embedded videos no longer in coordinator's list
- These videos now use MediaCell's independent autoplay
- No code changes needed (automatic)

**Verification:**
```swift
// Check coordinator's video count:
print("Coordinated videos: \(VideoPlaybackCoordinator.shared.allVideos.count)")
// Should be lower in v2.0 if feed has quoted tweets
```

---

### 📝 pauseVideo() Clears Command Cache

**What Changed:**
- v1.0: `videosSentPlayCommands` never cleared for individual videos
- v2.0: Cleared when video is paused

**Impact:**
- Videos can now replay after being paused
- No code changes needed (automatic)

**Verification:**
```swift
// Test replay:
1. Scroll video into view → plays ✅
2. Scroll video off-screen → pauses ✅
3. Scroll video back into view → plays again ✅ (was broken in v1.0)
```

---

### 📝 endSurveyPhase() Atomic Transition

**What Changed:**
- v1.0: Phase changed near end of method
- v2.0: Phase changed at start of method

**Impact:**
- No race conditions from duplicate calls
- No code changes needed (automatic)

**Verification:**
```swift
// Check logs for duplicate commands:
// v1.0: May see duplicate "Sending play command"
// v2.0: Will see "Skipping duplicate play command" instead
```

---

### 📝 Foreground Recovery No Longer Polls

**What Changed:**
- v1.0: Infinite retry loop checking infrastructure readiness
- v2.0: Returns immediately, relies on notification

**Impact:**
- Better CPU efficiency
- No code changes needed (automatic)

**Verification:**
```swift
// Monitor CPU during long background recovery:
// v1.0: Spike from polling loop
// v2.0: Flat (event-driven)
```

---

## API Compatibility Matrix

| API | v1.0 | v2.0 | Compatible? | Notes |
|-----|------|------|-------------|-------|
| `buildVideoList()` | ✅ | ✅ | ✅ Yes | Filters differently internally |
| `updateVisibleTweets()` | ✅ | ✅ | ✅ Yes | No changes |
| `stopAllVideos()` | ✅ | ✅ | ✅ Yes | No changes |
| `setTableView()` | ✅ | ✅ | ✅ Yes | No changes |
| `VideoPlaybackInfo` init | ✅ | ✅ | ⚠️ Partial | Requires `context` param |
| `.shouldPlayVideo` notification | ✅ | ✅ | ✅ Yes | Enhanced with `isMuted` |

---

## Custom Code Patterns

### Pattern 1: Creating VideoPlaybackInfo

**If you create VideoPlaybackInfo manually:**

```swift
// ❌ Old code (won't compile in v2.0):
let info = VideoPlaybackInfo(
    tweetId: "t1",
    videoMid: "v1",
    index: 0
)

// ✅ New code:
let info = VideoPlaybackInfo(
    tweetId: "t1",
    videoMid: "v1",
    index: 0,
    context: .regular  // Add appropriate context
)
```

**Choosing context:**
- Use `.regular` for main tweet videos
- Use `.retweet` for pure retweet videos
- Use `.quoted` for quoted tweet embeds (but these should NOT be added to coordinator!)
- Use `.embedded` for detail view embeds (but these should NOT be added to coordinator!)

### Pattern 2: Listening to Notifications

**If you observe `.shouldPlayVideo` notifications:**

```swift
// ✅ Compatible approach (works in both versions):
NotificationCenter.default.addObserver(
    forName: .shouldPlayVideo,
    object: nil,
    queue: .main
) { notification in
    guard let videoMid = notification.userInfo?["videoMid"] as? String else { return }
    
    // Optional: Use new isMuted parameter
    let isMuted = notification.userInfo?["isMuted"] as? Bool ?? MuteState.shared.isMuted
    
    // Your video handling code
}
```

### Pattern 3: Checking Coordinator State

**If you inspect coordinator's internal state:**

```swift
// ✅ Still works (but count may be lower):
let videoCount = VideoPlaybackCoordinator.shared.allVideos.count

// ✅ New capability:
let coordinatedCount = VideoPlaybackCoordinator.shared.allVideos
    .filter { $0.shouldCoordinate }
    .count
// Should equal allVideos.count in v2.0 (filtering happens in buildVideoList)
```

---

## Testing Migration

### Automated Tests

**Update test expectations:**

```swift
// Old test (may fail in v2.0):
func testBuildVideoList() {
    coordinator.buildVideoList(from: tweetsWithQuoted)
    XCTAssertEqual(coordinator.allVideos.count, 5)  // ❌ May be 3 in v2.0
}

// New test:
func testBuildVideoList() {
    coordinator.buildVideoList(from: tweetsWithQuoted)
    
    // Count only coordinated videos (v2.0 filters automatically)
    let expectedCount = tweetsWithQuoted.filter { tweet in
        // Logic to determine if tweet's videos should be coordinated
    }.count
    
    XCTAssertEqual(coordinator.allVideos.count, expectedCount)  // ✅ Correct
}
```

### Manual Tests

**Regression test checklist:**

1. **Regular Tweets:**
   - [ ] Single video plays
   - [ ] Multiple videos survey → primary
   - [ ] Sequential playback works

2. **Pure Retweets:**
   - [ ] Videos load from original
   - [ ] Play in correct position
   - [ ] Participate in sequential

3. **Quoted Tweets:**
   - [ ] Main body videos coordinated
   - [ ] Embedded videos independent
   - [ ] No conflicts

4. **Edge Cases:**
   - [ ] Scroll off/on replays
   - [ ] Background → Foreground works
   - [ ] Mute state correct from start

---

## Rollback Plan

### If v2.0 Causes Issues

**Immediate rollback:**
```bash
# Revert VideoPlaybackCoordinator.swift to previous version
git checkout HEAD~1 -- VideoPlaybackCoordinator.swift
```

**Compatibility shim (temporary):**
```swift
// Add this extension for backward compatibility with v1.0 code:
extension VideoPlaybackInfo {
    init(tweetId: String, videoMid: String, index: Int) {
        self.init(
            tweetId: tweetId,
            videoMid: videoMid,
            index: index,
            context: .regular  // Default to regular context
        )
    }
}
```

---

## Common Migration Issues

### Issue 1: Compilation Error in VideoPlaybackInfo

**Error:**
```
Missing argument for parameter 'context' in call
```

**Fix:**
Add `context` parameter to all `VideoPlaybackInfo` initializations.

---

### Issue 2: Video Count Mismatch

**Symptom:**
```
Expected 5 videos, got 3
```

**Cause:**
v2.0 filters out quoted/embedded videos.

**Fix:**
Update expectations to account for filtering.

---

### Issue 3: Tests Failing for Quoted Tweets

**Symptom:**
```
XCTAssertTrue(coordinator.allVideos.contains(embeddedVideoId)) // Fails
```

**Cause:**
Embedded videos no longer added to coordinator.

**Fix:**
Update test logic - embedded videos should NOT be in coordinator.

---

## Support & Resources

### Documentation
- **FIX_SUMMARY.md** - Overview of all changes
- **ARCHITECTURE.md** - New system design
- **DEBUG_GUIDE.md** - Troubleshooting help

### Questions?
1. Check documentation files
2. Review inline code comments
3. Run debug logging (emoji prefixes)
4. Inspect state with LLDB commands

---

## Migration Checklist

Use this checklist to verify migration:

### Code Changes
- [ ] Updated all `VideoPlaybackInfo` creations with `context`
- [ ] Added compatibility shim if needed
- [ ] Updated notification handlers to use `isMuted`

### Tests
- [ ] Updated video count expectations
- [ ] Updated quoted tweet test logic
- [ ] Added tests for new context system
- [ ] Verified regression tests pass

### Documentation
- [ ] Updated internal docs to reference v2.0
- [ ] Added migration notes to team wiki
- [ ] Updated API documentation

### Validation
- [ ] Manual testing complete (see checklist above)
- [ ] Performance profiling done (CPU, memory)
- [ ] Log output reviewed (clean, no errors)
- [ ] QA sign-off obtained

---

## Timeline Recommendation

| Phase | Duration | Activities |
|-------|----------|------------|
| **Preparation** | 1 day | Read docs, identify custom code |
| **Code Updates** | 2 days | Update VideoPlaybackInfo calls, add context |
| **Testing** | 2 days | Run tests, manual validation |
| **Deployment** | 1 day | Staged rollout, monitoring |
| **Total** | 1 week | Conservative estimate |

For simple projects with no custom code:
- **Immediate**: No code changes needed, deploy directly

---

## Success Criteria

Migration is complete when:
- ✅ All tests pass
- ✅ Video playback works correctly
- ✅ No compilation errors
- ✅ Performance is stable or improved
- ✅ Team understands new system

---

## Version History

**v2.0 - January 12, 2026**
- Added context tracking
- Filter embedded videos
- Enhanced notifications
- Improved reliability

**v1.0 - Previous**
- Basic coordination
- No context awareness

---

**Questions? See [VIDEO_COORDINATOR_DOCS_README.md](VIDEO_COORDINATOR_DOCS_README.md) for full documentation index.**
